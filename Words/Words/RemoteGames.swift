import Foundation
import Supabase

/// Server API for games (Phase 7). Everything goes through the SECURITY
/// DEFINER RPCs in supabase/phase7_games.sql — the client never reads game
/// tables directly, never sees the bag (count only), and never sees a human
/// opponent's rack. AI seats' racks are returned because the client runs
/// the AI engine for now.
///
/// Moves are submitted as INTENT (placements), never as scored results.
/// The client's score rides along as `client_score` for display/history,
/// explicitly untrusted; server-side validation and scoring can land later
/// with no change to this API.
enum RemoteGames {

    // MARK: - Wire types

    struct Placement: Codable {
        let row: Int
        let col: Int
        /// Display letter — for a blank, the assigned letter with blank=true.
        let letter: String
        let blank: Bool
    }

    struct BoardCell: Codable {
        let letter: String
        let blank: Bool
    }

    struct PlayerDTO: Decodable {
        let seat: Int
        let userID: UUID?
        let engine: String
        let aiDifficulty: String?
        let score: Int
        let displayName: String?
        let avatar: String?
        let rack: [String]?

        enum CodingKeys: String, CodingKey {
            case seat, engine, score, avatar, rack
            case userID = "user_id"
            case aiDifficulty = "ai_difficulty"
            case displayName = "display_name"
        }
    }

    struct MoveDTO: Decodable {
        let seat: Int
        let moveNumber: Int
        let kind: String
        let word: String?
        let clientScore: Int?

        enum CodingKeys: String, CodingKey {
            case seat, kind, word
            case moveNumber = "move_number"
            case clientScore = "client_score"
        }
    }

    /// Full game state (fetch_game) or lobby summary (fetch_lobby — the
    /// per-game fields absent there are optional here).
    struct GameDTO: Decodable {
        let gameID: UUID
        let status: String
        let turnSeat: Int
        let board: [String: BoardCell]?
        let turnNumber: Int?
        let consecutivePasses: Int?
        let endReason: String?
        let winnerSeat: Int?
        let bagCount: Int?
        let updatedAt: String?
        let players: [PlayerDTO]
        let moves: [MoveDTO]?
        let importLog: [String]?

        enum CodingKeys: String, CodingKey {
            case status, board, players, moves
            case gameID = "game_id"
            case turnSeat = "turn_seat"
            case turnNumber = "turn_number"
            case consecutivePasses = "consecutive_passes"
            case endReason = "end_reason"
            case winnerSeat = "winner_seat"
            case bagCount = "bag_count"
            case updatedAt = "updated_at"
            case importLog = "import_log"
        }

        var updatedDate: Date? { RemoteGames.parseTimestamp(updatedAt) }
    }

    struct CreateResult: Decodable {
        let gameID: UUID
        let myRack: [String]
        let aiRack: [String]
        let bagCount: Int

        enum CodingKeys: String, CodingKey {
            case gameID = "game_id"
            case myRack = "my_rack"
            case aiRack = "ai_rack"
            case bagCount = "bag_count"
        }
    }

    struct MoveResult: Decodable {
        let drawn: [String]
        let bagCount: Int
        let turnNumber: Int

        enum CodingKeys: String, CodingKey {
            case drawn
            case bagCount = "bag_count"
            case turnNumber = "turn_number"
        }
    }

    struct SubmitParams: Encodable {
        let p_game_id: UUID
        let p_seat: Int
        let p_kind: String
        let p_placements: [Placement]?
        let p_word: String?
        let p_client_score: Int?
        let p_swap_letters: [String]?
    }

    // MARK: - Calls

    static func create(difficulty: AIDifficulty) async throws -> CreateResult {
        struct P: Encodable { let p_ai_difficulty: String }
        return try await SupabaseService.client
            .rpc("create_game", params: P(p_ai_difficulty: difficulty.rawValue))
            .execute().value
    }

    static func submit(_ params: SubmitParams) async throws -> MoveResult {
        try await SupabaseService.client
            .rpc("submit_move", params: params)
            .execute().value
    }

    static func finish(gameID: UUID, reason: String, localFinal: Int,
                       opponentFinal: Int, winnerSeat: Int?) async throws {
        struct P: Encodable {
            let p_game_id: UUID
            let p_end_reason: String
            let p_scores: [String: Int]
            let p_winner_seat: Int?
        }
        _ = try await SupabaseService.client
            .rpc("finish_game", params: P(
                p_game_id: gameID,
                p_end_reason: reason,
                p_scores: ["0": localFinal, "1": opponentFinal],
                p_winner_seat: winnerSeat))
            .execute()
    }

    static func fetchLobby() async throws -> [GameDTO] {
        try await SupabaseService.client
            .rpc("fetch_lobby")
            .execute().value
    }

    static func fetchGame(id: UUID) async throws -> GameDTO {
        struct P: Encodable { let p_game_id: UUID }
        return try await SupabaseService.client
            .rpc("fetch_game", params: P(p_game_id: id))
            .execute().value
    }

    /// One-time migration of a pre-Phase-7 local game. Idempotent by id.
    static func importGame(_ saved: SavedGame) async throws {
        struct Payload: Encodable {
            let id: UUID
            let status: String
            let board: [String: BoardCell]
            let turn_seat: Int
            let turn_number: Int
            let consecutive_passes: Int
            let end_reason: String?
            let winner_seat: Int?
            let scores: [String: Int]
            let ai_difficulty: String
            let racks: [String: [String]]
            let bag: [String]
            let log: [String]
        }
        struct P: Encodable { let p: Payload }

        var board: [String: BoardCell] = [:]
        for (coord, tile) in saved.committed {
            board["\(coord.row)-\(coord.col)"] = BoardCell(
                letter: String(tile.displayLetter ?? "?"), blank: tile.isBlank)
        }
        // Tiles still tentatively placed migrate as part of the rack — the
        // server board holds committed tiles only.
        var rack0 = saved.players[0].rack.map { String($0.letter) }
        rack0.append(contentsOf: saved.placed.values.map { String($0.letter) })

        let (status, endReason, winnerSeat) = Self.serverEndState(saved)
        let payload = Payload(
            id: saved.id,
            status: status,
            board: board,
            turn_seat: saved.turnState == .local ? 0 : 1,
            turn_number: saved.turnNumber,
            consecutive_passes: saved.consecutivePasses,
            end_reason: endReason,
            winner_seat: winnerSeat,
            scores: ["0": saved.players[0].score, "1": saved.players[1].score],
            ai_difficulty: saved.difficulty.rawValue,
            racks: ["0": rack0, "1": saved.players[1].rack.map { String($0.letter) }],
            bag: saved.bag.map { String($0.letter) },
            log: saved.moveLog)
        _ = try await SupabaseService.client
            .rpc("import_local_game", params: P(p: payload))
            .execute()
    }

    private static func serverEndState(_ saved: SavedGame) -> (String, String?, Int?) {
        guard let over = saved.gameOver else { return ("active", nil, nil) }
        let reason: String
        switch over.reason {
        case .localEmptied, .opponentEmptied: reason = "emptied"
        case .sixPasses: reason = "six_passes"
        }
        let winner: Int? = over.localFinal == over.opponentFinal ? nil
            : (over.localFinal > over.opponentFinal ? 0 : 1)
        return ("finished", reason, winner)
    }

    // MARK: - Mapping helpers

    static func tiles(fromRack letters: [String]) -> [Tile] {
        letters.compactMap { $0.first.map { Tile(letter: $0) } }
    }

    static func tile(fromBoardCell cell: BoardCell) -> Tile? {
        guard let letter = cell.letter.first else { return nil }
        if cell.blank {
            var t = Tile(letter: "?")
            t.assignedLetter = letter
            return t
        }
        return Tile(letter: letter)
    }

    static func committed(fromBoard board: [String: BoardCell]) -> [BoardCoord: Tile] {
        var result: [BoardCoord: Tile] = [:]
        for (key, cell) in board {
            let parts = key.split(separator: "-")
            guard parts.count == 2, let row = Int(parts[0]), let col = Int(parts[1]),
                  let tile = tile(fromBoardCell: cell) else { continue }
            result[BoardCoord(row: row, col: col)] = tile
        }
        return result
    }

    static func placements(from placement: [BoardCoord: Tile]) -> [Placement] {
        placement.map { coord, tile in
            Placement(row: coord.row, col: coord.col,
                      letter: String(tile.displayLetter ?? "?"),
                      blank: tile.isBlank)
        }
    }

    /// Postgres timestamptz → Date, tolerant of fractional seconds.
    static func parseTimestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
