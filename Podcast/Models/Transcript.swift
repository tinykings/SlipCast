import Foundation

/// One recognized word with its position in the episode audio, in seconds.
nonisolated struct TranscriptWord: Codable, Sendable, Hashable {
    var text: String
    var start: Double
    var end: Double
}

/// Transcripts are stored as JSON files (not SwiftData rows) since an hour of audio is ~10k words.
/// The transcript is kept permanently so changing the mute list only re-runs matching.
nonisolated enum TranscriptStore {
    static func url(for episodeID: String) -> URL {
        Storage.transcriptsDirectory.appending(path: "\(episodeID).json")
    }

    static func save(_ words: [TranscriptWord], episodeID: String) throws {
        let data = try JSONEncoder().encode(words)
        try data.write(to: url(for: episodeID), options: .atomic)
    }

    static func load(episodeID: String) throws -> [TranscriptWord] {
        let data = try Data(contentsOf: url(for: episodeID))
        return try JSONDecoder().decode([TranscriptWord].self, from: data)
    }

    static func delete(episodeID: String) {
        try? FileManager.default.removeItem(at: url(for: episodeID))
    }
}
