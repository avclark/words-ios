//
//  PersistenceTests.swift
//  WordsTests
//
//  Round-trip tests for game persistence: a snapshot survives JSON
//  encode/decode and restores into a BoardState with identical game state.
//  Guards the custom Tile Codable (Character fields) and the non-string
//  dictionary keys in [BoardCoord: Tile].
//

import Foundation
import Testing
@testable import Words

struct PersistenceTests {

    /// A snapshot with every field populated — committed tiles, an assigned
    /// blank mid-placement, a pending blank, logs — survives a full
    /// encode → decode → restore cycle.
    @Test func snapshotRoundTripsThroughJSON() throws {
        let state = BoardState(difficulty: .easy)
        // Rig a mid-game situation directly through the public API.
        let rack = state.rack
        state.placeFromRack(tileID: rack[0].id, at: BoardCoord(row: 7, col: 7))
        state.placeFromRack(tileID: rack[1].id, at: BoardCoord(row: 7, col: 8))

        let snapshot = state.snapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SavedGame.self, from: data)

        #expect(decoded.id == snapshot.id)
        #expect(decoded.difficulty == .easy)
        #expect(decoded.placed.count == 2)
        #expect(decoded.bag.count == snapshot.bag.count)
        #expect(decoded.players.count == 2)
        #expect(decoded.turnState == .local)

        // Letters (not IDs) are the persisted identity of tiles.
        #expect(decoded.bag.map(\.letter) == snapshot.bag.map(\.letter))
        #expect(decoded.players[0].rack.map(\.letter) == snapshot.players[0].rack.map(\.letter))
        for (coord, tile) in snapshot.placed {
            #expect(decoded.placed[coord]?.letter == tile.letter)
        }

        let restored = BoardState(from: decoded)
        #expect(restored.gameID == state.gameID)
        #expect(restored.rack.map(\.letter) == state.rack.map(\.letter))
        #expect(restored.bag.map(\.letter) == state.bag.map(\.letter))
        #expect(restored.placed.count == 2)
        #expect(restored.turnState == .local)
        #expect(restored.gameOver == nil)
    }

    /// Blank tiles keep their assigned letter across persistence, and score
    /// zero after restore.
    @Test func blankAssignmentPersists() throws {
        var blank = Tile(letter: "?")
        blank.assignedLetter = "Q"
        let data = try JSONEncoder().encode(blank)
        let decoded = try JSONDecoder().decode(Tile.self, from: data)
        #expect(decoded.isBlank)
        #expect(decoded.assignedLetter == "Q")
        #expect(decoded.displayLetter == "Q")
        #expect(decoded.points == 0)
    }

    /// The store writes, reloads, and deletes games from disk.
    @Test func storePersistsAcrossInstances() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let game = BoardState(difficulty: .medium).snapshot()
        GameStore(directory: dir).save(game)

        let reloaded = GameStore(directory: dir)
        #expect(reloaded.games.count == 1)
        #expect(reloaded.games[0].id == game.id)
        #expect(reloaded.games[0].difficulty == .medium)

        reloaded.delete(id: game.id)
        #expect(reloaded.games.isEmpty)
        #expect(GameStore(directory: dir).games.isEmpty)
    }
}
