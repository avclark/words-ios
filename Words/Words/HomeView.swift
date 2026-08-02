import SwiftUI

/// The lobby (the Home tab): every game (in progress and finished) as a
/// tappable list, Scrabble GO-style, plus the new-game flow. The header's
/// friends/profile buttons jump to their tabs (RootView owns the tab
/// selection). Deliberately restrained styling — the full design pass
/// comes later.
struct HomeView: View {
    /// Screens pushed under Home. Match History is deliberately a pushed
    /// detail (NOT a tab, reachable only from the Home row): being in
    /// the navigation hierarchy is what makes "back out of a game opened
    /// from Match History" land on Match History, not Home.
    enum Destination: Hashable {
        case matchHistory
    }

    @Environment(\.theme) private var theme

    @Binding var profile: PlayerProfile
    let store: GameStore
    let friends: FriendsStore
    /// Home's navigation path — owned by RootView, NOT local state:
    /// opening a game swaps the whole tab shell out at the root, which
    /// destroys HomeView's local state. Held upstream, the pushed
    /// Match History screen survives the game and is restored when the
    /// game exits.
    @Binding var path: [Destination]
    /// Header shortcuts to the Friends / Profile tabs.
    let onShowFriends: () -> Void
    let onShowProfile: () -> Void
    let onOpen: (SavedGame) -> Void
    let onNewGame: (AIDifficulty) -> Void
    let onChallenge: (RemoteGames.FriendDTO) -> Void

    @State private var showNewGameSetup = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack(path: $path) {
            homeContent
                .navigationDestination(for: Destination.self) { destination in
                    switch destination {
                    case .matchHistory:
                        MatchHistoryView(store: store,
                                         onOpen: { onOpen($0) },
                                         onDelete: { deleteGame($0) })
                    }
                }
        }
        // On the stack, not the content: the delete alert must present
        // even while Match History is the visible screen.
        .alert("Couldn't delete game",
               isPresented: .init(get: { deleteError != nil },
                                  set: { if !$0 { deleteError = nil } })) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var homeContent: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, theme.metrics.screenHPadding)
                .padding(.top, 12)
                .padding(.bottom, 8)

            WordOfTheDayView()
                .padding(.horizontal, theme.metrics.screenHPadding)
                .padding(.bottom, 8)

            if store.currentGames.isEmpty && store.matchHistory.isEmpty {
                emptyState
            } else {
                gameList
            }
        }
        // NEW GAME is pinned above the tab bar; the list scrolls behind
        // it (safeAreaInset gives the scroll content the matching bottom
        // inset, so the last row can always clear the button).
        .safeAreaInset(edge: .bottom) {
            Button {
                showNewGameSetup = true
            } label: {
                Text("NEW GAME")
                    .font(theme.typography.buttonLabel)
                    .foregroundStyle(theme.chrome.buttonPrimaryText)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(theme.chrome.buttonPrimary))
            }
            .padding(.horizontal, theme.metrics.screenHPadding)
            .padding(.top, 8)
            // Breathing room above the tab bar so the button and the
            // tabs don't read as one cluster.
            .padding(.bottom, 10)
        }
        .background(theme.chrome.screenBackground.ignoresSafeArea())
        // Home draws its own header; no empty system bar above it. The
        // pushed Match History screen shows its bar (standard back).
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showNewGameSetup) {
            NewGameSetupSheet(friends: friends) { choice in
                showNewGameSetup = false
                switch choice {
                case .robo(let difficulty): onNewGame(difficulty)
                case .friend(let friend): onChallenge(friend)
                }
            }
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
            LogoView()
            Spacer()
            Button {
                onShowFriends()
            } label: {
                ZStack {
                    Circle().fill(theme.chrome.ink.opacity(0.08))
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.chrome.ink.opacity(0.7))
                    if !friends.incoming.isEmpty {
                        Circle().fill(theme.chrome.accent)
                            .frame(width: 10, height: 10)
                            .offset(x: 13, y: -13)
                    }
                }
                .frame(width: 38, height: 38)
            }
            Button {
                onShowProfile()
            } label: {
                AvatarView(profile: profile, size: 38)
            }
        }
    }

    /// The lobby buckets, in display order, labeled — only non-empty
    /// groups render. Active games only: finished games live in Match
    /// History from the moment they finish.
    private var lobbyGroups: [(label: String, games: [SavedGame])] {
        let current = store.currentGames
        return [("YOUR TURN", current.filter { $0.phase == .yourTurn }),
                ("THEIR TURN", current.filter { $0.phase == .waiting })]
            .filter { !$0.1.isEmpty }
    }

    /// Row content sits at the screen margin plus the standard card
    /// interior padding, so the row cards align with every other
    /// screen's content column.
    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 6,
                   leading: theme.metrics.screenHPadding + theme.metrics.cardPadding,
                   bottom: 6,
                   trailing: theme.metrics.screenHPadding + theme.metrics.cardPadding)
    }

    /// The row's card background, held to the shared screen margin
    /// (list row backgrounds otherwise span edge-to-edge).
    private func rowBackground(fill: Color) -> some View {
        RoundedRectangle(cornerRadius: theme.metrics.rowCornerRadius, style: .continuous)
            .fill(fill)
            .padding(.vertical, 4)
            .padding(.horizontal, theme.metrics.screenHPadding)
    }

    /// Group label, same section-title idiom as the other screens.
    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(theme.typography.sectionTitle)
            .kerning(1)
            .foregroundStyle(theme.chrome.ink.opacity(0.4))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8,
                                      leading: theme.metrics.screenHPadding,
                                      bottom: 2,
                                      trailing: theme.metrics.screenHPadding))
    }

    private var gameList: some View {
        List {
            ForEach(lobbyGroups, id: \.label) { group in
                sectionHeader(group.label)
                ForEach(group.games) { game in
                    Button {
                        onOpen(game)
                    } label: {
                        GameRow(game: game)
                    }
                    .listRowBackground(rowBackground(fill: theme.chrome.cardFill))
                    .listRowInsets(rowInsets)
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

            // Every finished game lives here — out of the way, never
            // gone. Stats count them all.
            if !store.matchHistory.isEmpty {
                Button {
                    path.append(.matchHistory)
                } label: {
                    HStack {
                        Image(systemName: "archivebox")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.chrome.ink.opacity(0.5))
                        Text("Match History")
                            .font(theme.typography.font(14, .semibold))
                            .foregroundStyle(theme.chrome.ink.opacity(0.7))
                        Spacer()
                        Text("\(store.matchHistory.count)")
                            .font(theme.typography.font(13, .bold))
                            .foregroundStyle(theme.chrome.ink.opacity(0.4))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.chrome.ink.opacity(0.3))
                    }
                    // A comfortable tap target — the old row was too thin.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .padding(.vertical, 8)
                }
                .listRowBackground(rowBackground(fill: theme.chrome.ink.opacity(0.03)))
                .listRowInsets(rowInsets)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 44))
                .foregroundStyle(theme.chrome.ink.opacity(0.25))
            Text("No games yet")
                .font(theme.typography.font(18, .bold))
                .foregroundStyle(theme.chrome.ink.opacity(0.7))
            Text("Start a game against Robo — your games\nwill live here, ready to resume any time.")
                .font(theme.typography.font(13, .regular))
                .foregroundStyle(theme.chrome.ink.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Game row

private struct GameRow: View {
    @Environment(\.theme) private var theme

    let game: SavedGame

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(profile: game.opponentPlayer.profile, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(game.opponentPlayer.profile.displayName)
                    .font(theme.typography.font(15, .semibold))
                    .foregroundStyle(theme.chrome.textPrimary)
                Text("You \(game.localPlayer.score) · \(game.opponentPlayer.profile.displayName) \(game.opponentPlayer.score)")
                    .font(theme.typography.font(12, .medium))
                    .foregroundStyle(theme.chrome.ink.opacity(0.5))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 5) {
                    if let unread = game.unreadChat, unread > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 8))
                            Text("\(unread)")
                                .font(theme.typography.font(10, .heavy))
                        }
                        .foregroundStyle(theme.chrome.onAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.chrome.accent))
                    }
                    phaseChip
                }
                Text(game.updatedAt.formatted(.relative(presentation: .named)))
                    .font(theme.typography.font(10, .regular))
                    .foregroundStyle(theme.chrome.textMuted)
                if let expiry = expiryWarning {
                    Text(expiry)
                        .font(theme.typography.font(10, .semibold))
                        .foregroundStyle(theme.chrome.warning.opacity(0.85))
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var phaseChip: some View {
        let (label, tint): (String, Color) = {
            switch game.phase {
            case .yourTurn: return ("YOUR TURN", theme.semantic.turnAccent)
            case .waiting: return ("THEIR TURN", theme.chrome.ink.opacity(0.5))
            case .finished: return (finishedLabel, theme.chrome.ink.opacity(0.45))
            }
        }()
        Text(label)
            .font(theme.typography.font(9, .heavy))
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

// MARK: - Match History (Phase 12; renamed from "Past games")

/// Match History: every finished game, from the moment it finishes.
/// A PUSHED detail screen under Home (navigationDestination), never a
/// sheet — being on Home's stack is what makes backing out of a game
/// opened from here return HERE. Everything still opens (result overlay
/// → review → rematch) and the same swipe-delete semantics apply as in
/// the lobby. Purely a presentation split — profile stats draw on all
/// finished games.
private struct MatchHistoryView: View {
    @Environment(\.theme) private var theme

    let store: GameStore
    let onOpen: (SavedGame) -> Void
    let onDelete: (SavedGame) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MATCH HISTORY")
                    .font(theme.typography.font(15, .black))
                    .kerning(1.5)
                    .foregroundStyle(theme.chrome.textPrimary)
                Spacer()
            }
            .padding(.horizontal, theme.metrics.screenHPadding)
            .padding(.top, 20)
            .padding(.bottom, 8)

            if store.matchHistory.isEmpty {
                // Deleting the last one shouldn't leave a blank sheet.
                Text("No finished games yet — every game lands here when it ends.")
                    .font(theme.typography.font(13, .regular))
                    .foregroundStyle(theme.chrome.ink.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(30)
                Spacer()
            } else {
                List {
                    ForEach(store.matchHistory) { game in
                        Button {
                            onOpen(game)
                        } label: {
                            GameRow(game: game)
                        }
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: theme.metrics.rowCornerRadius, style: .continuous)
                                .fill(theme.chrome.cardFill)
                                .padding(.vertical, 4)
                        )
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                onDelete(game)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.chrome.screenBackground.ignoresSafeArea())
    }
}

// MARK: - Logo

/// The WORDS wordmark, extracted so a later design pass (or a theme) can
/// swap the mark in one place. Renders from theme typography.
struct LogoView: View {
    @Environment(\.theme) private var theme

    var size: CGFloat = 28

    var body: some View {
        Text("WORDS")
            .font(theme.typography.font(size, .black))
            .foregroundStyle(theme.chrome.ink)
    }
}

// AvatarCircle (the icon avatar) is gone — AvatarView (photo/duotone
// monogram, AvatarView.swift) is the one avatar component everywhere.

// MARK: - Profile editor
// Replaced by ProfileView.swift (the Profile hub: identity + stats +
// Settings sheet). The old combined sheet's pieces live there now.

// MARK: - New game setup

/// Opponent choice + difficulty. The opponent list is the Phase 4/7
/// generic player model surfacing in UI: Robo and each friend are just
/// selectable opponents; a friend seat becomes a human seat server-side.
private struct NewGameSetupSheet: View {
    @Environment(\.theme) private var theme

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
                .font(theme.typography.font(18, .bold))
                .frame(maxWidth: .infinity)

            sectionLabel("OPPONENT")

            ScrollView {
                VStack(spacing: 8) {
                    Button {
                        selectedFriend = nil
                    } label: {
                        opponentRow(userID: nil, name: PlayerProfile.ai.displayName,
                                    detail: "AI opponent", selected: selectedFriend == nil)
                    }
                    ForEach(friends.friends) { friend in
                        Button {
                            selectedFriend = friend
                        } label: {
                            opponentRow(userID: friend.userID,
                                        name: friend.displayName,
                                        detail: friend.username.map { "@\($0)" } ?? "Friend",
                                        selected: selectedFriend == friend)
                        }
                    }
                    if friends.friends.isEmpty {
                        Text("Add friends to challenge them — tap the friends icon on the home screen.")
                            .font(theme.typography.font(12, .regular))
                            .foregroundStyle(theme.chrome.textMuted)
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
                    .font(theme.typography.font(12, .regular))
                    .foregroundStyle(theme.chrome.ink.opacity(0.45))
                    .frame(maxWidth: .infinity)
            }

            Button {
                dismiss()
                onStart(selectedFriend.map { .friend($0) } ?? .robo(difficulty))
            } label: {
                Text(selectedFriend.map { "CHALLENGE \($0.displayName.uppercased())" } ?? "START GAME")
                    .font(theme.typography.buttonLabel)
                    .foregroundStyle(theme.chrome.buttonPrimaryText)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(theme.chrome.buttonPrimary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.top, 2)
        }
        .padding(24)
        .presentationDetents([.large])
        .presentationBackground(theme.chrome.screenBackground)
        .task { await friends.refresh() }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.typography.sectionTitle)
            .kerning(1)
            .foregroundStyle(theme.chrome.ink.opacity(0.4))
    }

    private func opponentRow(userID: UUID?, name: String, detail: String,
                             selected: Bool) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: name,
                       photoURL: userID.flatMap(AvatarView.publicAvatarURL(for:)),
                       size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(theme.typography.font(15, .semibold))
                    .foregroundStyle(theme.chrome.textPrimary)
                Text(detail)
                    .font(theme.typography.font(12, .regular))
                    .foregroundStyle(theme.chrome.ink.opacity(0.5))
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.chrome.accent)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: theme.metrics.cardCornerRadius, style: .continuous)
                .fill(theme.chrome.ink.opacity(selected ? 0.08 : 0.04))
        )
    }
}
