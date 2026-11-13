import Foundation
import SwiftData

/// Owns the long-lived services. A singleton because iOS can launch the app in the background
/// (finished download, background task) before any UI exists.
final class AppEnvironment {
    static let shared = AppEnvironment()

    let container: ModelContainer
    let processing: ProcessingQueue
    let downloads: DownloadManager
    let feeds: FeedService
    let player: PlayerController
    let cloudSync: CloudSync

    private init() {
        AppSettings.registerDefaults()
        Storage.removeObsoleteFiles()
        do {
            container = try ModelContainer(for: Show.self, Episode.self, MutedTerm.self)
        } catch {
            fatalError("Could not create the data store: \(error)")
        }
        let context = container.mainContext
        processing = ProcessingQueue(context: context)
        downloads = DownloadManager(context: context, processing: processing)
        feeds = FeedService(context: context, downloads: downloads)
        player = PlayerController(context: context, processing: processing, downloads: downloads)
        cloudSync = CloudSync(context: context, feeds: feeds, player: player)
        cloudSync.start()

        processing.resetInterrupted()
        Task {
            await downloads.reconcile()
            processing.start()
        }
    }
}
