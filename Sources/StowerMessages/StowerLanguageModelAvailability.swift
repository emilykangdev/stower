import Foundation
import FoundationModels

/// Runtime gate for Apple's on-device system language model.
///
/// Availability is two-layered: an inline `#available(macOS 26, iOS 26, *)` gates
/// the symbols at compile time (FoundationModels ships on both, and the package
/// declares an iOS floor for the photos app, so iOS must be gated too), and on a
/// capable machine the model can still be unavailable (disabled, downloading, or
/// the device is ineligible). Resolves both layers into the typed
/// `StowerModelAvailability` the provider hands the app — never a bare `Bool`,
/// which would mislabel a fixable or transient state as a terminal "unsupported".
internal enum StowerLanguageModelAvailability {
    /// Resolves the current typed availability of the system language model.
    internal static func current() -> StowerModelAvailability {
        guard #available(macOS 26, iOS 26, *) else {
            // No macOS 26 / iOS 26 symbols ⇒ the device can't run the model.
            return .unavailable(.deviceNotEligible)
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(Self.reason(from: reason))
        }
    }

    @available(macOS 26, iOS 26, *)
    private static func reason(
        from reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> StowerModelUnavailableReason {
        switch reason {
        case .deviceNotEligible:
            return .deviceNotEligible
        case .appleIntelligenceNotEnabled:
            return .appleIntelligenceNotEnabled
        case .modelNotReady:
            return .modelNotReady
        @unknown default:
            return .unknown
        }
    }
}
