import Testing

@testable import StowerMacUI

/// The pure `resolve(environment:compiled:)` layer: a `STOWER_*` env value
/// overrides the compiled field, and an absent/empty/unparseable value falls
/// back — proven per field without mutating `ProcessInfo`.
@Suite internal struct StowerLicenseConfigTests {
    private let compiled = StowerLicenseConfig(
        checkoutURL: "https://compiled.example/checkout",
        storeID: 11,
        productID: 22
    )

    @Test("an empty environment falls back to every compiled field")
    internal func emptyEnvironmentUsesCompiled() {
        #expect(StowerLicenseConfig.resolve(environment: [:], compiled: compiled) == compiled)
    }

    @Test("each STOWER_* override replaces only its own field")
    internal func overridesApplyPerField() {
        let resolved = StowerLicenseConfig.resolve(
            environment: [
                "STOWER_CHECKOUT_URL": "https://env.example/checkout",
                "STOWER_STORE_ID": "33",
                "STOWER_PRODUCT_ID": "44"
            ],
            compiled: compiled
        )
        #expect(resolved.checkoutURL == "https://env.example/checkout")
        #expect(resolved.storeID == 33)
        #expect(resolved.productID == 44)
    }

    @Test("only the overridden field changes; the rest stay compiled")
    internal func partialOverrideLeavesOthers() {
        let resolved = StowerLicenseConfig.resolve(
            environment: ["STOWER_CHECKOUT_URL": "https://env.example/checkout"],
            compiled: compiled
        )
        #expect(resolved.checkoutURL == "https://env.example/checkout")
        #expect(resolved.storeID == compiled.storeID)
        #expect(resolved.productID == compiled.productID)
    }

    @Test("an empty-string override is ignored, falling back to compiled")
    internal func emptyOverrideFallsBack() {
        let resolved = StowerLicenseConfig.resolve(
            environment: ["STOWER_CHECKOUT_URL": ""],
            compiled: compiled
        )
        #expect(resolved.checkoutURL == compiled.checkoutURL)
    }

    @Test("an unparseable int override falls back to compiled rather than crash")
    internal func unparseableIntOverrideFallsBack() {
        let resolved = StowerLicenseConfig.resolve(
            environment: ["STOWER_STORE_ID": "not-a-number"],
            compiled: compiled
        )
        #expect(resolved.storeID == compiled.storeID)
    }

    @Test("a release build ignores STOWER_* overrides, pinning the compiled identity")
    internal func releaseIgnoresOverrides() {
        let resolved = StowerLicenseConfig.effectiveConfig(
            environment: [
                "STOWER_STORE_ID": "999",
                "STOWER_CHECKOUT_URL": "https://attacker.example/checkout"
            ],
            compiled: compiled,
            allowOverrides: false
        )
        #expect(resolved == compiled)
    }

    @Test("a debug build applies STOWER_* overrides")
    internal func debugAppliesOverrides() {
        let resolved = StowerLicenseConfig.effectiveConfig(
            environment: ["STOWER_STORE_ID": "77"],
            compiled: compiled,
            allowOverrides: true
        )
        #expect(resolved.storeID == 77)
    }
}
