import Foundation
import SwiftData

/// A subscribed podcast feed.
@Model
final class Show {
    @Attribute(.unique) var feedURL: String
    var title: String
    var author: String
    var summary: String
    var artworkURL: String?
    var language: String?
    var filteringEnabled: Bool = false
    /// The feed's show-level `itunes:explicit` tag. Filtering starts on for these.
    var isExplicit: Bool = false
    var autoDownload: Bool
    var subscribedAt: Date
    var lastRefreshed: Date?
    /// Publish date of the newest episode in the feed (for sorting and display).
    var latestEpisodeDate: Date?

    @Relationship(deleteRule: .cascade, inverse: \Episode.show)
    var episodes: [Episode] = []

    init(
        feedURL: String,
        title: String,
        author: String = "",
        summary: String = "",
        artworkURL: String? = nil,
        language: String? = nil,
        autoDownload: Bool
    ) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.summary = summary
        self.artworkURL = artworkURL
        self.language = language
        self.autoDownload = autoDownload
        self.subscribedAt = .now
    }

    var newestEpisodeDate: Date? {
        latestEpisodeDate ?? episodes.compactMap(\.pubDate).max()
    }

    var sortedEpisodes: [Episode] {
        episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
    }

    /// Locale used for on-device transcription.
    var transcriptionLocale: Locale {
        if let language, !language.isEmpty { return Locale(identifier: language) }
        return .current
    }
}
