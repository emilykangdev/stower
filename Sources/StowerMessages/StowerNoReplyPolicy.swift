import Foundation

/// A 1:1 conversation where the counterpart acted last and the user has not
/// responded — the surfaced subset of a `StowerConversationState`.
///
/// A non-text last act (photo/sticker/attachment) is surfaced with its
/// `lastMessageKind` set and `lastMessageText == nil`, never suppressed. The UI
/// derives the unanswered duration from `lastMessageTimestamp`.
public struct StowerNoReplyCandidate: Sendable, Equatable {
    /// The stable chat identity.
    public let chatID: String

    /// The resolved conversation title.
    public let chatTitle: String

    /// The resolved counterpart name, or the raw handle when Contacts has none.
    public let counterpart: String

    /// The counterpart's raw identifier; a display fallback, not a dedupe key.
    public let counterpartHandle: String

    /// The kind of the counterpart's last act.
    public let lastMessageKind: StowerConversationLastMessageKind

    /// The text of the last act, or `nil` for a non-text last act.
    public let lastMessageText: String?

    /// The timestamp of the unanswered last act.
    public let lastMessageTimestamp: Date

    /// A best-effort Messages deep link, or `nil` when none can be formed.
    public let deepLink: URL?

    /// Creates a no-reply candidate.
    public init(
        chatID: String,
        chatTitle: String,
        counterpart: String,
        counterpartHandle: String,
        lastMessageKind: StowerConversationLastMessageKind,
        lastMessageText: String?,
        lastMessageTimestamp: Date,
        deepLink: URL?
    ) {
        self.chatID = chatID
        self.chatTitle = chatTitle
        self.counterpart = counterpart
        self.counterpartHandle = counterpartHandle
        self.lastMessageKind = lastMessageKind
        self.lastMessageText = lastMessageText
        self.lastMessageTimestamp = lastMessageTimestamp
        self.deepLink = deepLink
    }
}

/// The first policy over conversation-state facts: the "you haven't replied" pass.
///
/// Pure and stateless. Future framings (e.g. "you're drifting from this
/// person") are separate policies over the same `StowerConversationState`
/// facts, so they need no engine re-cut.
public enum StowerNoReplyPolicy {
    /// Selects the 1:1 conversations the user owes a reply to.
    ///
    /// Applies, per state: one-to-one → recent-reciprocity mutuality gate
    /// (`recentExchangeCount >= minimumReciprocity`) → counterpart acted last →
    /// the user has not tapped back the last act → unanswered for at least
    /// `unansweredForDays` days. Results are ranked most-recently-unanswered
    /// first, with deterministic ties (older timestamp loses, then `chatID`).
    ///
    /// - Parameters:
    ///   - states: Per-1:1 facts from `StowerConversationStateExtractor`.
    ///   - unansweredForDays: Minimum whole days since the counterpart's last
    ///     act. Negative values yield no candidates rather than crashing; the
    ///     reader validates the public boundary.
    ///   - minimumReciprocity: Minimum recent reciprocal exchanges to count the
    ///     thread as a real two-way relationship.
    ///   - now: The reference instant the age is measured against.
    /// - Returns: The qualifying candidates, ranked most-recently-unanswered first.
    public static func candidates(
        from states: [StowerConversationState],
        unansweredForDays: Int,
        minimumReciprocity: Int = 1,
        now: Date
    ) -> [StowerNoReplyCandidate] {
        let threshold = Double(unansweredForDays) * 86_400
        return
            states
            .filter {
                qualifies(
                    $0,
                    minimumReciprocity: minimumReciprocity,
                    threshold: threshold,
                    now: now
                )
            }
            .sorted(by: rank)
            .map(candidate)
    }

    private static func qualifies(
        _ state: StowerConversationState,
        minimumReciprocity: Int,
        threshold: Double,
        now: Date
    ) -> Bool {
        state.isOneToOne
            && state.recentExchangeCount >= minimumReciprocity
            && state.lastActor == .counterpart
            && !state.userReactedToLastMessage
            && now.timeIntervalSince(state.lastMessageTimestamp) >= threshold
    }

    private static func rank(
        _ lhs: StowerConversationState,
        _ rhs: StowerConversationState
    ) -> Bool {
        if lhs.lastMessageTimestamp != rhs.lastMessageTimestamp {
            return lhs.lastMessageTimestamp > rhs.lastMessageTimestamp
        }
        return lhs.chatID < rhs.chatID
    }

    private static func candidate(_ state: StowerConversationState) -> StowerNoReplyCandidate {
        StowerNoReplyCandidate(
            chatID: state.chatID,
            chatTitle: state.chatTitle,
            counterpart: state.counterpart,
            counterpartHandle: state.counterpartHandle,
            lastMessageKind: state.lastMessageKind,
            lastMessageText: state.lastMessageText,
            lastMessageTimestamp: state.lastMessageTimestamp,
            deepLink: state.deepLink
        )
    }
}
