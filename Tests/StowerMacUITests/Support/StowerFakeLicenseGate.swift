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
    private let activationResults: [StowerLicenseActivation]
    private let blocksActivation: Bool
    private let firstTrialObservationResults: [Bool]
    private var stateIndex = 0
    private var activationIndex = 0
    private var firstTrialObservationIndex = 0
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
    ///   - activationResult: What `activate(key:)` returns on every call.
    ///     Defaults to `.couldNotReach` (tests that need `.activated`/`.invalid`
    ///     set it explicitly). Ignored when `activationResults` is non-empty.
    ///   - activationResults: A scripted SEQUENCE of `activate(key:)` results,
    ///     reusing the last once spent — for a retry test that must see one
    ///     outcome then a different one (e.g. `[.invalid, .activated(...)]`:
    ///     a rejected key, then a good key on the next attempt). When empty
    ///     (the default), every call returns `activationResult`.
    ///   - blocksActivation: When `true`, `activate(key:)` blocks until the
    ///     test calls `releaseActivation()` — for the in-flight race test:
    ///     the caller drives a `cancel()` while activation is still pending,
    ///     proving the generation guard drops the late persist.
    ///   - firstTrialObservationResults: The scripted `isFirstTrialObservation`
    ///     results, reusing the last once spent. Defaults to always `true` so
    ///     existing per-launch-latch tests (`trialStartedThisLaunch`) see
    ///     unchanged behavior; a test asserting the cross-launch "seeded once
    ///     ever" semantics scripts `[true, false]` explicitly.
    internal init(
        states: [StowerLicenseState] = [.licensed],
        activationResult: StowerLicenseActivation = .couldNotReach,
        activationResults: [StowerLicenseActivation] = [],
        blocksActivation: Bool = false,
        firstTrialObservationResults: [Bool] = [true]
    ) {
        self.states = states
        self.activationResults = activationResults.isEmpty ? [activationResult] : activationResults
        self.blocksActivation = blocksActivation
        self.firstTrialObservationResults = firstTrialObservationResults
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

    internal func isFirstTrialObservation(now: Date) -> Bool {
        lock.withLock {
            guard !firstTrialObservationResults.isEmpty else { return true }
            let index = min(firstTrialObservationIndex, firstTrialObservationResults.count - 1)
            firstTrialObservationIndex += 1
            return firstTrialObservationResults[index]
        }
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
        return lock.withLock {
            let index = min(activationIndex, activationResults.count - 1)
            activationIndex += 1
            return activationResults[index]
        }
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
