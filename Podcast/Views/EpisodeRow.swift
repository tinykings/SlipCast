import SwiftData
import SwiftUI

struct EpisodeRow: View {
    let episode: Episode
    var showArtwork = true
    var showsRemainingTime = true
    var showsDownloadedBadge = false
    /// Puts the show's name above the episode, for lists that mix shows.
    var showsShowTitle = false
    /// Tapping the row opens the show notes and leaves playback to a separate play button.
    var opensShowNotes = false

    @Environment(\.modelContext) private var context
    @Environment(DownloadManager.self) private var downloads
    @Environment(ProcessingQueue.self) private var processing
    @Environment(PlayerController.self) private var player
    @State private var showingNotes = false
    @Query(sort: \MutedTerm.createdAt) private var mutedTerms: [MutedTerm]
    @State private var filteredWordCount: Int?

    /// Processed for muted words, so there's a count to show.
    private var isFiltered: Bool {
        episode.requiresFiltering && episode.downloadState == .downloaded && episode.processingState == .ready
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
            } else {
                episodeContent
            }
            EpisodeActionButton(episode: episode)
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $showingNotes) { ShowNotesView(episode: episode) }
        .listRowBackground(rowBackground)
        .task(id: FilteredCountKey(isFiltered: isFiltered, terms: mutedTerms.map(\.text))) {
            let id = episode.episodeID
            guard isFiltered else {
                FilteredWordCount.forget(episodeID: id)
                filteredWordCount = nil
                return
            }
            let terms = mutedTerms.map(\.text)
            let count = await FilteredWordCount.count(episodeID: id, fileURL: episode.localFileURL, terms: terms)
            if !Task.isCancelled { filteredWordCount = count }
        }
        .contextMenu {
            if episode.downloadState == .downloaded || episode.downloadState == .failed {
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    player.deleteDownloadAndMarkPlayed(episode)
                }
            }
            if episode.requiresFiltering && episode.processingState == .failed {
                Button("Retry Processing", systemImage: "arrow.clockwise") {
                    processing.enqueue(episode, prioritize: true)
                }
            }
            ReprocessButton(episode: episode)
            if episode.downloadState == .queued || episode.downloadState == .downloading {
                Button("Cancel Download", systemImage: "xmark.circle") {
                    if player.isCurrent(episode) { player.stop() }
                    downloads.cancel(episode)
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
                titleText
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(episode.isPlayed ? .tertiary : .primary)
                    .lineLimit(2)
                if isFiltered, let count = filteredWordCount
                    ?? FilteredWordCount.cached(episodeID: episode.episodeID, terms: mutedTerms.map(\.text)) {
                    Label(count == 0 ? "No muted words found"
                            : count == 1 ? "1 muted word filtered" : "\(count) muted words filtered",
                          systemImage: "speaker.slash.fill")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(episode.isPlayed ? .tertiary : .secondary)
                }
                if let status {
                    // Progress text changes many times a second. Fixed-width digits and a
                    // constant two-line height stop it from rewrapping and resizing the row.
                    Text(status)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(statusColor)
                        .lineLimit(2, reservesSpace: statusIsLive)
                }
                if isWaitingToPlay {
                    Label("Plays automatically when ready", systemImage: "play.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 8)
        }
    }

    /// The title, followed by a chevron when tapping the row opens show notes. The chevron is
    /// part of the text so it trails the last line when the title wraps.
    private var titleText: Text {
        guard opensShowNotes, !episode.summary.isEmpty else { return Text(episode.title) }
        let chevron = Text(Image(systemName: "chevron.right"))
            .font(.caption.weight(.bold))
            .foregroundStyle(.tertiary)
        return Text("\(episode.title) \(chevron)")
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
        case (.failed, _): return "Download failed"
        case (.downloaded, _) where !episode.requiresFiltering: return nil
        case (.downloaded, .pending): return "Waiting to process transcript and overlapping voices…"
        case (.downloaded, .processing): return processing.phaseLabel[id] ?? "Processing muted words \(percent(processing.progress[id]))"
        case (.downloaded, .failed): return episode.processingError ?? "Processing failed"
        default: return nil
        }
    }

    /// The status is a progress readout that keeps changing.
    private var statusIsLive: Bool {
        switch (episode.downloadState, episode.processingState) {
        case (.downloading, _): true
        case (.downloaded, .processing): episode.requiresFiltering && !processing.isPaused
        default: false
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

private struct FilteredCountKey: Equatable {
    let isFiltered: Bool
    let terms: [String]
}

/// The round button on the right of an episode row. Episodes that aren't on the device get a
/// download button (downloading never starts playback); downloaded episodes get play/pause.
struct EpisodeActionButton: View {
    let episode: Episode

    @Environment(DownloadManager.self) private var downloads
    @Environment(ProcessingQueue.self) private var processing
    @Environment(PlayerController.self) private var player

    private static let size: CGFloat = 44

    var body: some View {
        control
            .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var control: some View {
        switch episode.downloadState {
        case .notDownloaded, .failed:
            let failed = episode.downloadState == .failed
            Button {
                downloads.download(episode, userInitiated: true)
            } label: {
                Image(systemName: failed ? "arrow.clockwise" : "arrow.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(failed ? Color.red : Color.downloadTint)
                    .circleControl(Self.size)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(failed ? "Retry download" : "Download")
        case .queued, .downloading:
            Button {
                if player.isCurrent(episode) { player.stop() }
                if player.playWhenReadyID == episode.episodeID { player.cancelPlayWhenReady() }
                downloads.cancel(episode)
            } label: {
                ProgressRing(fraction: downloads.progress[episode.episodeID], tint: .downloadTint)
                    .circleControl(Self.size)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Cancel download")
        case .downloaded:
            downloadedControl
        }
    }

    @ViewBuilder
    private var downloadedControl: some View {
        if episode.requiresFiltering && episode.processingState == .failed {
            Button {
                processing.enqueue(episode, prioritize: true)
            } label: {
                Image(systemName: "exclamationmark.arrow.trianglehead.counterclockwise")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.red)
                    .circleControl(Self.size)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Retry scanning")
        } else if player.playWhenReadyID == episode.episodeID {
            // Still being filtered; plays once it's ready.
            Button {
                player.cancelPlayWhenReady()
            } label: {
                ProgressView()
                    .tint(Color.onAccent)
                    .circleControl(Self.size)
            }
            .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
            .accessibilityLabel("Stop waiting to play")
        } else {
            let playing = player.isCurrent(episode) && player.isPlaying
            Button {
                if PlayerController.canPlay(episode) {
                    player.toggle(episode)
                } else {
                    player.togglePlayWhenReady(episode)
                }
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(Color.onAccent)
                    .contentTransition(.symbolEffect(.replace))
                    .circleControl(Self.size)
            }
            .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
            .accessibilityLabel(playing ? "Pause" : "Play")
            .accessibilityHint(PlayerController.canPlay(episode) ? "" : "Plays once it's filtered")
        }
    }
}

/// Redoes an episode's transcript and muted-word scan. Shows nothing unless the episode is
/// downloaded and its show is filtered. For swipe actions and menus.
struct ReprocessButton: View {
    let episode: Episode
    @Environment(PlayerController.self) private var player

    var body: some View {
        if episode.requiresFiltering && episode.downloadState == .downloaded {
            Button("Reprocess", systemImage: "waveform.badge.magnifyingglass") {
                player.reprocess(episode)
            }
            .tint(.indigo)
        }
    }
}

private extension View {
    func circleControl(_ size: CGFloat) -> some View {
        frame(width: size, height: size)
            .contentShape(.circle)
    }
}

extension Color {
    /// Download buttons, distinct from the accent-filled play buttons.
    static let downloadTint = Color.blue
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
