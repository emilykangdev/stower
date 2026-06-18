import SwiftUI

/// One debt-board row: "Xd" age, monogram, counterpart, and last-act summary.
///
/// The age leads in a fixed-width column so the days line up down the left edge
/// and scan at a glance. The summary renders the engine's non-text rule verbatim —
/// italic and angle-bracketed for a placeholder (`<Sent an attachment>`), plain for
/// real text — so a media act is never a blank or stale snippet. No confidence is
/// shown (v1 renders list membership only).
internal struct StowerNoReplyRowView: View {
    internal let row: StowerBoardRow

    internal var body: some View {
        HStack(spacing: StowerBoardTheme.rowSpacing) {
            age
            monogram
            VStack(alignment: .leading, spacing: StowerBoardTheme.rowTextSpacing) {
                Text(row.counterpart)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                summary
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, StowerBoardTheme.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }

    private var age: some View {
        Text("\(row.ageInDays)d")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: StowerBoardTheme.dayColumnWidth, alignment: .trailing)
            .accessibilityLabel("\(row.ageInDays) days")
    }

    private var monogram: some View {
        Text(row.monogram)
            .font(.callout.weight(.semibold))
            .foregroundStyle(StowerBoardTheme.monogramForeground)
            .frame(width: StowerBoardTheme.monogramSize, height: StowerBoardTheme.monogramSize)
            .background(StowerBoardTheme.monogramBackground, in: Circle())
            .accessibilityHidden(true)
    }

    @ViewBuilder private var summary: some View {
        let text = Text(row.summary.label)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        if row.summary.isPlaceholder {
            Text("<\(row.summary.label)>")
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            text
        }
    }
}
