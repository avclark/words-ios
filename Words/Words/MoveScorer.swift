import Foundation

/// Pure scoring/line logic over a snapshot of the committed board, factored
/// out of BoardState so the SAME code path scores the player's live preview,
/// the player's committed move, and every AI candidate — on any thread.
/// (Value type over value-type dictionaries: safe to hand to a background
/// queue.) The logic is unchanged from Phase 1.
struct MoveScorer {
    /// Tiles locked into the board from previous turns.
    let board: [BoardCoord: Tile]

    enum LineCheck {
        case notALine, gapped, ok(horizontal: Bool)
    }

    func tile(at coord: BoardCoord, placement: [BoardCoord: Tile]) -> Tile? {
        placement[coord] ?? board[coord]
    }

    /// Shared line/contiguity check for the score preview and move validation
    /// — one code path so they can never disagree.
    func placementLine(_ placement: [BoardCoord: Tile]) -> LineCheck {
        let coords = Array(placement.keys)
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
            for c in minC...maxC where tile(at: BoardCoord(row: row, col: c), placement: placement) == nil {
                return .gapped
            }
        } else {
            let col = cols.first!
            let minR = rows.min()!, maxR = rows.max()!
            for r in minR...maxR where tile(at: BoardCoord(row: r, col: col), placement: placement) == nil {
                return .gapped
            }
        }
        return .ok(horizontal: horizontal)
    }

    /// The maximal run of occupied cells through `coord` along one axis.
    func wordThrough(_ coord: BoardCoord, horizontal: Bool, placement: [BoardCoord: Tile]) -> [BoardCoord] {
        let dr = horizontal ? 0 : 1
        let dc = horizontal ? 1 : 0
        var start = coord
        while true {
            let prev = BoardCoord(row: start.row - dr, col: start.col - dc)
            if prev.isValid && tile(at: prev, placement: placement) != nil { start = prev } else { break }
        }
        var cells: [BoardCoord] = []
        var cur = start
        while cur.isValid && tile(at: cur, placement: placement) != nil {
            cells.append(cur)
            cur = BoardCoord(row: cur.row + dr, col: cur.col + dc)
        }
        return cells
    }

    func string(for cells: [BoardCoord], placement: [BoardCoord: Tile]) -> String {
        String(cells.compactMap { tile(at: $0, placement: placement)?.displayLetter })
    }

    /// Score for a tentative placement, or nil if it is not a single
    /// contiguous line. Includes cross-words, premium squares, and the bingo
    /// bonus. Dictionary/connection checks are the caller's job.
    func score(_ placement: [BoardCoord: Tile]) -> Int? {
        guard !placement.isEmpty else { return nil }
        guard case .ok(let horizontal) = placementLine(placement) else { return nil }
        let coords = Array(placement.keys)

        var total = 0
        var scoredMain = false
        let mainWord = wordThrough(coords[0], horizontal: horizontal, placement: placement)
        if mainWord.count > 1 {
            total += score(word: mainWord, placement: placement)
            scoredMain = true
        }
        for coord in coords {
            let cross = wordThrough(coord, horizontal: !horizontal, placement: placement)
            if cross.count > 1 { total += score(word: cross, placement: placement) }
        }
        // A lone tile with no neighbors forms no word yet; preview its face
        // value so the chip isn't blank. (Never a legal play — playMove
        // rejects it.) A lone tile WITH neighbors is fully counted by the
        // main/cross words above; adding its solo run too would double-count.
        if !scoredMain, total == 0, coords.count == 1 {
            total = score(word: mainWord, placement: placement)
        }
        guard scoredMain || total > 0 else { return nil }
        if placement.count == 7 { total += 50 } // bingo
        return total
    }

    private func score(word cells: [BoardCoord], placement: [BoardCoord: Tile]) -> Int {
        var sum = 0
        var wordMultiplier = 1
        for coord in cells {
            guard let tile = tile(at: coord, placement: placement) else { continue }
            var letterScore = tile.points
            // Premiums only apply to tiles placed this turn.
            if placement[coord] != nil, let premium = PremiumLayout.squares[coord] {
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
