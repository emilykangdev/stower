import Foundation
import StowerMessages
import Synchronization
import Testing

@testable import StowerMacUI

/// The board view-model's handling of `StowerContactsAccess`'s timeout/coalescing
/// contract: a wedged request releases the UI latch instead of hanging forever, a
/// retry joins the abandoned in-flight request instead of stacking a second real
/// `CNContactStore.requestAccess`, and a cancelled board neither reloads on a late
/// grant nor is left showing stale "Try Again" state.
///
/// Split from `StowerBoardViewModelContactsTests.swift` (same file, over the
/// `file_length`/`type_body_length` precheck gates) — the same split-across-files
/// posture as `StowerBoardViewModelContacts.swift` itself.
@MainActor
@Suite internal struct StowerBoardViewModelContactsTimeoutTests {
    /// Collects routed failures (none expected here; satisfies the VM's `onFailure`).
    private final class FailureRecorder {
        var failures: [StowerStartupFailure] = []
    }

    /// A one-row board, so a loaded board reaches `.rows` (the banner's precondition).
    private func oneRowBoard() -> StowerBoardModel {
        StowerBoardModel(
            neglected: [
                StowerBoardRow(
                    chatID: "a",
                    counterpart: "+14155550100",
                    counterpartHandle: "+14155550100",
                    draftKey: StowerDraftKey.derive(forHandle: "+14155550100"),
                    lastMessageGUID: "guid-a",
                    lastMessageTimestamp: Date(timeIntervalSince1970: 1_000_000),
                    monogram: "1",
                    summary: StowerLastMessageSummary.make(kind: .text, text: "hi"),
                    ageInDays: 1,
                    deepLink: nil
                )
            ],
            ghosted: []
        )
    }

    private func makeViewModel(
        _ spy: StowerSpyBoardDataSource,
        contacts: StowerContactsAccess,
        recorder: FailureRecorder
    ) -> StowerBoardViewModel {
        StowerBoardViewModel(
            dataSource: spy,
            contacts: contacts,
            onFailure: { recorder.failures.append($0) },
            sleep: { _ in }
        )
    }

    @Test("a retry after timeout joins the in-flight request instead of stacking a second one")
    internal func retryJoinsInFlightRequestInsteadOfStacking() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [oneRowBoard()]
        let requestCallCount = Mutex(0)
        // `request` never resumes, so the real OS call this test double models
        // stays outstanding across both taps — only the count tells us whether
        // a second real `CNContactStore.requestAccess` was started.
        let wedged = StowerContactsAccess(
            status: { .notDetermined },
            request: {
                requestCallCount.withLock { $0 += 1 }
                return await withCheckedContinuation { (_: CheckedContinuation<Bool, Never>) in }
            },
            sleep: { _ in }
        )
        let model = makeViewModel(spy, contacts: wedged, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value

        model.resolveContactsAccess()
        await model.contactsTaskHandle?.value
        #expect(model.contactsBannerActionTitle == "Try Again")

        model.resolveContactsAccess()  // the "Try Again" tap
        await model.contactsTaskHandle?.value
        #expect(model.contactsBannerActionTitle == "Try Again")

        #expect(
            requestCallCount.withLock { $0 } == 1,
            "a retry must join the abandoned in-flight request, not start a second real request"
        )
    }

    @Test("cancelling before the timeout resolves suppresses the Try Again state")
    internal func cancelBeforeTimeoutSuppressesTimedOutState() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [oneRowBoard()]
        let wedged = StowerContactsAccess(
            status: { .notDetermined },
            request: { await withCheckedContinuation { (_: CheckedContinuation<Bool, Never>) in } },
            sleep: { _ in }
        )
        let model = makeViewModel(spy, contacts: wedged, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value

        model.resolveContactsAccess()
        model.cancel()  // the board disappears before the (instant) timeout resolves
        await model.contactsTaskHandle?.value

        #expect(
            model.contactsRequestTimedOut == false,
            "a cancelled attempt must not leave Try Again state behind for the next appearance"
        )
    }

    @Test("a grant arriving after cancel does not reload a board the user already left")
    internal func lateGrantAfterCancelDoesNotReload() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [oneRowBoard()]
        let gate = StowerLateGrantGate()
        let access = StowerContactsAccess(
            status: { .notDetermined },
            request: { await gate.waitForGrant() },
            sleep: { _ in }
        )
        let model = makeViewModel(spy, contacts: access, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value

        model.resolveContactsAccess()
        // The instant injected sleep times this out — resolveContactsAccess's
        // own task has already returned, so the eventual grant below is
        // genuinely late, exactly the scenario Bugbot flagged.
        await model.contactsTaskHandle?.value
        #expect(model.contactsBannerActionTitle == "Try Again")
        let loadCountBeforeCancel = spy.loadCallCount

        model.cancel()  // the user leaves the board

        await gate.grant(true)  // the OS call finally answers, after cancel()
        // The late-result callback runs on an unrelated task; poll briefly
        // rather than assume a fixed ordering with it.
        for _ in 0..<50 where spy.loadCallCount == loadCountBeforeCancel {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(
            spy.loadCallCount == loadCountBeforeCancel,
            "a grant arriving after cancel() must not reload a board the user already left"
        )
        // A cancelled outcome must skip syncing authorization too, not just the
        // reload — otherwise the banner hides (status flips to authorized)
        // while the rows were never actually reloaded with resolved names,
        // leaving stale handle-only rows on screen with nothing left to
        // prompt a retry (Bugbot: "Late grant skips board reload").
        #expect(
            model.contactsBannerActionTitle == "Try Again",
            "a cancelled outcome must not sync authorization and hide the banner without reloading"
        )
    }
}

/// Holds `request()` suspended until the test calls `grant`, so a real OS
/// answer arriving strictly after `cancel()` can be modeled deterministically.
private actor StowerLateGrantGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var pendingResult: Bool?

    func waitForGrant() async -> Bool {
        if let pendingResult {
            self.pendingResult = nil
            return pendingResult
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func grant(_ result: Bool) {
        if let continuation {
            continuation.resume(returning: result)
            self.continuation = nil
        } else {
            pendingResult = result
        }
    }
}
