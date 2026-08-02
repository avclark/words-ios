import SwiftUI

/// Game screen header: both players with avatar/name/score, turn indicator,
/// bag + pass chips, and the move log line. Driven entirely by the player
/// model — it doesn't know whether the opponent is an AI or a remote human.
struct GameHeaderView: View {
    @Environment(\.theme) private var theme

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
                        .foregroundStyle(theme.chrome.textSecondary)
                        .frame(width: 28, height: 44)
                        .contentShape(Rectangle())
                }

                PlayerBadge(player: local, isActive: turnState == .local, trailing: false)

                Spacer(minLength: 4)

                VStack(spacing: 5) {
                    Text(turnState == .local ? "YOUR TURN" : "WAITING…")
                        .font(theme.typography.font(10, .heavy))
                        .kerning(1)
                        .foregroundStyle(turnState == .local ? theme.semantic.turnAccent
                                                             : theme.chrome.ink.opacity(0.45))
                    HStack(spacing: 5) {
                        chip(icon: "archivebox.fill", text: "\(bagCount)")
                        // Always mounted so the header never reflows between
                        // turns; dimmed at 0, lit while a pass streak is live.
                        chip(icon: "forward.end.fill", text: "\(passes)/6",
                             tint: passes > 0 ? theme.chrome.warning : theme.chrome.ink.opacity(0.3))
                        if let deadline = expiryText {
                            chip(icon: "clock.fill", text: deadline.text,
                                 tint: deadline.urgent ? theme.chrome.warning : theme.chrome.ink.opacity(0.6))
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
                                        .foregroundStyle(theme.chrome.textSecondary)
                                    if chatBadge > 0 {
                                        Text("\(min(chatBadge, 9))")
                                            .font(theme.typography.font(9, .heavy))
                                            .foregroundStyle(theme.chrome.onAccent)
                                            .frame(width: 14, height: 14)
                                            .background(Circle().fill(theme.chrome.accent))
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
                                        .foregroundStyle(theme.chrome.accent.opacity(0.7))
                                        .frame(width: 24, height: onResign == nil ? 44 : 22)
                                        .contentShape(Rectangle())
                                }
                            }
                            if let onResign {
                                Button(action: onResign) {
                                    Image(systemName: "flag.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(theme.chrome.ink.opacity(0.4))
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
                        .foregroundStyle(theme.chrome.error)
                } else if let logLine {
                    Text(logLine)
                        .foregroundStyle(theme.chrome.textSecondary)
                } else {
                    Text("Game on — good luck!")
                        .foregroundStyle(theme.chrome.ink.opacity(0.3))
                }
            }
            .font(theme.typography.font(12, .semibold))
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

    private func chip(icon: String, text: String, tint: Color? = nil) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(theme.typography.font(11, .bold))
        }
        .foregroundStyle(tint ?? theme.chrome.ink.opacity(0.6))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(theme.chrome.ink.opacity(0.08)))
    }
}

/// Avatar + name + score for one player. `isActive` marks whose turn it is.
private struct PlayerBadge: View {
    @Environment(\.theme) private var theme

    let player: Player
    let isActive: Bool
    /// True for the right-hand (opponent) slot: mirrors the layout.
    let trailing: Bool

    var body: some View {
        // Turn state shows via the ring and the YOUR TURN/WAITING text —
        // avatars themselves render at FULL opacity at all times (the
        // old whole-badge fade dimmed the avatar too; only the name/
        // score text keeps the subtle waiting fade).
        HStack(spacing: 8) {
            if trailing { info } else { avatar }
            if trailing { avatar } else { info }
        }
        .animation(.easeInOut(duration: 0.25), value: isActive)
    }

    private var avatar: some View {
        AvatarView(profile: player.profile, size: 40)
            .overlay(
                Circle().strokeBorder(isActive ? theme.semantic.turnAccent : theme.chrome.border,
                                      lineWidth: isActive ? theme.metrics.selectionBorder
                                                          : theme.metrics.hairline)
            )
    }

    private var info: some View {
        infoContent
            .opacity(isActive ? 1 : 0.55)
    }

    private var infoContent: some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 1) {
            Text(player.profile.displayName)
                .font(theme.typography.playerName)
                .foregroundStyle(theme.chrome.ink.opacity(0.75))
                .lineLimit(1)
            Text("\(player.score)")
                .font(theme.typography.scoreNumber)
                .foregroundStyle(theme.chrome.ink)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: player.score)
        }
        .frame(minWidth: 34, alignment: trailing ? .trailing : .leading)
    }
}
