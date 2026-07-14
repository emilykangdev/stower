import SwiftUI

/// Layout and color tokens for the board surface, co-located so the board views
/// hold no loose magic numbers.
internal enum StowerBoardTheme {
    /// Diameter of a row's monogram avatar.
    internal static let monogramSize: CGFloat = 36

    /// Side length of the unresolved-handle person glyph inside a monogram avatar.
    ///
    /// The custom Phosphor icon (unlike an `Image(systemName:)`) has no automatic
    /// text-relative scaling, so this sizes it explicitly against `monogramSize`.
    internal static let avatarGlyphSize: CGFloat = 18

    /// Side length of a Phosphor toolbar/row icon glyph.
    ///
    /// Custom asset-catalog vector images (unlike `Image(systemName:)`) render at
    /// their raw intrinsic size with no automatic text-relative scaling — every
    /// Phosphor icon needs this explicit frame or it renders enormous.
    internal static let iconGlyphSize: CGFloat = 16

    /// Width of the leading day column, fixed so the ages line up into a single
    /// scannable column down the left edge regardless of digit count.
    internal static let dayColumnWidth: CGFloat = 40

    /// Corner radius of a thread bubble.
    internal static let bubbleCornerRadius: CGFloat = 14

    /// Corner radius of the counterpart avatar's continuous-corner (squircle) shape.
    ///
    /// Replaces the prior plain `Circle()` — a rounded-square badge is the shape
    /// language the approved board-header-revamp mockup (variant A2) locked in.
    internal static let avatarCornerRadius: CGFloat = 10

    /// Point size of the custom window-title text rendered in the toolbar's
    /// `.title` placement.
    ///
    /// Modest and toolbar-scale on purpose — the approved mockup's first pass came
    /// back oversized ("too large"), so this sits just above `rowSpacing`-adjacent
    /// body text rather than at marketing-headline scale.
    internal static let titleFontSize: CGFloat = 16

    /// Horizontal padding inside a board-tab pill.
    internal static let tabPillHorizontalPadding: CGFloat = 14

    /// Vertical padding inside a board-tab pill.
    internal static let tabPillVerticalPadding: CGFloat = 6

    /// Vertical spacing between a row's name and its summary line.
    internal static let rowTextSpacing: CGFloat = 2

    /// Horizontal spacing between the monogram and the row's text block.
    internal static let rowSpacing: CGFloat = 12

    /// Vertical padding inside a row.
    internal static let rowVerticalPadding: CGFloat = 6

    /// Spacing between the header controls and the list.
    internal static let headerSpacing: CGFloat = 12

    /// Padding around a thread bubble's text.
    internal static let bubblePadding: CGFloat = 10

    /// Spacing between thread bubbles.
    internal static let threadSpacing: CGFloat = 8

    /// Horizontal padding inside the Contacts-access banner.
    internal static let bannerHorizontalPadding: CGFloat = 14

    /// Vertical padding inside the Contacts-access banner.
    internal static let bannerVerticalPadding: CGFloat = 10

    /// Spacing between the banner's icon, text, and action.
    internal static let bannerSpacing: CGFloat = 10

    /// The tint behind a monogram avatar.
    internal static let monogramBackground = Color.accentColor.opacity(0.16)

    /// The tint behind the Contacts-access banner.
    internal static let bannerBackground = Color.accentColor.opacity(0.12)

    /// The foreground of a monogram's initials.
    internal static let monogramForeground = Color.accentColor

    /// The fill of an outbound (from-me) thread bubble.
    internal static let outboundBubble = Color.accentColor

    /// The fill of an inbound (counterpart) thread bubble — a gray that stays
    /// legible against the window background in both light and dark mode (the
    /// system control-background gray is nearly the dark window background).
    internal static let inboundBubble = Color.gray.opacity(0.3)
}

extension View {
    /// Applies an equal width/height frame.
    ///
    /// Every Phosphor icon glyph and the avatar's fallback glyph need this same
    /// explicit square frame (unlike `Image(systemName:)`, a custom vector asset
    /// has no automatic text-relative sizing) — shared here instead of repeating
    /// `.frame(width: x, height: x)` at each of the six call sites.
    internal func squareFrame(_ side: CGFloat) -> some View {
        frame(width: side, height: side)
    }
}
