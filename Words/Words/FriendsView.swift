import SwiftUI
import Observation

/// Client-side friends state: the friend/request list, the shareable
/// invite link, and username search. All server calls go through
/// RemoteGames; this just caches and refreshes.
@MainActor
@Observable
final class FriendsStore {
    private(set) var entries: [RemoteGames.FriendDTO] = []
    private(set) var inviteToken: String?
    var searchResults: [RemoteGames.FriendDTO] = []
    /// True when the last non-empty search legitimately matched nobody —
    /// distinct from "no search performed" (a silent nothing is ambiguous
    /// between "no such user" and "they never set a username").
    private(set) var searchCameUpEmpty = false
    /// My own username (nil = not searchable), for the status line.
    private(set) var myUsername: String?
    /// Phase 13: me + friends with stats, for the leaderboard section.
    /// nil = not loaded yet; distinct from a loaded-but-failed state.
    private(set) var leaderboard: [RemoteGames.LeaderboardEntry]?
    private(set) var leaderboardFailed = false

    private let selfID: UUID

    init(selfID: UUID) {
        self.selfID = selfID
    }

    var friends: [RemoteGames.FriendDTO] { entries.filter { $0.state == "friend" } }
    var incoming: [RemoteGames.FriendDTO] { entries.filter { $0.state == "incoming" } }
    var outgoing: [RemoteGames.FriendDTO] { entries.filter { $0.state == "outgoing" } }

    /// The shareable link. Custom scheme for now (works with zero Apple
    /// configuration); universal links can replace this at ship time once
    /// a domain exists to host the AASA file.
    var inviteURL: URL? {
        inviteToken.flatMap { URL(string: "words://invite/\($0)") }
    }

    func refresh() async {
        if let list = try? await RemoteGames.listFriends() {
            entries = list
        }
        if let name = try? await RemoteGames.fetchUsername(userID: selfID) {
            myUsername = name
        }
        await refreshLeaderboard()
    }

    func refreshLeaderboard() async {
        do {
            leaderboard = try await RemoteGames.fetchLeaderboard()
            leaderboardFailed = false
        } catch {
            // Keep any previous board; only flag failure when we have
            // nothing at all to show (never a silent blank).
            if leaderboard == nil { leaderboardFailed = true }
        }
    }

    func loadInviteLink() async {
        if inviteToken == nil {
            inviteToken = try? await RemoteGames.createInvite()
        }
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            searchResults = []
            searchCameUpEmpty = false
            return
        }
        searchResults = (try? await RemoteGames.searchProfiles(query: trimmed)) ?? []
        searchCameUpEmpty = searchResults.isEmpty
    }

    func sendRequest(to user: RemoteGames.FriendDTO) async {
        _ = try? await RemoteGames.sendFriendRequest(to: user.userID)
        searchResults.removeAll { $0.userID == user.userID }
        await refresh()
    }

    func respond(to user: RemoteGames.FriendDTO, accept: Bool) async {
        try? await RemoteGames.respondFriendRequest(from: user.userID, accept: accept)
        await refresh()
    }

    func remove(_ user: RemoteGames.FriendDTO) async {
        try? await RemoteGames.removeFriend(user.userID)
        await refresh()
    }
}

/// Friends screen: invite link (primary), username search (backstop),
/// pending requests both ways, and the friends list with challenge.
/// People-management only — the leaderboard lives in its own tab
/// (LeaderboardView). Minimal styling — design pass later.
struct FriendsView: View {
    @Environment(\.theme) private var theme

    let store: FriendsStore
    /// True when shown as a root tab (no Done button — nothing to dismiss).
    var isTab: Bool = false
    let onChallenge: (RemoteGames.FriendDTO) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var removalCandidate: RemoteGames.FriendDTO?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("FRIENDS")
                    .font(theme.typography.font(20, .black))
                    .foregroundStyle(theme.chrome.ink)
                Spacer()
                if !isTab {
                    Button("Done") { dismiss() }
                        .font(theme.typography.font(14, .semibold))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    inviteSection
                    searchSection
                    if !store.incoming.isEmpty {
                        section("WANTS TO BE FRIENDS") {
                            ForEach(store.incoming) { user in
                                row(user) {
                                    HStack(spacing: 10) {
                                        smallButton("Accept", prominent: true) {
                                            Task { await store.respond(to: user, accept: true) }
                                        }
                                        smallButton("Decline") {
                                            Task { await store.respond(to: user, accept: false) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !store.outgoing.isEmpty {
                        section("REQUESTED") {
                            ForEach(store.outgoing) { user in
                                row(user) {
                                    smallButton("Cancel") {
                                        Task { await store.remove(user) }
                                    }
                                }
                            }
                        }
                    }
                    section("FRIENDS") {
                        if store.friends.isEmpty {
                            Text("No friends yet — share your invite link to get started.")
                                .font(theme.typography.body)
                                .foregroundStyle(theme.chrome.ink.opacity(0.4))
                                .padding(.vertical, 8)
                        }
                        ForEach(store.friends) { user in
                            row(user) {
                                HStack(spacing: 10) {
                                    smallButton("Challenge", prominent: true) {
                                        dismiss()
                                        onChallenge(user)
                                    }
                                    Menu {
                                        Button("Remove friend…", role: .destructive) {
                                            removalCandidate = user
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .foregroundStyle(theme.chrome.ink.opacity(0.5))
                                            .frame(width: 28, height: 28)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(theme.chrome.screenBackground.ignoresSafeArea())
        .task {
            await store.loadInviteLink()
            await store.refresh()
        }
        // The gentle rung of the ladder (unfriend < block < delete), and
        // it says exactly what it does before doing it.
        .confirmationDialog(
            "Remove \(removalCandidate?.displayName ?? "friend")?",
            isPresented: .init(get: { removalCandidate != nil },
                               set: { if !$0 { removalCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove friend", role: .destructive) {
                if let user = removalCandidate {
                    removalCandidate = nil
                    Task { await store.remove(user) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Games you're currently playing continue (with their chat), but you won't be able to start new games or rematch unless you become friends again. To cut off all contact instead, use Block from a game's chat.")
        }
    }

    private var inviteSection: some View {
        section("INVITE A FRIEND") {
            if let url = store.inviteURL {
                ShareLink(item: url,
                          message: Text("Play Words with me! Open this link on your iPhone:")) {
                    HStack {
                        Image(systemName: "link")
                        Text("Share my invite link")
                            .font(theme.typography.font(15, .semibold))
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                    }
                    .foregroundStyle(theme.chrome.buttonPrimaryText)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: theme.metrics.cardCornerRadius, style: .continuous)
                        .fill(theme.chrome.buttonPrimary))
                }
                Text("Anyone who opens your link becomes your friend. Links last 30 days.")
                    .font(theme.typography.font(11, .regular))
                    .foregroundStyle(theme.chrome.textMuted)
            } else {
                ProgressView().padding(8)
            }
        }
    }

    private var searchSection: some View {
        section("FIND FRIENDS") {
            TextField("name or username", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: searchText) { _, query in
                    searchTask?.cancel()
                    searchTask = Task {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        guard !Task.isCancelled else { return }
                        await store.search(query)
                    }
                }
            if store.searchCameUpEmpty {
                Text("No one found matching that.")
                    .font(theme.typography.font(12, .regular))
                    .foregroundStyle(theme.chrome.ink.opacity(0.4))
            }
            ForEach(store.searchResults) { user in
                row(user) {
                    searchAction(for: user)
                }
            }
            // Your own searchability, stated where search lives.
            if let mine = store.myUsername {
                Text("Friends can find you by your name or @\(mine).")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.chrome.ink.opacity(0.3))
            } else {
                Text("Friends can find you by your name. A username adds an exact handle — set one from your profile if you want one.")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.chrome.ink.opacity(0.3))
            }
        }
    }

    /// Search rows are distinguishable by relationship, not just name:
    /// same-named people differ by avatar, @username, and whether you're
    /// already connected.
    @ViewBuilder
    private func searchAction(for user: RemoteGames.FriendDTO) -> some View {
        switch user.state {
        case "friend":
            Text("Friends ✓")
                .font(theme.typography.font(12, .semibold))
                .foregroundStyle(theme.chrome.ink.opacity(0.4))
        case "outgoing":
            Text("Requested")
                .font(theme.typography.font(12, .semibold))
                .foregroundStyle(theme.chrome.ink.opacity(0.4))
        case "incoming":
            smallButton("Accept", prominent: true) {
                Task { await store.respond(to: user, accept: true) }
            }
        default:
            smallButton("Add", prominent: true) {
                Task { await store.sendRequest(to: user) }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(theme.typography.sectionTitle)
                .kerning(1)
                .foregroundStyle(theme.chrome.ink.opacity(0.4))
            content()
        }
    }

    private func row(_ user: RemoteGames.FriendDTO,
                     @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 10) {
            AvatarCircle(avatar: Avatar(rawValue: user.avatar ?? "") ?? .star, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(user.displayName)
                    .font(theme.typography.font(14, .semibold))
                    .foregroundStyle(theme.chrome.textPrimary)
                if let username = user.username {
                    Text("@\(username)")
                        .font(theme.typography.font(11, .regular))
                        .foregroundStyle(theme.chrome.ink.opacity(0.4))
                }
            }
            Spacer()
            trailing()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: theme.metrics.cardCornerRadius, style: .continuous)
            .fill(theme.chrome.cardFill))
    }

    private func smallButton(_ label: String, prominent: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(theme.typography.font(12, .bold))
                .foregroundStyle(prominent ? theme.chrome.buttonPrimaryText
                                           : theme.chrome.buttonSecondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(prominent ? theme.chrome.buttonPrimary
                                                     : theme.chrome.buttonSecondaryFill))
        }
    }
}
