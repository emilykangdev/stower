import Foundation

/// The app-owned typed failure the startup boundary surfaces and the model routes
/// on.
///
/// The adapter maps every engine `StowerMessagesError` onto exactly one case; a
/// throw that is not a `StowerMessagesError` becomes `.unexpected` via the startup
/// model's catch-all. The views derive their copy from the case — raw engine
/// strings are never shown, which is why every engine diagnostic payload is
/// dropped except the FDA `path` and the model `reason` a screen actually renders.
internal enum StowerStartupFailure: Error, Sendable, Equatable {
    // FROZEN-ADAPTER: StowerMessagesStartupAdapter is the only engine-coupled file; engine→failure map in "Why the UI boundary is durable" item 2.

    /// Full Disk Access is missing; `path` is the database path the FDA screen
    /// discloses behind its Technical-details disclosure.
    case fullDiskAccessMissing(path: String)

    /// The on-device model is unavailable; the reason selects the screen variant.
    case modelUnavailable(StowerStartupModelUnavailableReason)

    /// A caller-supplied config was out of range — an app/developer bug.
    case invalidConfig

    /// Messages isn't set up on this Mac.
    case sourceMissing

    /// The Messages data couldn't be read.
    case unreadable

    /// The Messages data was malformed.
    case invalidData

    /// An unrecognized, non-engine failure.
    case unexpected
}
