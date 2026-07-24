import SwiftUI

/// The lobby: every game (in progress and finished) as a tappable list,
/// Scrabble GO-style, plus profile access and the new-game flow.
/// Deliberately restrained styling — the full design pass comes later.
struct HomeView: View {
    @Binding var profile: PlayerProfile
    let store: GameStore
    let auth: AuthController
    let friends: FriendsStore
    /// Owned by RootView so a friend-notification tap can open it.
    @Binding var showFriends: Bool
    let onOpen: (SavedGame) -> Void
    let onNewGame: (AIDifficulty) -> Void
    let onChallenge: (RemoteGames.FriendDTO) -> Void

    @State private var showProfileEditor = false
    @State private var showNewGameSetup = false
    @State private var deleteError: String?

    static let background = Color(red: 0.05, green: 0.07, blue: 0.13)

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if store.games.isEmpty {
                emptyState
            } else {
                gameList
            }

            Button {
                showNewGameSetup = true
            } label: {
                Text("NEW GAME")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(Color.yellow))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Self.background.ignoresSafeArea())
        .sheet(isPresented: $showProfileEditor) {
            ProfileEditorSheet(profile: $profile, auth: auth)
        }
        .sheet(isPresented: $showNewGameSetup) {
            NewGameSetupSheet(friends: friends) { choice in
                showNewGameSetup = false
                switch choice {
                case .robo(let difficulty): onNewGame(difficulty)
                case .friend(let friend): onChallenge(friend)
                }
            }
        }
        .sheet(isPresented: $showFriends) {
            FriendsView(store: friends) { friend in
                onChallenge(friend)
            }
        }
        .alert("Couldn't delete game",
               isPresented: .init(get: { deleteError != nil },
                                  set: { if !$0 { deleteError = nil } })) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    /// Server-side first (hide for human games, hard delete for solo),
    /// local cache only after the server agrees — a local-only delete
    /// just resurrected on the next sync.
    private func deleteGame(_ game: SavedGame) {
        guard game.bagCount != nil else {
            store.delete(id: game.id)  // pre-Phase-7 local-only game
            return
        }
        Task {
            do {
                _ = try await RemoteGames.deleteGame(id: game.id)
                store.delete(id: game.id)
            } catch {
                deleteError = "The game couldn't be deleted — check your connection and try again."
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("WORDS")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Button {
                showFriends = true
            } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.08))
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.7))
                    if !friends.incoming.isEmpty {
                        Circle().fill(Color.yellow)
                            .frame(width: 10, height: 10)
                            .offset(x: 13, y: -13)
                    }
                }
                .frame(width: 38, height: 38)
            }
            Button {
                showProfileEditor = true
            } label: {
                AvatarCircle(avatar: profile.avatar, size: 38)
            }
        }
    }

    private var gameList: some View {
        List {
            ForEach(store.lobbyOrder) { game in
                Button {
                    onOpen(game)
                } label: {
                    GameRow(game: game)
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .padding(.vertical, 4)
                )
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing) {
                    // Active human games can't be deleted — that would be
                    // silent abandonment; resign first. (Server enforces
                    // this too via 'resign_first'.)
                    if game.gameOver != nil || game.opponentIsHuman != true {
                        Button(role: .destructive) {
                            deleteGame(game)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.25))
            Text("No games yet")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
            Text("Start a game against Robo — your games\nwill live here, ready to resume any time.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Game row

private struct GameRow: View {
    let game: SavedGame

    var body: some View {
        HStack(spacing: 12) {
            AvatarCircle(avatar: game.opponentPlayer.profile.avatar, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(game.opponentPlayer.profile.displayName)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Text("You \(game.localPlayer.score) · \(game.opponentPlayer.profile.displayName) \(game.opponentPlayer.score)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 5) {
                    if let unread = game.unreadChat, unread > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 8))
                            Text("\(unread)")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.yellow))
                    }
                    phaseChip
                }
                Text(game.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                if let expiry = expiryWarning {
                    Text(expiry)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.orange.opacity(0.85))
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var phaseChip: some View {
        let (label, tint): (String, Color) = {
            switch game.phase {
            case .yourTurn: return ("YOUR TURN", .yellow)
            case .waiting: return ("THEIR TURN", .white.opacity(0.5))
            case .finished: return (finishedLabel, .white.opacity(0.45))
            }
        }()
        Text(label)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .kerning(0.5)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private var finishedLabel: String {
        guard let over = game.gameOver else { return "FINISHED" }
        if over.reason == .expired { return "EXPIRED" }
        if let localWon = over.localWon { return localWon ? "YOU WON" : "YOU LOST" }
        if over.localFinal > over.opponentFinal { return "YOU WON" }
        if over.localFinal < over.opponentFinal { return "YOU LOST" }
        return "TIED"
    }

    /// Deadline nudge for active human games — visible well before the
    /// warn-then-expire flow fires, so expiry is never a surprise.
    private var expiryWarning: String? {
        guard game.gameOver == nil, game.opponentIsHuman == true,
              let expiresAt = game.expiresAt else { return nil }
        let remaining = expiresAt.timeIntervalSinceNow
        guard remaining < 3 * 86_400 else { return nil }
        if remaining <= 0 { return "expiring" }
        if remaining < 86_400 { return "expires today" }
        return "expires in \(Int(remaining / 86_400))d"
    }
}

// MARK: - Avatar

/// Small round avatar used across the lobby (rows, profile button, setup).
struct AvatarCircle: View {
    let avatar: Avatar
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(avatar.tint.opacity(0.22))
            Image(systemName: avatar.symbolName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(avatar.tint)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }
}

// MARK: - Profile editor

/// The thin profile: name + avatar (synced to the server when signed in),
/// plus the account controls — sign out and App-Store-required deletion.
private struct ProfileEditorSheet: View {
    @Binding var profile: PlayerProfile
    let auth: AuthController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var prefs: RemoteGames.NotificationPrefs?
    @State private var prefsLoadFailed = false
    @State private var blocked: [RemoteGames.BlockedUser] = []
    @State private var unblockNotice: String?
    @State private var username = ""
    @State private var savedUsername: String?
    @State private var usernameFeedback: (text: String, good: Bool)?
    @State private var savingUsername = false

    var body: some View {
        // Scrollable so the keyboard compresses the viewport instead of
        // shoving fields off the top (the sheet outgrew a fixed VStack).
        ScrollView {
        VStack(spacing: 20) {
            Text("Your profile")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            TextField("Your name", text: $profile.displayName)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
                .autocorrectionDisabled()

            usernameSection

            HStack(spacing: 10) {
                ForEach(Avatar.humanChoices, id: \.self) { avatar in
                    Button {
                        profile.avatar = avatar
                    } label: {
                        AvatarCircle(avatar: avatar, size: 36)
                            .overlay(
                                Circle().strokeBorder(profile.avatar == avatar ? Color.yellow : .clear,
                                                      lineWidth: 2)
                            )
                    }
                }
            }

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)

            Divider().overlay(.white.opacity(0.15))

            notificationSection

            blockedSection

            Divider().overlay(.white.opacity(0.15))

            accountSection
        }
        .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
        .presentationDetents([.medium, .large])
        .presentationBackground(HomeView.background)
        .task {
            await loadRemoteSections()
        }
        .alert("Delete your account?", isPresented: $confirmingDelete) {
            Button("Delete account", role: .destructive) {
                Task {
                    if await auth.deleteAccount() { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account and profile from the server. Games saved on this device stay on this device.")
        }
    }

    /// Optional search handle, distinct from the display name on purpose:
    /// the name is what people SEE (free-form, duplicable, zero friction);
    /// the username is how people FIND you (unique, opt-in — no username
    /// means not searchable, which is a privacy default, not a gap).
    private var usernameSection: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("@")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("username (optional)", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(maxWidth: 170)
                    .onSubmit { saveUsername() }
                if username.lowercased() != (savedUsername ?? "") {
                    Button("Save") { saveUsername() }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .disabled(savingUsername)
                }
            }
            if let feedback = usernameFeedback {
                Text(feedback.text)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(feedback.good ? Color.green.opacity(0.8)
                                                   : Color(red: 1, green: 0.45, blue: 0.4))
            } else {
                Text("Friends can find you by your name. A username is an optional exact handle on top.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func saveUsername() {
        let cleaned = username.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
        username = cleaned
        savingUsername = true
        Task {
            defer { savingUsername = false }
            guard let result = try? await RemoteGames.setUsername(cleaned.isEmpty ? nil : cleaned) else {
                usernameFeedback = ("Couldn't save — check your connection.", false)
                return
            }
            switch result {
            case "ok":
                savedUsername = cleaned
                usernameFeedback = ("You're @\(cleaned) — friends can find you by it.", true)
            case "cleared":
                savedUsername = nil
                usernameFeedback = ("Username removed — you won't appear in search.", true)
            case "taken":
                usernameFeedback = ("@\(cleaned) is taken — try another.", false)
            default:
                usernameFeedback = ("3–20 characters: a–z, 0–9, and underscores.", false)
            }
        }
    }

    private func loadRemoteSections() async {
        guard let userID = auth.signedInUserID else { return }
        prefsLoadFailed = false
        do {
            prefs = try await RemoteGames.fetchNotificationPrefs(userID: userID)
        } catch {
            // Say so — an empty section is indistinguishable from broken.
            prefsLoadFailed = true
        }
        blocked = (try? await RemoteGames.listBlocked()) ?? []
        if let existing = try? await RemoteGames.fetchUsername(userID: userID) {
            savedUsername = existing
            username = existing ?? ""
        }
    }

    /// Per-type push toggles, honored server-side (a disabled type is never
    /// queued, let alone sent). The list is FEATURE-LIST's exact events —
    /// there is nothing else to toggle because nothing else is ever sent.
    /// The section header ALWAYS renders with toggles, an error+retry, or
    /// a spinner — never a silent blank (that hid a decode bug once).
    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOTIFICATIONS")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .kerning(1)
                .foregroundStyle(.white.opacity(0.4))
            if prefs != nil {
                prefToggle("Your turn", \.turn)
                prefToggle("New games", \.newGame)
                prefToggle("Game over", \.gameOver)
                prefToggle("Expiry warnings", \.expiryWarning)
                prefToggle("Nudges from opponents", \.ping)
                prefToggle("Chat messages", \.chat)
                prefToggle("Friend requests", \.friend)
            } else if prefsLoadFailed {
                HStack {
                    Text("Couldn't load notification settings.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                    Button("Try again") {
                        Task { await loadRemoteSections() }
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
            } else {
                ProgressView()
                    .tint(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func prefToggle(_ label: String,
                            _ keyPath: WritableKeyPath<RemoteGames.NotificationPrefs, Bool>) -> some View {
        Toggle(label, isOn: Binding(
            get: { prefs?[keyPath: keyPath] ?? true },
            set: { newValue in
                prefs?[keyPath: keyPath] = newValue
                if let prefs {
                    Task { try? await RemoteGames.saveNotificationPrefs(prefs) }
                }
            }))
            .font(.system(size: 13, design: .rounded))
            .tint(.yellow)
    }

    @ViewBuilder
    private var blockedSection: some View {
        if !blocked.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("BLOCKED PLAYERS")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .kerning(1)
                    .foregroundStyle(.white.opacity(0.4))
                ForEach(blocked) { user in
                    HStack {
                        Text(user.displayName)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Button("Unblock") {
                            let name = user.displayName
                            Task {
                                try? await RemoteGames.unblockUser(user.userID)
                                blocked.removeAll { $0.userID == user.userID }
                                unblockNotice = "\(name) is unblocked. Blocking ended your friendship, so you're not friends again automatically — send a friend request or share your invite link if you want to reconnect."
                            }
                        }
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                }
                // The rule, stated where the action lives — never a
                // silent "wait, what happened?" moment.
                Text("Unblocking doesn't re-add someone as a friend.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .alert("Unblocked",
                   isPresented: .init(get: { unblockNotice != nil },
                                      set: { if !$0 { unblockNotice = nil } })) {
                Button("OK") { unblockNotice = nil }
            } message: {
                Text(unblockNotice ?? "")
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        if case .signedIn = auth.state {
            VStack(spacing: 12) {
                Text("Signed in with Apple")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                HStack(spacing: 20) {
                    Button("Sign out") {
                        Task {
                            await auth.signOut()
                            dismiss()
                        }
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Button("Delete account…", role: .destructive) {
                        confirmingDelete = true
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
            }
        }
    }
}

// MARK: - New game setup

/// Opponent choice + difficulty. The opponent list is the Phase 4/7
/// generic player model surfacing in UI: Robo and each friend are just
/// selectable opponents; a friend seat becomes a human seat server-side.
private struct NewGameSetupSheet: View {
    enum Choice {
        case robo(AIDifficulty)
        case friend(RemoteGames.FriendDTO)
    }

    let friends: FriendsStore
    let onStart: (Choice) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var difficulty: AIDifficulty = .medium
    @State private var selectedFriend: RemoteGames.FriendDTO?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New game")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)

            sectionLabel("OPPONENT")

            ScrollView {
                VStack(spacing: 8) {
                    Button {
                        selectedFriend = nil
                    } label: {
                        opponentRow(avatar: .robot, name: PlayerProfile.ai.displayName,
                                    detail: "AI opponent", selected: selectedFriend == nil)
                    }
                    ForEach(friends.friends) { friend in
                        Button {
                            selectedFriend = friend
                        } label: {
                            opponentRow(avatar: Avatar(rawValue: friend.avatar ?? "") ?? .star,
                                        name: friend.displayName,
                                        detail: friend.username.map { "@\($0)" } ?? "Friend",
                                        selected: selectedFriend == friend)
                        }
                    }
                    if friends.friends.isEmpty {
                        Text("Add friends to challenge them — tap the friends icon on the home screen.")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.top, 2)
                    }
                }
            }
            .frame(maxHeight: 190)

            if selectedFriend == nil {
                sectionLabel("DIFFICULTY")

                Picker("Difficulty", selection: $difficulty) {
                    ForEach(AIDifficulty.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)

                Text(difficulty.blurb)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
            }

            Button {
                dismiss()
                onStart(selectedFriend.map { .friend($0) } ?? .robo(difficulty))
            } label: {
                Text(selectedFriend.map { "CHALLENGE \($0.displayName.uppercased())" } ?? "START GAME")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(Color.yellow))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.top, 2)
        }
        .padding(24)
        .presentationDetents([.large])
        .presentationBackground(HomeView.background)
        .task { await friends.refresh() }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .kerning(1)
            .foregroundStyle(.white.opacity(0.4))
    }

    private func opponentRow(avatar: Avatar, name: String, detail: String,
                             selected: Bool) -> some View {
        HStack(spacing: 12) {
            AvatarCircle(avatar: avatar, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Text(detail)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.yellow)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.08 : 0.04))
        )
    }
}
