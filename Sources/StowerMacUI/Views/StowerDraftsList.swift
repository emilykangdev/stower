import SwiftUI

/// The Drafts tab: one card per on-board conversation that has a draft.
///
/// Each card shows the avatar, name, the conversation's day-age, a two-line draft
/// preview, and when it was last edited. Tapping a card opens the same
/// `StowerDraftComposer`; a trailing checkmark marks the draft sent directly (Flow
/// 2, D2) without opening the composer. A drafted conversation still appears in its
/// Your turn / Maybe follow up tab too — this is a lens, not a move.
internal struct StowerDraftsList: View {
    internal let cards: [StowerDraftCard]
    internal let onSelect: (StowerBoardRow) -> Void

    /// Marks a card's draft sent directly from the checkmark (Flow 2, D2).
    internal let onMarkSent: (StowerBoardRow) -> Void

    internal var body: some View {
        if cards.isEmpty {
            StowerBoardNotice(
                symbol: "square.and.pencil",
                title: "No drafts yet",
                message: "Open a conversation and jot what you want to say. "
                    + "Private notes, never sent."
            )
        } else {
            List {
                ForEach(cards) { card in
                    // The checkmark is a SIBLING `.overlay` (NOT nested inside the
                    // card's label Button) — mirrors `StowerBoardViewTriage`'s
                    // hover-dismiss-control pattern (~89–124): it layers on top and
                    // takes the trailing-region taps, the card Button takes the
                    // rest, so there's no nested-button conflict.
                    Button {
                        onSelect(card.row)
                    } label: {
                        StowerDraftCardView(card: card)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .trailing) { markSentControl(card) }
                }
            }
        }
    }

    /// The trailing "Mark as sent" checkmark, sibling to the card's open button.
    private func markSentControl(_ card: StowerDraftCard) -> some View {
        Button {
            onMarkSent(card.row)
        } label: {
            Image(systemName: "checkmark.circle")
                .font(.title3)
                .frame(minWidth: Self.checkmarkHitTarget, minHeight: Self.checkmarkHitTarget)
        }
        .buttonStyle(.borderless)
        .help("Mark as sent")
        .accessibilityLabel("Mark as sent")
    }

    /// The checkmark's minimum tap target (accessibility spec: ≥28pt).
    private static let checkmarkHitTarget: CGFloat = 28
}

/// One Drafts-tab card.
private struct StowerDraftCardView: View {
    let card: StowerDraftCard

    var body: some View {
        HStack(alignment: .top, spacing: StowerBoardTheme.rowSpacing) {
            StowerCounterpartAvatar(
                monogram: card.row.monogram,
                hasResolvedName: card.row.hasResolvedName
            )
            VStack(alignment: .leading, spacing: StowerBoardTheme.rowTextSpacing) {
                HStack(spacing: StowerBoardTheme.rowTextSpacing) {
                    Text(card.row.counterpart)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(card.row.ageInDays)d")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(card.row.ageInDays) days")
                }
                Text(card.entry.body)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(Self.previewLines)
                Text("Edited \(card.entry.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, StowerBoardTheme.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }

    private static let previewLines = 2
}
