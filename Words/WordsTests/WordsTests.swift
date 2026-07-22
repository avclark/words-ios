//
//  WordsTests.swift
//  WordsTests
//
//  Focused tests for the AI move generator (AIPlayer). Boards and racks are
//  rigged directly — no bag, no live game — so each scenario is deterministic.
//  Expected words/scores were verified against the bundled enable1.txt.
//

import Testing
@testable import Words

struct AIPlayerTests {

    // MARK: - Helpers

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

    /// Full legality audit of a generated move, mirroring the Phase 1 rules:
    /// no overlap with existing tiles, single contiguous line, first move
    /// covers center / later moves connect, and EVERY formed word (main +
    /// all cross-words) is in the dictionary. Also cross-checks the move's
    /// reported score against the shared MoveScorer.
    private func assertLegal(_ move: AIPlayer.Move, board: [BoardCoord: Tile]) {
        let scorer = MoveScorer(board: board)
        let placement = move.placement

        #expect(!placement.isEmpty && placement.count <= 7)
        for coord in placement.keys {
            #expect(coord.isValid, "Placed out of bounds: \(coord)")
            #expect(board[coord] == nil, "Placed on an occupied cell: \(coord)")
        }

        guard case .ok(let horizontal) = scorer.placementLine(placement) else {
            Issue.record("Placement is not a single contiguous line")
            return
        }

        if board.isEmpty {
            #expect(placement[.center] != nil, "First move must cover center")
        } else {
            let connects = placement.keys.contains { coord in
                [(0, 1), (0, -1), (1, 0), (-1, 0)].contains { dr, dc in
                    board[BoardCoord(row: coord.row + dr, col: coord.col + dc)] != nil
                }
            }
            #expect(connects, "Move doesn't connect to the existing board")
        }

        var formed: [[BoardCoord]] = []
        let main = scorer.wordThrough(placement.keys.first!, horizontal: horizontal, placement: placement)
        if main.count > 1 { formed.append(main) }
        for coord in placement.keys {
            let cross = scorer.wordThrough(coord, horizontal: !horizontal, placement: placement)
            if cross.count > 1 { formed.append(cross) }
        }
        #expect(!formed.isEmpty, "Move forms no word at all")
        for cells in formed {
            let word = scorer.string(for: cells, placement: placement)
            #expect(Lexicon.contains(word), "Formed a non-word: \(word)")
        }

        #expect(scorer.score(placement) == move.score,
                "Move's score \(move.score) disagrees with the shared scorer")
    }

    // MARK: - Blank tiles

    /// A rack containing a blank must still yield a fully legal play, and if
    /// the blank is used it must carry an assigned letter and score zero.
    @Test func blankInRackYieldsLegalPlay() {
        let b = board(word: "QUIZ", row: 7, startCol: 6)
        let move = AIPlayer.bestMove(board: b, rack: tiles("??VWKJB"))
        #expect(move != nil)
        if let move {
            assertLegal(move, board: b)
            for tile in move.placement.values where tile.isBlank {
                #expect(tile.assignedLetter != nil, "Blank played without an assigned letter")
                #expect(tile.points == 0, "Blank must score 0")
            }
        }
    }

    /// Board spells QUI; the rack is junk (VVWWKK) plus one blank. The only
    /// high play is QUICK: the blank MUST become C (17 pts with the real K) —
    /// a generator that hardcodes blanks as "A" (the old Replit bug) can't
    /// find it and would bottom out around WIZ/HO-level scraps.
    @Test func blankCompletesHighValueWord() {
        let b = board(word: "QUI", row: 7, startCol: 5)
        let move = AIPlayer.bestMove(board: b, rack: tiles("?VVWWKK"))
        #expect(move != nil)
        guard let move else { return }
        assertLegal(move, board: b)
        #expect(move.word == "QUICK")
        #expect(move.score == 17) // Q10 + U1 + I1 + blank-C 0 + K5, no premiums
        let blank = move.placement[BoardCoord(row: 7, col: 8)]
        #expect(blank?.isBlank == true, "The C in QUICK can only come from the blank")
        #expect(blank?.assignedLetter == "C")
        #expect(move.placement[BoardCoord(row: 7, col: 9)]?.letter == "K")
    }

    // MARK: - Vertical play

    /// Board spells JO horizontally; rack is S + N. Every 2-tile play here is
    /// vertical in column 8, through the O: SON or NOS for 5 (both new tiles
    /// on DL squares). All horizontal candidates are dead ends — JOS, JON,
    /// NJO, SJO, SN, NS are not words. A horizontal-only generator (the old
    /// Replit bug) can do no better than a single-tile hook, so the 2-tile
    /// column-8 assertion catches it. (Verified against enable1.txt; an
    /// earlier version of this rig used H+N and was defeated by the generator
    /// legitimately finding JOHN, which really is in ENABLE.)
    @Test func verticalOnlyBoardYieldsVerticalPlay() {
        let b = board(word: "JO", row: 7, startCol: 7)
        let move = AIPlayer.bestMove(board: b, rack: tiles("SN"))
        #expect(move != nil)
        guard let move else { return }
        assertLegal(move, board: b)
        #expect(move.placement.count == 2, "Best play uses both tiles")
        #expect(move.placement.keys.allSatisfy { $0.col == 8 }, "Play must be vertical in column 8")
        #expect(["SON", "NOS"].contains(move.word))
        #expect(move.score == 5)
    }

    // MARK: - Cross-word validity

    /// Board spells XU across the top edge; rack is J, O, S. The tempting
    /// play is JO parallel underneath at (1,6)-(1,7): "JO" is a valid main
    /// word worth 9, but it forms the invalid cross-words XJ and UO and must
    /// be rejected. Every other J placement is dead too. The best LEGAL play
    /// is the modest SO at (1,7)-(1,8) for 4 (main SO + valid cross US) —
    /// scoring less than half the illegal JO. A generator that skips
    /// cross-word validation returns JO here; the correct one returns SO.
    /// (All word/non-word assumptions verified against enable1.txt: jo, so,
    /// us, os are words; xj, uo, xo, xs, jos, xus, uj, usо are not.)
    @Test func invalidCrossWordIsRejected() {
        var b: [BoardCoord: Tile] = [:]
        b[BoardCoord(row: 0, col: 6)] = Tile(letter: "X")
        b[BoardCoord(row: 0, col: 7)] = Tile(letter: "U")
        let move = AIPlayer.bestMove(board: b, rack: tiles("JOS"))
        #expect(move != nil)
        guard let move else { return }
        assertLegal(move, board: b)
        #expect(move.word == "SO")
        #expect(move.score == 4) // SO (1+1) + cross US (1+1), no premiums
        #expect(move.placement[BoardCoord(row: 1, col: 7)]?.letter == "S")
        #expect(move.placement[BoardCoord(row: 1, col: 8)]?.letter == "O")
        // The trap cell: J under the X would only ever appear in the illegal
        // JO play. It must never be used.
        #expect(move.placement[BoardCoord(row: 1, col: 6)] == nil)
        #expect(move.placement.values.allSatisfy { $0.letter != "J" })
    }

    // MARK: - General legality

    /// Opening move on an empty board must cover center and be legal.
    @Test func openingMoveCoversCenterAndIsLegal() {
        let move = AIPlayer.bestMove(board: [:], rack: tiles("RETAINS"))
        #expect(move != nil)
        if let move { assertLegal(move, board: [:]) }
    }

    /// A busy-rack move on a normal board passes the full legality audit
    /// (no overlap, connected, contiguous, dictionary-valid crosses).
    @Test func movesOnExistingBoardAreLegal() {
        let b = board(word: "HELLO", row: 7, startCol: 5)
        let move = AIPlayer.bestMove(board: b, rack: tiles("TEAWQXZ"))
        #expect(move != nil)
        if let move { assertLegal(move, board: b) }
    }

    /// Seven Q's against HELLO: no legal play exists (no I anywhere for QI),
    /// so the generator must return nil rather than an illegal move.
    @Test func unplayableRackReturnsNil() {
        let b = board(word: "HELLO", row: 7, startCol: 5)
        let move = AIPlayer.bestMove(board: b, rack: tiles("QQQQQQQ"))
        if let move { assertLegal(move, board: b) } else { #expect(move == nil) }
    }
}
