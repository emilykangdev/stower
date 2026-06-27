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
/// Contrast tiers follow WCAG: `bodyContrast` (4.5:1) for primary reading text,
/// `largeOrUIContrast` (3.0:1) for de-emphasized/UI text, icons, and fills. The
/// `textSecondary` token is held to the UI tier (it is de-emphasized caption text and
/// the approved spec value lands at ≈3.3:1 — kept exact rather than darkened, so the
/// palette never drifts from the design source of truth).
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
            (StowerPalette.textSecondary, "#8C857C"),
            (StowerPalette.coral, "#C75D43"),
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

    @Test("primary text clears AA body contrast on both warm surfaces")
    internal func primaryTextIsBodyLegible() {
        #expect(Self.contrast(StowerPalette.textPrimary, StowerPalette.canvas) >= Self.bodyContrast)
        #expect(
            Self.contrast(StowerPalette.textPrimary, StowerPalette.surface) >= Self.bodyContrast
        )
    }

    @Test("secondary text clears the AA large/UI tier on both warm surfaces")
    internal func secondaryTextIsUILegible() {
        #expect(
            Self.contrast(StowerPalette.textSecondary, StowerPalette.canvas)
                >= Self.largeOrUIContrast
        )
        #expect(
            Self.contrast(StowerPalette.textSecondary, StowerPalette.surface)
                >= Self.largeOrUIContrast
        )
    }

    @Test("coral works as an icon/fill on cream and carries legible white initials")
    internal func coralIsLegibleAsFill() {
        #expect(Self.contrast(StowerPalette.coral, StowerPalette.canvas) >= Self.largeOrUIContrast)
        #expect(Self.contrast(StowerPalette.coral, .white) >= Self.largeOrUIContrast)
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
