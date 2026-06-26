import Foundation

@testable import StowerMacUI

/// What the fake's `activate` does on a given call.
internal enum StowerFakeActivateBehavior: Sendable {
    /// Returns the outcome immediately.
    case outcome(StowerLicenseActivation)

    /// Blocks until the test calls `release()`, then returns the outcome — for the
    /// in-flight tests (I6/I8): the run keeps running while the test drives a
    /// `cancel()` or a re-entrant submit, proving the generation guard / ignore
    /// path without racing on real cancellation timing.
    case blockUntilReleased(StowerLicenseActivation)
}

/// A Tests-only `StowerLicenseGating` double.
///
/// A locked `@unchecked Sendable` class (the seam's `hasStoredLicense` /
/// `persistLicense` are synchronous, so an `actor` can't conform). Records the
/// activate calls and persisted licenses so a test can assert that the launch
/// path never activates (I1/I7), that a stale activation persists nothing (I6),
/// and that a valid one persists the trimmed key (I3/I11).
internal final class StowerFakeLicenseGate: StowerLicenseGating, @unchecked Sendable {
    private let lock = NSLock()
    private var storedLicense: Bool
    private let activateBehaviors: [StowerFakeActivateBehavior]
    private var activateIndex = 0
    private var activateKeys: [String] = []
    private var persisted: [StowerStoredLicense] = []
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    /// Creates the fake.
    ///
    /// - Parameters:
    ///   - hasLicense: The initial `hasStoredLicense()` answer.
    ///   - activate: The scripted behaviors, reusing the last once spent.
    internal init(
        hasLicense: Bool = false,
        activate: [StowerFakeActivateBehavior] = [.outcome(.activated(instanceID: "inst"))]
    ) {
        storedLicense = hasLicense
        activateBehaviors = activate
    }

    /// How many times `activate` was invoked.
    internal var activateCallCount: Int {
        lock.withLock { activateKeys.count }
    }

    /// The licenses persisted via `persistLicense`, in order.
    internal var persistedLicenses: [StowerStoredLicense] {
        lock.withLock { persisted }
    }

    /// Unblocks a `.blockUntilReleased` activation.
    internal func release() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            let pending = releaseContinuation
            releaseContinuation = nil
            return pending
        }
        continuation?.resume()
    }

    internal func hasStoredLicense() -> Bool {
        lock.withLock { storedLicense }
    }

    internal func activate(key: String) async -> StowerLicenseActivation {
        let behavior: StowerFakeActivateBehavior = lock.withLock {
            activateKeys.append(key)
            guard !activateBehaviors.isEmpty else { return .outcome(.couldNotReach) }
            let index = min(activateIndex, activateBehaviors.count - 1)
            activateIndex += 1
            return activateBehaviors[index]
        }
        switch behavior {
        case .outcome(let outcome):
            return outcome
        case .blockUntilReleased(let outcome):
            await waitForRelease()
            return outcome
        }
    }

    internal func persistLicense(key: String, instanceID: String) {
        lock.withLock {
            persisted.append(StowerStoredLicense(key: key, instanceID: instanceID))
            storedLicense = true
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
