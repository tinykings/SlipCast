import Foundation

nonisolated struct SubscriptionOPML: Sendable {
    struct Feed: Sendable {
        let url: String
        let title: String
    }

    let feeds: [Feed]
    let invalidFeedCount: Int

    @concurrent
    static func read(from url: URL) async throws -> Self {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        return try parse(Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> Self {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), parser.parserError == nil, delegate.sawBody else {
            throw ImportError.invalidOPML
        }
        guard !delegate.feeds.isEmpty else {
            throw ImportError.noFeedURLs
        }
        return Self(feeds: delegate.feeds, invalidFeedCount: delegate.invalidFeedCount)
    }

    private enum ImportError: LocalizedError {
        case invalidOPML
        case noFeedURLs

        var errorDescription: String? {
            switch self {
            case .invalidOPML: "Choose a valid podcast OPML file."
            case .noFeedURLs: "This OPML file contains no usable podcast feed URLs."
            }
        }
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        private var elements: [String] = []
        private var seenURLs: Set<String> = []
        private(set) var sawBody = false
        private(set) var feeds: [Feed] = []
        private(set) var invalidFeedCount = 0

        func parser(
            _ parser: XMLParser,
            didStartElement name: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            elements.append(name)
            if elements == ["opml", "body"] { sawBody = true }
            guard name == "outline", elements.starts(with: ["opml", "body"]),
                  let value = attributes["xmlUrl"] else { return }

            let url = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: url, encodingInvalidCharacters: false),
                  let host = parsed.host, !host.isEmpty,
                  ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
                invalidFeedCount += 1
                return
            }

            guard seenURLs.insert(url).inserted else { return }
            let title = [attributes["title"], attributes["text"]].compactMap { $0 }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            feeds.append(Feed(url: url, title: title ?? host))
        }

        func parser(
            _ parser: XMLParser,
            didEndElement name: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            elements.removeLast()
        }
    }
}
