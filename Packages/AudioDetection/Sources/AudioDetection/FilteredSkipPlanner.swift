import Foundation

/// Chooses the end of a filtered passage. The caller supplies sorted, merged ranges and
/// keeps an audio mute over those ranges so a delayed seek cannot expose their contents.
public enum FilteredSkipPlanner {
    public static func destination(at time: Double, ranges: [ClosedRange<Double>], duration: Double,
                                   lead: Double = 0) -> Double? {
        guard time.isFinite, duration.isFinite, duration > 0 else { return nil }
        let lead = max(0, lead)
        var destination: Double?
        for range in ranges {
            guard range.lowerBound.isFinite, range.upperBound.isFinite else { continue }
            let position = destination ?? time
            if position < range.lowerBound - lead { break }
            if position <= range.upperBound + 0.015 && position >= range.lowerBound - lead {
                destination = min(duration, range.upperBound + 0.025)
            }
        }
        return destination
    }
}
