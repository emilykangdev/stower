import StowerCore
import Testing

@testable import StowerMacUI

/// `compiledDefault(for:)` resolves `staging`/`production` per `StowerEnvironment`.
@Suite internal struct StowerFeedbackConfigTests {
    // MARK: I7 — compiledDefault(for:) resolves staging/production per environment

    @Test("compiledDefault(for: .debug) resolves to staging (I7)")
    internal func compiledDefaultForDebugIsStaging() {
        #expect(StowerFeedbackConfig.compiledDefault(for: .debug) == StowerFeedbackConfig.staging)
    }

    @Test("compiledDefault(for: .release) resolves to production (I7)")
    internal func compiledDefaultForReleaseIsProduction() {
        #expect(
            StowerFeedbackConfig.compiledDefault(for: .release) == StowerFeedbackConfig.production
        )
    }
}
