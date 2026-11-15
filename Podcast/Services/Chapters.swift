import AVFoundation
import Foundation

/// A titled section of an episode, starting at `start` seconds.
nonisolated struct Chapter: Identifiable, Hashable, Codable, Sendable {
    var id: Int
    var start: Double
    var title: String
}

/// Chapters come from the audio file itself (MP4/M4A chapter tracks, and ID3 chapters where
/// AVFoundation reads them) or from the feed's Podcasting 2.0 `podcast:chapters` JSON.
nonisolated enum Chapters {
    // MARK: Embedded

    static func embedded(in asset: AVAsset) async -> [Chapter] {
        // AVAsset isn't Sendable, but its async load methods are safe to call from any thread.
        // Without this, the compiler rejects passing the caller's asset to them.
        nonisolated(unsafe) let asset = asset
        var groups = (try? await asset.loadChapterMetadataGroups(
            bestMatchingPreferredLanguages: Locale.preferredLanguages)) ?? []
        if groups.isEmpty, let locale = (try? await asset.load(.availableChapterLocales))?.first {
            groups = (try? await asset.loadChapterMetadataGroups(
                withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyTitle])) ?? []
        }
        var chapters: [Chapter] = []
        for group in groups {
            let start = group.timeRange.start.seconds
            guard start.isFinite else { continue }
            let item = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            var title: String?
            if let item { title = try? await item.load(.stringValue) }
            chapters.append(Chapter(id: 0, start: start, title: title ?? ""))
        }
        return normalized(chapters)
    }

    // MARK: Published

    /// The Podcasting 2.0 JSON chapters format. Chapters with `toc: false` aren't meant for the
    /// chapter list.
    private struct Document: Decodable {
        struct Item: Decodable {
            let startTime: Double
            let title: String?
            let toc: Bool?
        }
        let chapters: [Item]
    }

    static func cacheURL(for episodeID: String) -> URL {
        Storage.transcriptsDirectory.appending(path: "\(episodeID).chapters.json")
    }

    static func cached(episodeID: String) -> [Chapter]? {
        guard let data = try? Data(contentsOf: cacheURL(for: episodeID)) else { return nil }
        return try? JSONDecoder().decode([Chapter].self, from: data)
    }

    static func delete(episodeID: String) {
        try? FileManager.default.removeItem(at: cacheURL(for: episodeID))
    }

    /// The cached chapters, or downloads, parses and caches them.
    @concurrent
    static func published(episodeID: String, url: String) async throws -> [Chapter] {
        if let cached = cached(episodeID: episodeID) { return cached }
        guard let remote = URL(string: url) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: remote)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let chapters = try parse(data)
        try? JSONEncoder().encode(chapters).write(to: cacheURL(for: episodeID), options: .atomic)
        return chapters
    }

    static func parse(_ data: Data) throws -> [Chapter] {
        let document = try JSONDecoder().decode(Document.self, from: data)
        return normalized(document.chapters
            .filter { $0.toc != false }
            .map { Chapter(id: 0, start: $0.startTime, title: $0.title ?? "") })
    }

    /// Sorted, one chapter per start time, untitled ones numbered, ids in order.
    static func normalized(_ chapters: [Chapter]) -> [Chapter] {
        var seen = Set<Double>()
        let sorted = chapters
            .filter { $0.start.isFinite && $0.start >= 0 }
            .sorted { $0.start < $1.start }
            .filter { seen.insert(($0.start * 10).rounded()).inserted }
        return sorted.enumerated().map { index, chapter in
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return Chapter(id: index, start: chapter.start, title: title.isEmpty ? "Chapter \(index + 1)" : title)
        }
    }
}
