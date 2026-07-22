import SwiftUI

/// Placeholder tile-swap sheet. Unstyled on purpose — design pass later.
struct SwapView: View {
    let rack: [Tile]
    let bagCount: Int
    let onSwap: (Set<Tile.ID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Tile.ID> = []

    var body: some View {
        VStack(spacing: 24) {
            Text("Select tiles to swap")
                .font(.headline)
            Text("Bag has \(bagCount) tiles")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(rack) { tile in
                    Button {
                        if selected.contains(tile.id) {
                            selected.remove(tile.id)
                        } else {
                            selected.insert(tile.id)
                        }
                    } label: {
                        Text(String(tile.letter))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .frame(width: 40, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selected.contains(tile.id) ? Color.yellow : Color.gray.opacity(0.3))
                            )
                            .foregroundStyle(selected.contains(tile.id) ? .black : .primary)
                    }
                }
            }

            Button("Swap \(selected.count) tile\(selected.count == 1 ? "" : "s")") {
                onSwap(selected)
                dismiss()
            }
            .disabled(selected.isEmpty || selected.count > bagCount)
            .buttonStyle(.borderedProminent)

            Button("Cancel") { dismiss() }
        }
        .padding()
        .presentationDetents([.medium])
    }
}

/// Placeholder game-over screen, shown as an overlay so the board hierarchy
/// underneath is never torn down (see CLAUDE.md invariant 2).
struct GameOverView: View {
    let summary: GameOverSummary
    let localName: String
    let opponentName: String
    let onHome: () -> Void
    let onNewGame: () -> Void

    private var winnerText: String {
        if summary.localFinal > summary.opponentFinal { return "You win!" }
        if summary.localFinal < summary.opponentFinal { return "\(opponentName) wins" }
        return "It's a tie"
    }

    private var reasonText: String {
        switch summary.reason {
        case .localEmptied: return "You played all your tiles"
        case .opponentEmptied: return "\(opponentName) played all their tiles"
        case .sixPasses: return "Six passes in a row"
        case .resigned: return "The game ended by resignation"
        }
    }

    private var adjustmentText: String {
        switch summary.reason {
        case .localEmptied:
            return "You gain +\(summary.opponentLeftover) from \(opponentName)'s leftover tiles (\(opponentName) −\(summary.opponentLeftover))"
        case .opponentEmptied:
            return "\(opponentName) gains +\(summary.localLeftover) from your leftover tiles (you −\(summary.localLeftover))"
        case .sixPasses:
            return "Leftover tiles: you −\(summary.localLeftover), \(opponentName) −\(summary.opponentLeftover)"
        case .resigned:
            return "Final scores as they stood"
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("GAME OVER")
                .font(.system(size: 28, weight: .black, design: .rounded))
            Text(reasonText)
                .foregroundStyle(.secondary)
            Text(winnerText)
                .font(.title)
            Text("\(localName) \(summary.localFinal) — \(opponentName) \(summary.opponentFinal)")
                .font(.title3)
            Text(adjustmentText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("New Game", action: onNewGame)
                .buttonStyle(.borderedProminent)
            Button("Home", action: onHome)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.88).ignoresSafeArea())
    }
}
