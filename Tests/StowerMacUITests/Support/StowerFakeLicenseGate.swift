import Foundation

@testable import StowerMacUI

/// A Tests-only `StowerLicenseGating` double.
///
/// A locked `@unchecked Sendable` class (the seam's `licenseState` is
/// synchronous, so an `actor` can't conform). Records the `licenseState` calls
/// and the `now` each was passed, plus every `persist` call, so a test can
/// assert the gate is never asked before availability and that the model
/// routes each state to the right screen.
internal final class StowerFakeLicenseGate: StowerLicenseGating, @unchecked Sendable {
    private let lock = NSLock()
    private let states: [StowerLicenseState]
    private let activationResult: StowerLicenseActivation
    private let blocksActivation: Bool
    private var stateIndex = 0
    private var recordedNows: [Date] = []
    private var persistedCalls: [(key: String, instanceID: String)] = []
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var activationCallCount = 0

    /// Creates the fake.
    ///
    /// - Parameters:
    ///   - states: The scripted `licenseState` results, reusing the last once
    ///     spent. Defaults to a single `.licensed` so the pre-license routing
    ///     tests reach the board unchanged.
    ///   - activationResult: What `activate(key:)` returns. Defaults to
    ///     `.couldNotReach` (tests that need `.activated`/`.invalid` set it
    ///     explicitly).
    ///   - blocksActivation: When `true`, `activate(key:)` blocks until the
    ///     test calls `releaseActivation()` — for the in-flight race test:
    ///     the caller drives a `cancel()` while activation is still pending,
    ///     proving the generation guard drops the late persist.
    internal init(
        states: [StowerLicenseState] = [.licensed],
        activationResult: StowerLicenseActivation = .couldNotReach,
        blocksActivation: Bool = false
    ) {
        self.states = states
        self.activationResult = activationResult
        self.blocksActivation = blocksActivation
    }

    /// How many times `licenseState` was invoked.
    internal var stateCallCount: Int {
        lock.withLock { recordedNows.count }
    }

    /// The `now` values passed to each `licenseState` call, in order.
    internal var recordedNowValues: [Date] {
        lock.withLock { recordedNows }
    }

    /// Every `persist(key:instanceID:)` call recorded, in order.
    internal var persistCalls: [(key: String, instanceID: String)] {
        lock.withLock { persistedCalls }
    }

    internal func licenseState(now: Date) -> StowerLicenseState {
        lock.withLock {
            recordedNows.append(now)
            guard !states.isEmpty else { return .expired }
            let index = min(stateIndex, states.count - 1)
            stateIndex += 1
            return states[index]
        }
    }

    /// How many times `activate` was invoked — lets a race test wait until the
    /// blocked call has actually started before driving a `cancel()`.
    internal var activationCallCountValue: Int {
        lock.withLock { activationCallCount }
    }

    internal func activate(key: String) async -> StowerLicenseActivation {
        lock.withLock { activationCallCount += 1 }
        if blocksActivation {
            await waitForRelease()
        }
        return activationResult
    }

    internal func persist(key: String, instanceID: String) {
        lock.withLock { persistedCalls.append((key: key, instanceID: instanceID)) }
    }

    /// Unblocks a pending `blocksActivation` activate call.
    internal func releaseActivation() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            let pending = releaseContinuation
            releaseContinuation = nil
            return pending
        }
        continuation?.resume()
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
