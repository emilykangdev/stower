import SwiftUI

/// The low-salience `Muted Senders…` toolbar control and its management popover
/// (JC2 variant A).
///
/// An icon-only bell-slash button that is shown ONLY when at least one sender is muted
/// (an exclusion list should never pull attention with a count chip on the board). It
/// opens an anchored popover listing each muted sender — name-resolved, sorted
/// alphabetically — with an inline Unmute. The popover STAYS OPEN across unmutes
/// (closing only on an outside click), and a quiet "Dismissed" pill on a row warns
/// that the person will stay hidden by an active dismissal even after unmuting.
internal struct StowerMutedSendersButton: View {
    /// The muted senders to list (name-resolved + sorted by the data source).
    internal let senders: [StowerMutedSender]

    /// Whether the sender list is loading (drives a loading row, not a false empty).
    internal let isLoading: Bool

    /// Whether the popover is open — shared so the zero-state "Manage…" can open it too.
    @Binding internal var isPresented: Bool

    /// Loads the (name-resolved) muted senders — called as the popover opens.
    internal let onOpen: () -> Void

    /// Unmutes one sender; the list refreshes and the popover stays open.
    internal let onUnmute: (StowerMutedSender) -> Void

    internal var body: some View {
        Button {
            // Load explicitly here (not via `.onChange`): the zero-state "Manage…" link
            // can flip `isPresented` from elsewhere, and an onChange-driven load is
            // fragile across those entry points. Both call `onOpen()` before presenting.
            onOpen()
            isPresented = true
        } label: {
            Image(systemName: "bell.slash")
        }
        .help("Muted senders")
        .accessibilityLabel("Muted senders")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            StowerMutedSendersPopover(senders: senders, isLoading: isLoading, onUnmute: onUnmute)
        }
    }
}

/// The popover body: a titled, scrollable list of muted senders with inline Unmute.
private struct StowerMutedSendersPopover: View {
    let senders: [StowerMutedSender]
    let isLoading: Bool
    let onUnmute: (StowerMutedSender) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Self.titleSpacing) {
            Text("Muted senders")
                .font(.headline)
            Text("Hidden from this board, not from Messages.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            if senders.isEmpty, isLoading {
                // Loading, not empty — don't flash "No muted senders" before the first
                // (address-book-enumerating) load resolves.
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, Self.emptyVerticalPadding)
            } else if senders.isEmpty {
                Text("No muted senders.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Self.emptyVerticalPadding)
            } else {
                ScrollView {
                    VStack(spacing: Self.rowSpacing) {
                        ForEach(senders) { sender in
                            StowerMutedSenderRow(sender: sender) { onUnmute(sender) }
                        }
                    }
                }
                .frame(maxHeight: Self.listMaxHeight)
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width)
    }

    private static let titleSpacing: CGFloat = 6
    private static let rowSpacing: CGFloat = 4
    private static let emptyVerticalPadding: CGFloat = 8
    private static let listMaxHeight: CGFloat = 320
    private static let padding: CGFloat = 14
    private static let width: CGFloat = 280
}

/// One muted-sender row: avatar, name, a "Dismissed" pill when also actively
/// dismissed, and an inline Unmute.
private struct StowerMutedSenderRow: View {
    let sender: StowerMutedSender
    let onUnmute: () -> Void

    var body: some View {
        HStack(spacing: StowerBoardTheme.rowSpacing) {
            StowerCounterpartAvatar(
                monogram: StowerBoardRow.monogram(for: sender.displayName),
                hasResolvedName: sender.hasResolvedName
            )
            VStack(alignment: .leading, spacing: Self.textSpacing) {
                Text(sender.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if sender.isActivelyDismissed {
                    dismissedPill
                }
            }
            Spacer(minLength: 0)
            Button("Unmute", action: onUnmute)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, Self.rowVerticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        // Combining hides the inline Unmute button, so re-expose it as a VoiceOver action.
        .accessibilityAction(named: Text("Unmute")) { onUnmute() }
    }

    /// The quiet pill warning the person stays hidden by an active dismissal even
    /// after unmuting (the dismiss × mute AND-logic; see the plan's Open questions).
    private var dismissedPill: some View {
        Text("Dismissed")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Self.pillHorizontalPadding)
            .padding(.vertical, Self.pillVerticalPadding)
            .background(Color.secondary.opacity(Self.pillOpacity), in: Capsule())
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        sender.isActivelyDismissed
            ? "\(sender.displayName), also dismissed"
            : sender.displayName
    }

    private static let textSpacing: CGFloat = 3
    private static let rowVerticalPadding: CGFloat = 4
    private static let pillHorizontalPadding: CGFloat = 6
    private static let pillVerticalPadding: CGFloat = 1
    private static let pillOpacity: CGFloat = 0.15
}
