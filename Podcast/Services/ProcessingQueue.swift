import AVFoundation
import BackgroundTasks
import Foundation
import Observation
import SwiftData
import UIKit

/// Transcribes downloaded episodes one at a time. Runs in the foreground right after a download
/// finishes, and continues in a BGProcessingTask if the app is backgrounded.
///
/// While an episode is being transcribed, its words are published live (`liveWords`) so the
/// player can start before the whole episode is done.
@Observable
final class ProcessingQueue {
    /// episodeID -> 0...1
    private(set) var progress: [String: Double] = [:]
    private(set) var activeEpisodeID: String?

    /// Words found so far for `activeEpisodeID`, in order. Not observed (it changes constantly);
    /// the player listens via `onLiveUpdate` instead.
    @ObservationIgnored private(set) var liveWords: [TranscriptWord] = []
    /// Seconds into `activeEpisodeID` that are final.
    @ObservationIgnored private(set) var liveScannedThrough: Double = 0
    @ObservationIgnored var onLiveUpdate: ((String) -> Void)?
    /// Called when an episode's run ends. Check the episode's `processingState` for the outcome.
    @ObservationIgnored var onFinished: ((String) -> Void)?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var transcription: Task<[TranscriptWord], Error>?
    @ObservationIgnored private var priorityID: String?
    /// Transcription of an episode that's still downloading (see `transcribeWhileDownloading`).
    @ObservationIgnored private var streamingJob: Task<Void, Never>?
    @ObservationIgnored private var streamingEpisodeID: String?

    private enum Source {
        case file(URL)
        case stream(connect: @Sendable (AVAudioFormat) -> StreamingAudioInput, estimatedDuration: Double)
    }
    @ObservationIgnored private var backgroundTime: UIBackgroundTaskIdentifier = .invalid

    init(context: ModelContext) {
        self.context = context
    }

    var hasPendingWork: Bool {
        let pending = ProcessingState.pending.rawValue
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.processingStateRaw == pending })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    func enqueue(_ episode: Episode, prioritize: Bool = false) {
        guard episode.downloadState == .downloaded else { return }
        if episode.processingState != .processing {
            episode.processingState = .pending
            episode.processingError = nil
        }
        if prioritize { priorityID = episode.episodeID }
        try? context.save()
        start()
        if UIApplication.shared.applicationState != .active {
            BackgroundWork.scheduleProcessing()
        }
    }

    /// The user wants to listen to this episode now: process it immediately, pausing whatever
    /// else is being processed (that episode goes back in the queue).
    func processNow(_ episode: Episode) {
        guard episode.downloadState == .downloaded, episode.processingState != .ready else { return }
        guard activeEpisodeID != episode.episodeID else { return }
        enqueue(episode, prioritize: true)
        if activeEpisodeID != nil { transcription?.cancel() }
    }

    /// Transcribes an episode that's still downloading, ahead of everything else. If the format
    /// can't be decoded while downloading, the episode is left `.none` and gets a normal scan once
    /// the download completes.
    func transcribeWhileDownloading(
        _ episode: Episode,
        estimatedDuration: Double,
        connect: @escaping @Sendable (AVAudioFormat) -> StreamingAudioInput
    ) {
        let id = episode.episodeID
        // One streaming scan at a time; an interrupted one gets a normal scan after its download.
        if let other = streamingEpisodeID { cancelStreaming(other) }
        transcription?.cancel()  // pause any file scan; it resumes afterwards
        streamingEpisodeID = id
        streamingJob = Task {
            while activeEpisodeID != nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if !Task.isCancelled, let episode = context.episode(withID: id) {
                await process(episode, source: .stream(connect: connect, estimatedDuration: estimatedDuration))
            }
            if streamingEpisodeID == id {
                streamingJob = nil
                streamingEpisodeID = nil
            }
            start()
        }
    }

    /// Stops a while-downloading transcription (e.g. the download failed or was cancelled).
    func cancelStreaming(_ episodeID: String) {
        guard streamingEpisodeID == episodeID else { return }
        streamingJob?.cancel()
        if activeEpisodeID == episodeID { transcription?.cancel() }
    }

    /// An episode left in `.processing` means the app was killed mid-transcription.
    func resetInterrupted() {
        let processing = ProcessingState.processing.rawValue
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.processingStateRaw == processing })
        for episode in (try? context.fetch(descriptor)) ?? [] {
            episode.processingState = .pending
        }
        try? context.save()
    }

    @discardableResult
    func start() -> Task<Void, Never> {
        if let runner { return runner }
        let task = Task {
            await drain()
            runner = nil
        }
        runner = task
        return task
    }

    func stop() {
        runner?.cancel()
        transcription?.cancel()
    }

    /// Called from the BGProcessingTask handler.
    func run(in bgTask: BGProcessingTask) {
        let box = UncheckedBox(bgTask)
        bgTask.expirationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.stop() }
        }
        let runner = start()
        Task {
            await runner.value
            box.value.setTaskCompleted(success: !self.hasPendingWork)
            if self.hasPendingWork { BackgroundWork.scheduleProcessing() }
        }
    }

    private func drain() async {
        beginBackgroundTime()
        defer { endBackgroundTime() }
        while !Task.isCancelled {
            if let streamingJob {
                await streamingJob.value
                continue
            }
            guard let episode = nextEpisode() else { break }
            guard let url = episode.localFileURL else {
                episode.processingState = .failed
                episode.processingError = "Audio file is missing. Delete and re-download the episode."
                try? context.save()
                continue
            }
            await process(episode, source: .file(url))
        }
    }

    private func nextEpisode() -> Episode? {
        if let id = priorityID {
            priorityID = nil
            if let episode = context.episode(withID: id), episode.processingState == .pending {
                return episode
            }
        }
        let pending = ProcessingState.pending.rawValue
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.processingStateRaw == pending },
            sortBy: [SortDescriptor(\.downloadedAt)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func process(_ episode: Episode, source: Source) async {
        let id = episode.episodeID
        if case .file(let fileURL) = source,
           !FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            episode.processingState = .failed
            episode.processingError = "Audio file is missing. Delete and re-download the episode."
            try? context.save()
            onFinished?(id)
            return
        }

        episode.processingState = .processing
        activeEpisodeID = id
        liveWords = []
        liveScannedThrough = 0
        progress[id] = 0
        try? context.save()

        // Updates go through an AsyncStream so they reach the main actor in order.
        let (updates, continuation) = AsyncStream<TranscriptionUpdate>.makeStream()
        let consumer = Task {
            for await update in updates where activeEpisodeID == id {
                liveWords.append(contentsOf: update.words)
                liveScannedThrough = update.scannedThrough
                if update.totalDuration > 0 {
                    progress[id] = min(1, update.scannedThrough / update.totalDuration)
                }
                onLiveUpdate?(id)
            }
        }

        let locale = episode.show?.transcriptionLocale ?? .current
        let task = Task {
            defer { continuation.finish() }
            switch source {
            case .file(let fileURL):
                return try await TranscriptionService.transcribe(fileURL: fileURL, locale: locale) { update in
                    continuation.yield(update)
                }
            case .stream(let connect, let estimatedDuration):
                return try await TranscriptionService.transcribeStream(
                    locale: locale, estimatedDuration: estimatedDuration, connect: connect
                ) { update in
                    continuation.yield(update)
                }
            }
        }
        transcription = task

        do {
            let words = try await task.value
            await consumer.value
            try TranscriptStore.save(words, episodeID: id)
            episode.processingState = .ready
            episode.processingError = nil
        } catch {
            if episode.downloadState != .downloaded {
                // Streaming scan stopped early (cancelled, download failed, or a format that can't
                // be decoded mid-download). A normal scan runs once the download completes.
                episode.processingState = .none
            } else if task.isCancelled || error is CancellationError {
                episode.processingState = .pending  // resume later
            } else {
                episode.processingState = .failed
                episode.processingError = error.localizedDescription
            }
        }

        transcription = nil
        activeEpisodeID = nil
        progress[id] = nil
        try? context.save()
        onFinished?(id)
        liveWords = []
        liveScannedThrough = 0
    }

    // Gives the current transcription ~30s to finish if the user leaves the app mid-way.
    // (While audio is playing the app keeps running, so processing continues.)
    private func beginBackgroundTime() {
        guard backgroundTime == .invalid else { return }
        backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Transcription") { @Sendable [weak self] in
            Task { @MainActor in
                self?.stop()
                self?.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTime)
        backgroundTime = .invalid
    }
}

nonisolated struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
