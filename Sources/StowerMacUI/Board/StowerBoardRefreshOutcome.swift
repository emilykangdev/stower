import Foundation

/// The app-owned distillation of a background `refreshJudgments` pass.
///
/// The engine-coupled adapter collapses `StowerRefreshSummary?` into this so the
/// view-model decides usable-vs-empty-vs-broken without engine types. The signals
/// follow the engine's own contract plus the app's I9 split:
/// - `.coalesced` — the engine returned `nil`: a pass is already running. Keep the
///   current state; neither reload nor clear.
/// - `.completed` — `judgedCount + failedCount == totalCount` (the pass finished).
///   `reloadNeeded` is `changedCount > 0`; `anyJudged` is `judgedCount > 0`;
///   `hadRecords` is `totalCount > 0`.
/// - `.incomplete` — a non-nil summary with `judged + failed < total`: the engine's
///   loop was parent-cancelled mid-pass. The app keeps "preparing" and re-issues;
///   it never errors and never passively hangs.
internal enum StowerBoardRefreshOutcome: Sendable, Equatable {
    /// A pass is already running (engine returned `nil`).
    case coalesced

    /// The pass finished; resolves to rows / caught-up / error per I9.
    case completed(reloadNeeded: Bool, anyJudged: Bool, hadRecords: Bool)

    /// The pass was parent-cancelled mid-way; keep preparing and re-issue.
    case incomplete(reloadNeeded: Bool)
}
