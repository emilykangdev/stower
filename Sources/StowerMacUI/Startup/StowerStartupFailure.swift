import Foundation

/// The app-owned typed failure the startup boundary surfaces and the model routes
/// on.
///
/// The adapter maps every engine `StowerMessagesError` onto exactly one case; a
/// throw that is not a `StowerMessagesError` becomes `.unexpected` via the startup
/// model's catch-all. The views derive their copy from the case — raw engine
/// strings are never shown, which is why every engine diagnostic payload is
/// dropped except the messages-access `detail` and the model `reason` a screen
/// actually renders.
internal enum StowerStartupFailure: Error, Sendable, Equatable {
    // ENGINE-COUPLED: four files import the engine (StowerMessagesStartupAdapter, StowerLiveBoardDataSource, StowerMessagesComposition, StowerMessagesMapping); the engine→failure map is StowerMessagesMapping.mapError, and this app-owned failure is reused as the board seam's error type.

    /// Messages access is missing; `detail` is the diagnostic string the
    /// still-missing screen discloses behind its Technical-details disclosure.
    case messagesAccessMissing(detail: String)

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
