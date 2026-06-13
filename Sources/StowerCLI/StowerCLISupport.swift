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

/// Reports the upgraded Full Disk Access remedy: which app, which path, restart.
internal func stowerReportFullDiskAccess(path: String) {
    stowerStandardError(
        """
        Full Disk Access is required to read \(path).
        Grant it to your terminal app in System Settings → Privacy & Security → Full Disk Access,
        then fully quit and reopen the terminal (a restart of the app is required to take effect).
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

/// Formats one ranked result as a compact, single-line row.
internal func stowerFormatResult(_ rank: Int, _ item: StowerRetrievedItem) -> String {
    let body = item.snippet ?? String(item.item.text.prefix(80))
    let oneLine = body.replacingOccurrences(of: "\n", with: " ")
    return "  \(rank). [\(item.item.groupTitle)] \(oneLine)  (\(stowerProvenance(item)))"
}

/// Refuses a path that lives inside a git repo but is not gitignored.
///
/// Personal queries and any `--out` transcript must never be writable into the
/// tree; a filename convention alone cannot enforce that.
internal func stowerEnsureGitIgnored(_ path: String) throws {
    let expanded = (path as NSString).expandingTildeInPath
    let absolute = URL(fileURLWithPath: expanded).standardizedFileURL.path
    let directory = URL(fileURLWithPath: absolute).deletingLastPathComponent().path
    let status = stowerRunGit(["-C", directory, "check-ignore", "-q", absolute])
    switch status {
    case 0, 128:  // ignored, or not inside a git repo
        return
    default:
        throw StowerCLIError.pathNotGitIgnored(absolute)
    }
}

private func stowerRunGit(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return 128
    }
}

/// Errors surfaced directly by the CLI.
internal enum StowerCLIError: Error, LocalizedError {
    case emptyIndex(path: String)
    case pathNotGitIgnored(String)
    case queryFileUnreadable(path: String)
    case noEmbeddingsForGate

    internal var errorDescription: String? {
        switch self {
        case .emptyIndex(let path):
            return "No indexed items at \(path) — run `stower index` first."
        case .pathNotGitIgnored(let path):
            return "Refusing to use \(path): it is inside a git repo but not gitignored."
        case .queryFileUnreadable(let path):
            return "Query file not found or empty at \(path)."
        case .noEmbeddingsForGate:
            return """
                The index has zero embeddings, so eval would silently test FTS-only. \
                Run `stower index` with a model, or pass --allow-fts-only to accept that.
                """
        }
    }
}
