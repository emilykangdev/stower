import Foundation

/// Reads a validated, read-only snapshot of the local Messages Source DB.
public actor StowerChatDatabaseReader {
    private let snapshot: StowerChatSnapshot
    private let contacts: StowerContactsResolver

    /// The default local Messages database location.
    public static var defaultSourceURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
    }

    /// Creates a reader and one reusable ephemeral Source DB snapshot.
    public init(
        sourceURL: URL = StowerChatDatabaseReader.defaultSourceURL,
        contactsResolver: StowerContactsResolver = .live()
    ) throws {
        snapshot = try StowerChatSnapshot(sourceURL: sourceURL)
        contacts = contactsResolver
    }

    /// Returns decoded, indexable messages from the most recent window.
    public func ingestWindow(
        days: Int = 180,
        now: Date = Date()
    ) throws -> [StowerMessageItem] {
        guard days >= 0 else {
            throw StowerMessagesError.invalidArgument("Window days must not be negative.")
        }
        let startDate = now.addingTimeInterval(-Double(days) * 86_400)
        let source = try snapshot.ingestRows(since: startDate)
        return mapRows(
            source.rows,
            participants: source.participants,
            reverseForDisplay: false
        )
    }

    /// Returns the newest messages from one chat in chronological display order.
    public func recentMessages(
        chatID: String,
        limit: Int = 100
    ) throws -> [StowerMessageItem] {
        guard limit > 0 else {
            return []
        }
        let source = try snapshot.recentRows(chatID: chatID, limit: limit)
        return mapRows(
            source.rows,
            participants: source.participants,
            reverseForDisplay: true
        )
    }

    private func mapRows(
        _ rows: [StowerSourceMessageRow],
        participants: [Int64: [String]],
        reverseForDisplay: Bool
    ) -> [StowerMessageItem] {
        var seenGUIDs: Set<String> = []
        let items = rows.compactMap { row -> StowerMessageItem? in
            guard seenGUIDs.insert(row.guid).inserted else {
                return nil
            }
            let body = decodedBody(for: row)
            return StowerMessageMapper.map(
                row: row,
                body: body,
                participantHandles: participants[row.chat.rowID] ?? [],
                contacts: contacts
            )
        }
        return reverseForDisplay ? items.reversed() : items
    }

    private func decodedBody(for row: StowerSourceMessageRow) -> String? {
        guard let attributedBody = row.attributedBody else {
            return row.text
        }
        do {
            return try StowerAttributedBodyDecoder.decode(attributedBody) ?? row.text
        } catch {
            return row.text
        }
    }
}
