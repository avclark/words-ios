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

/// Top-level flow: auth gate → lobby → game. Also owns the persistence
/// wiring: every game that opens is saved on creation, after each turn
/// (BoardState's autosave hook), when the app leaves the foreground, and on
/// exit to home. Local games never touch the network — signed in or not.
struct RootView: View {
    @State private var auth = AuthController()
    @State private var store = GameStore()
    @State private var profile = LocalProfile.load()
    @State private var activeGame: BoardState?
    @State private var profilePushTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch auth.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(HomeView.background.ignoresSafeArea())
            case .signedOut:
                SignInView(auth: auth)
            case .signedIn:
                gameContent
            }
        }
        .task { await auth.start() }
        .onChange(of: scenePhase) { _, phase in
            // Force-quit shows no goodbye: the inactive/background hop is
            // the only chance to capture mid-turn placements.
            if phase != .active, let activeGame {
                store.save(activeGame.snapshot())
            }
        }
        .onChange(of: auth.signedInUserID) { _, userID in
            guard userID != nil else { return }
            Task {
                if let merged = await auth.resolveProfile(local: profile) {
                    profile = merged
                    LocalProfile.save(merged)
                }
            }
        }
    }

    @ViewBuilder
    private var gameContent: some View {
        if let activeGame {
            GameView(state: activeGame,
                     onExit: { closeActiveGame() },
                     onNewGame: { rematch() })
                // Fresh identity per game so GameView's local state
                // (drag controller, sheets) resets fully.
                .id(activeGame.gameID)
        } else {
            HomeView(profile: $profile,
                     store: store,
                     auth: auth,
                     onOpen: { open($0) },
                     onNewGame: { start(difficulty: $0) })
                .onChange(of: profile) { _, newValue in
                    LocalProfile.save(newValue)
                    schedulePushProfile(newValue)
                }
        }
    }

    private func start(difficulty: AIDifficulty) {
        let game = BoardState(localProfile: startableProfile, difficulty: difficulty)
        game.onAutosave = { store.save($0.snapshot()) }
        store.save(game.snapshot())
        activeGame = game
    }

    private func open(_ saved: SavedGame) {
        var saved = saved
        // Profile edits apply everywhere; only the per-game state is frozen.
        saved.players[0].profile = startableProfile
        let game = BoardState(from: saved)
        game.onAutosave = { store.save($0.snapshot()) }
        activeGame = game
    }

    private func closeActiveGame() {
        if let activeGame {
            store.save(activeGame.snapshot())
        }
        activeGame = nil
    }

    private func rematch() {
        let difficulty = activeGame?.difficulty ?? .medium
        closeActiveGame()
        start(difficulty: difficulty)
    }

    /// Debounced server push of profile edits (the name field fires per
    /// keystroke; one upsert after typing settles is plenty).
    private func schedulePushProfile(_ profile: PlayerProfile) {
        profilePushTask?.cancel()
        profilePushTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await auth.pushProfile(profile)
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
