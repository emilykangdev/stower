import Foundation

/// A source-agnostic value that can be stored in the Stower index.
public protocol StowerIndexedItem: Sendable {
    /// The source-native stable identifier.
    var id: String { get }

    /// The adapter that produced the item.
    var source: StowerSource { get }

    /// The body text searched by the index.
    var text: String { get }

    /// The time associated with the item.
    var timestamp: Date { get }

    /// Source-specific scalar metadata.
    var metadata: [String: String] { get }

    /// A best-effort URL that opens the source item.
    var deepLink: URL? { get }

    /// The stable identifier used to group related search results.
    var groupID: String { get }

    /// The user-facing title for the group.
    var groupTitle: String { get }
}
