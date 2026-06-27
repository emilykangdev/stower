import SwiftUI

/// One conversation bubble, sided by `isFromMe` and emphasized when most recent.
///
/// Extracted from the retired standalone thread screen so the corner composer's
/// read-only scrollback and any other caller share ONE renderer — the
/// placeholder-italic (`<Sent an attachment>`) and most-recent-emphasis rules never
/// drift between two copies.
internal struct StowerThreadBubbleRow: View {
    internal let line: StowerThreadLine

    internal var body: some View {
        HStack(spacing: 0) {
            if line.isFromMe { Spacer(minLength: StowerBoardTheme.rowSpacing) }
            bubble
            if !line.isFromMe { Spacer(minLength: StowerBoardTheme.rowSpacing) }
        }
    }

    private var bubble: some View {
        label
            .padding(StowerBoardTheme.bubblePadding)
            .background(
                line.isFromMe ? StowerPalette.coral : StowerPalette.incomingBubble,
                in: RoundedRectangle(cornerRadius: StowerBoardTheme.bubbleCornerRadius)
            )
            .foregroundStyle(line.isFromMe ? Color.white : StowerPalette.textPrimary)
    }

    @ViewBuilder private var label: some View {
        let weight: Font.Weight = line.isMostRecent ? .semibold : .regular
        if line.summary.isPlaceholder {
            Text("<\(line.summary.label)>")
                .font(.body.weight(weight).italic())
                .textSelection(.enabled)
        } else {
            Text(line.summary.label)
                .font(.body.weight(weight))
                .textSelection(.enabled)
        }
    }
}
