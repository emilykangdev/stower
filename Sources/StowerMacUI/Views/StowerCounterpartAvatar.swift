import SwiftUI

/// The rounded-square (continuous-corner) counterpart avatar shared by the board
/// row, the Drafts card, and the composer header.
///
/// One renderer for the resolved-name rule: a named conversation shows its initials
/// monogram; an unresolved handle shows a generic person glyph (so every unknown
/// `+1…` number doesn't collapse to an identical "1"). The continuous-corner
/// squircle (vs. a plain circle) is the shape language the approved
/// board-header-revamp mockup locked in.
internal struct StowerCounterpartAvatar: View {
    internal let monogram: String
    internal let hasResolvedName: Bool

    internal var body: some View {
        Group {
            if hasResolvedName {
                Text(monogram)
                    .font(.callout.weight(.semibold))
            } else {
                Image("PhosphorUser")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .squareFrame(StowerBoardTheme.avatarGlyphSize)
            }
        }
        .foregroundStyle(StowerBoardTheme.monogramForeground)
        .squareFrame(StowerBoardTheme.monogramSize)
        .background(
            StowerBoardTheme.monogramBackground,
            in: RoundedRectangle(
                cornerRadius: StowerBoardTheme.avatarCornerRadius,
                style: .continuous
            )
        )
        .accessibilityHidden(true)
    }
}
