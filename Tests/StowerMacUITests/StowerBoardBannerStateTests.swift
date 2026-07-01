import Foundation
import Testing

@testable import StowerMacUI

/// The board's F2/F3 bottom-banner state machine (`StowerBoardBannerState.resolve`).
@Suite internal struct StowerBoardBannerStateTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a stored license always resolves to .none, even if boughtThisSession is stuck true")
    internal func licensedAlwaysNone() {
        let state = StowerBoardBannerState.resolve(
            hasStoredLicense: true,
            boughtThisSession: true,
            trialBadge: StowerTrialBadge(expiry: now.addingTimeInterval(3600)),
            now: now
        )
        #expect(state == .none)
    }

    @Test("no license, no trial badge, not bought this session resolves to .none")
    internal func noLicenseNoTrialResolvesNone() {
        let state = StowerBoardBannerState.resolve(
            hasStoredLicense: false,
            boughtThisSession: false,
            trialBadge: nil,
            now: now
        )
        #expect(state == .none)
    }

    @Test("F2: boughtThisSession with no stored license resolves to .enterKey")
    internal func boughtThisSessionResolvesEnterKey() {
        let state = StowerBoardBannerState.resolve(
            hasStoredLicense: false,
            boughtThisSession: true,
            trialBadge: StowerTrialBadge(expiry: now.addingTimeInterval(5 * 24 * 60 * 60)),
            now: now
        )
        #expect(state == .enterKey)
    }

    @Test("more than a day of trial left resolves to the quiet .trialBadge")
    internal func multiDayTrialResolvesTrialBadge() {
        let expiry = now.addingTimeInterval(5 * 24 * 60 * 60)
        let state = StowerBoardBannerState.resolve(
            hasStoredLicense: false,
            boughtThisSession: false,
            trialBadge: StowerTrialBadge(expiry: expiry),
            now: now
        )
        #expect(state == .trialBadge(expiry: expiry))
    }

    @Test("F3: exactly one day of trial left resolves to .buyNudge")
    internal func exactlyOneDayResolvesBuyNudge() {
        let expiry = now.addingTimeInterval(24 * 60 * 60)
        let state = StowerBoardBannerState.resolve(
            hasStoredLicense: false,
            boughtThisSession: false,
            trialBadge: StowerTrialBadge(expiry: expiry),
            now: now
        )
        #expect(state == .buyNudge(expiry: expiry))
    }

    @Test("F3: less than a day of trial left resolves to .buyNudge")
    internal func underOneDayResolvesBuyNudge() {
        let expiry = now.addingTimeInterval(3600)
        let state = StowerBoardBannerState.resolve(
            hasStoredLicense: false,
            boughtThisSession: false,
            trialBadge: StowerTrialBadge(expiry: expiry),
            now: now
        )
        #expect(state == .buyNudge(expiry: expiry))
    }

    @Test("F2 takes priority over F3 — a same-session buy nudge still shows enterKey")
    internal func f2TakesPriorityOverF3() {
        let expiry = now.addingTimeInterval(3600)  // would be F3 alone
        let state = StowerBoardBannerState.resolve(
            hasStoredLicense: false,
            boughtThisSession: true,
            trialBadge: StowerTrialBadge(expiry: expiry),
            now: now
        )
        #expect(state == .enterKey)
    }
}
