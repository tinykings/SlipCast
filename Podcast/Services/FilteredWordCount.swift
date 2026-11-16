import AudioDetection
import Foundation

/// How many muted words were found in a processed episode, for episode lists: matches in the
/// transcript plus muted words heard in crosstalk.
enum FilteredWordCount {
    private static var cache: [String: (terms: [String], count: Int)] = [:]

    /// The count worked out earlier for this mute list, if any.
    static func cached(episodeID: String, terms: [String]) -> Int? {
        guard let entry = cache[episodeID], entry.terms == terms else { return nil }
        return entry.count
    }

    /// The episode is being processed again, or its files are gone.
    static func forget(episodeID: String) {
        cache[episodeID] = nil
    }

    /// Nil when the episode has no usable transcript.
    static func count(episodeID: String, fileURL: URL?, terms: [String]) async -> Int? {
        if let cached = cached(episodeID: episodeID, terms: terms) { return cached }
        guard let count = await compute(episodeID: episodeID, fileURL: fileURL, terms: terms) else { return nil }
        cache[episodeID] = (terms, count)
        return count
    }

    /// Reads the transcript (thousands of words) off the main thread.
    @concurrent
    nonisolated private static func compute(episodeID: String, fileURL: URL?, terms: [String]) async -> Int? {
        guard TranscriptStore.isCurrent(episodeID: episodeID),
              let words = try? TranscriptStore.load(episodeID: episodeID) else { return nil }
        var count = MuteMatcher.matchedWords(in: words, rules: terms.map(MuteRule.init(phrase:))).count

        let keywords = CrosstalkFilter.keywords(for: terms)
        if !keywords.isEmpty, let fileURL,
           let scan = try? OverlapScanStore().load(episodeID: episodeID, fileURL: fileURL), scan.isComplete,
           let check = CrosstalkFilter.savedCheck(fileURL: fileURL, episodeID: episodeID, scan: scan),
           check.covers(keywords) {
            count += check.hits(for: keywords).count
        }
        return count
    }
}
