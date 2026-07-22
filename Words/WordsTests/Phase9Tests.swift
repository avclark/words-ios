//
//  Phase9Tests.swift
//  WordsTests
//
//  Multiplayer robustness: the persisted op journal, resign semantics,
//  explicit-winner game overs, and idempotency keys. All network-free.
//

import Foundation
import Testing
@testable import Words

@MainActor
struct Phase9Tests {

    private func tiles(_ letters: String) -> [Tile] {
        letters.map { Tile(letter: $0) }
    }

    private func tempStore() -> GameStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Phase9Tests-\(UUID().uuidString)", isDirectory: true)
        return GameStore(directory: dir)
    }

    private func humanGame(localSeat: Int = 0) -> BoardState {
        BoardState(remoteID: UUID(),
                   myRack: tiles("CATXJQV"),
                   bagCount: 86,
                   localProfile: PlayerProfile(id: UUID(), displayName: "Me", avatar: .bolt),
                   difficulty: .hard,
                   opponentProfile: PlayerProfile(id: UUID(), displayName: "Wife", avatar: .heart),
                   opponentIsHuman: true,
                   localSeat: localSeat)
    }

    /// The journal file written by one GameSync is loaded by the next —
    /// the force-quit survival path.
    @Test func pendingOpsSurviveRelaunch() throws {
        let store = tempStore()
        let ops = [GameSync.PendingOp(
            id: UUID(), gameID: UUID(), kind: .submit,
            submit: RemoteGames.SubmitParams(
                p_game_id: UUID(), p_seat: 0, p_kind: "play",
                p_placements: [.init(row: 7, col: 7, letter: "A", blank: false)],
                p_word: "A", p_client_score: 1, p_swap_letters: nil,
                p_op_id: UUID()),
            localSeatIndex: 0, finish: nil),
        GameSync.PendingOp(
            id: UUID(), gameID: UUID(), kind: .resign,
            submit: nil, localSeatIndex: nil, finish: nil)]
        let data = try JSONEncoder().encode(ops)
        try data.write(to: store.directory.appendingPathComponent("pending-ops.json"))

        let sync = GameSync(store: store, userID: UUID())
        #expect(sync.pendingOpCount == 2, "journal must load on init")
    }

    /// A fresh GameSync with no journal file has an empty queue.
    @Test func emptyJournalLoadsClean() {
        let sync = GameSync(store: tempStore(), userID: UUID())
        #expect(sync.pendingOpCount == 0)
    }

    /// Resigning ends the game immediately with an explicit loss —
    /// regardless of who's ahead on points — and fires the sync hook once.
    @Test func resignIsAnExplicitLoss() {
        let state = humanGame()
        var resignEvents = 0
        state.onResigned = { _ in resignEvents += 1 }
        var finishEvents = 0
        state.onGameFinished = { _, _ in finishEvents += 1 }

        state.resignLocalPlayer()

        #expect(state.gameOver?.reason == .resigned)
        #expect(state.gameOver?.localWon == false)
        #expect(resignEvents == 1)
        #expect(finishEvents == 0, "resign must not also fire the finish path")

        state.resignLocalPlayer()
        #expect(resignEvents == 1, "resigning twice is a no-op")
    }

    /// AI games can't be resigned (no opponent to hand the win to yet).
    @Test func aiGamesCannotResign() {
        let state = BoardState(remoteID: UUID(), myRack: tiles("ABCDEFG"),
                               bagCount: 86,
                               localProfile: PlayerProfile(id: UUID(), displayName: "T", avatar: .bolt),
                               difficulty: .easy,
                               opponentRack: tiles("EEEEEEE"))
        state.resignLocalPlayer()
        #expect(state.gameOver == nil)
    }

    /// GameOverView-style winner resolution: explicit localWon beats score
    /// comparison, and old cache files (no localWon key) still decode.
    @Test func explicitWinnerDecodesAndOverridesScores() throws {
        let resigned = GameOverSummary(reason: .resigned, localFinal: 100,
                                       opponentFinal: 20, localLeftover: 0,
                                       opponentLeftover: 0, localWon: false)
        let data = try JSONEncoder().encode(resigned)
        let decoded = try JSONDecoder().decode(GameOverSummary.self, from: data)
        #expect(decoded.localWon == false, "score leader can still lose by resigning")

        let legacyJSON = #"{"reason":"sixPasses","localFinal":10,"opponentFinal":8,"localLeftover":0,"opponentLeftover":0}"#
        let legacy = try JSONDecoder().decode(GameOverSummary.self, from: Data(legacyJSON.utf8))
        #expect(legacy.localWon == nil, "pre-Phase-9 summaries decode with no explicit winner")
    }

    /// Every submitted op carries its idempotency key.
    @Test func submitParamsCarryOpID() {
        let opID = UUID()
        let params = GameSync.submitParams(
            gameID: UUID(), localSeat: 1,
            move: BoardState.RemoteMove(seat: 0, kind: .pass), opID: opID)
        #expect(params.p_op_id == opID)
        #expect(params.p_seat == 1)
    }

    /// Authoritative rack replacement (duplicate-op reconciliation) folds
    /// tentative placements back in rather than duplicating tiles.
    @Test func authoritativeRackReplacesAndClearsPlacement() {
        let state = humanGame()
        state.onRemoteMove = { _, _ in }
        let rack = state.rack
        state.placeFromRack(tileID: rack[0].id, at: BoardCoord(row: 7, col: 7))
        #expect(state.rack.count == 6)
        #expect(state.placed.count == 1)

        state.applyAuthoritativeRack(seat: 0, letters: tiles("ABCDEFG"), bagCount: 80)
        #expect(state.rack.count == 7)
        #expect(state.placed.isEmpty, "tentative tiles fold back into the server rack")
        #expect(state.bagRemaining == 80)
    }
}
