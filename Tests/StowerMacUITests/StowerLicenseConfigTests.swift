import StowerCore
import Testing

@testable import StowerMacUI

/// `compiledDefault(for:)` resolves `staging`/`production` per `StowerEnvironment`.
@Suite internal struct StowerLicenseConfigTests {
    // MARK: I6 — compiledDefault(for:) resolves staging/production per environment

    @Test("compiledDefault(for: .debug) resolves to staging (I6)")
    internal func compiledDefaultForDebugIsStaging() {
        #expect(StowerLicenseConfig.compiledDefault(for: .debug) == StowerLicenseConfig.staging)
    }

    @Test("compiledDefault(for: .release) resolves to production (I6)")
    internal func compiledDefaultForReleaseIsProduction() {
        #expect(
            StowerLicenseConfig.compiledDefault(for: .release) == StowerLicenseConfig.production
        )
    }
}
