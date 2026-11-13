import AudioDetection
import KeywordSpotting
import AVFoundation
import SwiftData
import XCTest
@testable import SlipCast

@MainActor
final class ProcessingIntegrationTests: XCTestCase {
    private func fixture(source: URL? = nil, word: String = "funny") throws -> (ModelContainer, Episode, ProcessingQueue, DownloadManager) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Show.self, Episode.self, MutedTerm.self, configurations: configuration)
        let context = container.mainContext
        let id = "integration-\(UUID().uuidString)"
        let episode = Episode(episodeID: id, guid: id, title: "Synthetic test", summary: "", pubDate: nil,
                              duration: 17, audioURL: "https://example.invalid/audio", imageURL: nil)
        episode.fileName = "\(id).\(source?.pathExtension ?? "caf")"
        episode.downloadState = .downloaded
        episode.processingState = .ready // existing Apple-only cache must be upgraded
        let file = try XCTUnwrap(episode.localFileURL)
        if let source { try FileManager.default.copyItem(at: source, to: file) }
        else {
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 17 * 8000)!
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
            let output = try AVAudioFile(forWriting: file, settings: format.settings)
            try output.write(from: buffer)
        }
        let show = Show(feedURL: "https://example.invalid/\(id)", title: "Test show", autoDownload: false)
        show.filteringEnabled = true
        episode.show = show
        context.insert(show)
        context.insert(episode)
        context.insert(MutedTerm(text: word))
        try context.save()
        // Simulates a completed Apple pass. No SpeechTranscriber is available on Simulator.
        try TranscriptStore.save([], episodeID: id, engine: TranscriptStore.engineIdentifier)
        let processing = ProcessingQueue(context: context)
        return (container, episode, processing, DownloadManager(context: context, processing: processing))
    }

    private func clean(_ episode: Episode, _ downloads: DownloadManager) {
        downloads.deleteDownload(episode)
    }

    func testCrosstalkIsCheckedForMutedWordsInsteadOfSkipped() async throws {
        let (container, episode, processing, downloads) = try fixture(source: try XCTUnwrap(Bundle(for: Self.self).url(forResource: "OverlappingVoices", withExtension: "wav")))
        defer { clean(episode, downloads); withExtendedLifetime(container) {} }
        let context = container.mainContext
        let file = try XCTUnwrap(episode.localFileURL)
        try ReviewedMuteStore().apply(episodeID: episode.episodeID, fileURL: file,
            expectedFingerprint: ReviewedMuteStore.fingerprint(file), keyword: "manual", section: 0...13,
            ranges: [12...12.5])
        processing.resetInterrupted()
        XCTAssertEqual(episode.processingState, .pending)
        let player = PlayerController(context: context, processing: processing, downloads: downloads)
        await processing.start().value
        XCTAssertEqual(episode.processingState, .ready, episode.processingError ?? "")
        let scan = try XCTUnwrap(OverlapScanStore().load(episodeID: episode.episodeID, fileURL: file))
        XCTAssertTrue(scan.isComplete)
        XCTAssertFalse(scan.regions.isEmpty, "The synthetic control contains two overlapping voices")
        XCTAssertTrue(try TranscriptStore.load(episodeID: episode.episodeID).isEmpty)
        await player.play(episode)
        defer { player.stop() }
        XCTAssertTrue(player.isFullyScanned)
        let skips = scan.skipRanges(padding: 0)
        XCTAssertFalse(skips.isEmpty)
        // Processing listened to the crosstalk for the muted word; only what it heard is muted.
        let check = try XCTUnwrap(OverlapKeywordStore().load(episodeID: episode.episodeID, fileURL: file, clips: skips))
        XCTAssertTrue(check.covers(["funny"]))
        let heard = check.hits.map { CrosstalkFilter.muteRange(for: $0, padding: AppSettings.padding) }
        for range in heard { XCTAssertTrue(player.mutedRanges.contains { $0.contains(range.lowerBound) }) }
        for skip in skips {
            let middle = (skip.lowerBound + skip.upperBound) / 2
            guard !heard.contains(where: { $0.overlaps(skip) }), !(11.5...13).contains(middle) else { continue }
            XCTAssertFalse(player.mutedRanges.contains { $0.contains(middle) }, "Crosstalk without a muted word plays")
        }
        XCTAssertTrue(player.mutedRanges.contains { $0.contains(12.25) }, "Manual mutes must be retained")
        XCTAssertTrue(player.transcriptLines.isEmpty)
    }

    func testAddedWordSkipsCrosstalkOnlyUntilItHasBeenChecked() async throws {
        let (container, episode, processing, downloads) = try fixture(source: try XCTUnwrap(Bundle(for: Self.self).url(forResource: "OverlappingVoices", withExtension: "wav")))
        defer { clean(episode, downloads); withExtendedLifetime(container) {} }
        processing.resetInterrupted()
        await processing.start().value
        XCTAssertEqual(episode.processingState, .ready, episode.processingError ?? "")
        let file = try XCTUnwrap(episode.localFileURL)
        let skips = try XCTUnwrap(OverlapScanStore().load(episodeID: episode.episodeID, fileURL: file)).skipRanges(padding: 0)
        XCTAssertFalse(skips.isEmpty)
        let player = PlayerController(context: container.mainContext, processing: processing, downloads: downloads)
        await player.play(episode)
        defer { player.stop() }
        player.pause()

        container.mainContext.insert(MutedTerm(text: "zebra"))
        try container.mainContext.save()
        player.refreshMuting()
        let middle = (skips[0].lowerBound + skips[0].upperBound) / 2
        XCTAssertTrue(player.mutedRanges.contains { $0.contains(middle) }, "Unchecked word: crosstalk is skipped meanwhile")

        var checked: OverlapKeywordCheck?
        for _ in 0..<100 {
            checked = OverlapKeywordStore().load(episodeID: episode.episodeID, fileURL: file, clips: skips)
            if checked?.covers(["zebra"]) == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let check = try XCTUnwrap(checked)
        XCTAssertTrue(check.covers(["funny", "zebra"]), "Only the new word needed checking")
        try await Task.sleep(for: .milliseconds(100))
        if check.hits.isEmpty {
            XCTAssertFalse(player.mutedRanges.contains { $0.contains(middle) }, "Checked crosstalk plays again")
        }
    }

    func testChangedWordsReuseOverlapScanAndApplyTranscriptFilterImmediately() async throws {
        let (container, episode, processing, downloads) = try fixture(word: "fuck")
        defer { clean(episode, downloads); withExtendedLifetime(container) {} }
        try TranscriptStore.save([TranscriptWord(text: "funny", start: 1, end: 1.5)],
                                 episodeID: episode.episodeID, engine: TranscriptStore.engineIdentifier)
        processing.resetInterrupted()
        await processing.start().value
        XCTAssertEqual(episode.processingState, .ready)
        let player = PlayerController(context: container.mainContext, processing: processing, downloads: downloads)
        await player.play(episode)
        defer { player.stop() }
        player.pause()
        XCTAssertTrue(player.mutedRanges.isEmpty)
        container.mainContext.insert(MutedTerm(text: "funny"))
        try container.mainContext.save()
        player.refreshMuting()
        XCTAssertTrue(player.isFullyScanned)
        XCTAssertEqual(episode.processingState, .ready)
        XCTAssertFalse(processing.hasPendingWork)
        XCTAssertTrue(player.filteredSkipRanges.contains { $0.contains(1.25) })
    }

    func testDeletingActiveDownloadCannotRecreateReadyStateOrScanFiles() async throws {
        let (container, episode, processing, downloads) = try fixture(word: "fuck")
        let file = try XCTUnwrap(episode.localFileURL)
        let id = episode.episodeID
        defer { processing.onLiveUpdate = nil; clean(episode, downloads); withExtendedLifetime(container) {} }
        var removed = false
        processing.onLiveUpdate = { _ in
            if !removed, let scan = processing.liveAudioScan, scan.nextWindow >= 1 {
                removed = true
                downloads.deleteDownload(episode)
            }
        }
        processing.resetInterrupted()
        await processing.start().value
        XCTAssertTrue(removed)
        XCTAssertEqual(episode.downloadState, .notDownloaded)
        XCTAssertEqual(episode.processingState, .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: TranscriptStore.url(for: id).path))
        XCTAssertNil(try OverlapScanStore().load(episodeID: id, fileURL: file))
    }

    func testRemovingModelDuringScanDoesNotReuseInvalidatedEpisode() async throws {
        let (container, episode, processing, downloads) = try fixture(word: "fuck")
        let id = episode.episodeID
        let file = try XCTUnwrap(episode.localFileURL)
        defer { processing.onLiveUpdate = nil; withExtendedLifetime(container) {} }
        var removed = false
        processing.onLiveUpdate = { _ in
            if !removed, let scan = processing.liveAudioScan, scan.nextWindow >= 1 {
                removed = true
                downloads.deleteDownload(episode)
                container.mainContext.delete(episode)
                try? container.mainContext.save()
            }
        }
        processing.resetInterrupted()
        await processing.start().value
        XCTAssertTrue(removed)
        XCTAssertNil(container.mainContext.episode(withID: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: TranscriptStore.url(for: id).path))
        XCTAssertNil(try OverlapScanStore().load(episodeID: id, fileURL: file))
    }
    func testUnfilteredShowSkipsProcessingAndAllSavedMutes() async throws {
        let (container, episode, processing, downloads) = try fixture(word: "fuck")
        defer { clean(episode, downloads); withExtendedLifetime(container) {} }
        let show = try XCTUnwrap(episode.show)
        show.filteringEnabled = false
        // Existing failed filter metadata must not stop original-audio playback.
        episode.processingState = .failed
        let file = try XCTUnwrap(episode.localFileURL)
        try ReviewedMuteStore().apply(episodeID: episode.episodeID, fileURL: file,
            expectedFingerprint: ReviewedMuteStore.fingerprint(file), keyword: "fuck", section: 0...17, ranges: [1...3])
        processing.resetInterrupted()
        processing.enqueue(episode)
        await processing.start().value
        XCTAssertEqual(episode.processingState, .none)
        XCTAssertTrue(episode.isReady)
        XCTAssertFalse(processing.hasPendingWork)
        XCTAssertNil(try OverlapScanStore().load(episodeID: episode.episodeID, fileURL: file))
        let player = PlayerController(context: container.mainContext, processing: processing, downloads: downloads)
        await player.play(episode)
        defer { player.stop() }
        XCTAssertTrue(player.mutedRanges.isEmpty)
        XCTAssertTrue(player.transcriptLines.isEmpty)
        XCTAssertTrue(player.isFullyScanned)
        XCTAssertFalse(player.isWaitingForScan)
        player.rescanDownloads()
        await processing.start().value
        XCTAssertTrue(player.isPlaying, "Re-scanning filtered shows must not pause original audio")
    }

    func testFilteredShowCannotStreamOrPlayBeforeProcessing() async throws {
        let (container, episode, processing, downloads) = try fixture(word: "fuck")
        defer { clean(episode, downloads); withExtendedLifetime(container) {} }
        episode.processingState = .pending
        XCTAssertFalse(PlayerController.canPlay(episode))
        episode.downloadState = .notDownloaded
        XCTAssertNil(downloads.stream(episode))
        episode.downloadState = .downloaded
        XCTAssertFalse(episode.isReady)
        processing.resetInterrupted()
        await processing.start().value
        XCTAssertTrue(PlayerController.canPlay(episode))
        XCTAssertTrue(episode.isReady)
    }

    func testShowFilteringDefaultsOffAndTurningOffCancelsPendingWork() async throws {
        let (container, episode, processing, downloads) = try fixture(word: "fuck")
        defer { clean(episode, downloads); withExtendedLifetime(container) {} }
        let fresh = Show(feedURL: "https://example.invalid/default", title: "Unfiltered", autoDownload: false)
        XCTAssertFalse(fresh.filteringEnabled)
        let show = try XCTUnwrap(episode.show)
        show.filteringEnabled = false
        processing.filteringChanged(for: show)
        XCTAssertEqual(episode.processingState, .none)
        XCTAssertFalse(processing.hasPendingWork)
        XCTAssertTrue(PlayerController.canPlay(episode))
        await processing.start().value
        withExtendedLifetime(container) {}
    }

    func testTurningOffFilteringStopsAnActiveScan() async throws {
        let (container, episode, processing, downloads) = try fixture(word: "fuck")
        defer { processing.onLiveUpdate = nil; clean(episode, downloads); withExtendedLifetime(container) {} }
        let show = try XCTUnwrap(episode.show)
        var disabled = false
        processing.onLiveUpdate = { _ in
            if !disabled, let scan = processing.liveAudioScan, scan.nextWindow >= 1 {
                disabled = true
                show.filteringEnabled = false
                processing.filteringChanged(for: show)
            }
        }
        processing.resetInterrupted()
        await processing.start().value
        XCTAssertTrue(disabled)
        XCTAssertEqual(episode.processingState, .none)
        XCTAssertFalse(processing.hasPendingWork)
        XCTAssertTrue(PlayerController.canPlay(episode))
    }

    func testPauseAndImmediateResumeKeepsProgressAndRestartsCancelledRunner() async throws {
        let previous = UserDefaults.standard.bool(forKey: AppSettings.processingPausedKey)
        let (container, episode, processing, downloads) = try fixture(word: "fuck")
        defer {
            processing.onLiveUpdate = nil
            clean(episode, downloads)
            UserDefaults.standard.set(previous, forKey: AppSettings.processingPausedKey)
            withExtendedLifetime(container) {}
        }
        processing.pauseProcessing()
        processing.resetInterrupted()
        await processing.start().value
        XCTAssertNil(processing.activeEpisodeID)
        XCTAssertEqual(episode.processingState, .pending)
        var interrupted = false
        processing.onLiveUpdate = { _ in
            if !interrupted, let scan = processing.liveAudioScan, scan.nextWindow >= 1 {
                interrupted = true
                processing.pauseProcessing()
                XCTAssertTrue(processing.isPaused)
                processing.resumeProcessing()
            }
        }
        processing.resumeProcessing()
        await processing.start().value
        await processing.start().value
        XCTAssertTrue(interrupted)
        XCTAssertFalse(processing.isPaused)
        XCTAssertEqual(episode.processingState, .ready, episode.processingError ?? "")
    }

    func testPlaybackAutomaticallyJumpsPastFilteredPassageAndPauseDoesNotSkip() async throws {
        let (container, episode, processing, downloads) = try fixture(word: "fuck")
        defer { clean(episode, downloads); withExtendedLifetime(container) {} }
        let file = try XCTUnwrap(episode.localFileURL)
        try ReviewedMuteStore().apply(episodeID: episode.episodeID, fileURL: file,
            expectedFingerprint: ReviewedMuteStore.fingerprint(file), keyword: "manual", section: 0...17, ranges: [0.2...3])
        processing.resetInterrupted()
        await processing.start().value
        let player = PlayerController(context: container.mainContext, processing: processing, downloads: downloads)
        await player.play(episode)
        defer { player.stop() }
        player.pause()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThan(player.currentTime, 0.2)
        player.resume()
        for _ in 0..<50 {
            if player.currentTime >= 3 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThanOrEqual(player.currentTime, 3, "Playback should jump rather than stay silent for the passage")
        XCTAssertNil(player.scanError)
        player.pause()
        player.seek(to: 1)
        XCTAssertGreaterThanOrEqual(player.currentTime, 3, "Seeking into filtered audio also jumps to its end")
    }

    func testFilteredTailFinishesEpisodeAndRewindSeekSupersedesAnOlderSkip() async throws {
        let previous = UserDefaults.standard.bool(forKey: AppSettings.autoDeletePlayedKey)
        UserDefaults.standard.set(false, forKey: AppSettings.autoDeletePlayedKey)
        let (container, episode, processing, downloads) = try fixture(word: "fuck")
        defer {
            clean(episode, downloads)
            UserDefaults.standard.set(previous, forKey: AppSettings.autoDeletePlayedKey)
            withExtendedLifetime(container) {}
        }
        let file = try XCTUnwrap(episode.localFileURL)
        try ReviewedMuteStore().apply(episodeID: episode.episodeID, fileURL: file,
            expectedFingerprint: ReviewedMuteStore.fingerprint(file), keyword: "manual", section: 0...17, ranges: [2...3, 8...17])
        processing.resetInterrupted()
        await processing.start().value
        let player = PlayerController(context: container.mainContext, processing: processing, downloads: downloads)
        await player.play(episode)
        defer { player.stop() }
        player.pause()
        player.seek(to: 2.5)
        player.seek(to: 5)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.currentTime, 5, accuracy: 0.05)
        XCTAssertNil(player.scanError)
        XCTAssertFalse(player.isPlaying)
        player.seek(to: 9)
        player.resume()
        for _ in 0..<30 {
            if episode.isPlayed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(episode.isPlayed)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(episode.playbackPosition, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testPlayWhenReadyStartsEpisodeAfterProcessingAndTappingAgainCancels() async throws {
        let (container, episode, processing, downloads) = try fixture()
        defer { clean(episode, downloads); withExtendedLifetime(container) {} }
        processing.resetInterrupted()
        XCTAssertEqual(episode.processingState, .pending)
        let player = PlayerController(context: container.mainContext, processing: processing, downloads: downloads)
        defer { player.stop() }

        player.togglePlayWhenReady(episode)
        XCTAssertEqual(player.playWhenReadyID, episode.episodeID)
        player.togglePlayWhenReady(episode)
        XCTAssertNil(player.playWhenReadyID)

        player.togglePlayWhenReady(episode)
        for _ in 0..<100 where !player.isCurrent(episode) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(episode.processingState, .ready)
        XCTAssertTrue(player.isCurrent(episode))
        XCTAssertTrue(player.isPlaying)
        XCTAssertNil(player.playWhenReadyID)
    }
}
