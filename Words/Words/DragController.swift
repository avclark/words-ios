import SwiftUI
import UIKit
import Observation

/// Single source of truth for the drag interaction.
///
/// THE RULE THAT MUST NEVER BE BROKEN:
/// The floating tile is drawn centered at `visualCenter`, and every
/// hit-test uses that SAME point. Finger position and tile position are
/// the same thing here (Scrabble GO keeps the tile directly under the
/// finger, translucent so the board shows through).
///
/// SECOND RULE (learned from the v1 hang):
/// Never remove the view a gesture is attached to mid-gesture. Board
/// tiles being dragged stay in `state.placed` and are merely hidden;
/// the move is committed only on gesture end.
///
/// ZOOM MODEL: exactly two states — 1.0 (full board) and `placementZoom`
/// (zoomed in). Content transform is visual = layout × zoom + panOffset,
/// scaled about top-leading. `BoardMetrics.cell(at:...)` inverts this
/// same transform, so visuals and hit-testing cannot disagree.
@Observable
final class DragController {

    enum Source: Equatable {
        case rack(Tile.ID)
        case board(BoardCoord)
    }

    struct ActiveDrag {
        var tile: Tile
        var source: Source
        /// Finger location in the "game" coordinate space.
        var location: CGPoint
        var isSettling: Bool = false
    }

    /// Tiny lift so the tile reads as "picked up" while staying under the
    /// finger, per Scrabble GO. Tuning knob.
    static let liftOffset = CGSize(width: 0, height: -12)
    /// Floating tile size — constant and finger-sized, like v1. Tuning knob.
    static let floatingSize: CGFloat = 54
    /// The single zoomed-in level. There are no other zoom states.
    static let placementZoom: CGFloat = 1.7

    var active: ActiveDrag?
    var hoverCell: BoardCoord?
    var rackProposedIndex: Int?

    // Two-state zoom + pan.
    var zoom: CGFloat = 1
    var panOffset: CGSize = .zero
    private var panStart: CGSize?

    // Frames captured from the view layer, all in the "game" space.
    var boardFrame: CGRect = .zero
    var rackFrame: CGRect = .zero
    var metrics: BoardMetrics = .zero

    var isZoomedIn: Bool { zoom > 1 }

    var visualCenter: CGPoint? {
        guard let active else { return nil }
        return CGPoint(
            x: active.location.x + Self.liftOffset.width,
            y: active.location.y + Self.liftOffset.height
        )
    }

    var floatingSize: CGFloat { Self.floatingSize }

    // MARK: - Tile drag entry points

    func began(tile: Tile, source: Source, location: CGPoint, state: BoardState) {
        // Board tiles are NOT lifted out of state — see second rule above.
        active = ActiveDrag(tile: tile, source: source, location: location)
        Haptics.lift()
        update(location: location, state: state)
    }

    func update(location: CGPoint, state: BoardState) {
        guard active != nil, active?.isSettling != true else { return }
        active?.location = location

        guard let center = visualCenter else { return }
        let previousHover = hoverCell
        let sourceCoord: BoardCoord? = {
            if case let .board(c) = active?.source { return c }
            return nil
        }()

        if boardFrame.contains(center),
           let cell = metrics.cell(at: center, boardFrame: boardFrame,
                                   zoom: zoom, offset: panOffset),
           !state.isOccupied(cell) || cell == sourceCoord {
            hoverCell = cell
            rackProposedIndex = nil
        } else if rackFrame.insetBy(dx: -12, dy: -20).contains(location) {
            hoverCell = nil
            rackProposedIndex = rackInsertionIndex(forFingerX: location.x, state: state)
        } else {
            hoverCell = nil
            rackProposedIndex = nil
        }

        if hoverCell != previousHover, hoverCell != nil {
            Haptics.hoverTick()
        }
    }

    func ended(state: BoardState) {
        guard let active, !active.isSettling else { return }

        if let cell = hoverCell {
            switch active.source {
            case .rack(let id):
                state.placeFromRack(tileID: id, at: cell)
            case .board(let origin):
                state.moveOnBoard(from: origin, to: cell) // no-ops if cell == origin
            }
            Haptics.drop()
            clear()
            refreshZoom(state: state)
        } else if let index = rackProposedIndex {
            switch active.source {
            case .rack(let id):
                state.reorderRack(tileID: id, to: index)
            case .board(let origin):
                state.returnToRack(from: origin, insertAt: index)
            }
            Haptics.drop()
            clear()
            refreshZoom(state: state)
        } else {
            switch active.source {
            case .rack:
                settleBackToRack()
            case .board:
                // Tile never left the board; just un-hide it where it was.
                clear()
            }
        }
    }

    func cancelled(state: BoardState) {
        guard let active else { return }
        if case .rack = active.source { settleBackToRack() } else { clear() }
    }

    // MARK: - Zoom & pan (pinch to toggle states, drag to pan when zoomed)

    func zoomIn(centering layoutPoint: CGPoint) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            zoom = Self.placementZoom
            panOffset = metrics.panOffset(centering: layoutPoint, zoom: Self.placementZoom)
        }
        Haptics.hoverTick()
    }

    func zoomOut() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            zoom = 1
            panOffset = .zero
        }
        Haptics.hoverTick()
    }

    /// One-finger pan of the zoomed board (no-op at 1x or during a tile drag).
    func panChanged(translation: CGSize, state: BoardState) {
        guard isZoomedIn, active == nil else { return }
        if panStart == nil { panStart = panOffset }
        let proposed = CGSize(width: (panStart?.width ?? 0) + translation.width,
                              height: (panStart?.height ?? 0) + translation.height)
        panOffset = metrics.clampedOffset(proposed, zoom: zoom)
    }

    func panEnded() {
        panStart = nil
    }

    /// Scrabble GO behavior: dropping a tile zooms the board in around the
    /// placement; clearing/committing the placement zooms back out.
    func refreshZoom(state: BoardState) {
        let coords = Array(state.placed.keys)
        if coords.isEmpty {
            zoomOut()
        } else {
            let cx = coords.map { metrics.cellCenter($0).x }.reduce(0, +) / CGFloat(coords.count)
            let cy = coords.map { metrics.cellCenter($0).y }.reduce(0, +) / CGFloat(coords.count)
            zoomIn(centering: CGPoint(x: cx, y: cy))
        }
    }

    // MARK: - Internals

    private func settleBackToRack() {
        guard active != nil else { return }
        let destination = CGPoint(x: rackFrame.midX,
                                  y: rackFrame.midY - Self.liftOffset.height)
        active?.isSettling = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            active?.location = destination
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            self?.clear()
        }
    }

    private func clear() {
        active = nil
        hoverCell = nil
        rackProposedIndex = nil
    }

    private func rackInsertionIndex(forFingerX x: CGFloat, state: BoardState) -> Int {
        let count = CGFloat(max(state.rack.count, 1))
        let slot = rackFrame.width / count
        guard slot > 0 else { return state.rack.count }
        let idx = Int(((x - rackFrame.minX) / slot).rounded(.down))
        return min(max(idx, 0), state.rack.count)
    }
}

// MARK: - Haptics

enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)

    static func lift() { medium.impactOccurred(intensity: 0.8) }
    static func hoverTick() { light.impactOccurred(intensity: 0.55) }
    static func drop() { rigid.impactOccurred(intensity: 0.9) }
}
