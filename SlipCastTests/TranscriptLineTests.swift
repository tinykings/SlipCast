import XCTest
@testable import SlipCast

final class TranscriptLineTests: XCTestCase {
    private let words = ["We", "laughed", "about", "it", "all", "afternoon."].enumerated().map { index, text in
        TranscriptWord(text: text, start: Double(index), end: Double(index) + 0.8)
    }

    func testSkippedPassageAddsMarkerAndStrikesItsWords() throws {
        let line = try XCTUnwrap(TranscriptLine.lines(from: words, mutedWordIndices: [], skippedRanges: [1.9...3.9]).first)
        XCTAssertEqual(line.words.map(\.isSkipMarker), [false, false, true, false, false, false, false])
        XCTAssertEqual(line.words.filter(\.isSkipped).map(\.text), ["about", "it"])
        XCTAssertTrue(line.containsMutedWord)
    }

    func testSkipBetweenWordsAndAfterLastWordStillGetMarkers() {
        let lines = TranscriptLine.lines(from: words, mutedWordIndices: [], skippedRanges: [9...10, 0.85...0.95])
        let all = lines.flatMap(\.words)
        XCTAssertEqual(all.count(where: \.isSkipMarker), 2)
        XCTAssertTrue(all[1].isSkipMarker, "A gap between words is marked before the next word")
        XCTAssertTrue(all.last?.isSkipMarker == true)
        XCTAssertTrue(all.allSatisfy { !$0.isSkipped })
    }

    func testNoSkipsKeepsPlainLines() {
        let lines = TranscriptLine.lines(from: words, mutedWordIndices: [])
        XCTAssertFalse(lines.contains(where: \.containsMutedWord))
        XCTAssertEqual(lines.flatMap(\.words).count, words.count)
    }
}
