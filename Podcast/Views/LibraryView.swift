import SwiftData
import SwiftUI

enum LibrarySort: String, CaseIterable, Identifiable {
    case name
    case newest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .newest: "Newest Episode"
        }
    }
}

struct LibraryView: View {
    @Query private var shows: [Show]
    @Environment(FeedService.self) private var feeds
    @AppStorage("librarySort") private var sort: LibrarySort = .name

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    private var sortedShows: [Show] {
        switch sort {
        case .name:
            shows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .newest:
            shows.sorted { ($0.newestEpisodeDate ?? .distantPast) > ($1.newestEpisodeDate ?? .distantPast) }
        }
    }

    var body: some View {
        Group {
            if shows.isEmpty {
                ContentUnavailableView(
                    "No Podcasts Yet",
                    systemImage: "mic",
                    description: Text("Use Search to find podcasts and subscribe.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(sortedShows) { show in
                            NavigationLink(value: show) {
                                ShowTile(show: show)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
                .refreshable { await feeds.refreshAll() }
            }
        }
        .tabTitle("Library")
        .navigationDestination(for: Show.self) { ShowDetailView(show: $0) }
        .toolbar {
            if !shows.isEmpty {
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
    }
}

private struct ShowTile: View {
    let show: Show

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkView(urlString: show.artworkURL, size: 150, cornerRadius: 12)
                .padding(.bottom, 2)
            Text(show.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
            if let date = show.newestEpisodeDate {
                Text(date, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 150, alignment: .leading)
    }
}
