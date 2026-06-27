import SwiftUI

/// The multi-line draft editor inside `StowerDraftComposer`.
///
/// `axis: .vertical` makes Return insert a NEWLINE (never submit-and-collapse), so
/// multi-line drafting works; the binding writes through on every change (JC2), so
/// there is no submit or blur commit step. Used only inside the composer — never as
/// an inline-row sibling, which would put an editor on every board row and wreck the
/// at-rest scan.
internal struct StowerDraftField: View {
    @Binding internal var text: String

    internal var body: some View {
        TextField(Self.placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(Self.minLines...Self.maxLines)
            .padding(StowerBoardTheme.bubblePadding)
            .background(
                StowerPalette.incomingBubble.opacity(Self.fieldBackgroundOpacity),
                in: RoundedRectangle(cornerRadius: StowerBoardTheme.bubbleCornerRadius)
            )
            .accessibilityLabel("Draft")
    }

    private static let placeholder = "Draft a reply…"
    private static let minLines = 3
    private static let maxLines = 10
    private static let fieldBackgroundOpacity = 0.5
}
