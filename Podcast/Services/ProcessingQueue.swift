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
/// Episodes of filtered shows come first: they can't play until they're done. Episodes of other
/// shows get a transcript too, just for reading along, unless the feed provides one. That
/// transcript is the same file filtering uses, so turning filtering on later reuses it.
///
/// While an episode is being transcribed, its words are published live (`liveWords`) so the
/// player can start before the whole episode is done.
@Observable
final class ProcessingQueue {
    /// episodeID -> 0...1
    private(set) var isPaused = UserDefaults.standard.bool(forKey: AppSettings.processingPausedKey)
    private(set) var progress: [String: Double] = [:] {
        didSet { reportContinuedProgress() }
    }
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

    /// The active run only makes a read-along transcript (an unfiltered episode).
    @ObservationIgnored private(set) var activeIsReadAlong = false
    /// Seconds of the active read-along episode that are transcribed and final.
    @ObservationIgnored private(set) var liveTranscribedThrough: Double = 0
    /// Read-along transcript to make next (the episode being played).
    @ObservationIgnored private var preferredReadAlongID: String?
    /// Read-along runs that failed this launch; not retried until the app restarts.
    @ObservationIgnored private var readAlongFailures: Set<String> = []
    /// Episodes whose feed transcript couldn't be loaded, so they get one made on the device.
    @ObservationIgnored private var publisherTranscriptFailed: Set<String> = []

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var transcription: Task<[TranscriptWord], Error>?
    @ObservationIgnored private var priorityID: String?
    @ObservationIgnored private var backgroundTime: UIBackgroundTaskIdentifier = .invalid
    /// Keeps a run the user started in the app going after they leave it, with system progress UI.
    @ObservationIgnored private var continuedTask: BGContinuedProcessingTask?
    @ObservationIgnored private var continuedRequested = false
    @ObservationIgnored private var processingTask: BGProcessingTask?
    /// How far the active episode's speech pass is final, for saving a resumable checkpoint.
    @ObservationIgnored private var speechCheckpoint: (through: Double, duration: Double)?
    @ObservationIgnored private var lastCheckpointSave = Date.distantPast

    init(context: ModelContext) {
        self.context = context
    }

    private func mutedTermTexts() -> [String] {
        ((try? context.fetch(FetchDescriptor<MutedTerm>())) ?? []).map(\.text)
    }

    private func hasCurrentAudioScan(_ episode: Episode) -> Bool {
        guard let url = episode.localFileURL else { return false }
        return (try? OverlapScanStore().load(episodeID: episode.episodeID, fileURL: url))?.isComplete == true
    }

    var hasPendingWork: Bool {
        if activeEpisodeID != nil { return true }
        let pending = ProcessingState.pending.rawValue
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.processingStateRaw == pending })
        if ((try? context.fetch(descriptor)) ?? []).contains(where: { $0.requiresFiltering }) { return true }
        return nextReadAlongEpisode() != nil
    }

    func enqueue(_ episode: Episode, prioritize: Bool = false) {
        guard episode.downloadState == .downloaded else { return }
        guard episode.requiresFiltering else {
            episode.processingState = .none
            episode.processingError = nil
            try? context.save()
            if needsReadAlong(episode) {
                start()
                if UIApplication.shared.applicationState != .active { BackgroundWork.scheduleProcessing() }
            }
            return
        }
        if episode.processingState != .processing {
            episode.processingState = .pending
            episode.processingError = nil
        }
        if prioritize || episode.episodeID == preferredEpisodeID { priorityID = episode.episodeID }
        try? context.save()
        // Filtered episodes can't play until they're done, so they go ahead of a read-along run.
        // That run keeps what it has finished and picks up from there later.
        if activeIsReadAlong { transcription?.cancel() }
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

    // MARK: Read-along transcripts

    /// An unfiltered episode that should get a transcript made on the device.
    func needsReadAlong(_ episode: Episode) -> Bool {
        let id = episode.episodeID
        return DeviceSupport.transcriptionAvailable
            && episode.downloadState == .downloaded && !episode.requiresFiltering && episode.localFileURL != nil
            && (episode.transcriptURL == nil || publisherTranscriptFailed.contains(id))
            && !readAlongFailures.contains(id)
            && !TranscriptStore.isCurrent(episodeID: id)
    }

    func readAlongFailed(_ episodeID: String) -> Bool {
        readAlongFailures.contains(episodeID)
    }

    /// The player is showing this unfiltered episode: make its transcript next.
    func preferReadAlong(_ episode: Episode) {
        preferredReadAlongID = episode.episodeID
        guard needsReadAlong(episode) else { return }
        if activeIsReadAlong, activeEpisodeID != episode.episodeID { transcription?.cancel() }
        start()
    }

    /// The feed's transcript couldn't be loaded; make one on the device instead.
    func publisherTranscriptUnavailable(for episode: Episode) {
        publisherTranscriptFailed.insert(episode.episodeID)
        preferReadAlong(episode)
    }

    private func nextReadAlongEpisode() -> Episode? {
        guard DeviceSupport.transcriptionAvailable else { return nil }
        let downloaded = DownloadState.downloaded.rawValue
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.downloadStateRaw == downloaded },
            sortBy: [SortDescriptor(\.downloadedAt, order: .reverse)]  // newest are likeliest to be played
        )
        let episodes = (try? context.fetch(descriptor)) ?? []
        if let id = preferredReadAlongID, let preferred = episodes.first(where: { $0.episodeID == id }),
           needsReadAlong(preferred) {
            return preferred
        }
        return episodes.first(where: needsReadAlong)
    }

    /// Makes a transcript for reading along. The episode's processing state isn't touched: it
    /// stays playable throughout.
    private func transcribeForReading(_ episode: Episode, fileURL: URL) async {
        let id = episode.episodeID
        let locale = episode.show?.transcriptionLocale ?? .current
        let resume = Self.audioDuration(of: fileURL).flatMap {
            TranscriptStore.loadPartial(episodeID: id, locale: locale, duration: $0)
        }
        activeEpisodeID = id
        activeIsReadAlong = true
        liveWords = resume?.words ?? []
        liveTranscribedThrough = resume?.through ?? 0
        speechCheckpoint = resume.map { ($0.through, $0.duration) }
        lastCheckpointSave = Date()

        let (updates, continuation) = AsyncStream<TranscriptionUpdate>.makeStream()
        let consumer = Task {
            for await update in updates where activeEpisodeID == id {
                liveWords.append(contentsOf: update.words)
                liveTranscribedThrough = update.scannedThrough
                if update.totalDuration > 0 {
                    speechCheckpoint = (update.scannedThrough, update.totalDuration)
                    if Date().timeIntervalSince(lastCheckpointSave) > 15 {
                        saveSpeechCheckpoint(episodeID: id, locale: locale)
                    }
                }
                onLiveUpdate?(id)
            }
        }
        let task = Task {
            defer { continuation.finish() }
            let rest = try await TranscriptionService.transcribe(
                fileURL: fileURL, locale: locale, startingAt: resume?.through ?? 0
            ) { update in
                continuation.yield(update)
            }
            return (resume?.words ?? []) + rest
        }
        transcription = task

        do {
            let words = try await task.value
            await consumer.value
            try Task.checkCancellation()
            guard !task.isCancelled, let current = context.episode(withID: id),
                  current.downloadState == .downloaded, let url = current.localFileURL,
                  FileManager.default.fileExists(atPath: url.path) else { throw CancellationError() }
            try TranscriptStore.save(words, episodeID: id, engine: TranscriptStore.engineIdentifier)
            TranscriptStore.deletePartial(episodeID: id)
        } catch {
            await consumer.value
            if task.isCancelled || error is CancellationError {
                // Cancelled to make way for other work: resume from here later.
                if context.episode(withID: id)?.downloadState == .downloaded {
                    saveSpeechCheckpoint(episodeID: id, locale: locale)
                }
            } else {
                readAlongFailures.insert(id)
            }
        }
        // The download was removed while transcribing.
        if context.episode(withID: id)?.downloadState != .downloaded {
            TranscriptStore.delete(episodeID: id)
        }

        transcription = nil
        activeEpisodeID = nil
        activeIsReadAlong = false
        liveWords = []
        liveTranscribedThrough = 0
        speechCheckpoint = nil
        onFinished?(id)
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
            CrosstalkFilter.remove(episodeID: episode.episodeID)
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
        if let runner {
            // A cancelled run (e.g. iOS ended our background time) may still be unwinding.
            // Don't hand that back as if it were working: start again once it finishes.
            if runner.isCancelled { restartRequested = true }
            return runner
        }
        let task = Task {
            await drain()
            runner = nil
            if restartRequested && !isPaused {
                restartRequested = false
                start()
            } else {
                finishContinuedTask()
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
        processingTask = bgTask
        bgTask.expirationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.stop() }
        }
        let runner = start()
        Task {
            await runner.value
            if self.processingTask === box.value { self.processingTask = nil }
            box.value.setTaskCompleted(success: !self.hasPendingWork)
            if self.hasPendingWork { BackgroundWork.scheduleProcessing() }
        }
    }

    // MARK: Continued processing (iOS 26)

    /// Asks iOS to let this run continue if the user leaves the app. Only allowed while the app
    /// is in the foreground, i.e. in response to something the user did.
    private func requestContinuedProcessing(for episode: Episode) {
        if let continuedTask {
            continuedTask.updateTitle(Self.continuedTitle, subtitle: episode.title)
            return
        }
        guard !continuedRequested, UIApplication.shared.applicationState == .active else { return }
        continuedRequested = BackgroundWork.submitContinuedProcessing(title: Self.continuedTitle, subtitle: episode.title)
    }

    private static let continuedTitle = "Preparing muted words"

    /// Called from the BGContinuedProcessingTask launch handler.
    func attach(_ task: BGContinuedProcessingTask) {
        continuedRequested = false
        guard runner != nil, !isPaused, continuedTask == nil else {
            task.setTaskCompleted(success: true)
            return
        }
        continuedTask = task
        task.progress.totalUnitCount = 1000
        reportContinuedProgress()
        task.expirationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.continuedTaskExpired() }
        }
    }

    /// iOS reclaimed the task, or the user cancelled it from the system progress UI.
    private func continuedTaskExpired() {
        guard let task = continuedTask else { return }
        continuedTask = nil
        task.setTaskCompleted(success: false)
        // In the foreground the work can carry on; in the background it's about to be suspended.
        if UIApplication.shared.applicationState != .active {
            stop()
            BackgroundWork.scheduleProcessing()
        }
    }

    private func finishContinuedTask() {
        continuedRequested = false
        guard let task = continuedTask else { return }
        continuedTask = nil
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.setTaskCompleted(success: !hasPendingWork)
    }

    private func reportContinuedProgress() {
        guard let task = continuedTask, let id = activeEpisodeID, let fraction = progress[id] else { return }
        task.progress.completedUnitCount = Int64((min(1, max(0, fraction)) * 1000).rounded())
    }

    // MARK: Speech checkpoints

    private func saveSpeechCheckpoint(episodeID id: String, locale: Locale) {
        guard activeEpisodeID == id, let checkpoint = speechCheckpoint, checkpoint.through > 0,
              !TranscriptStore.isCurrent(episodeID: id) else { return }
        let partial = TranscriptStore.Partial(engine: TranscriptStore.engineIdentifier, locale: locale.identifier,
                                              duration: checkpoint.duration, through: checkpoint.through, words: liveWords)
        try? TranscriptStore.savePartial(partial, episodeID: id)
        lastCheckpointSave = Date()
    }

    private static func audioDuration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func drain() async {
        beginBackgroundTime()
        defer { endBackgroundTime() }
        while !Task.isCancelled {
            guard let episode = nextEpisode() else {
                guard let readAlong = nextReadAlongEpisode(), let url = readAlong.localFileURL else { break }
                await transcribeForReading(readAlong, fileURL: url)
                continue
            }
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

        let locale = episode.show?.transcriptionLocale ?? .current
        // Pick up an interrupted speech pass where it stopped instead of starting over.
        let resume: TranscriptStore.Partial? = if !TranscriptStore.isCurrent(episodeID: id),
            let duration = Self.audioDuration(of: fileURL) {
            TranscriptStore.loadPartial(episodeID: id, locale: locale, duration: duration)
        } else {
            nil
        }

        episode.processingState = .processing
        activeEpisodeID = id
        liveWords = resume?.words ?? []
        liveAudioScan = nil
        liveScannedThrough = 0
        speechCheckpoint = resume.map { ($0.through, $0.duration) }
        lastCheckpointSave = Date()
        progress[id] = resume.map { 0.25 * $0.through / $0.duration } ?? 0
        phaseLabel[id] = resume == nil ? "Transcribing…" : "Resuming transcription…"
        try? context.save()
        requestContinuedProcessing(for: episode)

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
                        speechCheckpoint = (update.scannedThrough, update.totalDuration)
                        if Date().timeIntervalSince(lastCheckpointSave) > 15 {
                            saveSpeechCheckpoint(episodeID: id, locale: locale)
                        }
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

        let engine = TranscriptStore.engineIdentifier
        let task = Task {
            defer { continuation.finish() }
            let words: [TranscriptWord]
            if TranscriptStore.isCurrent(episodeID: id), let cached = try? TranscriptStore.load(episodeID: id) {
                words = cached
            } else {
                let rest = try await TranscriptionService.transcribe(
                    fileURL: fileURL, locale: locale, startingAt: resume?.through ?? 0
                ) { update in
                    continuation.yield(.speech(update))
                }
                words = (resume?.words ?? []) + rest
            }
            try Task.checkCancellation()
            guard let current = context.episode(withID: id), current.requiresFiltering, current.downloadState == .downloaded,
                  let fileURL = current.localFileURL,
                  FileManager.default.fileExists(atPath: fileURL.path) else { throw CancellationError() }
            // Keep the completed transcript when iOS interrupts the slower acoustic pass.
            try TranscriptStore.save(words, episodeID: id, engine: engine)
            TranscriptStore.deletePartial(episodeID: id)
            continuation.yield(.transcriptReady(words))
            let scan = try await OverlapDetector.shared.scan(fileURL: fileURL, episodeID: id,
                onActivity: { continuation.yield(.activity($0)) },
                onUpdate: { continuation.yield(.audio($0)) })
            // Usually a few seconds. The player redoes this if the mute list changes later.
            let keywords = CrosstalkFilter.keywords(for: mutedTermTexts())
            if !keywords.isEmpty {
                continuation.yield(.activity(.init(fraction: 1, message: "Listening for muted words in crosstalk…")))
                _ = try await CrosstalkFilter.check(fileURL: fileURL, episodeID: id, scan: scan, keywords: keywords)
            }
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
                    CrosstalkFilter.remove(episodeID: id)
                    current.processingState = .none
                } else if !current.requiresFiltering {
                    // Keep reusable progress when filtering is switched off; it is never applied
                    // to original-audio playback and can resume if filtering is enabled again.
                    current.processingState = .none
                } else if task.isCancelled || error is CancellationError {
                    current.processingState = .pending  // resume later
                    saveSpeechCheckpoint(episodeID: id, locale: locale)
                } else {
                    current.processingState = .failed
                    current.processingError = error.localizedDescription
                }
            } else {
                // Unsubscribing can delete the SwiftData model while inference is suspended.
                // Never touch that invalidated instance or leave its scan files behind.
                TranscriptStore.delete(episodeID: id)
                try? OverlapScanStore().remove(episodeID: id)
                CrosstalkFilter.remove(episodeID: id)
            }
        }

        // A cancellation can race an atomic checkpoint write on the inference actor. Delete
        // again after that worker stops when the user explicitly requested a fresh scan.
        if resetAfterCancellation.remove(id) != nil {
            TranscriptStore.delete(episodeID: id)
            try? OverlapScanStore().remove(episodeID: id)
            CrosstalkFilter.remove(episodeID: id)
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
        speechCheckpoint = nil
    }

    // Gives the current transcription ~30s to finish if the user leaves the app mid-way.
    // (While audio is playing the app keeps running, so processing continues.)
    private func beginBackgroundTime() {
        guard backgroundTime == .invalid else { return }
        // Called on the main thread; must end the background task before returning, or iOS
        // suspends (or kills) the app part-way through cancelling.
        backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Transcription") { @Sendable [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A continued/processing task is still keeping the app running.
                if self.continuedTask == nil && self.processingTask == nil {
                    self.stop()
                    BackgroundWork.scheduleProcessing()
                }
                self.endBackgroundTime()
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
