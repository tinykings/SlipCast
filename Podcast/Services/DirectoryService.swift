import Foundation

/// A podcast listed in the Apple Podcasts directory.
nonisolated struct DirectoryPodcast: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let author: String
    let artworkURL: String?
    let feedURL: String?
    let genre: String?
}

/// An Apple Podcasts category. `id == nil` means the overall chart.
nonisolated struct PodcastGenre: Identifiable, Hashable, Sendable {
    let id: Int?
    let name: String

    static let top = PodcastGenre(id: nil, name: "Top Podcasts")

    /// Top Podcasts first, then Apple's podcast categories.
    static let all: [PodcastGenre] = [
        .top,
        PodcastGenre(id: 1301, name: "Arts"),
        PodcastGenre(id: 1321, name: "Business"),
        PodcastGenre(id: 1303, name: "Comedy"),
        PodcastGenre(id: 1304, name: "Education"),
        PodcastGenre(id: 1483, name: "Fiction"),
        PodcastGenre(id: 1511, name: "Government"),
        PodcastGenre(id: 1512, name: "Health & Fitness"),
        PodcastGenre(id: 1487, name: "History"),
        PodcastGenre(id: 1305, name: "Kids & Family"),
        PodcastGenre(id: 1502, name: "Leisure"),
        PodcastGenre(id: 1310, name: "Music"),
        PodcastGenre(id: 1489, name: "News"),
        PodcastGenre(id: 1314, name: "Religion & Spirituality"),
        PodcastGenre(id: 1533, name: "Science"),
        PodcastGenre(id: 1324, name: "Society & Culture"),
        PodcastGenre(id: 1545, name: "Sports"),
        PodcastGenre(id: 1318, name: "Technology"),
        PodcastGenre(id: 1488, name: "True Crime"),
        PodcastGenre(id: 1309, name: "TV & Film"),
    ]
}

/// Search and top charts via Apple's free iTunes Search API (no key required).
/// Podcast Index (podcastindex.org) is a good second source if this ever falls short.
nonisolated enum DirectoryService {
    private struct LookupResponse: Decodable {
        struct Item: Decodable {
            let collectionId: Int?
            let collectionName: String?
            let artistName: String?
            let artworkUrl600: String?
            let artworkUrl100: String?
            let feedUrl: String?
            let primaryGenreName: String?
        }
        let results: [Item]
    }

    private struct ChartResponse: Decodable {
        struct Feed: Decodable {
            struct Entry: Decodable { let id: String }
            let results: [Entry]
        }
        let feed: Feed
    }

    private static var country: String {
        Locale.current.region?.identifier.lowercased() ?? "us"
    }

    @concurrent
    static func search(_ term: String) async throws -> [DirectoryPodcast] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "term", value: term),
        ]
        return try await lookup(components.url!)
    }

    /// Top podcasts chart for the user's region, overall or for one category.
    @concurrent
    static func topPodcasts(genre: PodcastGenre = .top, limit: Int = 50) async throws -> [DirectoryPodcast] {
        // The iTunes RSS chart supports categories; the newer marketing-tools chart doesn't, so it's
        // only used as a fallback for the overall chart.
        let genrePath = genre.id.map { "/genre=\($0)" } ?? ""
        let legacyURL = URL(string: "https://itunes.apple.com/\(country)/rss/toppodcasts/limit=\(limit)\(genrePath)/json")!
        var ids: [String] = []
        if let (data, _) = try? await URLSession.shared.data(from: legacyURL) {
            ids = legacyChartIDs(data)
        }
        if ids.isEmpty && genre.id == nil {
            let chartURL = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country)/podcasts/top/\(limit)/podcasts.json")!
            let (data, _) = try await URLSession.shared.data(from: chartURL)
            ids = try JSONDecoder().decode(ChartResponse.self, from: data).feed.results.map(\.id)
        }
        guard !ids.isEmpty else { throw URLError(.cannotParseResponse) }

        // The chart doesn't include feed URLs, so look them up in one batch and keep chart order.
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: ids.joined(separator: ",")),
            URLQueryItem(name: "entity", value: "podcast"),
        ]
        let podcasts = try await lookup(components.url!)
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return podcasts.sorted { (order[String($0.id)] ?? .max) < (order[String($1.id)] ?? .max) }
    }

    /// `feed.entry[].id.attributes["im:id"]`; `entry` is an object instead of an array when there's one.
    private static func legacyChartIDs(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = root["feed"] as? [String: Any]
        else { return [] }
        let entries: [[String: Any]]
        if let list = feed["entry"] as? [[String: Any]] {
            entries = list
        } else if let single = feed["entry"] as? [String: Any] {
            entries = [single]
        } else {
            return []
        }
        return entries.compactMap { entry in
            ((entry["id"] as? [String: Any])?["attributes"] as? [String: Any])?["im:id"] as? String
        }
    }

    private static func lookup(_ url: URL) async throws -> [DirectoryPodcast] {
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(LookupResponse.self, from: data)
        return response.results.compactMap { item in
            guard let id = item.collectionId, let title = item.collectionName else { return nil }
            return DirectoryPodcast(
                id: id,
                title: title,
                author: item.artistName ?? "",
                artworkURL: item.artworkUrl600 ?? item.artworkUrl100,
                feedURL: item.feedUrl,
                genre: item.primaryGenreName
            )
        }
    }
}
