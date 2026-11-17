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
    /// Artwork from the directory listing the show was added from. Used when the feed's own
    /// artwork won't load (e.g. a plain-http URL, which App Transport Security blocks).
    var directoryArtworkURL: String?
    /// Apple Podcasts directory ID, found by matching the feed URL. Used to look up episode covers.
    var directoryID: Int?
    /// When episode covers were last looked up in the directory.
    var directoryArtworkCheckedAt: Date?
    var language: String?
    var filteringEnabled: Bool = false
    /// This show's own speed; nil plays at the default for all shows. Set together with
    /// `sleepTimerSetting` when the player's settings are switched to "This Show".
    var playbackRate: Double?
    /// This show's own sleep timer, as `SleepTimer.storedValue`; nil uses the default for all shows.
    var sleepTimerSetting: Int?
    /// The feed's show-level `itunes:explicit` tag. Filtering starts on for these.
    var isExplicit: Bool = false
    var autoDownload: Bool
    var subscribedAt: Date
    var lastRefreshed: Date?
    /// Cache validators from the last full feed download, sent back so an unchanged feed
    /// answers 304 instead of resending the whole file.
    var feedETag: String?
    var feedLastModified: String?
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

    var isFullyPlayed: Bool {
        !episodes.isEmpty && episodes.allSatisfy(\.isPlayed)
    }

    /// Whether this show has its own speed and sleep timer instead of the defaults.
    var hasOwnPlaybackSettings: Bool { playbackRate != nil || sleepTimerSetting != nil }

    /// Artwork URLs to try, best first.
    var artworkCandidates: [String?] { [artworkURL, directoryArtworkURL] }

    var sortedEpisodes: [Episode] {
        episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
    }

    /// Locale used for on-device transcription.
    var transcriptionLocale: Locale {
        if let language, !language.isEmpty { return Locale(identifier: language) }
        return .current
    }
}
