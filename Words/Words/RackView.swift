import SwiftUI

/// The tile rack. Supports:
///  • dragging a tile out to the board,
///  • dragging within the rack to reorder (neighbors part to open a gap),
///  • receiving tiles dragged back from the board.
struct RackView: View {
    let state: BoardState
    let drag: DragController

    var tileSize: CGFloat = 46
    private let spacing: CGFloat = 7

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(slots) { slot in
                switch slot.kind {
                case .gap:
                    Color.clear
                        .frame(width: tileSize, height: tileSize)
                case .tile(let tile, let style):
                    TileView(tile: tile, size: tileSize, isGhost: style == .ghost)
                        // Hidden, not removed: the dragged tile's view must
                        // survive the whole gesture (see slots below).
                        .opacity(style == .hidden ? 0 : 1)
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
        enum TileStyle {
            case normal
            case ghost   // dim placeholder (dragged tile, not hovering the rack)
            case hidden  // invisible — this slot IS the open gap
        }
        enum Kind {
            case tile(Tile, style: TileStyle)
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
        let hoverIndex: Int? = drag.active != nil ? drag.rackProposedIndex : nil

        if let draggedID = draggedRackTileID,
           let from = state.rack.firstIndex(where: { $0.id == draggedID }) {
            // A rack tile is in hand. Its slot stays in the row for the whole
            // gesture and doubles as the gap: invisible at the proposed drop
            // index while hovering, a dim ghost at its original index
            // otherwise. Two constraints hang on this:
            //  • the tile's view is never removed mid-gesture (invariant 2 —
            //    removal kills the drag), and
            //  • slot count always equals the rack count, so a full rack can
            //    never overflow its layout.
            var order = state.rack
            let dragged = order.remove(at: from)
            let gapIndex = min(hoverIndex ?? from, order.count)
            order.insert(dragged, at: gapIndex)
            return order.map { tile in
                Slot(id: tile.id.uuidString,
                     kind: .tile(tile, style: tile.id != draggedID ? .normal
                                        : hoverIndex != nil ? .hidden : .ghost))
            }
        }

        var result = state.rack.map {
            Slot(id: $0.id.uuidString, kind: .tile($0, style: .normal))
        }
        // A board tile hovering the rack opens an inserted gap. The rack
        // holds at most 6 tiles whenever a placed tile exists, so this never
        // exceeds the 7-slot layout.
        if let hoverIndex {
            result.insert(Slot(id: "gap", kind: .gap),
                          at: min(max(hoverIndex, 0), result.count))
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
