import Foundation

/// The analytics backend: event reporting via TelemetryDeck.
///
/// The orchestration layer (consent gate, SDK init ordering) now lives in
/// `StowerDiagnostics` (JC1). `StowerAnalytics` owns only the TelemetryDeck
/// backend: the SDK init helper and the event reporter. The consent/identity
/// types live in `Sources/StowerMacUI/Diagnostics/`.
///
/// `@MainActor`-isolated: call from the main actor (the app's startup and UI
/// already do). Synchronous — an async caller off the main actor must hop to it
/// first; there is no `await` *within* main-actor code (Eng F4/F5). The reporter
/// itself is `Sendable`.
@MainActor
public final class StowerAnalytics {
    /// The singleton built by `startBackend` and used by `report`.
    private static var shared: StowerAnalytics?

    /// Whether the TelemetryDeck SDK has been initialized this session.
    ///
    /// Tracked so re-enabling from an off launch initializes the SDK exactly
    /// once (the Swift SDK has no `stop()`, A4), avoiding a duplicate
    /// `TelemetryDeck.initialize` (and its automatic `Session.started`, A3).
    private static var didStartSDK = false

    private let reporter: any StowerAnalyticsReporting
    private let consent: StowerDiagnosticsConsent

    /// The stable TelemetryDeck app identifier (write-only, public/committable).
    ///
    /// This is a collection-only App ID — not a Personal Access Token.
    private static let appID = "56961262-AADB-4F46-A4FE-954E19C6236B"

    /// A stable, app-specific salt for hash stability only.
    ///
    /// Anonymity comes from the random install UUID, NOT the salt (Eng F7).
    /// Once set, this must never change — a changed salt makes every existing
    /// user look like a new user to TelemetryDeck.
    private static let stableSalt = "stower-v0-analytics-salt-2026"

    private init(reporter: any StowerAnalyticsReporting, consent: StowerDiagnosticsConsent) {
        self.reporter = reporter
        self.consent = consent
    }

    // MARK: — Backend init (called only from StowerDiagnostics facade)

    /// Starts the TelemetryDeck backend when consent is enabled (JC3).
    ///
    /// Called exclusively by `StowerDiagnostics.initialize()` — not by the app
    /// target directly. The `makeClient` closure is injectable so tests can
    /// verify the kill switch without importing TelemetryDeck.
    ///
    /// When consent is disabled this is a complete no-op: `makeClient` is never
    /// called, suppressing the automatic `TelemetryDeck.Session.started` signal
    /// (A3/JC6). There is no Swift `stop()` (A4), so the gate is "never start
    /// when disabled."
    ///
    /// - Parameters:
    ///   - consent: The consent accessor (real UserDefaults-backed in production;
    ///     inject a fake for tests).
    ///   - identity: The install-identity accessor (real UserDefaults-backed in production;
    ///     inject a fake for tests).
    ///   - makeClient: Injectable SDK-init closure. Receives `(appID, salt,
    ///     userID)`. The default calls `StowerTelemetryDeckReporter.initializeSDK`
    ///     and `setDefaultUser` so this file never imports TelemetryDeck
    ///     (precheck 6k). Tests inject a spy closure.
    @MainActor
    internal static func startBackend(
        consent: StowerDiagnosticsConsent,
        identity: StowerDiagnosticsIdentity,
        makeClient: (String, String, String) -> Void = { appID, salt, userID in
            StowerTelemetryDeckReporter.initializeSDK(appID: appID, salt: salt)
            StowerTelemetryDeckReporter.setDefaultUser(userID)
        }
    ) {
        guard consent.isEnabled else {
            // Kill switch: build a no-op reporter; never call makeClient.
            let noOp = StowerAnalytics(
                reporter: StowerNoOpAnalyticsReporter(),
                consent: consent
            )
            Self.shared = noOp
            return
        }

        if Self.didStartSDK {
            // SDK already started this session (A4: no stop/restart); refresh live reporter only.
            Self.shared = StowerAnalytics(
                reporter: StowerTelemetryDeckReporter(consent: consent),
                consent: consent
            )
            return
        }

        // TelemetryDeck double-hashes the userID (UUID → SHA-256 with the salt →
        // its own hash on the wire) so the raw UUID never leaves the device.
        makeClient(appID, stableSalt, identity.clientUser())
        Self.didStartSDK = true

        let live = StowerAnalytics(
            reporter: StowerTelemetryDeckReporter(consent: consent),
            consent: consent
        )
        Self.shared = live
    }

    // MARK: — Event reporting

    /// Emits one analytics event through the configured reporter.
    ///
    /// A no-op when `startBackend` has not yet been called or analytics is off.
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

    // MARK: — Test support

    /// Resets all static state so each test starts from a clean slate.
    ///
    /// Clears `shared`, `didStartSDK`, and the kill latch. Call at the start of
    /// every test that calls `startBackend(consent:identity:makeClient:)` to prevent
    /// static state from one test leaking into the next (A4: no SDK restart).
    /// Not for production use.
    @MainActor
    internal static func resetForTesting() {
        shared = nil
        didStartSDK = false
        StowerDiagnosticsKillLatch.reset()
    }

    // MARK: — Consent passthrough (delegated to StowerDiagnostics in production)

    /// Whether diagnostics collection is currently enabled.
    ///
    /// Reads from the live `shared` reporter's consent; returns `false` when
    /// the backend has not been started. Used by `StowerPrivacySettingsView`
    /// to initialize its toggle state.
    internal static func isEnabled() -> Bool {
        shared?.consent.isEnabled ?? false
    }

    /// Enables or disables the analytics backend and updates the local UserDefaults cache.
    ///
    /// In production this is called via `StowerDiagnostics.setEnabled(_:)` which
    /// handles both backends. The caller (Settings toggle / disclosure card) is
    /// responsible for pushing the change to the license record.
    internal static func setEnabled(_ enabled: Bool) {
        guard let current = shared else { return }
        current.consent.setEnabled(enabled)
        if enabled {
            // Clear the in-memory kill latch, then bring up a live reporter. If
            // the SDK never started this session (launched disabled), initialize
            // it now — gated on the now-enabled consent. Otherwise just restore a
            // live reporter (the SDK can't be re-initialized; A4).
            StowerDiagnosticsKillLatch.reset()
            if Self.didStartSDK {
                Self.shared = StowerAnalytics(
                    reporter: StowerTelemetryDeckReporter(consent: current.consent),
                    consent: current.consent
                )
            } else {
                startBackend(consent: current.consent, identity: StowerDiagnosticsIdentity())
            }
        } else {
            // Fail closed in memory across every reporter, even if the UserDefaults
            // write failed. Durable off is backstopped by the license record's
            // `diagnostics_opt_out`, reconciled on the next check-in (JC8).
            StowerDiagnosticsKillLatch.latchOff()
            Self.shared = StowerAnalytics(
                reporter: StowerNoOpAnalyticsReporter(),
                consent: current.consent
            )
        }
    }

    /// Reconciles the local UserDefaults cache against the license record's opt-out
    /// flag on each license check-in.
    ///
    /// "Off wins" — this never auto-re-enables. Called via
    /// `StowerDiagnostics.reconcileLicenseConsent(licenseOptOut:)` in production.
    ///
    /// - Parameter licenseOptOut: `true` when the license record carries
    ///   `diagnostics_opt_out = true`.
    internal static func reconcileLicenseConsent(licenseOptOut: Bool) {
        guard let current = shared else { return }
        current.consent.reconcile(licenseOptOut: licenseOptOut)
        if licenseOptOut {
            StowerDiagnosticsKillLatch.latchOff()
            Self.shared = StowerAnalytics(
                reporter: StowerNoOpAnalyticsReporter(),
                consent: current.consent
            )
        }
    }
}
