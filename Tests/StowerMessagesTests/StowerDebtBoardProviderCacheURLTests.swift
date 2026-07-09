import Testing

@testable import StowerMessages

/// Folder-resolution invariants (I9, I11) for `StowerDebtBoardProvider.cacheURL(inFolder:)`.
///
/// Split from `StowerDebtBoardProviderTests` (a pure static-method surface, no
/// engine/model fixtures needed) so that suite stays under the swiftlint
/// `type_body_length` budget.
@Suite("StowerDebtBoardProvider.cacheURL")
internal struct StowerDebtBoardProviderCacheURLTests {
    // MARK: I9 — cacheURL(inFolder:) resolves under Application Support/<folderName>/

    @Test(
        "cacheURL(inFolder:) resolves under Application Support/<folderName>/, the cache file (I9)"
    )
    internal func cacheURLResolvesUnderGivenFolder() {
        let url = StowerDebtBoardProvider.cacheURL(inFolder: "SomeTestFolder")
        #expect(url?.lastPathComponent == StowerReplyVerdictCache.fileName)
        #expect(url?.deletingLastPathComponent().lastPathComponent == "SomeTestFolder")
    }

    // MARK: I11 — cacheURL(inFolder:) rejects an unsafe folder name

    @Test("cacheURL(inFolder:) rejects an empty, traversal, or multi-segment folder name (I11)")
    internal func cacheURLRejectsUnsafeFolderNames() {
        #expect(StowerDebtBoardProvider.cacheURL(inFolder: "") == nil)
        #expect(StowerDebtBoardProvider.cacheURL(inFolder: "../evil") == nil)
        #expect(StowerDebtBoardProvider.cacheURL(inFolder: "a/b") == nil)
        #expect(StowerDebtBoardProvider.cacheURL(inFolder: "..") == nil)
        #expect(StowerDebtBoardProvider.cacheURL(inFolder: ".") == nil)
    }
}
