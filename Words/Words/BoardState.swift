import SwiftUI
import Observation

/// Outcome of the last PLAY attempt, for the UI readout.
enum PlayStatus: Equatable {
    case rejected(String)
    case played(words: [String], score: Int)
}

/// All game state for a local single-player game. No networking.
@Observable
final class BoardState {
    /// Tiles locked into the board from previous turns.
    private(set) var committed: [BoardCoord: Tile] = [:]
    /// Tiles tentatively placed this turn (still movable/recallable).
    private(set) var placed: [BoardCoord: Tile] = [:]
    /// The player's rack, left to right.
    private(set) var rack: [Tile] = []
    /// Face-down tiles remaining to draw.
    private(set) var bag: [Tile] = []
    /// Player's running total.
    private(set) var totalScore = 0
    private(set) var turnNumber = 1
    /// Result of the most recent PLAY tap; cleared when the placement changes.
    private(set) var status: PlayStatus?

    /// The AI opponent's rack (hidden from the UI except for its count).
    private(set) var aiRack: [Tile] = []
    private(set) var aiTotalScore = 0
    /// True while the AI computes its move on a background queue.
    private(set) var isAIThinking = false
    /// What the AI did last turn; persists while the player builds a move.
    private(set) var aiMessage: String?

    /// One scorer shared by preview, player validation, and the AI so the
    /// scoring path can never fork.
    private var scorer: MoveScorer { MoveScorer(board: committed) }

    /// Set when a blank tile lands on the board and needs a letter.
    var pendingBlank: BoardCoord?

    init() {
        newGame()
    }

    func newGame() {
        // Touch the lexicon up front so a missing word list fails loudly at
        // game start, not mid-play.
        _ = Lexicon.words
        committed = [:]
        placed = [:]
        pendingBlank = nil
        totalScore = 0
        turnNumber = 1
        status = nil
        aiTotalScore = 0
        isAIThinking = false
        aiMessage = nil
        bag = TileDistribution.fullBag().shuffled()
        rack = draw(7)
        aiRack = draw(7)
        AIPlayer.warmUp()
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
        guard !isOccupied(coord), let idx = rack.firstIndex(where: { $0.id == tileID }) else { return }
        status = nil
        let tile = rack.remove(at: idx)
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
        let i = min(max(index ?? rack.count, 0), rack.count)
        rack.insert(t, at: i)
    }

    func returnToRack(from coord: BoardCoord, insertAt index: Int? = nil) {
        guard let tile = placed.removeValue(forKey: coord) else { return }
        status = nil
        if pendingBlank == coord { pendingBlank = nil }
        returnToRack(tile, insertAt: index)
    }

    func reorderRack(tileID: Tile.ID, to index: Int) {
        guard let from = rack.firstIndex(where: { $0.id == tileID }) else { return }
        var target = min(max(index, 0), rack.count - 1)
        let tile = rack.remove(at: from)
        target = min(target, rack.count)
        rack.insert(tile, at: target)
    }

    func assignBlank(at coord: BoardCoord, letter: Character) {
        guard var tile = placed[coord], tile.isBlank else { return }
        tile.assignedLetter = letter
        placed[coord] = tile
        pendingBlank = nil
    }

    func recallAll() {
        for coord in placed.keys.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }) {
            returnToRack(from: coord)
        }
    }

    func shuffleRack() {
        rack.shuffle()
    }

    // MARK: - Playing a move

    /// Attempt to play the current placement as a real move, enforcing every
    /// rule in GAME-LOGIC-REFERENCE.md. On success the tiles commit, the score
    /// banks, and the rack refills. On rejection the tiles stay on the board
    /// and `status` explains why.
    func playMove() {
        guard !placed.isEmpty else { return }
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

        for (coord, tile) in placed { committed[coord] = tile }
        placed = [:]
        totalScore += score
        refillRack()
        turnNumber += 1
        status = .played(words: wordsFormed, score: score)
        startAITurn()
    }

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

    private func refillRack() {
        rack.append(contentsOf: draw(7 - rack.count))
    }

    // MARK: - Live score preview

    /// Score for the tiles placed this turn, or nil if the placement is not
    /// a single contiguous line (Scrabble GO greys the score chip out then).
    /// Full logic lives in MoveScorer, shared with playMove() and the AI.
    func currentScore() -> Int? {
        scorer.score(placed)
    }

    // MARK: - AI turn

    /// Compute the AI's move on a background queue (generation can take a
    /// moment on a crowded board), then apply it on the main queue. The
    /// player's PLAY button is disabled while this runs, so `committed` and
    /// the bag can't change underneath the computation.
    private func startAITurn() {
        guard !aiRack.isEmpty else {
            aiMessage = "AI has no tiles — passed"
            return
        }
        isAIThinking = true
        aiMessage = nil
        let board = committed
        let aiTiles = aiRack
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let move = AIPlayer.bestMove(board: board, rack: aiTiles)
            // Small floor delay so the AI's tiles don't materialize the same
            // instant the player's commit — reads as a turn, not a glitch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.finishAITurn(with: move)
            }
        }
    }

    private func finishAITurn(with move: AIPlayer.Move?) {
        isAIThinking = false
        guard let move else {
            aiMessage = "AI couldn't find a play — passed"
            return
        }
        // The player may have tentatively placed tiles while the AI thought;
        // bounce any that sit on cells the AI's move needs back to the rack.
        for coord in move.placement.keys where placed[coord] != nil {
            returnToRack(from: coord)
        }
        for (coord, tile) in move.placement { committed[coord] = tile }
        for tile in move.placement.values {
            if let idx = aiRack.firstIndex(where: { $0.letter == tile.letter }) {
                aiRack.remove(at: idx)
            }
        }
        aiTotalScore += move.score
        aiRack.append(contentsOf: draw(7 - aiRack.count))
        aiMessage = "AI played \(move.word) +\(move.score)"
    }
}
