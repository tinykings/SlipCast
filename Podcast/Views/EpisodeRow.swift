import SwiftData
import SwiftUI

struct EpisodeRow: View {
    let episode: Episode
    var showArtwork = true
    var playsOnSelection = false
    var showsRemainingTime = false

    @Environment(\.modelContext) private var context
    @Environment(DownloadManager.self) private var downloads
    @Environment(ProcessingQueue.self) private var processing
    @Environment(PlayerController.self) private var player
    @State private var choosingStreamOrDownload = false

    /// Filtered and still downloading or processing: tapping toggles playing it once it's ready.
    private var offersPlayWhenReady: Bool {
        guard episode.requiresFiltering, !PlayerController.canPlay(episode) else { return false }
        switch episode.downloadState {
        case .queued, .downloading: return true
        case .downloaded: return [.none, .pending, .processing].contains(episode.processingState)
        default: return false
        }
    }

    private var isWaitingToPlay: Bool { player.playWhenReadyID == episode.episodeID }

    /// Filtering off and not on the device yet: tapping asks whether to stream or download.
    private var offersStreamOrDownload: Bool {
        !episode.requiresFiltering && (episode.downloadState == .notDownloaded || episode.downloadState == .failed)
    }

    var body: some View {
        HStack(spacing: 12) {
            if playsOnSelection {
                Button {
                    if offersStreamOrDownload {
                        choosingStreamOrDownload = true
                    } else if PlayerController.canPlay(episode) {
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
                .accessibilityHint(offersStreamOrDownload ? "Choose to stream or download"
                    : PlayerController.canPlay(episode) ? "Plays this episode"
                    : isWaitingToPlay ? "Stops waiting to play this episode"
                    : offersPlayWhenReady ? "Plays this episode automatically when it's ready"
                    : "Downloads and processes this episode before playback")
                .confirmationDialog(episode.title, isPresented: $choosingStreamOrDownload, titleVisibility: .visible) {
                    Button("Stream", systemImage: "play.fill") { Task { await player.play(episode) } }
                    Button("Download", systemImage: "arrow.down.circle") { downloads.download(episode, userInitiated: true) }
                }
            } else {
                episodeContent
            }
            EpisodeActionButton(episode: episode)
        }
        .padding(.vertical, 2)
        .listRowBackground(isWaitingToPlay ? Color.accentColor.opacity(0.18) : nil)
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
                let markAsPlayed = !episode.isPlayed
                if markAsPlayed && AppSettings.autoDeletePlayed {
                    if player.isCurrent(episode) { player.stop() }
                    downloads.deleteDownload(episode)
                }
                episode.isPlayed = markAsPlayed
                episode.playbackPosition = 0
                try? context.save()
            }
        }
    }

    private var episodeContent: some View {
        HStack(spacing: 12) {
            if showArtwork {
                ArtworkView(urlString: episode.artworkURL, size: 48)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(episode.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(episode.isPlayed ? .secondary : .primary)
                    .lineLimit(2)
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                }
                if isWaitingToPlay {
                    Label("Plays automatically when ready · tap to cancel", systemImage: "play.circle.fill")
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

    private var durationLabel: String? {
        let isCurrent = player.isCurrent(episode)
        let duration = isCurrent && player.duration > 0 ? player.duration : episode.duration
        let position = isCurrent ? player.currentTime : episode.playbackPosition
        guard showsRemainingTime, position > 0, let duration, duration > 0 else {
            return Format.duration(duration)
        }
        let remaining = max(0, duration - position)
        return remaining > 0 ? Format.duration(remaining).map { "\($0) left" } : "0 min left"
    }

    private var metadata: String {
        [episode.pubDate?.formatted(date: .abbreviated, time: .omitted), durationLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
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
        case (.failed, _): return "Download failed. Tap to retry."
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
        case .notDownloaded where !episode.requiresFiltering:
            EmptyView() // play streams it; tapping the row offers a download
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
        if episode.requiresFiltering && episode.downloadState != .downloaded {
            EmptyView() // the download control is the only action for an unprepared filtered episode
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
            // Unfiltered shows can stream; filtered shows reach this control only after processing.
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
}
