import Foundation
import SwiftData

/// Backs up subscriptions, played history and settings to the iCloud key-value store, so they
/// come back after a reinstall and stay in step across the user's devices. Downloads,
/// transcripts and scans aren't synced; each device rebuilds them.
///
/// Each synced item is an entry with a modification time; the newest entry wins. A local
/// ledger remembers what this device last agreed with iCloud, which is how local changes are
/// noticed (and timestamped) without hooking every place that edits a show or episode.
///
/// Layout (iCloud allows 1 MB and 1024 keys in total):
/// - `show.<hash>`: one key per show, so subscribing on one device never overwrites another
///   device's list. Unsubscribing leaves a deleted entry so the show isn't brought back.
/// - `setting.<name>`: one key per setting, muted words included.
/// - `history.v1`: played state and position for each episode, capped at the newest entries.
@MainActor
final class CloudSync {
    private let store: any KeyValueStore
    private let context: ModelContext
    private let feeds: FeedService
    private let player: PlayerController

    private var ledger: Ledger
    private var scheduled: Task<Void, Never>?
    /// Until iCloud has delivered this install's first download (or had the chance to),
    /// nothing is written, so a fresh install can't overwrite the backup it's about to restore.
    private var cloudReady = false
    private var restoring: Set<String> = []
    private var restoreAttempts: [String: Date] = [:]
    private var observers: [NSObjectProtocol] = []
    /// The synced settings in UserDefaults as last seen. UserDefaults reports every change,
    /// including keys that aren't synced (playback speed, sleep timer, refresh dates), so a
    /// pass is only scheduled when one of these is different.
    private var lastSyncedDefaults: [String: SettingValue] = [:]

    private static let historyKey = "history.v1"
    private static let showPrefix = "show."
    private static let settingPrefix = "setting."
    static let historyLimit = 4000

    init(store: any KeyValueStore = NSUbiquitousKeyValueStore.default, context: ModelContext,
         feeds: FeedService, player: PlayerController) {
        self.store = store
        self.context = context
        self.feeds = feeds
        self.player = player
        ledger = Ledger.load()
    }

    func start() {
        store.synchronize()
        cloudReady = ledger.initialized || store.keys.contains { Self.isSyncKey($0) }
        lastSyncedDefaults = SyncedSettings.readDefaults()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cloudReady = true
                    self?.schedule(after: 0)
                }
            },
            center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
                // Notification isn't Sendable, so pull out the (Sendable) identifiers first.
                let changes = SaveChanges(note)
                MainActor.assumeIsolated {
                    guard let self, !self.isPositionOnlySave(changes) else { return }
                    self.schedule()
                }
            },
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.defaultsChanged() }
            },
        ]
        // Positions saved every few seconds during playback sync when playback pauses or stops.
        player.onPositionCheckpoint = { [weak self] in self?.schedule() }
        if !cloudReady {
            // A brand-new iCloud account may never send an initial download.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.cloudReady = true
                self?.schedule(after: 0)
            }
        }
        schedule(after: 0)
    }

    /// Called when the app comes to the foreground.
    func refresh() {
        store.synchronize()
        schedule(after: 0)
    }

    /// Called when the app goes to the background, so the latest position is backed up even if
    /// the app is suspended before a scheduled pass runs.
    func syncNow() {
        scheduled?.cancel()
        scheduled = nil
        sync()
    }

    /// True for the save the player makes every few seconds during playback: only the current
    /// episode changed, and not its played state, so only its position can be different.
    /// Anything the notification doesn't describe counts as a real change.
    private func isPositionOnlySave(_ changes: SaveChanges) -> Bool {
        guard let current = player.episode, let updated = changes.updated,
              updated == [current.persistentModelID] else { return false }
        guard changes.inserted.isEmpty, changes.deleted.isEmpty else { return false }
        let syncedPlayed = ledger.history.entries[current.episodeID]?.value?.played ?? false
        return current.isPlayed == syncedPlayed
    }

    private func defaultsChanged() {
        let current = SyncedSettings.readDefaults()
        guard current != lastSyncedDefaults else { return }
        lastSyncedDefaults = current
        schedule()
    }

    private func schedule(after delay: Double = 2) {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    // MARK: - Sync pass

    private func sync() {
        // Before this device's first sync, its existing data predates sync: it's stamped 0 so
        // anything already in iCloud wins, while data iCloud lacks is still backed up.
        let now = ledger.initialized ? Int(Date.now.timeIntervalSince1970) : 0
        syncShows(now: now)
        syncHistory(now: now)
        syncSettings(now: now)
        // Only once iCloud has had its chance to deliver: otherwise a relaunch before the first
        // download would treat local data as current and could overwrite the backup.
        if cloudReady { ledger.initialized = true }
        ledger.save()
    }

    private func syncShows(now: Int) {
        let shows = (try? context.fetch(FetchDescriptor<Show>())) ?? []
        let byURL = Dictionary(shows.map { ($0.feedURL, $0) }, uniquingKeysWith: { first, _ in first })
        let local = byURL.filter { !restoring.contains($0.key) }.mapValues(SyncedShow.init)
        let remote = readPerKey(SyncedShow.self, prefix: Self.showPrefix)
        let merged = ledger.shows.reconcile(local: local, remote: remote, absentMeansDeleted: true,
                                            isDefault: { _, _ in false }, now: now) { feedURL, entry in
            guard let synced = entry.value else {
                if let show = byURL[feedURL] { unsubscribe(show) }
                return true
            }
            guard let show = byURL[feedURL] else {
                restore(feedURL, entry)
                return false
            }
            if show.autoDownload != synced.autoDownload { show.autoDownload = synced.autoDownload }
            if show.filteringEnabled != synced.filtering {
                show.filteringEnabled = synced.filtering
                player.filteringChanged(for: show)
            }
            if let artwork = synced.directoryArtwork { show.directoryArtworkURL = artwork }
            return true
        }
        writePerKey(merged, remote: remote, prefix: Self.showPrefix)
        if context.hasChanges { try? context.save() }
    }

    private func syncHistory(now: Int) {
        let episodes = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
        let byID = Dictionary(episodes.map { ($0.episodeID, $0) }, uniquingKeysWith: { first, _ in first })
        let local = byID.mapValues { PlayState(played: $0.isPlayed, position: Int($0.playbackPosition)) }
        let remote = read([String: SyncEntry<PlayState>].self, key: Self.historyKey)
        var merged = ledger.history.reconcile(local: local, remote: remote ?? [:], absentMeansDeleted: false,
                                              isDefault: { _, state in state.isDefault }, now: now) { id, entry in
            guard let state = entry.value else { return true }
            guard let episode = byID[id] else { return false } // not in the feed here yet
            if episode.isPlayed != state.played { episode.isPlayed = state.played }
            if Int(episode.playbackPosition) != state.position {
                // Don't move the episode that's playing; its own position is newer.
                if player.isCurrent(episode) { return false }
                episode.playbackPosition = Double(state.position)
            }
            return true
        }
        SyncLedger.pruneHistory(&merged, now: now, limit: Self.historyLimit)
        ledger.history.retain(merged.keys)
        // Never replaces history in a format this version can't read.
        let unreadable = remote == nil && store.data(forKey: Self.historyKey) != nil
        if cloudReady, !unreadable, merged != (remote ?? [:]), let data = try? JSONEncoder().encode(merged) {
            store.set(data, forKey: Self.historyKey)
        }
        if context.hasChanges { try? context.save() }
    }

    private func syncSettings(now: Int) {
        let terms = (try? context.fetch(FetchDescriptor<MutedTerm>())) ?? []
        let local = SyncedSettings.read(terms: terms)
        let remote = readPerKey(SettingValue.self, prefix: Self.settingPrefix)
        var mutingChanged = false
        let merged = ledger.settings.reconcile(local: local, remote: remote, absentMeansDeleted: false,
                                               isDefault: { key, value in SyncedSettings.defaults[key] == value },
                                               now: now) { key, entry in
            guard let value = entry.value, SyncedSettings.defaults[key] != nil else { return true }
            if key == SyncedSettings.mutedTermsKey, case .list(let texts) = value {
                let wanted = Set(texts)
                for term in terms where !wanted.contains(term.text) { context.delete(term) }
                for text in wanted.subtracting(terms.map(\.text)) { context.insert(MutedTerm(text: text)) }
                mutingChanged = true
            } else {
                // Recorded first, so applying iCloud's value doesn't look like a local change
                // and schedule another pass.
                lastSyncedDefaults[key] = value
                SyncedSettings.write(value, key: key)
                if key == AppSettings.paddingKey { mutingChanged = true }
            }
            return true
        }
        writePerKey(merged, remote: remote, prefix: Self.settingPrefix)
        if context.hasChanges { try? context.save() }
        if mutingChanged { player.refreshMuting() }
    }

    // MARK: - Applying shows

    private func unsubscribe(_ show: Show) {
        if let current = player.episode, current.show?.feedURL == show.feedURL { player.stop() }
        feeds.unsubscribe(show)
    }

    /// Resubscribes to a show subscribed on another device or before a reinstall.
    private func restore(_ feedURL: String, _ entry: SyncEntry<SyncedShow>) {
        guard let synced = entry.value, !restoring.contains(feedURL) else { return }
        if let last = restoreAttempts[feedURL], Date.now.timeIntervalSince(last) < 600 { return }
        restoring.insert(feedURL)
        restoreAttempts[feedURL] = .now
        Task {
            defer { restoring.remove(feedURL) }
            do {
                try await feeds.restore(feedURL: feedURL, synced)
                ledger.shows.entries[feedURL] = entry
                ledger.save()
                restoreAttempts[feedURL] = nil
            } catch {
                // Offline or the feed is down: try again on a later sync.
            }
            schedule(after: 0)
        }
    }

    // MARK: - Storage

    private static func isSyncKey(_ key: String) -> Bool {
        key == historyKey || key.hasPrefix(showPrefix) || key.hasPrefix(settingPrefix)
    }

    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        store.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func readPerKey<V>(_ type: V.Type, prefix: String) -> [String: SyncEntry<V>] {
        var result: [String: SyncEntry<V>] = [:]
        for key in store.keys where key.hasPrefix(prefix) {
            if let item = read(KeyedEntry<V>.self, key: key) { result[item.key] = item.entry }
        }
        return result
    }

    private func writePerKey<V>(_ merged: [String: SyncEntry<V>], remote: [String: SyncEntry<V>], prefix: String) {
        guard cloudReady else { return }
        for (key, entry) in merged where remote[key] != entry {
            if let data = try? JSONEncoder().encode(KeyedEntry(key: key, entry: entry)) {
                store.set(data, forKey: prefix + Storage.stableID(key))
            }
        }
    }
}

// MARK: - Synced values

nonisolated struct SyncedShow: Codable, Equatable, Sendable {
    var autoDownload: Bool
    var filtering: Bool
    /// Unix seconds. Keeps auto-download from fetching a back catalog after a restore.
    var subscribedAt: Int
    /// Directory artwork, used when the feed's own artwork won't load.
    var directoryArtwork: String?
}

extension SyncedShow {
    init(_ show: Show) {
        self.init(autoDownload: show.autoDownload, filtering: show.filteringEnabled,
                  subscribedAt: Int(show.subscribedAt.timeIntervalSince1970),
                  directoryArtwork: show.directoryArtworkURL)
    }
}

/// Encoded as `[played, seconds]` to keep the history small.
nonisolated struct PlayState: Codable, Equatable, Sendable {
    var played: Bool
    var position: Int

    var isDefault: Bool { !played && position == 0 }

    init(played: Bool, position: Int) {
        self.played = played
        self.position = position
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        played = try container.decode(Int.self) != 0
        position = try container.decode(Int.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(played ? 1 : 0)
        try container.encode(position)
    }
}

nonisolated enum SettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case text(String)
    case list([String])
}

/// The user's settings and muted words. Processing pause stays per device.
enum SyncedSettings {
    static let mutedTermsKey = "mutedTerms"
    static let librarySortKey = "librarySort"

    static let defaults: [String: SettingValue] = [
        AppSettings.paddingKey: .number(200),
        AppSettings.wifiOnlyKey: .bool(true),
        AppSettings.autoDownloadNewKey: .bool(true),
        AppSettings.autoDeletePlayedKey: .bool(false),
        librarySortKey: .text(LibrarySort.name.rawValue),
        mutedTermsKey: .list([]),
    ]

    static func read(terms: [MutedTerm]) -> [String: SettingValue] {
        var values = readDefaults()
        values[mutedTermsKey] = .list(Set(terms.map(\.text)).sorted())
        return values
    }

    /// The synced settings kept in UserDefaults: everything but the muted words.
    static func readDefaults() -> [String: SettingValue] {
        let defaults = UserDefaults.standard
        return [
            AppSettings.paddingKey: .number(defaults.double(forKey: AppSettings.paddingKey)),
            AppSettings.wifiOnlyKey: .bool(defaults.bool(forKey: AppSettings.wifiOnlyKey)),
            AppSettings.autoDownloadNewKey: .bool(defaults.bool(forKey: AppSettings.autoDownloadNewKey)),
            AppSettings.autoDeletePlayedKey: .bool(defaults.bool(forKey: AppSettings.autoDeletePlayedKey)),
            librarySortKey: .text(defaults.string(forKey: librarySortKey) ?? LibrarySort.name.rawValue),
        ]
    }

    static func write(_ value: SettingValue, key: String) {
        let defaults = UserDefaults.standard
        switch value {
        case .bool(let flag): defaults.set(flag, forKey: key)
        case .number(let number): defaults.set(number, forKey: key)
        case .text(let text): defaults.set(text, forKey: key)
        case .list: break
        }
    }
}

// MARK: - Ledger

nonisolated struct SyncEntry<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    /// nil marks a deletion (an unsubscribed show).
    var value: Value?
    /// Unix seconds. 0 means it existed before sync did.
    var modified: Int

    enum CodingKeys: String, CodingKey { case value = "v", modified = "m" }
}

/// Wraps a per-key entry with its real key, since stored keys are hashed.
nonisolated struct KeyedEntry<Value: Codable & Equatable & Sendable>: Codable, Sendable {
    var key: String
    var entry: SyncEntry<Value>
}

/// What this device last agreed with iCloud for one kind of item.
nonisolated struct SyncLedger<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var entries: [String: SyncEntry<Value>] = [:]

    /// Records local changes, merges with iCloud (newest wins, ties go to iCloud) and applies
    /// entries iCloud won. `apply` returns false when it couldn't be applied yet, leaving the
    /// entry to try again on a later sync. Returns the merged entries to store in iCloud.
    mutating func reconcile(
        local: [String: Value],
        remote: [String: SyncEntry<Value>],
        absentMeansDeleted: Bool,
        isDefault: (String, Value) -> Bool,
        now: Int,
        apply: (String, SyncEntry<Value>) -> Bool
    ) -> [String: SyncEntry<Value>] {
        capture(local, absentMeansDeleted: absentMeansDeleted, isDefault: isDefault, now: now)
        var merged = remote
        for (key, entry) in entries where (merged[key]?.modified ?? Int.min) < entry.modified {
            merged[key] = entry
        }
        for (key, entry) in merged where entries[key] != entry && apply(key, entry) {
            entries[key] = entry
        }
        return merged
    }

    mutating func capture(_ local: [String: Value], absentMeansDeleted: Bool,
                          isDefault: (String, Value) -> Bool, now: Int) {
        for (key, value) in local {
            if let entry = entries[key] {
                if entry.value != value { entries[key] = SyncEntry(value: value, modified: now) }
            } else if !isDefault(key, value) {
                entries[key] = SyncEntry(value: value, modified: now)
            }
        }
        if absentMeansDeleted {
            for (key, entry) in entries where entry.value != nil && local[key] == nil {
                entries[key] = SyncEntry(value: nil, modified: now)
            }
        }
    }

    mutating func retain(_ keys: some Sequence<String>) {
        let keep = Set(keys)
        entries = entries.filter { keep.contains($0.key) }
    }
}

extension SyncLedger where Value == PlayState {
    /// Drops unplayed-from-the-start entries after 30 days, then keeps the newest `limit`.
    nonisolated static func pruneHistory(_ entries: inout [String: SyncEntry<PlayState>], now: Int, limit: Int) {
        let cutoff = now - 30 * 86_400
        entries = entries.filter { !($0.value.value?.isDefault ?? true) || $0.value.modified > cutoff }
        if entries.count > limit {
            let kept = entries.sorted { $0.value.modified > $1.value.modified }.prefix(limit)
            entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
    }
}

/// All ledgers, saved as a local file (not UserDefaults, whose change notifications trigger syncs).
private nonisolated struct Ledger: Codable {
    var initialized = false
    var shows = SyncLedger<SyncedShow>()
    var history = SyncLedger<PlayState>()
    var settings = SyncLedger<SettingValue>()

    private static var url: URL { URL.applicationSupportDirectory.appending(path: "CloudSyncLedger.json") }

    static func load() -> Ledger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { return Ledger() }
        return ledger
    }

    func save() {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}

// MARK: - Store

protocol KeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    var keys: [String] { get }
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueStore {
    var keys: [String] { Array(dictionaryRepresentation.keys) }
}

/// The identifiers from a `ModelContext.didSave` notification.
nonisolated private struct SaveChanges: Sendable {
    let updated: [PersistentIdentifier]?
    let inserted: [PersistentIdentifier]
    let deleted: [PersistentIdentifier]

    init(_ note: Notification) {
        typealias Key = ModelContext.NotificationKey
        let info = note.userInfo
        updated = info?[Key.updatedIdentifiers.rawValue] as? [PersistentIdentifier]
        inserted = info?[Key.insertedIdentifiers.rawValue] as? [PersistentIdentifier] ?? []
        deleted = info?[Key.deletedIdentifiers.rawValue] as? [PersistentIdentifier] ?? []
    }
}
