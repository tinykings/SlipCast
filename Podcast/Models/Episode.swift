import Foundation
import SwiftData

enum DownloadState: String, Codable {
    /// Not on device.
    case notDownloaded
    /// Handed to the background session but no bytes yet (e.g. waiting for Wi-Fi).
    case queued
    case downloading
    case downloaded
    case failed
}

enum ProcessingState: String, Codable {
    case none
    /// Downloaded, waiting to be transcribed.
    case pending
    case processing
    /// Transcript and automatic overlap scan saved; muting can be applied.
    case ready
    case failed
}

@Model
final class Episode {
    /// Stable hash of feed URL + guid. Also used for local file names.
    @Attribute(.unique) var episodeID: String
    var guid: String
    var title: String
    var summary: String
    var pubDate: Date?
    var duration: Double?
    var audioURL: String
    var imageURL: String?
    /// The episode's own cover from the Apple Podcasts directory, when the feed has none.
    var directoryImageURL: String?
    /// The publisher's transcript from the feed, if it offers one we can read.
    var transcriptURL: String?
    var transcriptType: String?
    /// The publisher's chapters (Podcasting 2.0 `podcast:chapters` JSON), if the feed has them.
    var chaptersURL: String?
    var show: Show?

    var fileName: String?
    var downloadedAt: Date?
    var downloadStateRaw: String = DownloadState.notDownloaded.rawValue
    var processingStateRaw: String = ProcessingState.none.rawValue
    var processingError: String?

    var playbackPosition: Double = 0
    var isPlayed: Bool = false
    /// Position in the user's Ready to Play order. nil until they reorder; those come after the
    /// ordered ones, newest first.
    var queueOrder: Double?

    init(
        episodeID: String,
        guid: String,
        title: String,
        summary: String,
        pubDate: Date?,
        duration: Double?,
        audioURL: String,
        imageURL: String?
    ) {
        self.episodeID = episodeID
        self.guid = guid
        self.title = title
        self.summary = summary
        self.pubDate = pubDate
        self.duration = duration
        self.audioURL = audioURL
        self.imageURL = imageURL
    }

    var downloadState: DownloadState {
        get { DownloadState(rawValue: downloadStateRaw) ?? .notDownloaded }
        set { downloadStateRaw = newValue.rawValue }
    }

    var processingState: ProcessingState {
        get { ProcessingState(rawValue: processingStateRaw) ?? .none }
        set { processingStateRaw = newValue.rawValue }
    }

    var localFileURL: URL? {
        fileName.map { Storage.episodesDirectory.appending(path: $0) }
    }

    var requiresFiltering: Bool { show?.filteringEnabled == true }

    /// The Downloads list order for ready episodes: anything the user hasn't placed yet
    /// (newest published first), then the user's order.
    static func downloadsOrder(_ episodes: [Episode]) -> [Episode] {
        let ready = episodes.filter(\.isReady)
        let placed = ready.filter { $0.queueOrder != nil }.sorted { ($0.queueOrder ?? 0) < ($1.queueOrder ?? 0) }
        let unplaced = ready.filter { $0.queueOrder == nil }.sorted {
            ($0.pubDate ?? $0.downloadedAt ?? .distantPast) > ($1.pubDate ?? $1.downloadedAt ?? .distantPast)
        }
        return unplaced + placed
    }

    /// Downloaded; filtered shows also require both processing passes.
    var isReady: Bool {
        downloadState == .downloaded && (!requiresFiltering || processingState == .ready)
    }

    /// Downloading, or downloaded and still being scanned.
    var isInProgress: Bool {
        downloadState == .queued || downloadState == .downloading
            || (downloadState == .downloaded && requiresFiltering && (processingState == .pending || processingState == .processing))
    }

    var artworkURL: String? { imageURL ?? show?.artworkURL }

    /// Artwork URLs to try, best first: the episode's own from the feed, then its cover from the
    /// directory, then the show's. A feed image that's just the show artwork goes after the directory's.
    var artworkCandidates: [String?] {
        let showArtwork = show?.artworkCandidates ?? []
        let feedImageIsShowArt = imageURL != nil && imageURL == show?.artworkURL
        let episodeImages = feedImageIsShowArt ? [directoryImageURL, imageURL] : [imageURL, directoryImageURL]
        return episodeImages + showArtwork
    }
}

extension ModelContext {
    /// Ready-to-play downloads in the order the Downloads list shows them.
    func readyDownloads() -> [Episode] {
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.downloadStateRaw != "notDownloaded" })
        return Episode.downloadsOrder((try? fetch(descriptor)) ?? [])
    }

    func episode(withID id: String) -> Episode? {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.episodeID == id })
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }

    func show(withFeedURL feedURL: String) -> Show? {
        var descriptor = FetchDescriptor<Show>(predicate: #Predicate { $0.feedURL == feedURL })
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }
}
