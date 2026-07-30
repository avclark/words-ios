import SwiftUI

// MARK: - Theme
//
// The token layer for the Phase 14 design pass and the eventual themes
// feature. A Theme carries every themeable VALUE — colors grouped by the
// surface they belong to, a semantic type scale, radii/border metrics,
// and the tile's visual treatment. Views read the current theme from the
// environment (`@Environment(\.theme)`); it is injected exactly once at
// the root (WordsApp), so switching themes later is a single assignment
// that re-renders the tree.
//
// THE TILE BOUNDARY (see CLAUDE.md invariants): a theme controls how a
// tile LOOKS, never how it BEHAVES. TileView is the theme-agnostic
// container — frame, hit shape, gestures, and every coordinate all live
// with the game layer. The theme supplies only `tileContent(...)`, the
// view drawn INSIDE that container. A theme must never touch
// DragController, BoardMetrics, or visualCenter.
//
// Motion (spring constants, takeover timing, haptics) is deliberately
// NOT themeable — those stay in the existing tuning knobs.

protocol Theme: Sendable {
    var board: BoardTheme { get }
    var tile: TileTheme { get }
    var chrome: ChromeTheme { get }
    var semantic: SemanticTheme { get }
    var typography: ThemeTypography { get }
    var metrics: ThemeMetrics { get }

    /// The tile's visual content, drawn INSIDE the theme-agnostic tile
    /// container. Purely visual: no gestures, no frames beyond its own
    /// drawing, no assumptions about where the tile sits. The default
    /// implementation renders the standard face from `tile` tokens; a
    /// theme may vendor a fully custom look by overriding this.
    func tileContent(tile: Tile, size: CGFloat, isFreshlyPlaced: Bool) -> AnyView
}

extension Theme {
    func tileContent(tile: Tile, size: CGFloat, isFreshlyPlaced: Bool) -> AnyView {
        AnyView(StandardTileFace(tile: tile, size: size,
                                 isFreshlyPlaced: isFreshlyPlaced,
                                 style: self.tile, typography: typography))
    }
}

// MARK: - Color groups

/// Board surface: the frame, the grid, the squares.
struct BoardTheme: Sendable {
    /// The board's base surface. Today this one color is also what shows
    /// through the cell spacing (the "gridlines") and around the grid
    /// (the "frame"); `frame` and `gridline` exist so a theme can split
    /// those roles apart.
    var background: Color
    /// The border/frame region around the cell grid.
    var frame: Color
    /// The color visible between cells.
    var gridline: Color
    /// A plain (non-premium) empty square.
    var cellEmpty: Color
    /// Per-cell border stroke. Width 0 = no stroke drawn (current look).
    var cellBorder: Color
    var cellBorderWidth: CGFloat

    // The five premium squares, each its own token.
    var premiumDoubleLetter: Color
    var premiumTripleLetter: Color
    var premiumDoubleWord: Color
    var premiumTripleWord: Color
    var premiumCenter: Color
    /// The "DL"/"TW" labels and the center star.
    var premiumLabel: Color

    func premiumColor(_ premium: Premium?, isCenter: Bool) -> Color {
        if isCenter { return premiumCenter }
        switch premium {
        case .tripleWord: return premiumTripleWord
        case .doubleWord: return premiumDoubleWord
        case .tripleLetter: return premiumTripleLetter
        case .doubleLetter: return premiumDoubleLetter
        case nil: return cellEmpty
        }
    }
}

/// Token-level tile styling, consumed by the standard tile face. A theme
/// wanting more than tokens can override `Theme.tileContent` wholesale.
struct TileTheme: Sendable {
    var face: Color
    var faceFresh: Color         // this turn's tiles (gold today)
    var letter: Color
    var letterBlank: Color       // assigned blank's letter
    var blankPlaceholder: Color  // the "?" on an unassigned blank
    var score: Color

    var cornerRadiusFactor: CGFloat   // × tile size
    var bevelHighlight: Color         // top-leading edge of the border gradient
    var bevelShadow: Color            // bottom-trailing edge
    var bevelWidth: CGFloat
    var shadowColor: Color
    var shadowRadiusFactor: CGFloat   // × tile size
    var shadowYFactor: CGFloat        // × tile size
}

/// Everything outside the board: screens, cards, text, buttons.
struct ChromeTheme: Sendable {
    var screenBackground: Color
    /// The base "ink" all translucent text/surfaces derive from (white on
    /// today's dark chrome). Sites with non-canonical opacities use
    /// `ink.opacity(x)` so a theme changing ink re-colors them all.
    var ink: Color
    var textPrimary: Color
    var textSecondary: Color
    var textMuted: Color
    var cardFill: Color
    /// The tile rack's surface.
    var rackFill: Color
    var border: Color
    /// The accent (yellow today): highlights, badges, toggle tints.
    var accent: Color
    /// Text/glyphs drawn ON an accent-filled surface.
    var onAccent: Color
    var buttonPrimary: Color
    var buttonPrimaryText: Color
    var buttonSecondaryFill: Color
    var buttonSecondaryText: Color
    var error: Color
    var warning: Color
    /// Full-screen overlay dim (game-over screen).
    var overlayScrim: Color
    /// nil = system-default tab bar treatment.
    var tabBarBackground: Color?
}

/// Game-meaning colors: states, not surfaces.
struct SemanticTheme: Sendable {
    /// "Your turn" — the turn chip, active player ring, lobby row chip.
    var turnAccent: Color
    /// A legal placement: the word outline and the score badge.
    var validMove: Color
    /// The drop-target cell highlight and the building score chip.
    var dropTarget: Color
    /// Hint tiers (best / second best / the rest).
    var hintBest: Color
    var hintSecond: Color
    var hintRest: Color
}

// MARK: - Typography

/// The semantic type scale. `font(_:_:)` is the family seam — every
/// themed text goes through it, so a theme can swap the app's typeface
/// with one override; the named roles let a theme retune a single role.
struct ThemeTypography: Sendable {
    /// size, weight → Font. Default: the app's rounded system idiom.
    var font: @Sendable (CGFloat, Font.Weight) -> Font

    // Roles (values = today's canonical usage).
    func tileLetter(size: CGFloat) -> Font { font(size * 0.62, .heavy) }
    func tileScore(size: CGFloat) -> Font { font(max(7, size * 0.24), .bold) }
    func blankPlaceholder(size: CGFloat) -> Font { font(size * 0.5, .heavy) }
    var playerName: Font { font(12, .semibold) }
    var scoreNumber: Font { font(19, .black) }
    var sectionTitle: Font { font(11, .heavy) }
    var body: Font { font(13, .regular) }
    var caption: Font { font(10, .regular) }
    var buttonLabel: Font { font(16, .heavy) }
}

// MARK: - Metrics

/// Radii, border weights, and key chrome spacing. Board LAYOUT metrics
/// (cell size/spacing/padding) are NOT here — they live in BoardMetrics,
/// the single coordinate path, and are not themeable.
struct ThemeMetrics: Sendable {
    var boardCornerRadius: CGFloat
    var cellCornerFactor: CGFloat     // × cell size
    var cardCornerRadius: CGFloat     // stat/summary/setup cards, buttons
    var rowCornerRadius: CGFloat      // lobby rows, rack background
    var smallCornerRadius: CGFloat    // blank-picker keys, mini-board, word outline
    var highlightCornerRadius: CGFloat // cell-sized overlays (hover, hint outlines)
    var hairline: CGFloat             // resting borders (avatar ring)
    var selectionBorder: CGFloat      // active/selected borders
    var screenHPadding: CGFloat       // standard screen edge padding
    var cardPadding: CGFloat          // standard card interior padding
}

// MARK: - Default theme (the current look, exactly)

/// Reproduces today's hardcoded values verbatim. When this theme is
/// applied the app must render identically to the pre-theme build —
/// that identity is the proof the token refactor is clean.
struct DefaultTheme: Theme {
    let board = BoardTheme(
        background: Color(red: 0.07, green: 0.1, blue: 0.18),
        frame: Color(red: 0.07, green: 0.1, blue: 0.18),
        gridline: Color(red: 0.07, green: 0.1, blue: 0.18),
        cellEmpty: Color(red: 0.13, green: 0.17, blue: 0.27),
        cellBorder: .clear,
        cellBorderWidth: 0,
        premiumDoubleLetter: Color(red: 0.35, green: 0.68, blue: 0.85),
        premiumTripleLetter: Color(red: 0.2, green: 0.5, blue: 0.85),
        premiumDoubleWord: Color(red: 0.9, green: 0.55, blue: 0.25),
        premiumTripleWord: Color(red: 0.85, green: 0.28, blue: 0.25),
        premiumCenter: Color(red: 0.9, green: 0.55, blue: 0.25),  // center is a DW square
        premiumLabel: .white.opacity(0.9)
    )

    let tile = TileTheme(
        face: Color(red: 0.96, green: 0.93, blue: 0.85),      // ivory
        faceFresh: Color(red: 0.98, green: 0.84, blue: 0.42), // gold
        letter: .black.opacity(0.88),
        letterBlank: Color(red: 0.72, green: 0.45, blue: 0.1),
        blankPlaceholder: .black.opacity(0.35),
        score: .black.opacity(0.65),
        cornerRadiusFactor: 0.18,
        bevelHighlight: .white.opacity(0.55),
        bevelShadow: .black.opacity(0.15),
        bevelWidth: 1,
        shadowColor: .black.opacity(0.35),
        shadowRadiusFactor: 0.06,
        shadowYFactor: 0.05
    )

    let chrome = ChromeTheme(
        screenBackground: Color(red: 0.05, green: 0.07, blue: 0.13),
        ink: .white,
        textPrimary: .white.opacity(0.9),
        textSecondary: .white.opacity(0.55),
        textMuted: .white.opacity(0.35),
        cardFill: .white.opacity(0.06),
        rackFill: Color(red: 0.1, green: 0.13, blue: 0.22),
        border: .white.opacity(0.15),
        accent: .yellow,
        onAccent: .black,
        buttonPrimary: .yellow,
        buttonPrimaryText: .black,
        buttonSecondaryFill: .white.opacity(0.1),
        buttonSecondaryText: .white.opacity(0.7),
        error: Color(red: 1, green: 0.45, blue: 0.4),
        warning: .orange,
        overlayScrim: .black.opacity(0.88),
        tabBarBackground: nil
    )

    let semantic = SemanticTheme(
        turnAccent: .yellow,
        validMove: .green,
        dropTarget: .yellow,
        hintBest: .red,
        hintSecond: .yellow,
        hintRest: .green
    )

    let typography = ThemeTypography(
        font: { size, weight in .system(size: size, weight: weight, design: .rounded) }
    )

    let metrics = ThemeMetrics(
        boardCornerRadius: 12,
        cellCornerFactor: 0.15,
        cardCornerRadius: 12,
        rowCornerRadius: 14,
        smallCornerRadius: 8,
        highlightCornerRadius: 6,
        hairline: 1,
        selectionBorder: 2,
        screenHPadding: 20,
        cardPadding: 12
    )
}

// MARK: - Environment injection

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: any Theme = DefaultTheme()
}

extension EnvironmentValues {
    /// The active theme. Set ONCE at the root (WordsApp); everywhere else
    /// reads it via `@Environment(\.theme)`. Never thread a theme through
    /// initializers.
    var theme: any Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Standard tile face

/// The default tile VISUAL: ivory face, bevel, letter, point value —
/// exactly the pre-theme TileView drawing, now driven by TileTheme
/// tokens. Drawn inside the tile container; knows nothing about
/// gestures or position.
struct StandardTileFace: View {
    let tile: Tile
    let size: CGFloat
    let isFreshlyPlaced: Bool
    let style: TileTheme
    let typography: ThemeTypography

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * style.cornerRadiusFactor, style: .continuous)
                .fill(isFreshlyPlaced ? style.faceFresh : style.face)
                .overlay(
                    RoundedRectangle(cornerRadius: size * style.cornerRadiusFactor, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [style.bevelHighlight, style.bevelShadow],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: style.bevelWidth
                        )
                )
                .shadow(color: style.shadowColor,
                        radius: size * style.shadowRadiusFactor,
                        y: size * style.shadowYFactor)

            if let letter = tile.displayLetter {
                Text(String(letter))
                    .font(typography.tileLetter(size: size))
                    .foregroundStyle(tile.isBlank ? style.letterBlank : style.letter)
                    .minimumScaleFactor(0.7)
            } else {
                // Unassigned blank
                Text("?")
                    .font(typography.blankPlaceholder(size: size))
                    .foregroundStyle(style.blankPlaceholder)
            }

            if tile.points > 0 {
                Text("\(tile.points)")
                    .font(typography.tileScore(size: size))
                    .foregroundStyle(style.score)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(size * 0.05)
            }
        }
    }
}
