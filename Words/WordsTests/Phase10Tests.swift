//
//  Phase10Tests.swift
//  WordsTests
//
//  Push notification client logic that's testable without APNs: payload
//  routing, badge computation, and prefs coding against the server shape.
//

import Foundation
import Testing
@testable import Words

struct Phase10Tests {

    /// Notification payloads route by their game_id string.
    @Test func payloadGameIDParses() {
        let id = UUID()
        #expect(NotificationsController.gameID(
            fromUserInfo: ["game_id": id.uuidString, "type": "turn"]) == id)
        #expect(NotificationsController.gameID(fromUserInfo: [:]) == nil)
        #expect(NotificationsController.gameID(
            fromUserInfo: ["game_id": "not-a-uuid"]) == nil)
    }

    /// Badge counts only human games awaiting the local player's move.
    @Test func badgeCountsHumanGamesAwaitingMe() {
        func game(turn: TurnState, human: Bool, over: Bool) -> SavedGame {
            var snapshot = BoardState().snapshot()
            snapshot.turnState = turn
            snapshot.opponentIsHuman = human
            if over {
                snapshot.gameOver = GameOverSummary(
                    reason: .sixPasses, localFinal: 0, opponentFinal: 0,
                    localLeftover: 0, opponentLeftover: 0)
            }
            return snapshot
        }
        let games = [
            game(turn: .local, human: true, over: false),    // counts
            game(turn: .local, human: true, over: false),    // counts
            game(turn: .opponent, human: true, over: false), // their turn
            game(turn: .local, human: false, over: false),   // solo AI
            game(turn: .local, human: true, over: true),     // finished
        ]
        #expect(NotificationsController.awaitingMoveCount(in: games) == 2)
    }

    /// Prefs round-trip the exact server column names.
    @Test func prefsCodingMatchesServerColumns() throws {
        var prefs = RemoteGames.NotificationPrefs(userID: UUID())
        prefs.turn = false
        prefs.expiryWarning = false
        let data = try JSONEncoder().encode(prefs)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["turn"] as? Bool == false)
        #expect(json?["expiry_warning"] as? Bool == false)
        #expect(json?["new_game"] as? Bool == true)
        #expect(json?["user_id"] != nil)

        let decoded = try JSONDecoder().decode(RemoteGames.NotificationPrefs.self, from: data)
        #expect(decoded == prefs)
    }
}
