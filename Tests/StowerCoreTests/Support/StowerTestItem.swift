import Foundation
import StowerCore

/// A synthetic indexable item shared across StowerCore test suites.
internal struct StowerTestItem: StowerIndexedItem {
    internal let id: String
    internal let source: StowerSource
    internal let text: String
    internal let timestamp: Date
    internal let metadata: [String: String]
    internal let deepLink: URL?
    internal let groupID: String
    internal let groupTitle: String

    internal init(
        id: String,
        source: StowerSource = .messages,
        text: String,
        title: String = "Fixture",
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        metadata: [String: String] = [:],
        groupID: String? = nil
    ) {
        self.id = id
        self.source = source
        self.text = text
        self.timestamp = timestamp
        self.metadata = metadata
        deepLink = nil
        self.groupID = groupID ?? "group-\(id)"
        groupTitle = title
    }

    /// The id as stored after source namespacing (`<source>:<native-id>`).
    internal var namespacedID: String { "\(source.rawValue):\(id)" }
}
