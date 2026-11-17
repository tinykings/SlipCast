import SwiftData
import XCTest
@testable import SlipCast

@MainActor
final class DownloadsBadgeTests: XCTestCase {
    private func episode(_ download: DownloadState, _ processing: ProcessingState = .none, show: Show) -> Episode {
        let id = "badge-\(UUID().uuidString)"
        let episode = Episode(episodeID: id, guid: id, title: id, summary: "", pubDate: nil,
                              duration: nil, audioURL: "https://example.invalid/\(id)", imageURL: nil)
        episode.downloadState = download
        episode.processingState = processing
        episode.show = show
        return episode
    }

    func testCountsOnlyDownloadingAndProcessingEpisodes() throws {
        let container = try ModelContainer(for: Show.self, Episode.self, MutedTerm.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let filtered = Show(feedURL: "https://example.invalid/filtered", title: "Filtered", autoDownload: false)
        filtered.filteringEnabled = true
        let unfiltered = Show(feedURL: "https://example.invalid/plain", title: "Plain", autoDownload: false)
        context.insert(filtered)
        context.insert(unfiltered)

        let counted = [
            episode(.queued, show: unfiltered),
            episode(.downloading, show: unfiltered),
            episode(.downloaded, .pending, show: filtered),
            episode(.downloaded, .processing, show: filtered),
        ]
        let ignored = [
            episode(.notDownloaded, show: unfiltered),
            episode(.failed, show: unfiltered),
            episode(.downloaded, show: unfiltered),
            // Unfiltered shows are playable as soon as they download, whatever processing says.
            episode(.downloaded, .pending, show: unfiltered),
            episode(.downloaded, .ready, show: filtered),
            episode(.downloaded, .failed, show: filtered),
        ]
        for episode in counted + ignored { context.insert(episode) }
        try context.save()

        let onDevice = try context.fetch(FetchDescriptor<Episode>(
            predicate: #Predicate { $0.downloadStateRaw != "notDownloaded" }))
        XCTAssertEqual(onDevice.count(where: \.isInProgress), counted.count)

        for episode in counted {
            episode.downloadState = .downloaded
            episode.processingState = .ready
        }
        XCTAssertEqual(onDevice.count(where: \.isInProgress), 0, "A zero count hides the badge")
    }
}
