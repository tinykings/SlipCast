import XCTest
@testable import SlipCast

final class ChaptersTests: XCTestCase {
    func testParsesPodcastingChaptersJSON() throws {
        let json = """
        {"version":"1.2.0","chapters":[
          {"startTime":125.5,"title":"Listener mail"},
          {"startTime":0,"title":"Intro"},
          {"startTime":60,"title":"Sponsor","toc":false},
          {"startTime":300}
        ]}
        """
        let chapters = try Chapters.parse(Data(json.utf8))
        XCTAssertEqual(chapters.map(\.title), ["Intro", "Listener mail", "Chapter 3"])
        XCTAssertEqual(chapters.map(\.start), [0, 125.5, 300])
        XCTAssertEqual(chapters.map(\.id), [0, 1, 2])
    }

    func testNormalizedDropsDuplicateStarts() {
        let chapters = Chapters.normalized([
            Chapter(id: 0, start: 10, title: "B"),
            Chapter(id: 0, start: 0, title: " A "),
            Chapter(id: 0, start: 10.01, title: "Duplicate"),
        ])
        XCTAssertEqual(chapters.map(\.title), ["A", "B"])
    }
}
