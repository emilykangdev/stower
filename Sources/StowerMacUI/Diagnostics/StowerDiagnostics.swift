import Foundation

/// The diagnostics umbrella facade: the single launch entry point for all
/// diagnostics backends (crash reporting + analytics).
///
/// `initialize()` is the ONLY call the app target makes to start both backends.
/// It reads consent once, and when enabled starts them in the required order
/// (JC3): Sentry crash reporting FIRST (earliest crash coverage), then
/// TelemetryDeck analytics. When disabled, neither backend starts.
///
/// This facade also exposes consent passthrough — `isEnabled()`, `setEnabled`,
/// and `reconcileLicenseConsent` — so the app target and UI never need to name
/// the internal `StowerDiagnosticsConsent` type or the analytics backend
/// directly.
///
/// `StowerAnalytics.report(_:)` is the entry point for analytics events (it
/// stays on `StowerAnalytics`; this facade does not duplicate it).
@MainActor
public enum StowerDiagnostics {

    // MARK: — Initialization

    /// Initializes all diagnostics backends behind the shared consent gate.
    ///
    /// The production entry point for `StowerMacApp.init()`. When consent is
    /// off this is a complete no-op — no SDK init, no crash handler, no
    /// automatic `TelemetryDeck.Session.started` (A3/JC3/JC6).
    ///
    /// The injectable form used by tests is `internal`; this public wrapper
    /// supplies real Keychain-backed instances so the app target never names
    /// those internal types.
    @MainActor
    public static func initialize() {
        initialize(
            consent: StowerDiagnosticsConsent(),
            identity: StowerDiagnosticsIdentity()
        )
    }

    /// Initializes all diagnostics backends.
    ///
    /// - Parameters:
    ///   - consent: Shared consent accessor (real Keychain-backed in production;
    ///     inject a fake for tests).
    ///   - identity: Shared install-identity accessor (real Keychain in
    ///     production; inject a fake for tests).
    ///   - makeAnalyticsClient: Injectable TelemetryDeck init closure for tests.
    ///     Tests inject a spy to verify zero calls when consent is off.
    @MainActor
    internal static func initialize(
        consent: StowerDiagnosticsConsent,
        identity: StowerDiagnosticsIdentity,
        makeAnalyticsClient: (String, String, String) -> Void = { appID, salt, userID in
            StowerTelemetryDeckReporter.initializeSDK(appID: appID, salt: salt)
            StowerTelemetryDeckReporter.setDefaultUser(userID)
        }
    ) {
        guard consent.isEnabled else {
            // One gate: both backends stay off. Build a no-op analytics shared
            // instance so report(_:) calls are safe no-ops this session.
            StowerAnalytics.startBackend(
                consent: consent,
                identity: identity,
                makeClient: { _, _, _ in }
            )
            return
        }

        // Sentry FIRST — gives crash coverage as early as possible (JC3).
        StowerCrashReporting.start(consent: consent)

        // Then TelemetryDeck analytics backend.
        StowerAnalytics.startBackend(
            consent: consent,
            identity: identity,
            makeClient: makeAnalyticsClient
        )
    }

    // MARK: — Consent passthrough

    /// Whether diagnostics collection is currently enabled.
    ///
    /// Reads from the live analytics shared instance. Matches
    /// `StowerDiagnosticsConsent.isEnabled` (the Keychain cache + kill latch).
    public static func isEnabled() -> Bool {
        StowerAnalytics.isEnabled()
    }

    /// Enables or disables all diagnostics backends and updates the Keychain cache.
    ///
    /// Writes through to `StowerAnalytics.setEnabled(_:)` which owns the kill
    /// latch. The crash backend is a no-op backend — Sentry cannot be stopped
    /// mid-session once started (no `SentrySDK.close()` in the kill-switch path;
    /// the guarantee is "never started for an opted-out user", JC3). Effective
    /// next launch for crash; effective immediately for analytics events.
    ///
    /// The caller (Settings toggle / disclosure card) is responsible for pushing
    /// the change to the license record (`diagnostics_opt_out`) via the licensing
    /// workstream.
    public static func setEnabled(_ enabled: Bool) {
        StowerAnalytics.setEnabled(enabled)
    }

    /// Reconciles the local Keychain cache against the license record's opt-out
    /// flag on each license check-in.
    ///
    /// "Off wins" — this never auto-re-enables. Delegates to
    /// `StowerAnalytics.reconcileLicenseConsent(licenseOptOut:)`.
    ///
    /// - Parameter licenseOptOut: `true` when the license record carries
    ///   `diagnostics_opt_out = true`.
    public static func reconcileLicenseConsent(licenseOptOut: Bool) {
        StowerAnalytics.reconcileLicenseConsent(licenseOptOut: licenseOptOut)
    }
}
