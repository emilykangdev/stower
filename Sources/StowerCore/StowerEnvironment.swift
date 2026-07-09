import Foundation

/// The single source of truth for "is this a Debug or Release build".
///
/// Replaces five independent, previously-drifting detections of the same fact:
/// the 4 Application-Support stores' copy-pasted `"Stower"` literal, and
/// `StowerLicenseConfig`/`StowerFeedbackConfig`'s own `#if DEBUG` blocks.
public enum StowerEnvironment: Sendable {
    /// A Debug build (Xcode's `Debug` configuration).
    case debug

    /// A Release build (Xcode's `Release` configuration).
    case release

    /// The compiled default for this build (precheck 6j guarantees DEBUG is
    /// never defined in a Release build configuration).
    public static let current: StowerEnvironment = {
        #if DEBUG
            return .debug
        #else
            return .release
        #endif
    }()

    /// The Application Support subfolder name for this variant.
    public var applicationSupportDirectoryName: String {
        switch self {
        case .debug: return "StowerDebug"
        case .release: return "Stower"
        }
    }
}
