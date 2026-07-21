import SwiftUI

/// The 15×15 board. Committed tiles are inert; this-turn tiles can be
/// tapped (return to rack) or dragged (reposition / return). The hover
/// highlight and the live score chip are overlays, so cells stay simple.
struct BoardView: View {
    let state: BoardState
    let drag: DragController
    let metrics: BoardMetrics

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
                    .onTapGesture {
                        guard fresh else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            state.returnToRack(from: coord)
                        }
                        drag.refreshZoom(state: state)
                    }
                    .gesture(boardTileDrag(coord)) // no-ops on committed tiles
            }
        }
        .frame(width: metrics.cellSize, height: metrics.cellSize)
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

    /// Live score bubble hovering above the current placement, like
    /// Scrabble GO's. Grey when the placement isn't a scorable line.
    @ViewBuilder
    private var scoreChip: some View {
        if !state.placed.isEmpty, drag.active == nil {
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
                    Text(premium.label)
                        .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
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
