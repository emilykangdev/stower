import Foundation

@testable import StowerMacUI

/// What the fake returns for a given `currentStatus` call.
internal enum StowerFakeStatusBehavior: Sendable {
    /// Returns the status immediately.
    case status(StowerLicenseStatus)

    /// Blocks until the test calls `release()`, then returns the status — for the
    /// in-flight tests: the run keeps running while the test drives a `cancel()`,
    /// proving the generation guard drops the late commit without racing on real
    /// cancellation timing.
    case blockUntilReleased(StowerLicenseStatus)
}

/// A Tests-only `StowerLicenseGating` double.
///
/// A locked `@unchecked Sendable` class (the seam's `hasLease` is synchronous, so
/// an `actor` can't conform). Records the `currentStatus` calls and the `now` it
/// was passed so a test can assert the gate is never asked before availability
/// (B-I11) and that the model routes each status to the right state.
internal final class StowerFakeLicenseGate: StowerLicenseGating, @unchecked Sendable {
    private let lock = NSLock()
    private let lease: Bool
    private let behaviors: [StowerFakeStatusBehavior]
    private let badge: StowerTrialBadge?
    private var behaviorIndex = 0
    private var recordedNows: [Date] = []
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    /// Creates the fake.
    ///
    /// - Parameters:
    ///   - hasLease: The `hasLease()` answer.
    ///   - statuses: The scripted `currentStatus` behaviors, reusing the last once
    ///     spent. Defaults to a single `.valid` so the pre-license routing tests
    ///     reach the board unchanged.
    ///   - trialBadge: The value returned by `trialBadge()`. Defaults to `nil`
    ///     (paid / no active trial) so existing tests are unaffected.
    internal init(
        hasLease: Bool = false,
        statuses: [StowerFakeStatusBehavior] = [.status(.valid)],
        trialBadge: StowerTrialBadge? = nil
    ) {
        self.lease = hasLease
        self.behaviors = statuses
        self.badge = trialBadge
    }

    /// How many times `currentStatus` was invoked.
    internal var statusCallCount: Int {
        lock.withLock { recordedNows.count }
    }

    /// The `now` values passed to each `currentStatus` call, in order.
    internal var recordedNowValues: [Date] {
        lock.withLock { recordedNows }
    }

    /// Unblocks a `.blockUntilReleased` status.
    internal func release() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            let pending = releaseContinuation
            releaseContinuation = nil
            return pending
        }
        continuation?.resume()
    }

    internal func hasLease() -> Bool {
        lock.withLock { lease }
    }

    internal func trialBadge() -> StowerTrialBadge? {
        lock.withLock { badge }
    }

    internal func currentStatus(now: Date) async -> StowerLicenseStatus {
        let behavior: StowerFakeStatusBehavior = lock.withLock {
            recordedNows.append(now)
            guard !behaviors.isEmpty else { return .status(.couldNotReach) }
            let index = min(behaviorIndex, behaviors.count - 1)
            behaviorIndex += 1
            return behaviors[index]
        }
        switch behavior {
        case .status(let status):
            return status
        case .blockUntilReleased(let status):
            await waitForRelease()
            return status
        }
    }

    private func waitForRelease() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyReleased: Bool = lock.withLock {
                if released { return true }
                releaseContinuation = continuation
                return false
            }
            if alreadyReleased {
                continuation.resume()
            }
        }
    }
}
