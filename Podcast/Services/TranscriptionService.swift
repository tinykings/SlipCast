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
    /// Transcribes a complete file on disk.
    @concurrent
    static func transcribe(
        fileURL: URL,
        locale: Locale,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws -> [TranscriptWord] {
        let transcriber = try await makeTranscriber(locale: locale)
        let audioFile = try AVAudioFile(forReading: fileURL)
        let totalSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        return try await run(transcriber, totalSeconds: totalSeconds, onUpdate: onUpdate) { analyzer in
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        }
    }

    /// Transcribes an episode while it downloads. `connect` receives the analyzer's preferred
    /// audio format and returns the audio to analyze.
    @concurrent
    static func transcribeStream(
        locale: Locale,
        estimatedDuration: Double,
        connect: @escaping @Sendable (AVAudioFormat) -> StreamingAudioInput,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws -> [TranscriptWord] {
        let transcriber = try await makeTranscriber(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.unavailable
        }
        let input = connect(format)
        return try await run(transcriber, totalSeconds: estimatedDuration, onUpdate: onUpdate) { analyzer in
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
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void,
        analyze: (SpeechAnalyzer) async throws -> Void
    ) async throws -> [TranscriptWord] {
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task {
            var words: [TranscriptWord] = []
            for try await result in transcriber.results {
                let newWords = Self.words(from: result.text)
                words.append(contentsOf: newWords)
                var scannedThrough = result.range.end.seconds
                let finalized = result.resultsFinalizationTime
                if finalized.isValid, finalized.seconds.isFinite {
                    scannedThrough = max(scannedThrough, finalized.seconds)
                }
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
