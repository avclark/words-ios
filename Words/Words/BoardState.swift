import SwiftUI
import Observation

/// Rejection feedback for the last PLAY attempt; cleared when the placement
/// changes. Successful plays/passes/swaps land in `moveLog` instead.
enum PlayStatus: Equatable {
    case rejected(String)
}

/// Final result once the game ends. Scores here already include the
/// endgame math from GAME-LOGIC-REFERENCE.md: each player loses their
/// leftover tile values; a player who emptied their rack gains the
/// opponent's leftovers.
struct GameOverSummary: Equatable, Codable {
    enum Reason: String, Equatable, Codable {
        case localEmptied, opponentEmptied, sixPasses, resigned
    }
    let reason: Reason
    let localFinal: Int
    let opponentFinal: Int
    /// Face value of tiles left on each rack when the game ended.
    let localLeftover: Int
    let opponentLeftover: Int
}

/// Whose turn it is. `.opponent` covers the whole time the other side holds
/// the turn — for the local AI that's a second or two of computing; for a
/// future remote player it could be hours. The game screen renders the same
/// "waiting" state either way.
enum TurnState: String, Equatable, Codable {
    case local
    case opponent
}

/// All game state for one game. The opponent is driven through the
/// OpponentEngine seam and is NOT assumed to be the local AI.
@Observable
final class BoardState {
    /// Stable identity of this game across launches — the key the saved
    /// game is stored under, and later the server-side game ID.
    let gameID: UUID
    let createdAt: Date
    /// How strong this game's AI plays. Fixed at game creation.
    let difficulty: AIDifficulty

    /// Called after any change worth persisting (turn completions, blank
    /// assignment). The owner wires this to the GameStore; the model never
    /// touches storage itself.
    var onAutosave: ((BoardState) -> Void)?

    /// A turn-consuming action, reported for background sync. Remote games
    /// apply every move locally first (optimistic UI) and GameSync pushes
    /// the intent afterwards — the board never waits on the network.
    struct RemoteMove {
        enum Kind {
            case play(placements: [BoardCoord: Tile], word: String, score: Int)
            case pass
            case swap([Tile])
        }
        let seat: Int
        let kind: Kind
    }
    var onRemoteMove: ((BoardState, RemoteMove) -> Void)?
    var onGameFinished: ((BoardState, GameOverSummary) -> Void)?

    /// Phase 7 remote seam. Non-nil means this game's bag lives on the
    /// server: the client never draws tiles locally; refills arrive via
    /// applyServerDraw when a move syncs.
    private(set) var remoteBagCount: Int?
    var isRemote: Bool { remoteBagCount != nil }
    /// The server seat the local player occupies (challenge recipients sit
    /// in seat 1). Everything in this class stays local-perspective
    /// (players[0] = me); GameSync translates seats on the wire.
    private(set) var localSeat: Int = 0
    /// Phase 8: the opponent seat is a remote human — no local engine runs;
    /// the turn resolves when the server shows their move.
    private(set) var opponentIsHuman: Bool = false
    /// The one source for "tiles left" — server-authoritative for remote
    /// games, the local bag for legacy/local games (and unit tests).
    var bagRemaining: Int { remoteBagCount ?? bag.count }

    /// Tiles locked into the board from previous turns.
    private(set) var committed: [BoardCoord: Tile] = [:]
    /// Tiles tentatively placed this turn (still movable/recallable).
    private(set) var placed: [BoardCoord: Tile] = [:]
    /// Face-down tiles remaining to draw.
    private(set) var bag: [Tile] = []

    /// Both participants. [0] is the local player, [1] the opponent — but
    /// consumers should use `localPlayer`/`opponent`, not indexes.
    private(set) var players: [Player] = []
    private(set) var turnState: TurnState = .local

    private(set) var turnNumber = 1
    /// Rejection from the most recent PLAY tap; cleared when the placement changes.
    private(set) var status: PlayStatus?
    /// Human-readable history of completed actions, newest last.
    private(set) var moveLog: [String] = []
    /// Passes in a row by either side; 6 ends the game (3 each, per the
    /// reference doc). A scoring move or a swap resets it.
    private(set) var consecutivePasses = 0
    /// Non-nil once the game has ended.
    private(set) var gameOver: GameOverSummary?

    /// Set when a blank tile lands on the board and needs a letter.
    var pendingBlank: BoardCoord?

    /// Drives the opponent's turns. Today always the local AI; a remote
    /// implementation slots in here without changing anything above it.
    private let opponentEngine: OpponentEngine

    private let localIndex = 0
    private let opponentIndex = 1

    // MARK: - Convenience accessors

    var localPlayer: Player { players[localIndex] }
    var opponent: Player { players[opponentIndex] }
    var waitingForOpponent: Bool { turnState == .opponent && gameOver == nil }

    /// The local player's rack — the one the rack UI and drag layer operate
    /// on. (The opponent's rack is never rendered.)
    var rack: [Tile] { players[localIndex].rack }

    private var localRack: [Tile] {
        get { players[localIndex].rack }
        set { players[localIndex].rack = newValue }
    }

    /// One scorer shared by preview, player validation, and opponent moves
    /// so the scoring path can never fork.
    private var scorer: MoveScorer { MoveScorer(board: committed) }

    init(localProfile: PlayerProfile = LocalProfile.load(),
         opponentProfile: PlayerProfile = .ai,
         difficulty: AIDifficulty = .hard,
         opponentEngine: OpponentEngine? = nil) {
        self.gameID = UUID()
        self.createdAt = Date()
        self.difficulty = difficulty
        self.opponentEngine = opponentEngine ?? LocalAIOpponent(difficulty: difficulty)
        // Touch the lexicon up front so a missing word list fails loudly at
        // game start, not mid-play.
        _ = Lexicon.words
        bag = TileDistribution.fullBag().shuffled()
        players = [Player(profile: localProfile), Player(profile: opponentProfile)]
        players[localIndex].rack = draw(7)
        players[opponentIndex].rack = draw(7)
        AIPlayer.warmUp()
    }

    /// A fresh server-created game: the server built the bag and dealt both
    /// racks (create_game). For AI games the client holds the AI rack
    /// because it runs the engine; for a human opponent the rack stays on
    /// the server and `opponentRack` is empty.
    init(remoteID: UUID, myRack: [Tile], bagCount: Int,
         localProfile: PlayerProfile, difficulty: AIDifficulty,
         opponentProfile: PlayerProfile = .ai,
         opponentIsHuman: Bool = false,
         opponentRack: [Tile] = []) {
        self.gameID = remoteID
        self.createdAt = Date()
        self.difficulty = difficulty
        self.opponentIsHuman = opponentIsHuman
        self.opponentEngine = LocalAIOpponent(difficulty: difficulty)
        _ = Lexicon.words
        remoteBagCount = bagCount
        players = [Player(profile: localProfile, rack: myRack),
                   Player(profile: opponentProfile, rack: opponentRack)]
        if !opponentIsHuman { AIPlayer.warmUp() }
    }

    /// Restore a persisted game exactly where it left off.
    init(from saved: SavedGame, opponentEngine: OpponentEngine? = nil) {
        self.gameID = saved.id
        self.createdAt = saved.createdAt
        self.difficulty = saved.difficulty
        self.opponentEngine = opponentEngine ?? LocalAIOpponent(difficulty: saved.difficulty)
        _ = Lexicon.words
        committed = saved.committed
        placed = saved.placed
        pendingBlank = saved.pendingBlank
        bag = saved.bag
        players = saved.players
        turnState = saved.turnState
        turnNumber = saved.turnNumber
        consecutivePasses = saved.consecutivePasses
        moveLog = saved.moveLog
        gameOver = saved.gameOver
        remoteBagCount = saved.bagCount
        localSeat = saved.localSeat ?? 0
        opponentIsHuman = saved.opponentIsHuman ?? false
        if !opponentIsHuman { AIPlayer.warmUp() }
    }

    /// If the app died while the opponent held the turn, the engine's
    /// computation died with it — hand the turn over again. Separate from
    /// init(from:) so the owner can wire callbacks (autosave, remote sync)
    /// before any engine action flows.
    func resumeOpponentTurnIfNeeded() {
        if turnState == .opponent && gameOver == nil {
            beginOpponentTurn()
        }
    }

    /// Complete, serializable game state — everything needed to resume this
    /// exact game on a later launch (and, later, to sync a remote game).
    func snapshot() -> SavedGame {
        SavedGame(id: gameID,
                  createdAt: createdAt,
                  updatedAt: Date(),
                  difficulty: difficulty,
                  bagCount: remoteBagCount,
                  localSeat: localSeat,
                  opponentIsHuman: opponentIsHuman,
                  committed: committed,
                  placed: placed,
                  pendingBlank: pendingBlank,
                  bag: bag,
                  players: players,
                  turnState: turnState,
                  turnNumber: turnNumber,
                  consecutivePasses: consecutivePasses,
                  moveLog: moveLog,
                  gameOver: gameOver)
    }

    private func autosave() {
        onAutosave?(self)
    }

    // MARK: - Queries

    func tile(at coord: BoardCoord) -> Tile? {
        placed[coord] ?? committed[coord]
    }

    func isOccupied(_ coord: BoardCoord) -> Bool {
        tile(at: coord) != nil
    }

    func isPlacedThisTurn(_ coord: BoardCoord) -> Bool {
        placed[coord] != nil
    }

    // MARK: - Actions

    func placeFromRack(tileID: Tile.ID, at coord: BoardCoord) {
        guard !isOccupied(coord), let idx = localRack.firstIndex(where: { $0.id == tileID }) else { return }
        status = nil
        let tile = localRack.remove(at: idx)
        placed[coord] = tile
        if tile.isBlank { pendingBlank = coord }
    }

    func moveOnBoard(from: BoardCoord, to: BoardCoord) {
        guard from != to, let tile = placed[from], !isOccupied(to) else {
            // Invalid target: tile snaps back to where it was (handled by caller animation).
            return
        }
        status = nil
        placed.removeValue(forKey: from)
        placed[to] = tile
        if pendingBlank == from { pendingBlank = to }
    }

    /// Lift a placed tile off the board into the player's hand (drag start).
    func lift(from coord: BoardCoord) -> Tile? {
        guard let tile = placed[coord] else { return nil }
        status = nil
        placed.removeValue(forKey: coord)
        if pendingBlank == coord { pendingBlank = nil }
        return tile
    }

    /// Put a lifted tile back where it came from (cancelled board drag).
    func restore(_ tile: Tile, at coord: BoardCoord) {
        placed[coord] = tile
        if tile.isBlank && tile.assignedLetter == nil { pendingBlank = coord }
    }

    func drop(_ tile: Tile, at coord: BoardCoord) {
        guard !isOccupied(coord) else { return }
        status = nil
        placed[coord] = tile
        if tile.isBlank && tile.assignedLetter == nil { pendingBlank = coord }
    }

    func returnToRack(_ tile: Tile, insertAt index: Int? = nil) {
        var t = tile
        t.assignedLetter = nil // blanks revert to wildcards off the board
        let i = min(max(index ?? localRack.count, 0), localRack.count)
        localRack.insert(t, at: i)
    }

    func returnToRack(from coord: BoardCoord, insertAt index: Int? = nil) {
        guard let tile = placed.removeValue(forKey: coord) else { return }
        status = nil
        if pendingBlank == coord { pendingBlank = nil }
        returnToRack(tile, insertAt: index)
    }

    func reorderRack(tileID: Tile.ID, to index: Int) {
        guard let from = localRack.firstIndex(where: { $0.id == tileID }) else { return }
        var target = min(max(index, 0), localRack.count - 1)
        let tile = localRack.remove(at: from)
        target = min(target, localRack.count)
        localRack.insert(tile, at: target)
    }

    func assignBlank(at coord: BoardCoord, letter: Character) {
        guard var tile = placed[coord], tile.isBlank else { return }
        tile.assignedLetter = letter
        placed[coord] = tile
        pendingBlank = nil
        autosave()
    }

    func recallAll() {
        for coord in placed.keys.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }) {
            returnToRack(from: coord)
        }
    }

    func shuffleRack() {
        localRack.shuffle()
    }

    // MARK: - Playing a move

    /// Attempt to play the current placement as a real move, enforcing every
    /// rule in GAME-LOGIC-REFERENCE.md. On success the tiles commit, the score
    /// banks, and the rack refills. On rejection the tiles stay on the board
    /// and `status` explains why.
    func playMove() {
        guard gameOver == nil, turnState == .local, !placed.isEmpty else { return }
        guard pendingBlank == nil else {
            status = .rejected("Pick a letter for the blank tile first")
            return
        }

        let horizontal: Bool
        switch scorer.placementLine(placed) {
        case .notALine:
            status = .rejected("Tiles must be in a single row or column")
            return
        case .gapped:
            status = .rejected("Your word can't have gaps")
            return
        case .ok(let h):
            horizontal = h
        }

        if committed.isEmpty {
            guard placed[.center] != nil else {
                status = .rejected("The first word must cover the center square")
                return
            }
        } else {
            guard touchesCommitted() else {
                status = .rejected("Your word must connect to a tile on the board")
                return
            }
        }

        // Collect every word formed: the main run along the move's axis, plus
        // a cross word through each placed tile. Only runs of 2+ count.
        let coords = placed.keys.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        var formed: [[BoardCoord]] = []
        let main = scorer.wordThrough(coords[0], horizontal: horizontal, placement: placed)
        if main.count > 1 { formed.append(main) }
        for coord in coords {
            let cross = scorer.wordThrough(coord, horizontal: !horizontal, placement: placed)
            if cross.count > 1 { formed.append(cross) }
        }
        guard !formed.isEmpty else {
            status = .rejected("Words need at least two letters")
            return
        }

        let wordsFormed = formed.map { scorer.string(for: $0, placement: placed) }
        let invalid = wordsFormed.filter { !Lexicon.contains($0) }
        guard invalid.isEmpty else {
            status = .rejected("Not in dictionary: \(invalid.joined(separator: ", "))")
            return
        }

        guard let score = currentScore() else {
            status = .rejected("Invalid placement")
            return
        }

        let placement = placed
        for (coord, tile) in placed { committed[coord] = tile }
        placed = [:]
        players[localIndex].score += score
        if isRemote {
            // The server draws; the refill arrives via applyServerDraw.
            onRemoteMove?(self, RemoteMove(seat: 0, kind: .play(
                placements: placement, word: wordsFormed[0], score: score)))
        } else {
            localRack.append(contentsOf: draw(7 - localRack.count))
        }
        turnNumber += 1
        consecutivePasses = 0
        status = nil
        log("\(localPlayer.profile.displayName) played \(wordsFormed[0]) +\(score)")
        // Endgame: bag empty and the local player used every tile — the game
        // ends now; the opponent does not get another turn.
        if bagRemaining == 0 && localRack.isEmpty {
            endGame(reason: .localEmptied)
        } else {
            beginOpponentTurn()
        }
        autosave()
    }

    // MARK: - Pass & swap

    /// Forfeit the turn without playing. Any tentatively placed tiles are
    /// recalled first. Six consecutive passes (by either side) end the game.
    func passTurn() {
        guard gameOver == nil, turnState == .local else { return }
        recallAll()
        turnNumber += 1
        consecutivePasses += 1
        status = nil
        log("\(localPlayer.profile.displayName) passed")
        if isRemote {
            onRemoteMove?(self, RemoteMove(seat: 0, kind: .pass))
        }
        if consecutivePasses >= 6 {
            endGame(reason: .sixPasses)
        } else {
            beginOpponentTurn()
        }
        autosave()
    }

    /// Whether a swap of `count` tiles is currently allowed.
    func canSwap(count: Int) -> Bool {
        gameOver == nil && turnState == .local && count > 0 && bagRemaining >= count
    }

    /// Exchange the chosen rack tiles, forfeiting the turn. Ordering per
    /// GAME-LOGIC-REFERENCE.md: remove from rack → return to bag →
    /// RESHUFFLE → then draw replacements.
    func swapTiles(ids: Set<Tile.ID>) {
        guard canSwap(count: ids.count) else { return }
        recallAll()
        var discarded: [Tile] = []
        localRack.removeAll { tile in
            guard ids.contains(tile.id) else { return false }
            var t = tile
            t.assignedLetter = nil
            discarded.append(t)
            return true
        }
        guard !discarded.isEmpty else { return }
        if isRemote {
            // Server does return → reshuffle → draw; replacements arrive
            // via applyServerDraw.
            onRemoteMove?(self, RemoteMove(seat: 0, kind: .swap(discarded)))
        } else {
            bag.append(contentsOf: discarded)
            bag.shuffle()
            localRack.append(contentsOf: draw(discarded.count))
        }
        turnNumber += 1
        consecutivePasses = 0 // a swap is an action, not a pass
        status = nil
        log("\(localPlayer.profile.displayName) swapped \(discarded.count) tile\(discarded.count == 1 ? "" : "s")")
        beginOpponentTurn()
        autosave()
    }

    // MARK: - Opponent turn

    /// Hand the turn to the opponent engine. From here until the completion
    /// fires, the game is in `.opponent` turn state — the UI shows "waiting"
    /// whether that resolves in two seconds (local AI) or would take hours
    /// (future remote player).
    private func beginOpponentTurn() {
        guard gameOver == nil else { return }
        // A remote human's turn has no local engine: the rack lives on the
        // server (empty here by design) and the turn resolves when a server
        // refresh shows their move. Everything below is AI-only.
        if opponentIsHuman {
            turnState = .opponent
            return
        }
        guard !opponent.rack.isEmpty else {
            opponentPassed("\(opponent.profile.displayName) has no tiles — passed")
            return
        }
        turnState = .opponent
        opponentEngine.takeTurn(board: committed, rack: opponent.rack) { [weak self] action in
            self?.handleOpponentAction(action)
        }
    }

    /// The single entry point for opponent actions, whatever their source.
    private func handleOpponentAction(_ action: OpponentAction) {
        guard gameOver == nil else { return }
        defer { autosave() }
        turnState = .local
        switch action {
        case .pass:
            opponentPassed("\(opponent.profile.displayName) passed")

        case .play(let placement, let word):
            // Score through the same shared scorer as the local player's
            // moves — the engine's opinion of the score is never trusted.
            guard !placement.isEmpty, let score = scorer.score(placement) else {
                opponentPassed("\(opponent.profile.displayName) passed")
                return
            }
            // The local player may have tentatively placed tiles while
            // waiting; bounce any that sit on cells this move needs.
            for coord in placement.keys where placed[coord] != nil {
                returnToRack(from: coord)
            }
            for (coord, tile) in placement { committed[coord] = tile }
            for tile in placement.values {
                if let idx = players[opponentIndex].rack.firstIndex(where: { $0.letter == tile.letter }) {
                    players[opponentIndex].rack.remove(at: idx)
                }
            }
            players[opponentIndex].score += score
            if isRemote {
                onRemoteMove?(self, RemoteMove(seat: 1, kind: .play(
                    placements: placement, word: word, score: score)))
            } else {
                players[opponentIndex].rack.append(contentsOf: draw(7 - players[opponentIndex].rack.count))
            }
            consecutivePasses = 0
            log("\(opponent.profile.displayName) played \(word) +\(score)")
            // Endgame: bag empty and the opponent used every tile.
            if bagRemaining == 0 && players[opponentIndex].rack.isEmpty {
                endGame(reason: .opponentEmptied)
            }
        }
    }

    private func opponentPassed(_ message: String) {
        turnState = .local
        log(message)
        if isRemote {
            onRemoteMove?(self, RemoteMove(seat: 1, kind: .pass))
        }
        consecutivePasses += 1
        if consecutivePasses >= 6 {
            endGame(reason: .sixPasses)
        }
    }

    // MARK: - Endgame

    /// Apply the endgame math from GAME-LOGIC-REFERENCE.md: each player
    /// loses the sum of their leftover tile values; a player who emptied
    /// their rack gains the total of the opponent's leftovers.
    private func endGame(reason: GameOverSummary.Reason) {
        turnState = .local
        let localLeft = localRack.reduce(0) { $0 + $1.points }
        let oppLeft = opponent.rack.reduce(0) { $0 + $1.points }
        players[localIndex].score -= localLeft
        players[opponentIndex].score -= oppLeft
        switch reason {
        case .localEmptied: players[localIndex].score += oppLeft
        case .opponentEmptied: players[opponentIndex].score += localLeft
        case .sixPasses, .resigned: break
        }
        let summary = GameOverSummary(reason: reason,
                                      localFinal: players[localIndex].score,
                                      opponentFinal: players[opponentIndex].score,
                                      localLeftover: localLeft,
                                      opponentLeftover: oppLeft)
        gameOver = summary
        if isRemote {
            onGameFinished?(self, summary)
        }
    }

    /// Server response to a synced move: the authoritative refill for one
    /// seat (local-perspective index) plus the remaining bag count.
    func applyServerDraw(seat: Int, letters: [Tile], bagCount: Int) {
        guard isRemote, players.indices.contains(seat) else { return }
        remoteBagCount = bagCount
        players[seat].rack.append(contentsOf: letters)
        onAutosave?(self)
    }

    /// Fold freshly pulled server state into the live game — how a remote
    /// human opponent's move lands. Only ADDS committed tiles and advances
    /// the turn; views stay alive throughout (invariant 2: nothing is torn
    /// down, exactly like an AI move landing via handleOpponentAction).
    func applyServerRefresh(from saved: SavedGame) {
        guard isRemote, gameOver == nil else { return }
        guard saved.turnNumber > turnNumber || saved.gameOver != nil else { return }

        for (coord, tile) in saved.committed where committed[coord] == nil {
            // The local player may have tentatively placed tiles while
            // waiting; bounce any that sit on cells the move needs.
            if placed[coord] != nil { returnToRack(from: coord) }
            committed[coord] = tile
        }
        let scoreDelta = saved.players[1].score - players[opponentIndex].score
        players[localIndex].score = saved.players[0].score
        players[opponentIndex].score = saved.players[1].score
        turnNumber = saved.turnNumber
        consecutivePasses = saved.consecutivePasses
        remoteBagCount = saved.bagCount ?? remoteBagCount
        turnState = saved.turnState
        if scoreDelta > 0 {
            log("\(opponent.profile.displayName) played +\(scoreDelta)")
        } else if saved.turnState == .local {
            log("\(opponent.profile.displayName) passed or swapped")
        }
        gameOver = saved.gameOver
        onAutosave?(self)
    }

    // MARK: - Helpers

    /// True if any tile placed this turn is orthogonally adjacent to a tile
    /// committed on a previous turn.
    private func touchesCommitted() -> Bool {
        placed.keys.contains { coord in
            [(0, 1), (0, -1), (1, 0), (-1, 0)].contains { dr, dc in
                committed[BoardCoord(row: coord.row + dr, col: coord.col + dc)] != nil
            }
        }
    }

    private func draw(_ count: Int) -> [Tile] {
        let take = min(max(count, 0), bag.count)
        let drawn = Array(bag.prefix(take))
        bag.removeFirst(take)
        return drawn
    }

    private func log(_ entry: String) {
        moveLog.append(entry)
        if moveLog.count > 50 { moveLog.removeFirst(moveLog.count - 50) }
    }

    // MARK: - Live score preview

    /// Score for the tiles placed this turn, or nil if the placement is not
    /// a single contiguous line (Scrabble GO greys the score chip out then).
    /// Full logic lives in MoveScorer, shared with playMove() and opponents.
    func currentScore() -> Int? {
        scorer.score(placed)
    }
}
