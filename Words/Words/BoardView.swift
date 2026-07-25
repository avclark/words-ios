import SwiftUI

/// The 15×15 board. Committed tiles are inert; this-turn tiles can be
/// tapped (return to rack) or dragged (reposition / return). The hover
/// highlight and the live score chip are overlays, so cells stay simple.
struct BoardView: View {
    let state: BoardState
    let drag: DragController
    let metrics: BoardMetrics
    /// The one evaluatePlacement() verdict, computed by GameView per body
    /// evaluation and shared with the Play button — the green word outline
    /// and the score chip/badge below derive from THIS, never from a
    /// second validity check.
    let verdict: BoardState.PlacementVerdict
    /// Phase 12 tap-to-define: a committed (played) tile was tapped.
    var onTapCommitted: ((BoardCoord) -> Void)? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Grid of squares
            VStack(spacing: metrics.spacing) {
                ForEach(0..<15, id: \.self) { row in
                    HStack(spacing: metrics.spacing) {
                        ForEach(0..<15, id: \.self) { col in
                            cell(BoardCoord(row: row, col: col))
                        }
                    }
                }
            }
            .padding(metrics.padding)

            hintOutlines
            playableWordOutline
            hoverHighlight
            scoreChip
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.07, green: 0.1, blue: 0.18))
        )
        // Two-state zoom + pan. Hit-testing inverts this exact transform
        // (see BoardMetrics.cell), so drops stay accurate while zoomed.
        .scaleEffect(drag.zoom, anchor: .topLeading)
        .offset(drag.panOffset)
    }

    // MARK: - Cells

    @ViewBuilder
    private func cell(_ coord: BoardCoord) -> some View {
        ZStack {
            SquareBackground(premium: PremiumLayout.squares[coord],
                             isCenter: coord == .center,
                             size: metrics.cellSize)

            if let tile = state.tile(at: coord) {
                let fresh = state.isPlacedThisTurn(coord)
                let hidden = isBeingDragged(coord)
                TileView(tile: tile,
                         size: metrics.cellSize,
                         isFreshlyPlaced: fresh)
                    .opacity(hidden ? 0 : 1)
                    .scaleEffect(fresh ? 1.0 : 0.98)
                    .transition(.scale(scale: 1.25).combined(with: .opacity))
                    // Committed tiles are inert for DRAGS: touches pass
                    // through so a pan can start on them just like on an
                    // empty square. Their TAPS are caught by the cell
                    // below (tap-to-define) — a tap never moves anything,
                    // so the drag invariants are untouched.
                    // Fresh tiles have NO tap action on purpose: tapping a
                    // pending tile used to recall it, which fired
                    // constantly while rearranging tiles on the board.
                    // Moving a pending tile is a drag; recalling is the
                    // Recall button (or a drag back to the rack).
                    .allowsHitTesting(fresh)
                    .gesture(boardTileDrag(coord)) // no-ops on committed tiles
            }
        }
        .frame(width: metrics.cellSize, height: metrics.cellSize)
        .contentShape(Rectangle())
        // Tap-to-define on played tiles. A TapGesture fails as soon as
        // the finger moves, so board pans starting on a committed tile
        // still reach the pan gesture unharmed.
        .onTapGesture {
            guard state.committed[coord] != nil,
                  !state.isPlacedThisTurn(coord) else { return }
            onTapCommitted?(coord)
        }
    }

    private func isBeingDragged(_ coord: BoardCoord) -> Bool {
        if case let .board(c) = drag.active?.source, c == coord { return true }
        return false
    }

    private func boardTileDrag(_ coord: BoardCoord) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(GameView.spaceName))
            .onChanged { value in
                if drag.active == nil, let tile = state.placed[coord] {
                    drag.began(tile: tile, source: .board(coord), location: value.location, state: state)
                } else {
                    drag.update(location: value.location, state: state)
                }
            }
            .onEnded { _ in
                drag.ended(state: state)
            }
    }

    // MARK: - Overlays

    /// Phase 12 hint type 1: outlines around the cells each suggested
    /// word would occupy — red for the best-scoring option, yellow for
    /// the second best, green for the rest. Hit-test-disabled overlay;
    /// the board underneath is untouched.
    @ViewBuilder
    private var hintOutlines: some View {
        ForEach(Array(state.hintHighlights.enumerated()), id: \.offset) { _, highlight in
            let style = outlineStyle(for: highlight.tier)
            ForEach(highlight.coords, id: \.self) { coord in
                let origin = metrics.cellOrigin(coord)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(style.tint.opacity(style.opacity),
                                  lineWidth: style.lineWidth)
                    .frame(width: metrics.cellSize, height: metrics.cellSize)
                    .offset(x: origin.x, y: origin.y)
                    .allowsHitTesting(false)
            }
        }
        .transition(.opacity)
    }

    private func outlineStyle(for tier: HintHighlight.Tier)
        -> (tint: Color, opacity: Double, lineWidth: CGFloat) {
        switch tier {
        case .best:   (.red, 0.95, 2.5)
        case .second: (.yellow, 0.85, 2.0)
        case .rest:   (.green, 0.7, 1.5)
        }
    }

    @ViewBuilder
    private var hoverHighlight: some View {
        if let cell = drag.hoverCell {
            let origin = metrics.cellOrigin(cell)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.yellow.opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.yellow, lineWidth: 2)
                )
                .frame(width: metrics.cellSize, height: metrics.cellSize)
                .offset(x: origin.x, y: origin.y)
                .animation(.spring(response: 0.18, dampingFraction: 0.85), value: cell)
                .allowsHitTesting(false)
        }
    }

    /// Green outline around the main word once the placement is a legal
    /// move — same presentation-only mechanism as the hint outlines
    /// (hit-test-disabled overlay; the board and any live drag are
    /// untouched). One rounded rect spanning the word's run.
    @ViewBuilder
    private var playableWordOutline: some View {
        if drag.active == nil,
           case .playable(_, let mainWord, _) = verdict,
           let first = mainWord.first, let last = mainWord.last {
            let o1 = metrics.cellOrigin(first)
            let o2 = metrics.cellOrigin(last)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.green.opacity(0.9), lineWidth: 2.5)
                .frame(width: o2.x - o1.x + metrics.cellSize,
                       height: o2.y - o1.y + metrics.cellSize)
                .offset(x: o1.x, y: o1.y)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// The ONE score element, driven by the shared verdict:
    /// while building (not yet playable) it's the neutral running chip
    /// hovering above the placement, exactly as before; once the placement
    /// is a legal move it becomes a green total badge anchored to the END
    /// of the formed word ("this is playable, here's what it scores").
    @ViewBuilder
    private var scoreChip: some View {
        if !state.placed.isEmpty, drag.active == nil {
            if case .playable(_, let mainWord, let score) = verdict,
               let end = mainWord.last {
                let anchor = metrics.cellCenter(end)
                Text("+\(score)")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.green))
                    .position(x: min(anchor.x + metrics.cellSize * 0.9,
                                     metrics.side - 18),
                              y: max(14, anchor.y - metrics.cellSize * 0.9))
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            } else {
                let coords = state.placed.keys
                let minRow = coords.map(\.row).min() ?? 7
                let cols = coords.filter { $0.row == minRow }.map(\.col)
                let midCol = cols.sorted()[cols.count / 2]
                let anchor = metrics.cellCenter(BoardCoord(row: minRow, col: midCol))
                let score = state.currentScore()

                Text(score.map { "+\($0)" } ?? "—")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(score == nil ? Color.white.opacity(0.6) : .black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(score == nil ? Color.white.opacity(0.2) : Color.yellow)
                    )
                    .position(x: anchor.x, y: max(14, anchor.y - metrics.cellSize * 1.1))
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The empty square: premium colors, labels, center star.
private struct SquareBackground: View {
    let premium: Premium?
    let isCenter: Bool
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
            .fill(color)
            .overlay {
                if isCenter {
                    Image(systemName: "star.fill")
                        .font(.system(size: size * 0.5))
                        .foregroundStyle(.white.opacity(0.9))
                } else if let premium {
                    // Scrabble GO-scale labels: the two letters span ~3/4
                    // of the square so premiums read at full-board zoom.
                    Text(premium.label)
                        .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
    }

    private var color: Color {
        switch premium {
        case .tripleWord: return Color(red: 0.85, green: 0.28, blue: 0.25)
        case .doubleWord: return Color(red: 0.9, green: 0.55, blue: 0.25)
        case .tripleLetter: return Color(red: 0.2, green: 0.5, blue: 0.85)
        case .doubleLetter: return Color(red: 0.35, green: 0.68, blue: 0.85)
        case nil: return Color(red: 0.13, green: 0.17, blue: 0.27)
        }
    }
}
