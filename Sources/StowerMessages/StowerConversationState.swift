import Foundation

/// Who acted last in a conversation, derived from the true chronology.
public enum StowerConversationLastActor: Sendable, Equatable {
    /// The current user sent the last act.
    case user

    /// The counterpart sent the last act.
    case counterpart
}

/// A coarse label for the kind of a conversation's last act.
///
/// Populated from the message row alone (no `attachment`-table join), so
/// `attachment` is generic — it is not split into photo/voice/video/file in v1.
///
/// Backed by an explicit `String` raw value because the case token is folded into
/// the persisted verdict-cache key (`inputHash`). `rawValue` is a stable
/// serialization contract; `String(describing:)` is not (Apple documents it as
/// debug-only), so keying on it would silently re-hash the on-disk cache on a case
/// rename or compiler change. The raw values equal the old `String(describing:)`
/// output, so existing cache entries stay valid.
public enum StowerConversationLastMessageKind: String, Sendable, Equatable {
    /// A text message (its body is available in `lastMessageText`).
    case text

    /// A link preview (URL kept in the body, available in `lastMessageText`).
    case link

    /// An attachment of any type (photo, file, voice note, video, sticker).
    case attachment

    /// A non-URL app/extension balloon (payment, FindMy, …).
    case app

    /// Any other content the row alone cannot classify.
    case other
}

/// Neutral, per-1:1-conversation evidence for any policy or UI to read.
///
/// This is the facts boundary: it states what happened (who acted last, when,
/// how recently the two sides exchanged, whether the user reacted) without
/// deciding whether the user owes a reply. `StowerNoReplyPolicy` is the first
/// policy over these facts; a future "drifting" policy needs no engine re-cut.
public struct StowerConversationState: Sendable, Equatable {
    /// The stable chat identity (`StowerMessageItem.groupID`).
    public let chatID: String

    /// The resolved conversation title.
    public let chatTitle: String

    /// The resolved counterpart name, or the raw handle when Contacts has none.
    public let counterpart: String

    /// The counterpart's raw identifier (phone/email); a display fallback, not a
    /// dedupe key.
    public let counterpartHandle: String

    /// Whether this is a one-to-one (non-group) conversation.
    public let isOneToOne: Bool

    /// Who acted last, from the true chronology (any content type).
    public let lastActor: StowerConversationLastActor

    /// When the counterpart last acted, if ever in the window.
    public let lastInboundAt: Date?

    /// When the user last acted, if ever in the window.
    public let lastOutboundAt: Date?

    /// The kind of the true last act.
    public let lastMessageKind: StowerConversationLastMessageKind

    /// The text of the last act when it is text/link; `nil` for a non-text last
    /// act (photo/sticker/attachment/app).
    public let lastMessageText: String?

    /// The timestamp of the true last act.
    public let lastMessageTimestamp: Date

    /// Reciprocal direction-changes within the recent sub-window — the recency
    /// signal a policy gates mutuality on (user reactions count as user acts).
    public let recentExchangeCount: Int

    /// Whether the user has an active tapback on the true last act.
    public let userReactedToLastMessage: Bool

    /// Whether the counterpart has an active tapback on the true last act.
    ///
    /// Symmetric to `userReactedToLastMessage`. The Ghosted gate reads it: a
    /// counterpart 👍 on your last message means they acknowledged it, so it is
    /// not a ghost even though they sent no text reply.
    public let counterpartReactedToLastMessage: Bool

    /// A best-effort Messages deep link, or `nil` when none can be formed.
    public let deepLink: URL?

    /// Creates a conversation-state facts value.
    public init(
        chatID: String,
        chatTitle: String,
        counterpart: String,
        counterpartHandle: String,
        isOneToOne: Bool,
        lastActor: StowerConversationLastActor,
        lastInboundAt: Date?,
        lastOutboundAt: Date?,
        lastMessageKind: StowerConversationLastMessageKind,
        lastMessageText: String?,
        lastMessageTimestamp: Date,
        recentExchangeCount: Int,
        userReactedToLastMessage: Bool,
        counterpartReactedToLastMessage: Bool,
        deepLink: URL?
    ) {
        self.chatID = chatID
        self.chatTitle = chatTitle
        self.counterpart = counterpart
        self.counterpartHandle = counterpartHandle
        self.isOneToOne = isOneToOne
        self.lastActor = lastActor
        self.lastInboundAt = lastInboundAt
        self.lastOutboundAt = lastOutboundAt
        self.lastMessageKind = lastMessageKind
        self.lastMessageText = lastMessageText
        self.lastMessageTimestamp = lastMessageTimestamp
        self.recentExchangeCount = recentExchangeCount
        self.userReactedToLastMessage = userReactedToLastMessage
        self.counterpartReactedToLastMessage = counterpartReactedToLastMessage
        self.deepLink = deepLink
    }
}
