//
//  RemoteModeTests.swift
//  WordsTests
//
//  Phase 7: remote-mode BoardState behavior — no local draws, moves
//  reported as intent events, server refills applied on arrival — plus
//  cache-format compatibility for pre-Phase-7 saves.
//

import Foundation
import Testing
@testable import Words

struct RemoteModeTests {

    private func tiles(_ letters: String) -> [Tile] {
        letters.map { Tile(letter: $0) }
    }

    /// Remote game: playing a word must not draw locally, must emit a play
    /// intent for the right seat, and the server's refill lands via
    /// applyServerDraw.
    @Test func remotePlayEmitsIntentAndWaitsForServerDraw() {
        let state = BoardState(remoteID: UUID(),
                               myRack: tiles("CATXJQV"),
                               bagCount: 86,
                               localProfile: PlayerProfile(id: UUID(), displayName: "T", avatar: .bolt),
                               difficulty: .hard,
                               opponentRack: tiles("EEEEEEE"))
        var reported: BoardState.RemoteMove?
        state.onRemoteMove = { _, move in
            if reported == nil { reported = move }  // AI answers async; first event is ours
        }

        let rack = state.rack
        state.placeFromRack(tileID: rack[0].id, at: BoardCoord(row: 7, col: 6))  // C
        state.placeFromRack(tileID: rack[1].id, at: BoardCoord(row: 7, col: 7))  // A
        state.placeFromRack(tileID: rack[2].id, at: BoardCoord(row: 7, col: 8))  // T
        state.playMove()

        #expect(state.gameOver == nil)
        #expect(state.rack.count == 4, "remote mode must not draw locally")
        #expect(state.bagRemaining == 86, "bag count only changes on server response")

        guard case .play(let placements, let word, let score)? = reported?.kind else {
            Issue.record("expected a play intent, got \(String(describing: reported))")
            return
        }
        #expect(reported?.seat == 0)
        #expect(word == "CAT")
        #expect(placements.count == 3)
        #expect(score > 0)

        state.applyServerDraw(seat: 0, letters: tiles("AAA"), bagCount: 83)
        #expect(state.rack.count == 7)
        #expect(state.bagRemaining == 83)
    }

    /// A remote swap sends the discarded letters and leaves the refill to
    /// the server; the local bag is never touched.
    @Test func remoteSwapEmitsIntent() {
        let state = BoardState(remoteID: UUID(),
                               myRack: tiles("ABCDEFG"),
                               bagCount: 86,
                               localProfile: PlayerProfile(id: UUID(), displayName: "T", avatar: .bolt),
                               difficulty: .hard,
                               opponentRack: tiles("EEEEEEE"))
        var reported: BoardState.RemoteMove?
        state.onRemoteMove = { _, move in
            if reported == nil { reported = move }
        }

        let ids = Set(state.rack.prefix(2).map(\.id))
        state.swapTiles(ids: ids)

        #expect(state.rack.count == 5)
        #expect(state.bagRemaining == 86)
        guard case .swap(let discarded)? = reported?.kind else {
            Issue.record("expected a swap intent")
            return
        }
        #expect(discarded.count == 2)
    }

    /// Pre-Phase-7 cache files (no bagCount key) still decode, land in
    /// local mode, and keep their bag.
    @Test func legacySaveDecodesAsLocalGame() throws {
        let legacy = BoardState().snapshot()  // local game: bagCount nil
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(SavedGame.self, from: data)
        #expect(decoded.bagCount == nil)

        let restored = BoardState(from: decoded)
        #expect(!restored.isRemote)
        #expect(restored.bagRemaining == decoded.bag.count)
    }

    /// Remote snapshots round-trip the server bag count with an empty bag.
    @Test func remoteSaveRoundTripsBagCount() throws {
        let state = BoardState(remoteID: UUID(),
                               myRack: tiles("ABCDEFG"),
                               bagCount: 42,
                               localProfile: PlayerProfile(id: UUID(), displayName: "T", avatar: .bolt),
                               difficulty: .easy,
                               opponentRack: tiles("EEEEEEE"))
        let data = try JSONEncoder().encode(state.snapshot())
        let decoded = try JSONDecoder().decode(SavedGame.self, from: data)
        #expect(decoded.bagCount == 42)
        #expect(decoded.bag.isEmpty)

        let restored = BoardState(from: decoded)
        #expect(restored.isRemote)
        #expect(restored.bagRemaining == 42)
        #expect(restored.rack.count == 7)
    }
}
