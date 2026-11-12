import AVFoundation
import MediaPlayer
import Observation
import SwiftData
import UIKit

/// Plays downloaded episodes and silences muted words with a real-time audio tap. The audio file
/// is never modified; changing the mute list just updates the tap, even mid-episode.
///
/// Episodes that aren't downloaded yet are played while they download (`StreamingSession`).
/// Episodes can play while they're still being scanned. Playback (and seeking) is held behind
/// the scanned point, like a streaming buffer, and the tap silences anything past it as a backstop.
@Observable
final class PlayerController {
    private(set) var episode: Episode?
    /// The user wants audio playing (it may be briefly held while scanning catches up).
    private(set) var isPlaying = false
    /// Playback caught up with scanning and is waiting for it to get ahead again.
    private(set) var isWaitingForScan = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var mutedSpotCount = 0
    /// Seconds of the episode scanned for muted words. `.infinity` once fully scanned.
    private(set) var scannedThrough: Double = 0
    private(set) var scanError: String?
    /// Episodes queued by Play All, played in order after the current one.
    private(set) var upNext: [String] = []

    var rate: Float = 1 {
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
    /// Keeps the play-while-downloading session alive (the resource loader holds it weakly).
    @ObservationIgnored private var stream: StreamingSession?
    @ObservationIgnored private let timeline = MuteTimeline()
    @ObservationIgnored private var words: [TranscriptWord] = []
    @ObservationIgnored private var muteRefreshPending = false
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSavedPosition: Double = 0
    @ObservationIgnored private var artwork: MPMediaItemArtwork?

    /// Keep playback this far behind the scanned point (covers the 0.5s tick at high speeds).
    private let safetyMargin = 2.0
    /// How far scanning must be ahead before starting or resuming playback.
    private let startBuffer = 12.0

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

    /// Anything can play except an episode whose scan failed.
    static func canPlay(_ episode: Episode) -> Bool {
        episode.processingState != .failed
    }

    /// True while the current episode is still downloading.
    var isDownloading: Bool {
        guard let episode else { return false }
        return episode.downloadState != .downloaded
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
        player.pause()
        isPlaying = false
        self.episode = episode
        artwork = nil
        isWaitingForScan = false
        scanError = nil

        let asset: AVURLAsset
        if episode.downloadState == .downloaded, let url = episode.localFileURL {
            stream = nil
            asset = AVURLAsset(url: url)
            if episode.processingState != .ready { processing.processNow(episode) }
        } else if let session = downloads.stream(episode) {
            stream = session  // downloads, plays and scans at the same time
            asset = session.asset
        } else {
            scanError = "Couldn't start downloading this episode."
            return
        }
        loadScanState(for: episode)
        applyMuting()

        let item = AVPlayerItem(asset: asset)
        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            item.audioMix = MuteTap.makeAudioMix(track: track, timeline: timeline)
        }
        guard item.audioMix != nil else {
            // Without the tap nothing would be muted, so refuse to play.
            scanError = "Couldn't set up muting for this episode."
            return
        }
        player.replaceCurrentItem(with: item)
        observeEnd(of: item)

        // The feed's duration is available instantly; the real one may need data that's still downloading.
        duration = episode.duration ?? 0
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
        updateNowPlaying()
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), playableLimit)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        updatePlaybackGate()
        updateNowPlaying()
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    /// Stops playback and clears the player (e.g. when the current episode's file is deleted).
    func stop() {
        savePosition()
        player.pause()
        player.replaceCurrentItem(with: nil)
        stream = nil
        upNext = []
        episode = nil
        isPlaying = false
        isWaitingForScan = false
        words = []
        scannedThrough = 0
        mutedSpotCount = 0
        timeline.update(MuteSnapshot())
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Call after the mute list or padding changes.
    func refreshMuting() {
        applyMuting()
    }

    // MARK: - Scanning

    private func loadScanState(for episode: Episode) {
        if episode.processingState == .ready {
            words = (try? TranscriptStore.load(episodeID: episode.episodeID)) ?? []
            scannedThrough = .infinity
        } else if processing.activeEpisodeID == episode.episodeID {
            words = processing.liveWords
            scannedThrough = processing.liveScannedThrough
        } else {
            words = []
            scannedThrough = 0
        }
    }

    private func scanProgressed(_ id: String) {
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
        guard let episode, episode.episodeID == id else { return }
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
        let terms = (try? context.fetch(FetchDescriptor<MutedTerm>())) ?? []
        let padding = AppSettings.padding
        let ranges = MuteMatcher.muteRanges(in: words, rules: terms.map(\.rule), padding: padding)
        mutedSpotCount = ranges.count
        // A word just past the scanned point could have padding reaching back before it.
        let scannedUntil = isFullyScanned ? Double.infinity : scannedThrough - padding - MuteTap.fade
        timeline.update(MuteSnapshot(ranges: ranges, scannedUntil: scannedUntil))
        updatePlaybackGate()
    }

    /// Starts, holds or resumes the player depending on how far ahead scanning is.
    private func updatePlaybackGate() {
        guard isPlaying, player.currentItem != nil else { return }
        let ahead = isFullyScanned ? Double.infinity : playableLimit - currentTime
        let needed = min(startBuffer, max(0, duration - safetyMargin - currentTime))

        if player.timeControlStatus == .paused {
            if ahead >= needed && (isFullyScanned || ahead > 0) {
                isWaitingForScan = false
                try? AVAudioSession.sharedInstance().setActive(true)
                player.playImmediately(atRate: rate)
            } else {
                isWaitingForScan = true
            }
        } else if ahead <= 0 {
            player.pause()
            isWaitingForScan = true
        }
        updateNowPlaying()
    }

    // MARK: - Progress

    private func tick(_ seconds: Double) {
        guard episode != nil, seconds.isFinite else { return }
        currentTime = seconds
        if !isWaitingForScan && isPlaying && player.timeControlStatus == .paused && player.rate == 0 {
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
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinish() }
        }
    }

    private func didFinish() {
        guard let episode else { return }
        episode.isPlayed = true
        episode.playbackPosition = 0
        currentTime = 0
        isPlaying = false
        isWaitingForScan = false
        try? context.save()
        updateNowPlaying()
        playNextInQueue()
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
        guard let string = episode.artworkURL, let url = URL(string: string) else { return }
        let id = episode.episodeID
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  self.episode?.episodeID == id
            else { return }
            artwork = Self.makeArtwork(image)
            updateNowPlaying()
        }
    }

    /// Must be nonisolated: MediaPlayer calls the request handler off the main thread.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
