import SwiftUI

/// The board's type scale — the typeface-swap seam.
///
/// Variant E specifies Gabarito (headers) + Figtree (body); bundling those `.ttf`s is
/// deferred this sprint (SPM font tail-risk vs. the deadline). Until then every board
/// font flows through this one helper using the system face at the variant-E
/// weight/size relationships, so adopting the real typeface later is a one-file edit:
/// change `design` to `.custom("Gabarito"/"Figtree", …)` here and nothing at the call
/// sites moves. Tokens stay **relative** to the semantic text styles so Dynamic Type
/// still scales them.
internal enum StowerType {
    /// Notice/zero-state titles.
    internal static let display = Font.system(.title3, design: design).weight(.semibold)

    /// Names and section headers (composer header, row counterpart).
    internal static let title = Font.system(.headline, design: design).weight(.semibold)

    /// A medium-weight row name — heavier than body, lighter than `title`.
    internal static let rowName = Font.system(.body, design: design).weight(.medium)

    /// Standard reading text.
    internal static let body = Font.system(.body, design: design)

    /// Summaries, draft previews, and secondary lines.
    internal static let callout = Font.system(.callout, design: design)

    /// Ages and timestamps.
    internal static let caption = Font.system(.caption, design: design)

    /// Slightly tightened tracking on display/title text — modern-sans density.
    internal static let titleTracking: CGFloat = -0.2

    /// The single typeface seam. `.default` is the system face this sprint; swap to a
    /// `.custom(_:relativeTo:)`-backed design once the Gabarito/Figtree bundle lands.
    private static let design: Font.Design = .default
}
