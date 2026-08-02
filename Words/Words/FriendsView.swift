import SwiftUI
import Observation

/// Client-side friends state: the friend/request list, blocked players,
/// the shareable invite link, and username search. All server calls go
/// through RemoteGames; this just caches and refreshes.
@MainActor
@Observable
final class FriendsStore {

    #if DEBUG
    /// DEV SWITCH — when true, the Friends screen renders UNMISTAKABLY
    /// FAKE, client-side-only data ("Pending User 1", "Friend User A",
    /// "Blocked User B"…) so the fully-populated layout can be judged
    /// without test accounts. While on, NO friend/block/invite RPC is
    /// called and nothing is ever written to the server (row actions
    /// no-op); the leaderboard fetch stays live for its own tab.
    /// Compile-time walled: this symbol and every use site are inside
    /// `#if DEBUG` — it cannot exist in a release build.
    static let useMockFriends = false

    private static let mockEntries: [RemoteGames.FriendDTO] =
        (1...3).map {
            RemoteGames.FriendDTO(userID: UUID(),
                                  displayName: "Pending User \($0)",
                                  avatar: ["bolt", "flame", "leaf"][$0 - 1],
                                  username: "pending_user_\($0)",
                                  state: "incoming")
        }
        + zip(["A", "B", "C", "D", "E"],
              ["drop", "star", "heart", "moon", "crown"]).map { letter, avatar in
            RemoteGames.FriendDTO(userID: UUID(),
                                  displayName: "Friend User \(letter)",
                                  avatar: avatar,
                                  username: "friend_user_\(letter.lowercased())",
                                  state: "friend")
        }

    private static let mockBlocked: [RemoteGames.BlockedUser] =
        ["A", "B"].map {
            RemoteGames.BlockedUser(userID: UUID(),
                                    displayName: "Blocked User \($0)",
                                    avatar: nil)
        }
    #endif

    private(set) var entries: [RemoteGames.FriendDTO] = []
    /// Players I've blocked (Phase 11) — shown as Friends' BLOCKED section.
    private(set) var blocked: [RemoteGames.BlockedUser] = []
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
        #if DEBUG
        if Self.useMockFriends {
            entries = Self.mockEntries
            blocked = Self.mockBlocked
            myUsername = "mock_me"
            await refreshLeaderboard()
            return
        }
        #endif
        if let list = try? await RemoteGames.listFriends() {
            entries = list
        }
        if let mine = try? await RemoteGames.listBlocked() {
            blocked = mine
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
        #if DEBUG
        if Self.useMockFriends {
            inviteToken = "mock-invite-token-not-real"
            return
        }
        #endif
        if inviteToken == nil {
            inviteToken = try? await RemoteGames.createInvite()
        }
    }

    func search(_ query: String) async {
        #if DEBUG
        if Self.useMockFriends { return }
        #endif
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
        #if DEBUG
        if Self.useMockFriends { return }
        #endif
        _ = try? await RemoteGames.sendFriendRequest(to: user.userID)
        searchResults.removeAll { $0.userID == user.userID }
        await refresh()
    }

    func respond(to user: RemoteGames.FriendDTO, accept: Bool) async {
        #if DEBUG
        if Self.useMockFriends { return }
        #endif
        try? await RemoteGames.respondFriendRequest(from: user.userID, accept: accept)
        await refresh()
    }

    func remove(_ user: RemoteGames.FriendDTO) async {
        #if DEBUG
        if Self.useMockFriends { return }
        #endif
        try? await RemoteGames.removeFriend(user.userID)
        await refresh()
    }

    /// Phase 11 unblock, relocated here with the blocked list. Product
    /// rule unchanged (11b): unblocking does NOT restore friendship —
    /// it only permits a new, deliberate reconnection.
    func unblock(_ user: RemoteGames.BlockedUser) async {
        #if DEBUG
        if Self.useMockFriends { return }
        #endif
        try? await RemoteGames.unblockUser(user.userID)
        blocked.removeAll { $0.userID == user.userID }
    }
}

/// Friends screen — the single home for the whole relationship
/// lifecycle, sectioned top-to-bottom: invite → search → PENDING (only
/// when someone awaits your answer) → REQUESTED (only when you have
/// outgoing requests) → FRIENDS → BLOCKED (only when non-empty).
/// Also the home of head-to-head (a friend row's "…" menu) since the
/// Leaderboard tab was removed. Minimal styling — design pass later.
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
    @State private var unblockNotice: String?
    /// Head-to-head lives here now (the Leaderboard tab is gone):
    /// per-friend record, opened from the friend row's menu.
    @State private var headToHeadFriend: RemoteGames.FriendDTO?

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
            .padding(.horizontal, theme.metrics.screenHPadding)
            .padding(.vertical, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    inviteSection
                    searchSection
                    pendingSection
                    requestedSection
                    friendsSection
                    blockedSection
                }
                .padding(.horizontal, theme.metrics.screenHPadding)
                .padding(.bottom, 24)
            }
        }
        .background(theme.chrome.screenBackground.ignoresSafeArea())
        .alert("Unblocked",
               isPresented: .init(get: { unblockNotice != nil },
                                  set: { if !$0 { unblockNotice = nil } })) {
            Button("OK") { unblockNotice = nil }
        } message: {
            Text(unblockNotice ?? "")
        }
        .sheet(item: $headToHeadFriend) { friend in
            HeadToHeadSheet(friend: friend)
        }
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

    /// Incoming requests, accept/decline. Renders only when non-empty.
    @ViewBuilder
    private var pendingSection: some View {
        if !store.incoming.isEmpty {
            section("PENDING") {
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
    }

    /// Outgoing requests (with Cancel) — kept from the previous layout;
    /// renders only when non-empty.
    @ViewBuilder
    private var requestedSection: some View {
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
    }

    private var friendsSection: some View {
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
                            Button("Head-to-head record") {
                                headToHeadFriend = user
                            }
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

    /// Blocked players (moved here from the Profile sheet — Phase 11
    /// list, same unblock flow). Same row style as friends, but the only
    /// action is Unblock: no Challenge, no menu. Renders only when
    /// non-empty.
    @ViewBuilder
    private var blockedSection: some View {
        if !store.blocked.isEmpty {
            section("BLOCKED") {
                ForEach(store.blocked) { user in
                    row(userID: user.userID,
                        name: user.displayName,
                        username: nil) {
                        smallButton("Unblock") {
                            let name = user.displayName
                            Task {
                                await store.unblock(user)
                                unblockNotice = "\(name) is unblocked. Blocking ended your friendship, so you're not friends again automatically — send a friend request or share your invite link if you want to reconnect."
                            }
                        }
                    }
                }
                // The rule, stated where the action lives — never a
                // silent "wait, what happened?" moment.
                Text("Unblocking doesn't re-add someone as a friend.")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.chrome.ink.opacity(0.3))
            }
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
        row(userID: user.userID,
            name: user.displayName,
            username: user.username,
            trailing: trailing)
    }

    /// The one person-row shape (avatar · name · @username · action),
    /// shared by every section — blocked rows included.
    private func row(userID: UUID?, name: String, username: String?,
                     @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 10) {
            AvatarView(name: name,
                       photoURL: userID.flatMap(AvatarView.publicAvatarURL(for:)),
                       size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(theme.typography.font(14, .semibold))
                    .foregroundStyle(theme.chrome.textPrimary)
                if let username {
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
