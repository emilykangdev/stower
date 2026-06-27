import SwiftUI

/// Layout and color tokens for the board surface, co-located so the board views
/// hold no loose magic numbers.
internal enum StowerBoardTheme {
    /// Diameter of a row's monogram avatar.
    internal static let monogramSize: CGFloat = 36

    /// Width of the leading day column, fixed so the ages line up into a single
    /// scannable column down the left edge regardless of digit count.
    internal static let dayColumnWidth: CGFloat = 40

    /// Corner radius of a thread bubble.
    internal static let bubbleCornerRadius: CGFloat = 14

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
}
