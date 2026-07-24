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
/// Minimal styling — design pass later.
struct FriendsView: View {
    let store: FriendsStore
    let onChallenge: (RemoteGames.FriendDTO) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var removalCandidate: RemoteGames.FriendDTO?
    /// Phase 13: tapping a leaderboard row opens the head-to-head record.
    @State private var headToHeadFriend: RemoteGames.FriendDTO?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("FRIENDS")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button("Done") { dismiss() }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    leaderboardSection
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
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(.white.opacity(0.4))
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
                                            .foregroundStyle(.white.opacity(0.5))
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
        .background(HomeView.background.ignoresSafeArea())
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
        .sheet(item: $headToHeadFriend) { friend in
            HeadToHeadSheet(friend: friend)
        }
    }

    // MARK: - Leaderboard (Phase 13)

    /// Friends-only by construction: the server returns me + accepted
    /// friends, nothing else. Ranked on win rate over human games with a
    /// minimum-games floor (see Leaderboard); tapping a friend's row
    /// opens the head-to-head record.
    @ViewBuilder
    private var leaderboardSection: some View {
        section("LEADERBOARD") {
            if let entries = store.leaderboard {
                if store.friends.isEmpty {
                    Text("Your leaderboard starts with your first friend — share your invite link below.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.vertical, 6)
                } else {
                    let (ranked, unranked) = Leaderboard.ordered(entries)
                    ForEach(Array(ranked.enumerated()), id: \.element.id) { index, entry in
                        leaderboardRow(entry, rank: index + 1)
                    }
                    ForEach(unranked) { entry in
                        leaderboardRow(entry, rank: nil)
                    }
                    Text("Ranked by win rate against humans, after \(Leaderboard.rankingFloor) finished games. Robo doesn't count here.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                }
            } else if store.leaderboardFailed {
                HStack {
                    Text("Couldn't load the leaderboard.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                    Button("Try again") {
                        Task { await store.refreshLeaderboard() }
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
            } else {
                ProgressView()
                    .tint(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
    }

    private func leaderboardRow(_ entry: RemoteGames.LeaderboardEntry, rank: Int?) -> some View {
        Button {
            // My own row has no head-to-head; friends' rows open ours.
            guard !entry.me,
                  let friend = store.friends.first(where: { $0.userID == entry.userID })
            else { return }
            headToHeadFriend = friend
        } label: {
            HStack(spacing: 10) {
                Text(rank.map { "#\($0)" } ?? "—")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(rank == 1 ? Color.yellow : .white.opacity(0.4))
                    .frame(width: 30, alignment: .leading)
                AvatarCircle(avatar: Avatar(rawValue: entry.avatar ?? "") ?? .star, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.me ? "You" : (entry.displayName ?? "Player"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(entry.me ? 1 : 0.9))
                    if rank == nil {
                        let needed = Leaderboard.rankingFloor - entry.stats.human.games
                        Text("\(needed) more game\(needed == 1 ? "" : "s") to rank")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(entry.stats.human.wins)–\(entry.stats.human.losses)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("\(winRateText(wins: entry.stats.human.wins, losses: entry.stats.human.losses)) · avg \(entry.stats.human.avgScore)")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(10)
            .opacity(rank == nil ? 0.6 : 1)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(entry.me ? 0.09 : 0.06)))
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
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                    }
                    .foregroundStyle(.black)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.yellow))
                }
                Text("Anyone who opens your link becomes your friend. Links last 30 days.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
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
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
            ForEach(store.searchResults) { user in
                row(user) {
                    searchAction(for: user)
                }
            }
            // Your own searchability, stated where search lives.
            if let mine = store.myUsername {
                Text("Friends can find you by your name or @\(mine).")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
            } else {
                Text("Friends can find you by your name. A username adds an exact handle — set one from your profile if you want one.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
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
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
        case "outgoing":
            Text("Requested")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
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
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .kerning(1)
                .foregroundStyle(.white.opacity(0.4))
            content()
        }
    }

    private func row(_ user: RemoteGames.FriendDTO,
                     @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 10) {
            AvatarCircle(avatar: Avatar(rawValue: user.avatar ?? "") ?? .star, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(user.displayName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                if let username = user.username {
                    Text("@\(username)")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            Spacer()
            trailing()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.06)))
    }

    private func smallButton(_ label: String, prominent: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(prominent ? .black : .white.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(prominent ? Color.yellow : Color.white.opacity(0.1)))
        }
    }
}
