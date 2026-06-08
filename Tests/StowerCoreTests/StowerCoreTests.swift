import Testing

@testable import StowerCore

@Suite("StowerCore smoke")
internal struct StowerCoreSmokeTests {
    @Test("module loads and reports a version string")
    internal func versionIsSet() {
        #expect(StowerCore.version.hasPrefix("0."))
    }
}
