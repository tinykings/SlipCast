import XCTest
@testable import SlipCast

/// `isCurrent` remembers its answer per file, so it must notice the file being replaced or removed.
final class TranscriptStoreTests: XCTestCase {
    private let id = "transcript-store-test-\(UUID().uuidString)"

    override func tearDown() {
        TranscriptStore.delete(episodeID: id)
        super.tearDown()
    }

    func testCurrentFollowsSavesAndDeletes() throws {
        XCTAssertFalse(TranscriptStore.isCurrent(episodeID: id))

        try TranscriptStore.save([TranscriptWord(text: "hi", start: 0, end: 1)], episodeID: id, engine: "old-engine")
        XCTAssertFalse(TranscriptStore.isCurrent(episodeID: id))
        XCTAssertFalse(TranscriptStore.isCurrent(episodeID: id))  // cached answer

        try TranscriptStore.save([TranscriptWord(text: "hi", start: 0, end: 1)], episodeID: id,
                                 engine: TranscriptStore.engineIdentifier)
        XCTAssertTrue(TranscriptStore.isCurrent(episodeID: id))

        TranscriptStore.delete(episodeID: id)
        XCTAssertFalse(TranscriptStore.isCurrent(episodeID: id))
    }

    func testReplacedOutsideTheStoreIsNoticed() throws {
        try TranscriptStore.save([], episodeID: id, engine: TranscriptStore.engineIdentifier)
        XCTAssertTrue(TranscriptStore.isCurrent(episodeID: id))
        // A different size invalidates the remembered answer even without going through `save`.
        try Data("not a transcript at all".utf8).write(to: TranscriptStore.url(for: id))
        XCTAssertFalse(TranscriptStore.isCurrent(episodeID: id))
    }
}
