import Foundation

/// The analytics facade: one call site for init, one for every event.
///
/// Owns the kill switch (JC6): when consent is off, `initialize` is never
/// called (suppressing the automatic `TelemetryDeck.Session.started` signal,
/// A3) and no signal is forwarded.
///
/// The `makeClient` closure is injectable so tests can verify the kill switch
/// without importing TelemetryDeck: a disabled consent must result in zero
/// calls to `makeClient` AND zero calls to `report`.
///
/// All methods are safe to call from any context (the reporter is `Sendable`).
/// Synchronous throughout — no `await` needed or allowed (Eng F4/F5).
@MainActor
public final class StowerAnalytics {
    /// The singleton built by `initialize` and used by `report`.
    private static var shared: StowerAnalytics?

    private let reporter: any StowerAnalyticsReporting
    private let consent: StowerAnalyticsConsent

    /// The stable TelemetryDeck app identifier (write-only, public/committable).
    ///
    /// This is a collection-only App ID — not a Personal Access Token.
    private static let appID = "56961262-AADB-4F46-A4FE-954E19C6236B"

    /// A stable, app-specific salt for hash stability only.
    ///
    /// Anonymity comes from the random Keychain UUID, NOT the salt (Eng F7).
    /// Once set, this must never change — a changed salt makes every existing
    /// user look like a new user to TelemetryDeck.
    private static let stableSalt = "stower-v0-analytics-salt-2026"

    private init(reporter: any StowerAnalyticsReporting, consent: StowerAnalyticsConsent) {
        self.reporter = reporter
        self.consent = consent
    }

    // MARK: — SDK init (main-actor entry point)

    /// Initializes anonymous analytics behind the privacy kill switch (JC6).
    ///
    /// The production entry point for the app target (`StowerMacApp`). When
    /// consent is off this is a complete no-op — no SDK init, no automatic
    /// `TelemetryDeck.Session.started` (A3/JC6). The injectable form used by
    /// tests is `internal`; this public wrapper supplies the real Keychain-backed
    /// consent and identity so the app never names those internal types.
    @MainActor
    public static func initialize() {
        initialize(consent: StowerAnalyticsConsent(), identity: StowerAnalyticsIdentity())
    }

    /// Initializes the analytics system.
    ///
    /// When consent is disabled this is a complete no-op: `makeClient` is never
    /// called, suppressing the automatic `TelemetryDeck.Session.started` signal
    /// that `initialize` auto-emits (A3/JC6). There is no Swift `stop()` (A4),
    /// so the gate is "never start when disabled."
    ///
    /// - Parameters:
    ///   - consent: The consent accessor (the real Keychain-backed instance in
    ///     production; inject a fake for tests).
    ///   - identity: The install-identity accessor (real Keychain in production;
    ///     inject a fake for tests).
    ///   - makeClient: Injectable SDK-init closure. Receives `(appID, salt,
    ///     userID)`. The default calls `StowerTelemetryDeckReporter.initializeSDK`
    ///     and `setDefaultUser` so this file never needs to import TelemetryDeck
    ///     (precheck 6k). Tests inject a spy closure; never calls TelemetryDeck.
    @MainActor
    internal static func initialize(
        consent: StowerAnalyticsConsent,
        identity: StowerAnalyticsIdentity,
        makeClient: (String, String, String) -> Void = { appID, salt, userID in
            StowerTelemetryDeckReporter.initializeSDK(appID: appID, salt: salt)
            StowerTelemetryDeckReporter.setDefaultUser(userID)
        }
    ) {
        guard consent.isEnabled else {
            // Kill switch: build a no-op reporter; never call makeClient.
            let noOp = StowerAnalytics(reporter: StowerNoOpAnalyticsReporter(), consent: consent)
            Self.shared = noOp
            return
        }

        // TelemetryDeck double-hashes the userID (UUID → SHA-256 with the salt →
        // its own hash on the wire) so the raw UUID never leaves the device.
        makeClient(appID, stableSalt, identity.clientUser())

        let live = StowerAnalytics(
            reporter: StowerTelemetryDeckReporter(consent: consent),
            consent: consent
        )
        Self.shared = live
    }

    // MARK: — Event reporting

    /// Emits one analytics event through the configured reporter.
    ///
    /// A no-op when `initialize` has not yet been called or analytics is off.
    internal static func report(_ event: StowerAnalyticsEvent) {
        shared?.reporter.report(event)
    }

    /// Reports that the app finished launching (per-launch).
    ///
    /// A no-op when off. Public lifecycle entry point for the app target. The
    /// full event taxonomy (`StowerAnalyticsEvent`) stays internal — only the two
    /// app-emitted lifecycle events are exposed, so no internal associated-value
    /// types leak.
    public static func reportAppLaunched() {
        report(.appLaunched)
    }

    /// Reports that the user quit the app (per-launch).
    ///
    /// A no-op when off.
    public static func reportSessionEnded() {
        report(.sessionEnded)
    }

    // MARK: — Consent management

    /// Whether analytics collection is currently enabled.
    internal static func isEnabled() -> Bool {
        shared?.consent.isEnabled ?? false
    }

    /// Enables or disables analytics and updates the local Keychain cache.
    ///
    /// The caller (the Settings toggle) is responsible for pushing the change
    /// to the license record (`diagnostics_opt_out`) via the licensing workstream.
    internal static func setEnabled(_ enabled: Bool) {
        guard let current = shared else { return }
        current.consent.setEnabled(enabled)
        if !enabled {
            // Fail closed in memory: stop this session's facade emissions
            // immediately, even if the Keychain cache write failed. Durable off
            // is backstopped by the license record's `diagnostics_opt_out`,
            // reconciled on the next check-in (JC8).
            Self.shared = StowerAnalytics(
                reporter: StowerNoOpAnalyticsReporter(),
                consent: current.consent
            )
        }
    }

    /// Reconciles the local Keychain cache against the license record's opt-out
    /// flag on each license check-in.
    ///
    /// "Off wins" — this never auto-re-enables. Call this after a successful
    /// license check-in when `diagnostics_opt_out` is returned.
    ///
    /// - Parameter licenseOptOut: `true` when the license record carries
    ///   `diagnostics_opt_out = true`.
    internal static func reconcileLicenseConsent(licenseOptOut: Bool) {
        shared?.consent.reconcile(licenseOptOut: licenseOptOut)
    }
}
