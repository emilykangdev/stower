import Foundation

/// One row of the relationship-debt board — a conversation you owe attention to.
///
/// The same shape backs both lenses: the Neglected list (the counterpart acted
/// last) and the Ghosted list (you acted last on a statement worth responding
/// to). Every served row is already a trusted model verdict, so the row carries
/// no judge-mechanics discriminator — just display facts plus the model's
/// confidence. A non-text last act is surfaced with its `lastMessageKind` set and
/// `lastMessageText == nil`, never suppressed. The app derives "unanswered for N
/// days" from `lastMessageTimestamp` and maps this into its own view model.
public struct StowerDebtItem: Sendable, Equatable {
    /// The stable chat identity.
    public let chatID: String

    /// The resolved conversation title.
    public let chatTitle: String

    /// The resolved counterpart name, or the raw handle when Contacts has none.
    public let counterpart: String

    /// The counterpart's raw identifier; a display fallback, not a dedupe key.
    public let counterpartHandle: String

    /// The kind of the conversation's last act.
    public let lastMessageKind: StowerConversationLastMessageKind

    /// The text of the last act, or `nil` for a non-text last act.
    public let lastMessageText: String?

    /// The timestamp of the last act; the app derives the unanswered duration.
    public let lastMessageTimestamp: Date

    /// A best-effort Messages deep link, or `nil` when none can be formed.
    public let deepLink: URL?

    /// The on-device model's soft `0...1` confidence in this row's verdict.
    public let replyExpectationConfidence: Double

    /// Creates a debt-board row.
    public init(
        chatID: String,
        chatTitle: String,
        counterpart: String,
        counterpartHandle: String,
        lastMessageKind: StowerConversationLastMessageKind,
        lastMessageText: String?,
        lastMessageTimestamp: Date,
        deepLink: URL?,
        replyExpectationConfidence: Double
    ) {
        self.chatID = chatID
        self.chatTitle = chatTitle
        self.counterpart = counterpart
        self.counterpartHandle = counterpartHandle
        self.lastMessageKind = lastMessageKind
        self.lastMessageText = lastMessageText
        self.lastMessageTimestamp = lastMessageTimestamp
        self.deepLink = deepLink
        self.replyExpectationConfidence = replyExpectationConfidence
    }
}

extension StowerDebtItem {
    /// Builds a board row from a judged conversation, carrying only the model's
    /// confidence — every served row is already a trusted verdict.
    internal init(state: StowerConversationState, replyExpectationConfidence: Double) {
        self.init(
            chatID: state.chatID,
            chatTitle: state.chatTitle,
            counterpart: state.counterpart,
            counterpartHandle: state.counterpartHandle,
            lastMessageKind: state.lastMessageKind,
            lastMessageText: state.lastMessageText,
            lastMessageTimestamp: state.lastMessageTimestamp,
            deepLink: state.deepLink,
            replyExpectationConfidence: replyExpectationConfidence
        )
    }
}
