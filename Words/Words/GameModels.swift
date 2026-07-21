import SwiftUI

// MARK: - Core types

struct Tile: Identifiable, Equatable {
    let id = UUID()
    /// The rack letter. "?" means a blank tile.
    var letter: Character
    /// For blanks: the letter the player assigned when placing it.
    var assignedLetter: Character?

    var isBlank: Bool { letter == "?" }
    var displayLetter: Character? { isBlank ? assignedLetter : letter }
    var points: Int { isBlank ? 0 : LetterValues.points[letter, default: 0] }
}

struct BoardCoord: Hashable, Equatable {
    var row: Int
    var col: Int

    var isValid: Bool { row >= 0 && row < 15 && col >= 0 && col < 15 }
    static let center = BoardCoord(row: 7, col: 7)
}

enum Premium {
    case tripleWord, doubleWord, tripleLetter, doubleLetter

    var label: String {
        switch self {
        case .tripleWord: return "TW"
        case .doubleWord: return "DW"
        case .tripleLetter: return "TL"
        case .doubleLetter: return "DL"
        }
    }
}

// MARK: - Letter data

enum LetterValues {
    static let points: [Character: Int] = [
        "A": 1, "B": 3, "C": 3, "D": 2, "E": 1, "F": 4, "G": 2, "H": 4, "I": 1,
        "J": 8, "K": 5, "L": 1, "M": 3, "N": 1, "O": 1, "P": 3, "Q": 10, "R": 1,
        "S": 1, "T": 1, "U": 1, "V": 4, "W": 4, "X": 8, "Y": 4, "Z": 10,
    ]
}

// MARK: - Premium square layout (standard Scrabble board)

enum PremiumLayout {
    static let squares: [BoardCoord: Premium] = {
        var map: [BoardCoord: Premium] = [:]
        let tw: [(Int, Int)] = [(0,0),(0,7),(0,14),(7,0),(7,14),(14,0),(14,7),(14,14)]
        let dw: [(Int, Int)] = [(1,1),(2,2),(3,3),(4,4),(1,13),(2,12),(3,11),(4,10),
                                (10,4),(11,3),(12,2),(13,1),(10,10),(11,11),(12,12),(13,13),(7,7)]
        let tl: [(Int, Int)] = [(1,5),(1,9),(5,1),(5,5),(5,9),(5,13),
                                (9,1),(9,5),(9,9),(9,13),(13,5),(13,9)]
        let dl: [(Int, Int)] = [(0,3),(0,11),(2,6),(2,8),(3,0),(3,7),(3,14),
                                (6,2),(6,6),(6,8),(6,12),(7,3),(7,11),
                                (8,2),(8,6),(8,8),(8,12),(11,0),(11,7),(11,14),
                                (12,6),(12,8),(14,3),(14,11)]
        for (r, c) in tw { map[BoardCoord(row: r, col: c)] = .tripleWord }
        for (r, c) in dw { map[BoardCoord(row: r, col: c)] = .doubleWord }
        for (r, c) in tl { map[BoardCoord(row: r, col: c)] = .tripleLetter }
        for (r, c) in dl { map[BoardCoord(row: r, col: c)] = .doubleLetter }
        return map
    }()
}

// MARK: - Board metrics

/// All layout math in one place: cell sizes, cell frames, and point→cell
/// hit-testing. Every coordinate conversion goes through here so the visuals
/// and the drop logic can never disagree — the bug class that killed the
/// previous versions of this app.
struct BoardMetrics: Equatable {
    var cellSize: CGFloat = 0
    var spacing: CGFloat = 2
    var padding: CGFloat = 5

    static let zero = BoardMetrics()

    var side: CGFloat { padding * 2 + cellSize * 15 + spacing * 14 }

    static func fitting(width: CGFloat) -> BoardMetrics {
        var m = BoardMetrics()
        m.cellSize = ((width - m.padding * 2 - m.spacing * 14) / 15).rounded(.down)
        return m
    }

    /// Top-left of a cell in the board's own coordinate space.
    func cellOrigin(_ coord: BoardCoord) -> CGPoint {
        CGPoint(
            x: padding + CGFloat(coord.col) * (cellSize + spacing),
            y: padding + CGFloat(coord.row) * (cellSize + spacing)
        )
    }

    /// Center of a cell in the board's own coordinate space.
    func cellCenter(_ coord: BoardCoord) -> CGPoint {
        let o = cellOrigin(coord)
        return CGPoint(x: o.x + cellSize / 2, y: o.y + cellSize / 2)
    }

    /// The cell containing a point given in the *game* coordinate space.
    /// `zoom`/`offset` describe the board content transform
    /// (visual = layout × zoom + offset, scaled about top-leading), so
    /// hit-testing stays correct while zoomed and panned.
    func cell(at point: CGPoint, boardFrame: CGRect,
              zoom: CGFloat = 1, offset: CGSize = .zero) -> BoardCoord? {
        let q = CGPoint(x: point.x - boardFrame.minX, y: point.y - boardFrame.minY)
        let local = CGPoint(x: (q.x - offset.width) / zoom,
                            y: (q.y - offset.height) / zoom)
        let stride = cellSize + spacing
        let col = Int(((local.x - padding) / stride).rounded(.down))
        let row = Int(((local.y - padding) / stride).rounded(.down))
        let coord = BoardCoord(row: row, col: col)
        return coord.isValid ? coord : nil
    }

    /// Pan offset that centers `layoutPoint` in the board window at `zoom`,
    /// clamped so the board always fills its frame (no gaps past the edges).
    func panOffset(centering layoutPoint: CGPoint, zoom: CGFloat) -> CGSize {
        guard zoom > 1 else { return .zero }
        let raw = CGSize(width: side / 2 - layoutPoint.x * zoom,
                         height: side / 2 - layoutPoint.y * zoom)
        return clampedOffset(raw, zoom: zoom)
    }

    /// Keeps a pan offset within legal bounds for the given zoom.
    func clampedOffset(_ offset: CGSize, zoom: CGFloat) -> CGSize {
        let minOffset = side - side * zoom // ≤ 0
        return CGSize(width: min(max(offset.width, minOffset), 0),
                      height: min(max(offset.height, minOffset), 0))
    }
}
