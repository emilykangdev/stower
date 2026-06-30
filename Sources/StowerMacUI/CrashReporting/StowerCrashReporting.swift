// ONE of exactly two files in Stower that import Sentry (precheck 6l).
import Sentry

/// The ONLY `SentrySDK.start` site in Stower (precheck 6l).
///
/// Starts crash reporting when consent is enabled, using a hardened `Options`
/// configuration that disables every non-crash integration via individual
/// `enable*=false` flags (the xcframework public API) combined with
/// `enableCrashHandler = true`. This is the deny-list approach to non-crash
/// integrations that the xcframework's public API exposes.
///
/// The scrubber (`StowerSentryScrubber`) is wired as `beforeSend` and provides
/// defence-in-depth by dropping any non-crash event that slips through, and by
/// rebuilding `exception.value` to remove KSCrash memory-introspection content
/// (A5, spike-verified 2026-06-29).
///
/// `start(consent:)` is a no-op when consent is disabled — the crash handler
/// is never installed for an opted-out user (JC3). Do not rely on
/// `SentrySDK.close()` for the kill switch; don't-install is the testable
/// guarantee.
///
/// No `setUser` call — v1 attaches no identity to crash reports (brief
/// Decision 4). No `SentrySDK.capture*` call — v1 is crash-handler-only
/// (brief §Non-goals).
internal enum StowerCrashReporting {

    // MARK: — EU DSN (public/committable — client SDKs always ship the DSN)

    /// The Sentry EU-region project DSN.
    ///
    /// Hosted on `ingest.de.sentry.io` (EU data residency, A4). The DSN is
    /// public and committable — worst case is event-spam, mitigated by Sentry
    /// rate-limits/rotation. The `sentry-cli` auth token is NOT here (ops-gated).
    private static let euDSN =
        "https://sentry_dsn_placeholder@o0.ingest.de.sentry.io/0"

    // MARK: — Start

    /// Starts the Sentry crash handler when consent is enabled.
    ///
    /// - Parameters:
    ///   - consent: The shared diagnostics consent. When `isEnabled` is `false`
    ///     this is a no-op — no SDK init, no crash handler installed.
    ///   - startSDK: Injectable closure wrapping `SentrySDK.start`. The default
    ///     is the real SDK call; tests inject a spy to assert zero calls when
    ///     consent is off (§Invariants disabled-gate test).
    internal static func start(
        consent: StowerDiagnosticsConsent,
        startSDK: @escaping (@escaping (Options) -> Void) -> Void = { configure in
            SentrySDK.start(configureOptions: configure)
        }
    ) {
        // Defence-in-depth guard: the facade already gates on isEnabled, but a
        // second check here makes this function independently correct.
        guard consent.isEnabled else { return }

        startSDK { options in
            options.dsn = euDSN

            // Crash handler — the only integration we want.
            options.enableCrashHandler = true

            // Disable all non-crash integrations via individual flags.
            // The xcframework public API does not expose options.integrations; we
            // use the per-feature flags instead. All of these are the install-time
            // kill switches for the integrations the plan excludes (A1).
            options.enableAutoSessionTracking = false
            options.enableWatchdogTerminationTracking = false
            options.enableAppHangTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableAutoBreadcrumbTracking = false
            options.enableAutoPerformanceTracing = false
            options.enableNetworkTracking = false
            options.enableFileIOTracing = false
            options.enableSwizzling = false
            options.enableMetricKit = false

            // Client-level enrichment flags (not integrations — pinned explicitly
            // as drift guards; these are their defaults but we never leave them to
            // default-infer).
            // NEVER true — this is the PII landmine; Sentry quickstart sets it true.
            options.sendDefaultPii = false
            // attachScreenshot / attachViewHierarchy are UIKit-only and absent
            // from the macOS xcframework public API — not set here.
            options.attachStacktrace = false  // only adds stacks to messages; v1 sends none
            options.tracesSampleRate = 0  // no performance tracing

            // No breadcrumb bodies in v1.
            options.beforeBreadcrumb = { _ in nil }

            // Last-guardrail scrubber: rebuilds exception.value, redacts paths,
            // drops hard-stop tokens. The spike (A5) verified this mutates the
            // actual transmitted envelope.
            options.beforeSend = { event in StowerSentryScrubber.scrub(event) }

            #if DEBUG
                options.debug = true
            #endif
            // No setUser — v1 attaches no identity to crash reports (brief Decision 4).
        }
    }
}
