import SwiftUI

/// The board view's triage surface: the dismissable row (hover control + context
/// menu), batch Select mode, the draining-bar overlay, the `Muted Senders…` toolbar
/// control, the conditional zero-state line, and the first-time mute confirmation.
///
/// Split into this extension (the same split-across-files posture as the view-model's
/// `+Triage`) so the primary `StowerBoardView` file stays focused on the phase switch
/// and the shared chrome.
extension StowerBoardView {
    @ToolbarContentBuilder internal var toolbarContent: some ToolbarContent {
        // Keep the control mounted while the popover is open, so unmuting the LAST
        // sender (mutedCount → 0) doesn't yank the popover's anchor out from under it —
        // it stays open showing the empty state until the user clicks away (C1).
        if model.mutedCount > 0 || model.isShowingMutedSenders {
            StowerBoardView.withoutSharedGlassBackground {
                ToolbarItem(placement: .primaryAction) { mutedSendersButton }
            }
        }
        if model.selectedTab != .drafts {
            StowerBoardView.withoutSharedGlassBackground {
                ToolbarItem(placement: .primaryAction) { selectButton }
            }
            if model.isSelecting {
                StowerBoardView.withoutSharedGlassBackground {
                    ToolbarItem(placement: .primaryAction) { dismissSelectedButton }
                }
            }
        }
        StowerBoardView.withoutSharedGlassBackground {
            ToolbarItem(placement: .primaryAction) { presetPicker }
        }
        StowerBoardView.withoutSharedGlassBackground {
            ToolbarItem(placement: .primaryAction) { refreshButton }
        }
        // Always-visible feedback entry point (JC-A) — a labeled button
        // independent of the gear licenseMenu, shown for trial and licensed users
        // alike. On a narrow window it can collapse into the toolbar's ">>"
        // overflow chevron; acceptable for v0.
        StowerBoardView.withoutSharedGlassBackground {
            ToolbarItem(placement: .primaryAction) { feedbackButton }
        }
        // The permanent license home: always mounted so the Buy + Enter-key
        // paths are discoverable even after the banner is dismissed/changed.
        // Shows the trial end date + both actions only while on an active
        // trial (JC5).
        StowerBoardView.withoutSharedGlassBackground {
            ToolbarItem(placement: .primaryAction) { licenseMenu }
        }
    }

    /// A gear menu that surfaces Privacy plus the license status and buy/enter-key actions.
    ///
    /// "Privacy…" is always the first item, for every trial/license state: it writes
    /// `selectedSettingsTab = .privacy` and calls `openSettings()` so the Settings
    /// window lands on the Privacy pane even if Updates was last viewed. Below it (only
    /// on an active trial) the non-actionable trial date label, "Buy Stower" (checkout),
    /// and "Enter license key…" (JC5) give a mid-trial purchaser an activation path. The
    /// gear is always enabled because Privacy… is unconditional.
    internal var licenseMenu: some View {
        Menu {
            Button("Privacy…") {
                selectedSettingsTab = .privacy
                openSettings()
            }
            if let badge = trial {
                Divider()
                Section {
                    Text(StowerTrialBadgeView.endLabel(for: badge.expiry))
                }
                Button("Buy Stower", action: onBuy)
                Button("Enter license key…", action: onEnterKey)
            }
        } label: {
            Image("PhosphorGear")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .squareFrame(StowerBoardTheme.iconGlyphSize)
        }
        .menuStyle(.borderlessButton)
        .help("License & settings")
        .accessibilityLabel("License and settings menu")
    }

    /// The always-visible feedback button (JC-A): opens the in-app feedback sheet.
    ///
    /// A labeled flag glyph so it reads as "feedback," not settings —
    /// distinct from the gear `licenseMenu` (which now leads with Privacy…).
    internal var feedbackButton: some View {
        Button {
            isShowingFeedback = true
        } label: {
            Label {
                Text("Feedback")
            } icon: {
                Image("PhosphorFlag")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .squareFrame(StowerBoardTheme.iconGlyphSize)
            }
        }
        .buttonStyle(.plain)
        .help("Send feedback")
        .accessibilityLabel("Send feedback")
    }

    /// The clean at-rest row: a real Button opens the composer (so keyboard/VoiceOver
    /// activation works), a trailing hover control or the context menu dismisses, and
    /// the context menu also mutes.
    ///
    /// The hover control is a sibling `.overlay` (NOT nested in the label): it layers on
    /// top, so its own button takes the trailing-region taps while the row Button takes
    /// the rest — no nested-button conflict. The context menu is the keyboard/VoiceOver
    /// path for Dismiss/Mute (the hover control is a mouse convenience).
    internal func dismissableRow(_ row: StowerBoardRow) -> some View {
        Button {
            model.openComposer(for: row)
        } label: {
            StowerNoReplyRowView(
                row: row,
                draftPreview: model.activeDraftPreview(key: row.draftKey)
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) { hoverDismissControl(row) }
        .onHover { hovering in
            if hovering {
                hoveredRowID = row.id
            } else if hoveredRowID == row.id {
                hoveredRowID = nil
            }
        }
        .contextMenu {
            Button("Dismiss") { model.dismiss([row]) }
            Button("Mute Sender") { requestMute(row) }
        }
    }

    /// The trailing archive control, revealed only while this row is hovered.
    ///
    /// Its own button consumes the tap, so dismissing never falls through to opening
    /// the row.
    @ViewBuilder internal func hoverDismissControl(_ row: StowerBoardRow) -> some View {
        if hoveredRowID == row.id {
            Button {
                model.dismiss([row])
            } label: {
                Image("PhosphorArchive")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .squareFrame(StowerBoardTheme.iconGlyphSize)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
    }

    /// Batch Select mode: SwiftUI multi-select (Space toggles, Shift+Arrow range, ⌘A
    /// select-all — all free and accessible).
    ///
    /// A row tap toggles selection here, never opens the composer.
    internal func selectableList(_ rows: [StowerBoardRow]) -> some View {
        List(selection: $model.selection) {
            ForEach(rows) { row in
                StowerNoReplyRowView(
                    row: row,
                    draftPreview: model.activeDraftPreview(key: row.draftKey)
                )
                .tag(row.id)
            }
        }
    }

    @ViewBuilder internal var undoBarOverlay: some View {
        if let bar = model.undoBar {
            StowerDismissUndoBar(
                state: bar,
                onUndo: { model.undoLastDismiss() },
                onExpire: { model.expireUndoBar(id: $0) }
            )
            .padding(.bottom, Self.undoBarBottomPadding)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    internal var mutedSendersButton: some View {
        StowerMutedSendersButton(
            senders: model.mutedSenders,
            isLoading: model.isLoadingMutedSenders,
            isPresented: $model.isShowingMutedSenders,
            onOpen: { model.reloadMutedSendersList() },
            onUnmute: { model.unmute($0) }
        )
    }

    internal var selectButton: some View {
        Button(model.isSelecting ? "Cancel" : "Select") {
            model.toggleSelectMode()
        }
        .buttonStyle(.plain)
        .help(model.isSelecting ? "Leave Select mode" : "Select messages to dismiss")
    }

    internal var dismissSelectedButton: some View {
        Button("Dismiss \(model.selection.count)") {
            model.dismissSelected()
        }
        .buttonStyle(.plain)
        .disabled(model.selection.isEmpty)
    }

    /// The conditional repair line shown on ANY empty surface when senders are muted.
    ///
    /// It keeps an empty board honest (people are hidden, here's where) and opens the
    /// same popover. Hidden entirely at zero muted (I12).
    @ViewBuilder internal var mutedHiddenNotice: some View {
        if model.mutedCount > 0 {
            VStack(spacing: StowerBoardTheme.rowTextSpacing) {
                Text("Muted senders are hidden from this board.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Manage…") {
                    // Load explicitly before presenting (the toolbar button's popover is
                    // the anchor; this just drives the same shared `isShowingMutedSenders`).
                    model.reloadMutedSendersList()
                    model.isShowingMutedSenders = true
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Routes a Mute Sender action: first time, ask for confirmation; thereafter mute
    /// immediately (the user has seen the scope/recoverability explainer once).
    internal func requestMute(_ row: StowerBoardRow) {
        if hasConfirmedMute {
            model.mute(row)
        } else {
            muteCandidate = row
        }
    }

    /// Confirms the one-time mute explainer and performs the mute.
    internal func confirmMute(_ row: StowerBoardRow) {
        hasConfirmedMute = true
        model.mute(row)
        muteCandidate = nil
    }

    /// Drives the confirmation dialog's presentation off `muteCandidate`.
    internal var muteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { muteCandidate != nil },
            set: { presented in if !presented { muteCandidate = nil } }
        )
    }

    /// The draining bar's distance above the bottom edge.
    internal static let undoBarBottomPadding: CGFloat = 24
}
