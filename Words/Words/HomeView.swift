import SwiftUI

/// The lobby: every game (in progress and finished) as a tappable list,
/// Scrabble GO-style, plus profile access and the new-game flow.
/// Deliberately restrained styling — the full design pass comes later.
struct HomeView: View {
    @Binding var profile: PlayerProfile
    let store: GameStore
    let auth: AuthController
    let onOpen: (SavedGame) -> Void
    let onNewGame: (AIDifficulty) -> Void

    @State private var showProfileEditor = false
    @State private var showNewGameSetup = false

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
            NewGameSetupSheet { difficulty in
                showNewGameSetup = false
                onNewGame(difficulty)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("WORDS")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
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
                    Button(role: .destructive) {
                        store.delete(id: game.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
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
                phaseChip
                Text(game.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
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
        if over.localFinal > over.opponentFinal { return "YOU WON" }
        if over.localFinal < over.opponentFinal { return "YOU LOST" }
        return "TIED"
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

    var body: some View {
        VStack(spacing: 20) {
            Text("Your profile")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            TextField("Your name", text: $profile.displayName)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
                .autocorrectionDisabled()

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

            accountSection
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationBackground(HomeView.background)
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

    @ViewBuilder
    private var accountSection: some View {
        switch auth.state {
        case .signedIn:
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
        case .offline:
            VStack(spacing: 8) {
                Text("Playing offline — no account")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Button("Sign in") {
                    dismiss()
                    auth.leaveOfflineMode()
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - New game setup

/// Opponent choice + difficulty. Today the only opponent is the AI; the
/// list structure is the seam where "invite a friend" slots in later
/// without redesigning this screen.
private struct NewGameSetupSheet: View {
    let onStart: (AIDifficulty) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var difficulty: AIDifficulty = .medium

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New game")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)

            sectionLabel("OPPONENT")

            opponentRow(avatar: .robot, name: PlayerProfile.ai.displayName,
                        detail: "AI opponent", selected: true)
            opponentRow(avatar: .star, name: "Invite a friend",
                        detail: "Coming with multiplayer", selected: false)
                .opacity(0.35)

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

            Button {
                dismiss()
                onStart(difficulty)
            } label: {
                Text("START GAME")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(Color.yellow))
            }
            .padding(.top, 4)
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationBackground(HomeView.background)
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
