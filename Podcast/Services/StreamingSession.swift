import AVFoundation
import Speech
import UniformTypeIdentifiers

nonisolated enum StreamingError: LocalizedError {
    case unsupportedFormat
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "This episode's audio format can't be scanned while downloading."
        case .downloadFailed: "The download failed."
        }
    }
}

/// Downloads one episode to disk while it is being played and transcribed:
///
/// - The player reads the partial file through an `AVAssetResourceLoaderDelegate` (custom URL
///   scheme). Requests for bytes not downloaded yet wait until they arrive.
/// - The speech analyzer pulls decoded audio from the same file at its own pace
///   (`StreamingAudioInput`), so memory stays flat even when the network is faster than analysis.
///
/// When the download finishes, the file is kept as a normal downloaded episode.
/// All mutable state lives on `queue`.
nonisolated final class StreamingSession: NSObject, @unchecked Sendable {
    static let scheme = "podcast-stream"

    let episodeID: String
    let asset: AVURLAsset
    let partialURL: URL

    /// Set before `start()`.
    var onProgress: (@Sendable (Double) -> Void)?
    /// Called once all bytes are on disk, with the file extension to use.
    var onComplete: (@Sendable (String) -> Void)?
    var onFail: (@Sendable () -> Void)?

    private let remoteURL: URL
    private let queue = DispatchQueue(label: "StreamingSession", qos: .userInitiated)
    private var urlSession: URLSession!
    private var writer: FileHandle?
    private var reader: FileHandle?

    private var received: Int64 = 0
    private var expectedLength: Int64 = 0  // 0 = unknown
    private var mimeType: String?
    private var responseReceived = false
    private var isComplete = false
    private var isStopped = false
    private var retries = 0

    // Player side
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var rangeFetches: Set<ObjectIdentifier> = []

    // Transcription side
    private var analyzerFormat: AVAudioFormat?
    private var decoder: StreamDecoder?
    private var decodedOffset: Int64 = 0
    private var decodedInputs: [AnalyzerInput] = []
    private var inputWaiter: CheckedContinuation<AnalyzerInput?, Error>?
    /// Set once the app has recorded the finished download; the analyzer input ends after that.
    private var downloadCommitted = false

    private static let chunkSize = 64 * 1024

    init(episodeID: String, remoteURL: URL) {
        self.episodeID = episodeID
        self.remoteURL = remoteURL
        partialURL = Storage.episodesDirectory.appending(path: "\(episodeID).partial")
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "episode"
        let ext = remoteURL.pathExtension.isEmpty ? "mp3" : remoteURL.pathExtension
        components.path = "/\(episodeID).\(ext)"
        asset = AVURLAsset(url: components.url!)
        super.init()

        try? FileManager.default.removeItem(at: partialURL)
        FileManager.default.createFile(atPath: partialURL.path(percentEncoded: false), contents: nil)
        writer = try? FileHandle(forWritingTo: partialURL)
        reader = try? FileHandle(forReadingFrom: partialURL)

        asset.resourceLoader.setDelegate(self, queue: queue)
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
    }

    func start() {
        queue.async { self.requestBytes(from: 0) }
    }

    /// Stops the download and deletes the partial file.
    func cancel() {
        queue.async { self.stop(deleteFile: true) }
    }

    /// The app has moved the file into place; let the analyzer reach the end of the input.
    func commitDownload() {
        queue.async {
            self.downloadCommitted = true
            self.produceInput()
        }
    }

    /// Hands the analyzer a pull-based input sequence in its preferred format.
    func makeAnalyzerInput(format: AVAudioFormat) -> StreamingAudioInput {
        let box = UncheckedBox(format)
        queue.async {
            self.analyzerFormat = box.value
            self.produceInput()
        }
        return StreamingAudioInput(session: self)
    }

    // MARK: - Network

    private func requestBytes(from offset: Int64) {
        guard !isStopped else { return }
        var request = URLRequest(url: remoteURL)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        urlSession.dataTask(with: request).resume()
    }

    private var totalLength: Int64? {
        if expectedLength > 0 { return expectedLength }
        return isComplete ? received : nil
    }

    private var contentType: String {
        if let mimeType, let type = UTType(mimeType: mimeType), type.conforms(to: .audio) {
            return type.identifier
        }
        return UTType(filenameExtension: remoteURL.pathExtension)?.identifier ?? UTType.mp3.identifier
    }

    private func fileExtension() -> String {
        let response = HTTPURLResponse(
            url: remoteURL, mimeType: mimeType, expectedContentLength: 0, textEncodingName: nil)
        return DownloadManager.fileExtension(for: response, url: remoteURL)
    }

    private func didFinishDownloading() {
        isComplete = true
        try? writer?.close()
        writer = nil
        urlSession.finishTasksAndInvalidate()
        servePending()
        produceInput()
        onComplete?(fileExtension())
    }

    private func stop(deleteFile: Bool) {
        guard !isStopped else { return }
        isStopped = true
        urlSession.invalidateAndCancel()
        for request in pending { request.finishLoading(with: StreamingError.downloadFailed) }
        pending.removeAll()
        inputWaiter?.resume(throwing: StreamingError.downloadFailed)
        inputWaiter = nil
        try? writer?.close()
        writer = nil
        if deleteFile { try? FileManager.default.removeItem(at: partialURL) }
    }

    private func fail() {
        stop(deleteFile: true)
        onFail?()
    }

    // MARK: - Player (resource loader)

    private func servePending() {
        pending.removeAll { serve($0) }
    }

    /// Returns true when the request is finished and can be dropped.
    private func serve(_ request: AVAssetResourceLoadingRequest) -> Bool {
        if request.isCancelled || request.isFinished { return true }

        if let info = request.contentInformationRequest {
            guard responseReceived, let length = totalLength else { return false }
            info.contentType = contentType
            info.contentLength = length
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }

        let total = totalLength ?? .max
        let requestedEnd = dataRequest.requestsAllDataToEndOfResource
            ? total
            : dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
        let end = min(total, requestedEnd)

        var offset = dataRequest.currentOffset
        while offset < min(end, received), let reader {
            let count = Int(min(min(end, received) - offset, 512 * 1024))
            do {
                try reader.seek(toOffset: UInt64(offset))
                guard let data = try reader.read(upToCount: count), !data.isEmpty else { break }
                dataRequest.respond(with: data)
                offset += Int64(data.count)
            } catch {
                break
            }
        }

        if offset >= end || isComplete {
            request.finishLoading()
            return true
        }
        // Far ahead of the download (e.g. metadata at the end of the file): fetch that range directly.
        if offset > received + 2_000_000 && !rangeFetches.contains(ObjectIdentifier(request)) {
            fetchRange(for: request, from: offset, upTo: end)
        }
        return false
    }

    private func fetchRange(for request: AVAssetResourceLoadingRequest, from start: Int64, upTo end: Int64) {
        let id = ObjectIdentifier(request)
        rangeFetches.insert(id)
        let last = min(end, start + 1_000_000) - 1
        var urlRequest = URLRequest(url: remoteURL)
        urlRequest.setValue("bytes=\(start)-\(last)", forHTTPHeaderField: "Range")
        let box = UncheckedBox(request)
        URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            self.queue.async {
                self.rangeFetches.remove(id)
                guard let index = self.pending.firstIndex(where: { $0 === box.value }) else { return }
                self.pending.remove(at: index)
                if let data, (response as? HTTPURLResponse)?.statusCode == 206 {
                    box.value.dataRequest?.respond(with: data)
                    box.value.finishLoading()
                } else {
                    box.value.finishLoading(with: error ?? URLError(.badServerResponse))
                }
            }
        }.resume()
    }

    // MARK: - Analyzer input

    /// Called (via `StreamingAudioInput`) when the analyzer wants more audio.
    fileprivate func nextInput() async throws -> AnalyzerInput? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if self.isStopped {
                        continuation.resume(throwing: StreamingError.downloadFailed)
                        return
                    }
                    self.inputWaiter?.resume(throwing: CancellationError())
                    self.inputWaiter = continuation
                    self.produceInput()
                }
            }
        } onCancel: {
            queue.async {
                self.inputWaiter?.resume(throwing: CancellationError())
                self.inputWaiter = nil
            }
        }
    }

    /// Decodes just enough of the file to answer a waiting analyzer request.
    private func produceInput() {
        guard let waiter = inputWaiter else { return }

        if decoder == nil {
            guard let analyzerFormat, responseReceived else { return }
            let decoder = StreamDecoder(targetFormat: analyzerFormat) { [unowned self] buffer in
                decodedInputs.append(AnalyzerInput(buffer: buffer))
            }
            let hint = StreamDecoder.typeHint(mimeType: mimeType, pathExtension: remoteURL.pathExtension)
            guard decoder.open(typeHint: hint) else {
                inputWaiter = nil
                waiter.resume(throwing: StreamingError.unsupportedFormat)
                return
            }
            self.decoder = decoder
        }
        guard let decoder, let reader else { return }

        while decodedInputs.isEmpty && decodedOffset < received {
            do {
                try reader.seek(toOffset: UInt64(decodedOffset))
                let count = Int(min(received - decodedOffset, Int64(Self.chunkSize)))
                guard let data = try reader.read(upToCount: count), !data.isEmpty else { break }
                decoder.feed(data)
                decodedOffset += Int64(data.count)
            } catch {
                break
            }
            // No audio after several MB usually means an M4A with its index at the end.
            if decoder.failed || (!decoder.producedAudio && decodedOffset > 8_000_000) {
                inputWaiter = nil
                waiter.resume(throwing: StreamingError.unsupportedFormat)
                return
            }
        }

        if !decodedInputs.isEmpty {
            inputWaiter = nil
            waiter.resume(returning: decodedInputs.removeFirst())
        } else if isComplete && downloadCommitted && decodedOffset >= received {
            inputWaiter = nil
            waiter.resume(returning: nil)  // end of audio
        }
        // Otherwise wait for more bytes; `didReceive data` calls back in here.
    }
}

// MARK: - URLSessionDataDelegate

nonisolated extension StreamingSession: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if received > 0 {
            // Resuming after a dropped connection: must get the rest, not the whole file again.
            guard status == 206 else {
                completionHandler(.cancel)
                fail()
                return
            }
        } else {
            guard (200..<300).contains(status) else {
                completionHandler(.cancel)
                fail()
                return
            }
            expectedLength = max(0, response.expectedContentLength)
            mimeType = response.mimeType
            responseReceived = true
        }
        completionHandler(.allow)
        servePending()
        produceInput()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let writer, !isStopped else { return }
        do {
            try writer.seekToEnd()
            try writer.write(contentsOf: data)
        } catch {
            fail()
            return
        }
        received += Int64(data.count)
        if expectedLength > 0 { onProgress?(min(1, Double(received) / Double(expectedLength))) }
        servePending()
        produceInput()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isStopped else { return }
        let incomplete = expectedLength > 0 && received < expectedLength
        if error != nil || incomplete {
            // Retry dropped connections, resuming where we left off.
            guard retries < 5 else {
                fail()
                return
            }
            retries += 1
            let offset = received
            queue.asyncAfter(deadline: .now() + .seconds(retries * 2)) { self.requestBytes(from: offset) }
            return
        }
        didFinishDownloading()
    }
}

// MARK: - AVAssetResourceLoaderDelegate

nonisolated extension StreamingSession: AVAssetResourceLoaderDelegate {
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !isStopped else { return false }
        pending.append(loadingRequest)
        servePending()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
    }
}

/// Pull-based audio for `SpeechAnalyzer`: each `next()` decodes a little more of the download.
nonisolated struct StreamingAudioInput: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let session: StreamingSession

    struct AsyncIterator: AsyncIteratorProtocol {
        let session: StreamingSession
        mutating func next() async throws -> AnalyzerInput? {
            try await session.nextInput()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(session: session)
    }
}
