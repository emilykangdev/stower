import Foundation
import Testing

@testable import StowerMacUI

/// I3: the trial clock's first-launch date is set once and never moves.
@Suite internal struct StowerTrialClockTests {
    /// Makes an isolated defaults suite for one test, pre-cleared.
    private func makeDefaults(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("I3: the first-launch date is set on first read and never moves")
    internal func firstLaunchDateNeverMoves() {
        let suite = "stower.trialclock.stable"
        let defaults = makeDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = StowerTrialClock(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let threeDaysLater = t0.addingTimeInterval(3 * 24 * 60 * 60)

        let first = clock.state(now: t0)
        let second = clock.state(now: threeDaysLater)

        guard case .active(let firstExpiry) = first, case .active(let secondExpiry) = second else {
            Issue.record("expected both reads to be active")
            return
        }
        #expect(firstExpiry == secondExpiry)
    }

    @Test("active while now is before the 7-day expiry")
    internal func activeBeforeExpiry() {
        let suite = "stower.trialclock.active"
        let defaults = makeDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = StowerTrialClock(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = clock.state(now: t0)

        let state = clock.state(now: t0.addingTimeInterval(6 * 24 * 60 * 60))

        #expect(state == .active(expiry: t0.addingTimeInterval(7 * 24 * 60 * 60)))
    }

    @Test("expired once 7 days have elapsed since first launch")
    internal func expiredPastSevenDays() {
        let suite = "stower.trialclock.expired"
        let defaults = makeDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = StowerTrialClock(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = clock.state(now: t0)

        let state = clock.state(now: t0.addingTimeInterval(8 * 24 * 60 * 60))

        #expect(state == .expired)
    }

    @Test("reset clears the first-launch date so the next read seeds a fresh one")
    internal func resetClearsFirstLaunch() {
        let suite = "stower.trialclock.reset"
        let defaults = makeDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = StowerTrialClock(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = clock.state(now: t0)
        let eightDaysLater = t0.addingTimeInterval(8 * 24 * 60 * 60)
        #expect(clock.state(now: eightDaysLater) == .expired)

        clock.reset()
        let afterReset = clock.state(now: eightDaysLater)

        #expect(afterReset == .active(expiry: eightDaysLater.addingTimeInterval(7 * 24 * 60 * 60)))
    }
}
