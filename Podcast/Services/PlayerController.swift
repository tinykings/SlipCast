import AVFoundation
import AudioDetection
import KeywordSpotting
import MediaPlayer
import Observation
import SwiftData
import UIKit

/// Plays downloaded episodes and silences muted words with a real-time audio tap. The audio file
/// is never modified; changing the mute list just updates the tap, even mid-episode.
///
/// Filtered episodes play only once fully scanned. If a re-scan starts mid-episode, playback is
/// held until it finishes, and the tap silences anything past the scanned point as a backstop.
@Observable
final class PlayerController {
    private(set) var episode: Episode?
    /// The user wants audio playing (it may be held while a re-scan finishes).
    private(set) var isPlaying = false
    /// A filtered episode is being re-scanned; playback resumes once the scan is complete.
    private(set) var isWaitingForScan = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// Where audio is being silenced, in episode seconds (only what's been scanned so far).
    private(set) var mutedRanges: [ClosedRange<Double>] = []
    private(set) var filteredSkipRanges: [ClosedRange<Double>] = []
    var mutedSpotCount: Int { mutedRanges.count }
    /// The transcript found so far, with muted words flagged.
    private(set) var transcriptLines: [TranscriptLine] = []
    /// The feed's own transcript, shown for episodes that aren't filtered.
    private(set) var publisherTranscript = PublisherTranscriptState.none
    /// For unfiltered episodes without a feed transcript: the one made on the device so far.
    private(set) var readAlongLines: [TranscriptLine] = []
    /// Seconds of `readAlongLines` that are final; `.infinity` once the transcript is complete.
    private(set) var readAlongThrough: Double = 0
    private(set) var readAlongFailed = false
    @ObservationIgnored private var readAlongRefreshPending = false
    /// Seconds of the episode scanned for muted words. `.infinity` once fully scanned.
    private(set) var scannedThrough: Double = 0
    private(set) var scanError: String?
    /// Episodes queued by Play All, played in order after the current one.
    private(set) var upNext: [String] = []
    /// Still downloading or filtering; starts on its own as soon as it can play.
    private(set) var playWhenReadyID: String?
    /// Called when playback pauses, stops or changes episode, so the position can be synced.
    /// Periodic position saves during playback don't sync on their own.
    @ObservationIgnored var onPositionCheckpoint: (() -> Void)?

    /// Chapters for the current episode, from the file or the feed. Empty when it has none.
    private(set) var chapters: [Chapter] = []
    var currentChapter: Chapter? { chapters.last { $0.start <= currentTime + 0.25 } }

    /// What the sleep timer is set to; nil when it's off.
    private(set) var sleepTimer: SleepTimer?
    /// Listening time left on a timed sleep timer. It only counts down while audio plays.
    private(set) var sleepRemaining: Double = 0
    @ObservationIgnored private var lastSleepTick: Date?
    /// The volume fades out over this many seconds before the sleep timer pauses.
    private let sleepFade = 8.0

    /// Set with `setRate(_:)`, which also remembers it for the show.
    private(set) var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if player.timeControlStatus != .paused { player.rate = rate }
            updateNowPlaying()
        }
    }

    var isFullyScanned: Bool { scannedThrough.isInfinite }

    /// The furthest point playback and seeking may reach.
    var playableLimit: Double {
        if isFullyScanned { return duration }
        return max(0, min(duration, scannedThrough - safetyMargin))
    }

    private let player = AVPlayer()
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let processing: ProcessingQueue
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let timeline = MuteTimeline()
    @ObservationIgnored private var words: [TranscriptWord] = []
    @ObservationIgnored private var automaticAudioScan: OverlapScan?
    /// Muted words heard in the crosstalk clips of `automaticAudioScan`.
    @ObservationIgnored private var crosstalkCheck: OverlapKeywordCheck?
    @ObservationIgnored private var crosstalkTask: Task<Void, Never>?
    @ObservationIgnored private var muteRefreshPending = false
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var skipObserver: Any?
    @ObservationIgnored private var isSkippingSection = false
    @ObservationIgnored private var seekGeneration = 0
    @ObservationIgnored private var lastSavedPosition: Double = 0
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private let keepAlive = SilentKeepAlive()
    @ObservationIgnored private var playWhenReadyTimer: Timer?

    /// Keep seeking this far behind the scanned point while a re-scan is running.
    private let safetyMargin = 2.0

    init(context: ModelContext, processing: ProcessingQueue, downloads: DownloadManager) {
        self.context = context
        self.processing = processing
        self.downloads = downloads
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        processing.onLiveUpdate = { [weak self] id in self?.scanProgressed(id) }
        processing.onFinished = { [weak self] id in self?.scanFinished(id) }
        configureRemoteCommands()
    }

    func isCurrent(_ episode: Episode) -> Bool {
        self.episode?.episodeID == episode.episodeID
    }

    /// Episodes play only once downloaded; filtered ones also need their scan.
    static func canPlay(_ episode: Episode) -> Bool {
        episode.downloadState == .downloaded && (!episode.requiresFiltering || episode.processingState == .ready)
    }

    var scanStatus: String {
        if processing.isPaused && episode?.requiresFiltering == true { return "Filtering paused · resume in Downloads" }
        if let id = episode?.episodeID, let phase = processing.phaseLabel[id] { return phase }
        return "Waiting for muted-word processing…"
    }

    func toggle(_ episode: Episode) {
        if isCurrent(episode) {
            togglePlayPause()
        } else {
            Task { await play(episode) }
        }
    }

    /// Plays the episodes in order, one after another.
    func playAll(_ episodes: [Episode]) {
        let playable = episodes.filter(Self.canPlay)
        guard let first = playable.first else { return }
        upNext = playable.dropFirst().map(\.episodeID)
        Task { await load(first) }
    }

    /// Plays one episode, replacing any Play All queue.
    func play(_ episode: Episode) async {
        upNext = []
        await load(episode)
    }

    private func load(_ episode: Episode) async {
        guard Self.canPlay(episode) else { return }
        if isCurrent(episode) {
            resume()
            return
        }

        savePosition()
        if self.episode != nil { onPositionCheckpoint?() }
        player.pause()
        removeSkipObserver()
        seekGeneration &+= 1
        isSkippingSection = false
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        self.episode = episode
        artwork = nil
        isWaitingForScan = false
        scanError = nil

        guard let url = episode.localFileURL else {
            scanError = "Audio file is missing. Delete and re-download the episode."
            return
        }
        let asset = AVURLAsset(url: url)
        loadScanState(for: episode)
        applyMuting()
        loadPublisherTranscript(for: episode)
        loadReadAlong(for: episode)

        rate = Float(episode.show?.playbackRate ?? AppSettings.playbackRate)
        loadChapters(for: episode, asset: asset)

        let item = AVPlayerItem(asset: asset)
        if episode.requiresFiltering {
            guard DeviceSupport.transcriptionAvailable else {
                scanError = "Filtering isn't supported on this device. Turn it off for this show to play the original audio."
                return
            }
            if let track = try? await asset.loadTracks(withMediaType: .audio).first {
                item.audioMix = MuteTap.makeAudioMix(track: track, timeline: timeline)
            }
            guard item.audioMix != nil else {
                scanError = "Couldn't set up muting for this episode."
                return
            }
        }
        player.replaceCurrentItem(with: item)
        installSkipObserver()
        observeEnd(of: item)

        // The feed's duration is available instantly; the file's own is loaded below.
        duration = automaticAudioScan?.duration ?? episode.duration ?? 0
        let id = episode.episodeID
        Task {
            if let loaded = try? await asset.load(.duration).seconds, loaded.isFinite, loaded > 0,
               self.episode?.episodeID == id {
                duration = loaded
                updatePlaybackGate()
            }
        }
        var start = episode.playbackPosition
        if duration > 0 && start > duration - 5 { start = 0 }
        await player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        currentTime = start
        lastSavedPosition = start

        isPlaying = true
        updatePlaybackGate()
        loadArtwork(for: episode)
    }

    func resume() {
        guard player.currentItem != nil else { return }
        isPlaying = true
        updatePlaybackGate()
    }

    func pause() {
        player.pause()
        isPlaying = false
        isWaitingForScan = false
        savePosition()
        onPositionCheckpoint?()
        updateNowPlaying()
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), playableLimit)
        let destination = episode?.requiresFiltering == true
            ? (FilteredSkipPlanner.destination(at: clamped, ranges: filteredSkipRanges, duration: duration) ?? clamped) : clamped
        currentTime = destination
        performExactSeek(to: destination)
        updateNowPlaying()
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    /// Stops playback and clears the player (e.g. when the current episode's file is deleted).
    func stop() {
        savePosition()
        if episode != nil { onPositionCheckpoint?() }
        setSleepTimer(nil)
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeSkipObserver()
        seekGeneration &+= 1
        isSkippingSection = false
        filteredSkipRanges = []
        upNext = []
        episode = nil
        isPlaying = false
        isWaitingForScan = false
        words = []
        scannedThrough = 0
        mutedRanges = []
        automaticAudioScan = nil
        resetCrosstalkCheck()
        transcriptLines = []
        publisherTranscript = .none
        readAlongLines = []
        readAlongThrough = 0
        readAlongFailed = false
        chapters = []
        timeline.update(MuteSnapshot())
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func filteringChanged(for show: Show) {
        if episode?.show?.feedURL == show.feedURL { stop() }
        processing.filteringChanged(for: show)
    }

    /// Call after the mute list or padding changes.
    func refreshMuting() {
        applyMuting()
    }

    // MARK: - Publisher transcript

    private func loadPublisherTranscript(for episode: Episode) {
        guard !episode.requiresFiltering, let url = episode.transcriptURL else {
            publisherTranscript = .none
            return
        }
        let id = episode.episodeID, type = episode.transcriptType
        if let words = PublisherTranscript.cached(episodeID: id) {
            publisherTranscript = .loaded(TranscriptLine.lines(from: words, mutedWordIndices: []))
            return
        }
        publisherTranscript = .loading
        Task {
            let state: PublisherTranscriptState
            do {
                let words = try await PublisherTranscript.words(episodeID: id, url: url, type: type)
                state = .loaded(TranscriptLine.lines(from: words, mutedWordIndices: []))
            } catch {
                state = .failed
            }
            guard let current = self.episode, current.episodeID == id else { return }
            publisherTranscript = state
            if state == .failed {
                processing.publisherTranscriptUnavailable(for: current)
                loadReadAlong(for: current)
            }
        }
    }

    // MARK: - Read-along transcript

    /// Shows the transcript made on the device for an unfiltered episode, and asks for one to be
    /// made next if it doesn't have one yet.
    private func loadReadAlong(for episode: Episode) {
        let id = episode.episodeID
        readAlongFailed = false
        guard !episode.requiresFiltering else {
            readAlongLines = []
            readAlongThrough = 0
            return
        }
        let words: [TranscriptWord]
        if processing.activeIsReadAlong && processing.activeEpisodeID == id {
            words = processing.liveWords
            readAlongThrough = processing.liveTranscribedThrough
        } else if TranscriptStore.isCurrent(episodeID: id) {
            words = (try? TranscriptStore.load(episodeID: id)) ?? []
            readAlongThrough = .infinity
        } else {
            words = []
            readAlongThrough = 0
            readAlongFailed = processing.readAlongFailed(id)
            processing.preferReadAlong(episode)
        }
        readAlongLines = TranscriptLine.lines(from: words, mutedWordIndices: [])
    }

    private func readAlongProgressed(_ id: String) {
        guard !readAlongRefreshPending else { return }
        readAlongRefreshPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            readAlongRefreshPending = false
            guard let episode, episode.episodeID == id, !episode.requiresFiltering else { return }
            loadReadAlong(for: episode)
        }
    }

    // MARK: - Scanning

    private func loadScanState(for episode: Episode) {
        automaticAudioScan = nil
        resetCrosstalkCheck()
        guard episode.requiresFiltering else {
            words = []
            scannedThrough = .infinity
            return
        }
        if processing.activeEpisodeID == episode.episodeID {
            words = processing.liveWords
            automaticAudioScan = processing.liveAudioScan
            scannedThrough = processing.liveScannedThrough
        } else {
            let transcriptCurrent = TranscriptStore.isCurrent(episodeID: episode.episodeID)
            words = transcriptCurrent ? ((try? TranscriptStore.load(episodeID: episode.episodeID)) ?? []) : []
            if episode.downloadState == .downloaded, let url = episode.localFileURL {
                automaticAudioScan = try? OverlapScanStore().load(episodeID: episode.episodeID, fileURL: url)
            }
            if transcriptCurrent, let scan = automaticAudioScan {
                scannedThrough = scan.isComplete ? .infinity : scan.scannedThrough
            } else { scannedThrough = 0 }
        }
        // The queue emits its final callback before clearing live state.
        if episode.processingState == .ready, automaticAudioScan?.isComplete == true {
            scannedThrough = .infinity
        }
        if let scan = automaticAudioScan, scan.isComplete, let url = episode.localFileURL {
            crosstalkCheck = CrosstalkFilter.savedCheck(fileURL: url, episodeID: episode.episodeID, scan: scan)
        }
    }

    private func resetCrosstalkCheck() {
        crosstalkTask?.cancel()
        crosstalkTask = nil
        crosstalkCheck = nil
    }

    /// Mute ranges for muted words heard in crosstalk. Until the clips have been checked for
    /// every current word (a few seconds), the clips themselves are skipped so nothing slips by.
    private func crosstalkRanges(terms: [MutedTerm], padding: Double) -> [ClosedRange<Double>] {
        guard let scan = automaticAudioScan, !terms.isEmpty else { return [] }
        let keywords = CrosstalkFilter.keywords(for: terms.map(\.text))
        if keywords.isEmpty { return [] }
        if let crosstalkCheck, crosstalkCheck.covers(keywords) {
            return crosstalkCheck.hits(for: keywords).map { CrosstalkFilter.muteRange(for: $0, padding: padding) }
        }
        startCrosstalkCheck(scan: scan, keywords: keywords)
        return scan.skipRanges(padding: padding)
    }

    private func startCrosstalkCheck(scan: OverlapScan, keywords: Set<String>) {
        // While processing, the queue checks once the scan is complete; playback waits for it.
        guard crosstalkTask == nil, scan.isComplete, let episode, episode.downloadState == .downloaded,
              let url = episode.localFileURL else { return }
        let id = episode.episodeID
        crosstalkTask = Task {
            let check = try? await CrosstalkFilter.check(fileURL: url, episodeID: id, scan: scan, keywords: keywords)
            // stop() and loading another episode cancel this task, so the episode is still current.
            guard !Task.isCancelled else { return }
            crosstalkTask = nil
            if let check { crosstalkCheck = check }
            // On failure the clips stay skipped; a later mute-list change or reload retries.
            if check != nil { applyMuting() }
        }
    }

    func rescanDownloads() {
        if episode?.requiresFiltering == true { pause() }
        processing.rescanDownloads(prioritize: episode?.requiresFiltering == true ? episode?.episodeID : nil)
        if let episode { loadScanState(for: episode) }
        scanError = nil
        applyMuting()
    }

    private func scanProgressed(_ id: String) {
        if episode?.episodeID == id, episode?.requiresFiltering == false {
            readAlongProgressed(id)
            return
        }
        guard episode?.episodeID == id, !muteRefreshPending else { return }
        // Coalesce: results can arrive many times per second.
        muteRefreshPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            muteRefreshPending = false
            guard let episode, episode.episodeID == id, !isFullyScanned else { return }
            loadScanState(for: episode)
            applyMuting()
        }
    }

    private func scanFinished(_ id: String) {
        if id == playWhenReadyID { checkPlayWhenReady() }
        guard let episode, episode.episodeID == id else { return }
        guard episode.requiresFiltering else {
            loadReadAlong(for: episode)
            return
        }
        switch episode.processingState {
        case .ready:
            loadScanState(for: episode)
            applyMuting()
        case .failed:
            player.pause()
            isPlaying = false
            isWaitingForScan = false
            scanError = episode.processingError ?? "Couldn't scan this episode."
        case .pending:
            // Interrupted (e.g. background time ran out) while we still need it: pick it back up.
            Task { processing.processNow(episode) }
        default:
            break
        }
    }

    /// Recomputes mute ranges from the words known so far and hands them to the audio tap.
    private func applyMuting() {
        guard episode?.requiresFiltering == true else {
            mutedRanges = []
            filteredSkipRanges = []
            removeSkipObserver()
            transcriptLines = []
            timeline.update(MuteSnapshot(scannedUntil: .infinity))
            updatePlaybackGate()
            return
        }
        let terms = (try? context.fetch(FetchDescriptor<MutedTerm>())) ?? []
        let padding = AppSettings.padding
        let matches = MuteMatcher.matchedWords(in: words, rules: terms.map(\.rule))
        let transcriptRanges = MuteMatcher.muteRanges(for: matches, in: words, padding: padding)
        let reviewedRanges: [ClosedRange<Double>]
        if let episode, episode.downloadState == .downloaded, let fileURL = episode.localFileURL {
            reviewedRanges = (try? ReviewedMuteStore().ranges(episodeID: episode.episodeID, fileURL: fileURL)) ?? []
        } else { reviewedRanges = [] }
        let automaticRanges = crosstalkRanges(terms: terms, padding: padding)
        let ranges = MuteMatcher.merge(transcriptRanges + automaticRanges + reviewedRanges, joiningGapsUnder: 0.08)
        mutedRanges = ranges
        filteredSkipRanges = ranges
        installSkipObserver()
        let mutedWords = Set(matches.flatMap { Array($0) })
        transcriptLines = TranscriptLine.lines(from: words, mutedWordIndices: mutedWords,
            skippedRanges: MuteMatcher.merge(automaticRanges + reviewedRanges, joiningGapsUnder: 0.08))
        // A word just past the scanned point could have padding reaching back before it.
        let scannedUntil = isFullyScanned ? Double.infinity : scannedThrough - padding - MuteTap.fade
        timeline.update(MuteSnapshot(ranges: ranges, scannedUntil: scannedUntil))
        if !skipFilteredSectionIfNeeded() { updatePlaybackGate() }
    }

    /// Holds a filtered episode until its scan is complete, otherwise starts the player if the
    /// user wants it playing.
    private func updatePlaybackGate() {
        guard isPlaying, player.currentItem != nil else { return }
        if episode?.requiresFiltering == true && !isFullyScanned {
            player.pause()
            isWaitingForScan = true
            return
        }
        isWaitingForScan = false
        if player.timeControlStatus == .paused { startPlayback() }
        updateNowPlaying()
    }

    private var isActivatingSession = false

    /// Activates the audio session without blocking the main thread, then starts the player
    /// (unless the user paused in the meantime).
    private func startPlayback() {
        guard !isActivatingSession, !isSkippingSection else { return }
        if skipFilteredSectionIfNeeded() { return }
        isActivatingSession = true
        Task {
            await Self.activateAudioSession()
            isActivatingSession = false
            guard isPlaying, !isWaitingForScan, player.currentItem != nil,
                  player.timeControlStatus == .paused else { return }
            if skipFilteredSectionIfNeeded() { return }
            player.playImmediately(atRate: rate)
            updateNowPlaying()
        }
    }

    @concurrent
    private nonisolated static func activateAudioSession() async {
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 27, *) {
            _ = try? await session.activate(options: [])
        } else {
            try? session.setActive(true)
        }
    }

    private func removeSkipObserver() {
        if let skipObserver { player.removeTimeObserver(skipObserver) }
        skipObserver = nil
    }

    private func installSkipObserver() {
        removeSkipObserver()
        guard let episode, episode.requiresFiltering, !filteredSkipRanges.isEmpty else { return }
        let id = episode.episodeID
        let times = filteredSkipRanges.map {
            NSValue(time: CMTime(seconds: max(0, $0.lowerBound - 0.03), preferredTimescale: 60000))
        }
        skipObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard self?.episode?.episodeID == id else { return }
                _ = self?.skipFilteredSectionIfNeeded()
            }
        }
    }

    /// Skip whole filtered passages instead of waiting through silence. The audio tap still
    /// silences them while a boundary callback or exact seek is being delivered.
    @discardableResult
    private func skipFilteredSectionIfNeeded() -> Bool {
        guard isPlaying, !isSkippingSection, episode?.requiresFiltering == true, isFullyScanned,
              player.currentItem != nil,
              let destination = FilteredSkipPlanner.destination(at: player.currentTime().seconds,
                  ranges: filteredSkipRanges, duration: duration, lead: 0.035) else { return false }
        if destination >= duration - 0.001 {
            player.pause()
            didFinish()
            return true
        }
        performExactSeek(to: destination)
        return true
    }

    private func performExactSeek(to destination: Double) {
        guard let item = player.currentItem else { return }
        let id = episode?.episodeID
        seekGeneration &+= 1
        let generation = seekGeneration
        isSkippingSection = true
        player.pause()
        player.seek(to: CMTime(seconds: destination, preferredTimescale: 60000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] finished in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation,
                      self.episode?.episodeID == id, self.player.currentItem === item else { return }
                self.isSkippingSection = false
                guard finished else {
                    self.isPlaying = false
                    self.scanError = "Couldn't seek past a filtered section. Try playing this episode again."
                    return
                }
                self.currentTime = destination
                self.updatePlaybackGate()
                self.updateNowPlaying()
            }
        }
    }

    // MARK: - Progress

    private func tick(_ seconds: Double) {
        guard episode != nil, seconds.isFinite else { return }
        currentTime = seconds
        if advanceSleepTimer() { return }
        if skipFilteredSectionIfNeeded() { return }
        if !isSkippingSection && !isWaitingForScan && !isActivatingSession && isPlaying && player.timeControlStatus == .paused && player.rate == 0 {
            // Paused by the system (phone call, headphones unplugged, etc.).
            isPlaying = false
            updateNowPlaying()
        }
        if isPlaying && !isFullyScanned { updatePlaybackGate() }
        if abs(currentTime - lastSavedPosition) > 15 { savePosition() }
    }

    private func savePosition() {
        guard let episode else { return }
        episode.playbackPosition = currentTime
        lastSavedPosition = currentTime
        try? context.save()
    }

    private func observeEnd(of item: AVPlayerItem) {
        let id = episode?.episodeID
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.episode?.episodeID == id else { return }
                self?.didFinish()
            }
        }
    }

    private func didFinish() {
        guard let episode else { return }
        let sleepsNow = sleepTimer == .endOfEpisode
        let timer = sleepTimer, remaining = sleepRemaining
        episode.isPlayed = true
        episode.playbackPosition = 0
        currentTime = 0
        isPlaying = false
        isWaitingForScan = false
        try? context.save()
        if AppSettings.autoDeletePlayed {
            // Release the finished file before deleting it, keeping Play All's remaining queue.
            let remainingQueue = upNext
            stop()
            downloads.deleteDownload(episode)
            upNext = remainingQueue
            sleepTimer = timer
            sleepRemaining = remaining
        } else {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            updateNowPlaying()
        }
        if sleepsNow {
            setSleepTimer(nil)  // the queue is kept for later
        } else {
            playNextInQueue()
        }
    }

    private func playNextInQueue() {
        while let id = upNext.first {
            upNext.removeFirst()
            if let next = context.episode(withID: id), Self.canPlay(next) {
                Task { await load(next) }
                return
            }
        }
    }

    // MARK: - Speed

    /// Changes the speed and remembers it for this show and as the default for others.
    func setRate(_ newRate: Float) {
        rate = newRate
        AppSettings.playbackRate = Double(newRate)
        if let show = episode?.show, show.playbackRate != Double(newRate) {
            show.playbackRate = Double(newRate)
            try? context.save()
        }
    }

    // MARK: - Up next

    /// Re-sorts a Play All queue after the user reorders the list it came from.
    func reorderUpNext(_ order: [String]) {
        guard upNext.count > 1 else { return }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        upNext = upNext.enumerated()
            .sorted { (rank[$0.element] ?? Int.max, $0.offset) < (rank[$1.element] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    // MARK: - Chapters

    private func loadChapters(for episode: Episode, asset: AVURLAsset) {
        chapters = []
        let id = episode.episodeID, url = episode.chaptersURL
        Task {
            var found = await Chapters.embedded(in: asset)
            if found.isEmpty, let url {
                found = (try? await Chapters.published(episodeID: id, url: url)) ?? []
            }
            guard self.episode?.episodeID == id else { return }
            chapters = found
        }
    }

    func seek(to chapter: Chapter) {
        seek(to: chapter.start)
    }

    // MARK: - Sleep timer

    /// Starts, changes or (with nil) cancels the sleep timer.
    func setSleepTimer(_ timer: SleepTimer?) {
        sleepTimer = timer
        if case .minutes(let minutes) = timer { sleepRemaining = Double(minutes) * 60 } else { sleepRemaining = 0 }
        lastSleepTick = nil
        player.volume = 1
    }

    /// Counts a timed sleep timer down by the listening time since the last tick, fading out at the
    /// end. Returns true when it paused playback.
    private func advanceSleepTimer() -> Bool {
        guard case .minutes = sleepTimer else { return false }
        let now = Date.now
        defer { lastSleepTick = now }
        guard isPlaying, !isWaitingForScan, player.timeControlStatus == .playing, let last = lastSleepTick else {
            return false
        }
        // Capped so time spent paused (no ticks) isn't counted.
        sleepRemaining = max(0, sleepRemaining - min(now.timeIntervalSince(last), 1))
        if sleepRemaining > 0 {
            player.volume = Float(min(1, sleepRemaining / sleepFade))
            return false
        }
        pause()
        setSleepTimer(nil)
        return true
    }

    // MARK: - Play when ready

    /// Marks an episode that's still downloading or filtering to start as soon as it can play.
    /// Calling it again for the same episode cancels.
    func togglePlayWhenReady(_ episode: Episode) {
        if playWhenReadyID == episode.episodeID {
            cancelPlayWhenReady()
            return
        }
        playWhenReadyID = episode.episodeID
        processing.preferredEpisodeID = episode.episodeID
        if processing.isPaused { processing.resumeProcessing() }
        if episode.downloadState == .downloaded { processing.processNow(episode) }
        playWhenReadyTimer?.invalidate()
        playWhenReadyTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPlayWhenReady() }
        }
        checkPlayWhenReady()
    }

    func cancelPlayWhenReady() {
        clearPlayWhenReady()
        keepAlive.stop()
        if episode == nil { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
    }

    private func clearPlayWhenReady() {
        playWhenReadyID = nil
        processing.preferredEpisodeID = nil
        playWhenReadyTimer?.invalidate()
        playWhenReadyTimer = nil
    }

    private func checkPlayWhenReady() {
        guard let id = playWhenReadyID else { return }
        guard let waiting = context.episode(withID: id),
              waiting.downloadState != .notDownloaded, waiting.downloadState != .failed,
              !(waiting.requiresFiltering && waiting.processingState == .failed) else {
            cancelPlayWhenReady()
            return
        }
        guard waiting.downloadState == .downloaded, Self.canPlay(waiting) else {
            if waiting.downloadState == .downloaded, waiting.processingState == .pending,
               processing.activeEpisodeID != id, !processing.isPaused {
                processing.processNow(waiting)
            }
            if isPlaying {
                keepAlive.stop()
            } else {
                keepAlive.start()
                if episode == nil {
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                        MPMediaItemPropertyTitle: waiting.title,
                        MPMediaItemPropertyArtist: "Plays when filtering finishes",
                    ]
                }
            }
            return
        }
        clearPlayWhenReady()
        if isPlaying, let current = episode, current.episodeID != id {
            upNext.insert(id, at: 0)
            keepAlive.stop()
        } else {
            // Start the episode before releasing the silent session so iOS still allows it.
            Task {
                await play(waiting)
                keepAlive.stop()
            }
        }
    }

    // MARK: - Lock screen / Control Center

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
            MainActor.assumeIsolated { self?.skip(by: interval) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            MainActor.assumeIsolated { self?.skip(by: -interval) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            MainActor.assumeIsolated { self?.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let episode else { return }
        let audible = isPlaying && !isWaitingForScan
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.show?.title ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: audible ? Double(rate) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for episode: Episode) {
        let urls = episode.artworkCandidates.compactMap { $0.flatMap(URL.init(string:)) }
        guard !urls.isEmpty else { return }
        let id = episode.episodeID
        Task {
            for url in urls {
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = UIImage(data: data)
                else { continue }
                guard self.episode?.episodeID == id else { return }
                artwork = Self.makeArtwork(image)
                updateNowPlaying()
                return
            }
        }
    }

    /// Must be nonisolated: MediaPlayer calls the request handler off the main thread.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

enum PublisherTranscriptState: Equatable {
    /// Filtered, or the feed doesn't offer a transcript we can read.
    case none
    case loading
    case loaded([TranscriptLine])
    case failed
}

enum SleepTimer: Hashable {
    case minutes(Int)
    case endOfEpisode
}
