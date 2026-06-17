import Foundation
import StowerCore

/// A decoded Messages row ready for display and indexing.
public struct StowerMessageItem: StowerIndexedItem, Sendable {
    /// The stable native message GUID.
    public let id: String

    /// The decoded body.
    public let text: String

    /// The message date.
    public let timestamp: Date

    /// A best-effort Messages deep link.
    public let deepLink: URL?

    /// The stable chat identifier.
    public let groupID: String

    /// The resolved chat title.
    public let groupTitle: String

    /// Whether the current user sent the message.
    public let isFromMe: Bool

    /// The resolved sender label for this row.
    public let sender: String

    /// Whether this message belongs to a one-to-one (non-group) conversation.
    public let isOneToOne: Bool

    /// The source adapter.
    public let source = StowerSource.messages

    /// Scalar metadata persisted by StowerCore.
    public var metadata: [String: String] {
        ["direction": isFromMe ? "outgoing" : "incoming", "sender": sender]
    }

    internal init(
        id: String,
        text: String,
        timestamp: Date,
        deepLink: URL?,
        groupID: String,
        groupTitle: String,
        isFromMe: Bool,
        sender: String,
        isOneToOne: Bool
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.deepLink = deepLink
        self.groupID = groupID
        self.groupTitle = groupTitle
        self.isFromMe = isFromMe
        self.sender = sender
        self.isOneToOne = isOneToOne
    }
}
