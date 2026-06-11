import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerMessageDate")
internal struct StowerMessageDateTests {
    @Test("converts modern nanoseconds since 2001")
    internal func nanoseconds() throws {
        let rawValue: Int64 = 700_000_000_000_000_000
        let date = try #require(StowerMessageDate.date(from: rawValue))

        #expect(date.timeIntervalSinceReferenceDate == 700_000_000)
    }

    @Test("converts legacy seconds since 2001")
    internal func legacySeconds() throws {
        let date = try #require(StowerMessageDate.date(from: 700_000_000))

        #expect(date.timeIntervalSinceReferenceDate == 700_000_000)
    }

    @Test("excludes zero dates")
    internal func zeroDate() {
        #expect(StowerMessageDate.date(from: 0) == nil)
    }

    @Test("uses the documented unit threshold")
    internal func threshold() throws {
        let seconds = try #require(
            StowerMessageDate.date(from: StowerMessageDate.nanosecondsThreshold - 1)
        )
        let nanoseconds = try #require(
            StowerMessageDate.date(from: StowerMessageDate.nanosecondsThreshold)
        )

        #expect(seconds.timeIntervalSinceReferenceDate == 999_999_999_999)
        #expect(nanoseconds.timeIntervalSinceReferenceDate == 1_000)
    }
}
