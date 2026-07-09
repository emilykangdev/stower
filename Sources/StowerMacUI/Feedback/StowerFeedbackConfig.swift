import StowerCore

/// The app-side feedback endpoint identity, resolved once at launch.
///
/// The only field is a public HTTPS URL — the Deno Deploy relay that holds the
/// Resend key. No secret ships in the binary; the Resend key lives only in the
/// Deno function's environment (`deno/feedback/main.ts`). A placeholder or
/// wrong URL fails every send closed (`StowerFeedbackClient` → `.failed`), not
/// because it is secret.
///
/// Resolves to the compiled default for the current `StowerEnvironment`
/// (mirroring `StowerLicenseConfig`): `staging` in a `DEBUG` build,
/// `production` otherwise.
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
    /// The same single v0 deploy as `production` (a later second deploy could
    /// give staging its own throwaway relay to avoid spamming the real inbox).
    internal static let staging = StowerFeedbackConfig(
        endpointURL: "https://stower-feedback.emilykangdev.deno.net"
    )

    /// The compiled default for a given build variant (PAR-62 — replaces this
    /// type's own independent Debug/Release detection with `StowerEnvironment`,
    /// the app's single source of truth for Debug/Release).
    internal static func compiledDefault(
        for environment: StowerEnvironment
    ) -> StowerFeedbackConfig {
        switch environment {
        case .debug: return staging
        case .release: return production
        }
    }

    /// The compiled default for the build this binary was actually compiled as.
    internal static let compiledDefault: StowerFeedbackConfig = compiledDefault(for: .current)

    /// The config the app runs with: the compiled default for this build.
    internal static let resolved: StowerFeedbackConfig = compiledDefault
}
