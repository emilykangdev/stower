import Foundation

/// The app-side feedback endpoint identity, resolved once at launch.
///
/// The only field is a public HTTPS URL — the Deno Deploy relay that holds the
/// Resend key. No secret ships in the binary; the Resend key lives only in the
/// Deno function's environment (`deno/feedback/main.ts`). A placeholder or
/// wrong URL fails every send closed (`StowerFeedbackClient` → `.failed`), not
/// because it is secret.
///
/// Resolution mirrors `StowerLicenseConfig`: the compiled default (`staging` in
/// a `DEBUG` build, `production` otherwise), then a `STOWER_FEEDBACK_ENDPOINT`
/// `ProcessInfo` override applied **in DEBUG only**. A Release build pins the
/// compiled `production` URL and ignores the override (`effectiveConfig` passes
/// `allowOverrides: false`), so a launch-environment variable cannot swap the
/// endpoint in a shipped build; a DEBUG dev/test/CI run can point a build at a
/// throwaway Deno deploy without recompiling.
internal struct StowerFeedbackConfig: Sendable, Equatable {
    /// The Deno Deploy relay URL a feedback POST is sent to.
    internal let endpointURL: String

    /// Production endpoint — the deployed + smoke-tested Deno relay (OQ1
    /// resolved 2026-07-02: a real `curl` round-tripped `200 {ok:true}`).
    internal static let production = StowerFeedbackConfig(
        endpointURL: "https://stower-feedback.emilykangdev.deno.net"
    )

    /// Staging endpoint.
    ///
    /// The same single v0 deploy as `production`. A DEBUG dev points at a
    /// throwaway relay via `STOWER_FEEDBACK_ENDPOINT` (or a later second deploy)
    /// rather than spamming the real inbox.
    internal static let staging = StowerFeedbackConfig(
        endpointURL: "https://stower-feedback.emilykangdev.deno.net"
    )

    /// The compiled default for this build configuration.
    internal static let compiledDefault: StowerFeedbackConfig = {
        #if DEBUG
            return staging
        #else
            return production
        #endif
    }()

    /// Applies the `STOWER_FEEDBACK_ENDPOINT` environment override over `compiled`.
    ///
    /// Pure (the environment is injected) so the override/fallback logic is unit
    /// tested without mutating `ProcessInfo`. An unset or empty value falls back
    /// to the compiled URL.
    internal static func resolve(
        environment: [String: String],
        compiled: StowerFeedbackConfig
    ) -> StowerFeedbackConfig {
        guard let value = environment[endpointEnvKey], !value.isEmpty else { return compiled }
        return StowerFeedbackConfig(endpointURL: value)
    }

    /// The effective config: the compiled default with the `STOWER_FEEDBACK_ENDPOINT`
    /// override applied only when `allowOverrides` is true, else the compiled config
    /// verbatim.
    ///
    /// Pure (environment + flag injected) so both branches are unit tested. Release
    /// passes `allowOverrides: false` so a launch-environment variable cannot swap
    /// the configured endpoint; the override is a DEBUG dev/CI affordance.
    internal static func effectiveConfig(
        environment: [String: String],
        compiled: StowerFeedbackConfig,
        allowOverrides: Bool
    ) -> StowerFeedbackConfig {
        guard allowOverrides else { return compiled }
        return resolve(environment: environment, compiled: compiled)
    }

    /// The config the app runs with: compiled defaults, plus the
    /// `STOWER_FEEDBACK_ENDPOINT` override in DEBUG only (Release pins the compiled
    /// config — see `effectiveConfig`).
    internal static let resolved: StowerFeedbackConfig = {
        #if DEBUG
            let allowOverrides = true
        #else
            let allowOverrides = false
        #endif
        return effectiveConfig(
            environment: ProcessInfo.processInfo.environment,
            compiled: compiledDefault,
            allowOverrides: allowOverrides
        )
    }()

    /// The `ProcessInfo` override key (a DEBUG dev/test/CI points a build at any relay).
    private static let endpointEnvKey = "STOWER_FEEDBACK_ENDPOINT"
}
