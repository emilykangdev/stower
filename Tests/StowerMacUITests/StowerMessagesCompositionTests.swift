import Testing

@testable import StowerMacUI

/// The composition root's cross-store folder consistency invariant (I9).
///
/// Exercised via the pure `resolvedURLs(forFolder:)` seam so this file's first ever
/// test never opens a real store or touches the ambient `StowerDebug/` folder a live
/// app instance may be using concurrently.
@Suite internal struct StowerMessagesCompositionTests {
    private static let fixtureFolderName = "StowerCompositionTestFixture"

    @Test("all four stores resolve under the same caller-supplied folder name (I9)")
    internal func allStoresShareOneFolderName() {
        let resolved = StowerMessagesComposition.resolvedURLs(forFolder: Self.fixtureFolderName)

        let urls = [resolved.draftURL, resolved.triageURL, resolved.eventsURL, resolved.cacheURL]
        for url in urls {
            #expect(url != nil)
        }

        let parentFolders = Set(
            urls.compactMap { $0?.deletingLastPathComponent().lastPathComponent }
        )
        #expect(parentFolders == [Self.fixtureFolderName])
    }
}
