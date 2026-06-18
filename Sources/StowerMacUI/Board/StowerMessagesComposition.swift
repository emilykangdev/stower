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

    /// Builds the shared provider and both adapters over it.
    ///
    /// The engine is built with an **empty** `StowerContactsResolver()`, so it emits
    /// the raw handle as `counterpart` and does zero Contacts work: name resolution
    /// is owned solely by the app at the `StowerMessagesMapping.mapRow` seam (the
    /// board adapter's default `.live()` factory). This changes no verdict, ranking,
    /// or cache key — the name is absent from the judge (`context: []`) and the
    /// `inputHash` (text + kind only).
    internal init() {
        let provider = StowerDebtBoardProvider(contactsResolver: StowerContactsResolver())
        startup = StowerMessagesStartupAdapter(engine: provider)
        board = StowerLiveBoardDataSource(engine: provider)
        contacts = StowerContactsAccess()
    }
}
