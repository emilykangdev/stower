import AppKit
import SwiftUI

/// The debt board — the app's home once startup reaches `.connectedPreparingBoard`.
///
/// A content-area 3-segment tab control (Your turn / Maybe follow up / Drafts), a
/// day-filter preset, and a manual refresh sit above/around the list; the content
/// switches on the view-model's phase (preparing / rows / all-caught-up / error).
/// Both lens lists come from one `loadBoard`, so a lens tab never re-queries (I7);
/// changing the preset re-loads (I8). Clicking a row docks the `StowerDraftComposer`
/// in the lower-right corner — the only conversation surface.
internal struct StowerBoardView: View {
    @Bindable internal var model: StowerBoardViewModel

    internal var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { presetPicker }
                    ToolbarItem(placement: .primaryAction) { refreshButton }
                }
                .overlay(alignment: .bottomTrailing) { composerOverlay }
        }
        .task { model.onAppear() }
        .onDisappear { model.cancel() }
        .onReceive(Self.didBecomeActive) { _ in model.onAppBecameActive() }
    }

    /// Fires when the app returns to the foreground — the cue to re-check a Contacts
    /// grant the user may have made in System Settings.
    ///
    /// The board's `.task` does not re-run on an app switch; the view-model also
    /// closes the composer here on a revoke (I-ComposerClosesOnContactsRevoke).
    private static let didBecomeActive = NotificationCenter.default.publisher(
        for: NSApplication.didBecomeActiveNotification
    )

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .preparing:
            StowerConnectedLoadingView()
        case .caughtUp:
            caughtUpNotice
        case .error:
            errorNotice
        case .rows:
            boardSurface
        }
    }

    private var boardSurface: some View {
        VStack(spacing: 0) {
            if model.showsContactsAccessBanner {
                StowerContactsAccessBanner(actionTitle: model.contactsBannerActionTitle) {
                    model.resolveContactsAccess()
                }
            }
            tabBar
            tabContent
        }
    }

    private var tabBar: some View {
        Picker("Board tab", selection: $model.selectedTab) {
            ForEach(StowerBoardTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal)
        .padding(.vertical, StowerBoardTheme.rowVerticalPadding)
    }

    @ViewBuilder private var tabContent: some View {
        switch model.selectedTab {
        case .yourTurn:
            lensList(model.board?.rows(for: .neglected) ?? [], emptyMessage: Self.yourTurnEmpty)
        case .maybeFollowUp:
            lensList(model.board?.rows(for: .ghosted) ?? [], emptyMessage: Self.followUpEmpty)
        case .drafts:
            StowerDraftsList(cards: model.onBoardDrafts) { row in
                model.openComposer(for: row)
            }
        }
    }

    @ViewBuilder private func lensList(
        _ rows: [StowerBoardRow],
        emptyMessage: String
    ) -> some View {
        if rows.isEmpty {
            StowerBoardNotice(symbol: "tray", title: "Nothing in this list", message: emptyMessage)
        } else {
            List {
                ForEach(rows) { row in
                    Button {
                        model.openComposer(for: row)
                    } label: {
                        StowerNoReplyRowView(
                            row: row,
                            draftPreview: model.drafts[row.draftKey]?.body
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var composerOverlay: some View {
        if let row = model.composerRow, let thread = model.composerThread {
            StowerDraftComposer(
                row: row,
                thread: thread,
                draft: model.draftBinding(for: row.draftKey),
                onReplyInMessages: { model.dropIntoMessages(row) },
                onClose: { model.closeComposer() }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// The calm "all caught up" zero state — no scoreboard, just reassurance.
    private var caughtUpNotice: some View {
        StowerBoardNotice(
            symbol: "checkmark.circle",
            title: "You're all caught up",
            message: "No one's waiting on a reply right now."
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

    private static let yourTurnEmpty =
        "No conversations are waiting on your reply in this window."
    private static let followUpEmpty =
        "No conversations are waiting on their reply in this window."
}
