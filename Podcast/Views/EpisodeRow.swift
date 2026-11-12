import SwiftUI

struct EpisodeRow: View {
    let episode: Episode
    var showArtwork = true

    @Environment(DownloadManager.self) private var downloads
    @Environment(ProcessingQueue.self) private var processing
    @Environment(PlayerController.self) private var player

    var body: some View {
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
            }
            Spacer(minLength: 8)
            EpisodeActionButton(episode: episode)
        }
        .padding(.vertical, 2)
        .contextMenu {
            if episode.downloadState == .downloaded || episode.downloadState == .failed {
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    if player.isCurrent(episode) { player.stop() }
                    downloads.deleteDownload(episode)
                }
            }
            if episode.processingState == .failed {
                Button("Retry Processing", systemImage: "arrow.clockwise") {
                    processing.enqueue(episode, prioritize: true)
                }
            }
            Button(episode.isPlayed ? "Mark as Unplayed" : "Mark as Played", systemImage: "checkmark.circle") {
                episode.isPlayed.toggle()
                episode.playbackPosition = 0
            }
        }
    }

    private var metadata: String {
        [episode.pubDate?.formatted(date: .abbreviated, time: .omitted), Format.duration(episode.duration)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var status: String? {
        let id = episode.episodeID
        switch (episode.downloadState, episode.processingState) {
        case (.queued, _): return "Waiting to download…"
        case (.downloading, .processing):
            return "Downloading \(percent(downloads.progress[id])) · scanning as it plays"
        case (.downloading, _): return "Downloading \(percent(downloads.progress[id]))"
        case (.failed, _): return "Download failed. Tap to retry."
        case (.downloaded, .pending): return "Ready to play · will scan for muted words as it plays"
        case (.downloaded, .processing): return "Scanning for muted words \(percent(processing.progress[id])) · ready to play"
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
        if episode.processingState == .failed {
            Button {
                processing.enqueue(episode, prioritize: true)
            } label: {
                Image(systemName: "exclamationmark.arrow.trianglehead.counterclockwise").font(.title3)
            }
            .tint(.red)
            .accessibilityLabel("Retry scanning")
        } else {
            // Playable before download/scan finish: the player stays behind the scanned point.
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
