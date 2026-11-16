import XCTest
@testable import SlipCast

final class MusicSectionsTests: XCTestCase {
    private func word(_ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(text: "word", start: start, end: end)
    }

    func testGapsAreLongWordlessStretchesTrimmedAwayFromWords() {
        let words = [word(5, 5.5), word(6, 6.5), word(12, 12.5)]
        XCTAssertEqual(MusicSections.gaps(in: words, duration: 20), [0...4.75, 6.75...11.75, 12.75...20])
    }

    func testOrdinaryPausesAreNotGaps() {
        let words = [word(0.2, 1), word(2.5, 3)]
        XCTAssertEqual(MusicSections.gaps(in: words, duration: 4), [])
    }

    func testRunsSkipSilenceBridgeDipsAndDropShortSounds() {
        // 1 s silence, 2 s sound with a 0.2 s dip, 1 s silence, 0.5 s sound.
        let loud = [Float](repeating: -20, count: 18), quiet = [Float](repeating: -80, count: 20)
        let levels = quiet + loud + [Float](repeating: -80, count: 4) + loud + quiet + [Float](repeating: -20, count: 10)
        let runs = MusicSections.runs(levels: levels, threshold: -45, offset: 100)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].start, 101, accuracy: 0.001)
        XCTAssertEqual(runs[0].end, 103, accuracy: 0.001)
    }

    func testMusicLinesAreAddedInOrder() {
        let words = [word(0, 0.5), word(10, 10.5)]
        let lines = TranscriptLine.lines(from: words, mutedWordIndices: [])
        let merged = TranscriptLine.adding([MusicSection(start: 3, end: 8), MusicSection(start: 12, end: 15)], to: lines)
        XCTAssertEqual(merged.map(\.isMusic), [false, true, false, true])
        XCTAssertEqual(merged.map(\.id), [0, 1, 2, 3])
    }
}
