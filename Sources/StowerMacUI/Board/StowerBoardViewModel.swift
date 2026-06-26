import Foundation
import Observation

/// The presentation phase the board view switches on.
///
/// Distinct from the loaded data: `board` holds the rows, `phase` says which
/// surface to show. `.error` is the board-level "something went wrong" (total
/// refresh failure, I9) — NOT a thrown `StowerStartupFailure`, which routes to
/// onboarding via `onFailure`.
internal enum StowerBoardPhase: Sendable, Equatable {
    /// Cold start / in-flight: spinner with a first-run time expectation.
    case preparing

    /// A loaded board with at least one row in some lens.
    case rows

    /// A completed pass with nothing to show (empty snapshot or empty lenses).
    case caughtUp

    /// A completed pass that judged nothing despite having records — retryable.
    case error
}

/// Drives the debt-board surface: load, refresh, preset, and direction.
///
/// Mirrors `StowerStartupModel`'s discipline — a generation token on `load()` so a
/// stale preset's late result can't overwrite a newer board (I13), and the same
/// `CancellationError`-is-a-no-op / `StowerStartupFailure`-routes contract. `load`
/// and `refresh` are distinct engine calls: `load` serves cached rows at structural
/// speed; `refresh` runs the background model pass and resolves the cold-start
/// "preparing" state per the `StowerBoardRefreshOutcome` (I6/I6b/I9).
@MainActor
@Observable
internal final class StowerBoardViewModel {
    /// The presentation phase the view renders.
    ///
    /// Written by the load/refresh state machine in `+Load` (hence `internal`, not
    /// `private(set)`); the view treats it as read-only.
    internal var phase: StowerBoardPhase = .preparing

    /// The loaded board; the view reads the lens for `direction`.
    ///
    /// Written by `+Load` (and the Contacts-revoke path); the view treats it read-only.
    internal var board: StowerBoardModel?

    /// Whether a background refresh is in flight (disables the refresh control).
    internal var isRefreshing = false

    /// The visible day-filter preset; changing it re-loads (I8).
    internal private(set) var selectedPreset: StowerDayPreset = .default

    /// The visible tab — the single source of truth for the lens (JC-A).
    ///
    /// Switching between the two lens tabs re-lenses the loaded board without
    /// reloading (I7); `.drafts` shows the cross-cutting on-board draft list.
    ///
    /// Selection is per-lens, so changing tabs exits Select mode and clears the
    /// selection (B2) — a selection made in one lens must never leak into another.
    internal var selectedTab: StowerBoardTab = .yourTurn {
        didSet {
            guard selectedTab != oldValue, isSelecting else { return }
            exitSelectMode()
        }
    }

    /// The lens to render, derived from `selectedTab` (never held in parallel).
    ///
    /// The Drafts tab carries no lens, so it falls back to `.neglected` (unused there).
    internal var direction: StowerBoardDirection { selectedTab.direction ?? .neglected }

    /// The open draft composer's key, or `nil` when none is open.
    ///
    /// Single-valued (I-ComposerSingle) and the reload-merge guard
    /// (I-ReloadPreservesEdit). Mutate only via `openComposer`/`closeComposer`, which
    /// keep the embedded thread in lockstep.
    internal var composerKey: String?

    /// The stable `chatID` of the row the open composer belongs to, or `nil`.
    ///
    /// The composer resolves its row by this — NOT by `composerKey` — because two
    /// same-number threads (iMessage + SMS) share one `draftKey` but have distinct
    /// `chatID`s (A2); resolving by `draftKey` could show the other thread's
    /// header/deep-link. Mutated only via `openComposer`/`closeComposer`.
    internal var composerChatID: String?

    /// The embedded read-only thread the open composer shows, or `nil`.
    ///
    /// Owned here so opening loads it and closing cancels it (I-ComposerThreadLifecycle).
    internal var composerThread: StowerThreadViewModel?

    /// Drafts by `StowerDraftKey`, merged from the store on load and written through.
    ///
    /// Off-board drafts are kept here too — never pruned (I-NeverDelete).
    internal var drafts: [String: StowerDraftEntry] = [:]

    /// The last-synced Contacts authorization, as *observed* state.
    ///
    /// So SwiftUI recomputes the banner when it changes (a live read of
    /// `contacts.authorization` wouldn't). Refreshed wherever authorization can move:
    /// on appear, after an in-app prompt resolves (grant *or* deny), and on app
    /// re-activation.
    internal var contactsAuthorization: StowerContactsAuthorization

    /// Bumps whenever Contacts access is *lost* (authorized → not), so the board view
    /// dismisses an open thread before its captured row's resolved name can linger.
    internal private(set) var contactsRevocationToken = 0

    // `internal` (not `private`) so the `+Triage` extension can re-read the board via
    // the data source (`mutedSenders`, `reloadLocally`).
    internal let dataSource: any StowerBoardDataSource
    // `internal` (not `private`) so the `+Drafts` / `+Contacts` extension files can
    // reach them — the same split-across-files posture as `StowerDebtBoardProvider`'s
    // mechanics. The load/refresh state machine (which writes `phase`/`board`/
    // `isRefreshing`) lives in `+Load`, so those stay `internal`; `contactsRevocationToken`
    // keeps `private(set)` with its writer here.
    internal let draftStore: any StowerDraftStoring
    /// Records semantic triage events (dismiss/mute/unmute) as user interaction memory.
    ///
    /// Non-blocking: a recording failure never blocks the action. The producers are the
    /// dismiss/mute/unmute action methods (`+Triage`).
    internal let interactions: any StowerInteractionRecording

    /// The app-owned triage boundary the board WRITES dismiss/mute/unmute through, and
    /// reads the muted count from.
    ///
    /// The SAME instance the data source filters reads with (injected from the
    /// composition), so a write here is visible to the next `loadBoard` filter pass.
    /// Defaults to an empty in-memory store so previews/tests apply no triage.
    internal let triage: any StowerTriageStoring

    /// The app-owned `UndoManager` ⌘Z and the draining bar's Undo both drive.
    ///
    /// Injected (A4) so a background `refreshJudgments` reload can't swap or nil it
    /// mid-session — the failure mode of `@Environment(\.undoManager)`, which rebinds
    /// when the `List` rebuilds. `groupsByEvent` is forced off in `init` so each user
    /// action is exactly one undo step regardless of run-loop timing (I6). The Xcode
    /// app target binds ⌘Z to this same instance via `CommandGroup(.undoRedo)`.
    internal let undoManager: UndoManager

    /// The transient draining-bar undo slot, or `nil` when no bar is showing.
    ///
    /// A single REPLACEABLE slot (I6): a new dismiss replaces the slot, it never
    /// stacks. Set ONLY after the triage write resolves (no success bar on a failed
    /// write). The `StowerDismissUndoBar` view owns the drain timer and clears it via
    /// `expireUndoBar` when the dwell elapses (paused on hover/keyboard focus).
    /// `internal` (not `private(set)`) so the `+Triage` extension file can mutate it —
    /// the same cross-file posture as `inflightWrites`; the view only reads it.
    internal var undoBar: StowerDismissUndoBarState?

    /// Whether the current lens is in batch-Select mode (Apple Mail "Edit" model).
    ///
    /// Clean list at rest; toggling Select reveals checkboxes via `List(selection:)`.
    /// Switching tabs or applying a batch exits it; selection is per-lens.
    internal var isSelecting = false

    /// The selected row identities (`chatID`) in the current lens's Select mode.
    internal var selection: Set<String> = []

    /// The number of muted contacts — drives the toolbar control's visibility and the
    /// conditional zero-state line (I12).
    ///
    /// Read cheaply from `triage` (no Contacts enumeration) after each load and
    /// mute/unmute; the control is hidden entirely at zero.
    internal var mutedCount = 0

    /// The name-resolved muted senders for the popover.
    ///
    /// Refreshed when the popover opens and after each unmute (so the open popover
    /// stays current). Empty until loaded.
    internal var mutedSenders: [StowerMutedSender] = []

    /// Whether the `Muted Senders…` popover is showing.
    ///
    /// Shared state so BOTH the toolbar control and the zero-state "Manage…" link can
    /// open it.
    internal var isShowingMutedSenders = false

    /// Whether the popover's sender list is being (re)loaded.
    ///
    /// Drives a loading row so the popover never flashes "No muted senders" before the
    /// first load resolves — the resolver enumerates the whole address book, so the
    /// load is visibly non-instant on first open.
    internal var isLoadingMutedSenders = false
    internal let dropper: StowerMessagesDropper
    internal let contacts: StowerContactsAccess
    internal let settings: StowerSystemSettingsOpener
    private let opener: StowerMessagesLinkOpener
    // `internal` so the `+Load` state machine can route failures and pace retries.
    internal let onFailure: @MainActor (StowerStartupFailure) -> Void
    internal let clock: @Sendable () -> Date
    internal let sleep: @Sendable (Duration) async throws -> Void

    /// Backoff between `.coalesced` retries while cold start is unresolved, so the
    /// re-issue waits for the other in-flight pass instead of busy-spinning.
    internal static let coalesceRetryDelay: Duration = .milliseconds(400)

    /// In-flight write-through upserts, per key, chained in issue order so the last
    /// edit wins. Deliberately OUT of `cancel()`'s reach so the termination flush can
    /// still drain them (JC2) — a draft must not be lost to the disappear-cancel.
    internal var inflightWrites: [String: Task<Void, Never>] = [:]

    /// Monotonic id for the draining-bar slot, bumped on each replace so the
    /// `StowerDismissUndoBar` view restarts its drain timer (`.task(id:)`) when the
    /// slot is replaced by a newer dismiss. `internal` so `+Triage` can bump it.
    internal var undoBarSequence = 0

    /// The in-flight triage action (dismiss / undo / mute / unmute), exposed via
    /// `triageTaskHandle` so tests can await it.
    ///
    /// `internal` (not `private`) so the `+Triage` extension can chain onto it — the
    /// same cross-file posture as `inflightWrites`. Production fires and forgets.
    internal var triageTask: Task<Void, Never>?

    // `internal` so `+Load` owns the load/refresh task lifecycle.
    internal var loadTask: Task<Void, Never>?
    internal var refreshTask: Task<Void, Never>?
    internal var contactsTask: Task<Void, Never>?
    internal var loadGeneration = 0
    internal var refreshGeneration = 0
    internal var hasResolvedColdStart = false
    internal var isRequestingContacts = false
    internal var awaitingContactsRecovery = false

    /// Creates the board view-model.
    ///
    /// `draftStore` defaults to an in-memory store and `dropper` to a no-op, so
    /// previews/tests never touch the disk, pasteboard, or keystrokes; `contacts`
    /// defaults to a denied no-op so they never prompt. Production injects the real
    /// dependencies from the composition. `clock`/`sleep` are injected for test
    /// determinism.
    internal init(
        dataSource: any StowerBoardDataSource,
        draftStore: any StowerDraftStoring = StowerInMemoryDraftStore(),
        interactions: any StowerInteractionRecording = StowerNoOpInteractionRecorder(),
        triage: any StowerTriageStoring = StowerInMemoryTriageStore(),
        undoManager: UndoManager = UndoManager(),
        dropper: StowerMessagesDropper = StowerMessagesDropper(
            perform: { _ in },
            isAccessibilityTrusted: { false }
        ),
        contacts: StowerContactsAccess = .denied,
        settings: StowerSystemSettingsOpener = StowerSystemSettingsOpener(),
        opener: StowerMessagesLinkOpener = StowerMessagesLinkOpener(),
        onFailure: @escaping @MainActor (StowerStartupFailure) -> Void,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.dataSource = dataSource
        self.draftStore = draftStore
        self.interactions = interactions
        self.triage = triage
        self.undoManager = undoManager
        self.dropper = dropper
        self.contacts = contacts
        self.settings = settings
        self.opener = opener
        self.onFailure = onFailure
        self.clock = clock
        self.sleep = sleep
        contactsAuthorization = contacts.authorization
        // One user action == one undo step (I6): disable run-loop event coalescing so
        // three rapid single dismisses stay three separate ⌘Z steps, and drive grouping
        // explicitly (`begin`/`endUndoGrouping`) per action in `+Triage`.
        undoManager.groupsByEvent = false
    }

    /// Runs the launch sequence on appear: load the cached board, then refresh.
    ///
    /// Safe to call repeatedly: `load()` supersedes via its generation token and
    /// `refresh()` is guarded by `isRefreshing`.
    internal func onAppear() {
        syncContactsAuthorization()
        load()
        refresh()
        // Seed the muted count so the toolbar control and the zero-state line are
        // correct on first render; mute/unmute keep it current thereafter.
        enqueueTriage { await self.refreshMutedCount() }
    }

    /// Re-checks Contacts when the app returns to the foreground.
    ///
    /// Switching apps doesn't re-run the board's `.task` and a Settings change can't
    /// notify us, so this reconciles a foreground Contacts change: reload when
    /// authorization *changed* while away (a Settings grant surfaces names; a revoke
    /// drops them) or when we'd sent the user to recover access.
    internal func onAppBecameActive() {
        let previous = contactsAuthorization
        syncContactsAuthorization()
        // Access lost while away — hide resolved names *now* (don't wait for the async
        // reload), dismiss an open thread (token), then reload into handle-only rows.
        if previous == .authorized, contactsAuthorization != .authorized {
            board = nil
            phase = .preparing
            contactsRevocationToken += 1
            // Close the composer so a resolved name captured at open can't linger in
            // it after access is gone (I-ComposerClosesOnContactsRevoke).
            closeComposer()
        }
        let wasAwaitingRecovery = awaitingContactsRecovery
        awaitingContactsRecovery = false
        if wasAwaitingRecovery || contactsAuthorization != previous {
            load()
        }
    }

    /// Selects a new day preset, re-loading at the new threshold (I8).
    ///
    /// Shows `.preparing` immediately so the visible rows never lag behind the
    /// selected filter while the new load is in flight — the rows on screen always
    /// match the chosen threshold.
    internal func selectPreset(_ preset: StowerDayPreset) {
        guard preset != selectedPreset else { return }
        selectedPreset = preset
        phase = .preparing
        load()
    }

    /// Re-attempts the model pass after a board-level error.
    internal func retry() {
        phase = .preparing
        refresh()
    }

    /// Cancels in-flight work when the board view disappears.
    ///
    /// Supersedes BOTH generations so a cancellation-ignoring load/refresh that
    /// finishes after disappearance is discarded by the generation guards, and resets
    /// `isRefreshing` so the next `onAppear` can start a fresh refresh even before the
    /// cancelled task finishes unwinding (otherwise cold start strands in `.preparing`).
    internal func cancel() {
        loadTask?.cancel()
        refreshTask?.cancel()
        contactsTask?.cancel()
        loadGeneration += 1
        refreshGeneration += 1
        isRefreshing = false
    }

    /// Builds a thread view-model for a tapped row, sharing the data source/opener.
    internal func makeThreadViewModel(for row: StowerBoardRow) -> StowerThreadViewModel {
        StowerThreadViewModel(
            row: row,
            dataSource: dataSource,
            opener: opener,
            onFailure: onFailure,
            clock: clock
        )
    }

    /// The in-flight load/refresh/contacts/triage tasks, exposed so tests can await them.
    internal var loadTaskHandle: Task<Void, Never>? { loadTask }
    internal var refreshTaskHandle: Task<Void, Never>? { refreshTask }
    internal var contactsTaskHandle: Task<Void, Never>? { contactsTask }
    internal var triageTaskHandle: Task<Void, Never>? { triageTask }

    /// Loads the cached board under a fresh generation token (I13).
    internal func load() {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.runLoad(generation: generation)
        }
    }

    /// Runs the background refresh loop, guarded against user re-entry.
    internal func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            await self?.runRefreshLoop(generation: generation)
        }
    }

}
