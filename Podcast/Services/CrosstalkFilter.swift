import AudioDetection
import Foundation
import KeywordSpotting

/// Crosstalk (people talking over each other) is where the transcriber misses words. Instead of
/// skipping it, a keyword spotter listens to just those clips for the muted words, and only
/// what it hears is muted. The rest of the crosstalk plays.
nonisolated enum CrosstalkFilter {
    /// What the spotter listens for. Terms it can't spell (no English letters) are left out.
    static func keywords(for terms: [String]) -> Set<String> {
        Set(terms.compactMap(OverlapKeywordCheck.keyword(for:)))
    }

    /// The clips to listen to. Independent of mute padding, so changing padding keeps results.
    static func clips(in scan: OverlapScan) -> [ClosedRange<Double>] {
        scan.skipRanges(padding: 0)
    }

    /// The spotter reports token onsets, so the mute runs a little past the last one and
    /// covers at least a short word's length.
    static func muteRange(for hit: AudioDetectionHit, padding: Double) -> ClosedRange<Double> {
        max(0, hit.firstToken - padding)...(max(hit.lastToken + 0.25, hit.firstToken + 0.45) + padding)
    }

    static func check(fileURL: URL, episodeID: String, scan: OverlapScan,
                      keywords: Set<String>) async throws -> OverlapKeywordCheck {
        try await OverlapKeywordSpotter.shared.check(fileURL: fileURL, episodeID: episodeID,
                                                     clips: clips(in: scan), keywords: keywords)
    }

    static func savedCheck(fileURL: URL, episodeID: String, scan: OverlapScan) -> OverlapKeywordCheck? {
        OverlapKeywordStore().load(episodeID: episodeID, fileURL: fileURL, clips: clips(in: scan))
    }

    static func remove(episodeID: String) {
        OverlapKeywordStore().remove(episodeID: episodeID)
    }
}
