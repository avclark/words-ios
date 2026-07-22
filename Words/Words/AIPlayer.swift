import Foundation

/// AI opponent move generator.
///
/// Approach: Appel–Jacobson anchor-based generation ("The World's Fastest
/// Scrabble Program", 1988) over a prefix trie of the lexicon:
///
///  - Plays are seeded only at ANCHORS (empty cells adjacent to existing
///    tiles; the center square on an empty board) — never brute-forced
///    across all 225 board positions.
///  - The trie prunes the rack search: a partial letter sequence that can't
///    extend to any dictionary word is abandoned immediately, which keeps
///    blanks (which branch up to 26 ways) tractable.
///  - CROSS-CHECK sets — the letters legal on each empty cell given the
///    perpendicular word they would form — are precomputed, so cross-word
///    validity is enforced *during* generation instead of filtered after.
///  - Vertical plays come from transposing the board and rerunning the
///    horizontal generator. (The old Replit version could only play
///    horizontally; this fixes that.)
///  - A blank is tried as every letter the trie and cross-checks allow —
///    never hardcoded to "A" (the other Replit bug). When the rack has both
///    the real letter and a blank, the real letter is used (same word, more
///    points, saves the blank).
///
/// Tradeoff: the trie costs a couple of seconds and tens of MB to build,
/// ONCE, on a background queue at game start (see warmUp). Each turn's
/// generation is then milliseconds, and every emitted candidate is legal by
/// construction. Candidates are scored with the shared MoveScorer — the same
/// code path that scores the player — and the highest-scoring play wins.
enum AIPlayer {

    struct Move {
        let placement: [BoardCoord: Tile]
        let word: String
        let score: Int
    }

    /// Kick off the one-time trie build so it's ready before the first AI turn.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = trie }
    }

    /// The highest-scoring legal move, or nil if the AI cannot play.
    /// Pure function of value-type snapshots — safe on any thread.
    static func bestMove(board: [BoardCoord: Tile], rack: [Tile]) -> Move? {
        let scorer = MoveScorer(board: board)
        var best: Move?
        for transposed in [false, true] {
            let generator = Generator(board: board, rack: rack, transposed: transposed)
            generator.run { placement, word in
                guard let score = scorer.score(placement) else {
                    assertionFailure("Generator emitted an unscorable placement: \(word)")
                    return
                }
                if score > (best?.score ?? Int.min) {
                    best = Move(placement: placement, word: word, score: score)
                }
            }
        }
        return best
    }

    // MARK: - Trie

    private final class TrieNode {
        var children: [Character: TrieNode] = [:]
        var isWord = false
    }

    private static let trie: TrieNode = {
        let root = TrieNode()
        for word in Lexicon.words {
            var node = root
            for ch in word {
                if let next = node.children[ch] {
                    node = next
                } else {
                    let next = TrieNode()
                    node.children[ch] = next
                    node = next
                }
            }
            node.isWord = true
        }
        return root
    }()

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    // MARK: - Generator (one orientation per instance)

    /// Generates every legal horizontal play on `grid`. For vertical plays
    /// the board is transposed at init and coordinates are mapped back when
    /// a play is recorded.
    private final class Generator {
        private let transposed: Bool
        private var grid: [[Character?]]
        /// Rack as a multiset: letter counts plus a blank count.
        private var counts: [Character: Int] = [:]
        private var blanks = 0
        private var anchors: Set<Int> = []
        /// Allowed letters per empty cell that has perpendicular neighbors.
        /// Absent key = no perpendicular word forms, any letter is fine.
        private var crossChecks: [Int: Set<Character>] = [:]

        // Search state for the current anchor.
        private var emit: (([BoardCoord: Tile], String) -> Void)!
        private var row = 0
        private var anchorCol = 0
        private var partial: [Character] = []
        private var usedTiles: [Tile] = []

        init(board: [BoardCoord: Tile], rack: [Tile], transposed: Bool) {
            self.transposed = transposed
            grid = Array(repeating: [Character?](repeating: nil, count: 15), count: 15)
            for (coord, tile) in board {
                let r = transposed ? coord.col : coord.row
                let c = transposed ? coord.row : coord.col
                // Committed blanks carry their assigned letter in displayLetter.
                grid[r][c] = tile.displayLetter
            }
            for tile in rack {
                if tile.isBlank { blanks += 1 } else { counts[tile.letter, default: 0] += 1 }
            }
            computeAnchorsAndCrossChecks(boardEmpty: board.isEmpty)
        }

        func run(emit: @escaping ([BoardCoord: Tile], String) -> Void) {
            guard blanks > 0 || !counts.isEmpty else { return }
            self.emit = emit
            for anchor in anchors {
                row = anchor / 15
                anchorCol = anchor % 15
                partial = []
                usedTiles = []
                if anchorCol > 0, grid[row][anchorCol - 1] != nil {
                    // Existing tiles directly left of the anchor form a fixed
                    // prefix: descend the trie through them, then extend.
                    var start = anchorCol - 1
                    while start > 0, grid[row][start - 1] != nil { start -= 1 }
                    var node = AIPlayer.trie
                    var prefixAlive = true
                    for c in start..<anchorCol {
                        guard let next = node.children[grid[row][c]!] else {
                            prefixAlive = false
                            break
                        }
                        node = next
                        partial.append(grid[row][c]!)
                    }
                    if prefixAlive {
                        extendRight(node: node, col: anchorCol)
                    }
                } else {
                    // Build left parts from the rack over the empty,
                    // non-anchor cells to the left. Stopping at the previous
                    // anchor also guarantees each play is generated from
                    // exactly one anchor (no duplicates).
                    var limit = 0
                    var c = anchorCol - 1
                    while c >= 0, grid[row][c] == nil, !anchors.contains(row * 15 + c) {
                        limit += 1
                        c -= 1
                    }
                    leftPart(node: AIPlayer.trie, limit: limit)
                }
            }
        }

        private func computeAnchorsAndCrossChecks(boardEmpty: Bool) {
            if boardEmpty {
                // First move: everything routes through the center square.
                anchors = [7 * 15 + 7]
                return
            }
            for r in 0..<15 {
                for c in 0..<15 where grid[r][c] == nil {
                    let neighbors: [(Int, Int)] = [(r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)]
                    var adjacent = false
                    for (nr, nc) in neighbors {
                        guard nr >= 0, nr < 15, nc >= 0, nc < 15 else { continue }
                        if grid[nr][nc] != nil { adjacent = true }
                    }
                    if adjacent { anchors.insert(r * 15 + c) }

                    // Cross-check: letters that keep the vertical run through
                    // this cell a dictionary word.
                    var above = "", below = ""
                    var rr = r - 1
                    while rr >= 0, let ch = grid[rr][c] {
                        above = String(ch) + above
                        rr -= 1
                    }
                    rr = r + 1
                    while rr < 15, let ch = grid[rr][c] {
                        below.append(ch)
                        rr += 1
                    }
                    if !above.isEmpty || !below.isEmpty {
                        var allowed = Set<Character>()
                        for letter in AIPlayer.alphabet where Lexicon.contains(above + String(letter) + below) {
                            allowed.insert(letter)
                        }
                        crossChecks[r * 15 + c] = allowed
                    }
                }
            }
        }

        /// Try every rack-built prefix (up to `limit` letters) ending just
        /// before the anchor, extending right from the anchor after each.
        private func leftPart(node: TrieNode, limit: Int) {
            extendRight(node: node, col: anchorCol)
            guard limit > 0 else { return }
            for (letter, child) in node.children {
                guard let tile = take(letter) else { continue }
                partial.append(letter)
                usedTiles.append(tile)
                leftPart(node: child, limit: limit - 1)
                usedTiles.removeLast()
                partial.removeLast()
                give(back: tile)
            }
        }

        /// Walk rightward from `col`, consuming existing tiles for free and
        /// spending rack tiles on empty cells, recording every completed word.
        private func extendRight(node: TrieNode, col: Int) {
            let cellIsEmptyOrEdge = col > 14 || grid[row][col] == nil
            // A word only counts if it used a rack tile, covered the anchor
            // (col > anchorCol ⇒ the anchor cell was filled), and doesn't run
            // straight into an existing tile.
            if node.isWord, col > anchorCol, !usedTiles.isEmpty, cellIsEmptyOrEdge {
                record(endingBefore: col)
            }
            guard col <= 14 else { return }
            if let existing = grid[row][col] {
                if let child = node.children[existing] {
                    partial.append(existing)
                    extendRight(node: child, col: col + 1)
                    partial.removeLast()
                }
            } else {
                let allowed = crossChecks[row * 15 + col]
                for (letter, child) in node.children {
                    if let allowed, !allowed.contains(letter) { continue }
                    guard let tile = take(letter) else { continue }
                    partial.append(letter)
                    usedTiles.append(tile)
                    extendRight(node: child, col: col + 1)
                    usedTiles.removeLast()
                    partial.removeLast()
                    give(back: tile)
                }
            }
        }

        private func record(endingBefore col: Int) {
            let start = col - partial.count
            var placement: [BoardCoord: Tile] = [:]
            var used = 0
            for (i, _) in partial.enumerated() {
                let c = start + i
                guard grid[row][c] == nil else { continue }
                // Empty cells consume usedTiles in order: both leftPart and
                // extendRight place tiles strictly left-to-right.
                let tile = usedTiles[used]
                used += 1
                let coord = transposed ? BoardCoord(row: c, col: row)
                                       : BoardCoord(row: row, col: c)
                placement[coord] = tile
            }
            assert(used == usedTiles.count, "Tile bookkeeping out of sync")
            emit(placement, String(partial))
        }

        /// Take a tile for `letter` from the rack: real tile first, else a
        /// blank assigned to that letter. Returns nil if neither is available.
        private func take(_ letter: Character) -> Tile? {
            if let n = counts[letter], n > 0 {
                counts[letter] = n - 1
                return Tile(letter: letter)
            }
            if blanks > 0 {
                blanks -= 1
                return Tile(letter: "?", assignedLetter: letter)
            }
            return nil
        }

        private func give(back tile: Tile) {
            if tile.isBlank { blanks += 1 } else { counts[tile.letter, default: 0] += 1 }
        }
    }
}
