import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(PlayerController.self) private var player
    @State private var showingPlayer = false
    /// `isInProgress` depends on the show, so it can't go in the predicate.
    @Query(filter: #Predicate<Episode> { $0.downloadStateRaw != "notDownloaded" })
    private var downloadedEpisodes: [Episode]

    private var inProgressCount: Int {
        downloadedEpisodes.count(where: \.isInProgress)
    }

    var body: some View {
        tabs
    }

    private var tabs: some View {
        TabView {
            Tab("Library", systemImage: "square.stack") {
                NavigationStack { LibraryView() }
                    .safeAreaInset(edge: .bottom) { miniPlayer }
            }
            Tab("Downloads", systemImage: "arrow.down.circle") {
                NavigationStack { DownloadsView() }
                    .safeAreaInset(edge: .bottom) { miniPlayer }
            }
            .badge(inProgressCount)
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
                    .safeAreaInset(edge: .bottom) { miniPlayer }
            }
        }
        .sheet(isPresented: $showingPlayer) {
            PlayerView()
        }
        // Close the full player once playback ends with nothing to play next.
        .onChange(of: player.episode == nil && !player.isAdvancing) { _, isEmpty in
            if isEmpty { showingPlayer = false }
        }
    }

    /// Sits above the tab bar. The system bottom accessory is too short and fits only one pill.
    @ViewBuilder
    private var miniPlayer: some View {
        if player.episode != nil {
            MiniPlayerView { showingPlayer = true }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
