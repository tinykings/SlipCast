import SwiftData
import SwiftUI

struct DownloadsView: View {
    @Query(
        filter: #Predicate<Episode> { $0.downloadStateRaw != "notDownloaded" },
        sort: \Episode.downloadedAt,
        order: .reverse
    )
    private var episodes: [Episode]

    @Environment(DownloadManager.self) private var downloads
    @Environment(PlayerController.self) private var player

    private var inProgress: [Episode] {
        episodes.filter(\.isInProgress)
    }

    private var problems: [Episode] {
        episodes.filter { $0.downloadState == .failed || $0.processingState == .failed }
    }

    private var ready: [Episode] {
        episodes.filter(\.isReady)
    }

    /// Downloaded episodes in the order shown (scanning ones first, then ready).
    private var playAllEpisodes: [Episode] {
        (inProgress + ready).filter { $0.downloadState == .downloaded && $0.processingState != .failed }
    }

    var body: some View {
        List {
            if !inProgress.isEmpty {
                Section("In Progress") {
                    ForEach(inProgress) { row($0) }
                }
            }
            if !problems.isEmpty {
                Section("Needs Attention") {
                    ForEach(problems) { row($0) }
                }
            }
            if !ready.isEmpty {
                Section {
                    ForEach(ready) { row($0) }
                } header: {
                    Text("Ready to Play")
                } footer: {
                    Text("Using \(Format.bytes(Storage.bytesUsed)) of storage.")
                }
            }
        }
        .overlay {
            if episodes.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Downloaded episodes appear here. Muted words are scanned for as they download.")
                )
            }
        }
        .tabTitle("Downloads")
        .toolbar {
            if !playAllEpisodes.isEmpty {
                Button {
                    player.playAll(playAllEpisodes)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Play All")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
                }
                .accessibilityLabel("Play All")
            }
        }
    }

    private func row(_ episode: Episode) -> some View {
        EpisodeRow(episode: episode)
            .swipeActions {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    if player.isCurrent(episode) { player.stop() }
                    downloads.deleteDownload(episode)
                }
            }
    }
}
