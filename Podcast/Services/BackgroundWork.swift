import BackgroundTasks
import Foundation

/// Background feed refresh (BGAppRefreshTask), a daily refresh while charging (BGProcessingTask)
/// and transcription (BGProcessingTask).
/// iOS decides when these actually run based on usage, battery and charging.
enum BackgroundWork {
    static let refreshID = "com.tinyking.slipcast.refresh"
    static let processID = "com.tinyking.slipcast.process"
    static let dailyRefreshID = "com.tinyking.slipcast.dailyrefresh"

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
        BGTaskScheduler.shared.register(forTaskWithIdentifier: dailyRefreshID, using: .main) { task in
            let box = UncheckedBox(task)
            MainActor.assumeIsolated { handleDailyRefresh(box.value) }
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// App refresh tasks rarely run for apps that aren't opened often, so this asks for a
    /// processing task too. iOS is much more willing to run those while the phone is charging
    /// (usually overnight), and gives them minutes rather than seconds.
    static func scheduleDailyRefresh() {
        let request = BGProcessingTaskRequest(identifier: dailyRefreshID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        // Counted from the last daily run rather than from now, so resubmitting every time the
        // app goes to the background doesn't keep pushing it back.
        let lastRun = UserDefaults.standard.object(forKey: lastDailyRefreshKey) as? Date ?? .distantPast
        request.earliestBeginDate = max(Date.now, lastRun.addingTimeInterval(20 * 60 * 60))
        try? BGTaskScheduler.shared.submit(request)
    }

    private static let lastDailyRefreshKey = "lastDailyRefresh"

    static func scheduleProcessing() {
        guard !AppEnvironment.shared.processing.isPaused, AppEnvironment.shared.processing.hasPendingWork else { return }
        let request = BGProcessingTaskRequest(identifier: processID)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Matches the `com.tinyking.slipcast.transcribe.*` wildcard in Info.plist.
    static let continuedID = "com.tinyking.slipcast.transcribe.episodes"
    private static var continuedRegistered = false

    /// Starts a BGContinuedProcessingTask so transcription keeps going (with system progress UI)
    /// after the user leaves the app. Must be called while the app is in the foreground.
    /// Returns false if iOS can't run it right now; the queue then falls back to BGProcessingTask.
    static func submitContinuedProcessing(title: String, subtitle: String) -> Bool {
        if !continuedRegistered {
            continuedRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedID, using: .main) { task in
                let box = UncheckedBox(task)
                MainActor.assumeIsolated {
                    guard let task = box.value as? BGContinuedProcessingTask else {
                        box.value.setTaskCompleted(success: false)
                        return
                    }
                    AppEnvironment.shared.processing.attach(task)
                }
            }
            guard continuedRegistered else { return false }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: continuedID, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
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

    /// New episodes for auto-download shows are handed to the background URLSession, which keeps
    /// downloading after this task ends; finished downloads then queue their own processing.
    private static func handleDailyRefresh(_ task: BGTask) {
        let box = UncheckedBox(task)
        let work = Task {
            await AppEnvironment.shared.feeds.refreshAll()
            let finished = !Task.isCancelled
            if finished { UserDefaults.standard.set(Date.now, forKey: lastDailyRefreshKey) }
            scheduleDailyRefresh()
            box.value.setTaskCompleted(success: finished)
        }
        task.expirationHandler = { @Sendable in work.cancel() }
    }
}
