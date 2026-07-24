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
    /// Inactivity deadline (human games) — surfaced when under 3 days so
    /// expiry is never a surprise.
    var expiresAt: Date? = nil
    /// Present only when resigning makes sense (active human game).
    var onResign: (() -> Void)? = nil
    /// Present while waiting on a human opponent (rate-limited nudge).
    var onPing: (() -> Void)? = nil
    /// Present for human games: opens the chat thread.
    var onChat: (() -> Void)? = nil
    var chatBadge: Int = 0
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
                        // Always mounted so the header never reflows between
                        // turns; dimmed at 0, lit while a pass streak is live.
                        chip(icon: "forward.end.fill", text: "\(passes)/6",
                             tint: passes > 0 ? .orange : .white.opacity(0.3))
                        if let deadline = expiryText {
                            chip(icon: "clock.fill", text: deadline.text,
                                 tint: deadline.urgent ? .orange : .white.opacity(0.6))
                        }
                    }
                }

                Spacer(minLength: 4)

                PlayerBadge(player: opponent, isActive: turnState == .opponent, trailing: true)
                    .padding(.trailing, onResign == nil ? 12 : 0)

                if onChat != nil || onResign != nil || onPing != nil {
                    HStack(spacing: 2) {
                        if let onChat {
                            Button(action: onChat) {
                                ZStack {
                                    Image(systemName: "bubble.left.fill")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.55))
                                    if chatBadge > 0 {
                                        Text("\(min(chatBadge, 9))")
                                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                                            .foregroundStyle(.black)
                                            .frame(width: 14, height: 14)
                                            .background(Circle().fill(Color.yellow))
                                            .offset(x: 10, y: -9)
                                    }
                                }
                                .frame(width: 30, height: 44)
                                .contentShape(Rectangle())
                            }
                        }
                        VStack(spacing: 0) {
                            if let onPing {
                                Button(action: onPing) {
                                    Image(systemName: "bell.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.yellow.opacity(0.7))
                                        .frame(width: 24, height: onResign == nil ? 44 : 22)
                                        .contentShape(Rectangle())
                                }
                            }
                            if let onResign {
                                Button(action: onResign) {
                                    Image(systemName: "flag.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.4))
                                        .frame(width: 24, height: onPing == nil ? 44 : 22)
                                        .contentShape(Rectangle())
                                }
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
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

    private var expiryText: (text: String, urgent: Bool)? {
        guard let expiresAt else { return nil }
        let remaining = expiresAt.timeIntervalSinceNow
        guard remaining < 3 * 86_400 else { return nil }
        if remaining <= 0 { return ("expiring", true) }
        if remaining < 86_400 { return ("\(max(1, Int(remaining / 3600)))h", true) }
        return ("\(Int(remaining / 86_400))d", false)
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
