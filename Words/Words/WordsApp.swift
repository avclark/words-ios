import SwiftUI

@main
struct WordsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
    @State private var notifications = NotificationsController.shared
    @State private var offeringPushPermission = false
    /// True while a notification-opened game is being fetched (uncached
    /// case). Together with pendingGameID it defines the "opening your
    /// game" launch state — never shown on a normal launch.
    @State private var openingNotificationGame = false
    @State private var openFailure: String?
    @Environment(\.scenePhase) private var scenePhase

    private static let pendingInviteKey = "pendingInviteToken"
    private static let pushPromptedKey = "pushPermissionPrompted"

    /// A notification tap is being carried toward its game — show the
    /// dedicated launch state instead of flashing the lobby.
    private var isOpeningFromNotification: Bool {
        notifications.pendingGameID != nil || openingNotificationGame
    }

    var body: some View {
        Group {
            switch auth.state {
            case .loading:
                if isOpeningFromNotification {
                    OpeningGameView()
                } else {
                    loadingScreen
                }
            case .signedOut:
                SignInView(auth: auth)
            case .signedIn:
                if isOpeningFromNotification {
                    OpeningGameView()
                } else if store != nil {
                    gameContent
                } else {
                    loadingScreen
                }
            }
        }
        // Never hang on the opening screen: if the game hasn't opened
        // within 12s (offline session restore, dead game), fall through
        // to the lobby with an explanation.
        .task(id: isOpeningFromNotification) {
            guard isOpeningFromNotification else { return }
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, isOpeningFromNotification else { return }
            pushLog.notice("opening screen timed out — falling back to lobby")
            notifications.pendingGameID = nil
            openingNotificationGame = false
            openFailure = "Couldn't load the game — check your connection and open it from the lobby."
        }
        .alert("Couldn't open game",
               isPresented: .init(get: { openFailure != nil },
                                  set: { if !$0 { openFailure = nil } })) {
            Button("OK") { openFailure = nil }
        } message: {
            Text(openFailure ?? "")
        }
        .task {
            auth.onAccountDeleted = {
                // Server data is already gone (cascade); drop the local
                // cache for that account too.
                store?.wipe()
            }
            auth.onWillSignOut = {
                await NotificationsController.shared.unregisterCurrentToken()
            }
            await notifications.refreshPermissionState()
            await auth.start()
        }
        .onChange(of: notifications.pendingGameID) { _, gameID in
            guard gameID != nil else { return }
            consumePendingNotification()
        }
        .alert("Never miss your turn", isPresented: $offeringPushPermission) {
            Button("Enable notifications") {
                Task { await notifications.requestPermission() }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Get a notification when it's your move, a friend challenges you, or a game is about to expire. Real game events only — no spam, ever.")
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
                // Order matters: push our queued moves BEFORE pulling, so
                // a pull can't roll back state that has ops still waiting.
                sync.flushPending()
                Task {
                    await sync.refreshLobby()
                    if let store { notifications.updateBadge(from: store.games) }
                }
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
        // A live human-vs-human game has no local engine: poll so their
        // move — or a resignation/expiry — lands without leaving the board.
        // 10s while waiting on them, 30s on our own turn; the task dies
        // with the screen, so backgrounded apps never poll.
        .task(id: activeGame?.gameID) {
            guard let game = activeGame, game.opponentIsHuman else { return }
            while !Task.isCancelled {
                let seconds: UInt64 = game.waitingForOpponent ? 10 : 30
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                if game.gameOver == nil {
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
            // Queued ops from a force-quit session go up BEFORE anything
            // pulls, so the pull can't roll back their optimistic state.
            newSync.flushPending()
            await newSync.migrateLocalGames()
            await newSync.refreshLobby()
            await friends?.refresh()
            if let pending = UserDefaults.standard.string(forKey: Self.pendingInviteKey) {
                redeemInvite(pending)
            }
            // A cold-launch notification tap parked its game ID before the
            // session existed; the store is ready now.
            consumePendingNotification()
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

    /// Deep-link from a notification tap. Called both when the tap lands
    /// AND when the session becomes ready — whichever happens LAST wins:
    /// a cold-launch tap sets pendingGameID long before the store exists,
    /// so the ID must never be consumed until it can actually be opened.
    /// Always pulls fresh state for the opened game — the notification
    /// exists precisely because something changed server-side.
    private func consumePendingNotification() {
        guard let gameID = notifications.pendingGameID else { return }
        guard let store, let sync else {
            pushLog.notice("consume deferred (session not ready) game=\(gameID.uuidString, privacy: .public)")
            return
        }
        pushLog.notice("consume game=\(gameID.uuidString, privacy: .public) cached=\(self.store?.games.contains { $0.id == gameID } ?? false)")
        notifications.pendingGameID = nil

        func openAndRefresh(_ saved: SavedGame) {
            open(saved)
            if let game = activeGame {
                Task { await sync.refreshActiveGame(game) }
            }
        }

        if let current = activeGame, current.gameID == gameID {
            Task { await sync.refreshActiveGame(current) }
        } else if let saved = store.games.first(where: { $0.id == gameID }) {
            // Cached: opens synchronously, no interstitial needed.
            activeGame = nil
            openAndRefresh(saved)
        } else {
            // Unknown game (e.g. a brand-new challenge): keep the opening
            // screen up while it's pulled, then land directly in it.
            activeGame = nil
            openingNotificationGame = true
            Task {
                await sync.refreshLobby()
                if let saved = store.games.first(where: { $0.id == gameID }) {
                    openAndRefresh(saved)
                } else {
                    pushLog.notice("notification game not found after refresh game=\(gameID.uuidString, privacy: .public)")
                    openFailure = "That game couldn't be loaded — it may have ended or been removed."
                }
                openingNotificationGame = false
            }
        }
    }

    private func wire(_ game: BoardState) {
        game.onAutosave = { [weak store] in store?.save($0.snapshot()) }
        sync?.attach(game)
        notifications.visibleGameID = game.gameID
        // The moment notifications become worth having: the player's first
        // human game. Never on first launch.
        if game.opponentIsHuman, notifications.permission == .notAsked,
           !UserDefaults.standard.bool(forKey: Self.pushPromptedKey) {
            UserDefaults.standard.set(true, forKey: Self.pushPromptedKey)
            offeringPushPermission = true
        }
    }

    private func closeActiveGame() {
        if let activeGame {
            store?.save(activeGame.snapshot())
        }
        activeGame = nil
        notifications.visibleGameID = nil
        if let store { notifications.updateBadge(from: store.games) }
    }

    private func rematch() {
        guard let game = activeGame else { return }
        if game.opponentIsHuman {
            guard let sync, let store else { return }
            Task {
                do {
                    let fresh = try await sync.rematch(from: game, profile: startableProfile)
                    closeActiveGame()
                    wire(fresh)
                    store.save(fresh.snapshot())
                    activeGame = fresh
                } catch {
                    startError = "Couldn't start the rematch — check your connection and try again."
                }
            }
        } else {
            let difficulty = game.difficulty
            closeActiveGame()
            start(difficulty: difficulty)
        }
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

/// Launch state for a notification-opened game: shown instead of the lobby
/// while session restore + the game fetch finish, so the tap reads as
/// "opening your game", not "wrong screen, then right screen".
private struct OpeningGameView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("WORDS")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            ProgressView()
                .tint(.white.opacity(0.6))
            Text("Opening your game…")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HomeView.background.ignoresSafeArea())
    }
}
