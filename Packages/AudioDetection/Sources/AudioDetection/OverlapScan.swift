import CryptoKit
import Foundation

public struct OverlapRegion: Codable, Sendable, Equatable {
    public let start: Double
    public let end: Double
    public var range: ClosedRange<Double> { start...end }
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public struct OverlapScan: Codable, Sendable {
    public static let engine = "pyannote3-fp32-hop2p5-center-on0p9-off0p7-v2"
    /// Shorter passages are usually laughter or a quick "yeah" over the other speaker.
    public static let minimumSkip = 0.75
    public let fingerprint: ReviewedAudioFingerprint
    public let duration: Double
    public private(set) var nextWindow = 0
    public private(set) var regions: [OverlapRegion] = []
    public private(set) var elapsed = 0.0
    private let engine: String

    public var windowCount: Int {
        guard duration.isFinite, duration > 0, duration < Double(Int.max / 2) else { return 0 }
        return max(1, Int(ceil(max(0, duration - 10) / 2.5)) + 1)
    }
    public var isComplete: Bool { windowCount > 0 && nextWindow == windowCount }
    public var scannedThrough: Double { isComplete ? duration : min(duration, Double(nextWindow) * 2.5) }
    public var fraction: Double { windowCount > 0 ? Double(nextWindow) / Double(windowCount) : 0 }

    init(fingerprint: ReviewedAudioFingerprint, duration: Double) {
        self.fingerprint = fingerprint
        self.duration = duration
        self.engine = Self.engine
    }

    mutating func append(window: Int, regions: [OverlapRegion], elapsed: Double) throws {
        guard window == nextWindow, window < windowCount, elapsed.isFinite, elapsed >= 0,
              regions.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.start < $0.end && $0.end <= duration }) else {
            throw EpisodeAudioScanError.invalidCheckpoint
        }
        self.regions = Self.merge(self.regions + regions, gap: 0.15)
        nextWindow += 1
        self.elapsed += elapsed
    }

    public func skipRanges(padding: Double) -> [ClosedRange<Double>] {
        let padding = padding.isFinite ? max(0, padding) : 0.2
        return Self.merge(regions.filter { $0.end - $0.start >= Self.minimumSkip }.map {
            OverlapRegion(start: max(0, $0.start - padding), end: min(duration, $0.end + padding))
        }, gap: 0.08).map(\.range)
    }

    var isValid: Bool {
        engine == Self.engine && windowCount > 0 && (0...windowCount).contains(nextWindow) &&
        elapsed.isFinite && elapsed >= 0 && regions.allSatisfy {
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.start < $0.end && $0.end <= duration
        }
    }

    static func merge(_ regions: [OverlapRegion], gap: Double) -> [OverlapRegion] {
        var output: [OverlapRegion] = []
        for region in regions.sorted(by: { $0.start < $1.start }) {
            if let last = output.last, region.start <= last.end + gap {
                output[output.count - 1] = OverlapRegion(start: last.start, end: max(last.end, region.end))
            } else { output.append(region) }
        }
        return output
    }
}

public struct OverlapScanStore: Sendable {
    private let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("FastOverlapScans", isDirectory: true)
    }
    public func load(episodeID: String, fileURL: URL) throws -> OverlapScan? {
        let url = path(episodeID)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url), let scan = try? JSONDecoder().decode(OverlapScan.self, from: data),
              scan.isValid, scan.fingerprint == (try ReviewedMuteStore.fingerprint(fileURL)) else { return nil }
        return scan
    }
    public func save(_ scan: OverlapScan, episodeID: String, fileURL: URL) throws {
        guard scan.isValid else { throw EpisodeAudioScanError.invalidCheckpoint }
        guard scan.fingerprint == (try ReviewedMuteStore.fingerprint(fileURL)) else { throw EpisodeAudioScanError.changedDownload }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try folder.setResourceValues(flags)
        try JSONEncoder().encode(scan).write(to: path(episodeID), options: .atomic)
    }
    public func remove(episodeID: String) throws {
        let url = path(episodeID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func path(_ id: String) -> URL {
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
}
