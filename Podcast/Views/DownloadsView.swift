import SwiftData
import SwiftUI

struct DownloadsView: View {
    @Query(
        filter: #Predicate<Episode> { $0.downloadStateRaw != "notDownloaded" },
        sort: \Episode.downloadedAt,
        order: .reverse
    )
    private var episodes: [Episode]

    @Environment(ProcessingQueue.self) private var processing
    @Environment(DownloadManager.self) private var downloads
    @Environment(PlayerController.self) private var player
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.autoPlayNextKey) private var autoPlayNext = true

    private var inProgress: [Episode] {
        episodes.filter(\.isInProgress)
    }

    private var problems: [Episode] {
        episodes.filter { $0.downloadState == .failed || ($0.requiresFiltering && $0.processingState == .failed) }
    }

    private var ready: [Episode] { Episode.downloadsOrder(episodes) }

    var body: some View {
        List {
            if !inProgress.isEmpty {
                Section {
                    ForEach(inProgress) { row($0) }
                } header: {
                    HStack {
                        Text("In Progress")
                        Spacer()
                        if processing.hasPendingWork || processing.isPaused {
                            Button {
                                if processing.isPaused { processing.resumeProcessing() }
                                else { processing.pauseProcessing() }
                            } label: {
                                Label(processing.isPaused ? "Resume" : "Pause",
                                      systemImage: processing.isPaused ? "play.fill" : "pause.fill")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .textCase(nil)
                            .accessibilityLabel(processing.isPaused ? "Resume filtering" : "Pause filtering")
                        }
                    }
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
                        .onMove(perform: move)
                } header: {
                    HStack(spacing: 12) {
                        Toggle("Auto play", isOn: $autoPlayNext)
                            .toggleStyle(.switch)
                            .labelsHidden()
                        Text("Auto play")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .accessibilityHidden(true)
                        Spacer(minLength: 8)
                        if ready.count > 1 {
                            Text("Hold and drag to reorder episodes")
                                .font(.caption)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .textCase(nil)
                }
            }
        }
        .overlay {
            if episodes.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Downloaded episodes appear here. Enable filtering in a show’s settings to prepare its downloads for muted-word playback.")
                )
            }
        }
        .tabTitle("Downloads", detail: episodes.isEmpty ? nil : Format.bytes(Storage.bytesUsed))
    }

    /// Saves the new order for every ready episode; later downloads appear above them.
    private func move(from source: IndexSet, to destination: Int) {
        var ordered = ready
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, episode) in ordered.enumerated() where episode.queueOrder != Double(index) {
            episode.queueOrder = Double(index)
        }
        try? context.save()
    }

    private func row(_ episode: Episode) -> some View {
        EpisodeRow(episode: episode, showsRemainingTime: true, showsShowTitle: true, opensShowNotes: true)
            .swipeActions {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    if player.isCurrent(episode) { player.stop() }
                    downloads.deleteDownload(episode)
                }
                ReprocessButton(episode: episode)
            }
    }
}
