import SwiftUI

/// The lower-right corner composer — the ONLY conversation surface.
///
/// Top to bottom: a header (avatar + name + day-age + close), the read-only
/// conversation scrollback for context (the shared `StowerThreadBubbleRow` over the
/// embedded `StowerThreadViewModel`, scrollable), the private draft editor
/// (`StowerDraftField`, Return = newline, write-through), and the two-step reply
/// control: "Reply in Messages" (drops the draft), which replaces itself with
/// "Mark as sent" (resolves the draft and closes the composer, D1). Instantiated
/// only while open. Closing dismisses it — the draft is already persisted
/// write-through, so there is nothing to save on close.
internal struct StowerDraftComposer: View {
    internal let row: StowerBoardRow
    internal let thread: StowerThreadViewModel
    @Binding internal var draft: String
    internal let onReplyInMessages: () -> Void
    internal let onMarkSent: () -> Void
    internal let onClose: () -> Void

    /// Whether "Reply in Messages" has been clicked this composer session.
    ///
    /// View-local (JC3): released automatically when the composer is torn down on
    /// close, and reset on a conversation switch via the view's `.id(row.chatID)` —
    /// no manual cleanup needed, unlike a view-model-held flag would require.
    /// Deliberately NOT derived from `resolvedAt` (A2/bad-pattern): the record stays
    /// `nil` throughout this toggle, so only an ephemeral flag can distinguish
    /// before/after the first click. Reset by a further edit to `draft` (see
    /// `body`'s `.onChange`) — **Codex P2**: without this, editing after a drop
    /// left "Mark as sent" showing for a body that was never actually re-dropped
    /// into Messages, so resolving it would silently discard the edit's intent.
    @State private var repliedThisSession = false

    internal var body: some View {
        VStack(alignment: .leading, spacing: StowerBoardTheme.headerSpacing) {
            header
            Divider()
            scrollback
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            StowerDraftField(text: $draft)
            replyControls
        }
        // A further edit after "Reply in Messages" means the dropped text is now
        // stale — revert to "Reply in Messages" so the user re-drops the current
        // body rather than "Mark as sent" resolving text Messages never saw.
        .onChange(of: draft) { _, _ in
            repliedThisSession = false
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
            // `lines` is oldest-first, so anchor to the bottom: the composer opens
            // showing the most recent messages (iMessage-style) instead of scrolled
            // to the top at the oldest message.
            ScrollView {
                LazyVStack(spacing: StowerBoardTheme.threadSpacing) {
                    ForEach(thread.lines) { line in
                        StowerThreadBubbleRow(line: line)
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    @ViewBuilder private var replyControls: some View {
        if !repliedThisSession {
            VStack(alignment: .leading, spacing: StowerBoardTheme.rowTextSpacing) {
                Button {
                    onReplyInMessages()
                    repliedThisSession = true
                } label: {
                    Label("Reply in Messages", systemImage: "arrowshape.turn.up.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                // Stays enabled even without a deep link: `StowerMessagesDropper.drop`
                // always writes the draft to the clipboard first and only skips the
                // conversation open when `deepLink` is nil, so the promised copy-only
                // fallback stays reachable for rows the engine can't form an `sms:` URL
                // for.
                Text("Draft copied — press ⌘V to paste it into Messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: StowerBoardTheme.rowTextSpacing) {
                Button {
                    onMarkSent()
                    repliedThisSession = false
                } label: {
                    Label("Mark as sent", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("Already sent from Messages? Mark this draft as sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
