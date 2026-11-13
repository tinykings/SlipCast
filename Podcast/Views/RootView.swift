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
            }
            Tab("Downloads", systemImage: "arrow.down.circle") {
                NavigationStack { DownloadsView() }
            }
            Tab("Search", systemImage: "magnifyingglass") {
                NavigationStack { BrowseView() }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
        }
        .tabViewBottomAccessory(isEnabled: player.episode != nil) {
            MiniPlayerView()
                .contentShape(.rect)
                .onTapGesture { showingPlayer = true }
        }
        .sheet(isPresented: $showingPlayer) {
            PlayerView()
        }
    }
}
