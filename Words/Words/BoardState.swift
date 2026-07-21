import SwiftUI
import Observation

/// All game state for the prototype. Local-only — no networking. The demo
/// board starts with two committed words so cross-word placement, adjacency,
/// and premium squares can be exercised immediately.
@Observable
final class BoardState {
    /// Tiles locked into the board from previous turns.
    private(set) var committed: [BoardCoord: Tile] = [:]
    /// Tiles tentatively placed this turn (still movable/recallable).
    private(set) var placed: [BoardCoord: Tile] = [:]
    /// The player's rack, left to right.
    private(set) var rack: [Tile] = []

    /// Set when a blank tile lands on the board and needs a letter.
    var pendingBlank: BoardCoord?

    init() {
        setupDemo()
    }

    func setupDemo() {
        committed = [:]
        placed = [:]
        pendingBlank = nil
        // "WORDS" across the center, "GAME" crossing it at the S.
        let words = "WORDS"
        for (i, ch) in words.enumerated() {
            committed[BoardCoord(row: 7, col: 5 + i)] = Tile(letter: ch)
        }
        let game = "GAME"
        // G-A-M-E vertically, sharing no cell; crosses next to S for adjacency tests.
        for (i, ch) in game.enumerated() {
            committed[BoardCoord(row: 4 + i, col: 9)] = Tile(letter: ch)
        }
        rack = ["T", "E", "A", "R", "S", "?", "L"].map { Tile(letter: $0) }
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
        let tile = rack.remove(at: idx)
        placed[coord] = tile
        if tile.isBlank { pendingBlank = coord }
    }

    func moveOnBoard(from: BoardCoord, to: BoardCoord) {
        guard from != to, let tile = placed[from], !isOccupied(to) else {
            // Invalid target: tile snaps back to where it was (handled by caller animation).
            return
        }
        placed.removeValue(forKey: from)
        placed[to] = tile
        if pendingBlank == from { pendingBlank = to }
    }

    /// Lift a placed tile off the board into the player's hand (drag start).
    func lift(from coord: BoardCoord) -> Tile? {
        guard let tile = placed[coord] else { return nil }
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

    /// Locks the current placement into the board so you can keep building
    /// words on top of it. No dictionary validation in the prototype.
    func commitTurn() {
        guard pendingBlank == nil, currentScore() != nil else { return }
        for (coord, tile) in placed { committed[coord] = tile }
        placed = [:]
        refillRack()
    }

    private func refillRack() {
        let pool = "EEEEAAAIIOONNRRTTLSUDG?BCMPFHVWY"
        while rack.count < 7, let ch = pool.randomElement() {
            rack.append(Tile(letter: ch))
        }
    }

    // MARK: - Live score preview

    /// Score for the tiles placed this turn, or nil if the placement is not
    /// a single contiguous line (Scrabble GO greys the score chip out then).
    /// Includes cross-words and premium squares. Dictionary checks are out of
    /// scope for the prototype.
    func currentScore() -> Int? {
        guard !placed.isEmpty else { return nil }
        let coords = Array(placed.keys)
        let rows = Set(coords.map(\.row))
        let cols = Set(coords.map(\.col))
        let horizontal: Bool
        if coords.count == 1 { horizontal = true }
        else if rows.count == 1 { horizontal = true }
        else if cols.count == 1 { horizontal = false }
        else { return nil }

        // Contiguity: every cell between the extremes must hold a tile.
        if horizontal, rows.count == 1 {
            let row = rows.first!
            let minC = cols.min()!, maxC = cols.max()!
            for c in minC...maxC where tile(at: BoardCoord(row: row, col: c)) == nil { return nil }
        } else if !horizontal {
            let col = cols.first!
            let minR = rows.min()!, maxR = rows.max()!
            for r in minR...maxR where tile(at: BoardCoord(row: r, col: col)) == nil { return nil }
        }

        var total = 0
        var scoredMain = false
        let mainWord = wordThrough(coords[0], horizontal: horizontal)
        if mainWord.count > 1 || coords.count == 1 {
            total += score(word: mainWord)
            scoredMain = true
        }
        for coord in coords {
            let cross = wordThrough(coord, horizontal: !horizontal)
            if cross.count > 1 { total += score(word: cross) }
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
