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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    internal var body: some View {
        VStack(alignment: .leading, spacing: StowerBoardTheme.headerSpacing) {
            header
            sectionLabel("CONTEXT")
            scrollback
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            sectionLabel("Draft — private note")
            StowerDraftField(text: $draft)
            replyControls
        }
        .padding()
        // Width is fixed (the window is always wider than this); height is a CAP, not
        // a fixed size, so on a short window the composer shrinks (its scrollback
        // gives) instead of overflowing and clipping the header/close (JC-B).
        .frame(width: Self.width)
        .frame(maxHeight: Self.maxHeight)
        .background(surface)
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(StowerPalette.divider, lineWidth: 1)
        )
        .shadow(radius: Self.shadowRadius, y: Self.shadowOffset)
        .padding(Self.cornerInset)
    }

    /// The composer's warm surface: a frosted material warmed by a `surface` tint, with
    /// an opaque `surfaceSolid` fallback when Reduce Transparency is on (the canonical
    /// material pattern, A4).
    @ViewBuilder private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)
        if reduceTransparency {
            shape.fill(StowerPalette.surfaceSolid)
        } else {
            shape.fill(.regularMaterial)
                .overlay { shape.fill(StowerPalette.surface.opacity(Self.materialWarmth)) }
        }
    }

    /// A small uppercase section label (variant-E composer anatomy) marking the
    /// read-only context above the private draft note.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(StowerPalette.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    private var header: some View {
        HStack(spacing: StowerBoardTheme.rowSpacing) {
            StowerCounterpartAvatar(monogram: row.monogram, hasResolvedName: row.hasResolvedName)
            VStack(alignment: .leading, spacing: StowerBoardTheme.rowTextSpacing) {
                Text(row.counterpart)
                    .font(StowerType.title)
                    .tracking(StowerType.titleTracking)
                    .foregroundStyle(StowerPalette.textPrimary)
                    .lineLimit(1)
                Text("\(row.ageInDays)d")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(StowerPalette.textSecondary)
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
            .buttonStyle(StowerProminentButtonStyle())
            // Stays enabled even without a deep link: `StowerMessagesDropper.drop`
            // always writes the draft to the clipboard first and only skips the
            // open/paste when `deepLink` is nil, so the promised copy-only fallback
            // stays reachable for rows the engine can't form an `sms:` URL for.
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

    /// How strongly the `surface` tint warms the frosted material (0 = bare material,
    /// 1 = opaque surface).
    private static let materialWarmth = 0.55
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
