import AVFoundation
import Synchronization
import XCTest
@testable import AudioDetection

final class FastOverlapTests: XCTestCase {
    func testFrameRegionsUseHysteresisAndClipToKeptCenter() {
        let scores = [Float](repeating: 0, count: 20) + [Float](repeating: 0.95, count: 12)
            + [Float](repeating: 0.75, count: 10) + [Float](repeating: 0, count: 20)
        let regions = OverlapDetector.regions(scores: scores, start: 10, duration: 20, keep: 10...20)
        XCTAssertEqual(regions.count, 1)
        XCTAssertTrue(regions[0].range.contains(10.45))
        XCTAssertTrue(regions[0].range.contains(10.65), "Scores above the offset continue a passage")
        XCTAssertFalse(regions[0].range.contains(10.2))
        let weak = [Float](repeating: 0.8, count: 40)
        XCTAssertTrue(OverlapDetector.regions(scores: weak, start: 0, duration: 10, keep: 0...10).isEmpty)
        let clipped = OverlapDetector.regions(scores: scores, start: 10, duration: 20, keep: 10.5...10.6)
        XCTAssertEqual(clipped.first?.start, 10.5)
        XCTAssertEqual(clipped.first?.end, 10.6)
        XCTAssertTrue(OverlapDetector.regions(scores: scores, start: 10, duration: 20, keep: 15...17.5).isEmpty)
    }

    func testShortPassagesAreNotSkipped() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 1, count: 256).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var scan = OverlapScan(fingerprint: try ReviewedMuteStore.fingerprint(file), duration: 12)
        try scan.append(window: 0, regions: [OverlapRegion(start: 1, end: 1.5), OverlapRegion(start: 4, end: 4.4),
                                             OverlapRegion(start: 4.5, end: 5)], elapsed: 0)
        XCTAssertEqual(scan.skipRanges(padding: 0), [4...5])
    }

    func testFastCheckpointCursorBoundsAndVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("audio.wav")
        try Data(repeating: 1, count: 256).write(to: file)
        let store = OverlapScanStore(directory: root.appendingPathComponent("scans"))
        var scan = OverlapScan(fingerprint: try ReviewedMuteStore.fingerprint(file), duration: 17)
        try scan.append(window: 0, regions: [OverlapRegion(start: 3, end: 5)], elapsed: 0.03)
        try store.save(scan, episodeID: "episode", fileURL: file)
        var resumed = try XCTUnwrap(store.load(episodeID: "episode", fileURL: file))
        XCTAssertEqual(resumed.scannedThrough, 2.5)
        XCTAssertFalse(resumed.isComplete)
        for window in 1..<resumed.windowCount { try resumed.append(window: window, regions: [], elapsed: 0.03) }
        XCTAssertTrue(resumed.isComplete)
        XCTAssertEqual(resumed.scannedThrough, 17)
        XCTAssertEqual(resumed.skipRanges(padding: 0.2), [2.8...5.2])
        let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("scans"), includingPropertiesForKeys: nil).first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["engine"] = "old-model"
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertNil(try store.load(episodeID: "episode", fileURL: file))
        try store.save(resumed, episodeID: "episode", fileURL: file)
        try Data(repeating: 2, count: 256).write(to: file)
        XCTAssertNil(try store.load(episodeID: "episode", fileURL: file))
        XCTAssertThrowsError(try store.save(resumed, episodeID: "episode", fileURL: file))
        try store.remove(episodeID: "episode")
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try store.save(resumed, episodeID: "episode", fileURL: file))
    }

    func testSkipPlannerHandlesBoundariesChainsAndEOF() {
        let ranges = [2.0...4.0, 4.01...5.0, 8.0...12.0]
        XCTAssertNil(FilteredSkipPlanner.destination(at: 1, ranges: ranges, duration: 10))
        XCTAssertEqual(FilteredSkipPlanner.destination(at: 2, ranges: ranges, duration: 10), 5.025)
        XCTAssertEqual(FilteredSkipPlanner.destination(at: 1.98, ranges: ranges, duration: 10, lead: 0.035), 5.025)
        XCTAssertNil(FilteredSkipPlanner.destination(at: 6, ranges: ranges, duration: 10))
        XCTAssertEqual(FilteredSkipPlanner.destination(at: 9, ranges: ranges, duration: 10), 10)
        XCTAssertNil(FilteredSkipPlanner.destination(at: .nan, ranges: ranges, duration: 10))
    }

    @MainActor
    func testBundledModelFindsSyntheticOverlappingVoicesAndReusesCompletedCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Fixtures/OverlappingVoices.wav"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let store = OverlapScanStore(directory: root)
        let progress = Mutex<[Double]>([])
        let scan = try await OverlapDetector.shared.scan(fileURL: file, episodeID: "control", store: store,
            onUpdate: { update in progress.withLock { $0.append(update.scannedThrough) } })
        XCTAssertTrue(scan.isComplete)
        XCTAssertFalse(scan.regions.isEmpty)
        XCTAssertTrue(scan.regions.contains { $0.end > 3 && $0.start < 10 })
        XCTAssertEqual(progress.withLock { $0 }, progress.withLock { $0.sorted() })
        let cached = try await OverlapDetector.shared.scan(fileURL: file, episodeID: "control", store: store, onUpdate: { _ in })
        XCTAssertEqual(cached.elapsed, scan.elapsed)
        XCTAssertEqual(cached.regions, scan.regions)
    }
}
