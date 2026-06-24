import SwiftUI

/// The circular counterpart avatar shared by the board row, the Drafts card, and
/// the composer header.
///
/// One renderer for the resolved-name rule: a named conversation shows its initials
/// monogram; an unresolved handle shows a generic person glyph (so every unknown
/// `+1…` number doesn't collapse to an identical "1").
internal struct StowerCounterpartAvatar: View {
    internal let monogram: String
    internal let hasResolvedName: Bool

    internal var body: some View {
        Group {
            if hasResolvedName {
                Text(monogram)
                    .font(.callout.weight(.semibold))
            } else {
                Image(systemName: "person.fill")
                    .font(.callout)
                    .imageScale(.medium)
            }
        }
        .foregroundStyle(StowerBoardTheme.monogramForeground)
        .frame(width: StowerBoardTheme.monogramSize, height: StowerBoardTheme.monogramSize)
        .background(StowerBoardTheme.monogramBackground, in: Circle())
        .accessibilityHidden(true)
    }
}
