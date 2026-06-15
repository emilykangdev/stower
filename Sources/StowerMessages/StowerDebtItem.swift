import Foundation

/// One row of the relationship-debt board — a conversation you owe attention to.
///
/// The same shape backs both lenses: the Neglected list (the counterpart acted
/// last) and the Ghosted list (you acted last on a real ask with no reply). A
/// non-text last act is surfaced with its `lastMessageKind` set and
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

    /// Whether the judged last message reads as expecting a reply.
    public let expectsReply: Bool

    /// Soft `0...1` confidence; trust only when `verdictSource == .languageModel`.
    public let replyExpectationConfidence: Double

    /// Which judge produced the reply-expectation verdict for this row.
    public let verdictSource: StowerReplyJudgeSource

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
        expectsReply: Bool,
        replyExpectationConfidence: Double,
        verdictSource: StowerReplyJudgeSource
    ) {
        self.chatID = chatID
        self.chatTitle = chatTitle
        self.counterpart = counterpart
        self.counterpartHandle = counterpartHandle
        self.lastMessageKind = lastMessageKind
        self.lastMessageText = lastMessageText
        self.lastMessageTimestamp = lastMessageTimestamp
        self.deepLink = deepLink
        self.expectsReply = expectsReply
        self.replyExpectationConfidence = replyExpectationConfidence
        self.verdictSource = verdictSource
    }
}

extension StowerDebtItem {
    /// Builds a board row from a judged conversation, copying the verdict fields.
    internal init(state: StowerConversationState, verdict: StowerReplyExpectation) {
        self.init(
            chatID: state.chatID,
            chatTitle: state.chatTitle,
            counterpart: state.counterpart,
            counterpartHandle: state.counterpartHandle,
            lastMessageKind: state.lastMessageKind,
            lastMessageText: state.lastMessageText,
            lastMessageTimestamp: state.lastMessageTimestamp,
            deepLink: state.deepLink,
            expectsReply: verdict.expectsReply,
            replyExpectationConfidence: verdict.replyExpectationConfidence,
            verdictSource: verdict.verdictSource
        )
    }
}
