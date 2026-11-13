import XCTest
@testable import AudioDetection

final class ReviewedMuteStoreTests: XCTestCase {
    private func fixture() throws -> (URL, URL, ReviewedMuteStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("episode.mp3")
        try Data(repeating: 7, count: 256).write(to: audio)
        return (root, audio, ReviewedMuteStore(directory: root.appendingPathComponent("mutes")))
    }

    func testReviewedMutesSurviveReloadAndIncludeExtendedWord() throws {
        let (root, audio, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fingerprint = try ReviewedMuteStore.fingerprint(audio)
        try store.apply(episodeID: "episode", fileURL: audio, expectedFingerprint: fingerprint,
                        keyword: "fuck", section: 1948...1978, ranges: [1962.8...1963.7, 1970.8...1974])
        let reloaded = ReviewedMuteStore(directory: root.appendingPathComponent("mutes"))
        let ranges = try reloaded.ranges(episodeID: "episode", fileURL: audio)
        XCTAssertEqual(ranges, [1962.8...1963.7, 1970.8...1974])
        XCTAssertTrue(ranges.contains { $0.contains(1973.9) })
    }

    func testReplacingSectionPreservesOtherCoverageAndWords() throws {
        let (root, audio, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fingerprint = try ReviewedMuteStore.fingerprint(audio)
        try store.apply(episodeID: "episode", fileURL: audio, expectedFingerprint: fingerprint,
                        keyword: "fuck", section: 0...100, ranges: [10...12, 40...50, 80...82])
        try store.apply(episodeID: "episode", fileURL: audio, expectedFingerprint: fingerprint,
                        keyword: "another", section: 0...100, ranges: [32...33])
        try store.apply(episodeID: "episode", fileURL: audio, expectedFingerprint: fingerprint,
                        keyword: "fuck", section: 30...45, ranges: [43...44])
        XCTAssertEqual(try store.ranges(episodeID: "episode", fileURL: audio), [10...12, 32...33, 43...44, 45...50, 80...82])
    }

    func testChangedDownloadRejectsOldTimingsEvenWithSameSizeAndDate() throws {
        let (root, audio, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: audio.path)
        let fingerprint = try ReviewedMuteStore.fingerprint(audio)
        try store.apply(episodeID: "episode", fileURL: audio, expectedFingerprint: fingerprint,
                        keyword: "fuck", section: 0...10, ranges: [2...3])
        try Data(repeating: 8, count: 256).write(to: audio)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: audio.path)
        XCTAssertEqual(try store.ranges(episodeID: "episode", fileURL: audio), [])
        XCTAssertThrowsError(try store.apply(episodeID: "episode", fileURL: audio, expectedFingerprint: fingerprint,
                                            keyword: "fuck", section: 0...10, ranges: [2...3])) {
            XCTAssertTrue($0 is ReviewedMuteError)
        }
    }

    func testRemovalKeepsAudioAndOtherEpisodes() throws {
        let (root, audio, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fingerprint = try ReviewedMuteStore.fingerprint(audio)
        for id in ["first", "second"] {
            try store.apply(episodeID: id, fileURL: audio, expectedFingerprint: fingerprint,
                            keyword: "fuck", section: 0...10, ranges: [2...3])
        }
        try store.remove(episodeID: "first")
        XCTAssertEqual(try store.ranges(episodeID: "first", fileURL: audio), [])
        XCTAssertEqual(try store.ranges(episodeID: "second", fileURL: audio), [2...3])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }
}
