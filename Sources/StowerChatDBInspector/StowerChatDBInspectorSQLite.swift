import Foundation

/// Shells out to the system `sqlite3` CLI against the private working copy only.
///
/// Mirrors the deleted `Scripts/inspect-chatdb-shapes.sh`'s `run_sql()` exactly
/// (same tool, same read-only + immutable posture), just orchestrated from
/// Swift instead of bash.
internal enum StowerChatDBInspectorSQLite {
    private static let executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")

    /// Runs a read-only query against `databasePath`, preferring the
    /// immutable URI form (skips WAL/shared-memory setup, since the copy's
    /// WAL was already folded in by the checkpoint step) and falling back to
    /// plain `-readonly` if this `sqlite3` build lacks URI filenames.
    internal static func query(databasePath: String, sql: String) throws -> String {
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw StowerChatDBInspectorError.sqliteUnavailable
        }
        let uriPath = "file:\(databasePath)?immutable=1"
        if let output = try? run(arguments: ["-readonly", uriPath, sql]) {
            return output
        }
        return try run(arguments: ["-readonly", databasePath, sql])
    }

    /// Runs a statement against `databasePath` with normal (writable) access —
    /// used only for the checkpoint's `PRAGMA journal_mode=DELETE` on the
    /// PRIVATE COPY, never the live source.
    @discardableResult
    internal static func execute(databasePath: String, sql: String) throws -> String {
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw StowerChatDBInspectorError.sqliteUnavailable
        }
        return try run(arguments: [databasePath, sql])
    }

    private static func run(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "sqlite3 failed"
            throw StowerChatDBInspectorSQLiteError.nonZeroExit(message)
        }
        return String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .newlines) ?? ""
    }
}

/// A `sqlite3` CLI invocation failure.
private enum StowerChatDBInspectorSQLiteError: Error, LocalizedError {
    case nonZeroExit(String)

    fileprivate var errorDescription: String? {
        switch self {
        case .nonZeroExit(let message):
            return "sqlite3 exited non-zero: \(message)"
        }
    }
}
