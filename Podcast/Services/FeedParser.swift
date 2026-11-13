import Foundation

nonisolated struct ParsedFeed: Sendable {
    var title = ""
    var author = ""
    var summary = ""
    var artworkURL: String?
    var language: String?
    /// The show-level `itunes:explicit` tag; nil when the feed doesn't say.
    var isExplicit: Bool?
    var episodes: [ParsedEpisode] = []
}

nonisolated struct ParsedEpisode: Sendable {
    var guid = ""
    var title = ""
    var summary = ""
    var pubDate: Date?
    var duration: Double?
    var audioURL = ""
    var imageURL: String?
}

nonisolated enum FeedError: LocalizedError {
    case invalidFeed

    var errorDescription: String? { "That doesn't look like a podcast RSS feed." }
}

/// Minimal RSS 2.0 + iTunes namespace parser.
nonisolated final class FeedParser: NSObject, XMLParserDelegate {
    private var feed = ParsedFeed()
    private var item: ParsedEpisode?
    private var text = ""
    private var inChannelImage = false
    private var sawChannel = false
    private var channelImageURL: String?

    static func parse(_ data: Data) throws -> ParsedFeed {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // Be lenient: many feeds have small XML errors late in the file. Keep what parsed.
        let succeeded = parser.parse()
        guard delegate.sawChannel, succeeded || !delegate.feed.episodes.isEmpty else {
            throw parser.parserError ?? FeedError.invalidFeed
        }
        if delegate.feed.artworkURL == nil { delegate.feed.artworkURL = delegate.channelImageURL }
        return delegate.feed
    }

    func parser(
        _ parser: XMLParser,
        didStartElement name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        text = ""
        switch name {
        case "channel":
            sawChannel = true
        case "item":
            item = ParsedEpisode()
        case "image" where item == nil:
            inChannelImage = true
        case "enclosure":
            let type = attributes["type"]?.lowercased() ?? "audio"
            if let url = attributes["url"], type.hasPrefix("audio") || type.isEmpty || url.hasSuffix(".mp3") {
                item?.audioURL = url
            }
        case "itunes:image":
            if let href = Self.normalizedImageURL(attributes["href"]) {
                if item != nil { item?.imageURL = href } else { feed.artworkURL = href }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement name: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }

        if var current = item {
            switch name {
            case "title": current.title = value
            case "guid": current.guid = value
            case "pubDate": current.pubDate = Self.parseDate(value)
            case "itunes:duration": current.duration = Self.parseDuration(value)
            case "description", "itunes:summary", "content:encoded":
                if current.summary.isEmpty { current.summary = value }
            case "item":
                if current.guid.isEmpty { current.guid = current.audioURL }
                if !current.audioURL.isEmpty { feed.episodes.append(current) }
                item = nil
                return
            default: break
            }
            item = current
            return
        }

        if inChannelImage {
            if name == "url" { channelImageURL = Self.normalizedImageURL(value) }
            if name == "image" { inChannelImage = false }
            return
        }

        switch name {
        case "title": if feed.title.isEmpty { feed.title = value }
        case "itunes:author": feed.author = value
        case "description", "itunes:summary": if feed.summary.isEmpty { feed.summary = value }
        case "language": feed.language = value
        case "itunes:explicit": feed.isExplicit = Self.parseExplicit(value)
        default: break
        }
    }

    // MARK: - Helpers

    /// Trims, drops empty values, percent-encodes stray spaces, and upgrades http to https
    /// (App Transport Security blocks plain http, and most image hosts serve both).
    static func normalizedImageURL(_ value: String?) -> String? {
        guard var string = value?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
            return nil
        }
        string = string.replacingOccurrences(of: " ", with: "%20")
        if string.lowercased().hasPrefix("http://") {
            string = "https://" + string.dropFirst("http://".count)
        }
        return URL(string: string) == nil ? nil : string
    }

    private static let dateFormatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm Z",
        "yyyy-MM-dd'T'HH:mm:ssZ",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    static func parseDate(_ value: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    /// Apple's spec uses true/false; older feeds use yes/no/explicit/clean.
    static func parseExplicit(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "explicit": true
        case "false", "no", "clean": false
        default: nil
        }
    }

    /// Accepts "3600", "59:59" or "1:02:03".
    static func parseDuration(_ value: String) -> Double? {
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
