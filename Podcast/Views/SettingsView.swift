import SwiftData
import SwiftUI

struct SettingsView: View {
    @Query(sort: \MutedTerm.createdAt, order: .reverse) private var terms: [MutedTerm]
    @Environment(\.modelContext) private var context
    @Environment(PlayerController.self) private var player

    @AppStorage(AppSettings.paddingKey) private var paddingMs = 200.0
    @AppStorage(AppSettings.wifiOnlyKey) private var wifiOnly = true
    @AppStorage(AppSettings.autoDownloadNewKey) private var autoDownloadNew = true

    @AppStorage(AppSettings.autoDeletePlayedKey) private var autoDeletePlayed = false

    @State private var newTerm = ""
    @State private var rescanRequested = false

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
                Text("Used only for shows with Filter muted words enabled. Words are muted wherever they appear, including inside longer words: \"cool\" also mutes \"coolest\" and \"uncool\".")
            }

            Section {
                VStack(alignment: .leading) {
                    LabeledContent("Padding", value: "\(Int(paddingMs)) ms")
                    Slider(value: $paddingMs, in: 0...400, step: 20)
                }
            } header: {
                Text("Muting")
            } footer: {
                Text("Extra audio skipped before and after each muted word. Increase this if you can still hear the edges of words.")
            }

            Section {
                Toggle("Auto-download new subscriptions", isOn: $autoDownloadNew)
                Toggle("Auto-download on Wi-Fi only", isOn: $wifiOnly)
                Toggle("Auto-delete played episodes", isOn: $autoDeletePlayed)
            } header: {
                Text("Downloads")
            } footer: {
                Text("Auto-delete removes downloads when episodes finish or you mark them as played. Their played status is kept, and you can download them again.")
            }

            Section {
                Button("Re-scan filtered downloads") {
                    player.rescanDownloads()
                    rescanRequested = true
                }
                if rescanRequested {
                    Text("Re-scan queued. Follow progress in Downloads.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("On-device Transcription")
            } footer: {
                Text("Turn on Filter muted words for each show you want filtered. Those episodes must finish downloading and processing before they play. Muted words are skipped, with no silence left behind. Where people talk over each other, SlipCast also listens for your muted words and skips just those spots (English only). Unfiltered shows play the original audio.")
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
        Label(MuteMatcher.mask(term.text), systemImage: "speaker.slash.fill")
            .accessibilityLabel("Muted word starting with \(term.text.prefix(1).uppercased())")
    }
}
