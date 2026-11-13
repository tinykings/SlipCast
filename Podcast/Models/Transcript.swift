import Foundation

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
        try data.write(to: url(for: episodeID), options: .atomic)
    }

    static func load(episodeID: String) throws -> [TranscriptWord] {
        let data = try Data(contentsOf: url(for: episodeID))
        if let document = try? JSONDecoder().decode(Document.self, from: data) { return document.words }
        return try JSONDecoder().decode([TranscriptWord].self, from: data)
    }

    static func isCurrent(episodeID: String) -> Bool {
        guard let data = try? Data(contentsOf: url(for: episodeID)) else { return false }
        if let document = try? JSONDecoder().decode(Document.self, from: data) {
            return document.engine == engineIdentifier
        }
        // Transcripts saved before engine metadata was added used Apple Speech.
        return (try? JSONDecoder().decode([TranscriptWord].self, from: data)) != nil
    }

    static func delete(episodeID: String) {
        try? FileManager.default.removeItem(at: url(for: episodeID))
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
}
