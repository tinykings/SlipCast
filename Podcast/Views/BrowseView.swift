import SwiftUI

struct BrowseView: View {
    @State private var query = ""
    @State private var results: [DirectoryPodcast] = []
    @State private var genre: PodcastGenre = .top
    @State private var charts: [PodcastGenre: [DirectoryPodcast]] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var addingFeed = false

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }
            if query.isEmpty {
                Section {
                    Picker("Category", selection: $genre) {
                        ForEach(PodcastGenre.all) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Section(genre.id == nil ? "Top Podcasts" : "Top in \(genre.name)") {
                    ForEach(chart) { DirectoryRow(podcast: $0) }
                }
            } else {
                ForEach(results) { DirectoryRow(podcast: $0) }
            }
        }
        .overlay {
            if isLoading && (query.isEmpty ? chart.isEmpty : results.isEmpty) {
                ProgressView()
            } else if !query.isEmpty && results.isEmpty && !isLoading {
                ContentUnavailableView.search(text: query)
            }
        }
        .tabTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search podcasts")
        .navigationDestination(for: DirectoryPodcast.self) { DirectoryShowView(podcast: $0) }
        .toolbar {
            Button("Add by URL", systemImage: "link.badge.plus") { addingFeed = true }
        }
        .sheet(isPresented: $addingFeed) { AddFeedView() }
        .task(id: genre) { await loadChart() }
        .task(id: query) { await search() }
    }

    private var chart: [DirectoryPodcast] { charts[genre] ?? [] }

    private func loadChart() async {
        guard charts[genre] == nil else { return }
        let requested = genre
        isLoading = true
        defer { isLoading = false }
        do {
            charts[requested] = try await DirectoryService.topPodcasts(genre: requested)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = "Couldn't load \(requested.name)."
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(350))  // debounce typing
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            results = try await DirectoryService.search(term)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = "Search failed. Check your connection."
        }
    }
}

private struct DirectoryRow: View {
    let podcast: DirectoryPodcast

    var body: some View {
        NavigationLink(value: podcast) {
            HStack(spacing: 12) {
                ArtworkView(urlString: podcast.artworkURL, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(podcast.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(podcast.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let genre = podcast.genre {
                        Text(genre).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct AddFeedView: View {
    @Environment(FeedService.self) private var feeds
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/feed.xml", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text(errorMessage ?? "Paste a podcast's RSS feed URL, including private or premium feeds.")
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Add by URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isAdding {
                        ProgressView()
                    } else {
                        Button("Subscribe") { Task { await add() } }
                            .disabled(URL(string: url)?.scheme == nil)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func add() async {
        isAdding = true
        defer { isAdding = false }
        do {
            try await feeds.subscribe(feedURL: url.trimmingCharacters(in: .whitespaces))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
