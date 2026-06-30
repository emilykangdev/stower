import Foundation
import Testing

@testable import StowerMacUI

/// Tests the bucketing edges from the plan's taxonomy (brief: 0/1-5/6-20/21+;
/// duration <5s/5-30s/30s-5min/5min+).
@Suite internal struct StowerAnalyticsBucketTests {

    // MARK: — Result count

    @Test internal func resultCount_zero() {
        #expect(StowerAnalyticsBucket.resultCount(0) == "0")
    }

    @Test internal func resultCount_one() {
        #expect(StowerAnalyticsBucket.resultCount(1) == "1-5")
    }

    @Test internal func resultCount_five() {
        #expect(StowerAnalyticsBucket.resultCount(5) == "1-5")
    }

    @Test internal func resultCount_six() {
        #expect(StowerAnalyticsBucket.resultCount(6) == "6-20")
    }

    @Test internal func resultCount_twenty() {
        #expect(StowerAnalyticsBucket.resultCount(20) == "6-20")
    }

    @Test internal func resultCount_twentyOne() {
        #expect(StowerAnalyticsBucket.resultCount(21) == "21+")
    }

    @Test internal func resultCount_large() {
        #expect(StowerAnalyticsBucket.resultCount(1_000) == "21+")
    }

    // MARK: — Duration

    @Test internal func duration_underFive() {
        #expect(StowerAnalyticsBucket.duration(0) == "under_5s")
        #expect(StowerAnalyticsBucket.duration(4.9) == "under_5s")
    }

    @Test internal func duration_fiveToThirty() {
        #expect(StowerAnalyticsBucket.duration(5) == "5_30s")
        #expect(StowerAnalyticsBucket.duration(29.9) == "5_30s")
    }

    @Test internal func duration_thirtyToFiveMin() {
        #expect(StowerAnalyticsBucket.duration(30) == "30s_5min")
        #expect(StowerAnalyticsBucket.duration(299) == "30s_5min")
    }

    @Test internal func duration_overFiveMin() {
        #expect(StowerAnalyticsBucket.duration(300) == "over_5min")
        #expect(StowerAnalyticsBucket.duration(3_600) == "over_5min")
    }
}
