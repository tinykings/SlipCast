import SwiftData
import SwiftUI
import UIKit

@main
struct SlipCastApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let env = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env.player)
                .environment(env.downloads)
                .environment(env.processing)
                .environment(env.feeds)
        }
        .modelContainer(env.container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                env.processing.start()
                env.cloudSync.refresh()
                Task { await env.feeds.refreshIfStale() }
            case .background:
                BackgroundWork.scheduleRefresh()
                BackgroundWork.scheduleProcessing()
            default:
                break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = AppEnvironment.shared
        BackgroundWork.register()
        return true
    }

    /// iOS relaunched us in the background to deliver finished downloads.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        AppEnvironment.shared.downloads.backgroundCompletionHandler = completionHandler
    }
}
