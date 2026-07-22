import SwiftUI

@main
struct WordsApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

/// Switches between the home screen and a game. Each new game gets a fresh
/// UUID identity so GameView's local state (board, rack, drag) resets fully.
struct RootView: View {
    @State private var gameID: UUID?
    @State private var profile = LocalProfile.load()

    var body: some View {
        if let gameID {
            GameView(profile: startableProfile,
                     onExit: { self.gameID = nil },
                     onNewGame: { self.gameID = UUID() })
                .id(gameID)
        } else {
            HomeView(profile: $profile, onNewGame: { gameID = UUID() })
                .onChange(of: profile) { _, newValue in
                    LocalProfile.save(newValue)
                }
        }
    }

    /// The saved profile, with a sane fallback name if the field was left blank.
    private var startableProfile: PlayerProfile {
        var p = profile
        let trimmed = p.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        p.displayName = trimmed.isEmpty ? "Player" : trimmed
        return p
    }
}
