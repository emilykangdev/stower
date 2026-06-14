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
                  AND \(indexableMessagePredicate)
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
                  AND \(indexableMessagePredicate)
                  AND (c.guid = ? OR c.chat_identifier = ?)
                ORDER BY m.date DESC, m.ROWID DESC
                LIMIT ?
                """,
            arguments: [chatID, chatID, limit]
        )
    }

    /// Reads the full chronology of real messages in the window — any content type.
    ///
    /// Keeps text, photos, files, app payloads, and link previews, but excludes
    /// reactions and system rows, so the extractor can find the TRUE last act per
    /// chat and label its kind without decoding any body.
    internal static func activityRows(
        database: Database,
        since date: Date
    ) throws -> [StowerSourceActivityRow] {
        try StowerSourceActivityRow.fetchAll(
            database,
            sql: """
                SELECT
                  m.guid AS message_guid,
                  m.date AS raw_date,
                  m.is_from_me AS is_from_me,
                  m.cache_has_attachments AS has_attachments,
                  m.balloon_bundle_id AS balloon_bundle_id,
                  (m.text IS NOT NULL OR m.attributedBody IS NOT NULL) AS has_text,
                  \(chatColumns)
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                JOIN chat c ON c.ROWID = cmj.chat_id
                WHERE m.date != 0
                  AND m.associated_message_type = 0
                  AND m.item_type = 0
                  AND \(referenceSecondsExpression) >= ?
                ORDER BY m.date ASC, m.ROWID ASC, c.ROWID ASC
                """,
            arguments: [StowerMessageDate.rawReferenceSeconds(from: date)]
        )
    }

    /// Reads the user's own tapback rows in the window, each joined to its chat.
    ///
    /// Restricted to `is_from_me = 1` (only the user's reactions establish their
    /// engagement) and the reaction range `2000–3999` (added and removed). The
    /// `(date, ROWID)` order makes add/remove netting deterministic.
    internal static func myReactionRows(
        database: Database,
        since date: Date
    ) throws -> [StowerSourceReactionRow] {
        try StowerSourceReactionRow.fetchAll(
            database,
            sql: """
                SELECT
                  m.ROWID AS reaction_row_id,
                  m.associated_message_guid AS associated_message_guid,
                  m.associated_message_type AS associated_message_type,
                  m.date AS raw_date,
                  m.is_from_me AS is_from_me,
                  \(chatColumns)
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                JOIN chat c ON c.ROWID = cmj.chat_id
                WHERE m.is_from_me = 1
                  AND m.associated_message_type BETWEEN 2000 AND 3999
                  AND \(referenceSecondsExpression) >= ?
                ORDER BY m.date ASC, m.ROWID ASC
                """,
            arguments: [StowerMessageDate.rawReferenceSeconds(from: date)]
        )
    }

    /// Recovers the bare `message.guid` a tapback targets.
    ///
    /// `associated_message_guid` is prefix-encoded on real `chat.db`
    /// (`p:N/<guid>`, `bp:<guid>`); only ~12% are bare. Take the substring after
    /// the last `/` if present, else after the `:` if present, else the value
    /// unchanged. Compare *that* to `message.guid`. See `Docs/AppleEncodings.md`
    /// §1; a bare comparison silently no-ops on ~88% of real reactions.
    internal static func normalizeAssociatedGUID(_ value: String) -> String {
        if let slashIndex = value.lastIndex(of: "/") {
            return String(value[value.index(after: slashIndex)...])
        }
        if let colonIndex = value.lastIndex(of: ":") {
            return String(value[value.index(after: colonIndex)...])
        }
        return value
    }

    internal static func participants(
        database: Database,
        chatRowIDs: Set<Int64>
    ) throws -> [Int64: [String]] {
        guard !chatRowIDs.isEmpty else {
            return [:]
        }
        // One placeholder per chat; SQLite allows 32,766 parameters, far above
        // any realistic Messages chat count.
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

    /// Matches plain messages plus URL link previews.
    ///
    /// Link previews keep the shared URL as body text; other balloon payloads
    /// (apps, payments) carry no recall-worthy text and are excluded.
    private static let indexableMessagePredicate = """
        m.associated_message_type = 0
          AND m.item_type = 0
          AND (m.balloon_bundle_id IS NULL
               OR m.balloon_bundle_id = '\(StowerMessageMapper.urlPreviewBalloonBundleID)')
          AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
        """

    private static let referenceSecondsExpression = """
        CASE
          WHEN ABS(m.date) >= \(StowerMessageDate.nanosecondsThreshold)
            THEN CAST(m.date AS REAL) / 1000000000.0
          ELSE CAST(m.date AS REAL)
        END
        """

    /// The chat-identity columns `StowerSourceChatRow` decodes, shared by the
    /// chronology and reaction reads so both group by the same chat key.
    private static let chatColumns = """
        c.ROWID AS chat_row_id,
          c.guid AS chat_guid,
          c.chat_identifier AS chat_identifier,
          c.display_name AS chat_display_name,
          c.style AS chat_style
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
