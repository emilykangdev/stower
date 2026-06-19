import SwiftUI

/// The lower-right corner composer — the ONLY conversation surface.
///
/// Top to bottom: a header (avatar + name + day-age + close), the read-only
/// conversation scrollback for context (the shared `StowerThreadBubbleRow` over the
/// embedded `StowerThreadViewModel`, scrollable), the private draft editor
/// (`StowerDraftField`, Return = newline, write-through), and "Reply in Messages".
/// Instantiated only while open. Closing dismisses it — the draft is already
/// persisted write-through, so there is nothing to save on close.
internal struct StowerDraftComposer: View {
    internal let row: StowerBoardRow
    internal let thread: StowerThreadViewModel
    @Binding internal var draft: String
    internal let onReplyInMessages: () -> Void
    internal let onClose: () -> Void

    internal var body: some View {
        VStack(alignment: .leading, spacing: StowerBoardTheme.headerSpacing) {
            header
            Divider()
            scrollback
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            StowerDraftField(text: $draft)
            replyControls
        }
        .padding()
        // Width is fixed (the window is always wider than this); height is a CAP, not
        // a fixed size, so on a short window the composer shrinks (its scrollback
        // gives) instead of overflowing and clipping the header/close (JC-B).
        .frame(width: Self.width)
        .frame(maxHeight: Self.maxHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .shadow(radius: Self.shadowRadius, y: Self.shadowOffset)
        .padding(Self.cornerInset)
    }

    private var header: some View {
        HStack(spacing: StowerBoardTheme.rowSpacing) {
            StowerCounterpartAvatar(monogram: row.monogram, hasResolvedName: row.hasResolvedName)
            VStack(alignment: .leading, spacing: StowerBoardTheme.rowTextSpacing) {
                Text(row.counterpart)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(row.ageInDays)d")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(row.ageInDays) days")
            }
            Spacer(minLength: 0)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close composer")
        }
    }

    @ViewBuilder private var scrollback: some View {
        switch thread.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            StowerThreadNotice(
                symbol: "bubble.left",
                title: "No messages to show",
                message: "This conversation has no readable messages on this Mac."
            )
        case .error:
            StowerThreadNotice(
                symbol: "exclamationmark.triangle",
                title: "Couldn't read this thread",
                message: "Stower reached your Messages data but couldn't read this conversation."
            )
        case .loaded:
            ScrollView {
                LazyVStack(spacing: StowerBoardTheme.threadSpacing) {
                    ForEach(thread.lines) { line in
                        StowerThreadBubbleRow(line: line)
                    }
                }
            }
        }
    }

    private var replyControls: some View {
        VStack(alignment: .leading, spacing: StowerBoardTheme.rowTextSpacing) {
            Button {
                onReplyInMessages()
            } label: {
                Label("Reply in Messages", systemImage: "arrowshape.turn.up.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!row.canOpenInMessages)
            Text("Never sent — Stower drops your draft into Messages for you to send.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static let width: CGFloat = 360
    private static let maxHeight: CGFloat = 480
    private static let cornerRadius: CGFloat = 16
    private static let cornerInset: CGFloat = 16
    private static let shadowRadius: CGFloat = 16
    private static let shadowOffset: CGFloat = 4
}

/// A centered notice for the composer scrollback's empty and error states.
///
/// Relocated from the retired standalone thread screen; the composer is the only
/// place that still shows these thread-read states.
internal struct StowerThreadNotice: View {
    internal let symbol: String
    internal let title: String
    internal let message: String

    internal var body: some View {
        VStack(spacing: StowerBoardTheme.headerSpacing) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
