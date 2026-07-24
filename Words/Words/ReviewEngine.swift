import SwiftUI
import Observation
import os

/// Diagnostics for the blank-review-sheet investigation (same signature
/// as the chat-sheet Heisenbug, but reproducible). Mirrors the "chat"
/// category breadcrumbs so the discrimination matrix applies directly:
/// tap → sheet-closure eval → BODY eval → onAppear/.task → phase
/// transitions, with ObjectIdentifiers to catch identity churn.
let reviewLog = Logger(subsystem: "com.kittyrobotics.Words.Words", category: "review")

/// Post-game review (Phase 12): for each of MY turns, what I played vs the
/// best play the generator finds for the rack I actually held, against the
/// board as it stood that turn. Free and generous by design — this is the
/// feature Scrabble GO paywalls.
///
/// Everything is computed ON DEMAND from fetch_review (move history + my
/// rack snapshots) and cached locally as JSON; nothing derived is ever
/// stored server-side. Computation runs turn-by-turn off the main thread,
/// appending each result as it lands — the UI always shows progress,
/// never a frozen screen.
@MainActor
@Observable
final class ReviewEngine {

    /// One of my turns, fully analyzed.
    struct TurnReview: Identifiable, Codable {
        var id: Int { moveNumber }
        let moveNumber: Int
        /// 1-based among MY turns ("Turn 3" = my third move).
        let turnLabel: Int
        let kind: String            // play | pass | swap | resign
        let playedWord: String?
        let playedScore: Int
        /// Board as it stood when this turn started.
        let boardBefore: [BoardCoord: Tile]
        let playedPlacement: [BoardCoord: Tile]?
        /// Rack letters held ("?" = blank), for display.
        let rack: [String]
        let bestWord: String?
        let bestScore: Int
        let bestPlacement: [BoardCoord: Tile]?
        /// True for moves older than the rack-history migration: the rack
        /// wasn't recorded, so "best play" can't be computed for them.
        let rackUnknown: Bool

        var missed: Int { max(0, bestScore - playedScore) }
        /// The generous framing: a play within a whisker of optimal IS the
        /// best play as far as celebration goes.
        var foundBest: Bool { !rackUnknown && kind == "play" && missed == 0 }
    }

    enum Phase: Equatable {
        case idle
        case loading
        /// done/total over MY turns; results append live as they finish.
        case computing(done: Int, total: Int)
        case done
        case failed(String)
    }

    let gameID: UUID
    private(set) var phase: Phase = .idle
    private(set) var turns: [TurnReview] = []

    init(gameID: UUID) {
        self.gameID = gameID
        reviewLog.notice("ReviewEngine INIT \(String(describing: ObjectIdentifier(self)), privacy: .public) game=\(gameID.uuidString.prefix(8), privacy: .public)")
    }

    /// Single choke point for phase changes so every transition leaves a
    /// breadcrumb tied to this instance.
    private func transition(to new: Phase) {
        phase = new
        reviewLog.notice("phase -> \(String(describing: new), privacy: .public) engine=\(String(describing: ObjectIdentifier(self)), privacy: .public) turns=\(self.turns.count)")
    }

    // MARK: - Summary (recomputed live as turns land)

    var playTurns: [TurnReview] { turns.filter { $0.kind == "play" } }
    var analyzedTurns: [TurnReview] { turns.filter { !$0.rackUnknown } }

    var bestPlay: TurnReview? {
        playTurns.max { $0.playedScore < $1.playedScore }
    }
    var biggestMiss: TurnReview? {
        analyzedTurns.filter { $0.missed > 0 }.max { $0.missed < $1.missed }
    }
    /// Total points left on the table across analyzed turns.
    var pointsLeft: Int { analyzedTurns.reduce(0) { $0 + $1.missed } }
    var averagePerTurn: Int {
        guard !turns.isEmpty else { return 0 }
        return turns.reduce(0) { $0 + $1.playedScore } / turns.count
    }
    var turnsWithRackUnknown: Int { turns.filter(\.rackUnknown).count }

    // MARK: - Run

    /// Fetch, reconstruct, and analyze. Safe to call repeatedly — a cached
    /// or completed review returns immediately. A finished game's review
    /// never changes, so the disk cache never expires.
    func run() async {
        reviewLog.notice("run() start phase=\(String(describing: self.phase), privacy: .public) engine=\(String(describing: ObjectIdentifier(self)), privacy: .public)")
        guard phase == .idle || isFailed else { return }
        if let cached = Self.loadCache(gameID: gameID) {
            reviewLog.notice("run() cache hit turns=\(cached.count)")
            turns = cached
            transition(to: .done)
            return
        }
        transition(to: .loading)
        AIPlayer.warmUp()

        let data: RemoteGames.ReviewData
        do {
            data = try await RemoteGames.fetchReview(gameID: gameID)
            reviewLog.notice("run() fetch ok moves=\(data.moves.count)")
        } catch {
            reviewLog.notice("run() fetch FAILED \(String(describing: error), privacy: .public)")
            transition(to: .failed("Couldn't load the game's moves — check your connection and try again."))
            return
        }

        let ordered = data.moves.sorted { $0.moveNumber < $1.moveNumber }
        let myTotal = ordered.filter { $0.seat == data.mySeat }.count
        guard myTotal > 0 else {
            transition(to: .done)
            return
        }
        transition(to: .computing(done: 0, total: myTotal))

        var board: [BoardCoord: Tile] = [:]
        var myTurnCount = 0
        for move in ordered {
            if move.seat == data.mySeat {
                myTurnCount += 1
                let review = await analyze(move, boardBefore: board,
                                           turnLabel: myTurnCount)
                turns.append(review)
                transition(to: .computing(done: myTurnCount, total: myTotal))
            }
            // Everyone's plays build the board forward.
            if move.kind == "play", let placements = move.placements {
                for p in placements {
                    board[BoardCoord(row: p.row, col: p.col)] = Self.tile(from: p)
                }
            }
        }
        transition(to: .done)
        Self.saveCache(gameID: gameID, turns: turns)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func analyze(_ move: RemoteGames.ReviewMoveDTO,
                         boardBefore: [BoardCoord: Tile],
                         turnLabel: Int) async -> TurnReview {
        var playedPlacement: [BoardCoord: Tile]?
        if move.kind == "play", let placements = move.placements {
            var placement: [BoardCoord: Tile] = [:]
            for p in placements {
                placement[BoardCoord(row: p.row, col: p.col)] = Self.tile(from: p)
            }
            playedPlacement = placement
        }

        let rackLetters = move.rackBefore ?? []
        var best: AIPlayer.Move?
        if !rackLetters.isEmpty {
            let rack = RemoteGames.tiles(fromRack: rackLetters)
            let board = boardBefore
            // bestMove is a pure function of snapshots — off-main it goes.
            // The first call may also pay the one-time trie build; the
            // progress UI covers that.
            best = await Task.detached(priority: .userInitiated) {
                AIPlayer.bestMove(board: board, rack: rack)
            }.value
        }

        return TurnReview(moveNumber: move.moveNumber,
                          turnLabel: turnLabel,
                          kind: move.kind,
                          playedWord: move.word,
                          playedScore: move.clientScore ?? 0,
                          boardBefore: boardBefore,
                          playedPlacement: playedPlacement,
                          rack: rackLetters,
                          bestWord: best?.word,
                          bestScore: best?.score ?? 0,
                          bestPlacement: best?.placement,
                          rackUnknown: rackLetters.isEmpty)
    }

    private static func tile(from p: RemoteGames.Placement) -> Tile {
        guard let letter = p.letter.first else { return Tile(letter: "?") }
        if p.blank {
            var t = Tile(letter: "?")
            t.assignedLetter = letter
            return t
        }
        return Tile(letter: letter)
    }

    // MARK: - Local cache (never server-side)

    private struct CacheFile: Codable {
        let version: Int
        let turns: [TurnReview]
    }
    private static let cacheVersion = 1

    private static func cacheURL(gameID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Reviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(gameID.uuidString).json")
    }

    private static func loadCache(gameID: UUID) -> [TurnReview]? {
        guard let data = try? Data(contentsOf: cacheURL(gameID: gameID)),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              file.version == cacheVersion else { return nil }
        return file.turns
    }

    private static func saveCache(gameID: UUID, turns: [TurnReview]) {
        let file = CacheFile(version: cacheVersion, turns: turns)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: cacheURL(gameID: gameID), options: .atomic)
        }
    }
}
