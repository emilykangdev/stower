import Testing

@testable import StowerMessages

@Suite("StowerMessages smoke")
internal struct StowerMessagesSmokeTests {
    @Test("module loads and reports a version string")
    internal func versionIsSet() {
        #expect(StowerMessages.version.hasPrefix("0."))
    }
}
