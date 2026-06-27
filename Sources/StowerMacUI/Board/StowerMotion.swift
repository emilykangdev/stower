import SwiftUI

/// The board's motion tokens — the single source of truth for every animation curve on
/// the board, composer, and drafts surfaces.
///
/// Each token takes the view's `accessibilityReduceMotion` flag and returns an
/// `Animation?` that is **nil when motion is reduced**, so gating is structural: a view
/// passes the token to `.animation(_:value:)` or `withAnimation(_:)` and Reduce Motion
/// degrades it to an instant state change with no per-view conditional. Reduce Motion is
/// read in the *view* (never the view-model) and passed in.
///
/// Raw curve literals (`.spring`/`.smooth`/`.snappy`) live ONLY here — every consuming
/// view references a token by name, so durations/springs are tuned in one file and the
/// no-raw-animation precheck guard can scope its ban to everywhere *but* this file (plus
/// the `StowerDismissUndoBar` `.linear` drain, which is per-tick, not a curve).
internal enum StowerMotion {
    /// The dismiss row-removal + gap-close spring (the "most-felt" motion).
    ///
    /// Applied value-based on the list — `withAnimation { dismiss() }` animates nothing
    /// because the dismiss is async (A5).
    internal static func removal(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: removalResponse, dampingFraction: removalDamping)
    }

    /// The corner composer's spring entrance/exit, wrapped synchronously around the
    /// `composerChatID` mutation sites.
    internal static func composer(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: composerResponse, dampingFraction: composerDamping)
    }

    /// The tab/segment-switch cross-fade.
    internal static func tabSwitch(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: tabSwitchDuration)
    }

    /// The whole-screen and undo-bar cross-fade (replaces the old `easeInOut` literals).
    internal static func crossFade(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: crossFadeDuration)
    }

    /// The press-feedback scale spring (drives `StowerPressableButtonStyle`).
    internal static func press(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: pressResponse, dampingFraction: pressDamping)
    }

    // MARK: Tuning constants (tune on-device via design-review; one file)

    private static let removalResponse = 0.34
    private static let removalDamping = 0.86
    private static let composerResponse = 0.32
    private static let composerDamping = 0.82
    private static let tabSwitchDuration = 0.22
    private static let crossFadeDuration = 0.20
    private static let pressResponse = 0.25
    private static let pressDamping = 0.7

    /// How far a pressed control scales down (subtle — felt, not loud).
    internal static let pressedScale = 0.97
}

/// A button style that adds a subtle press-scale, gated on Reduce Motion.
///
/// Row hover fills and the warm focus ring live with their controls (the row tracks
/// hover by id; the segmented pill owns its per-segment focus ring) — this style is the
/// shared press-feedback half of the "press/hover/focus" treatment.
internal struct StowerPressableButtonStyle: ButtonStyle {
    internal func makeBody(configuration: Configuration) -> some View {
        StowerPressableButtonBody(configuration: configuration)
    }

    /// Reads Reduce Motion (a `ButtonStyle` can't hold `@Environment` directly) so the
    /// press spring degrades to an instant scale when motion is reduced.
    private struct StowerPressableButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? StowerMotion.pressedScale : 1)
                .animation(StowerMotion.press(reduceMotion), value: configuration.isPressed)
        }
    }
}

/// The warm prominent pill that replaces `.borderedProminent` on board surfaces — a
/// filled capsule with a `textPrimary` label (white fails AA on peach) and the same
/// Reduce-Motion-gated press-scale.
///
/// Defaults to peach (the "Reply in Messages" / Contacts-banner action); the deeper
/// `coral` is available for a higher-emphasis action.
internal struct StowerProminentButtonStyle: ButtonStyle {
    /// The capsule fill (peach by default).
    internal var fill: Color = StowerPalette.peach

    internal func makeBody(configuration: Configuration) -> some View {
        StowerProminentButtonBody(configuration: configuration, fill: fill)
    }

    private struct StowerProminentButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let fill: Color
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(StowerPalette.textPrimary)
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, Self.verticalPadding)
                .background(fill, in: Capsule())
                .scaleEffect(configuration.isPressed ? StowerMotion.pressedScale : 1)
                .animation(StowerMotion.press(reduceMotion), value: configuration.isPressed)
        }

        private static let horizontalPadding: CGFloat = 14
        private static let verticalPadding: CGFloat = 8
    }
}
