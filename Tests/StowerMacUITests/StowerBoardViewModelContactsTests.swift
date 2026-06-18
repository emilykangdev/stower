import Foundation
import Testing

@testable import StowerMacUI

/// The board view-model's non-blocking Contacts-grant reload: a *fresh* grant on
/// appear reloads so the per-load resolver rebuilds and rows flip to names, while a
/// denial or an already-authorized launch issues no extra load.
///
/// Driven by `StowerSpyBoardDataSource` (no engine) and an injected
/// `StowerContactsAccess`, so no real `CNContactStore` is touched. The refresh
/// outcome is a judged-nothing completion, so the refresh loop never issues its own
/// reload — the only reload observed is the contacts-grant one.
@MainActor
@Suite internal struct StowerBoardViewModelContactsTests {
    /// Collects routed failures (none expected here; satisfies the VM's `onFailure`).
    private final class FailureRecorder {
        var failures: [StowerStartupFailure] = []
    }

    /// A one-row board, so `applyLoaded` reaches the in-context Contacts prompt
    /// (an empty board deliberately never prompts).
    private func oneRowBoard() -> StowerBoardModel {
        StowerBoardModel(
            neglected: [
                StowerBoardRow(
                    chatID: "a",
                    counterpart: "+14155550100",
                    counterpartHandle: "+14155550100",
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
        spy.refreshOutcomes = [.completed(reloadNeeded: false, anyJudged: false, hadRecords: false)]
        return StowerBoardViewModel(
            dataSource: spy,
            contacts: contacts,
            onFailure: { recorder.failures.append($0) },
            sleep: { _ in }
        )
    }

    /// Awaits the in-flight refresh and any reload it spawns, twice, to quiesce.
    private func settle(_ model: StowerBoardViewModel) async {
        for _ in 0..<2 {
            await model.refreshTaskHandle?.value
            await model.loadTaskHandle?.value
        }
    }

    @Test("a fresh Contacts grant when rows appear triggers exactly one extra reload")
    internal func contactsGrantReloads() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [oneRowBoard()]
        // Undetermined → the request fires and grants, so wasAuthorized == false.
        let granting = StowerContactsAccess(status: { .notDetermined }, request: { true })
        let model = makeViewModel(spy, contacts: granting, recorder: FailureRecorder())

        model.onAppear()
        await model.loadTaskHandle?.value
        await model.contactsTaskHandle?.value
        await settle(model)

        // Initial launch load + one reload from the grant.
        #expect(spy.loadCallCount == 2)
    }

    @Test("a denied Contacts access never triggers an extra reload when rows appear")
    internal func contactsDenialDoesNotReload() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [oneRowBoard()]
        let model = makeViewModel(spy, contacts: .denied, recorder: FailureRecorder())

        model.onAppear()
        await model.loadTaskHandle?.value
        await model.contactsTaskHandle?.value
        await settle(model)

        #expect(spy.loadCallCount == 1)
    }

    @Test("an already-authorized launch does not reload (names came on the first load)")
    internal func alreadyAuthorizedDoesNotReload() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [oneRowBoard()]
        let authorized = StowerContactsAccess(status: { .authorized }, request: { true })
        let model = makeViewModel(spy, contacts: authorized, recorder: FailureRecorder())

        model.onAppear()
        await model.loadTaskHandle?.value
        await model.contactsTaskHandle?.value
        await settle(model)

        #expect(spy.loadCallCount == 1)
    }
}
