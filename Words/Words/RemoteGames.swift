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
        let expiresAt: String?
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
            case expiresAt = "expires_at"
            case importLog = "import_log"
        }

        var updatedDate: Date? { RemoteGames.parseTimestamp(updatedAt) }
        var expiresDate: Date? { RemoteGames.parseTimestamp(expiresAt) }
    }

    struct CreateResult: Decodable {
        let gameID: UUID
        let myRack: [String]
        /// Present only for AI games — human racks never leave the server.
        let aiRack: [String]?
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
        /// True when p_op_id matched an already-applied move (a replayed op
        /// from the persisted queue); `rack` then carries the seat's
        /// CURRENT rack so the client can reconcile a refill it never saw.
        let duplicate: Bool?
        let rack: [String]?

        enum CodingKeys: String, CodingKey {
            case drawn, duplicate, rack
            case bagCount = "bag_count"
            case turnNumber = "turn_number"
        }
    }

    /// Codable so pending ops survive force-quit in the on-disk journal.
    struct SubmitParams: Codable {
        let p_game_id: UUID
        let p_seat: Int
        let p_kind: String
        let p_placements: [Placement]?
        let p_word: String?
        let p_client_score: Int?
        let p_swap_letters: [String]?
        /// Idempotency key: the server applies each op id at most once.
        let p_op_id: UUID?
    }

    struct RematchResult: Decodable {
        struct Opponent: Decodable {
            let userID: UUID
            let displayName: String
            let avatar: String?

            enum CodingKeys: String, CodingKey {
                case avatar
                case userID = "user_id"
                case displayName = "display_name"
            }
        }
        let gameID: UUID
        let created: Bool
        let mySeat: Int
        let myRack: [String]
        let bagCount: Int
        let opponent: Opponent

        enum CodingKeys: String, CodingKey {
            case created, opponent
            case gameID = "game_id"
            case mySeat = "my_seat"
            case myRack = "my_rack"
            case bagCount = "bag_count"
        }
    }

    struct FriendDTO: Decodable, Identifiable, Equatable {
        let userID: UUID
        let displayName: String
        let avatar: String?
        let username: String?
        /// 'friend' | 'incoming' | 'outgoing'
        let state: String

        var id: UUID { userID }

        enum CodingKeys: String, CodingKey {
            case avatar, username, state
            case userID = "user_id"
            case displayName = "display_name"
        }
    }

    struct InviteRedemption: Decodable {
        /// The redeem_invite response's friend object carries identity only
        /// (no `state` field) — decoding it as FriendDTO fails on EVERY
        /// response, which once mislabeled all redemptions as network
        /// errors. Keep this shape matched to the RPC.
        struct Friend: Decodable {
            let userID: UUID
            let displayName: String

            enum CodingKeys: String, CodingKey {
                case userID = "user_id"
                case displayName = "display_name"
            }
        }
        let status: String   // accepted | already_friends | own_link | invalid
        let friend: Friend?
    }

    // MARK: - Calls

    /// nil opponent → AI game at `difficulty`; non-nil → human-vs-human
    /// with a friend (server enforces the friendship). `aiRack` comes back
    /// only for AI games — a human opponent's rack never leaves the server.
    static func create(difficulty: AIDifficulty, opponent: UUID? = nil) async throws -> CreateResult {
        struct P: Encodable {
            let p_ai_difficulty: String
            let p_opponent: UUID?
        }
        return try await SupabaseService.client
            .rpc("create_game", params: P(p_ai_difficulty: difficulty.rawValue,
                                          p_opponent: opponent))
            .execute().value
    }

    // MARK: - Friends & invites

    static func createInvite() async throws -> String {
        struct R: Decodable { let token: String }
        let result: R = try await SupabaseService.client
            .rpc("create_invite").execute().value
        return result.token
    }

    static func redeemInvite(token: String) async throws -> InviteRedemption {
        struct P: Encodable { let p_token: String }
        return try await SupabaseService.client
            .rpc("redeem_invite", params: P(p_token: token))
            .execute().value
    }

    static func listFriends() async throws -> [FriendDTO] {
        try await SupabaseService.client
            .rpc("list_friends").execute().value
    }

    static func sendFriendRequest(to userID: UUID) async throws -> String {
        struct P: Encodable { let p_user: UUID }
        return try await SupabaseService.client
            .rpc("send_friend_request", params: P(p_user: userID))
            .execute().value
    }

    static func respondFriendRequest(from userID: UUID, accept: Bool) async throws {
        struct P: Encodable { let p_user: UUID; let p_accept: Bool }
        _ = try await SupabaseService.client
            .rpc("respond_friend_request", params: P(p_user: userID, p_accept: accept))
            .execute()
    }

    static func removeFriend(_ userID: UUID) async throws {
        struct P: Encodable { let p_user: UUID }
        _ = try await SupabaseService.client
            .rpc("remove_friend", params: P(p_user: userID))
            .execute()
    }

    static func setUsername(_ username: String?) async throws -> String {
        struct P: Encodable { let p_username: String? }
        return try await SupabaseService.client
            .rpc("set_username", params: P(p_username: username))
            .execute().value
    }

    /// Username prefix search (profiles are readable by any signed-in user;
    /// there is deliberately no email or phone search).
    static func searchProfiles(usernamePrefix: String, excluding selfID: UUID) async throws -> [FriendDTO] {
        struct Row: Decodable {
            let id: UUID
            let display_name: String
            let avatar: String?
            let username: String?
        }
        let sanitized = usernamePrefix.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !sanitized.isEmpty else { return [] }
        let rows: [Row] = try await SupabaseService.client
            .from("profiles")
            .select("id, display_name, avatar, username")
            .ilike("username", pattern: "\(sanitized)%")
            .neq("id", value: selfID)
            .limit(10)
            .execute().value
        return rows.map {
            FriendDTO(userID: $0.id, displayName: $0.display_name,
                      avatar: $0.avatar, username: $0.username, state: "none")
        }
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

    // MARK: - Notifications (Phase 10)

    static func registerDeviceToken(_ token: String) async throws {
        struct P: Encodable { let p_token: String; let p_platform: String }
        _ = try await SupabaseService.client
            .rpc("register_device_token", params: P(p_token: token, p_platform: "ios"))
            .execute()
    }

    static func unregisterDeviceToken(_ token: String) async throws {
        struct P: Encodable { let p_token: String }
        _ = try await SupabaseService.client
            .rpc("unregister_device_token", params: P(p_token: token))
            .execute()
    }

    struct PingResult: Decodable {
        let status: String   // sent | cooldown | not_their_turn
        let retryAfterMinutes: Int?

        enum CodingKeys: String, CodingKey {
            case status
            case retryAfterMinutes = "retry_after_minutes"
        }
    }

    static func ping(gameID: UUID) async throws -> PingResult {
        struct P: Encodable { let p_game_id: UUID }
        return try await SupabaseService.client
            .rpc("ping_opponent", params: P(p_game_id: gameID))
            .execute().value
    }

    /// Per-type push preferences, honored SERVER-side at enqueue time.
    struct NotificationPrefs: Codable, Equatable {
        var userID: UUID
        var turn = true
        var newGame = true
        var gameOver = true
        var chat = true
        var expiryWarning = true
        var ping = true

        enum CodingKeys: String, CodingKey {
            case turn, chat, ping
            case userID = "user_id"
            case newGame = "new_game"
            case gameOver = "game_over"
            case expiryWarning = "expiry_warning"
        }
    }

    static func fetchNotificationPrefs(userID: UUID) async throws -> NotificationPrefs {
        let rows: [NotificationPrefs] = try await SupabaseService.client
            .from("notification_prefs")
            .select("user_id, turn, new_game, game_over, chat, expiry_warning, ping")
            .eq("user_id", value: userID)
            .execute().value
        return rows.first ?? NotificationPrefs(userID: userID)
    }

    static func saveNotificationPrefs(_ prefs: NotificationPrefs) async throws {
        _ = try await SupabaseService.client
            .from("notification_prefs")
            .upsert(prefs)
            .execute()
    }

    static func resign(gameID: UUID) async throws {
        struct P: Encodable { let p_game_id: UUID }
        _ = try await SupabaseService.client
            .rpc("resign_game", params: P(p_game_id: gameID))
            .execute()
    }

    /// Creates — or joins — THE one rematch game for a finished game.
    /// Both players tapping resolves to the same game server-side.
    static func requestRematch(gameID: UUID) async throws -> RematchResult {
        struct P: Encodable { let p_game_id: UUID }
        return try await SupabaseService.client
            .rpc("request_rematch", params: P(p_game_id: gameID))
            .execute().value
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
        case .resigned: reason = "resigned"
        case .expired: reason = "expired"  // unreachable for legacy imports
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
