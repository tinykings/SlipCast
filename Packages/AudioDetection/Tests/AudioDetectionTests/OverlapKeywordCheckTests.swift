import XCTest
@testable import AudioDetection
@testable import KeywordSpotting

final class OverlapKeywordCheckTests: XCTestCase {
    /// Two synthetic voices. From 6.7 s a second speaker talks over "...total crap..." (said ~10.7 s).
    private var fixture: URL {
        get throws { try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Fixtures/KeywordUnderCrosstalk.wav")) }
    }

    private func temporaryStore() throws -> OverlapKeywordStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return OverlapKeywordStore(directory: directory)
    }

    func testHearsMutedWordUnderSecondVoice() async throws {
        let store = try temporaryStore()
        let check = try await OverlapKeywordSpotter.shared.check(
            fileURL: try fixture, episodeID: "fixture", clips: [7.2...13.9], keywords: ["crap", "beer"], store: store)
        XCTAssertEqual(check.checked, ["crap", "beer"])
        let hits = check.hits(for: ["crap"])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(try XCTUnwrap(hits.first).firstToken, 10.7, accuracy: 0.3)
        XCTAssertTrue(check.hits(for: ["beer"]).isEmpty)
    }

    func testOnlyNewKeywordsAreCheckedAndResultsAreTiedToClips() async throws {
        let store = try temporaryStore()
        let url = try fixture
        _ = try await OverlapKeywordSpotter.shared.check(fileURL: url, episodeID: "fixture", clips: [7.2...13.9],
                                                         keywords: ["crap"], store: store)
        let saved = try XCTUnwrap(store.load(episodeID: "fixture", fileURL: url, clips: [7.2...13.9]))
        XCTAssertTrue(saved.covers(["crap"]))
        XCTAssertFalse(saved.covers(["crap", "beer"]))
        let grown = try await OverlapKeywordSpotter.shared.check(fileURL: url, episodeID: "fixture", clips: [7.2...13.9],
                                                                 keywords: ["crap", "beer"], store: store)
        XCTAssertEqual(grown.hits(for: ["crap"]).count, 1, "Earlier hits are kept")
        XCTAssertNil(store.load(episodeID: "fixture", fileURL: url, clips: [1...2]), "A new overlap scan invalidates it")
    }

    func testKeywordNormalization() {
        XCTAssertEqual(OverlapKeywordCheck.keyword(for: "  Damn "), "damn")
        XCTAssertEqual(OverlapKeywordCheck.keyword(for: "Oh-My  God"), "oh my god")
        XCTAssertEqual(OverlapKeywordCheck.keyword(for: "café"), "cafe")
        XCTAssertNil(OverlapKeywordCheck.keyword(for: "123 !!"))
    }
}
