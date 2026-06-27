import SwiftUI

/// The Drafts tab: one card per on-board conversation that has a draft.
///
/// Each card shows the avatar, name, the conversation's day-age, a two-line draft
/// preview, and when it was last edited. Tapping a card opens the same
/// `StowerDraftComposer`. A drafted conversation still appears in its Your turn /
/// Maybe follow up tab too — this is a lens, not a move.
internal struct StowerDraftsList: View {
    internal let cards: [StowerDraftCard]
    internal let onSelect: (StowerBoardRow) -> Void

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
                    Button {
                        onSelect(card.row)
                    } label: {
                        StowerDraftCardView(card: card)
                    }
                    .buttonStyle(StowerPressableButtonStyle())
                    .listRowBackground(StowerPalette.surface)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
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
                        .font(StowerType.rowName)
                        .foregroundStyle(StowerPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(card.row.ageInDays)d")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(StowerPalette.textSecondary)
                        .accessibilityLabel("\(card.row.ageInDays) days")
                }
                Text(card.entry.body)
                    .font(.callout)
                    .foregroundStyle(StowerPalette.textPrimary)
                    .lineLimit(Self.previewLines)
                Text("Edited \(card.entry.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(StowerPalette.textSecondary)
            }
        }
        .padding(.vertical, StowerBoardTheme.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }

    private static let previewLines = 2
}
