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
    @State private var friends: FriendsStore?
    @State private var profile = LocalProfile.load()
    @State private var activeGame: BoardState?
    @State private var profilePushTask: Task<Void, Never>?
    @State private var startError: String?
    @State private var inviteMessage: String?
    @Environment(\.scenePhase) private var scenePhase

    private static let pendingInviteKey = "pendingInviteToken"

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
        .alert("Invite",
               isPresented: .init(get: { inviteMessage != nil },
                                  set: { if !$0 { inviteMessage = nil } })) {
            Button("OK") { inviteMessage = nil }
        } message: {
            Text(inviteMessage ?? "")
        }
        .onOpenURL { url in
            handleInviteURL(url)
        }
        // A live human-vs-human game has no local engine: poll while it's
        // the opponent's turn so their move lands without leaving the board.
        .task(id: activeGame?.gameID) {
            guard let game = activeGame, game.opponentIsHuman else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                if game.waitingForOpponent {
                    await sync?.refreshActiveGame(game)
                }
            }
        }
    }

    // MARK: - Invite links (words://invite/<token>)

    private func handleInviteURL(_ url: URL) {
        guard url.scheme == "words", url.host == "invite" else { return }
        let token = url.lastPathComponent
        guard !token.isEmpty, token != "/" else { return }
        if auth.signedInUserID != nil {
            redeemInvite(token)
        } else {
            // Sign in first; sessionDidChange redeems once a session lands.
            UserDefaults.standard.set(token, forKey: Self.pendingInviteKey)
            inviteMessage = "Sign in to accept the invite."
        }
    }

    private func redeemInvite(_ token: String) {
        UserDefaults.standard.removeObject(forKey: Self.pendingInviteKey)
        Task {
            do {
                let result = try await RemoteGames.redeemInvite(token: token)
                // Every decoded status is terminal — the token stays
                // cleared; only a transport failure below may re-stash it.
                let name = result.friend?.displayName ?? "them"
                switch result.status {
                case "accepted":
                    inviteMessage = "You're now friends with \(name)!"
                case "already_friends":
                    inviteMessage = "You're already friends with \(name)."
                case "own_link":
                    inviteMessage = "That's your own invite link — send it to someone else!"
                default:
                    inviteMessage = "That invite link is invalid or has expired. Ask your friend for a fresh one."
                }
                await friends?.refresh()
            } catch where (error as NSError).domain == NSURLErrorDomain {
                // Genuinely couldn't reach the server: keep the token and
                // retry on the next launch/sign-in.
                UserDefaults.standard.set(token, forKey: Self.pendingInviteKey)
                inviteMessage = "Couldn't reach the server to accept the invite — it'll retry next time you open the app."
            } catch {
                // Server answered but something else broke (rejection,
                // malformed response). Retrying the same token forever
                // can't help — surface it and stop.
                inviteMessage = "Something went wrong accepting the invite. Ask your friend to send a fresh link."
            }
        }
    }

    private var loadingScreen: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HomeView.background.ignoresSafeArea())
    }

    @ViewBuilder
    private var gameContent: some View {
        if let store, let friends {
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
                         friends: friends,
                         onOpen: { open($0) },
                         onNewGame: { start(difficulty: $0) },
                         onChallenge: { challenge($0) })
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
            friends = nil
            return
        }
        let newStore = GameStore(userID: userID)
        let newSync = GameSync(store: newStore, userID: userID)
        store = newStore
        sync = newSync
        friends = FriendsStore(selfID: userID)
        Task {
            if let merged = await auth.resolveProfile(local: profile) {
                profile = merged
                LocalProfile.save(merged)
            }
            await newSync.migrateLocalGames()
            await newSync.refreshLobby()
            await friends?.refresh()
            if let pending = UserDefaults.standard.string(forKey: Self.pendingInviteKey) {
                redeemInvite(pending)
            }
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
        createGame(difficulty: difficulty, opponent: nil)
    }

    private func challenge(_ friend: RemoteGames.FriendDTO) {
        createGame(difficulty: .hard, opponent: friend)
    }

    private func createGame(difficulty: AIDifficulty, opponent: RemoteGames.FriendDTO?) {
        guard let sync, let store else { return }
        Task {
            do {
                let game = try await sync.createGame(difficulty: difficulty,
                                                     profile: startableProfile,
                                                     opponent: opponent)
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
