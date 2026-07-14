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
        // Drain both pipes CONCURRENTLY with the process running, never after
        // `waitUntilExit()`: a report section large enough to fill a pipe's
        // buffer would make `sqlite3` block on write() while this thread sits
        // blocked in `waitUntilExit()` — a permanent, timeout-less deadlock
        // (CodeRabbit finding).
        let group = DispatchGroup()
        let outputBox = StowerPipeDrainBox()
        let errorBox = StowerPipeDrainBox()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.data = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorBox.data, encoding: .utf8) ?? "sqlite3 failed"
            throw StowerChatDBInspectorSQLiteError.nonZeroExit(message)
        }
        return String(data: outputBox.data, encoding: .utf8)?
            .trimmingCharacters(in: .newlines) ?? ""
    }
}

/// Hands one pipe's drained `Data` from its background drain task back to the
/// caller after `DispatchGroup.wait()`.
///
/// `@unchecked Sendable`: safe because the group's `enter`/`leave`/`wait`
/// establish a happens-before edge — the drain task's single write to `data`
/// always completes before `wait()` returns and the caller reads it.
private final class StowerPipeDrainBox: @unchecked Sendable {
    var data = Data()
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
