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

    /// A caller-supplied argument was out of range.
    case invalidArgument(String)

    /// The on-device language model can't serve verdicts; the reason routes the
    /// app to the right onboarding / unsupported screen.
    case languageModelUnavailable(StowerModelUnavailableReason)

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
        case .invalidArgument(let reason):
            return "Invalid argument: \(reason)"
        case .languageModelUnavailable(let reason):
            return Self.unavailableDescription(reason)
        }
    }

    private static func unavailableDescription(_ reason: StowerModelUnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac can't run Apple Intelligence. Stower requires a supported Mac "
                + "on macOS 26 or later."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to use Stower."
        case .modelNotReady:
            return "Apple Intelligence is still downloading — Stower will work once it finishes."
        case .unknown:
            return "On-device language model unavailable."
        }
    }
}
