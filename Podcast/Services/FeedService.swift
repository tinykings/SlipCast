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
    /// Feeds fetched at once during a refresh.
    private static let maxConcurrentFetches = 6
    /// When `refreshAll` last ran in this session, whether or not every feed loaded.
    @ObservationIgnored private var lastRefreshAttempt: Date?

    init(context: ModelContext, downloads: DownloadManager) {
        self.context = context
        self.downloads = downloads
    }

    nonisolated static func fetchFeed(_ feedURL: String) async throws -> ParsedFeed {
        guard case .feed(let feed, _, _) = try await fetchFeed(feedURL, etag: nil, lastModified: nil) else {
            throw URLError(.badServerResponse)
        }
        return feed
    }

    /// Downloads and parses a feed, or reports `.notModified` when the server says it hasn't
    /// changed since the validators from the last download.
    @concurrent
    nonisolated static func fetchFeed(_ feedURL: String, etag: String?, lastModified: String?) async throws -> FeedFetchResult {
        guard let url = URL(string: feedURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 304 { return .notModified }
        if let http, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return .feed(try FeedParser.parse(data),
                     etag: http?.value(forHTTPHeaderField: "ETag"),
                     lastModified: http?.value(forHTTPHeaderField: "Last-Modified"))
    }

    func isSubscribed(_ feedURL: String) -> Bool {
        context.show(withFeedURL: feedURL) != nil
    }

    @discardableResult
    func subscribe(
        feedURL: String,
        feed: ParsedFeed? = nil,
        fallbackArtwork: String? = nil,
        directoryID: Int? = nil
    ) async throws -> Show {
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
        show.directoryArtworkURL = fallbackArtwork
        show.directoryID = directoryID
        show.isExplicit = parsed.isExplicit ?? false
        show.filteringEnabled = show.isExplicit && DeviceSupport.transcriptionAvailable
        context.insert(show)
        apply(parsed, to: show)
        try? context.save()
        Task { await fillDirectoryArtwork(for: [show]) }

        // Grab the latest episode so there's something ready to play.
        if show.autoDownload, let latest = show.sortedEpisodes.first {
            downloads.download(latest, userInitiated: true)
        }
        return show
    }

    /// Resubscribes to a show from iCloud with its synced settings. Nothing is downloaded
    /// straight away, and the original subscribe date keeps refreshes off the back catalog.
    func restore(feedURL: String, _ synced: SyncedShow) async throws {
        guard context.show(withFeedURL: feedURL) == nil else { return }
        let parsed = try await Self.fetchFeed(feedURL)
        guard context.show(withFeedURL: feedURL) == nil else { return }
        let show = Show(
            feedURL: feedURL,
            title: parsed.title,
            author: parsed.author,
            summary: parsed.summary,
            artworkURL: parsed.artworkURL ?? synced.directoryArtwork,
            language: parsed.language,
            autoDownload: synced.autoDownload
        )
        show.directoryArtworkURL = synced.directoryArtwork
        show.isExplicit = parsed.isExplicit ?? false
        show.filteringEnabled = synced.filtering
        show.subscribedAt = Date(timeIntervalSince1970: Double(synced.subscribedAt))
        context.insert(show)
        apply(parsed, to: show)
        try context.save()
    }

    func unsubscribe(_ show: Show) {
        for episode in show.episodes where episode.downloadState != .notDownloaded {
            downloads.deleteDownload(episode)
        }
        context.delete(show)
        try? context.save()
    }

    /// Refreshes on app open if it's been a while. Goes by the last attempt, so a feed that keeps
    /// failing doesn't make every app open refresh everything. On launch, before any attempt,
    /// it goes by the most recent successful refresh.
    func refreshIfStale() async {
        let last: Date
        if let lastRefreshAttempt {
            last = lastRefreshAttempt
        } else {
            let shows = (try? context.fetch(FetchDescriptor<Show>())) ?? []
            last = shows.compactMap(\.lastRefreshed).max() ?? .distantPast
        }
        if Date.now.timeIntervalSince(last) > 15 * 60 { await refreshAll() }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshAttempt = .now
        defer { isRefreshing = false }

        let shows = (try? context.fetch(FetchDescriptor<Show>())) ?? []
        var pending = shows.map { FeedRequest(url: $0.feedURL, etag: $0.feedETag, lastModified: $0.feedLastModified) }[...]

        let results = await withTaskGroup(of: (String, FeedFetchResult?).self) { group in
            // Start a few fetches, then one more each time one finishes.
            for _ in 0..<Self.maxConcurrentFetches {
                guard let next = pending.popFirst() else { break }
                group.addTask { await next.fetch() }
            }
            var collected: [String: FeedFetchResult] = [:]
            for await (url, result) in group {
                if let result { collected[url] = result }
                if let next = pending.popFirst() { group.addTask { await next.fetch() } }
            }
            return collected
        }
        guard !Task.isCancelled else { return }

        var showsWithNewEpisodes: [Show] = []
        for show in shows {
            guard let result = results[show.feedURL] else { continue }
            guard case .feed(let feed, let etag, let lastModified) = result else {
                show.lastRefreshed = .now  // 304: nothing new
                continue
            }
            show.feedETag = etag
            show.feedLastModified = lastModified
            let newEpisodes = apply(feed, to: show)
            if !newEpisodes.isEmpty { showsWithNewEpisodes.append(show) }
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

        let needsArtwork = shows.filter { show in
            show.directoryArtworkCheckedAt == nil || showsWithNewEpisodes.contains { $0 === show }
        }
        if !needsArtwork.isEmpty { Task { await fillDirectoryArtwork(for: needsArtwork) } }
    }

    /// Gives episodes without their own cover in the feed the one the Apple Podcasts directory has,
    /// if it's different from the show's artwork.
    func fillDirectoryArtwork(for shows: [Show]) async {
        for show in shows {
            let missing = show.episodes.filter { $0.directoryImageURL == nil && ($0.imageURL == nil || $0.imageURL == show.artworkURL) }
            guard !missing.isEmpty else { continue }
            // Shows that aren't in the directory are looked up again only when new episodes arrive.
            show.directoryArtworkCheckedAt = .now
            if show.directoryID == nil {
                show.directoryID = try? await DirectoryService.directoryID(feedURL: show.feedURL, title: show.title)
            }
            guard let id = show.directoryID,
                  let covers = try? await DirectoryService.episodeArtwork(directoryID: id) else { continue }
            for episode in missing {
                if let cover = covers[episode.guid] ?? covers[episode.audioURL] { episode.directoryImageURL = cover }
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

        var existing = Dictionary(show.episodes.map { ($0.guid, $0) }, uniquingKeysWith: { first, _ in first })
        var inserted: [Episode] = []
        for item in feed.episodes {
            if let episode = existing[item.guid] {
                // Publishers edit notes after release, and older versions of the app kept only the
                // short description, so keep these in step with the feed.
                if !item.summary.isEmpty, episode.summary != item.summary { episode.summary = item.summary }
                if episode.transcriptURL != item.transcriptURL {
                    episode.transcriptURL = item.transcriptURL
                    episode.transcriptType = item.transcriptType
                    PublisherTranscript.delete(episodeID: episode.episodeID)
                }
                if episode.chaptersURL != item.chaptersURL {
                    episode.chaptersURL = item.chaptersURL
                    Chapters.delete(episodeID: episode.episodeID)
                }
                continue
            }
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
            episode.transcriptURL = item.transcriptURL
            episode.transcriptType = item.transcriptType
            episode.chaptersURL = item.chaptersURL
            context.insert(episode)
            episode.show = show
            existing[item.guid] = episode
            inserted.append(episode)
        }
        removeEpisodesDropped(from: feed, show: show)
        show.lastRefreshed = .now
        return inserted
    }

    /// Deletes episodes the publisher has taken out of the feed, unless they've been downloaded
    /// or listened to. Skipped when the feed only partly parsed, so a broken file can't empty a show.
    private func removeEpisodesDropped(from feed: ParsedFeed, show: Show) {
        guard feed.isComplete, !feed.episodes.isEmpty else { return }
        let inFeed = Set(feed.episodes.map(\.guid))
        let dropped = show.episodes.filter { episode in
            !inFeed.contains(episode.guid)
                && episode.downloadState == .notDownloaded
                && episode.processingState == .none
                && !episode.isPlayed
                && episode.playbackPosition == 0
        }
        for episode in dropped {
            PublisherTranscript.delete(episodeID: episode.episodeID)
            Chapters.delete(episodeID: episode.episodeID)
            context.delete(episode)
        }
    }
}

nonisolated enum FeedFetchResult: Sendable {
    case feed(ParsedFeed, etag: String?, lastModified: String?)
    case notModified
}

/// One feed to fetch during a refresh, with the validators from its last download.
private nonisolated struct FeedRequest: Sendable {
    let url: String
    let etag: String?
    let lastModified: String?

    /// nil when the fetch or parse failed.
    func fetch() async -> (String, FeedFetchResult?) {
        (url, try? await FeedService.fetchFeed(url, etag: etag, lastModified: lastModified))
    }
}
