import XCTest
@testable import SlipCast

final class CloudSyncTests: XCTestCase {
    private let show = SyncedShow(autoDownload: true, filtering: false, subscribedAt: 100, directoryArtwork: nil)

    private func reconcile<V>(_ ledger: inout SyncLedger<V>, local: [String: V], remote: [String: SyncEntry<V>] = [:],
                              absentMeansDeleted: Bool = true, now: Int = 1000,
                              canApply: Bool = true) -> (merged: [String: SyncEntry<V>], applied: [String]) {
        var applied: [String] = []
        let merged = ledger.reconcile(local: local, remote: remote, absentMeansDeleted: absentMeansDeleted,
                                      isDefault: { _, _ in false }, now: now) { key, _ in
            applied.append(key)
            return canApply
        }
        return (merged, applied)
    }

    func testFreshInstallRestoresFromCloud() {
        var ledger = SyncLedger<SyncedShow>()
        let remote = ["a": SyncEntry(value: show, modified: 50)]
        let result = reconcile(&ledger, local: [:], remote: remote, now: 0)
        XCTAssertEqual(result.applied, ["a"])
        XCTAssertEqual(result.merged, remote) // nothing new to write
    }

    func testPendingRestoreIsNotTreatedAsUnsubscribe() {
        var ledger = SyncLedger<SyncedShow>()
        let remote = ["a": SyncEntry(value: show, modified: 50)]
        _ = reconcile(&ledger, local: [:], remote: remote, canApply: false)
        let second = reconcile(&ledger, local: [:], remote: remote, now: 2000, canApply: false)
        XCTAssertEqual(second.merged["a"]?.value, show)
    }

    func testDataFromBeforeSyncLosesToCloudButFillsGaps() {
        var ledger = SyncLedger<SyncedShow>()
        var changed = show
        changed.autoDownload = false
        let remote = ["a": SyncEntry(value: changed, modified: 50)]
        let result = reconcile(&ledger, local: ["a": show, "b": show], remote: remote, now: 0)
        XCTAssertEqual(result.merged["a"]?.value, changed)
        XCTAssertEqual(result.merged["b"]?.value, show)
        XCTAssertEqual(result.applied, ["a"])
    }

    func testUnsubscribeWritesDeletion() {
        var ledger = SyncLedger<SyncedShow>()
        _ = reconcile(&ledger, local: ["a": show], now: 10)
        let result = reconcile(&ledger, local: [:], remote: ["a": SyncEntry(value: show, modified: 10)], now: 20)
        XCTAssertEqual(result.merged["a"], SyncEntry(value: nil, modified: 20))
        XCTAssertTrue(result.applied.isEmpty)
    }

    func testNewerRemoteChangeIsApplied() {
        var ledger = SyncLedger<SyncedShow>()
        _ = reconcile(&ledger, local: ["a": show], now: 10)
        let deleted = SyncEntry<SyncedShow>(value: nil, modified: 30)
        let result = reconcile(&ledger, local: ["a": show], remote: ["a": deleted], now: 40)
        XCTAssertEqual(result.applied, ["a"])
        XCTAssertEqual(ledger.entries["a"], deleted)
    }

    func testHistoryKeepsDefaultsOutAndPrunes() {
        var ledger = SyncLedger<PlayState>()
        let merged = ledger.reconcile(local: ["new": PlayState(played: false, position: 0),
                                             "played": PlayState(played: true, position: 0)],
                                      remote: [:], absentMeansDeleted: false,
                                      isDefault: { _, state in state.isDefault }, now: 10) { _, _ in true }
        XCTAssertEqual(Set(merged.keys), ["played"])

        var history: [String: SyncEntry<PlayState>] = [
            "old-unplayed": SyncEntry(value: PlayState(played: false, position: 0), modified: 0),
            "old-played": SyncEntry(value: PlayState(played: true, position: 0), modified: 0),
            "a": SyncEntry(value: PlayState(played: false, position: 30), modified: 5_000_000),
            "b": SyncEntry(value: PlayState(played: false, position: 40), modified: 5_000_001),
        ]
        SyncLedger<PlayState>.pruneHistory(&history, now: 5_000_002, limit: 2)
        XCTAssertEqual(Set(history.keys), ["a", "b"])
    }

    func testPlayStateEncodesCompactly() throws {
        let data = try JSONEncoder().encode(PlayState(played: true, position: 75))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[1,75]")
        XCTAssertEqual(try JSONDecoder().decode(PlayState.self, from: data), PlayState(played: true, position: 75))
    }
}
