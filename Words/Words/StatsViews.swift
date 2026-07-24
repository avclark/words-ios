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
    @Environment(\.dismiss) private var dismiss
    @State private var stats: RemoteGames.PlayerStats?
    @State private var loadFailed = false

    var body: some View {
        // Scrollable: three sections outgrow the .medium detent.
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("YOUR STATS")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .kerning(1.5)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            if let stats {
                if stats.games == 0 {
                    Text("No finished games yet — your stats begin with your first result.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 12)
                } else {
                    statsGrid(stats)
                }
            } else if loadFailed {
                HStack {
                    Text("Couldn't load your stats.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                    Button("Try again") { Task { await load() } }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .padding(.top, 12)
            } else {
                ProgressView()
                    .tint(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        }
        .background(HomeView.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationBackground(HomeView.background)
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
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
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
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
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
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .kerning(1)
                .foregroundStyle(.white.opacity(0.55))
            Text(caption)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private func statCard(_ label: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .kerning(1)
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(.yellow)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let detail {
                Text(detail)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}

func winRateText(wins: Int, losses: Int) -> String {
    let decided = wins + losses
    guard decided > 0 else { return "—" }
    return "\(Int((Double(wins) / Double(decided) * 100).rounded()))%"
}

// MARK: - Head-to-head sheet

/// Our record against one friend — the stat a friends-and-family game
/// actually runs on.
struct HeadToHeadSheet: View {
    let friend: RemoteGames.FriendDTO
    @Environment(\.dismiss) private var dismiss
    @State private var record: RemoteGames.HeadToHead?
    @State private var loadFailed = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("YOU vs \(friend.displayName.uppercased())")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .kerning(1)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            if let record {
                if record.games == 0 {
                    Text("No finished games together yet — challenge them and start the record.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                } else {
                    Text("\(record.myWins) – \(record.theirWins)")
                        .font(.system(size: 44, weight: .black, design: .rounded))
                        .foregroundStyle(.yellow)
                    Text(recordLine(record))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 24) {
                        vStat("YOUR AVG", "\(record.myAvg)")
                        vStat("THEIR AVG", "\(record.theirAvg)")
                        if record.ties > 0 { vStat("TIES", "\(record.ties)") }
                    }
                    if let last = record.lastPlayedDate {
                        Text("Last played \(last.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            } else if loadFailed {
                HStack {
                    Text("Couldn't load the record.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                    Button("Try again") { Task { await load() } }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .padding(.top, 16)
            } else {
                ProgressView()
                    .tint(.white.opacity(0.4))
                    .padding(.top, 30)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(HomeView.background.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationBackground(HomeView.background)
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
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .kerning(1)
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}
