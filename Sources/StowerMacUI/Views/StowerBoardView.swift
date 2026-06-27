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
internal struct StowerBoardView: View {
    @Bindable internal var model: StowerBoardViewModel

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

    /// Reduce Motion, read once here and threaded into the motion tokens (a view-model
    /// never reads it — `+Triage` and the lists pull `reduceMotion` from this).
    @Environment(\.accessibilityReduceMotion) internal var reduceMotion

    internal var body: some View {
        NavigationStack {
            content
                .toolbar { toolbarContent }
                .overlay(alignment: .bottomTrailing) { composerOverlay }
                .overlay(alignment: .bottom) { undoBarOverlay }
        }
        .background(StowerPalette.canvas)
        .animation(StowerMotion.crossFade(reduceMotion), value: model.undoBar?.id)
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
        StowerSegmentedPill(
            selection: $model.selectedTab,
            options: StowerBoardTab.allCases,
            title: { $0.title },
            reduceMotion: reduceMotion
        )
        .accessibilityLabel("Board tab")
        .padding(.horizontal)
        .padding(.vertical, StowerBoardTheme.rowVerticalPadding)
    }

    @ViewBuilder private var tabContent: some View {
        currentTabContent
            // Switching tabs cross-fades the content (the pill animates its own fill).
            .animation(StowerMotion.tabSwitch(reduceMotion), value: model.selectedTab)
    }

    @ViewBuilder private var currentTabContent: some View {
        switch model.selectedTab {
        case .yourTurn:
            lensList(model.board?.rows(for: .neglected) ?? [], emptyMessage: Self.yourTurnEmpty)
        case .maybeFollowUp:
            lensList(model.board?.rows(for: .ghosted) ?? [], emptyMessage: Self.followUpEmpty)
        case .drafts:
            StowerDraftsList(cards: model.onBoardDrafts) { row in
                withAnimation(StowerMotion.composer(reduceMotion)) { model.openComposer(for: row) }
            }
        }
    }

    @ViewBuilder private func lensList(
        _ rows: [StowerBoardRow],
        emptyMessage: String
    ) -> some View {
        ZStack {
            if rows.isEmpty {
                StowerBoardNotice(
                    symbol: "tray",
                    title: "Nothing in this list",
                    message: emptyMessage
                ) {
                    mutedHiddenNotice
                }
                .transition(.opacity)
            } else if model.isSelecting {
                selectableList(rows)
            } else {
                List {
                    ForEach(rows) { row in
                        dismissableRow(row)
                            .listRowBackground(
                                hoveredRowID == row.id
                                    ? StowerPalette.rowHover : StowerPalette.surface
                            )
                    }
                }
                .scrollContentBackground(.hidden)
                .animation(StowerMotion.removal(reduceMotion), value: rows.map(\.id))
                .transition(.opacity)
            }
        }
        // The List↔Notice branch swap cross-fades, so dismissing the LAST row fades into
        // the empty notice instead of snapping (A6).
        .animation(StowerMotion.crossFade(reduceMotion), value: rows.isEmpty)
    }

    @ViewBuilder private var composerOverlay: some View {
        if let row = model.composerRow, let thread = model.composerThread {
            StowerDraftComposer(
                row: row,
                thread: thread,
                draft: model.draftBinding(for: row.draftKey),
                onReplyInMessages: { model.dropIntoMessages(row) },
                // Synchronous: closeComposer mutates composerChatID on this tick, so the
                // spring plays (A3). The async reload-driven close is an accepted edge.
                onClose: {
                    withAnimation(StowerMotion.composer(reduceMotion)) { model.closeComposer() }
                }
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
                .buttonStyle(StowerProminentButtonStyle())
        }
    }

    /// The day-filter control: a warm peach-pill trigger opening a checked menu.
    ///
    /// Restyled off the stock toolbar pop-up (JC-T2) — kept as a compact `Menu` rather
    /// than a 6-wide pill, since six day presets don't fit a pill in the toolbar. No
    /// stock gray control survives on the board.
    internal var presetPicker: some View {
        Menu {
            ForEach(StowerDayPreset.allCases) { preset in
                Button {
                    model.selectPreset(preset)
                } label: {
                    if preset == model.selectedPreset {
                        Label(preset.title, systemImage: "checkmark")
                    } else {
                        Text(preset.title)
                    }
                }
            }
        } label: {
            HStack(spacing: Self.presetLabelSpacing) {
                Text(model.selectedPreset.title)
                    .font(.callout.weight(.medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(StowerPalette.textPrimary)
            .padding(.horizontal, Self.presetLabelHorizontalPadding)
            .padding(.vertical, Self.presetLabelVerticalPadding)
            .background(StowerPalette.pillFill, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Unanswered for")
        .accessibilityValue(model.selectedPreset.title)
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

    private static let presetLabelSpacing: CGFloat = 4
    private static let presetLabelHorizontalPadding: CGFloat = 12
    private static let presetLabelVerticalPadding: CGFloat = 5
}
