import StowerMessages
import Testing

@testable import StowerMacUI

/// `StowerMessagesMapping.mapRefresh` distils a `StowerRefreshSummary?` into the
/// app-owned `StowerBoardRefreshOutcome` per the engine contract + I9: `nil` is
/// coalesced; `judged + failed == total` is complete (with reload/judged/records
/// flags); anything short of total is an incomplete, parent-cancelled pass.
@Suite internal struct StowerBoardRefreshMappingTests {
    @Test("nil summary is coalesced")
    internal func nilIsCoalesced() {
        #expect(StowerMessagesMapping.mapRefresh(nil) == .coalesced)
    }

    @Test("a complete pass carries reloadNeeded, anyJudged, and hadRecords")
    internal func completePassFlags() {
        let summary = StowerRefreshSummary(
            changedChatIDs: ["a"],
            judgedCount: 2,
            failedCount: 1,
            totalCount: 3
        )
        #expect(
            StowerMessagesMapping.mapRefresh(summary)
                == .completed(reloadNeeded: true, anyJudged: true, hadRecords: true)
        )
    }

    @Test("an empty snapshot is complete with no records and nothing judged")
    internal func emptySnapshotComplete() {
        let summary = StowerRefreshSummary(
            changedChatIDs: [],
            judgedCount: 0,
            failedCount: 0,
            totalCount: 0
        )
        #expect(
            StowerMessagesMapping.mapRefresh(summary)
                == .completed(reloadNeeded: false, anyJudged: false, hadRecords: false)
        )
    }

    @Test("a total failure is complete, had records, judged none")
    internal func totalFailureComplete() {
        let summary = StowerRefreshSummary(
            changedChatIDs: [],
            judgedCount: 0,
            failedCount: 4,
            totalCount: 4
        )
        #expect(
            StowerMessagesMapping.mapRefresh(summary)
                == .completed(reloadNeeded: false, anyJudged: false, hadRecords: true)
        )
    }

    @Test("a pass short of total is incomplete (parent-cancelled), reload flag kept")
    internal func incompletePass() {
        let summary = StowerRefreshSummary(
            changedChatIDs: ["a"],
            judgedCount: 1,
            failedCount: 1,
            totalCount: 5
        )
        #expect(StowerMessagesMapping.mapRefresh(summary) == .incomplete(reloadNeeded: true))
    }
}
