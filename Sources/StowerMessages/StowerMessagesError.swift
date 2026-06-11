import Foundation

/// Errors produced while reading the local Messages database.
public enum StowerMessagesError: Error, LocalizedError, Sendable {
    /// The configured Source DB does not exist.
    case sourceNotFound(String)

    /// macOS denied access to the Messages data directory.
    case fullDiskAccessMissing(String)

    /// The Source DB could not be copied or opened.
    case unreadableSource(String)

    /// A copied Source DB failed SQLite validation.
    case invalidSnapshot

    /// A Source DB row contained an invalid value.
    case invalidRow(String)

    /// A user-facing description of the failure.
    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let path):
            return "Messages database not found at \(path)."
        case .fullDiskAccessMissing:
            return "Full Disk Access is required to read Messages."
        case .unreadableSource(let reason):
            return "Unable to read Messages: \(reason)"
        case .invalidSnapshot:
            return "The copied Messages database failed validation."
        case .invalidRow(let reason):
            return "Messages contains an invalid row: \(reason)"
        }
    }
}
