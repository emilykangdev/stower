import Testing

@testable import StowerCore

/// Debug/Release folder-name invariants for `StowerEnvironment` (I1-I3).
@Suite("StowerEnvironment")
internal struct StowerEnvironmentTests {
    @Test("Debug and Release Application Support folder names are always distinct (I1)")
    internal func debugAndReleaseFolderNamesAreDistinct() {
        #expect(
            StowerEnvironment.debug.applicationSupportDirectoryName
                != StowerEnvironment.release.applicationSupportDirectoryName
        )
    }

    @Test("Release's folder name is byte-identical to the shared literal \"Stower\" (I2)")
    internal func releaseFolderNameIsUnchanged() {
        #expect(StowerEnvironment.release.applicationSupportDirectoryName == "Stower")
    }

    @Test("StowerEnvironment.current resolves to .debug under a normal test run (I3)")
    internal func currentResolvesToDebugUnderTest() {
        #expect(StowerEnvironment.current == .debug)
    }
}
