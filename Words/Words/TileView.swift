import SwiftUI

/// The tile CONTAINER — the theme-agnostic shell used everywhere a tile
/// appears (rack, board, floating drag layer). It owns the frame, the
/// hit shape, and the ghost treatment; call sites attach gestures and
/// positioning to it. What's drawn INSIDE comes from the current theme
/// (`theme.tileContent`), so themes can restyle or fully re-render the
/// tile face while the container — and therefore every gesture,
/// hit-test, and coordinate — stays identical across themes.
struct TileView: View {
    @Environment(\.theme) private var theme

    let tile: Tile
    var size: CGFloat = 44
    var isGhost: Bool = false        // dimmed placeholder (e.g., dragged rack slot)
    var isFreshlyPlaced: Bool = false // this turn's tiles get a gold tint

    var body: some View {
        theme.tileContent(tile: tile, size: size, isFreshlyPlaced: isFreshlyPlaced)
            .frame(width: size, height: size)
            // The container defines the hit area, not the theme's content:
            // a theme drawing a smaller or oddly-shaped face must not
            // change where a drag can start.
            .contentShape(Rectangle())
            .opacity(isGhost ? 0.25 : 1)
    }
}

/// Scrabble GO-style letter grid shown when a blank tile lands on the board.
struct BlankPickerView: View {
    @Environment(\.theme) private var theme

    let onPick: (Character) -> Void

    private let letters: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        VStack(spacing: 16) {
            Text("Choose a letter")
                .font(.headline)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(letters, id: \.self) { letter in
                    Button {
                        onPick(letter)
                    } label: {
                        Text(String(letter))
                            .font(theme.typography.font(20, .heavy))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(theme.tile.face)
                            .foregroundStyle(.black.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.smallCornerRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .presentationDetents([.medium])
    }
}
