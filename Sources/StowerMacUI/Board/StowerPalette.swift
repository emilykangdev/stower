import SwiftUI

/// The board's warm "variant-E" color palette — the single source of truth for every
/// color the board, composer, drafts, and their notices paint.
///
/// Values are **flat** `Color(.sRGB, …)` literals authored from the approved design
/// spec (`conversation-draft` variant E), light-only this sprint (JC3). They are NOT
/// `NSColor(name:dynamicProvider:)` adaptive colors: a dynamic provider would fight the
/// `.preferredColorScheme(.light)` surface lock and make the palette test
/// appearance-dependent. Adding a dark branch later is a one-file edit (author ~12 hex
/// values), not a refactor — the structure is already centralized here.
///
/// Each token's doc names its source hex so a drift is greppable; `StowerPaletteTests`
/// resolves every token in a forced-light environment and asserts the RGBA matches that
/// hex within tolerance.
internal enum StowerPalette {
    /// The whole-board canvas behind everything — cream `#F8F4EE`.
    ///
    /// Painted explicitly (`.background`) because `.preferredColorScheme(.light)` alone
    /// gives white, and an opaque `List` would punch a gray rectangle through it.
    internal static let canvas = Color(.sRGB, red: 0.9725, green: 0.9569, blue: 0.9333, opacity: 1)

    /// The warm row/card/surface fill above the canvas — `#FBF8F3`.
    internal static let surface = Color(.sRGB, red: 0.9843, green: 0.9725, blue: 0.9529, opacity: 1)

    /// The opaque warm fill that replaces a translucent material when Reduce
    /// Transparency is on — same warmth as `surface`, guaranteed fully opaque.
    internal static let surfaceSolid = Color(
        .sRGB,
        red: 0.9843,
        green: 0.9725,
        blue: 0.9529,
        opacity: 1
    )

    /// Primary text — warm near-black `#2E2A26` (≈13:1 on cream, clears AA body).
    internal static let textPrimary = Color(
        .sRGB,
        red: 0.1804,
        green: 0.1647,
        blue: 0.1490,
        opacity: 1
    )

    /// De-emphasized text (summaries, ages, captions) — warm gray `#665E55`.
    ///
    /// Darkened from the spec's `#8C857C` (the spec marks its colors "approximate,
    /// tunable") to clear AA **body** contrast (4.5:1) on every warm fill it lands on —
    /// not just cream (`canvas`/`surface`) but also `rowHover` (row text on hover) and
    /// `pillFill` (the Contacts banner caption), where the lighter spec value fell below
    /// 4.5:1. The token carries normal-size copy, which WCAG holds to the body tier.
    internal static let textSecondary = Color(
        .sRGB,
        red: 0.4000,
        green: 0.3686,
        blue: 0.3333,
        opacity: 1
    )

    /// The strong accent — a muted coral `#BE5238`, used for fills and icons only (never
    /// body text, JC6): the avatar's deep gradient stop, the from-me bubble, the undo
    /// drain, the draft pencil glyph.
    ///
    /// Deepened so **white** text clears AA body contrast (≈4.7:1) — the from-me thread
    /// bubble renders normal white text on it; ≈4.3:1 on cream as an icon/fill.
    internal static let coral = Color(.sRGB, red: 0.7451, green: 0.3216, blue: 0.2196, opacity: 1)

    /// The soft accent — peach `#E9A487` (design `accentPeach`): the "Reply in Messages"
    /// fill (with `textPrimary` label — white fails AA on peach) and the avatar's light
    /// gradient stop.
    internal static let peach = Color(.sRGB, red: 0.9137, green: 0.6431, blue: 0.5294, opacity: 1)

    /// The active tab/segment pill fill — `#F2D7C6`.
    internal static let tabActiveFill = Color(
        .sRGB,
        red: 0.9490,
        green: 0.8431,
        blue: 0.7765,
        opacity: 1
    )

    /// The soft pill fill for chips and the Contacts banner — `#F3D9C9`.
    internal static let pillFill = Color(
        .sRGB,
        red: 0.9529,
        green: 0.8510,
        blue: 0.7882,
        opacity: 1
    )

    /// The inbound (counterpart) thread-bubble fill — `#ECE8E2`.
    internal static let incomingBubble = Color(
        .sRGB,
        red: 0.9255,
        green: 0.9098,
        blue: 0.8863,
        opacity: 1
    )

    /// Hairline separators on the warm surface — `#ECE6DD`.
    internal static let divider = Color(.sRGB, red: 0.9255, green: 0.9020, blue: 0.8667, opacity: 1)

    /// The warm fill a row takes on hover — `#F4EBE2`, a tuned interaction tone sitting
    /// between `surface` and `tabActiveFill` (slightly warmer than rest, never loud).
    internal static let rowHover = Color(
        .sRGB,
        red: 0.9569,
        green: 0.9216,
        blue: 0.8863,
        opacity: 1
    )
}
