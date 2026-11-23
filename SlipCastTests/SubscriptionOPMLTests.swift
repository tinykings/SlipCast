import Foundation
import Testing
@testable import SlipCast

struct SubscriptionOPMLTests {
    @Test func exportShortcutIsBundledAndSigned() throws {
        let url = try #require(Bundle.main.url(forResource: "Export Apple Podcasts", withExtension: "shortcut"))
        let data = try Data(contentsOf: url)
        // Apple’s signed shortcut container, not an unsigned workflow plist.
        #expect(data.starts(with: Data("AEA1".utf8)))
        #expect(data.count > 1_000)
    }

    @Test func importsURLOnlyOutlinesFromBundledExporter() throws {
        let data = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
            <head><title>Apple Podcasts Subscriptions</title></head>
            <body>
                <outline type="rss" xmlUrl="https://example.com/feed?a=1&amp;b=two"/>
            </body>
            </opml>
            """.utf8)
        let parsed = try SubscriptionOPML.parse(data)
        #expect(parsed.feeds.count == 1)
        #expect(parsed.feeds.first?.url == "https://example.com/feed?a=1&b=two")
        #expect(parsed.feeds.first?.title == "example.com")
    }

    @Test func importsNestedFeedsAndDeduplicatesURLs() throws {
        let data = Data("""
            <?xml version="1.0"?>
            <opml version="2.0">
                <body>
                    <outline text="Podcasts">
                        <outline title="First Show" xmlUrl="https://example.com/feed?one=1&amp;two=2"/>
                        <outline text="Duplicate" xmlUrl="https://example.com/feed?one=1&amp;two=2"/>
                        <outline text="Second Show" xmlUrl="http://example.org/rss"/>
                        <outline text="Bad URL" xmlUrl="file:///tmp/feed.xml"/>
                        <outline text="Missing URL" xmlUrl=""/>
                    </outline>
                </body>
            </opml>
            """.utf8)

        let parsed = try SubscriptionOPML.parse(data)

        #expect(parsed.feeds.map(\.url) == ["https://example.com/feed?one=1&two=2", "http://example.org/rss"])
        #expect(parsed.feeds.map(\.title) == ["First Show", "Second Show"])
        #expect(parsed.invalidFeedCount == 2)
    }

    @Test(arguments: [
        "<opml><body><outline xmlUrl='https://example.com/feed'/></body>",
        "<rss><body><outline xmlUrl='https://example.com/feed'/></body></rss>",
        "<opml><body><outline text='Empty folder'/></body></opml>"
    ])
    func rejectsInvalidOrEmptyFiles(_ xml: String) {
        #expect(throws: (any Error).self) {
            try SubscriptionOPML.parse(Data(xml.utf8))
        }
    }
}
