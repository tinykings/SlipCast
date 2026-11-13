import AudioDetection
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
    private(set) var isPaused = UserDefaults.standard.bool(forKey: AppSettings.processingPausedKey)
    private(set) var progress: [String: Double] = [:]
    private(set) var activeEpisodeID: String?
    private(set) var phaseLabel: [String: String] = [:]
    @ObservationIgnored private(set) var liveAudioScan: OverlapScan?
    @ObservationIgnored private var resetAfterCancellation: Set<String> = []
    @ObservationIgnored private var restartRequested = false

    /// Words found so far for `activeEpisodeID`, in order. Not observed (it changes constantly);
    /// the player listens via `onLiveUpdate` instead.
    @ObservationIgnored private(set) var liveWords: [TranscriptWord] = []
    /// Seconds into `activeEpisodeID` that are final.
    @ObservationIgnored private(set) var liveScannedThrough: Double = 0
    @ObservationIgnored var onLiveUpdate: ((String) -> Void)?
    /// Called when an episode's run ends. Check the episode's `processingState` for the outcome.
    @ObservationIgnored var onFinished: ((String) -> Void)?
    /// Waiting to play as soon as it's ready: processed first, including once its download finishes.
    @ObservationIgnored var preferredEpisodeID: String?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var transcription: Task<[TranscriptWord], Error>?
    @ObservationIgnored private var priorityID: String?
    @ObservationIgnored private var backgroundTime: UIBackgroundTaskIdentifier = .invalid

    init(context: ModelContext) {
        self.context = context
    }

    private func hasCurrentAudioScan(_ episode: Episode) -> Bool {
        guard let url = episode.localFileURL else { return false }
        return (try? OverlapScanStore().load(episodeID: episode.episodeID, fileURL: url))?.isComplete == true
    }

    var hasPendingWork: Bool {
        if activeEpisodeID != nil { return true }
        let pending = ProcessingState.pending.rawValue
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.processingStateRaw == pending })
        return ((try? context.fetch(descriptor)) ?? []).contains { $0.requiresFiltering }
    }

    func enqueue(_ episode: Episode, prioritize: Bool = false) {
        guard episode.downloadState == .downloaded else { return }
        guard episode.requiresFiltering else {
            episode.processingState = .none
            episode.processingError = nil
            try? context.save()
            return
        }
        if episode.processingState != .processing {
            episode.processingState = .pending
            episode.processingError = nil
        }
        if prioritize || episode.episodeID == preferredEpisodeID { priorityID = episode.episodeID }
        try? context.save()
        start()
        if UIApplication.shared.applicationState != .active {
            BackgroundWork.scheduleProcessing()
        }
    }

    /// The user wants to listen to this episode now: process it immediately, pausing whatever
    /// else is being processed (that episode goes back in the queue).
    func processNow(_ episode: Episode) {
        guard episode.requiresFiltering, episode.downloadState == .downloaded, episode.processingState != .ready else { return }
        guard activeEpisodeID != episode.episodeID else { return }
        enqueue(episode, prioritize: true)
        if activeEpisodeID != nil { transcription?.cancel() }
    }

    /// Stops work for an episode whose downloaded files are being removed.
    func cancel(_ episodeID: String) {
        if activeEpisodeID == episodeID { transcription?.cancel() }
        if priorityID == episodeID { priorityID = nil }
    }

    func filteringChanged(for show: Show) {
        if let id = activeEpisodeID, show.episodes.contains(where: { $0.episodeID == id }) {
            transcription?.cancel()
        }
        for episode in show.episodes where episode.downloadState == .downloaded {
            episode.processingState = show.filteringEnabled ? .pending : .none
            episode.processingError = nil
        }
        try? context.save()
        start()
    }

    /// An episode left in `.processing` means the app was killed mid-transcription.
    func resetInterrupted() {
        let descriptor = FetchDescriptor<Episode>()
        for episode in (try? context.fetch(descriptor)) ?? [] {
            guard episode.downloadState == .downloaded else { continue }
            guard episode.requiresFiltering else {
                episode.processingState = .none
                episode.processingError = nil
                continue
            }
            if episode.processingState == .processing ||
                (episode.processingState == .ready &&
                 (!TranscriptStore.isCurrent(episodeID: episode.episodeID) || !hasCurrentAudioScan(episode))) {
                episode.processingState = .pending
            }
        }
        try? context.save()
    }

    /// Re-scan the existing audio with Apple transcription; reviewed audio mutes are kept.
    func rescanDownloads(prioritize episodeID: String? = nil) {
        transcription?.cancel()
        if let activeEpisodeID { resetAfterCancellation.insert(activeEpisodeID) }
        priorityID = episodeID
        for episode in (try? context.fetch(FetchDescriptor<Episode>())) ?? [] {
            guard episode.downloadState == .downloaded, episode.requiresFiltering else { continue }
            TranscriptStore.delete(episodeID: episode.episodeID)
            try? OverlapScanStore().remove(episodeID: episode.episodeID)
            episode.processingState = .pending
            episode.processingError = nil
        }
        liveWords = []
        liveAudioScan = nil
        liveScannedThrough = 0
        try? context.save()
        start()
    }

    @discardableResult
    func start() -> Task<Void, Never> {
        guard !isPaused else { return Task {} }
        if let runner { return runner }
        let task = Task {
            await drain()
            runner = nil
            if restartRequested && !isPaused {
                restartRequested = false
                start()
            }
        }
        runner = task
        return task
    }

    func pauseProcessing() {
        isPaused = true
        UserDefaults.standard.set(true, forKey: AppSettings.processingPausedKey)
        stop()
    }

    func resumeProcessing() {
        isPaused = false
        UserDefaults.standard.set(false, forKey: AppSettings.processingPausedKey)
        restartRequested = runner != nil
        start()
    }

    func stop() {
        restartRequested = false
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
            guard let episode = nextEpisode() else { break }
            guard let url = episode.localFileURL else {
                episode.processingState = .failed
                episode.processingError = "Audio file is missing. Delete and re-download the episode."
                try? context.save()
                continue
            }
            await process(episode, fileURL: url)
        }
    }

    private func nextEpisode() -> Episode? {
        if let id = priorityID {
            priorityID = nil
            if let episode = context.episode(withID: id), episode.requiresFiltering, episode.processingState == .pending {
                return episode
            }
        }
        let pending = ProcessingState.pending.rawValue
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.processingStateRaw == pending },
            sortBy: [SortDescriptor(\.downloadedAt)]
        )
        return ((try? context.fetch(descriptor)) ?? []).first { $0.requiresFiltering }
    }

    private func process(_ episode: Episode, fileURL: URL) async {
        guard episode.requiresFiltering else { return }
        let id = episode.episodeID
        if !FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            episode.processingState = .failed
            episode.processingError = "Audio file is missing. Delete and re-download the episode."
            try? context.save()
            onFinished?(id)
            return
        }

        episode.processingState = .processing
        activeEpisodeID = id
        liveWords = []
        liveAudioScan = nil
        liveScannedThrough = 0
        progress[id] = 0
        phaseLabel[id] = "Transcribing…"
        try? context.save()

        // Both phases publish through one stream so mute ranges reach the player before the
        // corresponding scanned point advances. A downloaded file waits for acoustic coverage.
        let (updates, continuation) = AsyncStream<ProcessingUpdate>.makeStream()
        let consumer = Task {
            for await update in updates where activeEpisodeID == id {
                guard let current = context.episode(withID: id), current.processingState == .processing else { continue }
                switch update {
                case .speech(let update):
                    liveWords.append(contentsOf: update.words)
                    liveScannedThrough = 0
                    if update.totalDuration > 0 {
                        let fraction = min(1, update.scannedThrough / update.totalDuration)
                        progress[id] = 0.25 * fraction
                        phaseLabel[id] = String(format: "Transcribing %.0f%% · %@ of %@", fraction * 100,
                                                Format.clock(update.scannedThrough), Format.clock(update.totalDuration))
                    }
                case .transcriptReady(let words):
                    liveWords = words
                    liveScannedThrough = 0
                    phaseLabel[id] = "Finding overlapping voices…"
                    progress[id] = 0.25
                case .activity(let activity):
                    phaseLabel[id] = activity.message
                case .audio(let scan):
                    liveAudioScan = scan
                    liveScannedThrough = scan.scannedThrough
                    progress[id] = 0.25 + 0.75 * scan.fraction
                    phaseLabel[id] = String(format: "Finding overlapping voices %.1f%% · %@ of %@", scan.fraction * 100, Format.clock(scan.scannedThrough), Format.clock(scan.duration))
                }
                onLiveUpdate?(id)
            }
        }

        let locale = episode.show?.transcriptionLocale ?? .current
        let engine = TranscriptStore.engineIdentifier
        let task = Task {
            defer { continuation.finish() }
            let words: [TranscriptWord]
            if TranscriptStore.isCurrent(episodeID: id), let cached = try? TranscriptStore.load(episodeID: id) {
                words = cached
            } else {
                words = try await TranscriptionService.transcribe(fileURL: fileURL, locale: locale) { update in
                    continuation.yield(.speech(update))
                }
            }
            try Task.checkCancellation()
            guard let current = context.episode(withID: id), current.requiresFiltering, current.downloadState == .downloaded,
                  let fileURL = current.localFileURL,
                  FileManager.default.fileExists(atPath: fileURL.path) else { throw CancellationError() }
            // Keep the completed transcript when iOS interrupts the slower acoustic pass.
            try TranscriptStore.save(words, episodeID: id, engine: engine)
            continuation.yield(.transcriptReady(words))
            _ = try await OverlapDetector.shared.scan(fileURL: fileURL, episodeID: id,
                onActivity: { continuation.yield(.activity($0)) },
                onUpdate: { continuation.yield(.audio($0)) })
            return words
        }
        transcription = task

        do {
            _ = try await task.value
            await consumer.value
            try Task.checkCancellation()
            guard !task.isCancelled, let current = context.episode(withID: id),
                  current.requiresFiltering, current.downloadState == .downloaded else { throw CancellationError() }
            guard let fileURL = current.localFileURL,
                  (try OverlapScanStore().load(episodeID: id, fileURL: fileURL))?.isComplete == true else { throw CancellationError() }
            current.processingState = .ready
            current.processingError = nil
        } catch {
            await consumer.value
            if let current = context.episode(withID: id) {
                if current.downloadState != .downloaded {
                    try? OverlapScanStore().remove(episodeID: id)
                    current.processingState = .none
                } else if !current.requiresFiltering {
                    // Keep reusable progress when filtering is switched off; it is never applied
                    // to original-audio playback and can resume if filtering is enabled again.
                    current.processingState = .none
                } else if task.isCancelled || error is CancellationError {
                    current.processingState = .pending  // resume later
                } else {
                    current.processingState = .failed
                    current.processingError = error.localizedDescription
                }
            } else {
                // Unsubscribing can delete the SwiftData model while inference is suspended.
                // Never touch that invalidated instance or leave its scan files behind.
                TranscriptStore.delete(episodeID: id)
                try? OverlapScanStore().remove(episodeID: id)
            }
        }

        // A cancellation can race an atomic checkpoint write on the inference actor. Delete
        // again after that worker stops when the user explicitly requested a fresh scan.
        if resetAfterCancellation.remove(id) != nil {
            TranscriptStore.delete(episodeID: id)
            try? OverlapScanStore().remove(episodeID: id)
        }

        transcription = nil
        activeEpisodeID = nil
        progress[id] = nil
        phaseLabel[id] = nil
        try? context.save()
        onFinished?(id)
        liveAudioScan = nil
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

nonisolated private enum ProcessingUpdate: Sendable {
    case speech(TranscriptionUpdate)
    case transcriptReady([TranscriptWord])
    case activity(AudioDetectionProgress)
    case audio(OverlapScan)
}
