import SwiftUI

/// Game screen header: both players with avatar/name/score, turn indicator,
/// bag + pass chips, and the move log line. Driven entirely by the player
/// model — it doesn't know whether the opponent is an AI or a remote human.
struct GameHeaderView: View {
    let local: Player
    let opponent: Player
    let turnState: TurnState
    let bagCount: Int
    let passes: Int
    let logLine: String?
    let rejection: String?
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 28, height: 44)
                        .contentShape(Rectangle())
                }

                PlayerBadge(player: local, isActive: turnState == .local, trailing: false)

                Spacer(minLength: 4)

                VStack(spacing: 5) {
                    Text(turnState == .local ? "YOUR TURN" : "WAITING…")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .kerning(1)
                        .foregroundStyle(turnState == .local ? Color.yellow : .white.opacity(0.45))
                    HStack(spacing: 5) {
                        chip(icon: "archivebox.fill", text: "\(bagCount)")
                        if passes > 0 {
                            chip(icon: "forward.end.fill", text: "\(passes)/6", tint: .orange)
                        }
                    }
                }

                Spacer(minLength: 4)

                PlayerBadge(player: opponent, isActive: turnState == .opponent, trailing: true)
                    .padding(.trailing, 12)
            }
            .padding(.leading, 4)

            Group {
                if let rejection {
                    Text(rejection)
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                } else if let logLine {
                    Text(logLine)
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    Text("Game on — good luck!")
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
        }
    }

    private func chip(icon: String, text: String, tint: Color = .white.opacity(0.6)) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

/// Avatar + name + score for one player. `isActive` marks whose turn it is.
private struct PlayerBadge: View {
    let player: Player
    let isActive: Bool
    /// True for the right-hand (opponent) slot: mirrors the layout.
    let trailing: Bool

    var body: some View {
        HStack(spacing: 8) {
            if trailing { info } else { avatar }
            if trailing { avatar } else { info }
        }
        .opacity(isActive ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.25), value: isActive)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(player.profile.avatar.tint.opacity(0.22))
            Image(systemName: player.profile.avatar.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(player.profile.avatar.tint)
        }
        .frame(width: 40, height: 40)
        .overlay(
            Circle().strokeBorder(isActive ? Color.yellow : .white.opacity(0.15),
                                  lineWidth: isActive ? 2 : 1)
        )
    }

    private var info: some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 1) {
            Text(player.profile.displayName)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Text("\(player.score)")
                .font(.system(size: 19, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: player.score)
        }
        .frame(minWidth: 34, alignment: trailing ? .trailing : .leading)
    }
}
