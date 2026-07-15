import Foundation

/// The diagnostics umbrella facade: the single launch entry point for all
/// diagnostics backends (crash reporting + analytics).
///
/// `initialize()` is the ONLY call the app target makes to start both backends.
/// It reads consent once, and when explicitly enabled starts them in the
/// required order (JC3): Sentry crash reporting FIRST (earliest crash coverage),
/// then TelemetryDeck analytics. Before an explicit choice, neither backend
/// starts.
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
    private static var didStartCrashReporting = false

    /// Test seam for diagnostics backend side effects.
    @MainActor
    internal struct BackendHooks {
        internal let makeAnalyticsClient: (String, String, String) -> Void
        internal let startCrashReporting: (StowerDiagnosticsConsent) -> Void
        internal let stopCrashReporting: () -> Void

        internal static let live = BackendHooks(
            makeAnalyticsClient: { appID, salt, userID in
                StowerTelemetryDeckReporter.initializeSDK(appID: appID, salt: salt)
                StowerTelemetryDeckReporter.setDefaultUser(userID)
            },
            startCrashReporting: { consent in
                StowerCrashReporting.start(consent: consent)
            },
            stopCrashReporting: {
                StowerCrashReporting.stop()
            }
        )
    }

    // MARK: — Initialization

    /// Initializes all diagnostics backends behind the shared consent gate.
    ///
    /// The production entry point for `StowerMacApp.init()`. When consent is
    /// off this is a complete no-op — no SDK init, no crash handler, no
    /// automatic `TelemetryDeck.Session.started` (A3/JC3/JC6).
    ///
    /// The injectable form used by tests is `internal`; this public wrapper
    /// supplies real UserDefaults-backed instances so the app target never names
    /// those internal types.
    @MainActor
    public static func initialize() {
        initialize(
            consent: StowerDiagnosticsConsent(),
            identity: StowerDiagnosticsIdentity(),
            hooks: .live
        )
    }

    /// Initializes all diagnostics backends.
    ///
    /// - Parameters:
    ///   - consent: Shared consent accessor (real UserDefaults-backed in production;
    ///     inject a fake for tests).
    ///   - identity: Shared install-identity accessor (real UserDefaults-backed in
    ///     production; inject a fake for tests).
    ///   - hooks: Injectable backend side-effect closures for tests. Tests inject
    ///     spies to verify zero calls before consent and crash-first order after
    ///     consent.
    @MainActor
    internal static func initialize(
        consent: StowerDiagnosticsConsent,
        identity: StowerDiagnosticsIdentity,
        hooks: BackendHooks = .live
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
        startCrashReportingIfNeeded(consent: consent, hooks: hooks)

        // Then TelemetryDeck analytics backend.
        StowerAnalytics.startBackend(
            consent: consent,
            identity: identity,
            makeClient: hooks.makeAnalyticsClient
        )
    }

    // MARK: — Consent passthrough

    /// Whether diagnostics collection is currently enabled.
    ///
    /// Reads from the live analytics shared instance. Matches
    /// `StowerDiagnosticsConsent.isEnabled` (the UserDefaults cache + kill latch).
    public static func isEnabled() -> Bool {
        StowerAnalytics.isEnabled()
    }

    /// Enables or disables all diagnostics backends and updates the UserDefaults cache.
    ///
    /// When disabling, calls `StowerCrashReporting.stop()` (which closes the
    /// Sentry SDK) for a best-effort immediate halt. The primary guarantee remains
    /// "never started for an opted-out user at launch" (JC3); mid-session close
    /// is defence-in-depth so crashes after the toggle are not collected.
    ///
    /// Enabling after a diagnostics-dark launch starts Sentry and TelemetryDeck
    /// from that user action. If the user disables and then re-enables in the
    /// same process, Sentry is not restarted after `close()` because the SDK start
    /// path is one-shot per process. TelemetryDeck reuses the session-level SDK
    /// state tracked in `StowerAnalytics`.
    ///
    /// The caller (Settings toggle / disclosure card) is responsible for pushing
    /// the change to the license record (`diagnostics_opt_out`) via the licensing
    /// workstream.
    public static func setEnabled(_ enabled: Bool) {
        setEnabled(
            enabled,
            consent: StowerDiagnosticsConsent(),
            identity: StowerDiagnosticsIdentity(),
            hooks: .live
        )
    }

    /// Injectable form of `setEnabled(_:)` for tests.
    internal static func setEnabled(
        _ enabled: Bool,
        consent: StowerDiagnosticsConsent,
        identity: StowerDiagnosticsIdentity,
        hooks: BackendHooks
    ) {
        if enabled {
            consent.setEnabled(true)
            StowerDiagnosticsKillLatch.reset()
            startCrashReportingIfNeeded(consent: consent, hooks: hooks)
            StowerAnalytics.startBackend(
                consent: consent,
                identity: identity,
                makeClient: hooks.makeAnalyticsClient
            )
        } else {
            consent.setEnabled(false)
            StowerAnalytics.setEnabled(false)
            hooks.stopCrashReporting()
        }
    }

    private static func startCrashReportingIfNeeded(
        consent: StowerDiagnosticsConsent,
        hooks: BackendHooks
    ) {
        guard !didStartCrashReporting else { return }
        hooks.startCrashReporting(consent)
        didStartCrashReporting = true
    }

    /// Reconciles the local UserDefaults cache against the license record's opt-out
    /// flag on each license check-in.
    ///
    /// "Off wins" — this never auto-re-enables. When `licenseOptOut` is `true`,
    /// delegates to `StowerAnalytics.reconcileLicenseConsent(licenseOptOut:)` AND
    /// calls `StowerCrashReporting.stop()` so the Sentry crash handler is also
    /// closed immediately (same best-effort mid-session halt as `setEnabled(false)`).
    ///
    /// - Parameter licenseOptOut: `true` when the license record carries
    ///   `diagnostics_opt_out = true`.
    public static func reconcileLicenseConsent(licenseOptOut: Bool) {
        reconcileLicenseConsent(
            licenseOptOut: licenseOptOut,
            stopCrashReporting: { StowerCrashReporting.stop() }
        )
    }

    /// Injectable form of `reconcileLicenseConsent(licenseOptOut:)` for tests.
    ///
    /// Tests inject a spy for `stopCrashReporting` to assert it is called on
    /// opt-out without touching the real Sentry SDK.
    internal static func reconcileLicenseConsent(
        licenseOptOut: Bool,
        stopCrashReporting: () -> Void
    ) {
        StowerAnalytics.reconcileLicenseConsent(licenseOptOut: licenseOptOut)
        if licenseOptOut {
            stopCrashReporting()
        }
    }

    /// Resets facade-only process state for tests.
    internal static func resetForTesting() {
        didStartCrashReporting = false
    }

    #if DEBUG
        /// Triggers an immediate trap so the end-to-end crash-reporting pipeline can
        /// be verified by hand.
        ///
        /// DEBUG-only — never compiled into a release build. Sentry's signal/Mach
        /// handler (installed by `initialize()` when consent is on) catches the trap,
        /// writes the report to disk in the dying process, and uploads it on the NEXT
        /// launch (A2) — so relaunch Stower after using this, then check the Sentry EU
        /// dashboard. Requires explicit consent before launch, or an opt-in during the
        /// current launch before forcing the crash; with consent off no handler is
        /// installed and nothing is captured. The reason is a static string (no user
        /// data — 6n) and the scrubber rebuilds `exception.value` content-free.
        public static func debugForceCrash() {
            fatalError("Stower DEBUG forced crash — Sentry pipeline test")
        }
    #endif
}
