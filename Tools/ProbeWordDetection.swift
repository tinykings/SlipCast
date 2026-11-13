import AVFoundation
import Foundation

// Runs the app's real transcription and matching pipeline on a short local audio excerpt.
// Uses Apple Speech, matching normal playback. Requires SpeechTranscriber on the host.
// Build with Storage.swift, Transcript.swift, MuteMatcher.swift, and TranscriptionService.swift.
// Usage: /tmp/slipcast-word-probe <audio-file> <start-seconds> <duration-seconds> <blocked-phrase>
// Exit status 1 means the expected phrase was not detected. Timestamps use the original file.
// Known regression: SmartLess, "RE-RELEASE: Bill Hader", published November 12, 2026.
// In the public RSS copy downloaded during investigation, the interruption overlaps Bill's
// "we were just like" at about 1532 seconds. The phone's download places it at 32:40–32:45.
// /tmp/slipcast-word-probe <episode.mp3> 1528 10 fucking  # currently fails
// /tmp/slipcast-word-probe <episode.mp3> 3399 12 fucking # clear-speech control passes
// Podcast ad insertion can shift these times; locate the dialogue again for another download.
@main
struct ProbeWordDetection {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5,
              let start = Double(arguments[2]), start.isFinite, start >= 0,
              let duration = Double(arguments[3]), duration.isFinite, duration > 0, duration <= 120,
              !MuteMatcher.tokenize(arguments[4]).isEmpty else {
            print("Usage: slipcast-word-probe <audio-file> <start-seconds> <duration-seconds (up to 120)> <blocked-phrase>")
            exit(2)
        }

        let source = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[1]))
        let format = source.processingFormat
        let fileDuration = Double(source.length) / format.sampleRate
        guard start < fileDuration else {
            print("Start time is past the end of the audio file.")
            exit(2)
        }
        let actualDuration = min(duration, fileDuration - start)
        source.framePosition = AVAudioFramePosition(start * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(actualDuration * format.sampleRate)
        ) else {
            print("Could not allocate the excerpt's audio buffer.")
            exit(2)
        }
        try source.read(into: buffer)

        let clip = FileManager.default.temporaryDirectory
            .appendingPathComponent("slipcast-probe-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: clip) }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let output = try AVAudioFile(forWriting: clip, settings: settings)
            try output.write(from: buffer)
        }

        let words = try await TranscriptionService.transcribe(
            fileURL: clip, locale: Locale(identifier: "en-US"), onUpdate: { _ in }
        )
        let matches = MuteMatcher.matchedWords(in: words, rules: [MuteRule(phrase: arguments[4])])
        let ranges = MuteMatcher.muteRanges(for: matches, in: words, padding: 0)
        print("Excerpt: \(start)...\(start + actualDuration) seconds")
        print("Transcript: \(words.map(\.text).joined(separator: " "))")
        guard !ranges.isEmpty else {
            print("FAIL: expected blocked phrase was not detected.")
            exit(1)
        }
        for range in ranges {
            print("Detected at \(start + range.lowerBound)...\(start + range.upperBound) seconds")
        }
        print("PASS: expected blocked phrase was detected.")
    }
}
