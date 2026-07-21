import SwiftUI

/// The tile itself: ivory face, letter, point value. One component used
/// everywhere — rack, board, floating drag layer — so the look stays
/// consistent and restyling later is a one-file job.
struct TileView: View {
    let tile: Tile
    var size: CGFloat = 44
    var isGhost: Bool = false        // dimmed placeholder (e.g., dragged rack slot)
    var isFreshlyPlaced: Bool = false // this turn's tiles get a gold tint

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(faceColor)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.55), .black.opacity(0.15)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.35), radius: size * 0.06, y: size * 0.05)

            if let letter = tile.displayLetter {
                Text(String(letter))
                    .font(.system(size: size * 0.62, weight: .heavy, design: .rounded))
                    .foregroundStyle(tile.isBlank ? Color(red: 0.72, green: 0.45, blue: 0.1) : .black.opacity(0.88))
                    .minimumScaleFactor(0.7)
            } else {
                // Unassigned blank
                Text("?")
                    .font(.system(size: size * 0.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black.opacity(0.35))
            }

            if tile.points > 0 {
                Text("\(tile.points)")
                    .font(.system(size: max(7, size * 0.24), weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.65))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(size * 0.05)
            }
        }
        .frame(width: size, height: size)
        .opacity(isGhost ? 0.25 : 1)
    }

    private var faceColor: Color {
        if isFreshlyPlaced {
            return Color(red: 0.98, green: 0.84, blue: 0.42) // gold: this turn's tiles
        }
        return Color(red: 0.96, green: 0.93, blue: 0.85) // ivory
    }
}

/// Scrabble GO-style letter grid shown when a blank tile lands on the board.
struct BlankPickerView: View {
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
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color(red: 0.96, green: 0.93, blue: 0.85))
                            .foregroundStyle(.black.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .presentationDetents([.medium])
    }
}
