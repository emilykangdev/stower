import Foundation

/// The state of a device's local, `UserDefaults`-tracked free trial.
internal enum StowerTrialClockState: Sendable, Equatable {
    /// Still inside the trial window; carries the computed expiry date.
    case active(expiry: Date)

    /// The trial window has elapsed.
    case expired
}

/// A `UserDefaults`-backed 7-day free-trial clock.
///
/// The first-launch date is written once, on the first `state(now:)` read, and
/// never moves afterward — so relaunching (or a slow first read) can never
/// silently reset or extend the trial (I3). Deliberately plaintext and
/// resettable by wiping app data: an anti-casual-copy trial, not DRM (JC2).
internal struct StowerTrialClock: Sendable {
    nonisolated(unsafe) private let defaults: UserDefaults

    /// Creates a clock over the given defaults.
    ///
    /// - Parameter defaults: The backing store; injectable so tests use an
    ///   ephemeral suite and never touch the real domain.
    internal init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the first-launch date has been seeded yet — a pure read, never
    /// writes. `true` means the trial clock has already started (this launch
    /// or an earlier one); `false` means the very next `state(now:)` call will
    /// be the one that starts it.
    ///
    /// Callers that need "did the trial truly just start" (as opposed to "is
    /// it merely still active") check this BEFORE calling `state(now:)` —
    /// once `state(now:)` runs, the seed always exists, so checking after
    /// can't distinguish first-ever launch from a relaunch mid-trial.
    internal var hasSeededFirstLaunch: Bool {
        defaults.object(forKey: Self.firstLaunchDefaultsKey) != nil
    }

    /// Resolves the trial state as of `now`, seeding the first-launch date on
    /// the first call.
    ///
    /// - Parameter now: The instant to evaluate against; injectable so tests
    ///   are deterministic.
    /// - Returns: `.active(expiry:)` while `now` is before the 7-day expiry,
    ///   else `.expired`.
    internal func state(now: Date) -> StowerTrialClockState {
        let firstLaunch = firstLaunchDate(now: now)
        let expiry = firstLaunch.addingTimeInterval(Self.trialDuration.seconds)
        return now < expiry ? .active(expiry: expiry) : .expired
    }

    /// Reads the stored first-launch date, seeding it to `now` if absent.
    private func firstLaunchDate(now: Date) -> Date {
        if let stored = defaults.object(forKey: Self.firstLaunchDefaultsKey) as? Date {
            return stored
        }
        defaults.set(now, forKey: Self.firstLaunchDefaultsKey)
        return now
    }

    /// Clears the first-launch date (DEBUG `--reset-trial` lever only).
    internal func reset() {
        defaults.removeObject(forKey: Self.firstLaunchDefaultsKey)
    }

    /// The free-trial window: 7 days, card-free (JC1).
    internal static let trialDuration: Duration = .seconds(trialDays * Self.secondsPerDay)

    private static let trialDays = 7
    private static let secondsPerDay = 24 * 60 * 60
    private static let firstLaunchDefaultsKey = "com.stower.trial.firstLaunch"
}

extension Duration {
    /// The duration expressed as a `TimeInterval` (seconds), for `Date` arithmetic.
    fileprivate var seconds: TimeInterval {
        TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / StowerDurationConversion.attosecondsPerSecond
    }
}

/// A case-less namespace for the one homeless conversion constant `Duration.seconds`
/// needs — attoseconds-per-second has no natural owner type of its own.
private enum StowerDurationConversion {
    fileprivate static let attosecondsPerSecond: TimeInterval = 1_000_000_000_000_000_000
}
