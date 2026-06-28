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
///
/// Triage (Phase B/C) lives here too: a hover-reveal + context-menu dismiss with a
/// draining-bar undo, a batch Select mode, a `Muted Senders…` toolbar popover, and a
/// conditional zero-state line — every surface gated to stay calm at rest.
///
/// When `trial` is non-nil the board shows a quiet "Free trial · ends <date>"
/// status banner and a gear menu "Buy Stower v0" item. The banner is
/// dismissible; the gear menu is not (it is the permanent license home). Both
/// are absent for paid users (`trial == nil`).
internal struct StowerBoardView: View {
    @Bindable internal var model: StowerBoardViewModel

    /// The trial badge data, or `nil` on a paid license or after the user dismisses.
    ///
    /// The dismissal flag is owned by the caller (`StowerRootView`) so
    /// `StowerBoardView` stays a pure display component.
    internal let trial: StowerTrialBadge?

    /// Opens the Lemon Squeezy checkout for the given `licenseID`.
    ///
    /// The only payment path in the board. Called exclusively from the gear menu item.
    internal let onBuy: (String) -> Void

    /// Persists the badge dismissal.
    ///
    /// Called when the user taps the badge's dismiss control; `StowerRootView` then
    /// nils out `trial` on the next render.
    internal let onDismissTrial: () -> Void

    /// The row hovered right now, so only its trailing dismiss control is revealed
    /// (the list stays clean at rest). `internal` so the `+Triage` view extension reads it.
    @State internal var hoveredRowID: String?

    /// The row pending a first-time mute confirmation, or `nil`.
    ///
    /// Once the user has confirmed once (`hasConfirmedMute`), mute is immediate.
    @State internal var muteCandidate: StowerBoardRow?

    /// Whether the user has seen the one-time mute explainer (persisted).
    ///
    /// After the first confirmation, Mute Sender acts without a dialog.
    @AppStorage("stower.board.hasConfirmedMute") internal var hasConfirmedMute = false

    internal var body: some View {
        NavigationStack {
            content
                .toolbar { toolbarContent }
                .overlay(alignment: .bottomTrailing) { composerOverlay }
                .overlay(alignment: .bottom) { undoBarOverlay }
                .overlay(alignment: .top) { trialBadgeOverlay }
        }
        .animation(.easeInOut(duration: Self.undoBarFade), value: model.undoBar?.id)
        .confirmationDialog(
            "Mute this sender?",
            isPresented: muteConfirmationBinding,
            presenting: muteCandidate
        ) { row in
            Button("Mute Sender") { confirmMute(row) }
            Button("Cancel", role: .cancel) { muteCandidate = nil }
        } message: { _ in
            Text(
                "They'll be hidden from this board, not from Messages. "
                    + "Unmute anytime from Muted Senders in the toolbar."
            )
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
            StowerBoardNotice(
                symbol: "tray",
                title: "Nothing in this list",
                message: emptyMessage
            ) {
                mutedHiddenNotice
            }
        } else if model.isSelecting {
            selectableList(rows)
        } else {
            List {
                ForEach(rows) { row in
                    dismissableRow(row)
                }
            }
        }
    }

    /// The quiet trial status banner, pinned to the top edge of the content area.
    ///
    /// Shown only when `trial` is non-nil (the caller has already gated on
    /// both "has a trial" and "not dismissed"). The dismiss control writes
    /// through `onDismissTrial`; `StowerRootView` then nils out `trial`.
    @ViewBuilder internal var trialBadgeOverlay: some View {
        if let badge = trial {
            StowerTrialBadgeView(badge: badge, onDismiss: onDismissTrial)
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

    /// The calm "all caught up" zero state — no scoreboard, just reassurance, plus the
    /// honest muted line when the board is empty *because* people are muted (I12).
    private var caughtUpNotice: some View {
        StowerBoardNotice(
            symbol: "checkmark.circle",
            title: "You're all caught up",
            message: "No one's waiting on a reply right now."
        ) {
            mutedHiddenNotice
        }
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

    internal var presetPicker: some View {
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

    internal var refreshButton: some View {
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
    private static let undoBarFade: Double = 0.2
}
