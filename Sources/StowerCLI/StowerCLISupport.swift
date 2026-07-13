import Contacts
import CryptoKit
import Foundation
import StowerCore

/// Resolved on-disk locations for one CLI invocation.
internal struct StowerLocations {
    internal let indexDirectory: URL
    internal let modelPath: URL

    internal var indexPath: String {
        indexDirectory.appendingPathComponent("index.sqlite").path
    }

    internal var storePath: String {
        indexDirectory.appendingPathComponent(StowerEmbeddingStore.fileName).path
    }
}

/// The user-level base directory shared across Conductor worktrees.
internal func stowerAppSupportDirectory() -> URL {
    let base =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support"
        )
    return base.appendingPathComponent("Stower", isDirectory: true)
}

/// Resolves the index/model locations and echoes them so stale paths are obvious.
internal func stowerResolveLocations(
    indexDirectory: String?,
    modelPath: String?
) -> StowerLocations {
    let appSupport = stowerAppSupportDirectory()
    let index =
        indexDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? appSupport.appendingPathComponent("Index", isDirectory: true)
    let model =
        modelPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? appSupport.appendingPathComponent("Models/default", isDirectory: true)
    let locations = StowerLocations(indexDirectory: index, modelPath: model)
    print("index-dir: \(locations.indexDirectory.path)")
    print("model-path: \(locations.modelPath.path)")
    print("build: \(stowerBuildConfiguration())")
    return locations
}

/// The build configuration, so debug-build timings never masquerade as the verdict.
internal func stowerBuildConfiguration() -> String {
    #if DEBUG
        return "debug"
    #else
        return "release"
    #endif
}

/// A stable content hash used as the embedding cache key for an item's text.
internal func stowerTextHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Resolves the embedder, returning a stub for FTS-only runs without a model.
internal func stowerResolveEmbedder(modelPath: URL, requireModel: Bool) throws -> StowerEmbedder {
    do {
        return try StowerCoreMLEmbedder(modelDirectory: modelPath)
    } catch {
        if requireModel { throw error }
        return StowerUnavailableEmbedder()
    }
}

/// A non-embedding stand-in for `search --arm fts`, never invoked on that path.
internal struct StowerUnavailableEmbedder: StowerEmbedder {
    internal let modelFingerprint = "unavailable"

    internal func embed(texts: [String]) async throws -> [StowerEmbedOutcome] {
        throw StowerEmbedderError.modelUnavailable
    }

    internal func embedQuery(_ text: String) async throws -> [Float] {
        throw StowerEmbedderError.modelUnavailable
    }
}

/// Prints a Contacts warning when names will silently degrade to raw handles.
internal func stowerWarnIfContactsDenied() {
    guard CNContactStore.authorizationStatus(for: .contacts) != .authorized else { return }
    stowerStandardError(
        """
        warning: Contacts access is not granted — sender names will show as raw handles. \
        Grant it in System Settings → Privacy & Security → Contacts.
        """
    )
}

/// Reports a missing/rejected Messages-access grant: what happened, what to do next.
internal func stowerReportMessagesAccessMissing(detail: String) {
    stowerStandardError(
        """
        Stower needs access to your Messages folder: \(detail).
        Run this command again and, in the dialog that opens, select the Messages folder
        and click Open.
        """
    )
}

/// Writes a line to standard error.
internal func stowerStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// A one-line, copy-pasteable description of a result's per-arm provenance.
internal func stowerProvenance(_ item: StowerRetrievedItem) -> String {
    var parts: [String] = []
    if let ftsRank = item.ftsRank { parts.append("fts#\(ftsRank)") }
    if let semanticRank = item.semanticRank { parts.append("sem#\(semanticRank)") }
    parts.append(String(format: "rrf=%.4f", item.fusedScore))
    return parts.joined(separator: " ")
}

/// Strips control and escape characters from untrusted message text before it
/// is printed, so a message body or contact name cannot inject terminal escape
/// sequences (cursor moves, OSC clipboard/title writes) into the user's shell.
internal func stowerSanitizedForTerminal(_ text: String) -> String {
    let scalars = text.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
        if scalar == "\n" || scalar == "\t" { return Unicode.Scalar(UInt8(0x20)) }
        if scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F) { return nil }
        return scalar
    }
    return String(String.UnicodeScalarView(scalars))
}

/// Formats one ranked result as a compact, single-line row.
internal func stowerFormatResult(_ rank: Int, _ item: StowerRetrievedItem) -> String {
    let body = stowerSanitizedForTerminal(item.snippet ?? String(item.item.text.prefix(80)))
    let title = stowerSanitizedForTerminal(item.item.groupTitle)
    return "  \(rank). [\(title)] \(body)  (\(stowerProvenance(item)))"
}

/// Refuses a path that lives inside a git repo but is not gitignored.
///
/// Personal queries and any `--out` transcript must never be writable into the
/// tree; a filename convention alone cannot enforce that.
internal func stowerEnsureGitIgnored(_ path: String) throws {
    let expanded = (path as NSString).expandingTildeInPath
    let absolute = URL(fileURLWithPath: expanded).standardizedFileURL.path
    // Anchor git at the nearest EXISTING ancestor: the target itself (and its
    // parent) may not exist yet, and `git -C <missing>` fails with 128, which we
    // must not mistake for "not in a repo".
    let anchor = stowerNearestExistingDirectory(of: absolute)
    let insideRepo = stowerRunGit(["-C", anchor, "rev-parse", "--is-inside-work-tree"])
    switch insideRepo {
    case .exit(128):
        return  // genuinely not inside any git repo — nothing to leak into
    case .exit(0):
        break  // inside a repo — the path must be ignored
    default:
        // git could not be run, or some other error: we cannot verify safety.
        throw StowerCLIError.pathNotGitIgnored(absolute)
    }
    if case .exit(0) = stowerRunGit(["-C", anchor, "check-ignore", "-q", absolute]) {
        return  // ignored — safe to write here
    }
    throw StowerCLIError.pathNotGitIgnored(absolute)
}

/// Walks up from `path` to the first directory that actually exists.
private func stowerNearestExistingDirectory(of path: String) -> String {
    var url = URL(fileURLWithPath: path).deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    while url.path != "/" {
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            return url.path
        }
        url = url.deletingLastPathComponent()
    }
    return "/"
}

/// The outcome of running git: a real exit status, or a failure to launch it.
private enum StowerGitResult: Equatable {
    case exit(Int32)
    case couldNotRun
}

private func stowerRunGit(_ arguments: [String]) -> StowerGitResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return .exit(process.terminationStatus)
    } catch {
        return .couldNotRun
    }
}

/// Errors surfaced directly by the CLI.
internal enum StowerCLIError: Error, LocalizedError {
    case emptyIndex(path: String)
    case pathNotGitIgnored(String)
    case queryFileUnreadable(path: String, reason: String)
    case emptyQueryFile(path: String)
    case malformedQueryLine(path: String, number: Int, reason: String)
    case incompleteGateSuite(found: Int, required: Int)
    case incompleteCoverage(items: Int, processed: Int)
    case noEmbeddingsForGate

    internal var errorDescription: String? {
        switch self {
        case .emptyIndex(let path):
            return "No indexed items at \(path) — run `stower index` first."
        case .pathNotGitIgnored(let path):
            return "Refusing to use \(path): it is inside a git repo but not gitignored."
        case .queryFileUnreadable(let path, let reason):
            return "Query file at \(path) could not be read: \(reason)"
        case .emptyQueryFile(let path):
            return "Query file at \(path) has no usable query lines."
        case .malformedQueryLine(let path, let number, let reason):
            return "Malformed query at \(path):\(number) — \(reason)"
        case .incompleteGateSuite(let found, let required):
            return "Gate needs the full \(required)-query suite; found only \(found)."
        case .incompleteCoverage(let items, let processed):
            return
                "Index/embeddings out of sync (\(processed)/\(items) processed) — "
                + "re-run `stower index`, or pass --allow-fts-only."
        case .noEmbeddingsForGate:
            return """
                The index has zero embeddings, so eval would silently test FTS-only. \
                Run `stower index` with a model, or pass --allow-fts-only to accept that.
                """
        }
    }
}
