import SwiftUI

/// The signature feature: a screen-takeover animation for an emoji the
/// opponent sent. Rendered as a hit-test-disabled overlay ABOVE the board —
/// nothing underneath is moved or torn down (invariant 2), so a takeover
/// can play over a live drag without disturbing it.
///
/// Each emoji has its own physicality (see TakeoverStyle): celebration
/// bursts, laughter tumbles, fire rises, rage slams. All motion is a pure
/// function of elapsed time over a TimelineView — no queued animations to
/// leak or fight.
struct EmojiTakeoverView: View {
    let emoji: String
    let onFinished: () -> Void

    private let style: TakeoverStyle
    private let particles: [TakeoverParticle]
    private let startDate = Date()

    init(emoji: String, onFinished: @escaping () -> Void) {
        self.emoji = emoji
        self.onFinished = onFinished
        let style = TakeoverStyle.style(for: emoji)
        self.style = style
        self.particles = style.makeParticles(emoji: emoji)
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(startDate)
            GeometryReader { geo in
                ZStack {
                    // Gentle scrim gives the moment punch without hiding
                    // the board; it's part of the overlay, not the board.
                    Color.black.opacity(0.28 * style.envelope(t))
                    styleTint(t)
                    particleCanvas(t: t, size: geo.size)
                    heroEmoji(t: t, size: geo.size)
                }
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .task {
            try? await Task.sleep(nanoseconds: UInt64(style.duration * 1_000_000_000))
            onFinished()
        }
    }

    @ViewBuilder
    private func styleTint(_ t: Double) -> some View {
        switch style {
        case .flames:
            RadialGradient(colors: [.orange.opacity(0.25 * style.envelope(t)), .clear],
                           center: .bottom, startRadius: 0, endRadius: 500)
        case .slamShake:
            RadialGradient(colors: [.clear, .red.opacity(0.3 * style.envelope(t))],
                           center: .center, startRadius: 150, endRadius: 500)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func heroEmoji(t: Double, size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height * 0.42)
        switch style {
        case .confetti:
            // Spring up, pop, hold, fade.
            let scale = TakeoverMath.springPop(t, peak: 0.35, settle: 3.2)
            Text(emoji)
                .font(.system(size: 120))
                .scaleEffect(scale)
                .opacity(TakeoverMath.fadeOut(t, from: 2.0, over: 0.5))
                .position(center)
        case .tumble:
            // The hero laughs its way down the screen, wobbling.
            let y = TakeoverMath.fallWithBounce(t, from: -100, to: size.height * 0.62,
                                                duration: 1.1)
            Text(emoji)
                .font(.system(size: 110))
                .rotationEffect(.degrees(sin(t * 9) * 14))
                .opacity(TakeoverMath.fadeOut(t, from: 2.0, over: 0.5))
                .position(x: center.x, y: y)
        case .zoomQuiver:
            // Tiny → screen-filling with overshoot, then a held tremble.
            let zoom = TakeoverMath.overshootZoom(t, to: 2.6)
            let quiver = t > 0.5 ? CGSize(width: TakeoverMath.jitter(t, seed: 1) * 6,
                                          height: TakeoverMath.jitter(t, seed: 2) * 6)
                                 : .zero
            Text(emoji)
                .font(.system(size: 120))
                .scaleEffect(zoom)
                .offset(quiver)
                .opacity(TakeoverMath.fadeOut(t, from: 1.6, over: 0.4))
                .position(center)
        case .flames:
            // The hero flame anchors low while particles carry the motion.
            Text(emoji)
                .font(.system(size: 130))
                .scaleEffect(1 + 0.1 * sin(t * 6))
                .opacity(TakeoverMath.fadeOut(t, from: 1.7, over: 0.5))
                .position(x: center.x, y: size.height * 0.7)
        case .clapWave:
            // Stamps across an arc, one pop per beat.
            let beats = 5
            let beat = min(Int(t / 0.28), beats - 1)
            let progress = Double(beat) / Double(beats - 1)
            let x = size.width * (0.18 + 0.64 * progress)
            let y = size.height * (0.45 - 0.18 * sin(progress * .pi))
            let beatT = t - Double(beat) * 0.28
            Text(emoji)
                .font(.system(size: 90))
                .scaleEffect(TakeoverMath.springPop(beatT, peak: 0.12, settle: 8))
                .opacity(TakeoverMath.fadeOut(t, from: 1.5, over: 0.4))
                .position(x: x, y: y)
        case .heartbeat:
            // Lub-dub, lub-dub.
            Text(emoji)
                .font(.system(size: 140))
                .scaleEffect(TakeoverMath.heartbeat(t))
                .opacity(TakeoverMath.fadeOut(t, from: 1.7, over: 0.5))
                .position(center)
        case .slamShake:
            // Slams in from above; the OVERLAY shakes, never the board.
            let y = TakeoverMath.slamY(t, from: -160, to: center.y)
            let shake = t > 0.32 && t < 0.9
                ? CGSize(width: TakeoverMath.jitter(t * 3, seed: 3) * 14,
                         height: TakeoverMath.jitter(t * 3, seed: 4) * 10)
                : .zero
            Text(emoji)
                .font(.system(size: 130))
                .offset(shake)
                .opacity(TakeoverMath.fadeOut(t, from: 1.3, over: 0.4))
                .position(x: center.x, y: y)
        }
    }

    private func particleCanvas(t: Double, size: CGSize) -> some View {
        Canvas { context, canvasSize in
            for particle in particles {
                let pt = t - particle.delay
                guard pt > 0 else { continue }
                guard let state = style.particleState(particle, t: pt, size: canvasSize) else { continue }
                var resolved = context
                resolved.translateBy(x: state.position.x, y: state.position.y)
                resolved.rotate(by: .degrees(state.rotation))
                resolved.opacity = state.opacity
                if let symbol = particle.symbol {
                    resolved.draw(Text(symbol).font(.system(size: particle.size)),
                                  at: .zero)
                } else {
                    let rect = CGRect(x: -particle.size / 2, y: -particle.size / 3,
                                      width: particle.size, height: particle.size * 0.66)
                    resolved.fill(Path(roundedRect: rect, cornerRadius: 2),
                                  with: .color(particle.color ?? .yellow))
                }
            }
        }
    }
}

// MARK: - Styles

enum TakeoverStyle {
    case confetti      // 🎉 pop + confetti rain
    case tumble        // 😂 giggle pile falling from the top
    case zoomQuiver    // 😮 😭 giant zoom with tremble (+tears for 😭)
    case flames        // 🔥 heat rising from the bottom
    case clapWave      // 👏 stamps across the screen
    case heartbeat     // ❤️ pulsing lub-dub with floating hearts
    case slamShake     // 🤬 slam down + overlay shake + red vignette

    static func style(for emoji: String) -> TakeoverStyle {
        switch emoji {
        case "🎉", "🥳", "🎊": return .confetti
        case "😂", "🤣", "😆": return .tumble
        case "🔥": return .flames
        case "👏": return .clapWave
        case "❤️", "😍", "🥰", "💛": return .heartbeat
        case "🤬", "😡", "😤": return .slamShake
        default: return .zoomQuiver
        }
    }

    var duration: Double {
        switch self {
        case .confetti: return 2.6
        case .tumble: return 2.6
        case .zoomQuiver: return 2.0
        case .flames: return 2.3
        case .clapWave: return 2.0
        case .heartbeat: return 2.2
        case .slamShake: return 1.8
        }
    }

    /// 0→1→0 intensity curve for scrims and tints.
    func envelope(_ t: Double) -> Double {
        let rise = min(t / 0.25, 1)
        let fall = max(0, min(1, (duration - t) / 0.5))
        return max(0, min(rise, fall))
    }

    func makeParticles(emoji: String) -> [TakeoverParticle] {
        var generator = SeededRandom(seed: 42)
        switch self {
        case .confetti:
            let colors: [Color] = [.yellow, .orange, .pink, .cyan, .green, .purple]
            return (0..<80).map { i in
                TakeoverParticle(
                    id: i,
                    seedX: generator.next(), seedY: generator.next(),
                    seedSpin: generator.next(),
                    size: 8 + generator.next() * 8,
                    symbol: nil,
                    color: colors[i % colors.count],
                    delay: 0.3 + generator.next() * 0.25)
            }
        case .tumble:
            return (0..<12).map { i in
                TakeoverParticle(
                    id: i,
                    seedX: generator.next(), seedY: generator.next(),
                    seedSpin: generator.next(),
                    size: 30 + generator.next() * 40,
                    symbol: emoji, color: nil,
                    delay: generator.next() * 0.7)
            }
        case .zoomQuiver where emoji == "😭":
            return (0..<14).map { i in
                TakeoverParticle(
                    id: i,
                    seedX: generator.next(), seedY: generator.next(),
                    seedSpin: generator.next(),
                    size: 16 + generator.next() * 10,
                    symbol: "💧", color: nil,
                    delay: 0.7 + generator.next() * 0.8)
            }
        case .zoomQuiver:
            return []
        case .flames:
            return (0..<16).map { i in
                TakeoverParticle(
                    id: i,
                    seedX: generator.next(), seedY: generator.next(),
                    seedSpin: generator.next(),
                    size: 28 + generator.next() * 40,
                    symbol: "🔥", color: nil,
                    delay: generator.next() * 1.0)
            }
        case .clapWave:
            return (0..<18).map { i in
                TakeoverParticle(
                    id: i,
                    seedX: generator.next(), seedY: generator.next(),
                    seedSpin: generator.next(),
                    size: 10 + generator.next() * 8,
                    symbol: "✨", color: nil,
                    delay: Double(i % 5) * 0.28 + 0.05)
            }
        case .heartbeat:
            return (0..<10).map { i in
                TakeoverParticle(
                    id: i,
                    seedX: generator.next(), seedY: generator.next(),
                    seedSpin: generator.next(),
                    size: 18 + generator.next() * 14,
                    symbol: "❤️", color: nil,
                    delay: 0.4 + generator.next() * 0.9)
            }
        case .slamShake:
            return []
        }
    }

    /// Position/rotation/opacity for one particle at time t — pure math.
    func particleState(_ p: TakeoverParticle, t: Double, size: CGSize) -> TakeoverParticleState? {
        switch self {
        case .confetti:
            let life = 2.0
            guard t < life else { return nil }
            let originX = size.width / 2, originY = size.height * 0.42
            let angle = p.seedSpin * 2 * .pi
            let speed = 180 + p.seedY * 260
            let x = originX + cos(angle) * speed * t * 0.6
            let y = originY + sin(angle) * speed * t * 0.25 + 360 * t * t
            return TakeoverParticleState(
                position: CGPoint(x: x, y: y),
                rotation: p.seedSpin * 360 + t * 400 * (p.seedX > 0.5 ? 1 : -1),
                opacity: TakeoverMath.fadeOut(t, from: life - 0.5, over: 0.5))
        case .tumble:
            let life = 2.2
            guard t < life else { return nil }
            let x = size.width * (0.08 + p.seedX * 0.84)
            let target = size.height * (0.55 + p.seedY * 0.32)
            let y = TakeoverMath.fallWithBounce(t, from: -80, to: target,
                                                duration: 0.9 + p.seedY * 0.4)
            return TakeoverParticleState(
                position: CGPoint(x: x, y: y),
                rotation: sin((t + p.seedSpin * 3) * 6) * 24,
                opacity: TakeoverMath.fadeOut(t, from: life - 0.5, over: 0.5))
        case .zoomQuiver:
            let life = 1.3
            guard t < life else { return nil }
            let x = size.width * (0.3 + p.seedX * 0.4)
            let y = size.height * 0.5 + (60 + p.seedY * 120) * t + 240 * t * t
            return TakeoverParticleState(
                position: CGPoint(x: x, y: y),
                rotation: 0,
                opacity: TakeoverMath.fadeOut(t, from: life - 0.4, over: 0.4))
        case .flames:
            let life = 1.6
            guard t < life else { return nil }
            let progress = t / life
            let x = size.width * (0.08 + p.seedX * 0.84) + sin(t * 5 + p.seedSpin * 6) * 22
            let y = size.height * (1.05 - progress * (0.55 + p.seedY * 0.3))
            return TakeoverParticleState(
                position: CGPoint(x: x, y: y),
                rotation: sin(t * 7 + p.seedSpin) * 10,
                opacity: min(1, progress * 4) * TakeoverMath.fadeOut(t, from: life - 0.45, over: 0.45))
        case .clapWave:
            let life = 0.8
            guard t < life else { return nil }
            let beat = Double(p.id % 5) / 4.0
            let baseX = size.width * (0.18 + 0.64 * beat)
            let baseY = size.height * (0.45 - 0.18 * sin(beat * .pi))
            let angle = p.seedSpin * 2 * .pi
            let radius = 30 + 90 * t
            return TakeoverParticleState(
                position: CGPoint(x: baseX + cos(angle) * radius,
                                  y: baseY + sin(angle) * radius),
                rotation: 0,
                opacity: TakeoverMath.fadeOut(t, from: 0.35, over: 0.45))
        case .heartbeat:
            let life = 1.6
            guard t < life else { return nil }
            let x = size.width * (0.2 + p.seedX * 0.6) + sin(t * 3 + p.seedSpin * 6) * 18
            let y = size.height * 0.5 - (80 + p.seedY * 140) * t
            return TakeoverParticleState(
                position: CGPoint(x: x, y: y),
                rotation: 0,
                opacity: TakeoverMath.fadeOut(t, from: life - 0.5, over: 0.5))
        case .slamShake:
            return nil
        }
    }
}

struct TakeoverParticle: Identifiable {
    let id: Int
    let seedX: Double
    let seedY: Double
    let seedSpin: Double
    let size: CGFloat
    let symbol: String?
    let color: Color?
    let delay: Double
}

struct TakeoverParticleState {
    let position: CGPoint
    let rotation: Double
    let opacity: Double
}

// MARK: - Motion math (pure functions of time)

enum TakeoverMath {
    /// 0→overshoot→1 spring-ish pop.
    static func springPop(_ t: Double, peak: Double, settle: Double) -> Double {
        guard t > 0 else { return 0.01 }
        if t < peak { return 0.01 + (1.25 - 0.01) * (t / peak) }
        let dt = t - peak
        return 1 + 0.25 * exp(-settle * dt) * cos(dt * 10)
    }

    static func overshootZoom(_ t: Double, to scale: Double) -> Double {
        guard t > 0 else { return 0.05 }
        let rise = 0.4
        if t < rise { return 0.05 + (scale * 1.12 - 0.05) * easeOut(t / rise) }
        let dt = t - rise
        return scale * (1 + 0.12 * exp(-6 * dt) * cos(dt * 12))
    }

    static func fallWithBounce(_ t: Double, from: CGFloat, to: CGFloat, duration: Double) -> CGFloat {
        if t < duration {
            let p = t / duration
            return from + (to - from) * CGFloat(p * p)   // accelerating fall
        }
        let dt = t - duration
        let bounce = 40 * exp(-4 * dt) * abs(sin(dt * 9))
        return to - CGFloat(bounce)
    }

    static func slamY(_ t: Double, from: CGFloat, to: CGFloat) -> CGFloat {
        let duration = 0.32
        if t < duration {
            let p = t / duration
            return from + (to - from) * CGFloat(p * p * p)  // violent arrival
        }
        return to
    }

    static func heartbeat(_ t: Double) -> Double {
        // Two lub-dubs: quick double-pulse each second.
        let phase = t.truncatingRemainder(dividingBy: 1.0)
        let lub = exp(-pow((phase - 0.15) * 12, 2)) * 0.18
        let dub = exp(-pow((phase - 0.42) * 12, 2)) * 0.24
        return 1 + lub + dub
    }

    static func fadeOut(_ t: Double, from start: Double, over duration: Double) -> Double {
        guard t > start else { return 1 }
        return max(0, 1 - (t - start) / duration)
    }

    static func jitter(_ t: Double, seed: Double) -> Double {
        sin(t * 47 + seed * 13) * cos(t * 31 + seed * 7)
    }

    static func easeOut(_ p: Double) -> Double {
        1 - pow(1 - p, 3)
    }
}

/// Deterministic particle layouts (Date/random-free so previews and tests
/// are stable).
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) % 10_000) / 10_000
    }
}
