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
            ToolbarItem(placement: .primaryAction) { mutedSendersButton }
        }
        if model.selectedTab != .drafts {
            ToolbarItem(placement: .primaryAction) { selectButton }
            if model.isSelecting {
                ToolbarItem(placement: .primaryAction) { dismissSelectedButton }
            }
        }
        ToolbarItem(placement: .primaryAction) { presetPicker }
        ToolbarItem(placement: .primaryAction) { refreshButton }
    }

    /// The clean at-rest row: a tap opens the composer, a trailing hover control or the
    /// context menu dismisses, and the context menu also mutes.
    internal func dismissableRow(_ row: StowerBoardRow) -> some View {
        StowerNoReplyRowView(row: row, draftPreview: model.drafts[row.draftKey]?.body)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) { hoverDismissControl(row) }
            .onTapGesture { model.openComposer(for: row) }
            .accessibilityAddTraits(.isButton)
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
                Image(systemName: "archivebox")
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
                StowerNoReplyRowView(row: row, draftPreview: model.drafts[row.draftKey]?.body)
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
            isPresented: $model.isShowingMutedSenders,
            onOpen: { model.reloadMutedSendersList() },
            onUnmute: { model.unmute($0) }
        )
    }

    internal var selectButton: some View {
        Button(model.isSelecting ? "Cancel" : "Select") {
            model.toggleSelectMode()
        }
        .help(model.isSelecting ? "Leave Select mode" : "Select messages to dismiss")
    }

    internal var dismissSelectedButton: some View {
        Button("Dismiss \(model.selection.count)") {
            model.dismissSelected()
        }
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
                Button("Manage…") { model.isShowingMutedSenders = true }
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
