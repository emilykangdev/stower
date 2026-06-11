import Foundation
import GRDB

/// The flattened representation of an indexed item stored in SQLite.
public struct StowerStoredItem: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// The Index DB table used for stored items.
    public static let databaseTableName = "item"

    /// The source-namespaced stable identifier.
    public let id: String

    /// The source raw value.
    public let source: String

    /// The searchable body text.
    public let text: String

    /// The item's Unix timestamp.
    public let timestamp: Double

    /// The serialized deep link.
    public let deepLink: String?

    /// The conversation or collection identifier.
    public let groupID: String

    /// The conversation or collection display title.
    public let groupTitle: String

    /// Sorted-key JSON containing source-specific metadata.
    public let metadata: String

    internal init<Item: StowerIndexedItem>(from item: Item) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadataData = try encoder.encode(item.metadata)
        guard let metadata = String(data: metadataData, encoding: .utf8) else {
            throw StowerStoredItemError.invalidMetadataEncoding
        }

        self.id = "\(item.source.rawValue):\(item.id)"
        self.source = item.source.rawValue
        self.text = item.text
        self.timestamp = item.timestamp.timeIntervalSince1970
        self.deepLink = item.deepLink?.absoluteString
        self.groupID = item.groupID
        self.groupTitle = item.groupTitle
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case text
        case timestamp
        case deepLink = "deep_link"
        case groupID = "group_id"
        case groupTitle = "group_title"
        case metadata
    }
}

private enum StowerStoredItemError: Error {
    case invalidMetadataEncoding
}
