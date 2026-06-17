import Foundation

/// One message in a tap-through thread read of a single conversation.
///
/// Lighter than `StowerMessageItem`: it carries only what a thread view renders
/// and adds `kind` so the app can label a non-text row. `text` is `nil` for a
/// non-text last act. `id` is the message GUID, so the list is stable across
/// reloads.
public struct StowerThreadMessage: Sendable, Identifiable, Equatable {
    /// The stable native message GUID.
    public let id: String

    /// Whether the current user sent the message.
    public let isFromMe: Bool

    /// When the message was sent.
    public let timestamp: Date

    /// The decoded body when the message is text/link; `nil` otherwise.
    public let text: String?

    /// The coarse kind of the message.
    public let kind: StowerConversationLastMessageKind

    /// Creates a thread-message row.
    public init(
        id: String,
        isFromMe: Bool,
        timestamp: Date,
        text: String?,
        kind: StowerConversationLastMessageKind
    ) {
        self.id = id
        self.isFromMe = isFromMe
        self.timestamp = timestamp
        self.text = text
        self.kind = kind
    }
}
