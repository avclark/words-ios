import SwiftUI

/// "Word of the Day" — the Home screen's featured-word block.
///
/// Self-contained on purpose: one container view (label + word + the
/// tap-to-reveal definition) so the Phase 14 design pass can set the
/// whole block off (card/border/background, NYT-style) by styling THIS
/// component without touching Home's layout. Styling is deliberately
/// minimal until then; everything reads the theme.
///
/// Despite the branding label, the word rerolls on every appearance of
/// the Home screen — it is random, not date-deterministic.
struct WordOfTheDayView: View {
    @Environment(\.theme) private var theme

    /// DEV SWITCH — how the featured word itself is drawn. Flip to
    /// `.text` for the typographic treatment; the container, label,
    /// tap/expand, and definition behavior are identical either way.
    /// Not a user-facing toggle.
    private static let wordStyle: WordDisplayStyle = .tiles

    enum WordDisplayStyle { case tiles, text }

    @State private var word: String?
    @State private var definition: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WORD OF THE DAY")
                .font(theme.typography.sectionTitle)
                .kerning(1)
                .foregroundStyle(theme.chrome.ink.opacity(0.4))

            if let word {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        expanded.toggle()
                    }
                } label: {
                    wordDisplay(word)
                }
                .buttonStyle(.plain)

                // JUST the definition — no part of speech, no score.
                if expanded {
                    Text(definition ?? "A valid word — no definition in our dictionary.")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.chrome.ink.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            } else {
                // Placeholder keeps the block's height stable while the
                // definitions store loads on first launch.
                Color.clear.frame(height: WordTileDisplay.tileSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: theme.metrics.cardCornerRadius, style: .continuous)
                .fill(theme.chrome.cardFill)
        )
        .clipped()
        .onAppear { reroll() }
    }

    /// The ONE switch point between the two word renderings.
    @ViewBuilder
    private func wordDisplay(_ word: String) -> some View {
        switch Self.wordStyle {
        case .tiles: WordTileDisplay(word: word)
        case .text: WordTextDisplay(word: word)
        }
    }

    /// Pick a fresh featured word, off the main thread — the first call
    /// pays the definitions-store load (~4MB). The pool is
    /// Definitions.randomDefinedWord() (the temporary has-a-definition
    /// filter lives THERE, in one place).
    private func reroll() {
        Task {
            let picked = await Task.detached(priority: .utility) { () -> (String, String?)? in
                guard let w = Definitions.randomDefinedWord() else { return nil }
                return (w, Definitions.lookup(w).map(Self.glossOnly))
            }.value
            guard let picked else { return }
            expanded = false
            word = picked.0
            definition = picked.1
        }
    }

    /// First sense of a stored definition line, with its part-of-speech
    /// marker stripped: "n. a domestic animal | v. …" → "a domestic animal".
    private static func glossOnly(_ line: String) -> String {
        let first = line.components(separatedBy: " | ").first ?? line
        for pos in ["n. ", "v. ", "adj. ", "adv. "] where first.hasPrefix(pos) {
            return String(first.dropFirst(pos.count))
        }
        return first
    }
}

// MARK: - Word renderings

/// Renders a word as game tiles — the app's own tile appearance via the
/// theme's tile content, so the featured word feels native. Purely
/// visual (display-only tiles, no gestures). Sized to fit the available
/// width, capped at the standard rack-ish tile size.
struct WordTileDisplay: View {
    static let tileSize: CGFloat = 36

    let word: String

    private let spacing: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let count = CGFloat(max(word.count, 1))
            let size = min(Self.tileSize,
                           (geo.size.width - spacing * (count - 1)) / count)
            HStack(spacing: spacing) {
                ForEach(Array(word.enumerated()), id: \.offset) { _, letter in
                    TileView(tile: Tile(letter: letter), size: size)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: Self.tileSize)
    }
}

/// Renders a word as styled text — the typographic alternative to the
/// tile treatment. Same contract: given a word, draw it.
struct WordTextDisplay: View {
    @Environment(\.theme) private var theme

    let word: String

    var body: some View {
        Text(word)
            .font(theme.typography.font(26, .black))
            .kerning(1)
            .foregroundStyle(theme.chrome.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}
