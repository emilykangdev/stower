import Foundation
import GRDB

internal enum StowerMessageQuery {
    internal static func ingestRows(
        database: Database,
        since date: Date
    ) throws -> [StowerSourceMessageRow] {
        try StowerSourceMessageRow.fetchAll(
            database,
            sql: baseSelect + """
                WHERE m.date != 0
                  AND \(referenceSecondsExpression) >= ?
                ORDER BY m.date ASC, m.ROWID ASC, c.ROWID ASC
                """,
            arguments: [StowerMessageDate.rawReferenceSeconds(from: date)]
        )
    }

    internal static func recentRows(
        database: Database,
        chatID: String,
        limit: Int
    ) throws -> [StowerSourceMessageRow] {
        try StowerSourceMessageRow.fetchAll(
            database,
            sql: baseSelect + """
                WHERE m.date != 0
                  AND m.associated_message_type = 0
                  AND m.item_type = 0
                  AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
                  AND (c.guid = ? OR c.chat_identifier = ?)
                ORDER BY m.date DESC, m.ROWID DESC
                LIMIT ?
                """,
            arguments: [chatID, chatID, limit]
        )
    }

    internal static func participants(
        database: Database,
        chatRowIDs: Set<Int64>
    ) throws -> [Int64: [String]] {
        guard !chatRowIDs.isEmpty else {
            return [:]
        }
        let placeholders = Array(repeating: "?", count: chatRowIDs.count).joined(separator: ",")
        let sortedIDs = chatRowIDs.sorted()
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT chj.chat_id AS chat_row_id, h.id AS handle
                FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                WHERE chj.chat_id IN (\(placeholders))
                ORDER BY chj.chat_id ASC, h.id ASC
                """,
            arguments: StatementArguments(sortedIDs)
        )
        return Dictionary(grouping: rows, by: { $0["chat_row_id"] }).mapValues { values in
            values.map { $0["handle"] }
        }
    }

    private static let referenceSecondsExpression = """
        CASE
          WHEN ABS(m.date) >= \(StowerMessageDate.nanosecondsThreshold)
            THEN CAST(m.date AS REAL) / 1000000000.0
          ELSE CAST(m.date AS REAL)
        END
        """

    private static let baseSelect = """
        SELECT
          m.ROWID AS message_row_id,
          m.guid AS message_guid,
          m.text AS text,
          m.attributedBody AS attributed_body,
          m.date AS raw_date,
          m.is_from_me AS is_from_me,
          m.handle_id AS handle_id,
          h.id AS sender_handle,
          m.associated_message_type AS associated_message_type,
          m.item_type AS item_type,
          m.cache_has_attachments AS has_attachments,
          m.balloon_bundle_id AS balloon_bundle_id,
          c.ROWID AS chat_row_id,
          c.guid AS chat_guid,
          c.chat_identifier AS chat_identifier,
          c.display_name AS chat_display_name,
          c.style AS chat_style
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id

        """
}
