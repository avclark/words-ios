import SwiftUI

/// Post-game review sheet: summary up top (best play, biggest miss,
/// points left, average), then my turns one by one, each expandable to
/// the board as it stood with the played tiles (gold) and the best play
/// (green outline). Renders progressively — turns appear as the engine
/// finishes them, behind a clear progress line, never a frozen screen.
struct ReviewView: View {
    @Environment(\.theme) private var theme

    let engine: ReviewEngine
    let opponentName: String

    @Environment(\.dismiss) private var dismiss
    @State private var expandedTurn: Int?

    var body: some View {
        // Diagnostic: every BODY evaluation, with the values it read —
        // discriminates "body never ran" from "body ran, pixels stuck".
        let _ = reviewLog.notice("ReviewView BODY engine=\(String(describing: ObjectIdentifier(engine)), privacy: .public) phase=\(String(describing: engine.phase), privacy: .public) turns=\(engine.turns.count)")
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("GAME REVIEW")
                        .font(theme.typography.font(15, .black))
                        .kerning(1.5)
                        .foregroundStyle(theme.chrome.textPrimary)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(theme.chrome.ink.opacity(0.3))
                    }
                }

                switch engine.phase {
                case .idle, .loading:
                    progressCard("Loading your moves…", fraction: nil)
                case .computing(let done, let total):
                    summaryGrid
                    progressCard("Analyzing turn \(min(done + 1, total)) of \(total)…",
                                 fraction: Double(done) / Double(max(total, 1)))
                    turnList
                case .done:
                    if engine.turns.isEmpty {
                        Text("No turns to review in this game.")
                            .font(theme.typography.font(14, .regular))
                            .foregroundStyle(theme.chrome.ink.opacity(0.5))
                    } else {
                        summaryGrid
                        turnList
                    }
                case .failed(let message):
                    VStack(spacing: 10) {
                        Text(message)
                            .font(theme.typography.font(14, .regular))
                            .foregroundStyle(theme.chrome.ink.opacity(0.6))
                            .multilineTextAlignment(.center)
                        Button("Try again") {
                            Task { await engine.run() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.chrome.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(20)
        }
        .background(theme.chrome.screenBackground.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationBackground(theme.chrome.screenBackground)
        .onAppear {
            reviewLog.notice("ReviewView onAppear (UIKit appearance)")
        }
        .task {
            reviewLog.notice("ReviewView task START")
            // Definitions back the missed-word lines; normally warmed at
            // game open, this is a harmless belt-and-braces for a review
            // opened straight from a cold lobby restore.
            Definitions.warmUp()
            await engine.run()
        }
    }

    // MARK: - Summary

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())],
                  spacing: 10) {
            summaryCard("BEST PLAY",
                        engine.bestPlay.map { "\($0.playedWord ?? "—") +\($0.playedScore)" } ?? "—",
                        detail: engine.bestPlay.map { "turn \($0.turnLabel)" })
            summaryCard("BIGGEST MISS",
                        engine.biggestMiss.map { "\($0.bestWord ?? "—") +\($0.bestScore)" } ?? "None!",
                        detail: engine.biggestMiss.map { "turn \($0.turnLabel) — you played +\($0.playedScore)" }
                            ?? "you found every best play")
            summaryCard("LEFT ON TABLE", "\(engine.pointsLeft) pts",
                        detail: engine.analyzedTurns.isEmpty ? nil : "across \(engine.analyzedTurns.count) turns")
            summaryCard("AVG PER TURN", "\(engine.averagePerTurn) pts", detail: nil)
        }
    }

    private func summaryCard(_ label: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(theme.typography.font(9, .heavy))
                .kerning(1)
                .foregroundStyle(theme.chrome.ink.opacity(0.4))
            Text(value)
                .font(theme.typography.font(17, .black))
                .foregroundStyle(theme.chrome.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.chrome.ink.opacity(0.45))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: theme.metrics.cardCornerRadius, style: .continuous)
                .fill(theme.chrome.cardFill)
        )
    }

    private func progressCard(_ text: String, fraction: Double?) -> some View {
        VStack(spacing: 8) {
            if let fraction {
                ProgressView(value: fraction)
                    .tint(theme.chrome.accent)
            } else {
                ProgressView()
                    .tint(theme.chrome.accent)
            }
            Text(text)
                .font(theme.typography.font(12, .semibold))
                .foregroundStyle(theme.chrome.ink.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: theme.metrics.cardCornerRadius, style: .continuous)
                .fill(theme.chrome.ink.opacity(0.05))
        )
    }

    // MARK: - Turns

    private var turnList: some View {
        VStack(spacing: 8) {
            ForEach(engine.turns) { turn in
                turnRow(turn)
            }
            if engine.turnsWithRackUnknown > 0 {
                Text("\(engine.turnsWithRackUnknown) turn\(engine.turnsWithRackUnknown == 1 ? " was" : "s were") played before rack history existed, so no best play can be computed for \(engine.turnsWithRackUnknown == 1 ? "it" : "them").")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.chrome.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
    }

    private func turnRow(_ turn: ReviewEngine.TurnReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    expandedTurn = expandedTurn == turn.id ? nil : turn.id
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Text("T\(turn.turnLabel)")
                        .font(theme.typography.font(12, .heavy))
                        .foregroundStyle(theme.chrome.ink.opacity(0.4))
                        .frame(width: 28, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(playedLine(turn))
                            .font(theme.typography.font(14, .semibold))
                            .foregroundStyle(theme.chrome.textPrimary)
                        Text(bestLine(turn))
                            .font(theme.typography.font(12, .regular))
                            .foregroundStyle(turn.foundBest ? theme.semantic.validMove.opacity(0.85)
                                             : theme.chrome.ink.opacity(0.5))
                        // The word you missed, defined — same bundled
                        // source and lookup path as tap-to-define, incl.
                        // inflections; ENABLE-only words say so honestly.
                        if let word = missedBestWord(turn) {
                            if let definition = Definitions.lookup(word) {
                                Text(definition.components(separatedBy: " | ").first ?? definition)
                                    .font(theme.typography.font(11, .regular))
                                    .foregroundStyle(theme.chrome.ink.opacity(0.4))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                            } else {
                                Text("A valid word — no definition in our dictionary.")
                                    .font(theme.typography.font(11, .regular))
                                    .foregroundStyle(theme.chrome.textMuted)
                                    .italic()
                            }
                        }
                    }
                    Spacer()
                    if turn.foundBest {
                        Image(systemName: "star.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.chrome.accent)
                    } else if turn.missed > 0 {
                        Text("−\(turn.missed)")
                            .font(theme.typography.font(13, .heavy))
                            .foregroundStyle(theme.chrome.warning.opacity(0.85))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.chrome.ink.opacity(0.3))
                        .rotationEffect(.degrees(expandedTurn == turn.id ? 180 : 0))
                }
            }

            if expandedTurn == turn.id {
                VStack(alignment: .leading, spacing: 8) {
                    MiniBoardView(board: turn.boardBefore,
                                  played: turn.playedPlacement ?? [:],
                                  best: turn.foundBest ? [:] : (turn.bestPlacement ?? [:]))
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                    HStack(spacing: 14) {
                        legend(color: theme.chrome.accent, text: "You played")
                        if !turn.foundBest, turn.bestPlacement != nil {
                            legend(color: theme.semantic.validMove, text: "Best: \(turn.bestWord ?? "") +\(turn.bestScore)")
                        }
                    }
                    if !turn.rack.isEmpty {
                        Text("Rack: \(turn.rack.joined(separator: " "))")
                            .font(theme.typography.font(11, .semibold))
                            .foregroundStyle(theme.chrome.ink.opacity(0.5))
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(theme.metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: theme.metrics.cardCornerRadius, style: .continuous)
                .fill(theme.chrome.ink.opacity(0.05))
        )
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.8))
                .frame(width: 10, height: 10)
            Text(text)
                .font(theme.typography.font(11, .semibold))
                .foregroundStyle(theme.chrome.ink.opacity(0.6))
        }
    }

    private func playedLine(_ turn: ReviewEngine.TurnReview) -> String {
        switch turn.kind {
        case "play": return "You played \(turn.playedWord ?? "a word") +\(turn.playedScore)"
        case "pass": return "You passed"
        case "swap": return "You swapped tiles"
        case "resign": return "You resigned"
        default: return "You moved"
        }
    }

    private func bestLine(_ turn: ReviewEngine.TurnReview) -> String {
        if turn.rackUnknown { return "Rack unknown for this turn" }
        if turn.foundBest { return "That was the best play — nice!" }
        if let best = turn.bestWord {
            return "Best available: \(best) for \(turn.bestScore)"
        }
        return "No play was possible"
    }

    /// The best word the player COULD have played but didn't — the one
    /// whose definition the row shows. Nil when the turn was the best
    /// play (nothing was missed) or no best play is known.
    private func missedBestWord(_ turn: ReviewEngine.TurnReview) -> String? {
        guard !turn.foundBest, !turn.rackUnknown else { return nil }
        return turn.bestWord
    }
}

/// A tiny, inert 15×15 board rendered with Canvas: the base position plus
/// this turn's played tiles (gold) and the best play (green). Purely
/// visual — none of the live board's gesture/zoom machinery, so it can't
/// interfere with invariants 1–4.
struct MiniBoardView: View {
    @Environment(\.theme) private var theme

    let board: [BoardCoord: Tile]
    let played: [BoardCoord: Tile]
    let best: [BoardCoord: Tile]

    var body: some View {
        Canvas { context, size in
            let cell = size.width / 15
            let inset: CGFloat = 0.5

            func rect(_ coord: BoardCoord) -> CGRect {
                CGRect(x: CGFloat(coord.col) * cell + inset,
                       y: CGFloat(coord.row) * cell + inset,
                       width: cell - inset * 2, height: cell - inset * 2)
            }

            func drawTile(_ coord: BoardCoord, _ tile: Tile,
                          fill: Color, textColor: Color) {
                let r = rect(coord)
                context.fill(Path(roundedRect: r, cornerRadius: cell * 0.15),
                             with: .color(fill))
                if let letter = tile.displayLetter {
                    context.draw(
                        Text(String(letter))
                            .font(theme.typography.font(cell * 0.62, .bold))
                            .foregroundColor(textColor),
                        at: CGPoint(x: r.midX, y: r.midY))
                }
            }

            // Empty grid
            for row in 0..<15 {
                for col in 0..<15 {
                    let coord = BoardCoord(row: row, col: col)
                    let r = rect(coord)
                    let premium = PremiumLayout.squares[coord]
                    let color: Color = premium == nil
                        ? theme.chrome.ink.opacity(0.06)
                        : theme.chrome.ink.opacity(0.14)
                    context.fill(Path(roundedRect: r, cornerRadius: cell * 0.15),
                                 with: .color(color))
                }
            }
            // Base position (muted), then this turn's tiles on top.
            for (coord, tile) in board {
                drawTile(coord, tile, fill: theme.chrome.ink.opacity(0.25),
                         textColor: theme.chrome.ink.opacity(0.85))
            }
            for (coord, tile) in played {
                drawTile(coord, tile, fill: theme.chrome.accent,
                         textColor: theme.chrome.onAccent)
            }
            for (coord, tile) in best {
                let r = rect(coord)
                drawTile(coord, tile, fill: theme.semantic.validMove.opacity(0.35),
                         textColor: theme.chrome.ink)
                context.stroke(Path(roundedRect: r, cornerRadius: cell * 0.15),
                               with: .color(theme.semantic.validMove), lineWidth: 1.5)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: theme.metrics.smallCornerRadius, style: .continuous)
                .fill(theme.board.background)
        )
    }
}
