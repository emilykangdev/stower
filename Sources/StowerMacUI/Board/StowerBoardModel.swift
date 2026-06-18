import Foundation

/// Which lens of the debt board the toggle is showing.
///
/// The app's concrete name for the two lists the engine computes in one
/// `StowerDebtBoard` (its own doc-comments call them the Neglected/Ghosted lenses).
/// Switching direction reads the already-loaded model; it never re-queries (I7).
internal enum StowerBoardDirection: Sendable, Equatable, CaseIterable, Identifiable {
    /// The counterpart acted last — "you haven't replied."
    case neglected

    /// You acted last on a statement worth a reply — "waiting on them."
    case ghosted

    /// The picker identity.
    internal var id: Self { self }

    /// The toggle label for this direction.
    internal var title: String {
        switch self {
        case .neglected: return "Your turn"
        case .ghosted: return "Maybe follow up"
        }
    }
}

/// The app-owned two-lens board the views render.
///
/// A 1:1 app mirror of the engine's `StowerDebtBoard`, holding pre-ranked rows the
/// app never re-sorts (I2). Both lists arrive from a single `loadBoard`.
internal struct StowerBoardModel: Sendable, Equatable {
    /// Conversations the counterpart left with you, judged then ranked.
    internal let neglected: [StowerBoardRow]

    /// Conversations you left on a statement worth a reply, judged then ranked.
    internal let ghosted: [StowerBoardRow]

    /// Whether both lenses are empty (the "all caught up" condition).
    internal var isEmpty: Bool { neglected.isEmpty && ghosted.isEmpty }

    /// The rows for `direction`, taken verbatim from the loaded model.
    internal func rows(for direction: StowerBoardDirection) -> [StowerBoardRow] {
        switch direction {
        case .neglected: return neglected
        case .ghosted: return ghosted
        }
    }

    /// Creates a board model from its two pre-ranked lenses.
    internal init(neglected: [StowerBoardRow], ghosted: [StowerBoardRow]) {
        self.neglected = neglected
        self.ghosted = ghosted
    }
}
