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

    var body: some View {
        if let gameID {
            GameView(onExit: { self.gameID = nil })
                .id(gameID)
        } else {
            HomeView(onNewGame: { gameID = UUID() })
        }
    }
}
