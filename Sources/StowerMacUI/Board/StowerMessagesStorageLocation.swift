import Foundation
import StowerCore

/// The three places a Debug or Release build's Messages stores can live, composing
/// `StowerEnvironment` (which build) with `StowerMessagesSourceOverride` (whether
/// this Debug run is against demo data) one layer up in `StowerMacUI`.
///
/// Deliberately not a third case on `StowerEnvironment` itself (JC2): Debug/Release
/// is a compile-time build config, demo mode is a runtime toggle driven by
/// `STOWER_MESSAGES_DB` — different categories, different lifecycles, and
/// `StowerCore` (the most depended-upon module) shouldn't couple to a
/// `ProcessInfo`-driven, dev-tooling fact. Closes a real bug: before this type
/// existed, a Debug-against-real-data process and a Debug-against-demo-data
/// process wrote drafts/triage/interaction-events/reply-verdicts into the same
/// `StowerDebug/` folder concurrently.
internal enum StowerMessagesStorageLocation: Sendable {
    /// A Debug build reading the user's real Messages data.
    case debug

    /// A Debug build reading a curated demo database (`STOWER_MESSAGES_DB` set).
    case debugDemo

    /// A Release build.
    case release

    /// Resolves the storage location for a given build environment and override
    /// state.
    ///
    /// Both branches are directly testable via this seam (I5) — unlike
    /// `current` alone, which can't prove the `.release` branch ignores
    /// `overrideIsActive` without it.
    internal static func location(
        for environment: StowerEnvironment,
        overrideIsActive: Bool
    ) -> StowerMessagesStorageLocation {
        switch environment {
        case .release: return .release
        case .debug: return overrideIsActive ? .debugDemo : .debug
        }
    }

    /// The storage location for this process, composing `StowerEnvironment.current`
    /// with `StowerMessagesSourceOverride.isActive`.
    internal static var current: StowerMessagesStorageLocation {
        location(
            for: StowerEnvironment.current,
            overrideIsActive: StowerMessagesSourceOverride.isActive
        )
    }

    /// The Application Support subfolder name for this storage location.
    internal var applicationSupportDirectoryName: String {
        switch self {
        case .debug: return StowerEnvironment.debug.applicationSupportDirectoryName
        case .debugDemo: return "StowerDebugDemo"
        case .release: return StowerEnvironment.release.applicationSupportDirectoryName
        }
    }
}
