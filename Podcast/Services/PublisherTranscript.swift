import Foundation

/// Transcripts published in the feed (`<podcast:transcript>`), for shows that aren't filtered.
/// They're only for reading along: muting always uses the on-device transcript, whose word
/// timings are exact.
nonisolated enum PublisherTranscript {
    /// Timed formats we can follow playback with, best first. HTML and plain-text transcripts
    /// have no timings, so they're skipped.
    enum Format: Int, Comparable, Sendable {
        case json, vtt, srt

        init?(type: String?, url: String) {
            switch type?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) {
            case "application/json": self = .json
            case "text/vtt": self = .vtt
            case "application/x-subrip", "application/srt", "text/srt", "text/x-subrip": self = .srt
            case nil, "", "application/octet-stream", "text/plain":
                // Some feeds leave the type out or get it wrong; fall back to the extension.
                switch URL(string: url)?.pathExtension.lowercased() {
                case "json": self = .json
                case "vtt": self = .vtt
                case "srt": self = .srt
                default: return nil
                }
            default: return nil
            }
        }

        static func < (lhs: Format, rhs: Format) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Cue: Equatable, Sendable {
        var start: Double
        var end: Double
        var text: String
    }

    enum FetchError: LocalizedError {
        case unsupported, empty
        var errorDescription: String? {
            switch self {
            case .unsupported: "This transcript's format isn't supported."
            case .empty: "The publisher's transcript is empty."
            }
        }
    }

    // MARK: Cache

    static func cacheURL(for episodeID: String) -> URL {
        Storage.transcriptsDirectory.appending(path: "\(episodeID).publisher.json")
    }

    static func cached(episodeID: String) -> [TranscriptWord]? {
        guard let data = try? Data(contentsOf: cacheURL(for: episodeID)) else { return nil }
        return try? JSONDecoder().decode([TranscriptWord].self, from: data)
    }

    static func delete(episodeID: String) {
        try? FileManager.default.removeItem(at: cacheURL(for: episodeID))
    }

    /// The cached transcript, or downloads, parses and caches it.
    @concurrent
    static func words(episodeID: String, url urlString: String, type: String?) async throws -> [TranscriptWord] {
        if let cached = cached(episodeID: episodeID) { return cached }
        guard let format = Format(type: type, url: urlString) else { throw FetchError.unsupported }
        guard var components = URLComponents(string: urlString) else { throw URLError(.badURL) }
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }  // ATS
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let words = words(from: try cues(from: data, format: format))
        guard !words.isEmpty else { throw FetchError.empty }
        try? JSONEncoder().encode(words).write(to: cacheURL(for: episodeID), options: .atomic)
        return words
    }

    // MARK: Parsing

    static func cues(from data: Data, format: Format) throws -> [Cue] {
        switch format {
        case .json: try jsonCues(data)
        case .vtt, .srt: timedTextCues(String(decoding: data, as: UTF8.self))
        }
    }

    /// Podcasting 2.0 JSON: `{"segments": [{"startTime": 0.5, "endTime": 1.2, "body": "Hi"}]}`.
    private static func jsonCues(_ data: Data) throws -> [Cue] {
        struct Document: Decodable {
            struct Segment: Decodable {
                var startTime: Double?
                var endTime: Double?
                var body: String?
            }
            var segments: [Segment]
        }
        return try JSONDecoder().decode(Document.self, from: data).segments.compactMap { segment in
            guard let start = segment.startTime, let body = segment.body else { return nil }
            return Cue(start: start, end: max(start, segment.endTime ?? start), text: body)
        }
    }

    /// WebVTT and SRT: blocks separated by blank lines, each with a `start --> end` line.
    static func timedTextCues(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = timestamp(parts[0]),
                  let end = timestamp(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "")
            else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: " ")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
            cues.append(Cue(start: start, end: max(start, end), text: body))
        }
        return cues
    }

    /// `01:02:03.456`, `02:03.456` or SRT's `01:02:03,456`.
    static func timestamp(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }

    /// Splits cues into words, spreading each cue's time across its words by length, so the
    /// transcript breaks into lines the same way as an on-device one.
    static func words(from cues: [Cue]) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            let tokens = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { continue }
            let totalLength = Double(tokens.reduce(0) { $0 + $1.count })
            let span = cue.end - cue.start
            var time = cue.start
            for token in tokens {
                let length = totalLength > 0 ? span * Double(token.count) / totalLength : 0
                words.append(TranscriptWord(text: token, start: time, end: time + length))
                time += length
            }
        }
        return words
    }
}
