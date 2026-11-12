import Foundation
import SwiftData

/// A word or phrase the user wants silenced. Matches anywhere inside a word, so "cool" also
/// mutes "coolest" and "uncool".
@Model
final class MutedTerm {
    var text: String
    var createdAt: Date

    init(text: String) {
        self.text = text
        self.createdAt = .now
    }

    var rule: MuteRule { MuteRule(phrase: text) }
}
