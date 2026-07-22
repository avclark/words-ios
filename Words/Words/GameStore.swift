import Foundation
import Observation

/// A complete, serializable game — everything BoardState needs to resume
/// exactly where the game left off, not a UI snapshot. This is the record
/// that later syncs with a server for async multiplayer, so it must always
/// stay self-contained (board, both racks, scores, bag, turn, passes, log).
struct SavedGame: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var difficulty: AIDifficulty

    var committed: [BoardCoord: Tile]
    /// Tiles tentatively placed this turn — preserved so quitting mid-move
    /// restores the placement instead of silently recalling it.
    var placed: [BoardCoord: Tile]
    var pendingBlank: BoardCoord?
    var bag: [Tile]
    var players: [Player]
    var turnState: TurnState
    var turnNumber: Int
    var consecutivePasses: Int
    var moveLog: [String]
    var gameOver: GameOverSummary?

    var localPlayer: Player { players[0] }
    var opponentPlayer: Player { players[1] }

    /// Lobby bucket, in display order: playable games first.
    enum LobbyPhase: Int, Comparable {
        case yourTurn = 0, waiting = 1, finished = 2
        static func < (a: LobbyPhase, b: LobbyPhase) -> Bool { a.rawValue < b.rawValue }
    }

    var phase: LobbyPhase {
        if gameOver != nil { return .finished }
        return turnState == .local ? .yourTurn : .waiting
    }
}

/// File-per-game store under Application Support. Loads everything at
/// launch (a handful of small JSON files), then keeps the in-memory list
/// and the files in sync on every save/delete.
@Observable
final class GameStore {
    private(set) var games: [SavedGame] = []
    private let directory: URL

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        self.directory = directory ?? base.appendingPathComponent("Games", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory,
                                                 withIntermediateDirectories: true)
        loadAll()
    }

    /// Lobby order: your-turn games first, then waiting, then finished;
    /// most recently touched first within each bucket.
    var lobbyOrder: [SavedGame] {
        games.sorted { a, b in
            a.phase != b.phase ? a.phase < b.phase : a.updatedAt > b.updatedAt
        }
    }

    func save(_ game: SavedGame) {
        do {
            let data = try JSONEncoder().encode(game)
            try data.write(to: fileURL(for: game.id), options: .atomic)
        } catch {
            assertionFailure("Failed to persist game \(game.id): \(error)")
        }
        if let idx = games.firstIndex(where: { $0.id == game.id }) {
            games[idx] = game
        } else {
            games.append(game)
        }
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
        games.removeAll { $0.id == id }
    }

    private func loadAll() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        // A file that no longer decodes (corrupt, or an old schema) is
        // skipped rather than crashing the lobby; the game it held is lost.
        games = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(SavedGame.self, from: data)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
