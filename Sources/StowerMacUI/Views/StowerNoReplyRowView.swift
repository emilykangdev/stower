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
                    .font(StowerType.rowName)
                    .foregroundStyle(StowerPalette.textPrimary)
                    .lineLimit(1)
                summary
                if let draftPreview {
                    draftLine(draftPreview)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, StowerBoardTheme.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }

    private var age: some View {
        Text("\(row.ageInDays)d")
            .font(.callout.monospacedDigit())
            .foregroundStyle(StowerPalette.textSecondary)
            .frame(width: StowerBoardTheme.dayColumnWidth, alignment: .trailing)
            .accessibilityLabel("\(row.ageInDays) days")
    }

    @ViewBuilder private var summary: some View {
        if row.summary.isPlaceholder {
            Text("<\(row.summary.label)>")
                .font(.callout.italic())
                .foregroundStyle(StowerPalette.textSecondary)
                .lineLimit(1)
        } else {
            Text(row.summary.label)
                .font(.callout)
                .foregroundStyle(StowerPalette.textSecondary)
                .lineLimit(1)
        }
    }

    /// The collapsed draft preview: a leading coral pencil glyph + truncated draft text.
    ///
    /// Only the glyph carries coral (icon/fill — JC6); the text stays warm near-black so
    /// small coral text on cream never trips WCAG-AA. The pencil + position keep it
    /// distinct from the gray last-message summary above it.
    private func draftLine(_ preview: String) -> some View {
        HStack(spacing: StowerBoardTheme.rowTextSpacing) {
            Image(systemName: "pencil")
                .foregroundStyle(StowerPalette.coral)
            Text(preview)
                .foregroundStyle(StowerPalette.textPrimary)
        }
        .font(.callout)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Draft: \(preview)")
    }
}
