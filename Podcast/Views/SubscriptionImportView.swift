import SwiftUI
import UniformTypeIdentifiers

struct SubscriptionImportView: View {
    @Environment(FeedService.self) private var feeds
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFile = false
    @State private var isImporting = false
    @State private var progress: Progress?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Button("Choose OPML File") { choosingFile = true }
                    .disabled(isImporting)
            } footer: {
                Text("Choose an OPML file to import followed shows. Listening history and playback positions aren’t included.")
            }

            Section {
                if let shortcutURL = Bundle.main.url(forResource: "Export Apple Podcasts", withExtension: "shortcut") {
                    ShareLink(item: shortcutURL) {
                        Label("Install Export Shortcut", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isImporting)
                } else {
                    Text("The export shortcut is unavailable in this build.")
                        .foregroundStyle(.secondary)
                }
                Text("1. Open the shared file in Shortcuts and confirm Add Shortcut. If needed, save it to Files first, then tap it there.")
                Text("2. Run Export Apple Podcasts in Shortcuts, allow access to Podcasts, and save Apple Podcasts.opml to Files.")
                Text("3. Return here and tap Choose OPML File.")
            } header: {
                Text("Export from Apple Podcasts")
            } footer: {
                Text("The bundled shortcut runs on your device. It reads your Podcasts library and asks where to save the list; it doesn’t upload it. Installation and permissions require your confirmation.")
            }

            if let progress {
                Section("Import Results") {
                    if isImporting {
                        ProgressView(value: Double(progress.processed), total: Double(progress.total)) {
                            Text("Importing \(progress.processed) of \(progress.total) shows")
                        }
                    }
                    LabeledContent("Added", value: progress.added.formatted())
                    LabeledContent("Already followed", value: progress.existing.formatted())
                    if progress.invalid > 0 {
                        LabeledContent("Invalid feed URLs", value: progress.invalid.formatted())
                    }
                    if !progress.failed.isEmpty {
                        LabeledContent("Couldn’t import", value: progress.failed.count.formatted())
                        ForEach(progress.failed.indices, id: \.self) { index in
                            Text(progress.failed[index])
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if isImporting {
                ProgressView("Reading file")
            }
        }
        .navigationTitle("Import Followed Shows")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .disabled(isImporting)
            }
        }
        .interactiveDismissDisabled(isImporting)
        .fileImporter(
            isPresented: $choosingFile,
            allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml, .plainText]
        ) { selection in
            switch selection {
            case .success(let url):
                isImporting = true
                progress = nil
                Task { await importFile(url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Couldn’t Open Import File", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func importFile(_ url: URL) async {
        defer { isImporting = false }
        do {
            let list = try await SubscriptionOPML.read(from: url)
            var result = Progress(total: list.feeds.count, invalid: list.invalidFeedCount)
            progress = result

            for feed in list.feeds {
                do {
                    if try await feeds.importSubscription(feedURL: feed.url) {
                        result.added += 1
                    } else {
                        result.existing += 1
                    }
                } catch {
                    result.failed.append(feed.title)
                }
                progress = result
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private struct Progress {
        let total: Int
        let invalid: Int
        var added = 0
        var existing = 0
        var failed: [String] = []

        var processed: Int { added + existing + failed.count }
    }
}
