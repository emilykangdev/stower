import Foundation
import TelemetryDeck

/// The ONLY file in Stower that imports TelemetryDeck (enforced by precheck 6k).
///
/// Routes typed `StowerAnalyticsEvent` values to `TelemetryDeck.signal` after
/// checking the kill switch. The facade (`StowerAnalytics`) gates `initialize`
/// and holds the consent reference; this reporter gates every individual signal
/// for defence-in-depth.
internal struct StowerTelemetryDeckReporter: StowerAnalyticsReporting {
    private let consent: StowerDiagnosticsConsent

    internal init(consent: StowerDiagnosticsConsent) {
        self.consent = consent
    }

    internal func report(_ event: StowerAnalyticsEvent) {
        guard consent.isEnabled else { return }
        TelemetryDeck.signal(event.signalName, parameters: event.parameters)
    }

    // MARK: — SDK lifecycle (called only from StowerAnalytics facade)

    /// Initializes the TelemetryDeck SDK.
    ///
    /// Called by the `StowerAnalytics` facade so that file does not need to
    /// import TelemetryDeck itself (precheck 6k — exactly one importer).
    ///
    /// - Parameters:
    ///   - appID: The TelemetryDeck app identifier.
    ///   - salt: A stable app-specific salt for hash stability.
    internal static func initializeSDK(appID: String, salt: String) {
        let config = TelemetryDeck.Config(appID: appID, salt: salt)
        TelemetryDeck.initialize(config: config)
    }

    /// Sets the default hashed user identifier on the TelemetryDeck SDK.
    ///
    /// Called by the `StowerAnalytics` facade after `initializeSDK`.
    internal static func setDefaultUser(_ userID: String) {
        TelemetryDeck.updateDefaultUserID(to: userID)
    }
}
