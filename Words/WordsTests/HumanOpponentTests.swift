//
//  HumanOpponentTests.swift
//  WordsTests
//
//  Phase 8: human-vs-human seat mapping and turn behavior. BoardState is
//  always local-perspective (players[0] = me); GameSync translates to
//  server seats. Challenge recipients occupy server seat 1, where the two
//  numberings differ.
//

import Foundation
import Testing
@testable import Words

@MainActor
struct HumanOpponentTests {

    private func tiles(_ letters: String) -> [Tile] {
        letters.map { Tile(letter: $0) }
    }

    private func humanGame(localSeat: Int = 0) -> BoardState {
        let state = BoardState(remoteID: UUID(),
                               myRack: tiles("CATXJQV"),
                               bagCount: 86,
                               localProfile: PlayerProfile(id: UUID(), displayName: "Me", avatar: .bolt),
                               difficulty: .hard,
                               opponentProfile: PlayerProfile(id: UUID(), displayName: "Wife", avatar: .heart),
                               opponentIsHuman: true)
        return state
    }

    /// A human opponent's empty local rack must NOT trigger the AI-path
    /// auto-pass: the turn simply goes to .opponent and waits for the
    /// server to show their move.
    @Test func humanOpponentTurnWaitsInsteadOfAutoPassing() {
        let state = humanGame()
        var emitted: [BoardState.RemoteMove] = []
        state.onRemoteMove = { emitted.append($1) }

        let rack = state.rack
        state.placeFromRack(tileID: rack[0].id, at: BoardCoord(row: 7, col: 6))
        state.placeFromRack(tileID: rack[1].id, at: BoardCoord(row: 7, col: 7))
        state.placeFromRack(tileID: rack[2].id, at: BoardCoord(row: 7, col: 8))
        state.playMove()

        #expect(state.turnState == .opponent, "turn hands over and waits")
        #expect(state.gameOver == nil)
        #expect(emitted.count == 1, "exactly the play intent — no phantom opponent pass")
        #expect(state.consecutivePasses == 0)
        #expect(state.moveLog.count == 1, "no 'has no tiles — passed' log entry")
    }

    /// Seat translation: a challenge recipient (server seat 1) submits
    /// their own moves as seat 1 and the opponent's as seat 0.
    @Test func submitParamsTranslateSeatsForChallengeRecipient() {
        let move = BoardState.RemoteMove(seat: 0, kind: .pass)
        #expect(GameSync.submitParams(gameID: UUID(), localSeat: 1, move: move).p_seat == 1)
        #expect(GameSync.submitParams(gameID: UUID(), localSeat: 0, move: move).p_seat == 0)
        let opponentMove = BoardState.RemoteMove(seat: 1, kind: .pass)
        #expect(GameSync.submitParams(gameID: UUID(), localSeat: 1, move: opponentMove).p_seat == 0)
        #expect(GameSync.submitParams(gameID: UUID(), localSeat: 0, move: opponentMove).p_seat == 1)
    }

    /// applyServerRefresh lands an opponent's move in place: new committed
    /// tiles appear, turn returns to local, nothing is torn down.
    @Test func serverRefreshAppliesOpponentMove() {
        let state = humanGame()
        state.onRemoteMove = { _, _ in }
        let rack = state.rack
        state.placeFromRack(tileID: rack[0].id, at: BoardCoord(row: 7, col: 6))
        state.placeFromRack(tileID: rack[1].id, at: BoardCoord(row: 7, col: 7))
        state.placeFromRack(tileID: rack[2].id, at: BoardCoord(row: 7, col: 8))
        state.playMove()
        #expect(state.turnState == .opponent)

        // Simulate the server showing the opponent's answer word.
        var snapshot = state.snapshot()
        snapshot.committed[BoardCoord(row: 8, col: 7)] = Tile(letter: "A")
        snapshot.committed[BoardCoord(row: 9, col: 7)] = Tile(letter: "N")
        snapshot.players[1].score = 12
        snapshot.turnState = .local
        snapshot.turnNumber = state.turnNumber + 1
        snapshot.bagCount = 81

        state.applyServerRefresh(from: snapshot)
        #expect(state.turnState == .local)
        #expect(state.tile(at: BoardCoord(row: 8, col: 7)) != nil)
        #expect(state.opponent.score == 12)
        #expect(state.bagRemaining == 81)
        #expect(state.turnNumber == snapshot.turnNumber)
    }

    /// A stale refresh (same turn number) must be a no-op — it would
    /// otherwise clobber optimistic local state.
    @Test func staleRefreshIsIgnored() {
        let state = humanGame()
        let before = state.snapshot()
        var stale = before
        stale.players[1].score = 999
        state.applyServerRefresh(from: stale)
        #expect(state.opponent.score == 0)
    }
}
