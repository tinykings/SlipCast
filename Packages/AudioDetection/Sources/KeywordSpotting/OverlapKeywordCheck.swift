import AudioDetection
import AVFoundation
import CryptoKit
import Foundation

/// Muted words heard inside overlapping-speech clips, which the transcriber can't hear reliably.
/// Results are kept per keyword, so adding a muted word only listens for that word.
public struct OverlapKeywordCheck: Codable, Sendable {
    public static let engine = "gigaspeech-kws-2.0.1-overlap-v1"
    /// Audio before and after each clip, so a word that straddles its edge is still heard.
    public static let context = 0.5

    let engine: String
    let fingerprint: ReviewedAudioFingerprint
    let clipSignature: String
    public internal(set) var checked: Set<String>
    public internal(set) var hits: [AudioDetectionHit]

    public func covers(_ keywords: some Sequence<String>) -> Bool {
        keywords.allSatisfy(checked.contains)
    }

    public func hits(for keywords: Set<String>) -> [AudioDetectionHit] {
        hits.filter { keywords.contains($0.keyword) }
    }

    /// Lowercase ASCII words separated by single spaces, or nil if the spotter can't listen for it.
    public static func keyword(for term: String) -> String? {
        let words = term.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "/" })
            .map { $0.filter { $0.isLetter && $0.isASCII } }
            .filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.joined(separator: " ").lowercased()
    }

    static func signature(_ clips: [ClosedRange<Double>]) -> String {
        let text = clips.map { String(format: "%.3f-%.3f", $0.lowerBound, $0.upperBound) }.joined(separator: ",")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct OverlapKeywordStore: Sendable {
    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("OverlapKeywordChecks", isDirectory: true)
    }

    /// The saved check, if it was made for this exact download and these clips.
    public func load(episodeID: String, fileURL: URL, clips: [ClosedRange<Double>]) -> OverlapKeywordCheck? {
        guard let data = try? Data(contentsOf: path(episodeID)),
              let check = try? JSONDecoder().decode(OverlapKeywordCheck.self, from: data),
              check.engine == OverlapKeywordCheck.engine,
              check.clipSignature == OverlapKeywordCheck.signature(clips),
              check.fingerprint == (try? ReviewedMuteStore.fingerprint(fileURL)) else { return nil }
        return check
    }

    func save(_ check: OverlapKeywordCheck, episodeID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try folder.setResourceValues(flags)
        try JSONEncoder().encode(check).write(to: path(episodeID), options: .atomic)
    }

    public func remove(episodeID: String) {
        try? FileManager.default.removeItem(at: path(episodeID))
    }

    private func path(_ id: String) -> URL {
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
}

/// Serializes keyword checks; the spotter isn't thread-safe and each check is short.
public actor OverlapKeywordSpotter {
    public static let shared = OverlapKeywordSpotter()

    /// Listens for any of `keywords` not yet checked inside `clips` and saves the result.
    /// `keywords` should come from `OverlapKeywordCheck.keyword(for:)`.
    public func check(fileURL: URL, episodeID: String, clips: [ClosedRange<Double>], keywords: Set<String>,
                      store: OverlapKeywordStore = .init()) async throws -> OverlapKeywordCheck {
        try Task.checkCancellation()
        let fingerprint = try ReviewedMuteStore.fingerprint(fileURL)
        var check = store.load(episodeID: episodeID, fileURL: fileURL, clips: clips)
            ?? OverlapKeywordCheck(engine: OverlapKeywordCheck.engine, fingerprint: fingerprint,
                                   clipSignature: OverlapKeywordCheck.signature(clips), checked: [], hits: [])
        let missing = keywords.subtracting(check.checked)
        guard !missing.isEmpty else { return check }
        let tokenizer = try KeywordTokenizer.bundled()
        var wanted: [(String, [String])] = []
        for keyword in missing.sorted() {
            // A word the model has no tokens for can't be heard; it's recorded as checked with no hits.
            if let tokens = try? tokenizer.encode(phrase: keyword) { wanted.append((keyword, tokens)) }
            check.checked.insert(keyword)
        }
        if !clips.isEmpty, !wanted.isEmpty {
            let spotter = try KeywordSpotter(keywords: wanted)
            let longest = wanted.map { $0.0.split(separator: " ").count }.max() ?? 1
            let window = 1.28 + 0.45 * Double(longest - 1)
            let file = try AVAudioFile(forReading: fileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            var hits: [AudioDetectionHit] = []
            for clip in clips {
                try Task.checkCancellation()
                let start = max(0, clip.lowerBound - OverlapKeywordCheck.context)
                let end = min(duration, clip.upperBound + OverlapKeywordCheck.context)
                guard end > start else { continue }
                let source = try AudioSamples.read(file, start: start, duration: end - start)
                let samples = try AudioSamples.resample(source.samples, from: source.rate, to: 16_000)
                hits += try spotter.scan(samples, rate: 16_000, origin: start, window: window)
                await Task.yield()
            }
            check.hits = AudioDetectionHit.merge(check.hits + hits)
        }
        try Task.checkCancellation()
        try store.save(check, episodeID: episodeID)
        return check
    }
}
