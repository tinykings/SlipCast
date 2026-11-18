import XCTest
@testable import SlipCast

@MainActor
final class BackgroundTranscriptionTests: XCTestCase {
    func testPlayingPodcastKeepsTranscriptionGoingWhenShortBackgroundTimeEnds() {
        XCTAssertFalse(ProcessingQueue.shouldStopTranscription(
            expiring: .shortBackgroundTime,
            continuedTaskAttached: false,
            continuedTaskRequested: false,
            processingTaskAttached: false,
            audioKeepsProcessAlive: true))
    }

    func testShortBackgroundTimeStopsOnlyWhenNothingElseIsKeepingTheProcessAlive() {
        XCTAssertTrue(ProcessingQueue.shouldStopTranscription(
            expiring: .shortBackgroundTime,
            continuedTaskAttached: false,
            continuedTaskRequested: false,
            processingTaskAttached: false,
            audioKeepsProcessAlive: false))
    }

    func testRequestedContinuedTaskSurvivesTheShortBackgroundTimer() {
        XCTAssertFalse(ProcessingQueue.shouldStopTranscription(
            expiring: .shortBackgroundTime,
            continuedTaskAttached: false,
            continuedTaskRequested: true,
            processingTaskAttached: false,
            audioKeepsProcessAlive: false))
    }

    func testProcessingTaskExpiryDoesNotCancelAudioOrContinuedWork() {
        XCTAssertFalse(ProcessingQueue.shouldStopTranscription(
            expiring: .processingTask,
            continuedTaskAttached: true,
            continuedTaskRequested: false,
            processingTaskAttached: true,
            audioKeepsProcessAlive: false))
        XCTAssertFalse(ProcessingQueue.shouldStopTranscription(
            expiring: .processingTask,
            continuedTaskAttached: false,
            continuedTaskRequested: false,
            processingTaskAttached: true,
            audioKeepsProcessAlive: true))
        XCTAssertTrue(ProcessingQueue.shouldStopTranscription(
            expiring: .processingTask,
            continuedTaskAttached: false,
            continuedTaskRequested: false,
            processingTaskAttached: true,
            audioKeepsProcessAlive: false))
    }

    func testContinuedTaskExpiryKeepsGoingWhileTheEpisodeIsAudible() {
        XCTAssertFalse(ProcessingQueue.shouldStopTranscription(
            expiring: .continuedTask,
            continuedTaskAttached: true,
            continuedTaskRequested: false,
            processingTaskAttached: false,
            audioKeepsProcessAlive: true))
        XCTAssertTrue(ProcessingQueue.shouldStopTranscription(
            expiring: .continuedTask,
            continuedTaskAttached: true,
            continuedTaskRequested: false,
            processingTaskAttached: false,
            audioKeepsProcessAlive: false))
    }

    func testQuietStretchWhileRunningIsNotTreatedAsADeadTranscriber() {
        XCTAssertFalse(ProcessingQueue.processWasSuspended(elapsed: .seconds(180)))
        XCTAssertFalse(ProcessingQueue.processWasSuspended(elapsed: .seconds(200)))
        XCTAssertTrue(ProcessingQueue.processWasSuspended(elapsed: .seconds(600)))
    }

    func testContinuedProgressDoesNotMoveBackwardOnTheNextEpisode() {
        var progress = ContinuedWorkProgress()
        XCTAssertEqual(progress.advance(episodeID: "one", fraction: 0.5), 5_000)
        XCTAssertEqual(progress.total(pendingIncludingActive: 2), 20_000)
        XCTAssertEqual(progress.advance(episodeID: "one", fraction: 1), 10_000)
        // A new episode starts at zero locally, but the system count keeps what already finished.
        XCTAssertEqual(progress.advance(episodeID: "two", fraction: 0), 10_000)
        XCTAssertEqual(progress.advance(episodeID: "two", fraction: 0.25), 12_500)
        XCTAssertEqual(progress.total(pendingIncludingActive: 1), 20_000)
        XCTAssertEqual(progress.advance(episodeID: "two", fraction: 0.1), 12_500)
    }
}
