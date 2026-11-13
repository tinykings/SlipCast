import BackgroundTasks
import Foundation

/// Background feed refresh (BGAppRefreshTask) and transcription (BGProcessingTask).
/// iOS decides when these actually run based on usage, battery and charging.
enum BackgroundWork {
    static let refreshID = "com.tinyking.slipcast.refresh"
    static let processID = "com.tinyking.slipcast.process"

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: .main) { task in
            let box = UncheckedBox(task)
            MainActor.assumeIsolated { handleRefresh(box.value) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processID, using: .main) { task in
            let box = UncheckedBox(task)
            MainActor.assumeIsolated {
                guard let task = box.value as? BGProcessingTask else { return }
                AppEnvironment.shared.processing.run(in: task)
            }
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func scheduleProcessing() {
        guard !AppEnvironment.shared.processing.isPaused, AppEnvironment.shared.processing.hasPendingWork else { return }
        let request = BGProcessingTaskRequest(identifier: processID)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleRefresh(_ task: BGTask) {
        scheduleRefresh()
        let box = UncheckedBox(task)
        let work = Task {
            await AppEnvironment.shared.feeds.refreshAll()
            box.value.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { @Sendable in work.cancel() }
    }
}
