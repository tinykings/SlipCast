import SwiftData
import SwiftUI

struct ShowDetailView: View {
    @Bindable var show: Show
    @Environment(FeedService.self) private var feeds
    @Environment(\.modelContext) private var context
    @Environment(PlayerController.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnsubscribe = false

    private static let recentCount = 25

    var body: some View {
        let episodes = show.sortedEpisodes
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 6) {
                        ArtworkView(urlStrings: show.artworkCandidates, size: 110, cornerRadius: 12)
                        if show.isExplicit { ExplicitBadge() }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(show.title).font(.title3.bold())
                        Text(show.author).font(.subheadline).foregroundStyle(.secondary)
                        Button("Unsubscribe", role: .destructive) { confirmingUnsubscribe = true }
                            .buttonStyle(.bordered)
                            .padding(.top, 6)
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

            Section {
                Toggle("Filter muted words", isOn: $show.filteringEnabled)
                    .disabled(!DeviceSupport.transcriptionAvailable && !show.filteringEnabled)
                    .onChange(of: show.filteringEnabled) {
                        try? context.save()
                        player.filteringChanged(for: show)
                    }
            } footer: {
                if !DeviceSupport.transcriptionAvailable {
                    Text("Filtering isn't supported on this device.")
                } else if show.filteringEnabled {
                    Text("Episode download required to filter")
                }
            }

            Section {
                ShowEpisodeRows(episodes: Array(episodes.prefix(Self.recentCount)))
                if episodes.count > Self.recentCount {
                    NavigationLink {
                        OlderEpisodesView(title: show.title, episodes: Array(episodes.dropFirst(Self.recentCount)))
                    } label: {
                        Label("Older Episodes (\(episodes.count - Self.recentCount))", systemImage: "clock.arrow.circlepath")
                    }
                }
            } header: {
                HStack {
                    Text("Episodes")
                    Spacer()
                    if !episodes.isEmpty {
                        let markAsPlayed = !show.isFullyPlayed
                        Button(markAsPlayed ? "Mark All as Played" : "Mark All as Unplayed") {
                            EpisodePlayedState.set(markAsPlayed, on: show.episodes, player: player, downloads: downloads, context: context)
                        }
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await feeds.refreshAll() }
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

/// Episodes beyond the most recent ones on the show page, one year at a time.
private struct OlderEpisodesView: View {
    let title: String
    let episodes: [Episode]

    /// nil selects episodes without a publish date.
    @State private var selectedYear: Int??

    private static func year(of episode: Episode) -> Int? {
        episode.pubDate.map { Calendar.current.component(.year, from: $0) }
    }

    /// Newest year first, with undated episodes last.
    private var years: [Int?] {
        let all = Set(episodes.map(Self.year))
        return all.compactMap { $0 }.sorted(by: >) + (all.contains(nil) ? [nil] : [])
    }

    private var currentYear: Int? {
        selectedYear ?? years.first ?? nil
    }

    var body: some View {
        let shown = episodes.filter { Self.year(of: $0) == currentYear }
        List {
            Section {
                ShowEpisodeRows(episodes: shown)
            } header: {
                Text("\(shown.count) episode\(shown.count == 1 ? "" : "s")")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Older Episodes")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if years.count > 1 { yearPicker }
        }
    }

    private var yearPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(years, id: \.self) { year in
                        let isSelected = year == currentYear
                        Button {
                            selectedYear = .some(year)
                        } label: {
                            Text(year.map(String.init) ?? "Undated")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.tertiary), in: .capsule)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .id(year)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.bar)
            .onChange(of: currentYear) { _, year in
                withAnimation { proxy.scrollTo(year, anchor: .center) }
            }
        }
    }
}

/// Show-page episode rows: tapping opens the show notes, the play button plays, swiping deletes a download
/// or, for an episode that isn't downloaded, marks it played.
private struct ShowEpisodeRows: View {
    let episodes: [Episode]
    @Environment(DownloadManager.self) private var downloads
    @Environment(PlayerController.self) private var player
    @Environment(\.modelContext) private var context

    var body: some View {
        ForEach(episodes) { episode in
            EpisodeRow(episode: episode, showArtwork: false, showsDownloadedBadge: true, opensShowNotes: true)
                .swipeActions(edge: .trailing) {
                    if episode.downloadState == .downloaded || episode.downloadState == .failed {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            if player.isCurrent(episode) { player.stop() }
                            downloads.deleteDownload(episode)
                        }
                    } else if episode.downloadState == .notDownloaded {
                        Button(episode.isPlayed ? "Unplayed" : "Played",
                               systemImage: episode.isPlayed ? "circle" : "checkmark.circle") {
                            EpisodePlayedState.set(!episode.isPlayed, on: [episode], player: player, downloads: downloads, context: context)
                        }
                        .tint(.accentColor)
                    }
                }
        }
    }
}

struct ExplicitBadge: View {
    var body: some View {
        Label("Explicit", systemImage: "e.square.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Explicit")
    }
}
