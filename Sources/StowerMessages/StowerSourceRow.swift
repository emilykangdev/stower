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
    internal let rowID: Int64
    internal let guid: String?
    internal let identifier: String
    internal let displayName: String?
    internal let style: Int64

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
}
