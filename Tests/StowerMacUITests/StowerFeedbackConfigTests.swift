import Testing

@testable import StowerMacUI

/// The pure config resolution layer: `STOWER_FEEDBACK_ENDPOINT` overrides the
/// compiled URL only in a DEBUG-equivalent (`allowOverrides: true`) build; a
/// Release build (`allowOverrides: false`) pins the compiled URL (I-ReleaseIgnoresEnv).
@Suite internal struct StowerFeedbackConfigTests {
    private let compiled = StowerFeedbackConfig(endpointURL: "https://compiled.example/feedback")

    @Test("an empty environment falls back to the compiled endpoint")
    internal func emptyEnvironmentUsesCompiled() {
        #expect(StowerFeedbackConfig.resolve(environment: [:], compiled: compiled) == compiled)
    }

    @Test("STOWER_FEEDBACK_ENDPOINT overrides the compiled endpoint")
    internal func overrideApplies() {
        let resolved = StowerFeedbackConfig.resolve(
            environment: ["STOWER_FEEDBACK_ENDPOINT": "https://env.example/feedback"],
            compiled: compiled
        )
        #expect(resolved.endpointURL == "https://env.example/feedback")
    }

    @Test("an empty-string override is ignored, falling back to compiled")
    internal func emptyOverrideFallsBack() {
        let resolved = StowerFeedbackConfig.resolve(
            environment: ["STOWER_FEEDBACK_ENDPOINT": ""],
            compiled: compiled
        )
        #expect(resolved == compiled)
    }

    @Test("I-ReleaseIgnoresEnv: a release build ignores the override, pinning compiled")
    internal func releaseIgnoresOverride() {
        let resolved = StowerFeedbackConfig.effectiveConfig(
            environment: ["STOWER_FEEDBACK_ENDPOINT": "https://attacker.example/feedback"],
            compiled: compiled,
            allowOverrides: false
        )
        #expect(resolved == compiled)
    }

    @Test("a debug build applies the override")
    internal func debugAppliesOverride() {
        let resolved = StowerFeedbackConfig.effectiveConfig(
            environment: ["STOWER_FEEDBACK_ENDPOINT": "https://dev.example/feedback"],
            compiled: compiled,
            allowOverrides: true
        )
        #expect(resolved.endpointURL == "https://dev.example/feedback")
    }
}
