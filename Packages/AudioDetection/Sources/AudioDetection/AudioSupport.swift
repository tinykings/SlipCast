import Accelerate
import AVFoundation
import Foundation

public struct AudioDetectionProgress: Sendable {
    public let fraction: Double
    public let message: String
    public init(fraction: Double, message: String) {
        self.fraction = fraction
        self.message = message
    }
}

public enum AudioDetectionError: LocalizedError {
    case invalidInput(String)
    case missingModel(String)
    case inferenceFailed

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message): message
        case .missingModel(let name): "Audio detection model is missing: \(name). Rebuild SlipCast with its model resources."
        case .inferenceFailed: "The audio model could not analyze this section."
        }
    }
}

public enum EpisodeAudioScanError: LocalizedError {
    case invalidCheckpoint
    case changedDownload
    public var errorDescription: String? {
        switch self {
        case .invalidCheckpoint: "The saved overlap scan is invalid. Re-scan this episode."
        case .changedDownload: "The downloaded audio changed during its overlap scan. Try processing it again."
        }
    }
}

package enum AudioSamples {
    /// Xcode's flat iOS bundle and SwiftPM's Contents/Resources Mac bundle differ, so look for
    /// `marker` in each candidate resources folder.
    package static func resources(in bundle: Bundle, containing marker: String) -> URL {
        let candidates = [bundle.bundleURL.appendingPathComponent("Resources")]
            + [bundle.resourceURL, bundle.resourceURL?.appendingPathComponent("Resources")].compactMap { $0 }
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path)
        } ?? candidates[0]
    }

    package static func read(_ url: URL, start: Double, duration: Double) throws -> (samples: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        return try read(file, start: start, duration: duration)
    }

    package static func read(_ file: AVAudioFile, start: Double, duration: Double) throws -> (samples: [Float], rate: Double) {
        let rate = file.processingFormat.sampleRate
        guard start < Double(file.length) / rate else {
            throw AudioDetectionError.invalidInput("The start time is past the end of this episode.")
        }
        file.framePosition = AVAudioFramePosition(start * rate)
        let frames = AVAudioFrameCount(min(Double(file.length - file.framePosition), duration * rate))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw AudioDetectionError.invalidInput("This section contains no audio.")
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { throw AudioDetectionError.inferenceFailed }
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: Int(buffer.frameLength))
        let monoCount = mono.count
        mono.withUnsafeMutableBufferPointer { output in
            for channel in 0..<channels {
                vDSP_vadd(output.baseAddress!, 1, data[channel], 1, output.baseAddress!, 1, vDSP_Length(monoCount))
            }
            var divisor = Float(channels)
            vDSP_vsdiv(output.baseAddress!, 1, &divisor, output.baseAddress!, 1, vDSP_Length(monoCount))
        }
        return (mono, rate)
    }

    package static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) throws -> [Float] {
        if sourceRate == targetRate { return samples }
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1)!
        let targetFormat = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * targetRate / sourceRate)) + 512
              ) else { throw AudioDetectionError.inferenceFailed }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard status != .error, output.frameLength > 0 else { throw AudioDetectionError.inferenceFailed }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
