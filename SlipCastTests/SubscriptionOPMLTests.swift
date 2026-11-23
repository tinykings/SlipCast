import Foundation
import Testing
@testable import SlipCast

struct SubscriptionOPMLTests {
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
