import Foundation

/// Why the on-device language model can't serve verdicts right now.
///
/// Mirrors Apple's `SystemLanguageModel.Availability.UnavailableReason` so the
/// app can route each state to the right screen instead of one flat
/// "unsupported": a terminal device-ineligibility, a fixable disabled toggle, a
/// transient download, or an unknown reason it should treat conservatively.
public enum StowerModelUnavailableReason: Sendable, Equatable {
    /// The Mac or hardware can't run Apple Intelligence — terminal.
    case deviceNotEligible

    /// The device is capable but Apple Intelligence is off in Settings — fixable.
    case appleIntelligenceNotEnabled

    /// The model is downloading or preparing — transient.
    case modelNotReady

    /// The reason could not be classified.
    case unknown
}

/// Whether the on-device language model can serve verdicts right now.
///
/// The app reads this at startup via `StowerDebtBoardProviding.modelAvailability()`
/// to route to the board, an onboarding screen, or an unsupported screen before
/// any board work begins — never a bare `Bool`, which would mislabel a fixable or
/// transient state as a terminal "unsupported".
public enum StowerModelAvailability: Sendable, Equatable {
    /// The model is ready to judge.
    case available

    /// The model can't judge; the reason tells the app where to route.
    case unavailable(StowerModelUnavailableReason)
}
