import Foundation

/// The "unanswered for at least N days" filter the board offers.
///
/// The raw value is the day count itself, so `days` needs no lookup table. `.all`
/// (0 days) passes `unansweredForDays = 0`, which the engine's existing
/// `age >= 0` gate treats as "every unanswered conversation, any age" — so a reply
/// you owe from an hour ago shows immediately, no engine change. Every preset stays
/// within the provider's default read window (180 days), so the engine's
/// `unansweredForDays <= windowDays` guard always holds. Changing the preset
/// re-runs `loadBoard` with the new threshold (I8); the engine re-gates and
/// re-ranks — the app never client-filters.
internal enum StowerDayPreset: Int, Sendable, Equatable, CaseIterable, Identifiable {
    case all = 0
    case sevenDays = 7
    case fourteenDays = 14
    case twentyEightDays = 28
    case sixtyDays = 60
    case ninetyDays = 90

    /// The board's default preset: every unanswered conversation, any age, so the
    /// board never hides a recent reply you owe.
    internal static let `default` = StowerDayPreset.all

    /// The day threshold passed to the engine config (0 means "any age").
    internal var days: Int { rawValue }

    /// The picker identity.
    internal var id: Int { rawValue }

    /// The filter label; `.all` reads as "All", the rest as "N days".
    internal var title: String {
        switch self {
        case .all: return "All"
        case .sevenDays, .fourteenDays, .twentyEightDays, .sixtyDays, .ninetyDays:
            return "\(days) days"
        }
    }
}
