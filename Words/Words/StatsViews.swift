import SwiftUI

/// Phase 13: leaderboard ranking policy — pure and testable, kept apart
/// from the views. The board ranks on WIN RATE over HUMAN games with a
/// minimum-games floor: total wins is a volume trophy, raw win rate lets
/// a 1-0 player squat on top forever, and the floor fixes exactly that.
/// Below the floor you're listed unranked with a "N more games" line.
/// Ties break by wins, then average score, then name — fully ordered so
/// the board never shuffles between refreshes.
enum Leaderboard {
    /// Finished HUMAN games needed before win rate means anything.
    static let rankingFloor = 5

    static func winRate(_ s: RemoteGames.PlayerStats.Subset) -> Double {
        let decided = s.wins + s.losses
        guard decided > 0 else { return 0 }
        return Double(s.wins) / Double(decided)
    }

    static func isRanked(_ e: RemoteGames.LeaderboardEntry) -> Bool {
        e.stats.human.games >= rankingFloor
    }

    /// Ranked players first (best first), then the not-yet-ranked (most
    /// games first — closest to qualifying on top).
    static func ordered(_ entries: [RemoteGames.LeaderboardEntry])
        -> (ranked: [RemoteGames.LeaderboardEntry], unranked: [RemoteGames.LeaderboardEntry]) {
        let ranked = entries.filter(isRanked).sorted { a, b in
            let ra = winRate(a.stats.human), rb = winRate(b.stats.human)
            if ra != rb { return ra > rb }
            if a.stats.human.wins != b.stats.human.wins {
                return a.stats.human.wins > b.stats.human.wins
            }
            if a.stats.human.avgScore != b.stats.human.avgScore {
                return a.stats.human.avgScore > b.stats.human.avgScore
            }
            return (a.displayName ?? "") < (b.displayName ?? "")
        }
        let unranked = entries.filter { !isRanked($0) }.sorted { a, b in
            a.stats.human.games != b.stats.human.games
                ? a.stats.human.games > b.stats.human.games
                : (a.displayName ?? "") < (b.displayName ?? "")
        }
        return (ranked, unranked)
    }
}

// MARK: - Personal stats sheet

/// "Your stats" — reached from the profile sheet, deliberately its own
/// sheet so the profile doesn't grow another section. Restrained styling;
/// the design pass is next.
struct StatsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var stats: RemoteGames.PlayerStats?
    @State private var loadFailed = false

    var body: some View {
        // Scrollable: three sections outgrow the .medium detent.
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("YOUR STATS")
                    .font(theme.typography.font(15, .black))
                    .kerning(1.5)
                    .foregroundStyle(theme.chrome.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.chrome.ink.opacity(0.3))
                }
            }

            if let stats {
                if stats.games == 0 {
                    Text("No finished games yet — your stats begin with your first result.")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.chrome.ink.opacity(0.5))
                        .padding(.top, 12)
                } else {
                    statsGrid(stats)
                }
            } else if loadFailed {
                HStack {
                    Text("Couldn't load your stats.")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.chrome.ink.opacity(0.5))
                    Button("Try again") { Task { await load() } }
                        .font(theme.typography.font(13, .semibold))
                }
                .padding(.top, 12)
            } else {
                ProgressView()
                    .tint(theme.chrome.ink.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        }
        .background(theme.chrome.screenBackground.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationBackground(theme.chrome.screenBackground)
        .task { await load() }
    }

    private func load() async {
        loadFailed = false
        do {
            stats = try await RemoteGames.fetchStats()
        } catch {
            loadFailed = true
        }
    }

    /// Three explicit blocks so nobody has to infer the framing:
    /// the RECORD is human games only (the competitive identity, what
    /// the leaderboard ranks); bests are opponent-agnostic; AI games
    /// read as PRACTICE — count and average, no W-L on purpose.
    private func statsGrid(_ s: RemoteGames.PlayerStats) -> some View {
        let grid = [GridItem(.flexible(), spacing: 10), GridItem(.flexible())]
        let human = s.human
        let practiceGames = s.ai?.games ?? max(0, s.games - human.games)
        return VStack(alignment: .leading, spacing: 14) {
            sectionLabel("YOUR RECORD",
                         caption: "Against people. These are the numbers the leaderboard ranks.")
            if human.games == 0 {
                Text("No games against people yet — challenge a friend to start your record.")
                    .font(theme.typography.font(12, .regular))
                    .foregroundStyle(theme.chrome.ink.opacity(0.45))
            } else {
                LazyVGrid(columns: grid, spacing: 10) {
                    statCard("RECORD",
                             "\(human.wins)–\(human.losses)\(human.ties > 0 ? "–\(human.ties)" : "")",
                             detail: "\(human.games) game\(human.games == 1 ? "" : "s")")
                    statCard("WIN RATE",
                             winRateText(wins: human.wins, losses: human.losses),
                             detail: human.wins + human.losses == 0 ? "no decided games yet" : nil)
                    statCard("AVG SCORE", "\(human.avgScore)", detail: nil)
                    statCard("BEST GAME", "\(s.bestGame)", detail: "any opponent")
                }
            }

            sectionLabel("BEST WORD",
                         caption: "Counts whoever you played — a great word is a great word.")
            statCard("BEST WORD",
                     s.bestWord.map { "\($0.word)" } ?? "—",
                     detail: s.bestWord.map { "+\($0.score)" } ?? "no words played yet")

            sectionLabel("PRACTICE VS ROBO",
                         caption: "Practice, not competition — you pick Robo's difficulty, so there's no win–loss record here.")
            if practiceGames == 0 {
                Text("No practice games yet — Robo's always up for one.")
                    .font(theme.typography.font(12, .regular))
                    .foregroundStyle(theme.chrome.ink.opacity(0.45))
            } else {
                LazyVGrid(columns: grid, spacing: 10) {
                    statCard("GAMES", "\(practiceGames)", detail: nil)
                    statCard("AVG SCORE", s.ai.map { "\($0.avgScore)" } ?? "—", detail: nil)
                }
            }
        }
    }

    private func sectionLabel(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(theme.typography.sectionTitle)
                .kerning(1)
                .foregroundStyle(theme.chrome.textSecondary)
            Text(caption)
                .font(theme.typography.caption)
                .foregroundStyle(theme.chrome.ink.opacity(0.3))
        }
    }

    private func statCard(_ label: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(theme.typography.font(9, .heavy))
                .kerning(1)
                .foregroundStyle(theme.chrome.ink.opacity(0.4))
            Text(value)
                .font(theme.typography.font(18, .black))
                .foregroundStyle(theme.chrome.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let detail {
                Text(detail)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.chrome.ink.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: theme.metrics.cardCornerRadius, style: .continuous)
                .fill(theme.chrome.cardFill)
        )
    }
}

func winRateText(wins: Int, losses: Int) -> String {
    let decided = wins + losses
    guard decided > 0 else { return "—" }
    return "\(Int((Double(wins) / Double(decided) * 100).rounded()))%"
}

// MARK: - Leaderboard (currently unpresented)

/// NOTE (2026-07-31): the Leaderboard TAB was removed — it didn't earn
/// top-level nav in a friends-and-family app; head-to-head moved to the
/// Friends screen (friend row's "…" menu). This view is intentionally
/// left intact but UNREFERENCED (nothing presents it), along with the
/// Phase 13 leaderboard RPCs, so it can be repurposed or fully removed
/// later.
///
/// The friends-only leaderboard. Friends-only by construction: the
/// server returns me + accepted friends, nothing else. Ranked on win
/// rate over human games with a minimum-games floor (see Leaderboard);
/// tapping a friend's row opens the head-to-head record.
struct LeaderboardView: View {
    @Environment(\.theme) private var theme

    let store: FriendsStore
    /// Phase 13: tapping a leaderboard row opens the head-to-head record.
    @State private var headToHeadFriend: RemoteGames.FriendDTO?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LEADERBOARD")
                    .font(theme.typography.font(20, .black))
                    .foregroundStyle(theme.chrome.ink)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let entries = store.leaderboard {
                        if store.friends.isEmpty {
                            Text("Your leaderboard starts with your first friend — share your invite link from the Friends tab.")
                                .font(theme.typography.font(12, .regular))
                                .foregroundStyle(theme.chrome.ink.opacity(0.4))
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
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.chrome.ink.opacity(0.3))
                        }
                    } else if store.leaderboardFailed {
                        HStack {
                            Text("Couldn't load the leaderboard.")
                                .font(theme.typography.font(12, .regular))
                                .foregroundStyle(theme.chrome.ink.opacity(0.5))
                            Button("Try again") {
                                Task { await store.refreshLeaderboard() }
                            }
                            .font(theme.typography.font(12, .semibold))
                        }
                    } else {
                        ProgressView()
                            .tint(theme.chrome.ink.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(theme.chrome.screenBackground.ignoresSafeArea())
        .task { await store.refresh() }
        .sheet(item: $headToHeadFriend) { friend in
            HeadToHeadSheet(friend: friend)
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
                    .font(theme.typography.font(13, .heavy))
                    .foregroundStyle(rank == 1 ? theme.chrome.accent : theme.chrome.ink.opacity(0.4))
                    .frame(width: 30, alignment: .leading)
                AvatarCircle(avatar: Avatar(rawValue: entry.avatar ?? "") ?? .star, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.me ? "You" : (entry.displayName ?? "Player"))
                        .font(theme.typography.font(14, .semibold))
                        .foregroundStyle(theme.chrome.ink.opacity(entry.me ? 1 : 0.9))
                    if rank == nil {
                        let needed = Leaderboard.rankingFloor - entry.stats.human.games
                        Text("\(needed) more game\(needed == 1 ? "" : "s") to rank")
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.chrome.textMuted)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(entry.stats.human.wins)–\(entry.stats.human.losses)")
                        .font(theme.typography.font(14, .bold))
                        .foregroundStyle(theme.chrome.textPrimary)
                    Text("\(winRateText(wins: entry.stats.human.wins, losses: entry.stats.human.losses)) · avg \(entry.stats.human.avgScore)")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.chrome.ink.opacity(0.4))
                }
            }
            .padding(10)
            .opacity(rank == nil ? 0.6 : 1)
            .background(RoundedRectangle(cornerRadius: theme.metrics.cardCornerRadius, style: .continuous)
                .fill(theme.chrome.ink.opacity(entry.me ? 0.09 : 0.06)))
        }
    }
}

// MARK: - Head-to-head sheet

/// Our record against one friend — the stat a friends-and-family game
/// actually runs on.
struct HeadToHeadSheet: View {
    @Environment(\.theme) private var theme
    let friend: RemoteGames.FriendDTO
    @Environment(\.dismiss) private var dismiss
    @State private var record: RemoteGames.HeadToHead?
    @State private var loadFailed = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("YOU vs \(friend.displayName.uppercased())")
                    .font(theme.typography.font(15, .black))
                    .kerning(1)
                    .foregroundStyle(theme.chrome.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.chrome.ink.opacity(0.3))
                }
            }

            if let record {
                if record.games == 0 {
                    Text("No finished games together yet — challenge them and start the record.")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.chrome.ink.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                } else {
                    Text("\(record.myWins) – \(record.theirWins)")
                        .font(theme.typography.font(44, .black))
                        .foregroundStyle(theme.chrome.accent)
                    Text(recordLine(record))
                        .font(theme.typography.font(13, .semibold))
                        .foregroundStyle(theme.chrome.ink.opacity(0.6))
                    HStack(spacing: 24) {
                        vStat("YOUR AVG", "\(record.myAvg)")
                        vStat("THEIR AVG", "\(record.theirAvg)")
                        if record.ties > 0 { vStat("TIES", "\(record.ties)") }
                    }
                    if let last = record.lastPlayedDate {
                        Text("Last played \(last.formatted(.relative(presentation: .named)))")
                            .font(theme.typography.font(11, .regular))
                            .foregroundStyle(theme.chrome.textMuted)
                    }
                }
            } else if loadFailed {
                HStack {
                    Text("Couldn't load the record.")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.chrome.ink.opacity(0.5))
                    Button("Try again") { Task { await load() } }
                        .font(theme.typography.font(13, .semibold))
                }
                .padding(.top, 16)
            } else {
                ProgressView()
                    .tint(theme.chrome.ink.opacity(0.4))
                    .padding(.top, 30)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(theme.chrome.screenBackground.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationBackground(theme.chrome.screenBackground)
        .task { await load() }
    }

    private func load() async {
        loadFailed = false
        do {
            record = try await RemoteGames.fetchHeadToHead(with: friend.userID)
        } catch {
            loadFailed = true
        }
    }

    private func recordLine(_ r: RemoteGames.HeadToHead) -> String {
        if r.myWins > r.theirWins { return "You lead \(friend.displayName)" }
        if r.myWins < r.theirWins { return "\(friend.displayName) leads you" }
        return "Dead even with \(friend.displayName)"
    }

    private func vStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(theme.typography.font(9, .heavy))
                .kerning(1)
                .foregroundStyle(theme.chrome.ink.opacity(0.4))
            Text(value)
                .font(theme.typography.font(18, .black))
                .foregroundStyle(theme.chrome.textPrimary)
        }
    }
}
