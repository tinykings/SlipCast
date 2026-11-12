import Foundation
import Observation
import SwiftData

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
    /// Episodes downloading while being played (foreground, see `StreamingSession`).
    @ObservationIgnored private var streams: [String: StreamingSession] = [:]

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

        var request = URLRequest(url: url)
        if !userInitiated && AppSettings.wifiOnly {
            request.allowsExpensiveNetworkAccess = false
            request.allowsConstrainedNetworkAccess = false
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = episode.episodeID
        episode.downloadState = .queued
        try? context.save()
        task.resume()
    }

    /// Starts (or returns) a download that can be played and transcribed while it arrives.
    /// Replaces any background download of the same episode.
    func stream(_ episode: Episode) -> StreamingSession? {
        let id = episode.episodeID
        if let existing = streams[id] { return existing }
        guard episode.downloadState != .downloaded, let url = URL(string: episode.audioURL) else { return nil }

        if episode.downloadState == .queued || episode.downloadState == .downloading {
            Task {
                for task in await session.allTasks where task.taskDescription == id { task.cancel() }
            }
        }

        let stream = StreamingSession(episodeID: id, remoteURL: url)
        stream.onProgress = { [weak self] fraction in
            Task { @MainActor in self?.updateProgress(id, fraction) }
        }
        stream.onComplete = { [weak self] ext in
            Task { @MainActor in self?.finishStreaming(id, fileExtension: ext) }
        }
        stream.onFail = { [weak self] in
            Task { @MainActor in self?.failStreaming(id) }
        }
        streams[id] = stream
        episode.downloadState = .downloading
        episode.processingState = .none
        try? context.save()
        stream.start()

        processing.transcribeWhileDownloading(episode, estimatedDuration: episode.duration ?? 0) { format in
            stream.makeAnalyzerInput(format: format)
        }
        return stream
    }

    func cancel(_ episode: Episode) {
        let id = episode.episodeID
        if let stream = streams.removeValue(forKey: id) {
            stream.cancel()
            processing.cancelStreaming(id)
        }
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
        if episode.downloadState == .queued || episode.downloadState == .downloading {
            cancel(episode)
        }
        if let url = episode.localFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        TranscriptStore.delete(episodeID: episode.episodeID)
        episode.fileName = nil
        episode.downloadedAt = nil
        episode.downloadState = .notDownloaded
        episode.processingState = .none
        episode.processingError = nil
        try? context.save()
    }

    /// Fix up episodes that think they're downloading but whose task no longer exists.
    func reconcile() async {
        // Partial files from play-while-downloading sessions don't survive a relaunch.
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Storage.episodesDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "partial" && streams.isEmpty {
            try? FileManager.default.removeItem(at: file)
        }

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
        progress[id] = fraction
        if let episode = context.episode(withID: id), episode.downloadState == .queued {
            episode.downloadState = .downloading
        }
    }

    private func finish(_ id: String, fileName: String) {
        progress[id] = nil
        guard let episode = context.episode(withID: id) else {
            try? FileManager.default.removeItem(at: Storage.episodesDirectory.appending(path: fileName))
            return
        }
        episode.fileName = fileName
        episode.downloadedAt = .now
        episode.downloadState = .downloaded
        try? context.save()
        processing.enqueue(episode)
    }

    private func finishStreaming(_ id: String, fileExtension: String) {
        guard let stream = streams.removeValue(forKey: id) else { return }
        progress[id] = nil
        guard let episode = context.episode(withID: id) else {
            stream.cancel()
            return
        }
        let fileName = "\(id).\(fileExtension)"
        let destination = Storage.episodesDirectory.appending(path: fileName)
        do {
            try? FileManager.default.removeItem(at: destination)
            // The player and analyzer keep reading through open file handles, so moving is safe.
            try FileManager.default.moveItem(at: stream.partialURL, to: destination)
        } catch {
            stream.cancel()
            failStreaming(id)
            return
        }
        episode.fileName = fileName
        episode.downloadedAt = .now
        episode.downloadState = .downloaded
        try? context.save()
        stream.commitDownload()

        // Not scanned while downloading (unsupported format or interrupted): scan it now.
        if episode.processingState == .none || episode.processingState == .pending {
            processing.processNow(episode)
        }
    }

    private func failStreaming(_ id: String) {
        streams[id] = nil
        processing.cancelStreaming(id)
        fail(id)
    }

    private func fail(_ id: String) {
        progress[id] = nil
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
        Task { @MainActor in self.updateProgress(id, fraction) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil, let id = task.taskDescription else { return }
        Task { @MainActor in self.fail(id) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.finishBackgroundEvents() }
    }
}
