import Accelerate
import AVFoundation
import Foundation
import SoundAnalysis

/// A stretch of an episode with sound but no spoken words: usually a jingle or the music that
/// opens or closes an ad break.
nonisolated struct MusicSection: Codable, Sendable, Hashable {
    var start: Double
    var end: Double
}

/// Finds music by listening only where the transcript has no words. Sound in a wordless gap is
/// given to the system's sound classifier, and kept only if that hears music. Only a few minutes
/// of audio are read and classified, however long the episode is.
/// Music playing underneath speech is deliberately not found.
nonisolated enum MusicSections {
    /// Bump to throw away saved results when detection changes.
    private static let version = 2
    /// Wordless gaps shorter than this are ordinary pauses.
    static let minimumGap = 2.5
    /// Word times are approximate: stay this far away from the neighbouring words.
    static let wordMargin = 0.25
    /// Loudness is measured in steps of this many seconds.
    static let frame = 0.05
    /// Sound has to last this long to count.
    static let minimumLength = 1.5
    /// Quieter moments up to this long don't end a section.
    static let bridge = 0.4
    /// At most this much of a section is classified; the start says whether it's music.
    static let classifiedLength = 15.0
    /// The classifier's confidence (0...1) that a window of sound is music.
    static let musicConfidence = 0.3

    // MARK: Finding

    /// The stretches without words that are long enough to hold music, trimmed away from the
    /// words on either side. `words` must be in order.
    static func gaps(in words: [TranscriptWord], duration: Double) -> [ClosedRange<Double>] {
        var gaps: [ClosedRange<Double>] = []
        var spokenThrough = 0.0
        for word in words where word.start.isFinite && word.end.isFinite {
            if word.start - spokenThrough >= minimumGap {
                let lower = spokenThrough == 0 ? 0 : spokenThrough + wordMargin
                gaps.append(lower...(word.start - wordMargin))
            }
            spokenThrough = max(spokenThrough, word.end)
        }
        if duration - spokenThrough >= minimumGap {
            gaps.append((spokenThrough == 0 ? 0 : spokenThrough + wordMargin)...duration)
        }
        return gaps
    }

    /// Runs of sound above `threshold` (dB) in a gap's loudness frames. `offset` is the time of
    /// the first frame.
    static func runs(levels: [Float], threshold: Float, offset: Double) -> [MusicSection] {
        let bridgeFrames = Int((bridge / frame).rounded())
        var sections: [MusicSection] = []
        var runStart: Int?
        var lastLoud = 0
        func close() {
            guard let start = runStart else { return }
            runStart = nil
            let length = Double(lastLoud + 1 - start) * frame
            guard length >= minimumLength else { return }
            sections.append(MusicSection(start: offset + Double(start) * frame,
                                         end: offset + Double(lastLoud + 1) * frame))
        }
        for (index, level) in levels.enumerated() {
            if level > threshold {
                if runStart == nil { runStart = index }
                lastLoud = index
            } else if runStart != nil, index - lastLoud > bridgeFrames {
                close()
            }
        }
        close()
        return sections
    }

    /// What counts as sound: well below how loud the speech is, within sensible limits.
    static func threshold(speechLevels: [Float]) -> Float {
        guard !speechLevels.isEmpty else { return -45 }
        let sorted = speechLevels.sorted()
        let speech = sorted[min(sorted.count - 1, sorted.count * 7 / 10)]
        return min(-35, max(-55, speech - 25))
    }

    private static func detect(in file: AVAudioFile, words: [TranscriptWord], duration: Double) throws -> [MusicSection] {
        // How loud speech is in this episode, from a few short samples spread through it.
        var speechLevels: [Float] = []
        let samples = min(7, words.count)
        for sample in 0..<samples {
            let word = words[(words.count - 1) * sample / max(1, samples - 1)]
            guard word.start.isFinite, word.start >= 0 else { continue }
            speechLevels += try levels(in: file, from: word.start, to: word.start + 3)
        }
        let threshold = threshold(speechLevels: speechLevels)

        var sections: [MusicSection] = []
        for gap in gaps(in: words, duration: duration) {
            let gapLevels = try levels(in: file, from: gap.lowerBound, to: gap.upperBound)
            for candidate in runs(levels: gapLevels, threshold: threshold, offset: gap.lowerBound) {
                // If the classifier can't run, sound without words is the best guess there is.
                let heard = try? isMusic(candidate, in: file)
                try Task.checkCancellation()
                if heard ?? true { sections.append(candidate) }
            }
        }
        return sections
    }

    /// Whether the system sound classifier hears music in a section. Nil when it gave no answer.
    private static func isMusic(_ section: MusicSection, in file: AVAudioFile) throws -> Bool? {
        let format = file.processingFormat
        let rate = format.sampleRate
        let length = min(section.end - section.start, classifiedLength)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: min(3, max(1, length)), preferredTimescale: 600)
        request.overlapFactor = 0.5
        let observer = MusicObserver()
        let analyzer = SNAudioStreamAnalyzer(format: format)
        try analyzer.add(request, withObserver: observer)

        let chunk = AVAudioFrameCount(rate)  // 1 s at a time
        guard chunk > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        file.framePosition = min(file.length, AVAudioFramePosition(section.start * rate))
        var remaining = min(Int(length * rate), Int(file.length - file.framePosition))
        var position: AVAudioFramePosition = 0
        while remaining > 0 {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(remaining)))
            guard buffer.frameLength > 0 else { break }
            analyzer.analyze(buffer, atAudioFramePosition: position)
            position += AVAudioFramePosition(buffer.frameLength)
            remaining -= Int(buffer.frameLength)
        }
        analyzer.completeAnalysis()
        return observer.verdict
    }

    /// Loudness in dB of each `frame` of the audio between two times.
    private static func levels(in file: AVAudioFile, from start: Double, to end: Double) throws -> [Float] {
        let format = file.processingFormat
        let rate = format.sampleRate
        let frameLength = Int(rate * frame)
        let first = AVAudioFramePosition(max(0, start) * rate)
        let last = min(file.length, AVAudioFramePosition(end * rate))
        let chunk = frameLength * 400  // 20 s at a time
        guard frameLength > 0, last > first,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { return [] }
        file.framePosition = first
        let channelCount = Int(format.channelCount)
        var levels: [Float] = []
        var remaining = Int(last - first)
        while remaining >= frameLength {
            try Task.checkCancellation()
            let wanted = min(chunk, remaining / frameLength * frameLength)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(wanted))
            let read = Int(buffer.frameLength)
            guard read >= frameLength, let channels = buffer.floatChannelData else { break }
            for index in 0..<(read / frameLength) {
                var total: Float = 0
                for channel in 0..<channelCount {
                    var meanSquare: Float = 0
                    vDSP_measqv(channels[channel] + index * frameLength, 1, &meanSquare, vDSP_Length(frameLength))
                    total += meanSquare
                }
                levels.append(10 * log10(max(total / Float(max(1, channelCount)), 1e-10)))
            }
            if read < wanted { break }
            remaining -= read
        }
        return levels
    }

    // MARK: Saved results

    private struct Document: Codable {
        let version: Int
        /// Length of the audio these were found in, to reject results for other audio.
        let duration: Double
        let sections: [MusicSection]
    }

    static func cacheURL(for episodeID: String) -> URL {
        Storage.transcriptsDirectory.appending(path: "\(episodeID).music.json")
    }

    static func delete(episodeID: String) {
        try? FileManager.default.removeItem(at: cacheURL(for: episodeID))
    }

    /// The episode's music sections: saved ones, or found now from its finished transcript (a
    /// few seconds). Nil when there's no complete transcript yet or the audio can't be read.
    @concurrent
    static func load(episodeID: String, fileURL: URL, allowPublisherTranscript: Bool) async -> [MusicSection]? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        if let data = try? Data(contentsOf: cacheURL(for: episodeID)),
           let document = try? JSONDecoder().decode(Document.self, from: data),
           document.version == version, abs(document.duration - duration) < 0.5 {
            return document.sections
        }
        let words: [TranscriptWord]
        if TranscriptStore.isCurrent(episodeID: episodeID), let made = try? TranscriptStore.load(episodeID: episodeID) {
            words = made
        } else if allowPublisherTranscript, let published = PublisherTranscript.cached(episodeID: episodeID) {
            words = published
        } else {
            return nil
        }
        // Without any words everything would look like music.
        guard !words.isEmpty else { return [] }
        guard let sections = try? detect(in: file, words: words, duration: duration) else { return nil }
        let document = Document(version: version, duration: duration, sections: sections)
        try? JSONEncoder().encode(document).write(to: cacheURL(for: episodeID), options: .atomic)
        return sections
    }
}

/// Collects the sound classifier's results for one section.
nonisolated private final class MusicObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var windows = 0
    private var musical = 0

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let music = result.classification(forIdentifier: "music")?.confidence ?? 0
        let speech = result.classification(forIdentifier: "speech")?.confidence ?? 0
        lock.lock()
        windows += 1
        if music >= MusicSections.musicConfidence, music > speech { musical += 1 }
        lock.unlock()
    }

    /// Music if at least half of the windows were. Nil when nothing was classified.
    var verdict: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return windows == 0 ? nil : musical * 2 >= windows
    }
}
