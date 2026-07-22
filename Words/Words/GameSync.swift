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

    /// A durable operation: journaled to disk before its first submission
    /// attempt and removed only on success or terminal rejection, so a
    /// force-quit can never lose a played move (the Phase 7 gap).
    struct PendingOp: Codable, Identifiable {
        enum Kind: String, Codable { case submit, resign, finish }
        let id: UUID
        let gameID: UUID
        let kind: Kind
        var submit: RemoteGames.SubmitParams?
        /// Local-perspective seat of a submit, for applying the draw.
        var localSeatIndex: Int?
        var finish: FinishPayload?
    }

    struct FinishPayload: Codable {
        let reason: String
        let scoreServerSeat0: Int
        let scoreServerSeat1: Int
        let winnerServerSeat: Int?
    }

    private let store: GameStore
    private let userID: UUID
    /// Tail of the op chain per game — each new op awaits the previous one.
    private var chains: [UUID: Task<Void, Never>] = [:]
    /// The durable queue, mirrored at journalURL. Order is submission order.
    private var journal: [PendingOp] = []
    private var inFlight: Set<UUID> = []
    private weak var activeBoard: BoardState?

    private var journalURL: URL {
        store.directory.appendingPathComponent("pending-ops.json")
    }

    /// Ops waiting to reach the server (for tests and future UI).
    var pendingOpCount: Int { journal.count }

    init(store: GameStore, userID: UUID) {
        self.store = store
        self.userID = userID
        if let data = try? Data(contentsOf: journalURL),
           let saved = try? JSONDecoder().decode([PendingOp].self, from: data) {
            journal = saved
        }
    }

    /// Re-submit every journaled op (launch, foreground). Ops already in
    /// flight are skipped; per-game FIFO order is preserved.
    func flushPending() {
        for op in journal where !inFlight.contains(op.id) {
            chain(op)
        }
    }

    private func persistJournal() {
        if journal.isEmpty {
            try? FileManager.default.removeItem(at: journalURL)
        } else if let data = try? JSONEncoder().encode(journal) {
            try? data.write(to: journalURL, options: .atomic)
        }
    }

    private func complete(_ op: PendingOp) {
        journal.removeAll { $0.id == op.id }
        persistJournal()
    }

    private func dropOps(for gameID: UUID) {
        journal.removeAll { $0.gameID == gameID }
        persistJournal()
    }

    // MARK: - Wiring

    /// Hook a live game's turn events into the sync queue.
    func attach(_ board: BoardState) {
        guard board.isRemote else { return }
        activeBoard = board
        board.onRemoteMove = { [weak self] state, move in
            self?.enqueueMove(move, from: state)
        }
        board.onGameFinished = { [weak self] state, summary in
            self?.enqueueFinish(state: state, summary: summary)
        }
        board.onResigned = { [weak self] state in
            self?.enqueueResign(state)
        }
    }

    private func boardFor(_ gameID: UUID) -> BoardState? {
        activeBoard?.gameID == gameID ? activeBoard : nil
    }

    // MARK: - Game creation

    /// New games are born on the server (it owns the bag and the racks);
    /// requires connectivity by design. Pass an opponent to challenge a
    /// friend instead of the AI — same seats, no rack comes back.
    func createGame(difficulty: AIDifficulty, profile: PlayerProfile,
                    opponent: RemoteGames.FriendDTO? = nil) async throws -> BoardState {
        let created = try await RemoteGames.create(difficulty: difficulty,
                                                   opponent: opponent?.userID)
        let opponentProfile: PlayerProfile
        if let opponent {
            opponentProfile = PlayerProfile(
                id: opponent.userID,
                displayName: opponent.displayName,
                avatar: Avatar(rawValue: opponent.avatar ?? "") ?? .star)
        } else {
            opponentProfile = .ai
        }
        return BoardState(remoteID: created.gameID,
                          myRack: RemoteGames.tiles(fromRack: created.myRack),
                          bagCount: created.bagCount,
                          localProfile: profile,
                          difficulty: difficulty,
                          opponentProfile: opponentProfile,
                          opponentIsHuman: opponent != nil,
                          opponentRack: RemoteGames.tiles(fromRack: created.aiRack ?? []))
    }

    /// Poll the server for an open human-vs-human game — how the
    /// opponent's move reaches a live board. Applies in place (no view
    /// teardown) and persists.
    func refreshActiveGame(_ board: BoardState) async {
        guard board.isRemote, board.opponentIsHuman else { return }
        guard let dto = try? await RemoteGames.fetchGame(id: board.gameID),
              let fresh = Self.savedGame(from: dto, localUserID: userID) else { return }
        board.applyServerRefresh(from: fresh)
    }

    // MARK: - Move pipeline

    private func enqueueMove(_ move: BoardState.RemoteMove, from board: BoardState) {
        let opID = UUID()
        let params = Self.submitParams(gameID: board.gameID, localSeat: board.localSeat,
                                       move: move, opID: opID)
        let op = PendingOp(id: opID, gameID: board.gameID, kind: .submit,
                           submit: params, localSeatIndex: move.seat, finish: nil)
        journal.append(op)
        persistJournal()
        chain(op)
    }

    private func enqueueResign(_ board: BoardState) {
        let op = PendingOp(id: UUID(), gameID: board.gameID, kind: .resign,
                           submit: nil, localSeatIndex: nil, finish: nil)
        journal.append(op)
        persistJournal()
        chain(op)
    }

    private func enqueueFinish(state board: BoardState, summary: GameOverSummary) {
        let localSeat = board.localSeat
        let reason: String
        switch summary.reason {
        case .localEmptied, .opponentEmptied: reason = "emptied"
        case .sixPasses: reason = "six_passes"
        case .resigned: reason = "resigned"
        case .expired: return  // expiry is decided server-side, never pushed up
        }
        // Local perspective → server seats.
        let winnerLocal: Int? = summary.localWon.map { $0 ? 0 : 1 }
            ?? (summary.localFinal == summary.opponentFinal ? nil
                : (summary.localFinal > summary.opponentFinal ? 0 : 1))
        let payload = FinishPayload(
            reason: reason,
            scoreServerSeat0: localSeat == 0 ? summary.localFinal : summary.opponentFinal,
            scoreServerSeat1: localSeat == 0 ? summary.opponentFinal : summary.localFinal,
            winnerServerSeat: winnerLocal.map { $0 == 0 ? localSeat : 1 - localSeat })
        let op = PendingOp(id: UUID(), gameID: board.gameID, kind: .finish,
                           submit: nil, localSeatIndex: nil, finish: payload)
        journal.append(op)
        persistJournal()
        chain(op)
    }

    private func chain(_ op: PendingOp) {
        guard !inFlight.contains(op.id) else { return }
        inFlight.insert(op.id)
        let previous = chains[op.gameID]
        chains[op.gameID] = Task {
            await previous?.value
            await perform(op)
            inFlight.remove(op.id)
        }
    }

    private func perform(_ op: PendingOp) async {
        switch op.kind {
        case .submit: await performSubmit(op)
        case .resign: await performResign(op)
        case .finish: await performFinish(op)
        }
    }

    private func performSubmit(_ op: PendingOp) async {
        guard let params = op.submit, let seat = op.localSeatIndex else {
            complete(op)
            return
        }
        var attempt = 0
        while true {
            do {
                let result = try await RemoteGames.submit(params)
                let board = boardFor(op.gameID)
                if result.duplicate == true {
                    // This op already landed (we force-quit before hearing
                    // back). Reconcile the refill we never received: the
                    // server rack is the whole truth for the seat.
                    if let rackLetters = result.rack {
                        let tiles = RemoteGames.tiles(fromRack: rackLetters)
                        if let board {
                            board.applyAuthoritativeRack(seat: seat, letters: tiles,
                                                         bagCount: result.bagCount)
                        } else {
                            applyRackToCache(gameID: op.gameID, seat: seat,
                                             letters: tiles, bagCount: result.bagCount)
                        }
                    }
                } else {
                    let tiles = RemoteGames.tiles(fromRack: result.drawn)
                    if let board {
                        board.applyServerDraw(seat: seat, letters: tiles,
                                              bagCount: result.bagCount)
                    } else {
                        applyDrawToCache(gameID: op.gameID, seat: seat,
                                         letters: tiles, bagCount: result.bagCount)
                    }
                }
                complete(op)
                return
            } catch let error as PostgrestError {
                // Terminal: this op — and everything queued behind it,
                // which builds on it — will never be accepted.
                dropOps(for: op.gameID)
                await rollback(gameID: op.gameID, serverMessage: error.message)
                return
            } catch {
                // Network trouble: retry briefly, then leave the op in the
                // journal — it survives force-quit and retries on the next
                // launch/foreground (idempotent via p_op_id).
                attempt += 1
                if attempt >= 3 { return }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
    }

    private func performResign(_ op: PendingOp) async {
        do {
            try await RemoteGames.resign(gameID: op.gameID)
            complete(op)
        } catch is PostgrestError {
            // Already over server-side (opponent finished/resigned first,
            // or a replay) — nothing left to do.
            complete(op)
        } catch {
            // Network: stays journaled for the next flush.
        }
    }

    private func performFinish(_ op: PendingOp) async {
        guard let payload = op.finish else {
            complete(op)
            return
        }
        do {
            try await RemoteGames.finish(gameID: op.gameID, reason: payload.reason,
                                         localFinal: payload.scoreServerSeat0,
                                         opponentFinal: payload.scoreServerSeat1,
                                         winnerSeat: payload.winnerServerSeat)
            complete(op)
        } catch is PostgrestError {
            complete(op)  // finish_game is idempotent; a rejection is terminal
        } catch {
            // Network: stays journaled for the next flush.
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

    private func applyRackToCache(gameID: UUID, seat: Int, letters: [Tile], bagCount: Int) {
        guard var saved = store.games.first(where: { $0.id == gameID }),
              saved.players.indices.contains(seat) else { return }
        saved.players[seat].rack = letters
        if seat == 0 {
            saved.placed = [:]
            saved.pendingBlank = nil
        }
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
        let opponent = store.games.first { $0.id == gameID }?
            .players[1].profile.displayName
        rejection = Rejection(gameID: gameID,
                              message: Self.friendlyMessage(serverMessage,
                                                            opponent: opponent))
    }

    private static func friendlyMessage(_ raw: String, opponent: String?) -> String {
        let game = opponent.map { "your game with \($0)" } ?? "the game"
        switch raw {
        case "not_your_turn":
            return "A move in \(game) couldn't sync — the server had already moved on (your opponent may have played first). The board has been restored to the server's state."
        case "tiles_not_in_rack":
            return "A move in \(game) couldn't sync — the server says those tiles weren't in the rack. The board has been restored to the server's state."
        case "cell_occupied":
            return "A move in \(game) couldn't sync — a square was already taken. The board has been restored to the server's state."
        case "game_not_active":
            return "A move in \(game) couldn't sync because the game has already ended (finished, resigned, or expired). The final state is shown."
        default:
            return "A move in \(game) was rejected by the server (\(raw)). The board has been restored to the server's state."
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

    /// One-tap rematch: server creates or joins THE single rematch game.
    func rematch(from board: BoardState, profile: PlayerProfile) async throws -> BoardState {
        let result = try await RemoteGames.requestRematch(gameID: board.gameID)
        let opponentProfile = PlayerProfile(
            id: result.opponent.userID,
            displayName: result.opponent.displayName,
            avatar: Avatar(rawValue: result.opponent.avatar ?? "") ?? .star)
        return BoardState(remoteID: result.gameID,
                          myRack: RemoteGames.tiles(fromRack: result.myRack),
                          bagCount: result.bagCount,
                          localProfile: profile,
                          difficulty: board.difficulty,
                          opponentProfile: opponentProfile,
                          opponentIsHuman: true,
                          opponentRack: [],
                          localSeat: result.mySeat)
    }

    /// BoardState speaks local-perspective seats (0 = me); the server wants
    /// real seats. Challenge recipients sit in server seat 1, so the two
    /// numberings differ exactly when localSeat == 1.
    static func submitParams(gameID: UUID, localSeat: Int,
                             move: BoardState.RemoteMove,
                             opID: UUID? = nil) -> RemoteGames.SubmitParams {
        let serverSeat = move.seat == 0 ? localSeat : 1 - localSeat
        switch move.kind {
        case .play(let placements, let word, let score):
            return .init(p_game_id: gameID, p_seat: serverSeat, p_kind: "play",
                         p_placements: RemoteGames.placements(from: placements),
                         p_word: word, p_client_score: score, p_swap_letters: nil,
                         p_op_id: opID)
        case .pass:
            return .init(p_game_id: gameID, p_seat: serverSeat, p_kind: "pass",
                         p_placements: nil, p_word: nil, p_client_score: nil,
                         p_swap_letters: nil, p_op_id: opID)
        case .swap(let tiles):
            return .init(p_game_id: gameID, p_seat: serverSeat, p_kind: "swap",
                         p_placements: nil, p_word: nil, p_client_score: nil,
                         p_swap_letters: tiles.map { String($0.letter) },
                         p_op_id: opID)
        }
    }

    /// Rebuild a cacheable SavedGame from server state. Used for rollback,
    /// cross-device refresh, and live human-game refresh. The cache is
    /// local-perspective: players[0] is always the local user, whatever
    /// server seat they occupy; mid-turn tentative placements are local UI
    /// state and aren't part of it.
    static func savedGame(from dto: RemoteGames.GameDTO, localUserID: UUID) -> SavedGame? {
        guard dto.players.count == 2,
              let mine = dto.players.first(where: { $0.userID == localUserID }),
              let theirs = dto.players.first(where: { $0.seat != mine.seat })
        else { return nil }
        let localSeat = mine.seat
        // 'departed' = a human who deleted their account (phase8b): the
        // game ends by forfeit server-side; the seat stays, anonymized.
        let opponentIsHuman = theirs.engine != "local_ai"

        let localProfile = PlayerProfile(
            id: localUserID,
            displayName: mine.displayName ?? "Player",
            avatar: Avatar(rawValue: mine.avatar ?? "") ?? .bolt)
        let opponentFallbackName = theirs.engine == "departed"
            ? "Departed player" : PlayerProfile.ai.displayName
        let opponentProfile = PlayerProfile(
            id: theirs.userID ?? PlayerProfile.ai.id,
            displayName: theirs.displayName ?? opponentFallbackName,
            avatar: Avatar(rawValue: theirs.avatar ?? "") ?? (opponentIsHuman ? .star : .robot))

        // A human opponent's rack is never in the DTO (server refuses);
        // an AI seat's rack is (the client runs the engine).
        let players = [Player(profile: localProfile, score: mine.score,
                              rack: RemoteGames.tiles(fromRack: mine.rack ?? [])),
                       Player(profile: opponentProfile, score: theirs.score,
                              rack: RemoteGames.tiles(fromRack: theirs.rack ?? []))]

        var gameOver: GameOverSummary?
        if dto.status != "active" {
            let reason: GameOverSummary.Reason
            switch (dto.endReason, dto.winnerSeat) {
            case ("six_passes", _): reason = .sixPasses
            case ("resigned", _): reason = .resigned
            case ("expired", _): reason = .expired
            case (_, .some(let w)): reason = w == localSeat ? .localEmptied : .opponentEmptied
            default: reason = .sixPasses
            }
            // Leftover detail isn't stored server-side; finals are. The
            // explicit winner matters for resign/expiry, where the higher
            // scorer can still lose.
            gameOver = GameOverSummary(reason: reason,
                                       localFinal: players[0].score,
                                       opponentFinal: players[1].score,
                                       localLeftover: 0, opponentLeftover: 0,
                                       localWon: dto.winnerSeat.map { $0 == localSeat })
        }

        var log = dto.importLog ?? []
        for move in dto.moves ?? [] {
            let name = move.seat == localSeat ? localProfile.displayName
                                              : opponentProfile.displayName
            switch move.kind {
            case "play":
                log.append("\(name) played \(move.word ?? "a word") +\(move.clientScore ?? 0)")
            case "pass": log.append("\(name) passed")
            case "swap": log.append("\(name) swapped tiles")
            case "resign": log.append("\(name) resigned")
            default: break
            }
        }

        let difficulty = AIDifficulty(rawValue: theirs.aiDifficulty ?? "") ?? .hard
        return SavedGame(
            id: dto.gameID,
            createdAt: Date(),
            updatedAt: dto.updatedDate ?? Date(),
            difficulty: difficulty,
            bagCount: dto.bagCount ?? 0,
            localSeat: localSeat,
            opponentIsHuman: opponentIsHuman,
            expiresAt: opponentIsHuman ? dto.expiresDate : nil,
            committed: RemoteGames.committed(fromBoard: dto.board ?? [:]),
            placed: [:],
            pendingBlank: nil,
            bag: [],
            players: players,
            turnState: dto.turnSeat == localSeat ? .local : .opponent,
            turnNumber: dto.turnNumber ?? 1,
            consecutivePasses: dto.consecutivePasses ?? 0,
            moveLog: log,
            gameOver: gameOver)
    }
}
