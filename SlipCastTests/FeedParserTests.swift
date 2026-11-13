import XCTest
@testable import SlipCast

final class FeedParserTests: XCTestCase {
    private func feed(channel: String, item: String = "") throws -> ParsedFeed {
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" version="2.0"><channel>
        <title>Show</title>\(channel)
        <item><title>One</title><guid>1</guid>\(item)<enclosure url="https://example.com/1.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """
        return try FeedParser.parse(Data(xml.utf8))
    }

    func testShowLevelExplicitTag() throws {
        XCTAssertEqual(try feed(channel: "<itunes:explicit>true</itunes:explicit>").isExplicit, true)
        XCTAssertEqual(try feed(channel: "<itunes:explicit>Yes</itunes:explicit>").isExplicit, true)
        XCTAssertEqual(try feed(channel: "<itunes:explicit>clean</itunes:explicit>").isExplicit, false)
        XCTAssertEqual(try feed(channel: "<itunes:explicit>false</itunes:explicit>").isExplicit, false)
        XCTAssertNil(try feed(channel: "").isExplicit)
    }

    func testEpisodeExplicitTagDoesNotMarkTheShow() throws {
        XCTAssertNil(try feed(channel: "", item: "<itunes:explicit>true</itunes:explicit>").isExplicit)
    }
}
