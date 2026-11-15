import SwiftUI

struct RootView: View {
    @Environment(PlayerController.self) private var player
    @State private var showingPlayer = false

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
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
                    .safeAreaInset(edge: .bottom) { miniPlayer }
            }
        }
        .sheet(isPresented: $showingPlayer) {
            PlayerView()
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
