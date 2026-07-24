import SwiftUI

/// Post-game review sheet: summary up top (best play, biggest miss,
/// points left, average), then my turns one by one, each expandable to
/// the board as it stood with the played tiles (gold) and the best play
/// (green outline). Renders progressively — turns appear as the engine
/// finishes them, behind a clear progress line, never a frozen screen.
struct ReviewView: View {
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
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .kerning(1.5)
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.3))
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
                            .font(.system(size: 14, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    } else {
                        summaryGrid
                        turnList
                    }
                case .failed(let message):
                    VStack(spacing: 10) {
                        Text(message)
                            .font(.system(size: 14, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                        Button("Try again") {
                            Task { await engine.run() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.yellow)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(20)
        }
        .background(HomeView.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationBackground(HomeView.background)
        .onAppear {
            reviewLog.notice("ReviewView onAppear (UIKit appearance)")
        }
        .task {
            reviewLog.notice("ReviewView task START")
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
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .kerning(1)
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(.yellow)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func progressCard(_ text: String, fraction: Double?) -> some View {
        VStack(spacing: 8) {
            if let fraction {
                ProgressView(value: fraction)
                    .tint(.yellow)
            } else {
                ProgressView()
                    .tint(.yellow)
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
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
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
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
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 28, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(playedLine(turn))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(bestLine(turn))
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(turn.foundBest ? Color.green.opacity(0.85)
                                             : .white.opacity(0.5))
                    }
                    Spacer()
                    if turn.foundBest {
                        Image(systemName: "star.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.yellow)
                    } else if turn.missed > 0 {
                        Text("−\(turn.missed)")
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                            .foregroundStyle(.orange.opacity(0.85))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
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
                        legend(color: .yellow, text: "You played")
                        if !turn.foundBest, turn.bestPlacement != nil {
                            legend(color: .green, text: "Best: \(turn.bestWord ?? "") +\(turn.bestScore)")
                        }
                    }
                    if !turn.rack.isEmpty {
                        Text("Rack: \(turn.rack.joined(separator: " "))")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.8))
                .frame(width: 10, height: 10)
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
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
}

/// A tiny, inert 15×15 board rendered with Canvas: the base position plus
/// this turn's played tiles (gold) and the best play (green). Purely
/// visual — none of the live board's gesture/zoom machinery, so it can't
/// interfere with invariants 1–4.
struct MiniBoardView: View {
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
                            .font(.system(size: cell * 0.62, weight: .bold, design: .rounded))
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
                        ? Color.white.opacity(0.06)
                        : Color.white.opacity(0.14)
                    context.fill(Path(roundedRect: r, cornerRadius: cell * 0.15),
                                 with: .color(color))
                }
            }
            // Base position (muted), then this turn's tiles on top.
            for (coord, tile) in board {
                drawTile(coord, tile, fill: Color.white.opacity(0.25),
                         textColor: .white.opacity(0.85))
            }
            for (coord, tile) in played {
                drawTile(coord, tile, fill: Color.yellow, textColor: .black)
            }
            for (coord, tile) in best {
                let r = rect(coord)
                drawTile(coord, tile, fill: Color.green.opacity(0.35),
                         textColor: .white)
                context.stroke(Path(roundedRect: r, cornerRadius: cell * 0.15),
                               with: .color(.green), lineWidth: 1.5)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.07, green: 0.1, blue: 0.18))
        )
    }
}
