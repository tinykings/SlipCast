import SwiftData
import SwiftUI

struct SettingsView: View {
    @Query(sort: \MutedTerm.createdAt, order: .reverse) private var terms: [MutedTerm]
    @Environment(\.modelContext) private var context
    @Environment(PlayerController.self) private var player

    @AppStorage(AppSettings.paddingKey) private var paddingMs = 200.0
    @AppStorage(AppSettings.wifiOnlyKey) private var wifiOnly = true
    @AppStorage(AppSettings.autoDownloadNewKey) private var autoDownloadNew = true

    @State private var newTerm = ""

    /// Changes whenever anything affecting the mute ranges changes.
    private var muteSignature: String {
        terms.map(\.text).joined(separator: ",") + "#\(paddingMs)"
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Add a word or phrase", text: $newTerm)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(addTerm)
                    let canAdd = !MuteMatcher.tokenize(newTerm).isEmpty
                    Button(action: addTerm) {
                        Image(systemName: "plus.circle.fill")
                            .accentCircleSymbol()
                            .opacity(canAdd ? 1 : 0.35)
                    }
                    .font(.title2)
                    .disabled(!canAdd)
                    .accessibilityLabel("Add")
                }
                ForEach(terms) { term in
                    MutedTermRow(term: term)
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(terms[index]) }
                    try? context.save()
                }
            } header: {
                Text("Muted Words")
            } footer: {
                Text("Words are muted wherever they appear, including inside longer words: \"cool\" also mutes \"coolest\" and \"uncool\".")
            }

            Section {
                VStack(alignment: .leading) {
                    LabeledContent("Padding", value: "\(Int(paddingMs)) ms")
                    Slider(value: $paddingMs, in: 0...400, step: 20)
                }
            } header: {
                Text("Muting")
            } footer: {
                Text("Extra silence before and after each muted word. Increase this if you can still hear the edges of words.")
            }

            Section("Downloads") {
                Toggle("Auto-download new subscriptions", isOn: $autoDownloadNew)
                Toggle("Auto-download on Wi-Fi only", isOn: $wifiOnly)
            }
        }
        .tabTitle("Settings")
        .onChange(of: muteSignature) {
            player.refreshMuting()
        }
    }

    private func addTerm() {
        let text = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !MuteMatcher.tokenize(text).isEmpty else { return }
        let normalized = MuteMatcher.tokenize(text)
        guard !terms.contains(where: { MuteMatcher.tokenize($0.text) == normalized }) else {
            newTerm = ""
            return
        }
        context.insert(MutedTerm(text: text))
        try? context.save()
        newTerm = ""
    }
}

private struct MutedTermRow: View {
    let term: MutedTerm

    var body: some View {
        Label(Self.masked(term.text), systemImage: "speaker.slash.fill")
            .accessibilityLabel("Muted word starting with \(term.text.prefix(1).uppercased())")
    }

    /// Hides each word behind its first letter: "bad word" → "b** w***".
    static func masked(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false)
            .map { word in
                guard let first = word.first else { return "" }
                return String(first) + String(repeating: "*", count: word.count - 1)
            }
            .joined(separator: " ")
    }
}
