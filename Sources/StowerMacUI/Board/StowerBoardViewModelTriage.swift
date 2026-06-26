import Foundation

/// The board view-model's triage surface: dismiss (single + batch), the draining-bar
/// undo + ⌘Z backstop, batch Select mode, and mute / unmute with the muted-senders
/// popover state.
///
/// Split into this extension (the same split-across-files posture as the draft
/// surface) so the primary file stays focused on the load/refresh state machine.
/// Every write goes to `triage` and records ONE semantic interaction event from the
/// action method (never a view closure — gotcha #7); recording is non-blocking
/// (gotcha #8). The keystone is undo granularity (I6): exactly one `registerUndo` per
/// user action, capturing the whole set it acted on, wrapped in an explicit undo
/// group so run-loop timing can't merge or split steps.
extension StowerBoardViewModel {
    // MARK: Dismiss

    /// Serializes a triage action AFTER the in-flight one, so rapid actions preserve
    /// user order — the write, undo registration, bar, and reload of action N never
    /// interleave with action N+1 (the same chaining posture as `commitDraft`).
    ///
    /// `internal` so the load path can seed the muted count through the same queue.
    internal func enqueueTriage(_ work: @escaping () async -> Void) {
        let previous = triageTask
        triageTask = Task {
            await previous?.value
            await work()
        }
    }

    /// Dismisses a set of rows as ONE user action — the single entry point for both a
    /// single-row dismiss (a set of one) and a batch "Dismiss N" (a set of N).
    ///
    /// Kicks off the async work; the view calls this directly from its action closures.
    internal func dismiss(_ rows: Set<StowerBoardRow>) {
        enqueueTriage { await self.performDismiss(rows) }
    }

    /// Writes the dismissals, records the events, registers ONE undo step for the set,
    /// shows the draining bar, and reloads — in that order.
    ///
    /// The bar appears ONLY after the writes resolve (no success bar on a failed
    /// write), and the undo step captures exactly the rows that actually persisted, so
    /// ⌘Z / bar-Undo reverses precisely this action (I6). A recorder failure is
    /// swallowed by the recorder and never suppresses the bar (I14).
    private func performDismiss(_ rows: Set<StowerBoardRow>) async {
        let dismissed = await dismissIO(rows)
        guard !dismissed.isEmpty else { return }
        registerDismissUndo(for: dismissed)
        showUndoBar(count: dismissed.count)
        await reloadLocally()
    }

    /// The pure dismiss IO: write + record per row, returning the rows that persisted.
    private func dismissIO(_ rows: Set<StowerBoardRow>) async -> Set<StowerBoardRow> {
        let at = clock()
        var dismissed: Set<StowerBoardRow> = []
        for row in rows {
            do {
                try await triage.dismiss(
                    handleKey: row.draftKey,
                    messageGUID: row.lastMessageGUID,
                    anchorTimestamp: row.lastMessageTimestamp,
                    at: at
                )
            } catch {
                // A failed write earns no bar and no undo entry for that row; skip it.
                continue
            }
            await interactions.record(
                .messageDismissed(
                    handleKey: row.draftKey,
                    messageGUID: row.lastMessageGUID,
                    boardTab: selectedTab.eventToken,
                    occurredAt: at
                )
            )
            dismissed.insert(row)
        }
        return dismissed
    }

    /// The pure undismiss IO: delete each active row (logs nothing — JC5/I2).
    private func undismissIO(_ rows: Set<StowerBoardRow>) async {
        for row in rows {
            try? await triage.undismiss(handleKey: row.draftKey)
        }
    }

    /// Registers exactly ONE undo step for the dismissed set, in an explicit group so
    /// run-loop timing can neither merge separate dismisses nor split a batch (I6).
    private func registerDismissUndo(for rows: Set<StowerBoardRow>) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { vm in vm.handleUndoDismiss(rows) }
        undoManager.setActionName(Self.dismissUndoActionName)
        undoManager.endUndoGrouping()
    }

    /// The undo handler — runs SYNCHRONOUSLY inside `undo()`.
    ///
    /// It registers the REDO *now* (so it lands on the redo stack while the manager is
    /// mid-undo) and defers only the async triage delete + reload. Deferring the
    /// registration too (inside the Task) would land it back on the UNDO stack after
    /// `undo()` returns, corrupting the step sequence (I6).
    private func handleUndoDismiss(_ rows: Set<StowerBoardRow>) {
        undoManager.registerUndo(withTarget: self) { vm in vm.handleRedoDismiss(rows) }
        undoManager.setActionName(Self.dismissUndoActionName)
        undoBar = nil
        enqueueTriage {
            await self.undismissIO(rows)
            await self.reloadLocally()
        }
    }

    /// The redo handler — runs SYNCHRONOUSLY inside `redo()`.
    ///
    /// Symmetric to the undo handler: re-register the undo now, defer only the
    /// re-dismiss IO + bar + reload.
    private func handleRedoDismiss(_ rows: Set<StowerBoardRow>) {
        undoManager.registerUndo(withTarget: self) { vm in vm.handleUndoDismiss(rows) }
        undoManager.setActionName(Self.dismissUndoActionName)
        enqueueTriage {
            let dismissed = await self.dismissIO(rows)
            self.showUndoBar(count: dismissed.count)
            await self.reloadLocally()
        }
    }

    /// The bar's Undo button and ⌘Z are the SAME call — reverse the last action.
    internal func undoLastDismiss() {
        undoManager.undo()
    }

    /// Replaces the single draining-bar slot with a fresh one (bumps the id so the
    /// view restarts its drain timer).
    private func showUndoBar(count: Int) {
        undoBarSequence += 1
        undoBar = StowerDismissUndoBarState(id: undoBarSequence, count: count)
    }

    /// Clears the draining bar when its dwell elapses (called by the bar view).
    ///
    /// Guarded on the slot id so a stale timer from a replaced bar can't clear a newer
    /// one — only the bar that is still showing dismisses itself.
    internal func expireUndoBar(id: Int) {
        guard undoBar?.id == id else { return }
        undoBar = nil
    }

    // MARK: Batch Select mode

    /// Enters batch Select mode for the current lens (clean list → checkboxes).
    internal func enterSelectMode() {
        selection = []
        isSelecting = true
    }

    /// Exits Select mode and clears the selection (per-lens; B2).
    internal func exitSelectMode() {
        isSelecting = false
        selection = []
    }

    /// Toggles Select mode for the current lens.
    internal func toggleSelectMode() {
        if isSelecting {
            exitSelectMode()
        } else {
            enterSelectMode()
        }
    }

    /// Dismisses the selected rows as one batch action, then exits Select mode.
    ///
    /// Resolves the selection (`chatID`s) against the current lens's rows so only
    /// still-present rows are dismissed; the one undo step + one summary bar follow
    /// from `dismiss(_:)` (I6).
    internal func dismissSelected() {
        let rows = selectedRows()
        guard !rows.isEmpty else {
            exitSelectMode()
            return
        }
        exitSelectMode()
        dismiss(rows)
    }

    /// The rows in the current lens matching the current selection.
    private func selectedRows() -> Set<StowerBoardRow> {
        guard let board else { return [] }
        let lens = board.rows(for: direction)
        return Set(lens.filter { selection.contains($0.id) })
    }

    // MARK: Mute / unmute

    /// Mutes a sender from a board row, records the event, and reloads.
    ///
    /// First-time confirmation is the view's concern (it owns the persisted "seen"
    /// flag); this method performs the mute unconditionally.
    internal func mute(_ row: StowerBoardRow) {
        enqueueTriage { await self.performMute(handleKey: row.draftKey) }
    }

    /// Unmutes a sender (popover Unmute), records the event from the popover surface,
    /// and refreshes both the board and the still-open popover list.
    internal func unmute(_ sender: StowerMutedSender) {
        enqueueTriage {
            await self.performUnmute(handleKey: sender.key, surface: Self.mutedSendersSurface)
        }
    }

    private func performMute(handleKey: String) async {
        let at = clock()
        do {
            try await triage.mute(handleKey: handleKey, at: at)
        } catch {
            // Mute is durable but non-fatal: a failed write simply leaves the row
            // visible (degrade-never-crash). No bar — mute is not on the ⌘Z stack.
            return
        }
        await interactions.record(
            .senderMuted(handleKey: handleKey, surface: Self.boardSurface, occurredAt: at)
        )
        await refreshMutedCount()
        await reloadLocally()
    }

    private func performUnmute(handleKey: String, surface: String) async {
        let at = clock()
        do {
            try await triage.unmute(handleKey: handleKey, at: at)
        } catch {
            return
        }
        await interactions.record(
            .senderUnmuted(handleKey: handleKey, surface: surface, occurredAt: at)
        )
        await refreshMutedCount()
        // Keep the open popover current across unmutes (it stays open — C1).
        await loadMutedSenders()
        await reloadLocally()
    }

    // MARK: Muted-state reads

    /// Refreshes the cheap muted COUNT from `triage` (no Contacts enumeration).
    ///
    /// Drives the toolbar control's visibility and the zero-state line (I12). On a
    /// read failure the count is left unchanged (degrade, never crash).
    internal func refreshMutedCount() async {
        guard let muted = try? await triage.muted() else { return }
        mutedCount = muted.count
    }

    /// Loads the name-resolved muted senders for the popover.
    ///
    /// Called when the popover opens and after each unmute. Resolution lives in the
    /// data source (it owns the Contacts resolver).
    internal func loadMutedSenders() async {
        isLoadingMutedSenders = true
        mutedSenders = await dataSource.mutedSenders()
        isLoadingMutedSenders = false
    }

    /// Refreshes the popover list (the toolbar control calls this as it opens).
    internal func reloadMutedSendersList() {
        enqueueTriage { await self.loadMutedSenders() }
    }

    // MARK: Reload

    /// Re-reads the (now-filtered) board WITHOUT flipping to `.preparing`, so dismissed
    /// and muted rows animate out via SwiftUI's list diff rather than a spinner.
    ///
    /// Reuses `load()` — it keeps the current board on screen until the fresh one
    /// arrives and never sets `.preparing` (only `selectPreset`/`retry` do), which is
    /// exactly the local-reflow behavior the dismiss/mute actions want.
    private func reloadLocally() async {
        load()
        await loadTaskHandle?.value
    }

    /// The Edit-menu action name ⌘Z surfaces ("Undo Dismiss").
    private static let dismissUndoActionName = "Dismiss"

    /// The `surface` token recorded for a mute taken from a board row.
    private static let boardSurface = "board"

    /// The `surface` token recorded for an unmute taken from the popover.
    private static let mutedSendersSurface = "muted_senders"
}

/// The transient draining-bar undo slot's state — a single REPLACEABLE slot.
///
/// Carries only what the bar renders: a monotonic `id` (so a replaced slot restarts
/// the drain timer) and the dismissed `count` (1 → "Dismissed", N → "N dismissed").
/// The dwell duration and copy live on `StowerDismissUndoBar` (the view), keeping the
/// view-model free of presentation constants.
internal struct StowerDismissUndoBarState: Equatable, Identifiable {
    /// The monotonic slot id; a newer dismiss bumps it to restart the drain.
    internal let id: Int

    /// How many rows this bar's Undo would restore (1 = single, >1 = batch).
    internal let count: Int
}
