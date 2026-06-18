import Foundation

/// One row of the relationship-debt board, in app-owned display terms.
///
/// Built by the engine-coupled mapper from a `StowerDebtItem`; the views never see
/// the engine type. It is `Identifiable` by the engine's stable `chatID` (never the
/// mutable `counterpart` display text), so SwiftUI diffs the list across a reload
/// by stable identity. It deliberately carries **no** confidence value — v1 renders
/// list membership only, not the raw `replyExpectationConfidence` (the engine
/// already spent it in the Ghosted gate).
internal struct StowerBoardRow: Identifiable, Sendable, Equatable, Hashable {
    /// The stable chat identity; also the SwiftUI list identity.
    internal let chatID: String

    /// The resolved counterpart name, or the raw handle when Contacts has none.
    internal let counterpart: String

    /// The counterpart's raw identifier; a display fallback, never a key.
    internal let counterpartHandle: String

    /// One- or two-letter monogram derived from `counterpart`.
    internal let monogram: String

    /// The last act's presentation (verbatim text or a non-text placeholder).
    internal let summary: StowerLastMessageSummary

    /// Whole days since the last act, floored, never negative.
    internal let ageInDays: Int

    /// A best-effort Messages deep link, or `nil` when none can be formed.
    internal let deepLink: URL?

    /// The SwiftUI identity: the stable `chatID`.
    internal var id: String { chatID }

    /// Whether "Open in Messages" is enabled — exactly `deepLink != nil`.
    internal var canOpenInMessages: Bool { deepLink != nil }

    /// Whether a Contacts name resolved (`counterpart` is a real name, not the handle).
    ///
    /// Drives the avatar: a named row shows its initials monogram, an unresolved
    /// handle shows a generic person glyph instead of a meaningless digit (every
    /// unknown `+1…` number would otherwise collapse to an identical "1").
    internal var hasResolvedName: Bool { counterpart != counterpartHandle }

    /// Creates a board row from already-computed display values.
    internal init(
        chatID: String,
        counterpart: String,
        counterpartHandle: String,
        monogram: String,
        summary: StowerLastMessageSummary,
        ageInDays: Int,
        deepLink: URL?
    ) {
        self.chatID = chatID
        self.counterpart = counterpart
        self.counterpartHandle = counterpartHandle
        self.monogram = monogram
        self.summary = summary
        self.ageInDays = ageInDays
        self.deepLink = deepLink
    }
}

extension StowerBoardRow {
    /// Whole days between `timestamp` and `now`, floored, clamped at zero.
    ///
    /// - Parameters:
    ///   - timestamp: The last act's time.
    ///   - now: The reference time the board was loaded at.
    /// - Returns: A non-negative day count (future skew clamps to `0`).
    internal static func ageInDays(from timestamp: Date, to now: Date) -> Int {
        let elapsed = now.timeIntervalSince(timestamp)
        guard elapsed > 0 else { return 0 }
        return Int(elapsed / Self.secondsPerDay)
    }

    /// A one- or two-letter uppercased monogram from a display name.
    ///
    /// - Parameter name: The counterpart's display name (or raw handle).
    /// - Returns: Up to two leading letters of the first two words, or `"?"` when
    ///   the name has no letters.
    internal static func monogram(for name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        let initials = words.prefix(Self.monogramLetters).compactMap { word in
            word.first(where: { $0.isLetter || $0.isNumber })
        }
        guard !initials.isEmpty else { return Self.monogramFallback }
        return String(initials).uppercased()
    }

    private static let secondsPerDay: TimeInterval = 86_400
    private static let monogramLetters = 2
    private static let monogramFallback = "?"
}
