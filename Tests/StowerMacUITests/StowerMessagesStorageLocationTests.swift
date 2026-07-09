import StowerCore
import Testing

@testable import StowerMacUI

/// Demo/real-data isolation invariants for `StowerMessagesStorageLocation` (I4/I5).
@Suite internal struct StowerMessagesStorageLocationTests {
    // MARK: I4 — all three cases resolve to pairwise-distinct folder names

    @Test("all three storage locations resolve to pairwise-distinct folder names (I4)")
    internal func allCasesHaveDistinctFolderNames() {
        let names = [
            StowerMessagesStorageLocation.debug,
            .debugDemo,
            .release
        ].map(\.applicationSupportDirectoryName)
        #expect(Set(names).count == 3)
    }

    // MARK: I5 — .release never resolves to .debugDemo, regardless of overrideIsActive

    @Test("a release environment always resolves to .release, override active or not (I5)")
    internal func releaseIgnoresOverrideActive() {
        #expect(
            StowerMessagesStorageLocation.location(for: .release, overrideIsActive: true)
                == .release
        )
        #expect(
            StowerMessagesStorageLocation.location(for: .release, overrideIsActive: false)
                == .release
        )
    }

    @Test("a debug environment resolves to .debugDemo when the override is active (I5)")
    internal func debugWithActiveOverrideResolvesToDebugDemo() {
        #expect(
            StowerMessagesStorageLocation.location(for: .debug, overrideIsActive: true)
                == .debugDemo
        )
    }

    @Test("a debug environment resolves to .debug when the override is inactive (I5)")
    internal func debugWithInactiveOverrideResolvesToDebug() {
        #expect(
            StowerMessagesStorageLocation.location(for: .debug, overrideIsActive: false)
                == .debug
        )
    }
}
