import XCTest
@testable import SlipCast

final class MuteMatcherTests: XCTestCase {
    private func words(_ texts: [String]) -> [TranscriptWord] {
        texts.enumerated().map { TranscriptWord(text: $1, start: Double($0), end: Double($0) + 1) }
    }

    private func matches(_ texts: [String], _ phrases: [String]) -> [ClosedRange<Int>] {
        MuteMatcher.matchedWords(in: words(texts), rules: phrases.map(MuteRule.init(phrase:)))
    }

    // MARK: Normalizing

    func testNormalizeIgnoresCaseAccentsAndPunctuation() {
        XCTAssertEqual(MuteMatcher.normalize("Don't!"), "dont")
        XCTAssertEqual(MuteMatcher.normalize("CAFÉ"), "cafe")
        XCTAssertEqual(MuteMatcher.normalize("“Hell,”"), "hell")
    }

    func testTokenizeSplitsOnSpacesAndJoiners() {
        XCTAssertEqual(MuteMatcher.tokenize("son-of-a gun"), ["son", "of", "a", "gun"])
        XCTAssertEqual(MuteMatcher.tokenize("  either/or_maybe  "), ["either", "or", "maybe"])
        XCTAssertEqual(MuteMatcher.tokenize("!!! ..."), [])
    }

    func testMaskKeepsFirstLetterAndPunctuation() {
        XCTAssertEqual(MuteMatcher.mask("bad word,"), "b** w***,")
        XCTAssertEqual(MuteMatcher.mask("Heck!"), "H***!")
    }

    // MARK: Matching

    func testMatchesWordWithPunctuationAndCase() {
        XCTAssertEqual(matches(["What", "the", "HELL?"], ["hell"]), [2...2])
    }

    /// Deliberate: muted words match inside longer words, so compounds are caught.
    func testMatchesInsideLongerWords() {
        XCTAssertEqual(matches(["so", "uncool"], ["cool"]), [1...1])
        XCTAssertEqual(matches(["coolest", "thing"], ["cool"]), [0...0])
    }

    func testPhraseMatchesConsecutiveWordsOnly() {
        XCTAssertEqual(matches(["oh", "my", "gosh"], ["my gosh"]), [1...2])
        XCTAssertEqual(matches(["my", "dear", "gosh"], ["my gosh"]), [])
    }

    func testHyphenatedTranscriptWordMatchesSpelledOutPhrase() {
        XCTAssertEqual(matches(["son-of-a", "gun"], ["son of a"]), [0...0])
    }

    func testEveryOccurrenceAndEveryRuleIsReported() {
        let found = matches(["heck", "no", "heck", "darn"], ["heck", "darn"])
        XCTAssertEqual(Set(found), [0...0, 2...2, 3...3])
    }

    func testEmptyOrOverlongRulesMatchNothing() {
        XCTAssertEqual(matches(["hello"], ["!!!"]), [])
        XCTAssertEqual(matches(["one"], ["one two three"]), [])
        XCTAssertEqual(matches([], ["anything"]), [])
    }

    // MARK: Ranges

    func testMuteRangesAddPaddingAndClampAtZero() {
        let transcript = [
            TranscriptWord(text: "darn", start: 0.25, end: 1),
            TranscriptWord(text: "it", start: 1, end: 2),
            TranscriptWord(text: "darn", start: 5, end: 6),
        ]
        let ranges = MuteMatcher.muteRanges(for: [0...0, 2...2], in: transcript, padding: 0.5)
        XCTAssertEqual(ranges, [0...1.5, 4.5...6.5])
    }

    func testMuteRangesSpanWholePhrase() {
        let transcript = words(["oh", "my", "gosh"])
        XCTAssertEqual(MuteMatcher.muteRanges(for: [1...2], in: transcript, padding: 0.25), [0.75...3.25])
    }

    func testMergeSortsAndJoinsNearlyTouchingRanges() {
        let merged = MuteMatcher.merge([3...4, 0...1, 1.0625...2, 1.5...1.75], joiningGapsUnder: 0.08)
        XCTAssertEqual(merged, [0...2, 3...4])
        XCTAssertEqual(MuteMatcher.merge([0...1, 1.25...2], joiningGapsUnder: 0.08), [0...1, 1.25...2])
    }
}
