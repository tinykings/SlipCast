import Foundation
import os

/// One recognized word with its position in the episode audio, in seconds.
nonisolated struct TranscriptWord: Codable, Sendable, Hashable {
    var text: String
    var start: Double
    var end: Double
}

/// Transcripts are stored as JSON files (not SwiftData rows) since an hour of audio is ~10k words.
/// The transcript is kept permanently so changing the mute list only re-runs matching.
nonisolated enum TranscriptStore {
    static let engineIdentifier = "apple-speech-v1"
    private struct Document: Codable {
        let engine: String
        let words: [TranscriptWord]
    }
    static func url(for episodeID: String) -> URL {
        Storage.transcriptsDirectory.appending(path: "\(episodeID).json")
    }

    static func save(_ words: [TranscriptWord], episodeID: String, engine: String) throws {
        let data = try JSONEncoder().encode(Document(engine: engine, words: words))
        forgetCurrent(episodeID: episodeID)
        try data.write(to: url(for: episodeID), options: .atomic)
    }

    static func load(episodeID: String) throws -> [TranscriptWord] {
        let data = try Data(contentsOf: url(for: episodeID))
        if let document = try? JSONDecoder().decode(Document.self, from: data) { return document.words }
        return try JSONDecoder().decode([TranscriptWord].self, from: data)
    }

    /// Whether a complete transcript from the current engine is saved. Answering means decoding
    /// the whole file, and this is asked about every download whenever the queue looks for work,
    /// so the answer is remembered until the file's size or modification date changes.
    static func isCurrent(episodeID: String) -> Bool {
        let fileURL = url(for: episodeID)
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else {
            forgetCurrent(episodeID: episodeID)
            return false
        }
        let stamp = FileStamp(size: size, modified: values.contentModificationDate)
        if let known = currentCache.withLock({ $0[episodeID] }), known.stamp == stamp { return known.isCurrent }
        let current = decodeIsCurrent(fileURL)
        currentCache.withLock { $0[episodeID] = CachedCheck(stamp: stamp, isCurrent: current) }
        return current
    }

    private static func decodeIsCurrent(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        if let document = try? JSONDecoder().decode(Document.self, from: data) {
            return document.engine == engineIdentifier
        }
        // Transcripts saved before engine metadata was added used Apple Speech.
        return (try? JSONDecoder().decode([TranscriptWord].self, from: data)) != nil
    }

    private struct FileStamp: Equatable, Sendable {
        let size: Int
        let modified: Date?
    }

    private struct CachedCheck: Sendable {
        let stamp: FileStamp
        let isCurrent: Bool
    }

    private static let currentCache = OSAllocatedUnfairLock(initialState: [String: CachedCheck]())

    private static func forgetCurrent(episodeID: String) {
        _ = currentCache.withLock { $0.removeValue(forKey: episodeID) }
    }

    static func delete(episodeID: String) {
        forgetCurrent(episodeID: episodeID)
        try? FileManager.default.removeItem(at: url(for: episodeID))
        deletePartial(episodeID: episodeID)
        MusicSections.delete(episodeID: episodeID)
    }

    // MARK: Partial transcripts

    /// Words finalized so far by an interrupted transcription, so a later run resumes at
    /// `through` instead of starting over.
    struct Partial: Codable {
        let engine: String
        let locale: String
        /// Length of the audio file this was made from, to reject a checkpoint for other audio.
        let duration: Double
        let through: Double
        let words: [TranscriptWord]
    }

    static func partialURL(for episodeID: String) -> URL {
        Storage.transcriptsDirectory.appending(path: "\(episodeID).partial.json")
    }

    static func savePartial(_ partial: Partial, episodeID: String) throws {
        try JSONEncoder().encode(partial).write(to: partialURL(for: episodeID), options: .atomic)
    }

    /// The checkpoint if it matches the current engine, locale and audio.
    static func loadPartial(episodeID: String, locale: Locale, duration: Double) -> Partial? {
        guard let data = try? Data(contentsOf: partialURL(for: episodeID)),
              let partial = try? JSONDecoder().decode(Partial.self, from: data),
              partial.engine == engineIdentifier, partial.locale == locale.identifier,
              abs(partial.duration - duration) < 0.5, partial.through > 0, partial.through < duration else { return nil }
        return partial
    }

    static func deletePartial(episodeID: String) {
        try? FileManager.default.removeItem(at: partialURL(for: episodeID))
    }
}

/// A run of transcript words shown as one line in the player's transcript.
nonisolated struct TranscriptLine: Identifiable, Sendable, Hashable {
    struct Word: Sendable, Hashable {
        var text: String
        var isMuted: Bool
        /// Spoken inside a skipped passage, so it's never heard.
        var isSkipped = false
        /// Not a word: marks where playback jumps past a skipped passage.
        var isSkipMarker = false
    }

    let id: Int
    var start: Double
    var end: Double
    var words: [Word]
    /// Not speech: marks where music plays without anyone talking. Has no words.
    var isMusic = false

    var containsMutedWord: Bool { words.contains { $0.isMuted || $0.isSkipped || $0.isSkipMarker } }

    /// Splits a transcript into lines at sentence ends, long pauses, or a maximum length.
    /// Each skipped passage gets a marker before the first word at or after its start.
    static func lines(from words: [TranscriptWord], mutedWordIndices muted: Set<Int>,
                      skippedRanges: [ClosedRange<Double>] = []) -> [TranscriptLine] {
        let skipped = skippedRanges.sorted { $0.lowerBound < $1.lowerBound }
        var nextSkip = 0
        var lines: [TranscriptLine] = []
        var current: TranscriptLine?
        for (index, word) in words.enumerated() {
            if let line = current, word.start - line.end > 1.2 {
                lines.append(line)
                current = nil
            }
            let middle = (word.start + word.end) / 2
            var line = current ?? TranscriptLine(id: lines.count, start: word.start, end: word.end, words: [])
            while nextSkip < skipped.count, skipped[nextSkip].lowerBound <= middle {
                line.start = min(line.start, skipped[nextSkip].lowerBound)
                line.words.append(Word(text: "", isMuted: false, isSkipMarker: true))
                nextSkip += 1
            }
            let isSkipped = skipped.contains { $0.contains(middle) }
            line.words.append(Word(text: word.text, isMuted: muted.contains(index), isSkipped: isSkipped))
            line.end = word.end
            let endsSentence = word.text.last.map { ".?!".contains($0) } ?? false
            let spoken = line.words.count(where: { !$0.isSkipMarker })
            if (endsSentence && spoken >= 4) || spoken >= 18 {
                lines.append(line)
                current = nil
            } else {
                current = line
            }
        }
        if nextSkip < skipped.count, var line = current ?? lines.popLast() {
            for _ in nextSkip..<skipped.count { line.words.append(Word(text: "", isMuted: false, isSkipMarker: true)) }
            current = line
        }
        if let current { lines.append(current) }
        return lines
    }

    /// Adds a line for each music section, in time order. Lines are renumbered.
    static func adding(_ music: [MusicSection], to lines: [TranscriptLine]) -> [TranscriptLine] {
        guard !music.isEmpty else { return lines }
        var result: [TranscriptLine] = []
        var next = 0
        func appendMusic() {
            result.append(TranscriptLine(id: result.count, start: music[next].start, end: music[next].end,
                                         words: [], isMusic: true))
            next += 1
        }
        for line in lines {
            while next < music.count, music[next].start <= line.start { appendMusic() }
            result.append(TranscriptLine(id: result.count, start: line.start, end: line.end, words: line.words))
        }
        while next < music.count { appendMusic() }
        return result
    }
}
