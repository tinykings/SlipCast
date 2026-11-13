import AudioDetection
import Foundation
import SherpaOnnxC

/// The bundled GigaSpeech keyword-spotting model (~5 MB). English only.
public enum KeywordModel {
    public static var resources: URL { AudioSamples.models(in: .module) }
}

public struct AudioDetectionHit: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let keyword: String
    /// Onset of the keyword's first token, in episode seconds.
    public var firstToken: Double
    /// Onset of its last token. The word continues a little past this.
    public var lastToken: Double
    public var supportingScans: Int

    public init(id: UUID, keyword: String, firstToken: Double, lastToken: Double, supportingScans: Int) {
        self.id = id
        self.keyword = keyword
        self.firstToken = firstToken
        self.lastToken = lastToken
        self.supportingScans = supportingScans
    }

    public func muteRange(padding: Double, extraAfter: Double = 0) -> ClosedRange<Double> {
        max(0, firstToken - padding)...(lastToken + 0.15 + padding + max(0, extraAfter))
    }

    /// Joins repeated detections of the same keyword that start within 0.25 s of each other.
    public static func merge(_ hits: [AudioDetectionHit]) -> [AudioDetectionHit] {
        var output: [AudioDetectionHit] = []
        for group in Dictionary(grouping: hits, by: \.keyword).values {
            var merged: [AudioDetectionHit] = []
            for hit in group.sorted(by: { $0.firstToken < $1.firstToken }) {
                if let index = merged.indices.last, hit.firstToken - merged[index].firstToken <= 0.25 {
                    merged[index].lastToken = max(merged[index].lastToken, hit.lastToken)
                    merged[index].supportingScans = max(merged[index].supportingScans, hit.supportingScans)
                } else { merged.append(hit) }
            }
            output += merged
        }
        return output.sorted { ($0.firstToken, $0.keyword) < ($1.firstToken, $1.keyword) }
    }
}

/// The model's file is named bpe.model, but it uses SentencePiece's unigram model.
/// Select the highest-scoring complete segmentation, including the leading word marker.
public struct KeywordTokenizer: Sendable {
    let vocabulary: [String: Double]

    public init(vocabulary: [String: Double]) { self.vocabulary = vocabulary }

    public static func bundled() throws -> KeywordTokenizer {
        KeywordTokenizer(vocabulary: try JSONDecoder().decode([String: Double].self,
            from: Data(contentsOf: KeywordModel.resources.appendingPathComponent("keyword-vocabulary.json"))))
    }

    /// Tokens for one word, or each word of a phrase in turn.
    public func encode(phrase: String) throws -> [String] {
        try phrase.split(separator: " ").flatMap { try encode(String($0)) }
    }

    public func encode(_ word: String) throws -> [String] {
        let characters = Array(("▁" + word.uppercased()).map(String.init))
        let limit = vocabulary.keys.map(\.count).max() ?? 1
        var scores = [Float](repeating: -.infinity, count: characters.count + 1)
        var previous = [Int](repeating: -1, count: scores.count)
        scores[0] = 0
        for start in characters.indices where scores[start].isFinite {
            for end in (start + 1)...min(characters.count, start + limit) {
                let piece = characters[start..<end].joined()
                guard let score = vocabulary[piece] else { continue }
                let candidate = scores[start] + Float(score)
                if candidate > scores[end] {
                    scores[end] = candidate
                    previous[end] = start
                }
            }
        }
        guard previous[characters.count] >= 0 else {
            throw AudioDetectionError.invalidInput("This model cannot encode that word. Try an English word.")
        }
        var pieces: [String] = []
        var end = characters.count
        while end > 0 {
            let start = previous[end]
            pieces.append(characters[start..<end].joined())
            end = start
        }
        return pieces.reversed()
    }
}

/// Not thread-safe: use one instance from one task or actor at a time.
public final class KeywordSpotter {
    /// How readily a keyword fires. Lower threshold and higher boost catch more words and
    /// cause more false alarms.
    public struct Sensitivity: Sendable, Equatable {
        public var threshold: Float
        public var boost: Float
        /// Overlapping windows that must agree before a detection counts.
        public var minimumSupport: Int
        public init(threshold: Float, boost: Float, minimumSupport: Int) {
            self.threshold = threshold; self.boost = boost; self.minimumSupport = minimumSupport
        }
        public static let standard = Sensitivity(threshold: 0.25, boost: 1, minimumSupport: 2)
    }

    private let pointer: OpaquePointer
    private let sensitivity: Sensitivity

    public convenience init(resources: URL = KeywordModel.resources, tokens: [String]) throws {
        try self.init(resources: resources, keywords: [("target", tokens)])
    }

    public init(resources: URL = KeywordModel.resources, keywords: [(String, [String])],
                sensitivity: Sensitivity = .standard) throws {
        self.sensitivity = sensitivity
        let files = ["keyword-encoder.onnx", "keyword-decoder.onnx", "keyword-joiner.onnx", "keyword-tokens.txt"]
        for file in files where !FileManager.default.fileExists(atPath: resources.appendingPathComponent(file).path) {
            throw AudioDetectionError.missingModel(file)
        }
        // sherpa-onnx keyword names can't contain spaces.
        let keywordText = keywords.map { $0.1.joined(separator: " ") + " @" + $0.0.replacingOccurrences(of: " ", with: "_") + "\n" }.joined()
        let strings = files.map { resources.appendingPathComponent($0).path } + ["cpu", keywordText]
        let pointers = strings.map { strdup($0)! }
        defer { for pointer in pointers { free(pointer) } }
        var config = SherpaOnnxKeywordSpotterConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = UnsafePointer(pointers[0])
        config.model_config.transducer.decoder = UnsafePointer(pointers[1])
        config.model_config.transducer.joiner = UnsafePointer(pointers[2])
        config.model_config.tokens = UnsafePointer(pointers[3])
        config.model_config.provider = UnsafePointer(pointers[4])
        config.model_config.num_threads = 2
        config.model_config.debug = 0
        config.max_active_paths = 4
        config.num_trailing_blanks = 1
        config.keywords_score = sensitivity.boost
        config.keywords_threshold = sensitivity.threshold
        config.keywords_buf = UnsafePointer(pointers[5])
        config.keywords_buf_size = Int32(keywordText.utf8.count)
        guard let pointer = SherpaOnnxCreateKeywordSpotter(&config) else { throw AudioDetectionError.inferenceFailed }
        self.pointer = pointer
    }

    deinit { SherpaOnnxDestroyKeywordSpotter(pointer) }

    /// Scans overlapping short windows and keeps detections seen by at least two of them.
    /// `window` must be long enough to hold the longest keyword.
    public func scan(_ samples: [Float], rate: Int, origin: Double, keyword: String? = nil,
                     window: Double = 1.28) throws -> [AudioDetectionHit] {
        struct Candidate { let keyword: String; let onset: Double; let last: Double; let scan: Int }
        var groups: [[Candidate]] = []
        guard !samples.isEmpty else { return [] }
        for offset in stride(from: 0, to: samples.count, by: Int(0.32 * Double(rate))) {
            try Task.checkCancellation()
            guard let stream = SherpaOnnxCreateKeywordStream(pointer) else { throw AudioDetectionError.inferenceFailed }
            defer { SherpaOnnxDestroyOnlineStream(stream) }
            let count = min(samples.count - offset, Int(window * Double(rate)))
            samples.withUnsafeBufferPointer {
                SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(rate), $0.baseAddress!.advanced(by: offset), Int32(count))
            }
            let tail = [Float](repeating: 0, count: Int(0.66 * Double(rate)))
            tail.withUnsafeBufferPointer {
                SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(rate), $0.baseAddress, Int32(tail.count))
            }
            SherpaOnnxOnlineStreamInputFinished(stream)
            while SherpaOnnxIsKeywordStreamReady(pointer, stream) == 1 {
                SherpaOnnxDecodeKeywordStream(pointer, stream)
                guard let result = SherpaOnnxGetKeywordResult(pointer, stream) else { throw AudioDetectionError.inferenceFailed }
                defer { SherpaOnnxDestroyKeywordResult(result) }
                if let word = result.pointee.keyword, word.pointee != 0 {
                    if result.pointee.count > 0, let times = result.pointee.timestamps {
                        let onsets = UnsafeBufferPointer(start: times, count: Int(result.pointee.count)).map(Double.init)
                        let start = origin + Double(offset) / Double(rate)
                        if let first = onsets.min(), let last = onsets.max(),
                           first >= 0, start + first <= origin + Double(samples.count) / Double(rate) {
                            let name = keyword ?? String(cString: word).replacingOccurrences(of: "_", with: " ")
                            let candidate = Candidate(keyword: name, onset: start + first, last: start + last, scan: offset)
                            if let index = groups.firstIndex(where: { $0[0].keyword == candidate.keyword && abs($0[0].onset - candidate.onset) <= 0.2 }) {
                                groups[index].append(candidate)
                            } else { groups.append([candidate]) }
                        }
                    }
                    break // Fresh short streams avoid the library's timestamp reset after silence.
                }
            }
        }
        return groups.filter { $0.count >= sensitivity.minimumSupport }.map { group in
            let starts = group.map(\.onset).sorted()
            let ends = group.map(\.last).sorted()
            func median(_ values: [Double]) -> Double {
                let mid = values.count / 2
                return values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
            }
            return AudioDetectionHit(id: UUID(), keyword: group[0].keyword, firstToken: median(starts), lastToken: median(ends), supportingScans: group.count)
        }
    }
}
