import CryptoKit
import Foundation

public struct ReviewedAudioFingerprint: Codable, Equatable, Sendable {
    let filename: String
    let size: UInt64
    let modified: Date
    let edgeHash: String
}

public enum ReviewedMuteError: LocalizedError {
    case changedDownload
    case invalidRanges
    case unsupportedVersion

    public var errorDescription: String? {
        switch self {
        case .changedDownload: "This download changed. Analyze it again before applying these mutes."
        case .invalidRanges: "The reviewed mute times are invalid. Analyze this section again."
        case .unsupportedVersion: "These saved mutes use an unsupported format. Remove them and analyze the section again."
        }
    }
}

/// Reviewed timing is tied to the exact local download: ad insertion can change a new copy.
public struct ReviewedMuteStore: Sendable {
    private struct Range: Codable {
        let start: Double
        let end: Double
        var value: ClosedRange<Double> { start...end }
        init(_ value: ClosedRange<Double>) { start = value.lowerBound; end = value.upperBound }
    }
    private struct Record: Codable {
        var version = 1
        let fingerprint: ReviewedAudioFingerprint
        var words: [String: [Range]]
    }
    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReviewedAudioMutes", isDirectory: true)
    }

    public static func fingerprint(_ file: URL) throws -> ReviewedAudioFingerprint {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = UInt64(values.fileSize ?? 0)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var edges = try handle.read(upToCount: 65_536) ?? Data()
        if size > 65_536 {
            try handle.seek(toOffset: max(65_536, size > 65_536 ? size - 65_536 : 0))
            edges.append(try handle.read(upToCount: 65_536) ?? Data())
        }
        return ReviewedAudioFingerprint(
            filename: file.lastPathComponent, size: size,
            modified: values.contentModificationDate ?? .distantPast,
            edgeHash: SHA256.hash(data: edges).map { String(format: "%02x", $0) }.joined()
        )
    }

    public func apply(
        episodeID: String, fileURL: URL, expectedFingerprint: ReviewedAudioFingerprint,
        keyword: String, section: ClosedRange<Double>, ranges: [ClosedRange<Double>]
    ) throws {
        guard !keyword.isEmpty, section.lowerBound.isFinite, section.upperBound.isFinite,
              section.lowerBound >= 0, section.lowerBound < section.upperBound,
              ranges.allSatisfy({ $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.lowerBound <= $0.upperBound }) else {
            throw ReviewedMuteError.invalidRanges
        }
        let fingerprint = try Self.fingerprint(fileURL)
        guard fingerprint == expectedFingerprint else { throw ReviewedMuteError.changedDownload }
        var record = try read(episodeID).flatMap { $0.fingerprint == fingerprint ? $0 : nil }
            ?? Record(fingerprint: fingerprint, words: [:])
        let word = keyword.lowercased()
        var kept: [ClosedRange<Double>] = []
        // Replace this word's reviewed coverage only inside the newly reviewed section.
        for range in (record.words[word] ?? []).map(\.value) {
            if !range.overlaps(section) { kept.append(range); continue }
            if range.lowerBound < section.lowerBound { kept.append(range.lowerBound...section.lowerBound) }
            if range.upperBound > section.upperBound { kept.append(section.upperBound...range.upperBound) }
        }
        for range in ranges {
            let start = max(section.lowerBound, range.lowerBound)
            let end = min(section.upperBound, range.upperBound)
            if start < end { kept.append(start...end) }
        }
        record.words[word] = Self.merge(kept).map(Range.init)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try folder.setResourceValues(flags)
        try JSONEncoder().encode(record).write(to: path(episodeID), options: .atomic)
    }

    public func ranges(episodeID: String, fileURL: URL) throws -> [ClosedRange<Double>] {
        guard let record = try read(episodeID), record.fingerprint == (try Self.fingerprint(fileURL)) else { return [] }
        let ranges = record.words.values.flatMap { $0 }.map(\.value)
        return Self.merge(ranges)
    }

    public func remove(episodeID: String) throws {
        let url = path(episodeID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func path(_ episodeID: String) -> URL {
        let key = SHA256.hash(data: Data(episodeID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }

    private func read(_ episodeID: String) throws -> Record? {
        let url = path(episodeID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.version == 1 else { throw ReviewedMuteError.unsupportedVersion }
        guard record.words.values.flatMap({ $0 }).allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.start < $0.end }) else {
            throw ReviewedMuteError.invalidRanges
        }
        return record
    }

    private static func merge(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, last.upperBound >= range.lowerBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else { result.append(range) }
        }
        return result
    }
}
