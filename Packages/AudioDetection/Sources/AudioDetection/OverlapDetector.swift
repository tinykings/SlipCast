import AVFoundation
import Foundation
import OverlapRuntime

/// Detects overlapping speech without separating voices or recognizing words. Its passages
/// include clean speech, intentionally: enabled shows skip all detected overlap passages.
public actor OverlapDetector {
    public static let shared = OverlapDetector()
    public init() {}

    public func scan(fileURL: URL, episodeID: String, store: OverlapScanStore = .init(),
                     onActivity: @escaping @Sendable (AudioDetectionProgress) -> Void = { _ in },
                     onUpdate: @escaping @Sendable (OverlapScan) -> Void) async throws -> OverlapScan {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: fileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw AudioDetectionError.invalidInput("This episode contains no readable audio.") }
        var scan = try store.load(episodeID: episodeID, fileURL: fileURL)
            ?? OverlapScan(fingerprint: ReviewedMuteStore.fingerprint(fileURL), duration: duration)
        guard abs(scan.duration - duration) < 0.01 else { throw EpisodeAudioScanError.changedDownload }
        try store.save(scan, episodeID: episodeID, fileURL: fileURL)
        onUpdate(scan)
        if scan.isComplete { return scan }
        onActivity(.init(fraction: scan.fraction, message: "Preparing fast overlap detector…"))
        let runtime = try OverlapModel(url: Self.modelURL)
        onUpdate(scan)
        while !scan.isComplete {
            try Task.checkCancellation()
            let began = Date(), window = scan.nextWindow
            let start = Double(window) * 2.5
            let source = try AudioSamples.read(file, start: start, duration: 10)
            var samples = try AudioSamples.resample(source.samples, from: source.rate, to: 16000)
            if samples.count > 160000 { samples.removeLast(samples.count - 160000) }
            if samples.count < 160000 { samples += [Float](repeating: 0, count: 160000 - samples.count) }
            let scores = try runtime.predict(samples)
            let keep = (window == 0 ? 0 : start + 3.75)...(window == scan.windowCount - 1 ? duration : start + 6.25)
            let regions = Self.regions(scores: scores, start: start, duration: duration, keep: keep)
            try scan.append(window: window, regions: regions, elapsed: Date().timeIntervalSince(began))
            try Task.checkCancellation()
            try store.save(scan, episodeID: episodeID, fileURL: fileURL)
            onUpdate(scan)
            await Task.yield()
        }
        return scan
    }

    static var modelURL: URL {
        AudioSamples.models(in: .module).appendingPathComponent("VoiceOverlap.onnx")
    }

    /// Window edges are unreliable, so each window only reports frames inside `keep` (its middle
    /// 2.5 s, or the episode edge). Hysteresis runs over the whole window so a passage that
    /// started before `keep` still counts. Minimum length is applied after windows are joined.
    static func regions(scores: [Float], start: Double, duration: Double, keep: ClosedRange<Double>,
                        onset: Float = 0.9, offset: Float = 0.7) -> [OverlapRegion] {
        let step = 270.0 / 16000, center = 495.5 / 16000
        let lowerBound = max(0, keep.lowerBound), upperBound = min(duration, keep.upperBound)
        var regions: [OverlapRegion] = []
        var first: Int?
        for index in 0...scores.count {
            let active = index < scores.count && scores[index] >= (first == nil ? onset : offset)
            if active, first == nil { first = index }
            if !active, let beginning = first {
                let lower = max(lowerBound, start + center + Double(beginning) * step - step / 2)
                let upper = min(upperBound, start + center + Double(index) * step - step / 2)
                if upper > lower { regions.append(OverlapRegion(start: lower, end: upper)) }
                first = nil
            }
        }
        return regions
    }
}

/// The native session stays on one detector actor. No shared mutable C buffers cross actors.
private final class OverlapModel {
    private let runtime: OpaquePointer
    init(url: URL) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard let runtime = SCOverlapCreate(url.path, &error, error.count) else {
            throw AudioDetectionError.invalidInput("Couldn't load the overlap model: \(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))")
        }
        self.runtime = runtime
    }
    deinit { SCOverlapDestroy(runtime) }
    func predict(_ samples: [Float]) throws -> [Float] {
        var output = [Float](repeating: 0, count: 1024), frames = 0
        var error = [CChar](repeating: 0, count: 1024)
        let status = samples.withUnsafeBufferPointer { input in
            SCOverlapRun(runtime, input.baseAddress, input.count, &output, output.count, &frames, &error, error.count)
        }
        guard status == 1 else {
            throw AudioDetectionError.invalidInput("The overlap model couldn't read this audio: \(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))")
        }
        return Array(output.prefix(frames))
    }
}
