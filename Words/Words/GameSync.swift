import Foundation
import Observation
import Supabase

/// Background sync between live games / the local cache and the server
/// (Phase 7). Optimistic by design: BoardState applies every move locally
/// and reports it here afterwards — the board never waits on the network.
/// Ops are strictly FIFO per game (a human move must land before the AI
/// move that answered it). A server rejection rolls the local game back to
/// server truth and surfaces an explanation for RootView to present.
@MainActor
@Observable
final class GameSync {

    struct Rejection: Identifiable, Equatable {
        let id = UUID()
        let gameID: UUID
        let message: String
    }

    /// Set when the server refused an op and the cache was rolled back to
    /// server state. RootView presents it and reloads the live game.
    var rejection: Rejection?

    private let store: GameStore
    private let userID: UUID
    /// Tail of the op chain per game — each new op awaits the previous one.
    private var chains: [UUID: Task<Void, Never>] = [:]

    init(store: GameStore, userID: UUID) {
        self.store = store
        self.userID = userID
    }

    // MARK: - Wiring

    /// Hook a live game's turn events into the sync queue.
    func attach(_ board: BoardState) {
        guard board.isRemote else { return }
        board.onRemoteMove = { [weak self] state, move in
            self?.enqueueMove(move, from: state)
        }
        board.onGameFinished = { [weak self] state, summary in
            self?.enqueueFinish(gameID: state.gameID, summary: summary)
        }
    }

    // MARK: - Game creation

    /// New games are born on the server (it owns the bag and the racks);
    /// requires connectivity by design.
    func createGame(difficulty: AIDifficulty, profile: PlayerProfile) async throws -> BoardState {
        let created = try await RemoteGames.create(difficulty: difficulty)
        return BoardState(remoteID: created.gameID,
                          myRack: RemoteGames.tiles(fromRack: created.myRack),
                          aiRack: RemoteGames.tiles(fromRack: created.aiRack),
                          bagCount: created.bagCount,
                          localProfile: profile,
                          difficulty: difficulty)
    }

    // MARK: - Move pipeline

    private func enqueueMove(_ move: BoardState.RemoteMove, from board: BoardState) {
        let gameID = board.gameID
        let params = Self.submitParams(gameID: gameID, move: move)
        enqueue(gameID: gameID) { [weak self, weak board] in
            await self?.submit(params: params, seat: move.seat, gameID: gameID, board: board)
        }
    }

    private func enqueueFinish(gameID: UUID, summary: GameOverSummary) {
        let reason: String
        switch summary.reason {
        case .localEmptied, .opponentEmptied: reason = "emptied"
        case .sixPasses: reason = "six_passes"
        }
        let winner: Int? = summary.localFinal == summary.opponentFinal ? nil
            : (summary.localFinal > summary.opponentFinal ? 0 : 1)
        enqueue(gameID: gameID) {
            try? await RemoteGames.finish(gameID: gameID, reason: reason,
                                          localFinal: summary.localFinal,
                                          opponentFinal: summary.opponentFinal,
                                          winnerSeat: winner)
        }
    }

    private func enqueue(gameID: UUID, op: @escaping () async -> Void) {
        let previous = chains[gameID]
        chains[gameID] = Task {
            await previous?.value
            await op()
        }
    }

    private func submit(params: RemoteGames.SubmitParams, seat: Int,
                        gameID: UUID, board: BoardState?) async {
        var attempt = 0
        while true {
            do {
                let result = try await RemoteGames.submit(params)
                let tiles = RemoteGames.tiles(fromRack: result.drawn)
                if let board, board.gameID == gameID {
                    board.applyServerDraw(seat: seat, letters: tiles,
                                          bagCount: result.bagCount)
                } else {
                    // Game screen already closed: fold the refill into the cache.
                    applyDrawToCache(gameID: gameID, seat: seat, letters: tiles,
                                     bagCount: result.bagCount)
                }
                return
            } catch let error as PostgrestError {
                await rollback(gameID: gameID, serverMessage: error.message)
                return
            } catch {
                // Network trouble: retry briefly, then leave the op behind.
                // The optimistic local state stands; the next lobby refresh
                // reconciles against whatever the server last accepted.
                attempt += 1
                if attempt >= 3 { return }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
    }

    private func applyDrawToCache(gameID: UUID, seat: Int, letters: [Tile], bagCount: Int) {
        guard var saved = store.games.first(where: { $0.id == gameID }),
              saved.players.indices.contains(seat) else { return }
        saved.players[seat].rack.append(contentsOf: letters)
        saved.bagCount = bagCount
        saved.updatedAt = Date()
        store.save(saved)
    }

    // MARK: - Rejection → rollback to server truth

    private func rollback(gameID: UUID, serverMessage: String) async {
        if let dto = try? await RemoteGames.fetchGame(id: gameID),
           let fresh = Self.savedGame(from: dto, localUserID: userID) {
            store.save(fresh)
        }
        chains[gameID]?.cancel()
        chains[gameID] = nil
        rejection = Rejection(gameID: gameID,
                              message: Self.friendlyMessage(serverMessage))
    }

    private static func friendlyMessage(_ raw: String) -> String {
        switch raw {
        case "not_your_turn":
            return "The server says it wasn't your turn — the game has been restored to the server's state."
        case "tiles_not_in_rack":
            return "The server says those tiles weren't in the rack — the game has been restored to the server's state."
        case "cell_occupied":
            return "The server says a square was already taken — the game has been restored to the server's state."
        case "game_not_active":
            return "This game has already ended on the server."
        default:
            return "The server rejected the move (\(raw)) — the game has been restored to the server's state."
        }
    }

    // MARK: - Migration & lobby refresh

    /// One-time upload of pre-Phase-7 local games (bag still local). Safe
    /// to call every launch: already-migrated games are skipped, imports
    /// are idempotent by game id, and failures just retry next time.
    func migrateLocalGames() async {
        for saved in store.games where saved.bagCount == nil {
            do {
                try await RemoteGames.importGame(saved)
                var migrated = saved
                migrated.bagCount = migrated.bag.count
                migrated.bag = []
                store.save(migrated)
            } catch {
                // Offline or schema not applied yet — game stays local-mode
                // and playable; migration retries on the next launch.
            }
        }
    }

    /// Pull server state into the local cache: games changed elsewhere
    /// (another device) are refreshed; games deleted on the server drop
    /// out of the cache.
    func refreshLobby() async {
        guard let lobby = try? await RemoteGames.fetchLobby() else { return }
        for summary in lobby {
            let local = store.games.first { $0.id == summary.gameID }
            guard let serverStamp = summary.updatedDate else { continue }
            // Only pull games the server has seen move AFTER our cache did
            // (small fudge so our own just-synced ops don't churn the cache).
            let localStamp = local?.updatedAt ?? .distantPast
            if local == nil || serverStamp > localStamp.addingTimeInterval(2) {
                if let dto = try? await RemoteGames.fetchGame(id: summary.gameID),
                   let fresh = Self.savedGame(from: dto, localUserID: userID) {
                    store.save(fresh)
                }
            }
        }
        let serverIDs = Set(lobby.map(\.gameID))
        for game in store.games where game.bagCount != nil && !serverIDs.contains(game.id) {
            store.delete(id: game.id)
        }
    }

    // MARK: - DTO ↔ SavedGame

    static func submitParams(gameID: UUID, move: BoardState.RemoteMove) -> RemoteGames.SubmitParams {
        switch move.kind {
        case .play(let placements, let word, let score):
            return .init(p_game_id: gameID, p_seat: move.seat, p_kind: "play",
                         p_placements: RemoteGames.placements(from: placements),
                         p_word: word, p_client_score: score, p_swap_letters: nil)
        case .pass:
            return .init(p_game_id: gameID, p_seat: move.seat, p_kind: "pass",
                         p_placements: nil, p_word: nil, p_client_score: nil,
                         p_swap_letters: nil)
        case .swap(let tiles):
            return .init(p_game_id: gameID, p_seat: move.seat, p_kind: "swap",
                         p_placements: nil, p_word: nil, p_client_score: nil,
                         p_swap_letters: tiles.map { String($0.letter) })
        }
    }

    /// Rebuild a cacheable SavedGame from server state. Used for rollback
    /// and cross-device refresh; mid-turn tentative placements are local
    /// UI state and aren't part of it.
    static func savedGame(from dto: RemoteGames.GameDTO, localUserID: UUID) -> SavedGame? {
        guard dto.players.count == 2 else { return nil }
        let p0 = dto.players[0], p1 = dto.players[1]

        let localProfile = PlayerProfile(
            id: p0.userID ?? localUserID,
            displayName: p0.displayName ?? "Player",
            avatar: Avatar(rawValue: p0.avatar ?? "") ?? .bolt)
        let aiProfile = PlayerProfile(
            id: PlayerProfile.ai.id,
            displayName: p1.displayName ?? PlayerProfile.ai.displayName,
            avatar: Avatar(rawValue: p1.avatar ?? "") ?? .robot)

        var players = [Player(profile: localProfile, score: p0.score,
                              rack: RemoteGames.tiles(fromRack: p0.rack ?? [])),
                       Player(profile: aiProfile, score: p1.score,
                              rack: RemoteGames.tiles(fromRack: p1.rack ?? []))]

        var gameOver: GameOverSummary?
        if dto.status != "active" {
            let reason: GameOverSummary.Reason
            switch dto.endReason {
            case "six_passes": reason = .sixPasses
            default: reason = dto.winnerSeat == 1 ? .opponentEmptied : .localEmptied
            }
            // Leftover detail isn't stored server-side; finals are.
            gameOver = GameOverSummary(reason: reason,
                                       localFinal: players[0].score,
                                       opponentFinal: players[1].score,
                                       localLeftover: 0, opponentLeftover: 0)
        }

        var log = dto.importLog ?? []
        for move in dto.moves ?? [] {
            let name = move.seat == 0 ? localProfile.displayName : aiProfile.displayName
            switch move.kind {
            case "play":
                log.append("\(name) played \(move.word ?? "a word") +\(move.clientScore ?? 0)")
            case "pass": log.append("\(name) passed")
            case "swap": log.append("\(name) swapped tiles")
            case "resign": log.append("\(name) resigned")
            default: break
            }
        }

        let difficulty = AIDifficulty(rawValue: p1.aiDifficulty ?? "") ?? .hard
        return SavedGame(
            id: dto.gameID,
            createdAt: Date(),
            updatedAt: dto.updatedDate ?? Date(),
            difficulty: difficulty,
            bagCount: dto.bagCount ?? 0,
            committed: RemoteGames.committed(fromBoard: dto.board ?? [:]),
            placed: [:],
            pendingBlank: nil,
            bag: [],
            players: players,
            turnState: dto.turnSeat == 0 ? .local : .opponent,
            turnNumber: dto.turnNumber ?? 1,
            consecutivePasses: dto.consecutivePasses ?? 0,
            moveLog: log,
            gameOver: gameOver)
    }
}
