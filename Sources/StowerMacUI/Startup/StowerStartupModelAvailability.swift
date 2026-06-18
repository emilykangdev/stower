import Foundation

/// Why the on-device language model can't serve verdicts, in app-owned terms.
///
/// A 1:1 copy of the engine's `StowerModelUnavailableReason`, kept under a
/// distinct name so the SwiftUI views can route on it without importing the
/// engine. The adapter translates the engine reason into this; each reason's
/// screen treatment is the four-reasons table in the FDA-onboarding plan.
internal enum StowerStartupModelUnavailableReason: Sendable, Equatable {
    /// The Mac can't run Apple Intelligence — terminal; no retry.
    case deviceNotEligible

    /// Apple Intelligence is off in Settings — deep-link to turn it on.
    case appleIntelligenceNotEnabled

    /// The model is still downloading or preparing — transient; offer Check Again.
    case modelNotReady

    /// The reason could not be classified — generic unavailable + retry/support.
    case unknown
}

/// Whether the on-device language model can serve verdicts, in app-owned terms.
///
/// A distinctly-named copy of the engine's `StowerModelAvailability` so the views
/// route on it directly; the adapter maps the engine value into this.
internal enum StowerStartupModelAvailability: Sendable, Equatable {
    /// The model is ready; startup proceeds to the board load.
    case available

    /// The model can't judge; the reason routes to a `StowerModelUnavailableView`.
    case unavailable(StowerStartupModelUnavailableReason)
}
