import Foundation

/// One structural report section: a header plus the SQL that produces it.
///
/// Ported verbatim from `Scripts/inspect-chatdb-shapes.sh`'s `SECTION_*`/
/// `SQL_*` constants (JC6) — same five queries, same allowlisted structural
/// columns (counts, `balloon_bundle_id`, derived prefix heads, NULL-ness
/// booleans) and never a message body, `attributedBody`, handle, or full
/// GUID value.
internal struct StowerChatDBInspectorSection {
    internal let header: String
    internal let sql: String
}

internal enum StowerChatDBInspectorSections {
    internal static let bundleHistogram = StowerChatDBInspectorSection(
        header: "Section 1 — balloon_bundle_id histogram  "
            + "(Maps link: URLBalloonProvider vs app balloon)",
        sql: """
            SELECT '  ' || COALESCE(balloon_bundle_id, '(null)') || ' = ' || count(*)
            FROM message
            GROUP BY balloon_bundle_id
            ORDER BY count(*) DESC;
            """
    )

    internal static let reactionTypeHistogram = StowerChatDBInspectorSection(
        header: "Section 2 — reaction associated_message_type histogram",
        sql: """
            SELECT '  type ' || associated_message_type
              || CASE
                   WHEN associated_message_type BETWEEN 2000 AND 2999 THEN ' (added)'
                   WHEN associated_message_type BETWEEN 3000 AND 3999 THEN ' (removed)'
                   ELSE ''
                 END
              || ' = ' || count(*)
            FROM message
            WHERE associated_message_type >= 2000 AND associated_message_type < 4000
            GROUP BY associated_message_type
            ORDER BY associated_message_type;
            """
    )

    internal static let prefixShapeHistogram = StowerChatDBInspectorSection(
        header: "Section 3 — associated_message_guid prefix-shape histogram",
        sql: """
            SELECT '  ' || shape || ' = ' || n
            FROM (
              SELECT
                CASE
                  WHEN associated_message_guid IS NULL THEN '(null)'
                  WHEN instr(associated_message_guid, ':') = 0
                       AND instr(associated_message_guid, '/') = 0 THEN '(bare)'
                  ELSE substr(
                         associated_message_guid, 1,
                         CASE
                           WHEN instr(associated_message_guid, ':') = 0
                             THEN instr(associated_message_guid, '/')
                           WHEN instr(associated_message_guid, '/') = 0
                             THEN instr(associated_message_guid, ':')
                           ELSE min(instr(associated_message_guid, ':'),
                                    instr(associated_message_guid, '/'))
                         END
                       ) || '<redacted>'
                END AS shape,
                count(*) AS n
              FROM message
              WHERE associated_message_type >= 2000 AND associated_message_type < 4000
              GROUP BY shape
            )
            ORDER BY n DESC;
            """
    )

    internal static let matchCounts = StowerChatDBInspectorSection(
        header: "Section 4 — reaction target match: bare vs prefix-strip  "
            + "(does normalizeAssociatedGUID need to strip?)",
        sql: """
            WITH reac AS (
              SELECT
                associated_message_guid AS g,
                CASE
                  WHEN instr(associated_message_guid, '/') > 0
                    THEN substr(associated_message_guid, instr(associated_message_guid, '/') + 1)
                  WHEN instr(associated_message_guid, ':') > 0
                    THEN substr(associated_message_guid, instr(associated_message_guid, ':') + 1)
                  ELSE associated_message_guid
                END AS tail
              FROM message
              WHERE associated_message_type >= 2000 AND associated_message_type < 4000
                AND associated_message_guid IS NOT NULL
            )
            SELECT
              '  reaction rows (non-null target): '
                || (SELECT count(*) FROM reac) || char(10) ||
              '  match bare (target equals message guid as-is): '
                || (SELECT count(*) FROM reac
                    WHERE EXISTS (SELECT 1 FROM message t WHERE t.guid = reac.g)) || char(10) ||
              '  match ONLY after prefix-strip: '
                || (SELECT count(*) FROM reac
                    WHERE g <> tail
                      AND EXISTS (SELECT 1 FROM message t WHERE t.guid = reac.tail)
                      AND NOT EXISTS (SELECT 1 FROM message t WHERE t.guid = reac.g)) || char(10) ||
              '  no match either way: '
                || (SELECT count(*) FROM reac
                    WHERE NOT EXISTS (SELECT 1 FROM message t WHERE t.guid = reac.g)
                      AND NOT EXISTS (SELECT 1 FROM message t WHERE t.guid = reac.tail));
            """
    )

    internal static let attachmentOnly = StowerChatDBInspectorSection(
        header: "Section 5 — attachment-only / body-empty row count",
        sql: """
            SELECT '  attachment-only / body-empty rows: ' || count(*)
            FROM message
            WHERE cache_has_attachments = 1
              AND text IS NULL
              AND attributedBody IS NULL;
            """
    )

    /// All five sections, in report order.
    internal static let all: [StowerChatDBInspectorSection] = [
        bundleHistogram,
        reactionTypeHistogram,
        prefixShapeHistogram,
        matchCounts,
        attachmentOnly
    ]
}
