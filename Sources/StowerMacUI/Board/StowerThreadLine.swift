import Foundation

/// One message bubble in a tap-through thread read, in app-owned display terms.
///
/// Built by the engine-coupled mapper from a `StowerThreadMessage`, preserving the
/// reader's order (oldest-first); the view never re-sorts. `Identifiable` by the
/// engine's stable message GUID so SwiftUI diffs bubbles by identity, not text.
internal struct StowerThreadLine: Identifiable, Sendable, Equatable {
    /// The stable native message GUID; also the SwiftUI list identity.
    internal let id: String

    /// Whether the current user sent the message (selects the bubble side).
    internal let isFromMe: Bool

    /// The last act's presentation (verbatim text or a non-text placeholder).
    internal let summary: StowerLastMessageSummary

    /// Whether this is the most recent line in the thread (rendered emphasized).
    internal let isMostRecent: Bool
}
