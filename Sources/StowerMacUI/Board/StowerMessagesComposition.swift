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

    /// Builds the shared provider and both adapters over it.
    internal init() {
        let provider = StowerDebtBoardProvider()
        startup = StowerMessagesStartupAdapter(engine: provider)
        board = StowerLiveBoardDataSource(engine: provider)
    }
}
