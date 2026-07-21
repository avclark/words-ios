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
        bag = TileDistribution.fullBag().shuffled()
        rack = draw(7)
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
        switch placementLine() {
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
        let main = wordThrough(coords[0], horizontal: horizontal)
        if main.count > 1 { formed.append(main) }
        for coord in coords {
            let cross = wordThrough(coord, horizontal: !horizontal)
            if cross.count > 1 { formed.append(cross) }
        }
        guard !formed.isEmpty else {
            status = .rejected("Words need at least two letters")
            return
        }

        let wordsFormed = formed.map(string(for:))
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

    private func string(for cells: [BoardCoord]) -> String {
        String(cells.compactMap { tile(at: $0)?.displayLetter })
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

    private enum LineCheck {
        case notALine, gapped, ok(horizontal: Bool)
    }

    /// Shared line/contiguity check for the score preview and move validation
    /// — one code path so they can never disagree.
    private func placementLine() -> LineCheck {
        let coords = Array(placed.keys)
        let rows = Set(coords.map(\.row))
        let cols = Set(coords.map(\.col))
        let horizontal: Bool
        if coords.count == 1 { horizontal = true }
        else if rows.count == 1 { horizontal = true }
        else if cols.count == 1 { horizontal = false }
        else { return .notALine }

        // Contiguity: every cell between the extremes must hold a tile
        // (placed this turn or already committed).
        if horizontal {
            let row = rows.first!
            let minC = cols.min()!, maxC = cols.max()!
            for c in minC...maxC where tile(at: BoardCoord(row: row, col: c)) == nil { return .gapped }
        } else {
            let col = cols.first!
            let minR = rows.min()!, maxR = rows.max()!
            for r in minR...maxR where tile(at: BoardCoord(row: r, col: col)) == nil { return .gapped }
        }
        return .ok(horizontal: horizontal)
    }

    /// Score for the tiles placed this turn, or nil if the placement is not
    /// a single contiguous line (Scrabble GO greys the score chip out then).
    /// Includes cross-words and premium squares. Dictionary/connection checks
    /// happen in playMove(), not here — this is just the live preview.
    func currentScore() -> Int? {
        guard !placed.isEmpty else { return nil }
        guard case .ok(let horizontal) = placementLine() else { return nil }
        let coords = Array(placed.keys)

        var total = 0
        var scoredMain = false
        let mainWord = wordThrough(coords[0], horizontal: horizontal)
        if mainWord.count > 1 {
            total += score(word: mainWord)
            scoredMain = true
        }
        for coord in coords {
            let cross = wordThrough(coord, horizontal: !horizontal)
            if cross.count > 1 { total += score(word: cross) }
        }
        // A lone tile with no neighbors forms no word yet; preview its face
        // value so the chip isn't blank. (Never a legal play — playMove
        // rejects it.) A lone tile WITH neighbors is fully counted by the
        // main/cross words above; adding its solo run too would double-count.
        if !scoredMain, total == 0, coords.count == 1 {
            total = score(word: mainWord)
        }
        guard scoredMain || total > 0 else { return nil }
        if placed.count == 7 { total += 50 } // bingo
        return total
    }

    /// The maximal run of occupied cells through `coord` along one axis.
    private func wordThrough(_ coord: BoardCoord, horizontal: Bool) -> [BoardCoord] {
        let dr = horizontal ? 0 : 1
        let dc = horizontal ? 1 : 0
        var start = coord
        while true {
            let prev = BoardCoord(row: start.row - dr, col: start.col - dc)
            if prev.isValid && isOccupied(prev) { start = prev } else { break }
        }
        var cells: [BoardCoord] = []
        var cur = start
        while cur.isValid && isOccupied(cur) {
            cells.append(cur)
            cur = BoardCoord(row: cur.row + dr, col: cur.col + dc)
        }
        return cells
    }

    private func score(word cells: [BoardCoord]) -> Int {
        var sum = 0
        var wordMultiplier = 1
        for coord in cells {
            guard let tile = tile(at: coord) else { continue }
            var letterScore = tile.points
            // Premiums only apply to tiles placed this turn.
            if isPlacedThisTurn(coord), let premium = PremiumLayout.squares[coord] {
                switch premium {
                case .doubleLetter: letterScore *= 2
                case .tripleLetter: letterScore *= 3
                case .doubleWord: wordMultiplier *= 2
                case .tripleWord: wordMultiplier *= 3
                }
            }
            sum += letterScore
        }
        return sum * wordMultiplier
    }
}
