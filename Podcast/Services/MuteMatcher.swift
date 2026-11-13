import Foundation

nonisolated struct MuteRule: Sendable, Hashable {
    let tokens: [String]

    init(phrase: String) {
        self.tokens = MuteMatcher.tokenize(phrase)
    }
}

/// Turns a transcript + mute list into the time ranges to silence. Pure and cheap: this re-runs
/// whenever the mute list changes, without re-transcribing or re-downloading anything.
nonisolated enum MuteMatcher {
    /// Lowercases, strips accents and punctuation: "Don't!" -> "dont".
    static func normalize(_ text: some StringProtocol) -> String {
        String(text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func tokenize(_ phrase: String) -> [String] {
        phrase
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "/" })
            .map(normalize)
            .filter { !$0.isEmpty }
    }

    /// Hides each word behind its first letter, keeping punctuation: "bad word," -> "b** w***,".
    static func mask(_ text: String) -> String {
        var seenFirst = false
        return String(text.map { character in
            if character.isWhitespace { seenFirst = false }
            guard character.isLetter || character.isNumber else { return character }
            if seenFirst { return "*" }
            seenFirst = true
            return character
        })
    }

    /// A muted word matches anywhere inside a spoken word ("cool" matches "uncool", "coolest").
    static func matches(_ word: String, _ token: String) -> Bool {
        word.contains(token)
    }

    /// Time ranges to silence for matches found with `matchedWords`.
    static func muteRanges(
        for matches: [ClosedRange<Int>],
        in words: [TranscriptWord],
        padding: Double
    ) -> [ClosedRange<Double>] {
        let hits = matches.map { match in
            let start = max(0, words[match.lowerBound].start - padding)
            let end = max(start, words[match.upperBound].end + padding)
            return start...end
        }
        return merge(hits, joiningGapsUnder: 0.08)
    }

    /// Every match of a rule, as the range of transcript word indices it covers.
    static func matchedWords(in words: [TranscriptWord], rules: [MuteRule]) -> [ClosedRange<Int>] {
        struct Token {
            let text: String
            let wordIndex: Int
        }
        // Hyphenated transcript words ("son-of-a") become several tokens of the same word.
        let tokens: [Token] = words.indices.flatMap { index in
            tokenize(words[index].text).map { Token(text: $0, wordIndex: index) }
        }

        var hits: [ClosedRange<Int>] = []
        for rule in rules where !rule.tokens.isEmpty && rule.tokens.count <= tokens.count {
            let count = rule.tokens.count
            for i in 0...(tokens.count - count) {
                var matched = true
                for j in 0..<count where !matches(tokens[i + j].text, rule.tokens[j]) {
                    matched = false
                    break
                }
                if matched {
                    hits.append(tokens[i].wordIndex...tokens[i + count - 1].wordIndex)
                }
            }
        }
        return hits
    }

    /// Sorts and merges overlapping (or nearly touching) ranges so volume ramps never overlap.
    static func merge(_ ranges: [ClosedRange<Double>], joiningGapsUnder gap: Double) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound + gap {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
