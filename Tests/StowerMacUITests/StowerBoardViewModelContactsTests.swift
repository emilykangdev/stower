import Foundation
import StowerMessages
import Synchronization
import Testing

@testable import StowerMacUI

/// The board view-model's Contacts-access affordance: a durable banner shown above
/// the board whenever it has rows but Contacts isn't authorized, and the banner
/// action that either raises the system prompt (never asked) or routes to System
/// Settings (denied) — and reloads into names on a fresh grant.
///
/// Driven by `StowerSpyBoardDataSource` (no engine) plus an injected
/// `StowerContactsAccess` and a recording `StowerSystemSettingsOpener`, so no real
/// `CNContactStore` and no real System Settings are touched.
@MainActor
@Suite internal struct StowerBoardViewModelContactsTests {
    /// Collects routed failures (none expected here; satisfies the VM's `onFailure`).
    private final class FailureRecorder {
        var failures: [StowerStartupFailure] = []
    }

    /// Records every URL an opener was asked to open, returning a scriptable result.
    private final class OpenedURLRecorder {
        private(set) var opened: [URL] = []
        var result = true

        func record(_ url: URL) -> Bool {
            opened.append(url)
            return result
        }
    }

    private var emptyModel: StowerBoardModel { StowerBoardModel(neglected: [], ghosted: []) }

    /// A one-row board, so a loaded board reaches `.rows` (the banner's precondition).
    private func oneRowBoard() -> StowerBoardModel {
        StowerBoardModel(
            neglected: [
                StowerBoardRow(
                    chatID: "a",
                    counterpart: "+14155550100",
                    counterpartHandle: "+14155550100",
                    draftKey: StowerDraftKey.derive(forHandle: "+14155550100"),
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
        settings: StowerSystemSettingsOpener = StowerSystemSettingsOpener(open: { _ in true }),
        recorder: FailureRecorder
    ) -> StowerBoardViewModel {
        StowerBoardViewModel(
            dataSource: spy,
            contacts: contacts,
            settings: settings,
            onFailure: { recorder.failures.append($0) },
            sleep: { _ in }
        )
    }

    @Test("the banner shows when the board has rows and Contacts is not authorized")
    internal func bannerShowsWhenUnauthorizedWithRows() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [oneRowBoard()]
        let denied = StowerContactsAccess(status: { .denied }, request: { false })
        let model = makeViewModel(spy, contacts: denied, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value

        #expect(model.phase == .rows)
        #expect(model.showsContactsAccessBanner)
    }

    @Test("the banner is hidden once Contacts is authorized")
    internal func bannerHiddenWhenAuthorized() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [oneRowBoard()]
        let authorized = StowerContactsAccess(status: { .authorized }, request: { true })
        let model = makeViewModel(spy, contacts: authorized, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value

        #expect(model.showsContactsAccessBanner == false)
    }

    @Test("the banner is hidden when there are no rows to label")
    internal func bannerHiddenWhenNoRows() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [emptyModel]
        let denied = StowerContactsAccess(status: { .denied }, request: { false })
        let model = makeViewModel(spy, contacts: denied, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value

        #expect(model.phase != .rows)
        #expect(model.showsContactsAccessBanner == false)
    }

    @Test("a never-asked banner action requests and reloads on a fresh grant")
    internal func notDeterminedActionRequestsAndReloads() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [oneRowBoard()]
        let granting = StowerContactsAccess(status: { .notDetermined }, request: { true })
        let model = makeViewModel(spy, contacts: granting, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        #expect(model.contactsBannerActionTitle == "Show names")

        model.resolveContactsAccess()
        await model.contactsTaskHandle?.value
        await model.loadTaskHandle?.value

        // Initial load + one reload from the grant.
        #expect(spy.loadCallCount == 2)
    }

    @Test("denying the in-app prompt flips the banner action to Open Settings")
    internal func denyingPromptFlipsToSettings() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [oneRowBoard()]
        // Status is .notDetermined until asked, then .denied; the request denies.
        let asked = Mutex(false)
        let access = StowerContactsAccess(
            status: { asked.withLock { $0 } ? .denied : .notDetermined },
            request: {
                asked.withLock { $0 = true }
                return false
            }
        )
        let model = makeViewModel(spy, contacts: access, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        #expect(model.contactsBannerActionTitle == "Show names")

        model.resolveContactsAccess()
        await model.contactsTaskHandle?.value

        // Status moved to denied; the banner stays but its action now routes to Settings.
        #expect(model.contactsBannerActionTitle == "Open Settings")
        #expect(model.showsContactsAccessBanner)
        #expect(spy.loadCallCount == 1)  // deny does not reload
    }

    @Test("a denied banner action opens the Contacts Settings pane and never reloads")
    internal func deniedActionOpensSettings() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [oneRowBoard()]
        let denied = StowerContactsAccess(status: { .denied }, request: { false })
        let recorder = OpenedURLRecorder()
        let model = makeViewModel(
            spy,
            contacts: denied,
            settings: StowerSystemSettingsOpener(open: { recorder.record($0) }),
            recorder: FailureRecorder()
        )

        model.load()
        await model.loadTaskHandle?.value
        #expect(model.contactsBannerActionTitle == "Open Settings")

        model.resolveContactsAccess()

        #expect(recorder.opened.first == StowerSystemSettingsOpener.paneURL(for: .contacts))
        #expect(model.contactsTaskHandle == nil)  // denied takes no async path
        #expect(spy.loadCallCount == 1)  // no reload yet — recovery happens on re-activation
    }

    @Test("granting in Settings then returning to the app reloads into names")
    internal func recoversAfterSettingsGrant() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [oneRowBoard()]
        // Status flips denied -> authorized to model the grant made in System Settings.
        let granted = Mutex(false)
        let access = StowerContactsAccess(
            status: { granted.withLock { $0 } ? .authorized : .denied },
            request: { false }
        )
        let model = makeViewModel(spy, contacts: access, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        #expect(model.showsContactsAccessBanner)  // denied + rows

        model.resolveContactsAccess()  // opens Settings, arms recovery
        granted.withLock { $0 = true }  // user grants in Settings
        model.onAppBecameActive()  // returns to the app
        await model.loadTaskHandle?.value

        #expect(spy.loadCallCount == 2)  // recovery reload fired
        #expect(model.showsContactsAccessBanner == false)  // now authorized

        // A second activation does not reload again (recovery was one-shot).
        model.onAppBecameActive()
        await model.loadTaskHandle?.value
        #expect(spy.loadCallCount == 2)
    }

    @Test("revoking access in Settings drops resolved names on return (no stale names)")
    internal func revokeReplacesNamesWithHandles() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [oneRowBoard()]
        let authorized = Mutex(true)
        let access = StowerContactsAccess(
            status: { authorized.withLock { $0 } ? .authorized : .denied },
            request: { true }
        )
        let model = makeViewModel(spy, contacts: access, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        #expect(model.showsContactsAccessBanner == false)  // authorized: no banner

        authorized.withLock { $0 = false }  // user revokes Contacts in Settings
        model.onAppBecameActive()
        await model.loadTaskHandle?.value

        #expect(spy.loadCallCount == 2)  // reloaded so names don't linger
        #expect(model.showsContactsAccessBanner)  // banner returns
    }

    @Test("revocation bumps the token so the board view can dismiss an open thread")
    internal func revocationBumpsThreadDismissalToken() async {
        let spy = StowerSpyBoardDataSource()
        spy.loadModels = [oneRowBoard()]
        let authorized = Mutex(true)
        let access = StowerContactsAccess(
            status: { authorized.withLock { $0 } ? .authorized : .denied },
            request: { true }
        )
        let model = makeViewModel(spy, contacts: access, recorder: FailureRecorder())

        model.load()
        await model.loadTaskHandle?.value
        let tokenBefore = model.contactsRevocationToken

        authorized.withLock { $0 = false }  // revoke
        model.onAppBecameActive()
        await model.loadTaskHandle?.value
        #expect(model.contactsRevocationToken == tokenBefore + 1)

        // A grant (non-authorized → authorized) does NOT bump the dismissal token.
        authorized.withLock { $0 = true }
        model.onAppBecameActive()
        await model.loadTaskHandle?.value
        #expect(model.contactsRevocationToken == tokenBefore + 1)
    }
}
