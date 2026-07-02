import Contacts
import Foundation
import Testing

@testable import StowerMacUI

/// Proves `StowerContactsAccess` requests exactly when `.notDetermined` and maps
/// each terminal status to the right authorized-ness without re-prompting (I4).
///
/// Injects a scripted status + a spy request closure, so no real `CNContactStore`
/// and no real Contacts data are ever touched.
@Suite internal struct StowerContactsAccessTests {
    /// Records how many times the injected request closure fired, returning a
    /// scripted result; an `actor` so it is `Sendable` inside the `@Sendable` closure.
    private actor RequestSpy {
        private(set) var callCount = 0
        private let result: Bool

        init(result: Bool) { self.result = result }

        func fire() -> Bool {
            callCount += 1
            return result
        }
    }

    @Test("requestAccessIfNeeded prompts once on .notDetermined and returns the grant")
    internal func promptsWhenNotDetermined() async throws {
        let spy = RequestSpy(result: true)
        let access = StowerContactsAccess(status: { .notDetermined }, request: { await spy.fire() })
        let granted = try await access.requestAccessIfNeeded()
        #expect(granted)
        #expect(await spy.callCount == 1)
    }

    @Test("a denied prompt result is returned, still from a single request")
    internal func promptCanReturnDenied() async throws {
        let spy = RequestSpy(result: false)
        let access = StowerContactsAccess(status: { .notDetermined }, request: { await spy.fire() })
        let granted = try await access.requestAccessIfNeeded()
        #expect(granted == false)
        #expect(await spy.callCount == 1)
    }

    @Test("authorized returns true and never re-prompts")
    internal func authorizedNeverPrompts() async throws {
        let spy = RequestSpy(result: false)
        let access = StowerContactsAccess(status: { .authorized }, request: { await spy.fire() })
        #expect(access.isAuthorized)
        #expect(try await access.requestAccessIfNeeded())
        #expect(await spy.callCount == 0)
    }

    @Test("denied and restricted return false and never re-prompt")
    internal func terminalDenialNeverPrompts() async throws {
        for status in [CNAuthorizationStatus.denied, .restricted] {
            let spy = RequestSpy(result: true)
            let access = StowerContactsAccess(status: { status }, request: { await spy.fire() })
            #expect(access.isAuthorized == false)
            #expect(try await access.requestAccessIfNeeded() == false)
            #expect(await spy.callCount == 0)
        }
    }

    /// Proves the timeout race actually terminates on a wedged `request()` — the
    /// exact real-world failure (`Docs/Permissions.md`): `request` never resumes
    /// its continuation, so only a genuinely non-blocking timeout arm can ever
    /// settle this. A `TaskGroup`-based race would hang this test forever, since
    /// it implicitly awaits every child before returning (see
    /// `raceRequestAgainstTimeout`'s doc comment) — this test is what catches a
    /// regression back to that shape.
    @Test("requestAccessIfNeeded throws .timedOut when request() never resumes")
    internal func timesOutWhenRequestNeverResumes() async {
        let access = StowerContactsAccess(
            status: { .notDetermined },
            // Deliberately never resumed — this IS a wedged requestAccess. Swift
            // logs "leaked its continuation" for this at runtime; expected noise,
            // not a bug (see the doc comment above).
            request: { await withCheckedContinuation { (_: CheckedContinuation<Bool, Never>) in } },
            sleep: { _ in }  // resolves instantly — no real 10s wait in the test
        )
        await #expect(throws: StowerContactsAccessError.timedOut) {
            try await access.requestAccessIfNeeded()
        }
    }

    /// Proves a `request()` that finishes before the timeout still wins even
    /// with the real (non-instant) default timeout in play — the happy path is
    /// not remotely racy against a genuine 10-second timer.
    @Test("requestAccessIfNeeded returns the grant when it beats the (real) timeout")
    internal func grantBeatsRealTimeout() async throws {
        let spy = RequestSpy(result: true)
        let access = StowerContactsAccess(status: { .notDetermined }, request: { await spy.fire() })
        let granted = try await access.requestAccessIfNeeded()
        #expect(granted)
    }

    /// Proves a `request()` that only answers AFTER the timeout already threw
    /// still reports through `onLateResult` instead of being discarded — the
    /// scenario a slow-to-tap-Allow user hits if the timeout fires while the
    /// system prompt is still on screen.
    ///
    /// `request()` suspends on `LateAnswerGate` until the test explicitly
    /// signals it — deliberately AFTER `requestAccessIfNeeded` has already
    /// thrown `.timedOut` below — so "late" is a real, deterministic ordering
    /// here, not an instant-vs-instant race against the (also instant) injected
    /// `sleep`.
    @Test("a late request() answer reports through onLateResult instead of being dropped")
    internal func lateAnswerReportsThroughOnLateResult() async throws {
        let gate = LateAnswerGate()
        let late = LateResultBox()
        let access = StowerContactsAccess(
            status: { .notDetermined },
            request: { await gate.waitForSignal() },
            sleep: { _ in }
        )
        await #expect(throws: StowerContactsAccessError.timedOut) {
            try await access.requestAccessIfNeeded { granted in
                Task { await late.set(granted) }
            }
        }
        // Only now let request() answer — proving onLateResult is reachable
        // strictly after requestAccessIfNeeded already returned.
        await gate.signal(true)
        for _ in 0..<50 where await late.value == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await late.value == true)
    }
}

/// Holds `request()` suspended until the test calls `signal`, so a "late" OS
/// answer (arriving after `requestAccessIfNeeded` already timed out) can be
/// modeled deterministically instead of racing two near-instant closures.
private actor LateAnswerGate {
    private var continuation: CheckedContinuation<Bool, Never>?

    func waitForSignal() async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }

    func signal(_ result: Bool) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// Records `onLateResult`'s report from a `@MainActor @Sendable` callback,
/// polled from the test after signaling `LateAnswerGate`.
private actor LateResultBox {
    private(set) var value: Bool?
    func set(_ granted: Bool) { value = granted }
}
