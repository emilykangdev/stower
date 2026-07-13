import Foundation
import StowerCore
import StowerMessages

/// The production composition point: builds ONE engine provider and vends both
/// app-owned boundaries over it.
///
/// One of the four files in `StowerMacUI` that import the engine. Constructing a
/// single `StowerDebtBoardProvider` and injecting that same instance into both the
/// startup adapter and the board adapter is load-bearing: the snapshot reader, the
/// disposable verdict cache, and `refreshJudgments`' single-flight coalescing are
/// all provider state, so two providers would split them and each re-copy the
/// Messages database. `StowerRootView` builds this once and holds both boundaries.
internal struct StowerMessagesComposition {
    /// The startup boundary the `StowerStartupModel` drives.
    internal let startup: any StowerStartupProviding

    /// The board boundary the `StowerBoardViewModel` drives.
    internal let board: any StowerBoardDataSource

    /// The Contacts-access wrapper the board view-model requests permission through.
    internal let contacts: StowerContactsAccess

    /// The precious draft store, behind its app-owned boundary.
    internal let draftStore: any StowerDraftStoring

    /// The precious triage store (dismiss + mute), behind its app-owned boundary.
    internal let triageStore: any StowerTriageStoring

    /// The precious interaction-event recorder, behind its app-owned boundary.
    internal let interactions: any StowerInteractionRecording

    /// The analytics reporter for funnel + board-interaction events.
    ///
    /// Shared between `StowerStartupModel` (funnel) and `StowerBoardViewModel`
    /// (board_item_clicked) so both flow through the same kill switch.
    internal let analyticsReporter: any StowerAnalyticsReporting

    /// The "Reply in Messages" bridge.
    internal let dropper: StowerMessagesDropper

    /// The persisted security-scoped bookmark for the user's granted Messages
    /// folder.
    ///
    /// Exposed so `StowerRootView`'s onboarding flow can write a freshly
    /// created bookmark here after the user grants access via
    /// `StowerMessagesAccessPicker` — the engine itself never persists
    /// anything (JC2).
    internal let messagesAccessBookmarkStore: StowerUserDefaultsItem

    /// Builds the shared provider, both adapters, and the precious draft store.
    ///
    /// The engine is built with an **empty** `StowerContactsResolver()`, so it emits
    /// the raw handle as `counterpart` and does zero Contacts work: name resolution
    /// is owned solely by the app at the `StowerMessagesMapping.mapRow` seam (the
    /// board adapter's default `.live()` factory). This changes no verdict, ranking,
    /// or cache key — the name is absent from the judge (`context: []`) and the
    /// `inputHash` (text + kind only).
    ///
    /// The draft store is opened on-disk and ALWAYS yields persistence (it quarantines
    /// a corrupt file aside and recreates — never deletes, never an in-memory
    /// fallback). Only a true disk-level failure throws, which propagates as a startup
    /// failure like any other essential store.
    internal init() throws {
        // The storage-location Application Support subfolder — Debug, Debug-demo,
        // and Release now resolve to distinct folders (PAR-62), so a Debug run
        // against real data, a Debug run against demo data, and a Release run
        // never mix drafts/triage/interaction-events/reply-cache into each other.
        let folderName = StowerMessagesStorageLocation.current.applicationSupportDirectoryName
        let bookmarkStore = StowerUserDefaultsItem(key: Self.messagesAccessBookmarkKey)
        messagesAccessBookmarkStore = bookmarkStore
        let (provider, demoContactsResolver) = Self.makeEngine(
            inFolder: folderName,
            bookmarkStore: bookmarkStore
        )
        startup = StowerMessagesStartupAdapter(engine: provider)
        contacts = StowerContactsAccess()
        // Build one live reporter shared across the startup funnel and the board.
        // The facade singleton (StowerAnalytics.shared) is the authoritative kill
        // switch; this reporter checks consent on every call (defence-in-depth).
        let consent = StowerDiagnosticsConsent()
        analyticsReporter = StowerTelemetryDeckReporter(consent: consent)
        guard let draftURL = StowerDraftStore.defaultURL(inFolder: folderName) else {
            throw StowerDraftStoreUnavailable.locationUnavailable
        }
        draftStore = StowerLiveDraftStore(store: try StowerDraftStore.open(at: draftURL))
        // The triage store is precious like drafts: it ALWAYS yields persistence
        // (quarantine-and-recreate on corruption, never delete), and only a true
        // disk-level fault throws — surfaced as a startup failure like any essential
        // store. Inject it into the board adapter so the filter applies the user's
        // dismiss/mute at display time.
        guard let triageURL = StowerTriageStore.defaultURL(inFolder: folderName) else {
            throw StowerTriageStoreUnavailable.locationUnavailable
        }
        let triage = StowerLiveTriageStore(store: try StowerTriageStore.open(at: triageURL))
        triageStore = triage
        if let demoContactsResolver {
            board = StowerLiveBoardDataSource(
                engine: provider,
                triage: triage,
                makeContactsResolver: demoContactsResolver
            )
        } else {
            board = StowerLiveBoardDataSource(engine: provider, triage: triage)
        }
        // Interaction recording is a NON-BLOCKING side log (gotcha #8): unlike drafts
        // and triage, a failure to open it must NEVER block the board. So it is opened
        // best-effort — any fault (unresolvable directory or a disk-level open error)
        // degrades to a no-op recorder, and dismiss/mute/unmute still work.
        interactions = Self.openInteractionRecorder(inFolder: folderName)
        dropper = StowerMessagesDropper()
    }

    /// Builds the shared engine provider and, in demo mode, its fake-contacts factory.
    ///
    /// A DEBUG-only `STOWER_MESSAGES_DB` override points the provider at a curated
    /// database (e.g. the demo db) without touching the user's real Messages history —
    /// absent (always so in Release) keeps the production, bookmark-backed source.
    /// When the override is active, the board also resolves names from an in-memory
    /// table of fake contacts so the demo shows names, not raw handles, without
    /// touching the real address book or the production `.live()` resolution path.
    /// The returned factory is `nil` outside demo mode (and always in Release).
    ///
    /// The production branch never captures a fixed bookmark `Data`: it passes a
    /// `loadMessagesAccessBookmark` closure that re-reads `StowerUserDefaultsItem`
    /// on every call, so a bookmark granted after this composition root ran takes
    /// effect on the very next load/refresh, not only after a relaunch (JC2).
    ///
    /// - Parameters:
    ///   - folderName: The build-variant Application Support subfolder the
    ///     provider's verdict cache lives under, passed explicitly (never the
    ///     default parameter — the default resolves the SAME variant folder
    ///     today, but relying on it here would silently stop tracking the
    ///     composition root's own folder name if the two ever diverge, e.g.
    ///     once demo mode gets its own folder).
    ///   - bookmarkStore: The composition root's single bookmark-storage
    ///     instance, reused here rather than constructed a second time.
    /// - Returns: The shared provider and, in demo mode only, the fake-contacts
    ///   resolver factory (`nil` outside demo mode and always in Release).
    private static func makeEngine(
        inFolder folderName: String,
        bookmarkStore: StowerUserDefaultsItem
    ) -> (
        provider: StowerDebtBoardProvider,
        demoContactsResolver: (@Sendable () -> StowerContactsResolver)?
    ) {
        let cacheURL = StowerDebtBoardProvider.cacheURL(inFolder: folderName)
        #if DEBUG
            if let overrideURL = StowerMessagesSourceOverride.resolved {
                let provider = StowerDebtBoardProvider(
                    demoSourceURL: overrideURL,
                    contactsResolver: StowerContactsResolver(),
                    cacheURL: cacheURL
                )
                return (provider, { StowerContactsResolver(mapping: StowerDemoContacts.mapping) })
            }
        #endif
        let provider = StowerDebtBoardProvider(
            loadMessagesAccessBookmark: { bookmarkStore.readData() },
            contactsResolver: StowerContactsResolver(),
            onBookmarkRefreshed: { bookmarkStore.write($0) },
            cacheURL: cacheURL
        )
        return (provider, nil)
    }

    /// The `UserDefaults` key holding the security-scoped bookmark `Data` for
    /// the user's granted Messages folder.
    ///
    /// `internal` (not `private`) so `StowerRootView`'s default constructs the
    /// exact same-keyed store without duplicating the literal.
    internal static let messagesAccessBookmarkKey = "messagesAccessBookmark"

    /// Opens the interaction recorder best-effort, degrading to a no-op on any fault.
    private static func openInteractionRecorder(
        inFolder folderName: String
    ) -> any StowerInteractionRecording {
        guard let url = StowerInteractionEventStore.defaultURL(inFolder: folderName) else {
            return StowerNoOpInteractionRecorder()
        }
        do {
            return StowerLiveInteractionRecorder(
                store: try StowerInteractionEventStore.open(at: url)
            )
        } catch {
            return StowerNoOpInteractionRecorder()
        }
    }

    // swiftlint:disable:next orphaned_doc_comment
    /// Pure URL resolution, given an explicit folder name.
    ///
    /// No store is opened, no file is created beyond `FileManager`'s own harmless
    /// `.applicationSupportDirectory` lookup. Exists so `StowerMessagesCompositionTests`
    /// can assert all 4 stores share one folder name WITHOUT calling `init()` (which
    /// opens real database connections against the REAL ambient `StowerDebug/` folder a
    /// live app instance may be using concurrently — exactly the collision this
    /// file's storage-location isolation closes elsewhere; a naive composition-root
    /// test would silently reintroduce it). The named tuple mirrors `init()`'s own
    /// four stores, with no single-use result type only a test would construct.
    // swiftlint:disable:next large_tuple
    internal static func resolvedURLs(forFolder folderName: String) -> (
        draftURL: URL?, triageURL: URL?, eventsURL: URL?, cacheURL: URL?
    ) {
        (
            StowerDraftStore.defaultURL(inFolder: folderName),
            StowerTriageStore.defaultURL(inFolder: folderName),
            StowerInteractionEventStore.defaultURL(inFolder: folderName),
            StowerDebtBoardProvider.cacheURL(inFolder: folderName)
        )
    }
}

/// The drafts store could not even be located (Application Support unresolvable) —
/// a disk-level failure surfaced to the caller, never papered over.
internal enum StowerDraftStoreUnavailable: Error, Equatable {
    /// Application Support could not be resolved or created.
    case locationUnavailable
}

/// The triage store could not even be located (Application Support unresolvable).
internal enum StowerTriageStoreUnavailable: Error, Equatable {
    /// Application Support could not be resolved or created.
    case locationUnavailable
}

/// Adapts the engine's precious `StowerDraftStore` to the app-owned
/// `StowerDraftStoring`, so the view layer never imports `StowerMessages`.
private struct StowerLiveDraftStore: StowerDraftStoring {
    private let store: StowerDraftStore

    init(store: StowerDraftStore) {
        self.store = store
    }

    func all() async throws -> [String: StowerDraftEntry] {
        try await store.all().mapValues {
            StowerDraftEntry(body: $0.body, updatedAt: $0.updatedAt, resolvedAt: $0.resolvedAt)
        }
    }

    func upsert(key: String, body: String) async throws {
        try await store.upsert(key: key, body: body)
    }

    func delete(key: String) async throws {
        try await store.delete(key: key)
    }

    func markSent(key: String) async throws {
        try await store.markSent(key: key)
    }

    func unmarkSent(key: String) async throws {
        try await store.unmarkSent(key: key)
    }
}

/// Adapts the engine's precious `StowerTriageStore` to the app-owned
/// `StowerTriageStoring`, so the board/view layer never imports `StowerMessages`.
private struct StowerLiveTriageStore: StowerTriageStoring {
    private let store: StowerTriageStore

    init(store: StowerTriageStore) {
        self.store = store
    }

    func dismissedMessages() async throws -> [String: StowerDismissedAnchor] {
        try await store.dismissedMessages().mapValues {
            StowerDismissedAnchor(messageGUID: $0.messageGUID, anchorTimestamp: $0.anchorTimestamp)
        }
    }

    func muted() async throws -> Set<String> {
        Set(try await store.muted().map(\.handleKey))
    }

    func dismiss(
        handleKey: String,
        messageGUID: String,
        anchorTimestamp: Date,
        at: Date
    ) async throws {
        try await store.dismiss(
            handleKey: handleKey,
            messageGUID: messageGUID,
            anchorTimestamp: anchorTimestamp,
            dismissedAt: at
        )
    }

    func undismiss(handleKey: String) async throws {
        try await store.undismiss(handleKey: handleKey)
    }

    func retireDismissal(
        handleKey: String,
        messageGUID: String,
        anchorTimestamp: Date,
        at: Date
    ) async throws {
        try await store.retireDismissal(
            handleKey: handleKey,
            messageGUID: messageGUID,
            anchorTimestamp: anchorTimestamp,
            retiredAt: at
        )
    }

    func mute(handleKey: String, at: Date) async throws {
        try await store.mute(handleKey: handleKey, mutedAt: at)
    }

    func unmute(handleKey: String, at: Date) async throws {
        try await store.unmute(handleKey: handleKey, unmutedAt: at)
    }
}

/// Adapts the engine's precious `StowerInteractionEventStore` to the app-owned
/// `StowerInteractionRecording`, mapping the app event to the engine event.
///
/// Recording is NON-blocking by contract: a store failure is swallowed (the action it
/// accompanies — dismiss/mute/unmute — has already committed and must not roll back).
private struct StowerLiveInteractionRecorder: StowerInteractionRecording {
    private let store: StowerInteractionEventStore

    init(store: StowerInteractionEventStore) {
        self.store = store
    }

    func record(_ event: StowerBoardInteractionEvent) async {
        // Swallow on failure: interaction memory is a side log; it must never block or
        // roll back the triage action. (Non-blocking contract — see the protocol doc.)
        try? await store.record(Self.engineEvent(for: event))
    }

    private static func engineEvent(
        for event: StowerBoardInteractionEvent
    ) -> StowerInteractionEvent {
        switch event {
        case let .messageDismissed(handleKey, messageGUID, boardTab, occurredAt):
            return .messageDismissed(
                handleKey: handleKey,
                messageGUID: messageGUID,
                boardTab: boardTab,
                occurredAt: occurredAt
            )
        case let .senderMuted(handleKey, surface, occurredAt):
            return .senderMuted(handleKey: handleKey, surface: surface, occurredAt: occurredAt)
        case let .senderUnmuted(handleKey, surface, occurredAt):
            return .senderUnmuted(handleKey: handleKey, surface: surface, occurredAt: occurredAt)
        }
    }
}

/// Re-exports the engine's Messages-database file name for the picker's
/// selection validation (JC4).
///
/// `StowerMessagesAccessPicker` must never hardcode the database's file name
/// literal (guard 6e) and must never `import StowerMessages` directly (guard
/// 6b's closed 4-file allowlist — this file is already one of the four). This
/// re-export satisfies both guards with a one-line addition here.
internal enum StowerMessagesAccessConstants {
    /// The Messages database's file name inside the granted folder.
    internal static let databaseFileName = StowerChatDatabaseReader.databaseFileName
}
