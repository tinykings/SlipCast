import AVFoundation
import CoreMedia
import Foundation
import Speech

nonisolated enum TranscriptionError: LocalizedError {
    case unsupportedLanguage(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let id): "On-device transcription doesn't support \(id) yet."
        case .unavailable: "On-device transcription isn't available on this device."
        }
    }
}

/// Words recognized since the last update, and how far into the episode results are final.
nonisolated struct TranscriptionUpdate: Sendable {
    let words: [TranscriptWord]
    /// Everything before this time (seconds) has been transcribed and won't change.
    let scannedThrough: Double
    let totalDuration: Double
}

/// Transcribes a downloaded episode on-device with word-level timestamps using SpeechAnalyzer.
/// Results arrive in order while analysis runs, so playback can start before it finishes.
nonisolated enum TranscriptionService {
    /// Transcribes a complete file on disk, or the rest of it from `startingAt` seconds (to resume
    /// an interrupted run). Returned and reported word times are always relative to the file start.
    @concurrent
    static func transcribe(
        fileURL: URL,
        locale: Locale,
        startingAt start: Double = 0,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws -> [TranscriptWord] {
        let transcriber = try await makeTranscriber(locale: locale)
        let audioFile = try AVAudioFile(forReading: fileURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        let totalSeconds = Double(audioFile.length) / sampleRate
        let startFrame = AVAudioFramePosition(max(0, start) * sampleRate)
        guard startFrame > 0, startFrame < audioFile.length else {
            return try await run(transcriber, totalSeconds: totalSeconds, onUpdate: onUpdate) { analyzer in
                if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            }
        }

        let offset = Double(startFrame) / sampleRate
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: audioFile.processingFormat) else {
            throw TranscriptionError.unavailable
        }
        let input = try FileAnalyzerInput(file: audioFile, startFrame: startFrame, format: format)
        return try await run(transcriber, totalSeconds: totalSeconds, offset: offset, onUpdate: onUpdate) { analyzer in
            if let lastSample = try await analyzer.analyzeSequence(input) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        }
    }

    private static func makeTranscriber(locale: Locale) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLanguage(locale.identifier)
        }

        // No `.etiquetteReplacements`: we need the real words to match against, not "****".
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // First run for a language downloads the speech model (handled by the system).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    /// Runs the analyzer, reporting final results in order as they arrive.
    private static func run(
        _ transcriber: SpeechTranscriber,
        totalSeconds: Double,
        offset: Double = 0,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void,
        analyze: (SpeechAnalyzer) async throws -> Void
    ) async throws -> [TranscriptWord] {
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task {
            var words: [TranscriptWord] = []
            for try await result in transcriber.results {
                var newWords = Self.words(from: result.text)
                if offset > 0 {
                    for index in newWords.indices {
                        newWords[index].start += offset
                        newWords[index].end += offset
                    }
                }
                words.append(contentsOf: newWords)
                var scannedThrough = result.range.end.seconds
                let finalized = result.resultsFinalizationTime
                if finalized.isValid, finalized.seconds.isFinite {
                    scannedThrough = max(scannedThrough, finalized.seconds)
                }
                scannedThrough += offset
                onUpdate(TranscriptionUpdate(
                    words: newWords, scannedThrough: scannedThrough, totalDuration: totalSeconds))
            }
            return words
        }

        do {
            try await withTaskCancellationHandler {
                try await analyze(analyzer)
            } onCancel: {
                collector.cancel()
            }
            try Task.checkCancellation()
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }

        return try await collector.value
    }

    /// Splits a result's attributed text into words. Each run carries an audio time range; when a
    /// run holds several words, its time is divided proportionally by character count.
    static func words(from text: AttributedString) -> [TranscriptWord] {
        var output: [TranscriptWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let runText = String(text[run.range].characters)
            let parts = runText.split(whereSeparator: \.isWhitespace)
            guard !parts.isEmpty else { continue }

            let start = range.start.seconds
            let end = range.end.seconds
            guard start.isFinite, end.isFinite else { continue }

            let totalChars = max(1, parts.reduce(0) { $0 + $1.count })
            var cursor = start
            for part in parts {
                let length = (end - start) * Double(part.count) / Double(totalChars)
                output.append(TranscriptWord(text: String(part), start: cursor, end: cursor + length))
                cursor += length
            }
        }
        return output
    }
}

/// Reads an audio file from a given frame, converted to the analyzer's format. Used to resume
/// transcription part-way through a file (`analyzeSequence(from:)` always starts at the top).
/// Buffers carry no start time, so analyzer times are relative to `startFrame`.
nonisolated private final class FileAnalyzerInput: AsyncSequence, AsyncIteratorProtocol, @unchecked Sendable {
    typealias Element = AnalyzerInput

    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private let chunk: AVAudioFrameCount

    init(file: AVAudioFile, startFrame: AVAudioFramePosition, format: AVAudioFormat) throws {
        self.file = file
        self.format = format
        file.framePosition = startFrame
        converter = file.processingFormat == format ? nil : AVAudioConverter(from: file.processingFormat, to: format)
        if file.processingFormat != format, converter == nil { throw TranscriptionError.unavailable }
        chunk = AVAudioFrameCount(file.processingFormat.sampleRate)  // 1 s per buffer
    }

    func makeAsyncIterator() -> FileAnalyzerInput { self }

    func next() async throws -> AnalyzerInput? {
        try Task.checkCancellation()
        guard file.framePosition < file.length,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return nil }
        try file.read(into: source, frameCount: chunk)
        guard source.frameLength > 0 else { return nil }
        guard let converter else { return AnalyzerInput(buffer: source) }

        let ratio = format.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(source.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        return AnalyzerInput(buffer: output)
    }
}
