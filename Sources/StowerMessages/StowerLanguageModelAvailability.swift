import Foundation
import FoundationModels

/// Runtime gate for Apple's on-device system language model.
///
/// Availability is two-layered: `@available(macOS 26, iOS 26, *)` gates the
/// symbols at compile time (FoundationModels ships on both, and the package
/// declares an iOS floor for the photos app, so iOS must be gated too), but on a
/// capable machine the model can still be `.unavailable(.appleIntelligenceNotEnabled)`
/// (or downloading, or the device is ineligible). Both layers must pass before
/// the provider routes to the FoundationModels judge; anything else degrades to
/// the heuristic.
internal enum StowerLanguageModelAvailability {
    /// Whether the system language model can serve requests right now.
    internal static func isAvailable() -> Bool {
        if #available(macOS 26, iOS 26, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        return false
    }
}
