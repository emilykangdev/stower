import Foundation

@testable import StowerMacUI

/// What the fake's `loadDebtBoard` does on a given call.
internal enum StowerFakeLoadBehavior: Sendable {
    /// Resolves successfully — routes to the connected-loading state.
    case success

    /// Throws the given app-owned failure — drives routing.
    case failure(StowerStartupFailure)

    /// Awaits an effectively unbounded sleep that throws `CancellationError` when
    /// the in-flight task is cancelled — for the re-entrancy / cancel tests.
    case blockUntilCancelled
}

/// One recorded boundary call, so a test can assert ordering and counts.
internal enum StowerFakeStartupCall: Sendable, Equatable {
    case availability
    case load
}

/// A permanent Tests-only `StowerStartupProviding` double (an `actor`, so the
/// `Sendable` boundary holds without `@unchecked`).
///
/// Scriptable per the five routing scenarios the FDA slice tests: FDA-missing,
/// preflight-unavailable (per reason), unavailable-mid-load, invalid-config, and
/// the non-FDA failures. It records call order so a test can assert availability
/// runs before the load and that a preflight-unavailable never reaches the load.
internal actor StowerFakeStartupProvider: StowerStartupProviding {
    private let availability: StowerStartupModelAvailability
    private let loadBehaviors: [StowerFakeLoadBehavior]
    private let windowDays: Int
    private var loadIndex = 0

    /// The boundary calls in the order they were made.
    internal private(set) var recordedCalls: [StowerFakeStartupCall] = []

    /// Models a too-large debt threshold the same way the engine does (`§5b`): the
    /// load throws `.invalidConfig` when `unansweredForDays > windowDays`.
    internal init(
        availability: StowerStartupModelAvailability = .available,
        loadBehaviors: [StowerFakeLoadBehavior] = [.success],
        windowDays: Int = 180
    ) {
        self.availability = availability
        self.loadBehaviors = loadBehaviors
        self.windowDays = windowDays
    }

    /// How many times `modelAvailability()` was called.
    internal var availabilityCallCount: Int {
        recordedCalls.filter { $0 == .availability }.count
    }

    /// How many times `loadDebtBoard` was called.
    internal var loadCallCount: Int {
        recordedCalls.filter { $0 == .load }.count
    }

    internal func modelAvailability() async -> StowerStartupModelAvailability {
        recordedCalls.append(.availability)
        return availability
    }

    internal func loadDebtBoard(config: StowerStartupDebtConfig, now: Date) async throws {
        recordedCalls.append(.load)
        // Invalid config is detected before any availability re-check, matching the
        // engine's in-load ordering — the app preflight already ran once.
        guard config.unansweredForDays <= windowDays else {
            throw StowerStartupFailure.invalidConfig
        }
        switch nextLoadBehavior() {
        case .success:
            return
        case .failure(let failure):
            throw failure
        case .blockUntilCancelled:
            try await Task.sleep(for: .seconds(3_600))
        }
    }

    /// The behavior for this load call, reusing the last once the script is spent.
    private func nextLoadBehavior() -> StowerFakeLoadBehavior {
        guard !loadBehaviors.isEmpty else { return .success }
        let index = min(loadIndex, loadBehaviors.count - 1)
        loadIndex += 1
        return loadBehaviors[index]
    }
}
