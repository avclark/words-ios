import SwiftUI

/// The tile rack. Supports:
///  • dragging a tile out to the board,
///  • dragging within the rack to reorder (neighbors part to open a gap),
///  • receiving tiles dragged back from the board.
struct RackView: View {
    let state: BoardState
    let drag: DragController

    private let tileSize: CGFloat = 46
    private let spacing: CGFloat = 7

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(slots) { slot in
                switch slot.kind {
                case .gap:
                    Color.clear
                        .frame(width: tileSize, height: tileSize)
                case .tile(let tile, let hidden):
                    TileView(tile: tile, size: tileSize, isGhost: hidden)
                        .gesture(rackDrag(tile: tile))
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: slotSignature)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.1, green: 0.13, blue: 0.22))
        )
    }

    // MARK: - Slots (tiles + a gap while a drag hovers the rack)

    private struct Slot: Identifiable {
        enum Kind {
            case tile(Tile, hidden: Bool)
            case gap
        }
        let id: String
        let kind: Kind
    }

    private var draggedRackTileID: Tile.ID? {
        if case let .rack(id) = drag.active?.source { return id }
        return nil
    }

    private var slots: [Slot] {
        var result: [Slot] = []
        let draggedID = draggedRackTileID

        // Visual order excludes the tile currently in hand…
        var order = state.rack
        if let draggedID {
            order.removeAll { $0.id == draggedID }
        }
        // …and shows an open gap at the proposed drop position.
        if let gapIndex = drag.rackProposedIndex, drag.active != nil {
            let clamped = min(max(gapIndex, 0), order.count)
            for (i, tile) in order.enumerated() {
                if i == clamped { result.append(Slot(id: "gap", kind: .gap)) }
                result.append(Slot(id: tile.id.uuidString, kind: .tile(tile, hidden: false)))
            }
            if clamped == order.count { result.append(Slot(id: "gap", kind: .gap)) }
        } else {
            // No hover: dragged tile's original slot stays as a dim ghost.
            for tile in state.rack {
                result.append(Slot(
                    id: tile.id.uuidString,
                    kind: .tile(tile, hidden: tile.id == draggedID)
                ))
            }
        }
        return result
    }

    /// Cheap value the spring animation can key on.
    private var slotSignature: String {
        slots.map(\.id).joined(separator: ",")
    }

    // MARK: - Gesture

    private func rackDrag(tile: Tile) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(GameView.spaceName))
            .onChanged { value in
                if drag.active == nil {
                    drag.began(tile: tile, source: .rack(tile.id), location: value.location, state: state)
                } else {
                    drag.update(location: value.location, state: state)
                }
            }
            .onEnded { _ in
                drag.ended(state: state)
            }
    }
}
