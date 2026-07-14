import Foundation
import StowerMacUI
import StowerMessages

/// Errors the inspector's run can surface, beyond the picker's own errors.
internal enum StowerChatDBInspectorError: Error, LocalizedError {
    case cancelled
    case accessDenied
    case redactionGuardTripped
    case sqliteUnavailable

    internal var errorDescription: String? {
        switch self {
        case .cancelled:
            return "no Messages folder selected — cancelled"
        case .accessDenied:
            return "could not access the granted Messages folder — the bookmark "
                + "resolved but security-scoped access failed"
        case .redactionGuardTripped:
            return "redaction guard tripped — content-shaped data detected in the report. "
                + "Output withheld; nothing was printed. Investigate the queries before "
                + "re-running."
        case .sqliteUnavailable:
            return "/usr/bin/sqlite3 not found — required to query the copied database"
        }
    }
}

/// Orchestrates one report run: picker → bookmark → copy+checkpoint → the
/// five SQL sections → the redaction guard → print.
internal enum StowerChatDBInspectorRunner {
    @MainActor
    internal static func run() throws {
        guard let bookmark = try StowerMessagesAccessPicker.presentAndCreateBookmark() else {
            throw StowerChatDBInspectorError.cancelled
        }

        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard resolvedURL.startAccessingSecurityScopedResource() else {
            throw StowerChatDBInspectorError.accessDenied
        }
        defer { resolvedURL.stopAccessingSecurityScopedResource() }

        let sourceDatabaseURL = resolvedURL.appendingPathComponent(
            StowerChatDatabaseReader.databaseFileName
        )
        let workingCopy = try StowerChatDBInspectorCopy.makeCheckpointedCopy(
            of: sourceDatabaseURL
        )
        defer { workingCopy.remove() }

        let report = try buildReport(databasePath: workingCopy.databaseURL.path)
        guard !StowerChatDBInspectorRedactionGuard.reportHasContent(report) else {
            throw StowerChatDBInspectorError.redactionGuardTripped
        }
        print(report)
    }

    internal static func reportUnknownArgument(_ argument: String) {
        FileHandle.standardError.write(
            Data(
                """
                ERROR: unknown argument: \(argument)
                Try --help, --self-test, or no argument.

                """.utf8
            )
        )
    }

    private static func buildReport(databasePath: String) throws -> String {
        var lines = [
            "chat.db shape inspector — redacted structural report",
            "(no message text, handles, chat ids, or full GUIDs are ever shown)",
            ""
        ]
        for section in StowerChatDBInspectorSections.all {
            let result = try StowerChatDBInspectorSQLite.query(
                databasePath: databasePath,
                sql: section.sql
            )
            lines.append(section.header)
            lines.append(result.isEmpty ? "  (none)" : result)
            lines.append("")
        }
        lines.append(
            """
            Reading: Section 4 — if "match ONLY after prefix-strip" dominates,
            normalizeAssociatedGUID MUST strip the prefix; if "match bare"
            dominates, the bare comparison is already correct.
            """
        )
        return lines.joined(separator: "\n")
    }
}
