import SwiftUI
import Testing

@testable import StowerMacUI

/// Locks the warm palette to the approved variant-E spec and proves the text/fill
/// pairings are legible on cream.
///
/// Two threats: palette drift from the approved design (every token is resolved in a
/// forced-light environment and compared to its source hex within `colorTolerance`),
/// and coral-on-cream illegibility (JC6 — relative-luminance contrast per pairing).
///
/// Contrast tiers follow WCAG: `bodyContrast` (4.5:1) for reading text (primary AND the
/// de-emphasized `textSecondary`, which carries normal-size row/notice copy), and
/// `largeOrUIContrast` (3.0:1) for icons and fills on cream. `textSecondary` and `coral`
/// are darkened from the spec's nominal values (the spec marks its colors "approximate,
/// tunable") specifically so body text clears 4.5:1.
@Suite internal struct StowerPaletteTests {
    /// Forced-light environment so a (flat, non-dynamic) token resolves deterministically
    /// regardless of the host appearance.
    private static var lightEnvironment: EnvironmentValues {
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        return environment
    }

    /// Max per-channel deviation between a resolved token and its spec hex (covers the
    /// 4-decimal authoring of the sRGB components and any resolve round-trip).
    private static let colorTolerance = 0.02

    /// WCAG AA contrast for normal reading text.
    private static let bodyContrast = 4.5

    /// WCAG AA contrast for large text, UI components, and meaningful icons/fills.
    private static let largeOrUIContrast = 3.0

    @Test(
        "every token resolves to its approved variant-E spec hex",
        arguments: [
            (StowerPalette.canvas, "#F8F4EE"),
            (StowerPalette.surface, "#FBF8F3"),
            (StowerPalette.surfaceSolid, "#FBF8F3"),
            (StowerPalette.textPrimary, "#2E2A26"),
            (StowerPalette.textSecondary, "#665E55"),
            (StowerPalette.coral, "#BE5238"),
            (StowerPalette.peach, "#E9A487"),
            (StowerPalette.tabActiveFill, "#F2D7C6"),
            (StowerPalette.pillFill, "#F3D9C9"),
            (StowerPalette.incomingBubble, "#ECE8E2"),
            (StowerPalette.divider, "#ECE6DD"),
            (StowerPalette.rowHover, "#F4EBE2")
        ]
    )
    internal func tokenMatchesSpecHex(color: Color, hex: String) {
        let resolved = color.resolve(in: Self.lightEnvironment)
        let expected = Self.components(hex: hex)
        #expect(abs(Double(resolved.red) - expected.red) < Self.colorTolerance)
        #expect(abs(Double(resolved.green) - expected.green) < Self.colorTolerance)
        #expect(abs(Double(resolved.blue) - expected.blue) < Self.colorTolerance)
        #expect(abs(Double(resolved.opacity) - 1) < Self.colorTolerance)
    }

    @Test(
        "primary text clears AA body contrast on every fill it sits on",
        arguments: [
            StowerPalette.canvas,  // notices, names
            StowerPalette.surface,  // rows, cards
            StowerPalette.peach,  // Reply in Messages label
            StowerPalette.tabActiveFill,  // active tab segment label
            StowerPalette.pillFill  // preset-menu label, banner title
        ]
    )
    internal func primaryTextIsBodyLegible(on fill: Color) {
        #expect(Self.contrast(StowerPalette.textPrimary, fill) >= Self.bodyContrast)
    }

    @Test(
        "secondary text clears AA body contrast on every warm fill it sits on",
        arguments: [
            StowerPalette.canvas,  // notice messages
            StowerPalette.surface,  // row summaries/ages, inactive tab segments
            StowerPalette.rowHover,  // row secondary text while hovered
            StowerPalette.pillFill  // Contacts banner caption
        ]
    )
    internal func secondaryTextIsBodyLegible(on fill: Color) {
        #expect(Self.contrast(StowerPalette.textSecondary, fill) >= Self.bodyContrast)
    }

    @Test("coral carries legible white text (the from-me bubble) and works as an icon on cream")
    internal func coralIsLegibleUnderWhiteAndOnCream() {
        // The from-me thread bubble renders normal white body text on coral → AA body.
        #expect(Self.contrast(StowerPalette.coral, .white) >= Self.bodyContrast)
        // Coral as an icon/fill on the cream canvas → AA large/UI.
        #expect(Self.contrast(StowerPalette.coral, StowerPalette.canvas) >= Self.largeOrUIContrast)
    }

    @Test("the peach Reply fill carries a legible dark label (white fails AA on peach)")
    internal func peachReplyLabelIsLegible() {
        #expect(Self.contrast(StowerPalette.textPrimary, StowerPalette.peach) >= Self.bodyContrast)
    }

    /// The sRGB components (0…1) of a `#RRGGBB` string — the independent source of truth
    /// the resolved tokens are compared against (so a typo in a token's components fails).
    private struct SpecColor {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Parses a `#RRGGBB` string into its sRGB components.
    private static func components(hex: String) -> SpecColor {
        let digits = hex.dropFirst()
        let value = UInt32(digits, radix: 16) ?? 0
        return SpecColor(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// The WCAG contrast ratio between two palette tokens, resolved in forced light.
    private static func contrast(_ foreground: Color, _ background: Color) -> Double {
        let lighter = max(luminance(foreground), luminance(background))
        let darker = min(luminance(foreground), luminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// WCAG relative luminance from a token's linearized sRGB components.
    private static func luminance(_ color: Color) -> Double {
        let resolved = color.resolve(in: lightEnvironment)
        return 0.2126 * Double(resolved.linearRed)
            + 0.7152 * Double(resolved.linearGreen)
            + 0.0722 * Double(resolved.linearBlue)
    }
}
