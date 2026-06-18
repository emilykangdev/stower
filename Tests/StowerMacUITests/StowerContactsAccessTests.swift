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
    internal func promptsWhenNotDetermined() async {
        let spy = RequestSpy(result: true)
        let access = StowerContactsAccess(status: { .notDetermined }, request: { await spy.fire() })
        let granted = await access.requestAccessIfNeeded()
        #expect(granted)
        #expect(await spy.callCount == 1)
    }

    @Test("a denied prompt result is returned, still from a single request")
    internal func promptCanReturnDenied() async {
        let spy = RequestSpy(result: false)
        let access = StowerContactsAccess(status: { .notDetermined }, request: { await spy.fire() })
        let granted = await access.requestAccessIfNeeded()
        #expect(granted == false)
        #expect(await spy.callCount == 1)
    }

    @Test("authorized returns true and never re-prompts")
    internal func authorizedNeverPrompts() async {
        let spy = RequestSpy(result: false)
        let access = StowerContactsAccess(status: { .authorized }, request: { await spy.fire() })
        #expect(access.isAuthorized)
        #expect(await access.requestAccessIfNeeded())
        #expect(await spy.callCount == 0)
    }

    @Test("denied and restricted return false and never re-prompt")
    internal func terminalDenialNeverPrompts() async {
        for status in [CNAuthorizationStatus.denied, .restricted] {
            let spy = RequestSpy(result: true)
            let access = StowerContactsAccess(status: { status }, request: { await spy.fire() })
            #expect(access.isAuthorized == false)
            #expect(await access.requestAccessIfNeeded() == false)
            #expect(await spy.callCount == 0)
        }
    }
}
