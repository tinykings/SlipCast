import CryptoKit
import Foundation

/// On-disk locations. Everything lives in Application Support and is excluded from iCloud backup.
nonisolated enum Storage {
    static var episodesDirectory: URL { directory(named: "Episodes") }
    static var transcriptsDirectory: URL { directory(named: "Transcripts") }

    static func stableID(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func episodeID(feedURL: String, guid: String) -> String {
        stableID("\(feedURL)|\(guid)")
    }

    static var bytesUsed: Int64 {
        let urls = [episodesDirectory, transcriptsDirectory]
        var total: Int64 = 0
        for dir in urls {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for file in files {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    private static func directory(named name: String) -> URL {
        var url = URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return url
    }
}

nonisolated enum AppSettings {
    static let paddingKey = "mutePaddingMs"
    static let wifiOnlyKey = "autoDownloadWiFiOnly"
    static let autoDownloadNewKey = "autoDownloadNewSubscriptions"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            paddingKey: 200.0,
            wifiOnlyKey: true,
            autoDownloadNewKey: true,
        ])
    }

    /// Extra silence on each side of a muted word, in seconds. ASR word boundaries are approximate.
    static var padding: Double { UserDefaults.standard.double(forKey: paddingKey) / 1000 }
    static var wifiOnly: Bool { UserDefaults.standard.bool(forKey: wifiOnlyKey) }
    static var autoDownloadNew: Bool { UserDefaults.standard.bool(forKey: autoDownloadNewKey) }
}
