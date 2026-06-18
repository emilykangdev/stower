import SwiftUI

/// The debt board — the app's home once startup reaches `.connectedPreparingBoard`.
///
/// A direction toggle (Neglected / Waiting on them), a day-filter preset, and a
/// manual refresh control sit in the toolbar; the content switches on the
/// view-model's phase (preparing / rows / all-caught-up / error). Both lists come
/// from one `loadBoard`, so the toggle never re-queries (I7); changing the preset
/// re-loads (I8). Tapping a row pushes the thread read.
internal struct StowerBoardView: View {
    @Bindable internal var model: StowerBoardViewModel
    @State private var selectedRow: StowerBoardRow?

    internal var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .principal) { directionPicker }
                    ToolbarItem(placement: .primaryAction) { presetPicker }
                    ToolbarItem(placement: .primaryAction) { refreshButton }
                }
                .navigationDestination(item: $selectedRow) { row in
                    StowerThreadView(model: model.makeThreadViewModel(for: row))
                }
        }
        .task { model.onAppear() }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .preparing:
            StowerConnectedLoadingView()
        case .caughtUp:
            caughtUpNotice
        case .error:
            errorNotice
        case .rows:
            rowsList
        }
    }

    @ViewBuilder private var rowsList: some View {
        let rows = model.board?.rows(for: model.direction) ?? []
        if rows.isEmpty {
            StowerBoardNotice(
                symbol: "tray",
                title: "Nothing in this list",
                message: emptyDirectionMessage
            )
        } else {
            List {
                ForEach(rows) { row in
                    Button {
                        selectedRow = row
                    } label: {
                        StowerNoReplyRowView(row: row)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var caughtUpNotice: some View {
        StowerBoardNotice(
            symbol: "checkmark.circle",
            title: "All caught up",
            message: "No conversations are waiting on a reply right now."
        )
    }

    private var errorNotice: some View {
        StowerBoardNotice(
            symbol: "exclamationmark.triangle",
            title: "Something went wrong",
            message: "Stower couldn't prepare your board. Try again in a moment."
        ) {
            Button("Retry") { model.retry() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var directionPicker: some View {
        Picker("Direction", selection: $model.direction) {
            ForEach(StowerBoardDirection.allCases) { direction in
                Text(direction.title).tag(direction)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var presetPicker: some View {
        let binding = Binding(
            get: { model.selectedPreset },
            set: { model.selectPreset($0) }
        )
        return Picker("Unanswered for", selection: binding) {
            ForEach(StowerDayPreset.allCases) { preset in
                Text(preset.title).tag(preset)
            }
        }
    }

    private var refreshButton: some View {
        Button {
            model.refresh()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .disabled(model.isRefreshing)
        .help("Refresh the board")
        .accessibilityLabel("Refresh board")
    }

    private var emptyDirectionMessage: String {
        switch model.direction {
        case .neglected: return "No conversations are waiting on your reply in this window."
        case .ghosted: return "No conversations are waiting on their reply in this window."
        }
    }
}

/// A centered notice for the board's caught-up, error, and per-list-empty states.
private struct StowerBoardNotice<Action: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let action: () -> Action

    init(
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

    var body: some View {
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
