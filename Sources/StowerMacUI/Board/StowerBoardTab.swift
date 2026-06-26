import Foundation

/// The board's three top-level tabs.
///
/// The first two are lenses over the already-loaded `StowerBoardModel` and map 1:1
/// to `StowerBoardDirection` (selecting one re-lenses without reloading — I7); the
/// third is the cross-cutting list of on-board drafts. `selectedTab` is the single
/// source of truth for the visible lens — `StowerBoardViewModel.direction` is
/// derived from it, never held in parallel (JC-A).
internal enum StowerBoardTab: Sendable, Equatable, CaseIterable, Identifiable {
    /// Conversations the counterpart left with you ("you haven't replied").
    case yourTurn

    /// Conversations you left on a reply-worthy statement ("waiting on them").
    case maybeFollowUp

    /// Every on-board conversation that has a private draft.
    case drafts

    /// The tab-control identity.
    internal var id: Self { self }

    /// The lens this tab presents, or `nil` for the cross-cutting Drafts tab.
    internal var direction: StowerBoardDirection? {
        switch self {
        case .yourTurn: return .neglected
        case .maybeFollowUp: return .ghosted
        case .drafts: return nil
        }
    }

    /// The tab's segment label.
    ///
    /// Lens tabs reuse the lens title, keeping one source of truth for the labels.
    internal var title: String {
        direction?.title ?? "Drafts"
    }

    /// The stable snake-case token recorded on a `message_dismissed` interaction
    /// event's `boardTab` field, so the local memory log stays greppable and stable
    /// across UI copy changes (never the localized `title`).
    internal var eventToken: String {
        switch self {
        case .yourTurn: return Self.yourTurnToken
        case .maybeFollowUp: return Self.maybeFollowUpToken
        case .drafts: return Self.draftsToken
        }
    }

    /// The persisted `boardTab` tokens — typo-proof, greppable constants (never the
    /// localized `title`), so a UI copy change can't silently fork the memory log.
    private static let yourTurnToken = "your_turn"
    private static let maybeFollowUpToken = "maybe_follow_up"
    private static let draftsToken = "drafts"
}
