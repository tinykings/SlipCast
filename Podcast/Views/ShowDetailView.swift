import SwiftData
import SwiftUI

struct ShowDetailView: View {
    @Bindable var show: Show
    @Environment(FeedService.self) private var feeds
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnsubscribe = false

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    ArtworkView(urlString: show.artworkURL, size: 110, cornerRadius: 12)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(show.title).font(.title3.bold())
                        Text(show.author).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if !show.summary.isEmpty {
                    Text(show.summary.strippingHTML)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                Toggle("Auto-download new episodes", isOn: $show.autoDownload)
            }

            Section("Episodes") {
                ForEach(show.sortedEpisodes) { episode in
                    EpisodeRow(episode: episode, showArtwork: false)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await feeds.refreshAll() }
        .toolbar {
            Menu {
                Button("Unsubscribe", systemImage: "minus.circle", role: .destructive) {
                    confirmingUnsubscribe = true
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
        .confirmationDialog(
            "Unsubscribe from \(show.title)?",
            isPresented: $confirmingUnsubscribe,
            titleVisibility: .visible
        ) {
            Button("Unsubscribe and Delete Downloads", role: .destructive) {
                if let current = player.episode, current.show?.feedURL == show.feedURL { player.stop() }
                feeds.unsubscribe(show)
                dismiss()
            }
        }
    }
}
