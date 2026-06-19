import Foundation
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

    /// The "Reply in Messages" bridge.
    internal let dropper: StowerMessagesDropper

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
        let provider = StowerDebtBoardProvider(contactsResolver: StowerContactsResolver())
        startup = StowerMessagesStartupAdapter(engine: provider)
        board = StowerLiveBoardDataSource(engine: provider)
        contacts = StowerContactsAccess()
        guard let url = StowerDraftStore.defaultURL else {
            throw StowerDraftStoreUnavailable.locationUnavailable
        }
        draftStore = StowerLiveDraftStore(store: try StowerDraftStore.open(at: url))
        dropper = StowerMessagesDropper()
    }
}

/// The drafts store could not even be located (Application Support unresolvable) —
/// a disk-level failure surfaced to the caller, never papered over.
internal enum StowerDraftStoreUnavailable: Error, Equatable {
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
            StowerDraftEntry(body: $0.body, updatedAt: $0.updatedAt)
        }
    }

    func upsert(key: String, body: String) async throws {
        try await store.upsert(key: key, body: body)
    }

    func delete(key: String) async throws {
        try await store.delete(key: key)
    }
}
