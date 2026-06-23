import SwiftUI

/// A centered notice for the board's caught-up, error, per-lens-empty, and
/// empty-Drafts states.
///
/// Extracted so the board surface and the Drafts list share one notice style
/// instead of each rolling its own.
internal struct StowerBoardNotice<Action: View>: View {
    internal let symbol: String
    internal let title: String
    internal let message: String
    @ViewBuilder internal let action: () -> Action

    internal init(
        symbol: String,
        title: String,
        message: String,
        @ViewBuilder action: @escaping () -> Action = { EmptyView() }
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action
    }

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
            action()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
