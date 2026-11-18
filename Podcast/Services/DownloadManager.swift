import Foundation
import AudioDetection
import Observation
import SwiftData
import os

/// Downloads episodes with a background URLSession, so transfers continue while the app is
/// suspended. When a download finishes, the episode is queued for transcription.
@Observable
final class DownloadManager: NSObject {
    static let sessionIdentifier = "com.tinyking.slipcast.downloads"

    /// episodeID -> 0...1
    private(set) var progress: [String: Double] = [:]

    /// Set by the app delegate when iOS relaunches the app to deliver background session events.
    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let processing: ProcessingQueue
    @ObservationIgnored private var session: URLSession!
    /// The last fraction sent to the main actor for each transfer, so progress callbacks (which
    /// can arrive hundreds of times a second) only hop over when the bar would visibly move.
    private nonisolated let reportedProgress = OSAllocatedUnfairLock(initialState: [String: Double]())

    init(context: ModelContext, processing: ProcessingQueue) {
        self.context = context
        self.processing = processing
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// - Parameter userInitiated: user taps always download; automatic downloads respect Wi-Fi only.
    func download(_ episode: Episode, userInitiated: Bool) {
        guard [.notDownloaded, .failed].contains(episode.downloadState),
              let url = URL(string: episode.audioURL)
        else { return }

        let restricted = !userInitiated && AppSettings.wifiOnly
        let task: URLSessionDownloadTask
        // A failed transfer picks up where it stopped. Resume data carries the original request's
        // network rules, so a Wi-Fi-only attempt isn't resumed when the user asks for it now.
        if let resume = ResumeDataStore.take(episodeID: episode.episodeID),
           !(resume.restricted && !restricted) {
            task = session.downloadTask(withResumeData: resume.data)
        } else {
            var request = URLRequest(url: url)
            if restricted {
                request.allowsExpensiveNetworkAccess = false
                request.allowsConstrainedNetworkAccess = false
            }
            task = session.downloadTask(with: request)
        }
        task.taskDescription = episode.episodeID
        if !userInitiated { NewEpisodeNotifier.markAutomatic(episode.episodeID) }
        episode.downloadState = .queued
        try? context.save()
        task.resume()
    }

    func cancel(_ episode: Episode) {
        let id = episode.episodeID
        NewEpisodeNotifier.forget(id)
        ResumeDataStore.remove(episodeID: id)
        episode.downloadState = .notDownloaded
        progress[id] = nil
        try? context.save()
        Task {
            for task in await session.allTasks where task.taskDescription == id {
                task.cancel()
            }
        }
    }

    /// Removes the audio and transcript. The episode can be downloaded again later.
    func deleteDownload(_ episode: Episode) {
        processing.cancel(episode.episodeID)
        if episode.downloadState == .queued || episode.downloadState == .downloading {
            cancel(episode)
        }
        if let url = episode.localFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        ResumeDataStore.remove(episodeID: episode.episodeID)
        TranscriptStore.delete(episodeID: episode.episodeID)
        PublisherTranscript.delete(episodeID: episode.episodeID)
        Chapters.delete(episodeID: episode.episodeID)
        try? ReviewedMuteStore().remove(episodeID: episode.episodeID)
        try? OverlapScanStore().remove(episodeID: episode.episodeID)
        CrosstalkFilter.remove(episodeID: episode.episodeID)
        episode.fileName = nil
        episode.downloadedAt = nil
        episode.downloadState = .notDownloaded
        episode.processingState = .none
        episode.processingError = nil
        episode.queueOrder = nil  // a later download goes to the top of the list
        try? context.save()
    }

    /// Fix up episodes that think they're downloading but whose task no longer exists.
    func reconcile() async {
        let activeIDs = Set(await session.allTasks.compactMap(\.taskDescription))
        let queued = DownloadState.queued.rawValue
        let downloading = DownloadState.downloading.rawValue
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.downloadStateRaw == queued || $0.downloadStateRaw == downloading }
        )
        for episode in (try? context.fetch(descriptor)) ?? [] where !activeIDs.contains(episode.episodeID) {
            episode.downloadState = .failed
        }
        try? context.save()
    }

    // MARK: - Main-actor state updates

    private func updateProgress(_ id: String, _ fraction: Double) {
        let isFirstUpdate = progress[id] == nil
        progress[id] = fraction
        // Only the first bytes move it from queued to downloading; skip the fetch after that.
        guard isFirstUpdate else { return }
        if let episode = context.episode(withID: id), episode.downloadState == .queued {
            episode.downloadState = .downloading
        }
    }

    private func finish(_ id: String, fileName: String) {
        progress[id] = nil
        // Gone, or the user cancelled (or deleted it) just as the transfer finished.
        guard let episode = context.episode(withID: id), episode.downloadState != .notDownloaded else {
            try? FileManager.default.removeItem(at: Storage.episodesDirectory.appending(path: fileName))
            return
        }
        episode.fileName = fileName
        episode.downloadedAt = .now
        episode.downloadState = .downloaded
        try? context.save()
        ResumeDataStore.remove(episodeID: id)
        processing.enqueue(episode)
        NewEpisodeNotifier.downloaded(episode)
        prefetchPublisherTranscript(episode)
        if let url = episode.chaptersURL {
            Task { _ = try? await Chapters.published(episodeID: id, url: url) }
        }
    }

    /// Fetches the feed's transcript with the audio, so it can be read offline too.
    private func prefetchPublisherTranscript(_ episode: Episode) {
        guard !episode.requiresFiltering, let url = episode.transcriptURL else { return }
        let id = episode.episodeID, type = episode.transcriptType
        Task { _ = try? await PublisherTranscript.words(episodeID: id, url: url, type: type) }
    }

    private func fail(_ id: String) {
        progress[id] = nil
        NewEpisodeNotifier.forget(id)
        guard let episode = context.episode(withID: id) else { return }
        if episode.downloadState != .notDownloaded {  // not a user cancel
            episode.downloadState = .failed
        }
        try? context.save()
    }

    private func finishBackgroundEvents() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }

    nonisolated static func fileExtension(for response: URLResponse?, url: URL?) -> String {
        switch response?.mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac": return "m4a"
        case "audio/wav", "audio/x-wav": return "wav"
        default: break
        }
        let ext = url?.pathExtension.lowercased() ?? ""
        return ["mp3", "m4a", "mp4", "aac", "wav"].contains(ext) ? ext : "mp3"
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Task { @MainActor in self.fail(id) }
            return
        }
        // The temp file is deleted when this method returns, so move it synchronously.
        let ext = Self.fileExtension(
            for: downloadTask.response,
            url: downloadTask.currentRequest?.url ?? downloadTask.originalRequest?.url
        )
        let fileName = "\(id).\(ext)"
        let destination = Storage.episodesDirectory.appending(path: fileName)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in self.finish(id, fileName: fileName) }
        } catch {
            Task { @MainActor in self.fail(id) }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let shouldReport = reportedProgress.withLock { reported in
            guard let last = reported[id], fraction - last < 0.005, fraction < 1 else {
                reported[id] = fraction
                return true
            }
            return false
        }
        guard shouldReport else { return }
        Task { @MainActor in self.updateProgress(id, fraction) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let id = task.taskDescription { _ = reportedProgress.withLock { $0.removeValue(forKey: id) } }
        guard let error = error as NSError?, let id = task.taskDescription else { return }
        // Keep what arrived so a retry continues instead of starting over. User cancels don't
        // produce resume data, and their state is already `.notDownloaded`.
        if error.code != NSURLErrorCancelled,
           let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            let restricted = task.originalRequest?.allowsExpensiveNetworkAccess == false
            ResumeDataStore.save(data, restricted: restricted, episodeID: id)
        }
        Task { @MainActor in self.fail(id) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.finishBackgroundEvents() }
    }
}

/// Resume data from failed downloads, one file per episode. A `.wifi` marker in the name records
/// that the original request was limited to Wi-Fi.
nonisolated enum ResumeDataStore {
    private static func url(for episodeID: String, restricted: Bool) -> URL {
        Storage.resumeDataDirectory.appending(path: restricted ? "\(episodeID).wifi" : episodeID)
    }

    static func save(_ data: Data, restricted: Bool, episodeID: String) {
        remove(episodeID: episodeID)
        try? data.write(to: url(for: episodeID, restricted: restricted), options: .atomic)
    }

    /// Returns and removes the saved resume data, so a bad checkpoint is only tried once.
    static func take(episodeID: String) -> (data: Data, restricted: Bool)? {
        for restricted in [false, true] {
            let file = url(for: episodeID, restricted: restricted)
            if let data = try? Data(contentsOf: file) {
                try? FileManager.default.removeItem(at: file)
                return (data, restricted)
            }
        }
        return nil
    }

    static func remove(episodeID: String) {
        for restricted in [false, true] {
            try? FileManager.default.removeItem(at: url(for: episodeID, restricted: restricted))
        }
    }
}
