import Foundation

/// The "unanswered for at least N days" filter the board offers.
///
/// The raw value is the day count itself, so `days` needs no lookup table. Every
/// preset stays within the provider's default read window (180 days), so the
/// engine's `unansweredForDays <= windowDays` guard always holds. Changing the
/// preset re-runs `loadBoard` with the new threshold (I8); the engine re-gates and
/// re-ranks — the app never client-filters.
internal enum StowerDayPreset: Int, Sendable, Equatable, CaseIterable, Identifiable {
    case sevenDays = 7
    case fourteenDays = 14
    case twentyEightDays = 28
    case sixtyDays = 60
    case ninetyDays = 90

    /// The board's default preset (the first, shortest window).
    internal static let `default` = StowerDayPreset.sevenDays

    /// The day threshold passed to the engine config.
    internal var days: Int { rawValue }

    /// The picker identity.
    internal var id: Int { rawValue }

    /// The filter label (e.g. "7 days").
    internal var title: String { "\(days) days" }
}
