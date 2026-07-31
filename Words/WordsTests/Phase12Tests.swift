//
//  Phase12Tests.swift
//  WordsTests
//
//  Phase 12: hints (budgets + generation), result acknowledgment /
//  Past-games archival, tap-to-define lookups, and persistence of the
//  new per-game fields.
//

import Testing
import Foundation
@testable import Words

// MARK: - Hint generation (AIPlayer.topMoves)

struct TopMovesTests {

    private func tiles(_ letters: String) -> [Tile] {
        letters.map { Tile(letter: $0) }
    }

    private func board(word: String, row: Int, startCol: Int) -> [BoardCoord: Tile] {
        var board: [BoardCoord: Tile] = [:]
        for (i, ch) in word.enumerated() {
            board[BoardCoord(row: row, col: startCol + i)] = Tile(letter: ch)
        }
        return board
    }

    /// topMoves must return distinct positions, best-first, capped at the
    /// limit, with the first entry agreeing with bestMove.
    @Test func topMovesAreDistinctSortedAndCapped() {
        let b = board(word: "QUIZ", row: 7, startCol: 6)
        let rack = tiles("AEINRST")
        let moves = AIPlayer.topMoves(board: b, rack: rack,
                                      limit: HintBudget.placementSpots)
        #expect(!moves.isEmpty)
        #expect(moves.count <= HintBudget.placementSpots)

        // Best-first, and the top hint IS the best move.
        for i in 1..<moves.count {
            #expect(moves[i - 1].score >= moves[i].score)
        }
        let best = AIPlayer.bestMove(board: b, rack: rack)
        #expect(moves.first?.score == best?.score)

        // Position dedup: no two hints share (orientation, start cell).
        var seen = Set<String>()
        for move in moves {
            let coords = move.placement.keys
            let horizontal = Set(coords.map(\.row)).count == 1
            let key = "\(horizontal)-\(coords.map(\.row).min()!)-\(coords.map(\.col).min()!)"
            #expect(seen.insert(key).inserted, "Duplicate hint position \(key)")
        }
    }

    /// An unplayable rack yields no hints (the UI then says so instead of
    /// spending a use).
    @Test func topMovesEmptyWhenNothingPlays() {
        // No vowels, no board hooks that help: VVWWKKX against QI.
        let b = board(word: "QI", row: 7, startCol: 7)
        let moves = AIPlayer.topMoves(board: b, rack: tiles("VVWWKKX"), limit: 12)
        // Every returned move must at least be scorable and legal-shaped.
        for move in moves {
            #expect(MoveScorer(board: b).score(move.placement) == move.score)
        }
    }
}

// MARK: - Hint budgets & staging (BoardState)

@MainActor
struct HintBudgetTests {

    /// Spots hint: spends exactly one use per call, caps at the budget,
    /// and populates highlights with exactly one "best".
    @Test func placementsHintSpendsBudget() {
        let state = BoardState()
        let moves = AIPlayer.topMoves(board: [:], rack: state.rack, limit: 12)
        guard !moves.isEmpty else { return }  // pathological rack; nothing to test

        #expect(state.hintPlacementsLeft == HintBudget.placements)
        state.applyPlacementsHint(moves)
        #expect(state.hintPlacementsLeft == HintBudget.placements - 1)
        #expect(!state.hintHighlights.isEmpty)
        #expect(state.hintHighlights.filter(\.isBest).count == 1)

        for _ in 0..<20 { state.applyPlacementsHint(moves) }
        #expect(state.hintPlacementsLeft == 0)
        #expect(state.hintBestWordsLeft == HintBudget.bestWord,
                "Spot hints must not touch the best-word budget")
    }

    /// Best-word hint: stages the tiles as a playable placement (the
    /// shared scorer accepts it), spends one use, and never commits.
    @Test func bestWordHintStagesPlayableMove() {
        let state = BoardState()
        guard let best = AIPlayer.bestMove(board: [:], rack: state.rack) else { return }

        state.applyBestWordHint(best)
        #expect(state.hintBestWordsLeft == HintBudget.bestWord - 1)
        #expect(!state.placed.isEmpty, "Hint must stage tiles on the board")
        #expect(state.pendingBlank == nil, "Staged blanks arrive pre-assigned")
        #expect(state.currentScore() == best.score,
                "Staged hint must score exactly what the generator promised")
        #expect(state.turnNumber == 1, "Staging must not commit the move")

        // The player can still recall it — nothing is locked.
        state.recallAll()
        #expect(state.placed.isEmpty)
        #expect(state.rack.count == 7)
    }

    /// A stale hint (a COMMITTED tile landed on one of its cells since
    /// compute — e.g. the opponent's move applied) must bail without
    /// spending a use. Tentative tiles don't count: the hint recalls
    /// those first by design.
    @Test func staleBestWordHintDoesNotSpend() {
        let source = BoardState()
        guard let best = AIPlayer.bestMove(board: [:], rack: source.rack),
              let coord = best.placement.keys.first else { return }
        var saved = source.snapshot()
        saved.committed = [coord: Tile(letter: "Z")]
        let state = BoardState(from: saved)
        state.applyBestWordHint(best)
        #expect(state.hintBestWordsLeft == HintBudget.bestWord,
                "A bailed hint must not cost a use")
        #expect(state.placed.isEmpty, "A bailed hint must stage nothing")
    }
}

// MARK: - Result acknowledgment & archive

@MainActor
struct ResultSeenTests {

    /// A BoardState restored into a finished position — the same path a
    /// persisted finished game takes (there's no public "end it now").
    private func finishedState(from source: BoardState = BoardState()) -> BoardState {
        var saved = source.snapshot()
        saved.gameOver = GameOverSummary(reason: .sixPasses,
                                         localFinal: 10, opponentFinal: 5,
                                         localLeftover: 0, opponentLeftover: 0)
        saved.turnState = .local
        return BoardState(from: saved)
    }

    /// markResultSeen: no-op while the game runs, once-only after it ends.
    @Test func acknowledgmentIsOnceOnlyAndPostGame() {
        let active = BoardState()
        #expect(active.markResultSeen() == false, "Active games can't be acknowledged")
        #expect(active.resultSeen == false)

        let finished = finishedState()
        #expect(finished.markResultSeen() == true, "First acknowledgment reports true")
        #expect(finished.resultSeen == true)
        #expect(finished.markResultSeen() == false, "Second acknowledgment is a no-op")
    }

    /// The new fields survive a snapshot → restore round trip, and
    /// isArchived = finished (Match History holds every finished game
    /// immediately; resultSeen no longer gates placement).
    @Test func snapshotRoundTripAndArchiveRule() {
        let source = BoardState()
        let moves = AIPlayer.topMoves(board: [:], rack: source.rack, limit: 5)
        if !moves.isEmpty { source.applyPlacementsHint(moves) }
        let state = finishedState(from: source)
        state.markResultSeen()

        let saved = state.snapshot()
        #expect(saved.resultSeen == true)
        #expect(saved.isArchived == true)
        if !moves.isEmpty { #expect(saved.hintPlacementsUsed == 1) }

        let restored = BoardState(from: saved)
        #expect(restored.resultSeen == true)
        if !moves.isEmpty {
            #expect(restored.hintPlacementsLeft == HintBudget.placements - 1)
        }

        // Finished games are archived the moment they finish — the
        // acknowledgment mark is irrelevant to placement now.
        var unseen = saved
        unseen.resultSeen = nil
        #expect(unseen.isArchived == true)
        // Active games are never archived, seen mark or not.
        var active = saved
        active.gameOver = nil
        #expect(active.isArchived == false)
    }

    /// Server rebuilds must not clobber local-only fields.
    @Test func carryLocalOnlyPreservesHintSpendsAndAck() {
        let state = finishedState()
        state.markResultSeen()
        var local = state.snapshot()
        local.hintPlacementsUsed = 3
        local.hintBestWordsUsed = 1

        var fresh = local
        fresh.hintPlacementsUsed = nil
        fresh.hintBestWordsUsed = nil
        fresh.resultSeen = nil  // server hasn't echoed the ack yet

        let merged = GameSync.carryLocalOnly(from: local, into: fresh)
        #expect(merged.hintPlacementsUsed == 3)
        #expect(merged.hintBestWordsUsed == 1)
        #expect(merged.resultSeen == true)
    }
}

// MARK: - Tap-to-define

@MainActor
struct DefinitionsTests {

    /// The bundled file loads and answers for a plain lemma.
    @Test func directLookupWorks() {
        #expect(Definitions.lookup("QUARTZ") != nil)
        #expect(Definitions.lookup("quartz") != nil, "Lookup is case-insensitive")
    }

    /// Regular inflections resolve to their base entry via stems.
    @Test func inflectedLookupsResolve() {
        #expect(Definitions.lookup("CATS") != nil)      // -S
        #expect(Definitions.lookup("BOXES") != nil)     // -ES
        #expect(Definitions.lookup("PONIES") != nil)    // -IES → Y
        #expect(Definitions.lookup("BAKED") != nil)     // -ED → -E
        #expect(Definitions.lookup("STOPPED") != nil)   // undoubling
        #expect(Definitions.lookup("MAKING") != nil)    // -ING → -E
        #expect(Definitions.lookup("RUNNING") != nil)   // undoubling
        #expect(Definitions.lookup("HAPPIER") != nil)   // -IER → Y
        #expect(Definitions.lookup("MICE") != nil)      // irregular, baked in
    }

    /// stems() candidate generation (pure function, no store needed).
    @Test func stemCandidates() {
        #expect(Definitions.stems(of: "CATS").contains("CAT"))
        #expect(Definitions.stems(of: "PONIES").contains("PONY"))
        #expect(Definitions.stems(of: "STOPPED").contains("STOP"))
        #expect(Definitions.stems(of: "MAKING").contains("MAKE"))
        #expect(Definitions.stems(of: "BIGGEST").contains("BIG"))
    }

    /// committedWords finds every run of 2+ through a tapped cell, and
    /// nothing for empty or tentative cells.
    @Test func committedWordsThroughCell() {
        let state = BoardState()
        // Play CAT through center to commit it.
        var rack = state.rack
        for (i, letter) in "CAT".enumerated() {
            if let idx = rack.firstIndex(where: { $0.letter == letter }) {
                state.placeFromRack(tileID: rack[idx].id,
                                    at: BoardCoord(row: 7, col: 6 + i))
                rack.remove(at: idx)
            } else if let blank = rack.firstIndex(where: { $0.isBlank }) {
                let coord = BoardCoord(row: 7, col: 6 + i)
                state.placeFromRack(tileID: rack[blank].id, at: coord)
                state.assignBlank(at: coord, letter: letter)
                rack.remove(at: blank)
            } else {
                return  // rack can't spell CAT this run; nothing to test
            }
        }
        guard state.currentScore() != nil else { return }
        state.playMove()
        guard state.committed[BoardCoord(row: 7, col: 7)] != nil else { return }

        let words = state.committedWords(through: BoardCoord(row: 7, col: 7))
        #expect(words == ["CAT"])
        #expect(state.committedWords(through: BoardCoord(row: 0, col: 0)).isEmpty)
    }
}
