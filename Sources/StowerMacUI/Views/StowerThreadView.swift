import SwiftUI

/// The tap-through thread read: readable bubbles plus "Open in Messages".
///
/// Bubbles render in `recentMessages` order (oldest-first, never re-sorted), the
/// side comes from `isFromMe`, and the most-recent line is emphasized. The non-text
/// rule is identical to the board: a placeholder is italic and angle-bracketed.
/// "Open in Messages" is disabled when the row carries no deep link.
internal struct StowerThreadView: View {
    @State private var model: StowerThreadViewModel

    /// Wraps a thread view-model built by the board for the tapped row.
    internal init(model: StowerThreadViewModel) {
        _model = State(initialValue: model)
    }

    internal var body: some View {
        content
            .navigationTitle(model.row.counterpart)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Open in Messages") { model.openInMessages() }
                        .disabled(!model.canOpenInMessages)
                }
            }
            .task { model.onAppear() }
            .onDisappear { model.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .controlSize(.large)
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
            thread
        }
    }

    private var thread: some View {
        ScrollView {
            LazyVStack(spacing: StowerBoardTheme.threadSpacing) {
                ForEach(model.lines) { line in
                    StowerThreadBubbleRow(line: line)
                }
            }
            .padding()
        }
    }
}

/// One thread bubble, sided by `isFromMe` and emphasized when most recent.
private struct StowerThreadBubbleRow: View {
    let line: StowerThreadLine

    var body: some View {
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
                line.isFromMe ? StowerBoardTheme.outboundBubble : StowerBoardTheme.inboundBubble,
                in: RoundedRectangle(cornerRadius: StowerBoardTheme.bubbleCornerRadius)
            )
            .foregroundStyle(line.isFromMe ? Color.white : Color.primary)
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

/// A centered notice used for the thread's empty and error states.
private struct StowerThreadNotice: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: StowerBoardTheme.headerSpacing) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
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
