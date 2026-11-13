import SwiftData
import SwiftUI

/// Preview of a directory podcast before subscribing.
struct DirectoryShowView: View {
    let podcast: DirectoryPodcast

    @Environment(FeedService.self) private var feeds
    @Query private var subscribed: [Show]
    @State private var feed: ParsedFeed?
    @State private var errorMessage: String?
    @State private var isSubscribing = false

    init(podcast: DirectoryPodcast) {
        self.podcast = podcast
        let feedURL = podcast.feedURL ?? ""
        _subscribed = Query(filter: #Predicate<Show> { $0.feedURL == feedURL })
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 6) {
                        ArtworkView(urlString: podcast.artworkURL, size: 110, cornerRadius: 12)
                        if feed?.isExplicit == true { ExplicitBadge() }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(podcast.title).font(.title3.bold())
                        Text(podcast.author).font(.subheadline).foregroundStyle(.secondary)
                        subscribeButton.padding(.top, 6)
                    }
                }
                if let summary = feed?.summary, !summary.isEmpty {
                    Text(summary.strippingHTML)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }

            if let feed {
                Section("Recent Episodes") {
                    ForEach(feed.episodes.prefix(25), id: \.guid) { episode in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                [episode.pubDate?.formatted(date: .abbreviated, time: .omitted),
                                 Format.duration(episode.duration)]
                                    .compactMap { $0 }.joined(separator: " · ")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            Text(episode.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        }
                    }
                }
            } else if errorMessage == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private var subscribeButton: some View {
        if !subscribed.isEmpty {
            Label("Subscribed", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        } else if isSubscribing {
            ProgressView()
        } else {
            Button("Subscribe") { Task { await subscribe() } }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Color.onAccent)
                .disabled(podcast.feedURL == nil)
        }
    }

    private func load() async {
        guard feed == nil else { return }
        guard let feedURL = podcast.feedURL else {
            errorMessage = "This podcast doesn't have a public RSS feed."
            return
        }
        do {
            feed = try await FeedService.fetchFeed(feedURL)
        } catch {
            errorMessage = "Couldn't load episodes: \(error.localizedDescription)"
        }
    }

    private func subscribe() async {
        guard let feedURL = podcast.feedURL else { return }
        isSubscribing = true
        defer { isSubscribing = false }
        do {
            try await feeds.subscribe(feedURL: feedURL, feed: feed, fallbackArtwork: podcast.artworkURL)
        } catch {
            errorMessage = "Couldn't subscribe: \(error.localizedDescription)"
        }
    }
}
