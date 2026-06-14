import Foundation
import GRDB

internal struct StowerSourceMessageRow: Decodable, FetchableRecord, Sendable {
    internal let messageRowID: Int64
    internal let guid: String
    internal let text: String?
    internal let attributedBody: Data?
    internal let rawDate: Int64
    internal let isFromMe: Bool
    internal let handleID: Int64
    internal let senderHandle: String?
    internal let associatedMessageType: Int64
    internal let itemType: Int64
    internal let hasAttachments: Bool
    internal let balloonBundleID: String?
    internal let chat: StowerSourceChatRow

    private enum CodingKeys: String, CodingKey {
        case messageRowID = "message_row_id"
        case guid = "message_guid"
        case text
        case attributedBody = "attributed_body"
        case rawDate = "raw_date"
        case isFromMe = "is_from_me"
        case handleID = "handle_id"
        case senderHandle = "sender_handle"
        case associatedMessageType = "associated_message_type"
        case itemType = "item_type"
        case hasAttachments = "has_attachments"
        case balloonBundleID = "balloon_bundle_id"
        case chat
    }

    internal init(row: Row) throws {
        messageRowID = row["message_row_id"]
        guid = row["message_guid"]
        text = row["text"]
        attributedBody = row["attributed_body"]
        rawDate = row["raw_date"]
        isFromMe = row["is_from_me"]
        handleID = row["handle_id"]
        senderHandle = row["sender_handle"]
        associatedMessageType = row["associated_message_type"]
        itemType = row["item_type"]
        hasAttachments = row["has_attachments"]
        balloonBundleID = row["balloon_bundle_id"]
        chat = try StowerSourceChatRow(row: row)
    }
}

internal struct StowerSourceChatRow: Decodable, FetchableRecord, Sendable {
    /// Apple's `chat.style` value for a one-to-one (non-group) conversation.
    internal static let directChatStyle: Int64 = 45

    internal let rowID: Int64
    internal let guid: String?
    internal let identifier: String
    internal let displayName: String?
    internal let style: Int64

    /// Whether this is a one-to-one (non-group) conversation.
    internal var isOneToOne: Bool {
        style == Self.directChatStyle
    }

    /// The stable chat identity used to group rows of one conversation.
    internal var groupID: String {
        if let guid, !guid.isEmpty {
            return guid
        }
        if !identifier.isEmpty {
            return identifier
        }
        return "chat:\(rowID)"
    }

    /// A best-effort Messages deep link, or `nil` for group chats.
    ///
    /// Group chats stay `nil`: there is no public per-chat URL, and an `sms:`
    /// compose link with the full recipient set CREATES A NEW group instead of
    /// matching the existing one (verified on real data, 2026-06-11). Callers
    /// must offer their own navigation fallback.
    internal var deepLink: URL? {
        guard isOneToOne else {
            return nil
        }
        // chat_identifier is the chat's canonical counterpart address. The
        // participant list can hold several handles for one person (old email +
        // current phone), so picking any of those can open the wrong
        // conversation in Messages.
        let address = identifier.trimmingCharacters(in: .whitespaces)
        // Email identifiers can carry reserved URL characters (#, ?, %) in the
        // local part; interpolating them raw would split the address into a
        // fragment/query and open the wrong conversation, so percent-encode first.
        guard !address.isEmpty,
            let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            return nil
        }
        return URL(string: "sms:\(encoded)")
    }

    private enum CodingKeys: String, CodingKey {
        case rowID = "chat_row_id"
        case guid = "chat_guid"
        case identifier = "chat_identifier"
        case displayName = "chat_display_name"
        case style = "chat_style"
    }

    internal init(row: Row) throws {
        rowID = row["chat_row_id"]
        guid = row["chat_guid"]
        identifier = row["chat_identifier"]
        displayName = row["chat_display_name"]
        style = row["chat_style"]
    }

    internal init(
        rowID: Int64,
        guid: String?,
        identifier: String,
        displayName: String?,
        style: Int64
    ) {
        self.rowID = rowID
        self.guid = guid
        self.identifier = identifier
        self.displayName = displayName
        self.style = style
    }
}

/// A lightweight chronology row: any real message of any content type.
///
/// Unlike the indexable read, this keeps photos, files, app payloads, and link
/// previews so the extractor can find the TRUE last act and label its kind. It
/// still excludes reactions (`associated_message_type = 0`) and system rows
/// (`item_type = 0`), whose `is_from_me` is unreliable. No body is decoded.
internal struct StowerSourceActivityRow: Decodable, FetchableRecord, Sendable {
    internal let guid: String
    internal let rawDate: Int64
    internal let isFromMe: Bool
    internal let hasAttachments: Bool
    internal let balloonBundleID: String?
    internal let hasText: Bool
    internal let chat: StowerSourceChatRow

    private enum CodingKeys: String, CodingKey {
        case guid = "message_guid"
        case rawDate = "raw_date"
        case isFromMe = "is_from_me"
        case hasAttachments = "has_attachments"
        case balloonBundleID = "balloon_bundle_id"
        case hasText = "has_text"
        case chat
    }

    internal init(row: Row) throws {
        guid = row["message_guid"]
        rawDate = row["raw_date"]
        isFromMe = row["is_from_me"]
        hasAttachments = row["has_attachments"]
        balloonBundleID = row["balloon_bundle_id"]
        hasText = row["has_text"]
        chat = try StowerSourceChatRow(row: row)
    }

    internal init(
        guid: String,
        rawDate: Int64,
        isFromMe: Bool,
        hasAttachments: Bool,
        balloonBundleID: String?,
        hasText: Bool,
        chat: StowerSourceChatRow
    ) {
        self.guid = guid
        self.rawDate = rawDate
        self.isFromMe = isFromMe
        self.hasAttachments = hasAttachments
        self.balloonBundleID = balloonBundleID
        self.hasText = hasText
        self.chat = chat
    }
}

/// One of the user's own tapback rows, carrying its chat provenance.
///
/// The reaction's own chat is joined in (`chat_message_join` → `chat`) so
/// mutuality-by-reaction works even when the reacted-to message itself was
/// dropped from the indexable window. `reactionRowID` gives a deterministic
/// tie-break when an add and a remove share a timestamp.
internal struct StowerSourceReactionRow: Decodable, FetchableRecord, Sendable {
    internal let reactionRowID: Int64
    internal let associatedMessageGuid: String?
    internal let associatedMessageType: Int64
    internal let rawDate: Int64
    internal let isFromMe: Bool
    internal let chat: StowerSourceChatRow

    private enum CodingKeys: String, CodingKey {
        case reactionRowID = "reaction_row_id"
        case associatedMessageGuid = "associated_message_guid"
        case associatedMessageType = "associated_message_type"
        case rawDate = "raw_date"
        case isFromMe = "is_from_me"
        case chat
    }

    internal init(row: Row) throws {
        reactionRowID = row["reaction_row_id"]
        associatedMessageGuid = row["associated_message_guid"]
        associatedMessageType = row["associated_message_type"]
        rawDate = row["raw_date"]
        isFromMe = row["is_from_me"]
        chat = try StowerSourceChatRow(row: row)
    }

    internal init(
        reactionRowID: Int64,
        associatedMessageGuid: String?,
        associatedMessageType: Int64,
        rawDate: Int64,
        isFromMe: Bool,
        chat: StowerSourceChatRow
    ) {
        self.reactionRowID = reactionRowID
        self.associatedMessageGuid = associatedMessageGuid
        self.associatedMessageType = associatedMessageType
        self.rawDate = rawDate
        self.isFromMe = isFromMe
        self.chat = chat
    }
}
