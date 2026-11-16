import Foundation
import UIKit
import UserNotifications

/// Posts one summary notification for automatic downloads that finish while the app isn't open,
/// e.g. after the daily refresh. Each new download replaces the notification with an updated
/// count, so a night's downloads show up as one "3 new episodes" alert instead of three.
///
/// Downloads the user started themselves, and ones that finish with the app open, don't notify.
enum NewEpisodeNotifier {
    private static let automaticKey = "notifier.automaticDownloads"
    private static let pendingKey = "notifier.pendingEpisodes"
    private static let notificationID = "new-episodes"
    private static let pendingLimit = 50

    private struct Entry: Codable {
        let showTitle: String
        let episodeTitle: String
        let filtered: Bool
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Called when an automatic download starts, so its completion can be told apart from the user's.
    static func markAutomatic(_ episodeID: String) {
        var ids = automaticIDs
        ids.insert(episodeID)
        automaticIDs = ids
    }

    /// The download was cancelled or failed; a later retry is marked again if it's automatic.
    static func forget(_ episodeID: String) {
        var ids = automaticIDs
        guard ids.remove(episodeID) != nil else { return }
        automaticIDs = ids
    }

    static func downloaded(_ episode: Episode) {
        var ids = automaticIDs
        guard ids.remove(episode.episodeID) != nil else { return }
        automaticIDs = ids
        guard AppSettings.notifyNewEpisodes, UIApplication.shared.applicationState != .active else { return }

        var entries = pending
        entries.append(Entry(showTitle: episode.show?.title ?? "", episodeTitle: episode.title,
                             filtered: episode.requiresFiltering))
        pending = Array(entries.suffix(pendingLimit))
        post(pending)
    }

    /// The user is looking at the app now, so the summary is out of date.
    static func appBecameActive() {
        guard !pending.isEmpty else { return }
        pending = []
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
    }

    private static func post(_ entries: [Entry]) {
        guard let first = entries.first else { return }
        let content = UNMutableNotificationContent()
        let filteredNote = "Filtered episodes play once muted words are prepared."
        if entries.count == 1 {
            content.title = first.showTitle.isEmpty ? "New episode" : "New episode from \(first.showTitle)"
            content.body = first.filtered ? "\(first.episodeTitle)\n\(filteredNote)" : first.episodeTitle
        } else {
            content.title = "\(entries.count) new episodes"
            var shows: [String] = []
            for entry in entries where !entry.showTitle.isEmpty && !shows.contains(entry.showTitle) {
                shows.append(entry.showTitle)
            }
            var body = listed(shows)
            if entries.contains(where: \.filtered) { body += body.isEmpty ? filteredNote : "\n\(filteredNote)" }
            content.body = body
        }
        content.sound = .default
        content.threadIdentifier = notificationID
        let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// "A", "A and B", "A, B and C", "A, B and 3 more".
    private static func listed(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    // MARK: Storage

    /// Kept on disk: iOS may relaunch the app just to deliver a finished download.
    private static var automaticIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: automaticKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: automaticKey) }
    }

    private static var pending: [Entry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return [] }
            return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: pendingKey)
            } else {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: pendingKey)
            }
        }
    }
}
