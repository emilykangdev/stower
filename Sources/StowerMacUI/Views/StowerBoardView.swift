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
/// The gear menu is always enabled and always contains "Send Feedback…". When
/// `trial` is non-nil it also shows the trial end date and a "Buy Stower v0" item.
/// A quiet, dismissible "Free trial · ends <date>" banner is shown while
/// `showsTrialBanner` is true; the gear-menu Buy survives a banner dismissal.
internal struct StowerBoardView: View {
    @Bindable internal var model: StowerBoardViewModel

    /// The active trial badge data, or `nil` on a paid license or no trial.
    ///
    /// Independent of banner dismissal: it powers the permanent gear-menu Buy path,
    /// so it stays non-nil for an active trial even after the user dismisses the
    /// banner. Banner visibility is governed separately by `showsTrialBanner`.
    internal let trial: StowerTrialBadge?

    /// Whether the dismissible top banner is shown.
    ///
    /// `StowerRootView` sets this false once the user dismisses the banner (and on a
    /// relaunch where the dismissal flag is set); the gear-menu Buy is unaffected.
    internal let showsTrialBanner: Bool

    /// Opens the Lemon Squeezy checkout for the given `licenseID`.
    ///
    /// The only payment path in the board. Called exclusively from the gear menu item.
    internal let onBuy: (String) -> Void

    /// Submits the feedback draft and returns the result.
    ///
    /// Assembled and injected by `StowerRootView` (models the `onBuy` closure
    /// seam). The board owns the sheet presentation and the success confirmation;
    /// it delegates all network + payload work to this closure.
    internal let onSendFeedback: (StowerFeedbackDraft) async -> StowerFeedbackResult

    /// The Keygen license resource id to attach to feedback submissions, or `nil` when no lease exists.
    ///
    /// Assembled by `StowerRootView` from the startup model.
    internal let feedbackLicenseID: String?

    /// The app version string included in every feedback payload, e.g. `"1.0 (42)"`.
    ///
    /// Assembled by `StowerRootView` from `Bundle.main`.
    internal let feedbackAppVersion: String

    /// Persists the banner dismissal.
    ///
    /// Called when the user taps the banner's dismiss control; `StowerRootView` then
    /// hides the banner (but keeps `trial` so the gear-menu Buy persists).
    internal let onDismissTrial: () -> Void

    /// Whether the feedback sheet is presented.
    @State internal var showingFeedback = false

    /// The current feedback form model, held as `@State` so board re-renders do not
    /// recreate it and erase text the user has already typed.
    ///
    /// Created (fresh) when `showingFeedback` becomes `true`; set to `nil` on dismiss
    /// so the next open starts with a clean slate. The sheet closure reads this value
    /// — its `@Observable` mutations propagate to `StowerFeedbackView` normally.
    @State private var feedbackFormModel: StowerFeedbackFormModel?

    /// Whether the board-level feedback success confirmation is visible.
    ///
    /// Set to `true` when the sheet's `onSuccess` fires; auto-clears after a
    /// short dwell so the confirmation reads as a momentary acknowledgement.
    @State internal var showsFeedbackConfirmation = false

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
                .overlay(alignment: .bottom) { feedbackConfirmationOverlay }
                .safeAreaInset(edge: .top, spacing: 0) { trialBadgeOverlay }
        }
        .animation(.easeInOut(duration: Self.undoBarFade), value: model.undoBar?.id)
        .animation(.easeInOut(duration: Self.undoBarFade), value: showsFeedbackConfirmation)
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
        .onChange(of: showingFeedback) { _, isPresented in
            if isPresented {
                feedbackFormModel = StowerFeedbackFormModel(
                    licenseID: feedbackLicenseID,
                    appVersion: feedbackAppVersion,
                    onSubmit: onSendFeedback
                )
            } else {
                feedbackFormModel = nil
            }
        }
        .sheet(isPresented: $showingFeedback) {
            if let formModel = feedbackFormModel {
                StowerFeedbackView(
                    model: formModel,
                    onSuccess: {
                        showsFeedbackConfirmation = true
                        Task {
                            try? await Task.sleep(for: Self.feedbackConfirmationDwell)
                            showsFeedbackConfirmation = false
                        }
                    },
                    isPresented: $showingFeedback
                )
            }
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

    /// The quiet trial status banner, inset into the top of the content area so it
    /// reserves its own space above the Contacts banner and tab picker rather than
    /// floating over (and intercepting) them.
    ///
    /// Shown only while `showsTrialBanner` is true and `trial` is non-nil; otherwise
    /// it is an empty view that reserves no space. The dismiss control writes through
    /// `onDismissTrial`; `StowerRootView` then hides the banner while keeping `trial`
    /// so the gear-menu Buy persists.
    @ViewBuilder internal var trialBadgeOverlay: some View {
        if showsTrialBanner, let badge = trial {
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

    /// The brief bottom-edge confirmation shown after a successful feedback send.
    ///
    /// Reuses the same bottom-edge anchoring as `undoBarOverlay` — a calm capsule
    /// that appears for a short dwell then fades. No undo action (fire-and-forget).
    @ViewBuilder internal var feedbackConfirmationOverlay: some View {
        if showsFeedbackConfirmation {
            Text("Thanks for the feedback! Emily reads every one.")
                .font(.callout)
                .padding(.horizontal, Self.confirmationHPadding)
                .padding(.vertical, Self.confirmationVPadding)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(
                    color: .black.opacity(Self.confirmationShadowOpacity),
                    radius: Self.confirmationShadowRadius,
                    y: Self.confirmationShadowY
                )
                .padding(.bottom, Self.undoBarBottomPadding)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityLabel("Thanks for the feedback! Emily reads every one.")
        }
    }

    private static let yourTurnEmpty =
        "No conversations are waiting on your reply in this window."
    private static let followUpEmpty =
        "No conversations are waiting on their reply in this window."
    private static let undoBarFade: Double = 0.2
    private static let feedbackConfirmationDwell: Duration = .seconds(4)
    private static let confirmationHPadding: CGFloat = 16
    private static let confirmationVPadding: CGFloat = 10
    private static let confirmationShadowOpacity: CGFloat = 0.15
    private static let confirmationShadowRadius: CGFloat = 8
    private static let confirmationShadowY: CGFloat = 2
}
