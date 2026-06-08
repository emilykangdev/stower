import Testing

@testable import StowerPhotos

@Suite("StowerPhotos smoke")
internal struct StowerPhotosSmokeTests {
    @Test("module loads and reports a version string")
    internal func versionIsSet() {
        #expect(StowerPhotos.version.hasPrefix("0."))
    }
}
