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
                Link("Apple Podcasts Export Instructions",
                     destination: URL(string: "https://haroldgao.com/post/opml/#2-export-your-apple-podcast-subscription-list-into-other-podcast-apps")!)
            } footer: {
                Text("For Apple Podcasts, use the export shortcut to save your followed shows to Files first. The file contains shows only.")
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
