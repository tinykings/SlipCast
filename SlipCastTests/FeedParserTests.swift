import XCTest
@testable import SlipCast

final class FeedParserTests: XCTestCase {
    private func feed(channel: String, item: String = "") throws -> ParsedFeed {
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:podcast="https://podcastindex.org/namespace/1.0" version="2.0"><channel>
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

    func testEpisodeChaptersURL() throws {
        let item = #"<podcast:chapters url=" https://example.com/1.json " type="application/json+chapters"/>"#
        XCTAssertEqual(try feed(channel: "", item: item).episodes.first?.chaptersURL, "https://example.com/1.json")
    }

    func testTruncatedFeedIsMarkedIncomplete() throws {
        XCTAssertTrue(try feed(channel: "").isComplete)
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>Show</title>
        <item><title>One</title><guid>1</guid><enclosure url="https://example.com/1.mp3" type="audio/mpeg"/></item>
        <item><title>Two</title><guid>2</guid><enclosure url="https://example.com/2.mp3"
        """
        let partial = try FeedParser.parse(Data(xml.utf8))
        XCTAssertEqual(partial.episodes.map(\.guid), ["1"])
        XCTAssertFalse(partial.isComplete, "Episodes missing from a broken feed must not be pruned")
    }

    func testEpisodeExplicitTagDoesNotMarkTheShow() throws {
        XCTAssertNil(try feed(channel: "", item: "<itunes:explicit>true</itunes:explicit>").isExplicit)
    }

    func testFullNotesWinOverShortDescription() throws {
        let item = """
        <description>Short blurb.</description>
        <content:encoded><![CDATA[<p>Full notes with <a href="https://example.com">a link</a>.</p>]]></content:encoded>
        <itunes:summary>Short blurb, a bit longer.</itunes:summary>
        """
        XCTAssertEqual(try feed(channel: "", item: item).episodes.first?.summary,
                       "<p>Full notes with <a href=\"https://example.com\">a link</a>.</p>")
    }

    func testLongerDescriptionWithoutContentEncoded() throws {
        let item = "<description>Short.</description><itunes:summary>The longer summary.</itunes:summary>"
        XCTAssertEqual(try feed(channel: "", item: item).episodes.first?.summary, "The longer summary.")
    }

    func testPicksBestTimedTranscript() throws {
        let item = """
        <podcast:transcript url="https://example.com/t.html" type="text/html"/>
        <podcast:transcript url="https://example.com/t.srt" type="application/x-subrip"/>
        <podcast:transcript url="https://example.com/t.vtt" type="text/vtt"/>
        """
        let episode = try XCTUnwrap(try feed(channel: "", item: item).episodes.first)
        XCTAssertEqual(episode.transcriptURL, "https://example.com/t.vtt")
        XCTAssertEqual(episode.transcriptType, "text/vtt")
    }

    func testIgnoresUntimedTranscripts() throws {
        let item = #"<podcast:transcript url="https://example.com/t.html" type="text/html"/>"#
        XCTAssertNil(try feed(channel: "", item: item).episodes.first?.transcriptURL)
    }
}

final class PublisherTranscriptTests: XCTestCase {
    func testParsesWebVTT() {
        let vtt = """
        WEBVTT

        NOTE header comment

        1
        00:00:01.000 --> 00:00:03.000 align:start
        <v Host>Hello &amp; welcome</v>

        00:01:02.500 --> 00:01:04.000
        Second cue
        """
        XCTAssertEqual(PublisherTranscript.timedTextCues(vtt), [
            .init(start: 1, end: 3, text: "Hello & welcome"),
            .init(start: 62.5, end: 64, text: "Second cue"),
        ])
    }

    func testParsesSRT() {
        let srt = "1\r\n00:00:01,500 --> 00:00:02,000\r\nHi there\r\n\r\n2\r\n01:00:00,000 --> 01:00:01,000\r\nLater\r\n"
        XCTAssertEqual(PublisherTranscript.timedTextCues(srt), [
            .init(start: 1.5, end: 2, text: "Hi there"),
            .init(start: 3600, end: 3601, text: "Later"),
        ])
    }

    func testParsesJSON() throws {
        let json = #"{"version":"1.0.0","segments":[{"speaker":"A","startTime":0.5,"endTime":1.5,"body":"Hi"},{"body":"no time"}]}"#
        XCTAssertEqual(try PublisherTranscript.cues(from: Data(json.utf8), format: .json),
                       [.init(start: 0.5, end: 1.5, text: "Hi")])
    }

    func testSpreadsCueTimeAcrossWords() {
        let words = PublisherTranscript.words(from: [.init(start: 10, end: 14, text: "ab cd")])
        XCTAssertEqual(words.map(\.text), ["ab", "cd"])
        XCTAssertEqual(words.map(\.start), [10, 12])
        XCTAssertEqual(words.last?.end, 14)
    }
}

@MainActor
final class ShowNotesTests: XCTestCase {
    func testKeepsLinksAndParagraphs() {
        let notes = ShowNotes.attributed(#"<p>Intro &amp; more.</p><p>See <a href="https://example.com/x">our site</a></p><img src="https://example.com/a.png">"#)
        XCTAssertEqual(String(notes.characters), "Intro & more.\n\nSee our site")
        let linked = notes.runs.compactMap { run in run.link.map { (String(notes[run.range].characters), $0) } }
        XCTAssertEqual(linked.first?.0, "our site")
        XCTAssertEqual(linked.first?.1, URL(string: "https://example.com/x"))
    }

    func testLinksBareURLsInPlainText() {
        let notes = ShowNotes.attributed("Line one\nVisit https://example.com today")
        XCTAssertEqual(String(notes.characters), "Line one\nVisit https://example.com today")
        XCTAssertTrue(notes.runs.contains { $0.link == URL(string: "https://example.com") })
    }
}
