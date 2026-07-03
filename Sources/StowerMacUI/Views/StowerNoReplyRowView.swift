import SwiftUI

/// One debt-board row: "Xd" age, monogram, counterpart, last-act summary, and — when
/// the conversation has a draft — a compact one-line draft preview below the summary.
///
/// The age leads in a fixed-width column so the days line up down the left edge and
/// scan at a glance. The avatar shows the contact's initials when a Contacts name
/// resolved, and a generic person glyph for an unknown handle. The summary renders
/// the engine's non-text rule verbatim — italic and angle-bracketed for a placeholder
/// (`<Sent an attachment>`), plain for real text. A row with no draft looks exactly as
/// it did before; a drafted row adds a leading-pencil preview line BELOW the summary,
/// never displacing it. No confidence is shown (v1 renders list membership only).
internal struct StowerNoReplyRowView: View {
    internal let row: StowerBoardRow

    /// The draft preview text, or `nil` when this conversation has no draft.
    internal let draftPreview: String?

    /// Creates a row view, optionally carrying a one-line draft preview.
    internal init(row: StowerBoardRow, draftPreview: String? = nil) {
        self.row = row
        self.draftPreview = draftPreview
    }

    internal var body: some View {
        HStack(spacing: StowerBoardTheme.rowSpacing) {
            age
            StowerCounterpartAvatar(monogram: row.monogram, hasResolvedName: row.hasResolvedName)
            VStack(alignment: .leading, spacing: StowerBoardTheme.rowTextSpacing) {
                Text(row.counterpart)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                summary
                if let draftPreview {
                    draftLine(draftPreview)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, StowerBoardTheme.rowVerticalPadding)
        // Make the whole row rectangle a hit target: SwiftUI only hit-tests drawn
        // content, so without this the Spacer, inter-element spacing, and padding
        // fall through and only taps on the text/avatar open the composer.
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var age: some View {
        Text("\(row.ageInDays)d")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: StowerBoardTheme.dayColumnWidth, alignment: .trailing)
            .accessibilityLabel("\(row.ageInDays) days")
    }

    @ViewBuilder private var summary: some View {
        if row.summary.isPlaceholder {
            Text("<\(row.summary.label)>")
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(row.summary.label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// The collapsed draft preview: a leading pencil glyph + truncated draft text,
    /// visually distinct from (and below) the last-message summary.
    private func draftLine(_ preview: String) -> some View {
        Label(preview, systemImage: "pencil")
            .font(.callout)
            .foregroundStyle(StowerBoardTheme.monogramForeground)
            .lineLimit(1)
            .accessibilityLabel("Draft: \(preview)")
    }
}
