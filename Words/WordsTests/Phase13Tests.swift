//
//  Phase13Tests.swift
//  WordsTests
//
//  Phase 13: leaderboard ranking policy (floor, ordering, tie-breaks)
//  and the stats wire types.
//

import Testing
import Foundation
@testable import Words

struct Phase13Tests {

    // MARK: - Fixtures

    private func statsJSON(games: Int = 0, wins: Int = 0, losses: Int = 0,
                           ties: Int = 0, avg: Int = 0, best: Int = 0,
                           bestWord: String? = nil,
                           hGames: Int = 0, hWins: Int = 0, hLosses: Int = 0,
                           hAvg: Int = 0,
                           aiGames: Int = 0, aiAvg: Int = 0,
                           includeAI: Bool = true) -> String {
        let word = bestWord.map { "{\"word\":\"\($0)\",\"score\":42}" } ?? "null"
        let ai = includeAI ? ",\"ai\":{\"games\":\(aiGames),\"avg_score\":\(aiAvg)}" : ""
        return """
        {"games":\(games),"wins":\(wins),"losses":\(losses),"ties":\(ties),
         "avg_score":\(avg),"best_game":\(best),"best_word":\(word),
         "human":{"games":\(hGames),"wins":\(hWins),"losses":\(hLosses),
                  "ties":0,"avg_score":\(hAvg)}\(ai)}
        """
    }

    private func entry(name: String, me: Bool = false,
                       hGames: Int, hWins: Int, hLosses: Int,
                       hAvg: Int = 0) -> RemoteGames.LeaderboardEntry {
        let json = """
        {"user_id":"\(UUID().uuidString)","display_name":"\(name)",
         "avatar":null,"username":null,"me":\(me),
         "stats":\(statsJSON(games: hGames, wins: hWins, losses: hLosses,
                             hGames: hGames, hWins: hWins, hLosses: hLosses,
                             hAvg: hAvg))}
        """
        return try! JSONDecoder().decode(RemoteGames.LeaderboardEntry.self,
                                         from: Data(json.utf8))
    }

    // MARK: - Wire types

    @Test func statsDecodeWithAndWithoutBestWord() throws {
        let with = try JSONDecoder().decode(
            RemoteGames.PlayerStats.self,
            from: Data(statsJSON(games: 3, wins: 2, losses: 1, avg: 210,
                                 best: 305, bestWord: "QUARTZ",
                                 hGames: 1, hWins: 1,
                                 aiGames: 2, aiAvg: 180).utf8))
        #expect(with.wins == 2 && with.bestGame == 305)
        #expect(with.bestWord?.word == "QUARTZ" && with.bestWord?.score == 42)
        #expect(with.human.games == 1 && with.human.wins == 1)
        #expect(with.ai?.games == 2 && with.ai?.avgScore == 180)

        // A player with no finished games: best_word null, everything 0.
        let empty = try JSONDecoder().decode(
            RemoteGames.PlayerStats.self, from: Data(statsJSON().utf8))
        #expect(empty.games == 0 && empty.bestWord == nil)
    }

    /// Pre-13c payloads have no 'ai' key — decode must tolerate it so a
    /// client update never breaks against a not-yet-pasted schema.
    @Test func statsDecodeToleratesMissingPracticeSubset() throws {
        let old = try JSONDecoder().decode(
            RemoteGames.PlayerStats.self,
            from: Data(statsJSON(games: 5, wins: 1, hGames: 2, hWins: 1,
                                 includeAI: false).utf8))
        #expect(old.ai == nil)
        #expect(old.games == 5 && old.human.games == 2)
    }

    @Test func headToHeadDecodes() throws {
        let json = """
        {"games":4,"my_wins":3,"their_wins":1,"ties":0,
         "my_avg":250,"their_avg":238,"last_played":"2026-07-20T10:00:00+00:00"}
        """
        let record = try JSONDecoder().decode(RemoteGames.HeadToHead.self,
                                              from: Data(json.utf8))
        #expect(record.myWins == 3 && record.theirWins == 1)
        #expect(record.lastPlayedDate != nil)
    }

    // MARK: - Ranking policy

    /// The floor: fewer than rankingFloor human games = unranked, however
    /// good the rate. At the floor = ranked.
    @Test func rankingFloorSplitsRankedFromUnranked() {
        let veteran = entry(name: "Vet", hGames: Leaderboard.rankingFloor,
                            hWins: 2, hLosses: 3)
        let hotshot = entry(name: "Hot", hGames: 1, hWins: 1, hLosses: 0) // 1-0
        let (ranked, unranked) = Leaderboard.ordered([hotshot, veteran])
        #expect(ranked.map(\.displayName) == ["Vet"],
                "A 1-0 record must not outrank a qualified player")
        #expect(unranked.map(\.displayName) == ["Hot"])
    }

    /// Ranked order: win rate desc, then wins, then avg score, then name.
    @Test func rankedOrderingAndTieBreaks() {
        let a = entry(name: "Alice", hGames: 10, hWins: 8, hLosses: 2)          // 80%
        let b = entry(name: "Bob", hGames: 10, hWins: 6, hLosses: 4)            // 60%
        let c = entry(name: "Cara", hGames: 20, hWins: 12, hLosses: 8)          // 60%, more wins
        let d = entry(name: "Dan", hGames: 10, hWins: 6, hLosses: 4, hAvg: 300) // 60%, avg beats Bob
        let (ranked, unranked) = Leaderboard.ordered([b, d, c, a])
        #expect(unranked.isEmpty)
        #expect(ranked.map(\.displayName) == ["Alice", "Cara", "Dan", "Bob"])
    }

    /// Unranked order: closest to qualifying first.
    @Test func unrankedOrderedByProgress() {
        let near = entry(name: "Near", hGames: Leaderboard.rankingFloor - 1,
                         hWins: 0, hLosses: Leaderboard.rankingFloor - 1)
        let fresh = entry(name: "Fresh", hGames: 0, hWins: 0, hLosses: 0)
        let (ranked, unranked) = Leaderboard.ordered([fresh, near])
        #expect(ranked.isEmpty)
        #expect(unranked.map(\.displayName) == ["Near", "Fresh"])
    }

    /// Ties don't count toward win rate — only decided games do.
    @Test func winRateIgnoresTies() {
        var subset: RemoteGames.PlayerStats.Subset {
            try! JSONDecoder().decode(
                RemoteGames.PlayerStats.Subset.self,
                from: Data("{\"games\":10,\"wins\":4,\"losses\":4,\"ties\":2,\"avg_score\":200}".utf8))
        }
        #expect(Leaderboard.winRate(subset) == 0.5)
        #expect(winRateText(wins: 4, losses: 4) == "50%")
        #expect(winRateText(wins: 0, losses: 0) == "—",
                "Undefined rate must render as a dash, not 0% or a crash")
    }
}
