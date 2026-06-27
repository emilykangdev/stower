import Testing

@testable import StowerMacUI

/// The pure `resolve(environment:compiled:)` layer: a `STOWER_*` env value
/// overrides the compiled field, and an absent or empty value falls back — proven
/// per field without mutating `ProcessInfo`.
@Suite internal struct StowerLicenseConfigTests {
    private let compiled = StowerLicenseConfig(
        functionBaseURL: "https://compiled.example/license",
        keygenPublicKeyHex: "aa",
        checkoutBaseURL: "https://compiled.example/checkout"
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
}
