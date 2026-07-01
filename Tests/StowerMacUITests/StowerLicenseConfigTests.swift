import Testing

@testable import StowerMacUI

/// The pure `resolve(environment:compiled:)` layer: a `STOWER_*` env value
/// overrides the compiled field, and an absent or empty value falls back — proven
/// per field without mutating `ProcessInfo`.
@Suite internal struct StowerLicenseConfigTests {
    private let compiled = StowerLicenseConfig(
        functionBaseURL: "https://compiled.example/license",
        keygenPublicKeyHex: "aa",
        checkoutBaseURL: "https://compiled.example/checkout",
        feedbackBaseURL: "https://compiled.example/feedback"
    )

    @Test("an empty environment falls back to every compiled field")
    internal func emptyEnvironmentUsesCompiled() {
        #expect(StowerLicenseConfig.resolve(environment: [:], compiled: compiled) == compiled)
    }

    @Test("each STOWER_* override replaces only its own field")
    internal func overridesApplyPerField() {
        let resolved = StowerLicenseConfig.resolve(
            environment: [
                "STOWER_FUNCTION_URL": "https://env.example/license",
                "STOWER_KEYGEN_PUBLIC_KEY": "bb",
                "STOWER_CHECKOUT_URL": "https://env.example/checkout"
            ],
            compiled: compiled
        )
        #expect(resolved.functionBaseURL == "https://env.example/license")
        #expect(resolved.keygenPublicKeyHex == "bb")
        #expect(resolved.checkoutBaseURL == "https://env.example/checkout")
    }

    @Test("only the overridden field changes; the rest stay compiled")
    internal func partialOverrideLeavesOthers() {
        let resolved = StowerLicenseConfig.resolve(
            environment: ["STOWER_FUNCTION_URL": "https://env.example/license"],
            compiled: compiled
        )
        #expect(resolved.functionBaseURL == "https://env.example/license")
        #expect(resolved.keygenPublicKeyHex == compiled.keygenPublicKeyHex)
        #expect(resolved.checkoutBaseURL == compiled.checkoutBaseURL)
    }

    @Test("an empty-string override is ignored, falling back to compiled")
    internal func emptyOverrideFallsBack() {
        let resolved = StowerLicenseConfig.resolve(
            environment: ["STOWER_FUNCTION_URL": ""],
            compiled: compiled
        )
        #expect(resolved.functionBaseURL == compiled.functionBaseURL)
    }

    @Test("a release build ignores STOWER_* overrides, pinning the compiled trust anchor")
    internal func releaseIgnoresOverrides() {
        let resolved = StowerLicenseConfig.effectiveConfig(
            environment: [
                "STOWER_KEYGEN_PUBLIC_KEY": "deadbeef",
                "STOWER_FUNCTION_URL": "https://attacker.example/license"
            ],
            compiled: compiled,
            allowOverrides: false
        )
        // The forged trust anchor and endpoint are both ignored.
        #expect(resolved == compiled)
    }

    @Test("a debug build applies STOWER_* overrides")
    internal func debugAppliesOverrides() {
        let resolved = StowerLicenseConfig.effectiveConfig(
            environment: ["STOWER_KEYGEN_PUBLIC_KEY": "bb"],
            compiled: compiled,
            allowOverrides: true
        )
        #expect(resolved.keygenPublicKeyHex == "bb")
    }

    // I7 — feedbackBaseURL resolves to the compiled default and honors
    // STOWER_FEEDBACK_BASE_URL only when overrides are allowed.
    @Test("I7: feedbackBaseURL falls back to compiled when no override is set")
    internal func feedbackURLFallsBackToCompiled() {
        let resolved = StowerLicenseConfig.resolve(environment: [:], compiled: compiled)
        #expect(resolved.feedbackBaseURL == compiled.feedbackBaseURL)
    }

    @Test("I7: STOWER_FEEDBACK_BASE_URL overrides the feedback URL in a debug build")
    internal func feedbackURLOverriddenInDebug() {
        let resolved = StowerLicenseConfig.effectiveConfig(
            environment: ["STOWER_FEEDBACK_BASE_URL": "https://override.example/feedback"],
            compiled: compiled,
            allowOverrides: true
        )
        #expect(resolved.feedbackBaseURL == "https://override.example/feedback")
    }

    @Test("I7: STOWER_FEEDBACK_BASE_URL is ignored in a release build")
    internal func feedbackURLIgnoredInRelease() {
        let resolved = StowerLicenseConfig.effectiveConfig(
            environment: ["STOWER_FEEDBACK_BASE_URL": "https://attacker.example/feedback"],
            compiled: compiled,
            allowOverrides: false
        )
        #expect(resolved.feedbackBaseURL == compiled.feedbackBaseURL)
    }
}
