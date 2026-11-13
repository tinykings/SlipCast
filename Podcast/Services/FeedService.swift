import Foundation
import Observation
import SwiftData

/// Subscribing, unsubscribing and refreshing feeds.
@Observable
final class FeedService {
    private(set) var isRefreshing = false

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let downloads: DownloadManager

    /// Max new episodes auto-downloaded per show in one refresh (avoids pulling a back catalog).
    private let autoDownloadLimit = 2

    init(context: ModelContext, downloads: DownloadManager) {
        self.context = context
        self.downloads = downloads
    }

    @concurrent
    nonisolated static func fetchFeed(_ feedURL: String) async throws -> ParsedFeed {
        guard let url = URL(string: feedURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try FeedParser.parse(data)
    }

    func isSubscribed(_ feedURL: String) -> Bool {
        context.show(withFeedURL: feedURL) != nil
    }

    @discardableResult
    func subscribe(feedURL: String, feed: ParsedFeed? = nil, fallbackArtwork: String? = nil) async throws -> Show {
        if let existing = context.show(withFeedURL: feedURL) { return existing }

        let parsed: ParsedFeed
        if let feed { parsed = feed } else { parsed = try await Self.fetchFeed(feedURL) }

        let show = Show(
            feedURL: feedURL,
            title: parsed.title,
            author: parsed.author,
            summary: parsed.summary,
            artworkURL: parsed.artworkURL ?? fallbackArtwork,
            language: parsed.language,
            autoDownload: AppSettings.autoDownloadNew
        )
        show.isExplicit = parsed.isExplicit ?? false
        show.filteringEnabled = show.isExplicit && DeviceSupport.transcriptionAvailable
        context.insert(show)
        apply(parsed, to: show)
        try? context.save()

        // Grab the latest episode so there's something ready to play.
        if show.autoDownload, let latest = show.sortedEpisodes.first {
            downloads.download(latest, userInitiated: true)
        }
        return show
    }

    func unsubscribe(_ show: Show) {
        for episode in show.episodes where episode.downloadState != .notDownloaded {
            downloads.deleteDownload(episode)
        }
        context.delete(show)
        try? context.save()
    }

    /// Refreshes on app open if it's been a while.
    func refreshIfStale() async {
        let shows = (try? context.fetch(FetchDescriptor<Show>())) ?? []
        let oldest = shows.compactMap(\.lastRefreshed).min() ?? .distantPast
        if Date.now.timeIntervalSince(oldest) > 15 * 60 { await refreshAll() }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let shows = (try? context.fetch(FetchDescriptor<Show>())) ?? []
        let feedURLs = shows.map(\.feedURL)

        let results = await withTaskGroup(of: (String, ParsedFeed?).self) { group in
            for url in feedURLs {
                group.addTask { (url, try? await Self.fetchFeed(url)) }
            }
            var collected: [String: ParsedFeed] = [:]
            for await (url, feed) in group {
                if let feed { collected[url] = feed }
            }
            return collected
        }
        guard !Task.isCancelled else { return }

        for show in shows {
            guard let feed = results[show.feedURL] else { continue }
            let newEpisodes = apply(feed, to: show)
            guard show.autoDownload else { continue }
            let toDownload = newEpisodes
                .filter { ($0.pubDate ?? .distantPast) > show.subscribedAt.addingTimeInterval(-7 * 86_400) }
                .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
                .prefix(autoDownloadLimit)
            for episode in toDownload {
                downloads.download(episode, userInitiated: false)
            }
        }
        try? context.save()
    }

    /// Updates show metadata and inserts episodes we haven't seen. Returns the new ones.
    @discardableResult
    private func apply(_ feed: ParsedFeed, to show: Show) -> [Episode] {
        if !feed.title.isEmpty { show.title = feed.title }
        if !feed.author.isEmpty { show.author = feed.author }
        if !feed.summary.isEmpty { show.summary = feed.summary }
        if let artwork = feed.artworkURL { show.artworkURL = artwork }
        if let language = feed.language { show.language = language }
        if let explicit = feed.isExplicit { show.isExplicit = explicit }
        if let newest = feed.episodes.compactMap(\.pubDate).max(),
           newest > (show.latestEpisodeDate ?? .distantPast) {
            show.latestEpisodeDate = newest
        }

        var known = Set(show.episodes.map(\.guid))
        var inserted: [Episode] = []
        for item in feed.episodes where !known.contains(item.guid) {
            known.insert(item.guid)
            let episode = Episode(
                episodeID: Storage.episodeID(feedURL: show.feedURL, guid: item.guid),
                guid: item.guid,
                title: item.title,
                summary: item.summary,
                pubDate: item.pubDate,
                duration: item.duration,
                audioURL: item.audioURL,
                imageURL: item.imageURL
            )
            context.insert(episode)
            episode.show = show
            inserted.append(episode)
        }
        show.lastRefreshed = .now
        return inserted
    }
}
