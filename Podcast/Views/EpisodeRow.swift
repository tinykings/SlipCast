import SwiftData
import SwiftUI

struct EpisodeRow: View {
    let episode: Episode
    var showArtwork = true
    var playsOnSelection = false
    var showsRemainingTime = true
    var showsDownloadedBadge = false
    /// Puts the show's name above the episode, for lists that mix shows.
    var showsShowTitle = false
    /// Tapping the row opens the show notes, shows a short description, and leaves playback to a
    /// separate play button.
    var opensShowNotes = false

    @Environment(\.modelContext) private var context
    @Environment(DownloadManager.self) private var downloads
    @Environment(ProcessingQueue.self) private var processing
    @Environment(PlayerController.self) private var player
    @State private var showingNotes = false

    /// Still downloading (or, when filtered, processing): tapping toggles playing it once it's ready.
    private var offersPlayWhenReady: Bool {
        guard !PlayerController.canPlay(episode) else { return false }
        switch episode.downloadState {
        case .queued, .downloading: return true
        case .downloaded: return [.none, .pending, .processing].contains(episode.processingState)
        default: return false
        }
    }

    private var isWaitingToPlay: Bool { player.playWhenReadyID == episode.episodeID }

    /// Tint episodes queued to play automatically when ready.
    private var rowBackground: Color? {
        isWaitingToPlay ? Color.accentColor.opacity(0.18) : nil
    }

    var body: some View {
        HStack(spacing: 12) {
            if opensShowNotes {
                Button { showingNotes = true } label: {
                    episodeContent
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the episode notes")
            } else if playsOnSelection {
                Button {
                    if PlayerController.canPlay(episode) {
                        Task { await player.play(episode) }
                    } else if offersPlayWhenReady {
                        player.togglePlayWhenReady(episode)
                    } else if episode.downloadState != .downloaded {
                        downloads.download(episode, userInitiated: true)
                    } else {
                        processing.processNow(episode)
                    }
                } label: {
                    episodeContent
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(PlayerController.canPlay(episode) ? "Plays this episode"
                    : isWaitingToPlay ? "Stops waiting to play this episode"
                    : offersPlayWhenReady ? "Plays this episode automatically when it's ready"
                    : episode.requiresFiltering ? "Downloads and processes this episode before playback"
                    : "Downloads this episode")
            } else {
                episodeContent
            }
            EpisodeActionButton(episode: episode, alwaysOffersPlay: opensShowNotes)
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $showingNotes) { ShowNotesView(episode: episode) }
        .listRowBackground(rowBackground)
        .contextMenu {
            if episode.downloadState == .downloaded || episode.downloadState == .failed {
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    if player.isCurrent(episode) { player.stop() }
                    downloads.deleteDownload(episode)
                }
            }
            if episode.requiresFiltering && episode.processingState == .failed {
                Button("Retry Processing", systemImage: "arrow.clockwise") {
                    processing.enqueue(episode, prioritize: true)
                }
            }
            Button(episode.isPlayed ? "Mark as Unplayed" : "Mark as Played", systemImage: "checkmark.circle") {
                EpisodePlayedState.set(!episode.isPlayed, on: [episode], player: player, downloads: downloads, context: context)
            }
        }
    }

    private var episodeContent: some View {
        HStack(spacing: 12) {
            if episode.isPlayed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Played")
            }
            if showArtwork {
                ArtworkView(urlStrings: episode.artworkCandidates, size: 48)
                    .opacity(episode.isPlayed ? 0.5 : 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                if showsShowTitle, let showTitle = episode.show?.title, !showTitle.isEmpty {
                    Text(showTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(episode.isPlayed ? .tertiary : .secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    if showsDownloadedBadge && episode.downloadState == .downloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(episode.isPlayed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                            .accessibilityLabel("Downloaded")
                    }
                    metadata
                        .foregroundStyle(episode.isPlayed ? .tertiary : .secondary)
                }
                .font(.caption)
                Text(episode.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(episode.isPlayed ? .tertiary : .primary)
                    .lineLimit(2)
                if opensShowNotes, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(episode.isPlayed ? .tertiary : .secondary)
                        .lineLimit(3)
                }
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                }
                if isWaitingToPlay {
                    Label(opensShowNotes ? "Plays automatically when ready" : "Plays automatically when ready · tap to cancel",
                          systemImage: "play.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                } else if offersPlayWhenReady && playsOnSelection {
                    Text("Tap to play when ready")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
        }
    }

    /// Plain-text show notes for the row preview. Only the start is needed for three lines.
    private var description: String {
        String(episode.summary.prefix(1500)).strippingHTML
    }

    private var playbackDuration: Double? {
        player.isCurrent(episode) && player.duration > 0 ? player.duration : episode.duration
    }

    private var remainingDuration: Double? {
        let position = player.isCurrent(episode) ? player.currentTime : episode.playbackPosition
        guard showsRemainingTime, !episode.isPlayed, position > 0,
              let duration = playbackDuration, duration > 0 else { return nil }
        return max(0, duration - position)
    }

    private var durationLabel: String? {
        if let remaining = remainingDuration {
            return remaining > 0 ? Format.duration(remaining).map { "\($0) left" } : "0 min left"
        }
        return Format.duration(playbackDuration)
    }

    private var metadata: Text {
        let date = episode.pubDate?.formatted(date: .abbreviated, time: .omitted)
        guard let durationLabel else { return Text(date ?? "") }
        let highlightsRemainingTime = (remainingDuration ?? 0) > 0
        let duration = Text(durationLabel)
            .foregroundColor(highlightsRemainingTime ? .accentColor : nil)
            .fontWeight(highlightsRemainingTime ? .semibold : .regular)
        if let date {
            return Text("\(Text(date + " · "))\(duration)")
        }
        return duration
    }

    private var status: String? {
        let id = episode.episodeID
        if episode.requiresFiltering, episode.downloadState == .downloaded, !episode.isReady, processing.isPaused {
            return "Filtering paused · resume in Downloads"
        }
        switch (episode.downloadState, episode.processingState) {
        case (.queued, _): return "Waiting to download…"
        case (.downloading, _) where episode.requiresFiltering:
            return "Downloading \(percent(downloads.progress[id])) · filtering starts after download"
        case (.downloading, _): return "Downloading \(percent(downloads.progress[id]))"
        case (.failed, _): return opensShowNotes ? "Download failed" : "Download failed. Tap to retry."
        case (.downloaded, _) where !episode.requiresFiltering: return nil
        case (.downloaded, .pending): return "Waiting to process transcript and overlapping voices…"
        case (.downloaded, .processing): return processing.phaseLabel[id] ?? "Processing muted words \(percent(processing.progress[id]))"
        case (.downloaded, .failed): return episode.processingError ?? "Processing failed"
        default: return nil
        }
    }

    private var statusColor: Color {
        switch (episode.downloadState, episode.processingState) {
        case (.failed, _), (_, .failed): .red
        default: .secondary
        }
    }

    private func percent(_ value: Double?) -> String {
        "\(Int((value ?? 0) * 100))%"
    }
}

struct EpisodeActionButton: View {
    let episode: Episode
    /// Shows a play button even before the episode is ready; tapping it downloads (or processes)
    /// the episode and plays it once ready.
    var alwaysOffersPlay = false

    @Environment(DownloadManager.self) private var downloads
    @Environment(ProcessingQueue.self) private var processing
    @Environment(PlayerController.self) private var player

    var body: some View {
        HStack(spacing: 14) {
            downloadControl
            playControl
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var downloadControl: some View {
        switch episode.downloadState {
        case .notDownloaded, .failed:
            Button {
                downloads.download(episode, userInitiated: true)
            } label: {
                Image(systemName: episode.downloadState == .failed ? "arrow.clockwise" : "arrow.down.circle")
                    .font(.title3)
            }
            .tint(episode.downloadState == .failed ? .red : .secondary)
            .accessibilityLabel(episode.downloadState == .failed ? "Retry download" : "Download")
        case .queued, .downloading:
            Button {
                if player.isCurrent(episode) { player.stop() }
                downloads.cancel(episode)
            } label: {
                ProgressRing(fraction: downloads.progress[episode.episodeID])
            }
            .accessibilityLabel("Cancel download")
        case .downloaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private var playControl: some View {
        if alwaysOffersPlay && !PlayerController.canPlay(episode)
            && !(episode.requiresFiltering && episode.processingState == .failed) {
            playWhenReadyControl
        } else if episode.downloadState != .downloaded {
            EmptyView() // the download control is the only action until the episode is on the device
        } else if episode.requiresFiltering && (episode.processingState == .pending || episode.processingState == .processing || episode.processingState == .none) {
            ProgressView().accessibilityLabel("Preparing filtered download")
        } else if episode.requiresFiltering && episode.processingState == .failed {
            Button {
                processing.enqueue(episode, prioritize: true)
            } label: {
                Image(systemName: "exclamationmark.arrow.trianglehead.counterclockwise").font(.title3)
            }
            .tint(.red)
            .accessibilityLabel("Retry scanning")
        } else {
            let playing = player.isCurrent(episode) && player.isPlaying
            Button {
                player.toggle(episode)
            } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
                    .accentCircleSymbol()
            }
            .accessibilityLabel(playing ? "Pause" : "Play")
        }
    }

    @ViewBuilder
    private var playWhenReadyControl: some View {
        if player.playWhenReadyID == episode.episodeID {
            Button {
                player.cancelPlayWhenReady()
            } label: {
                ProgressView()
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel("Stop waiting to play")
        } else {
            Button {
                if episode.downloadState == .notDownloaded || episode.downloadState == .failed {
                    downloads.download(episode, userInitiated: true)
                }
                player.togglePlayWhenReady(episode)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .accentCircleSymbol()
            }
            .accessibilityLabel("Play")
            .accessibilityHint(episode.downloadState == .downloaded ? "Plays once it's processed" : "Downloads and plays it")
        }
    }
}

/// Marks episodes played or unplayed, resetting their position and, when marking played with
/// auto-delete on, removing their downloads.
@MainActor
enum EpisodePlayedState {
    static func set(
        _ played: Bool,
        on episodes: some Sequence<Episode>,
        player: PlayerController,
        downloads: DownloadManager,
        context: ModelContext
    ) {
        for episode in episodes where episode.isPlayed != played {
            if played && AppSettings.autoDeletePlayed {
                if player.isCurrent(episode) { player.stop() }
                downloads.deleteDownload(episode)
            }
            episode.isPlayed = played
            episode.playbackPosition = 0
        }
        try? context.save()
    }
}
