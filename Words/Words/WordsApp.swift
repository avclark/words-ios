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

/// Top-level flow: auth gate → lobby → game. Owns the per-account session
/// objects (game cache + server sync) and the persistence wiring: games
/// save on creation, after each turn, when the app leaves the foreground,
/// and on exit to home. Moves apply locally first and sync in the
/// background (GameSync) — play never waits on the network.
struct RootView: View {
    @State private var auth = AuthController()
    @State private var store: GameStore?
    @State private var sync: GameSync?
    @State private var profile = LocalProfile.load()
    @State private var activeGame: BoardState?
    @State private var profilePushTask: Task<Void, Never>?
    @State private var startError: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch auth.state {
            case .loading:
                loadingScreen
            case .signedOut:
                SignInView(auth: auth)
            case .signedIn:
                if store != nil {
                    gameContent
                } else {
                    loadingScreen
                }
            }
        }
        .task {
            auth.onAccountDeleted = {
                // Server data is already gone (cascade); drop the local
                // cache for that account too.
                store?.wipe()
            }
            await auth.start()
        }
        .onChange(of: auth.signedInUserID) { _, userID in
            sessionDidChange(userID: userID)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, let activeGame {
                // Force-quit shows no goodbye: this hop is the only chance
                // to capture mid-turn placements.
                store?.save(activeGame.snapshot())
            }
            if phase == .active, let sync {
                Task { await sync.refreshLobby() }
            }
        }
        .alert("Move not accepted",
               isPresented: .init(get: { sync?.rejection != nil },
                                  set: { if !$0 { dismissRejection() } })) {
            Button("OK") { dismissRejection() }
        } message: {
            Text(sync?.rejection?.message ?? "")
        }
        .alert("Couldn't start game",
               isPresented: .init(get: { startError != nil },
                                  set: { if !$0 { startError = nil } })) {
            Button("OK") { startError = nil }
        } message: {
            Text(startError ?? "")
        }
    }

    private var loadingScreen: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HomeView.background.ignoresSafeArea())
    }

    @ViewBuilder
    private var gameContent: some View {
        if let store {
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
    }

    // MARK: - Session lifecycle

    private func sessionDidChange(userID: UUID?) {
        activeGame = nil
        guard let userID else {
            store = nil
            sync = nil
            return
        }
        let newStore = GameStore(userID: userID)
        let newSync = GameSync(store: newStore, userID: userID)
        store = newStore
        sync = newSync
        Task {
            if let merged = await auth.resolveProfile(local: profile) {
                profile = merged
                LocalProfile.save(merged)
            }
            await newSync.migrateLocalGames()
            await newSync.refreshLobby()
        }
    }

    private func dismissRejection() {
        guard let rejection = sync?.rejection else { return }
        sync?.rejection = nil
        // The cache already holds server truth; reload the live game from it.
        if activeGame?.gameID == rejection.gameID {
            if let fresh = store?.games.first(where: { $0.id == rejection.gameID }) {
                open(fresh)
            } else {
                activeGame = nil
            }
        }
    }

    // MARK: - Games

    private func start(difficulty: AIDifficulty) {
        guard let sync, let store else { return }
        Task {
            do {
                let game = try await sync.createGame(difficulty: difficulty,
                                                     profile: startableProfile)
                wire(game)
                store.save(game.snapshot())
                activeGame = game
            } catch {
                startError = "New games need a connection — the server deals the tiles. Try again once you're online."
            }
        }
    }

    private func open(_ saved: SavedGame) {
        var saved = saved
        // Profile edits apply everywhere; only the per-game state is frozen.
        saved.players[0].profile = startableProfile
        let game = BoardState(from: saved)
        wire(game)
        activeGame = game
        game.resumeOpponentTurnIfNeeded()
    }

    private func wire(_ game: BoardState) {
        game.onAutosave = { [weak store] in store?.save($0.snapshot()) }
        sync?.attach(game)
    }

    private func closeActiveGame() {
        if let activeGame {
            store?.save(activeGame.snapshot())
        }
        activeGame = nil
    }

    private func rematch() {
        let difficulty = activeGame?.difficulty ?? .medium
        closeActiveGame()
        start(difficulty: difficulty)
    }

    // MARK: - Profile

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
