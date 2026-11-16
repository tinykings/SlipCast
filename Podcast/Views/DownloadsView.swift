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
    @State private var editMode = EditMode.inactive

    private var inProgress: [Episode] {
        episodes.filter(\.isInProgress)
    }

    private var problems: [Episode] {
        episodes.filter { $0.downloadState == .failed || ($0.requiresFiltering && $0.processingState == .failed) }
    }

    /// In the user's order, then anything they haven't placed yet (newest first).
    private var ready: [Episode] {
        let ready = episodes.filter(\.isReady)
        let placed = ready.filter { $0.queueOrder != nil }.sorted { ($0.queueOrder ?? 0) < ($1.queueOrder ?? 0) }
        return placed + ready.filter { $0.queueOrder == nil }
    }

    /// Play All follows the order of the ready list.
    private var playAllEpisodes: [Episode] {
        ready.filter(PlayerController.canPlay)
    }

    private var isReordering: Bool { editMode.isEditing }

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
                    HStack(spacing: 16) {
                        Spacer()
                        if ready.count > 1 {
                            Button {
                                withAnimation { editMode = isReordering ? .inactive : .active }
                            } label: {
                                Label(isReordering ? "Done" : "Reorder",
                                      systemImage: isReordering ? "checkmark" : "arrow.up.arrow.down")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .textCase(nil)
                        }
                        if !playAllEpisodes.isEmpty && !isReordering {
                            Button {
                                player.playAll(playAllEpisodes)
                            } label: {
                                Label("Play All", systemImage: "play.fill")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .textCase(nil)
                        }
                    }
                } footer: {
                    if isReordering {
                        Text("Drag episodes into the order Play All should play them.")
                    }
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
        .environment(\.editMode, $editMode)
        .onChange(of: ready.count) { _, count in
            if count < 2 { editMode = .inactive }
        }
        .tabTitle("Downloads", detail: episodes.isEmpty ? nil : Format.bytes(Storage.bytesUsed))
    }

    /// Saves the new order for every ready episode, so later downloads go after them.
    private func move(from source: IndexSet, to destination: Int) {
        var ordered = ready
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, episode) in ordered.enumerated() where episode.queueOrder != Double(index) {
            episode.queueOrder = Double(index)
        }
        try? context.save()
        player.reorderUpNext(ordered.map(\.episodeID))
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
