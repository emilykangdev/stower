import Foundation
import Synchronization
import Testing

@testable import StowerMacUI

/// "Reply in Messages" populates but NEVER sends (I-NoAutoSend).
///
/// The dropper's effects are recorded through an injected sink, so this asserts
/// exactly what it does — clipboard first (the guaranteed fallback), then open —
/// and that no send/Return/paste effect exists at all (I5). The
/// `StowerMessagesDropEffect` enum has no send/paste case, so "never sends,
/// never auto-pastes" is structural (App Sandbox blocks `CGEventPost` outright);
/// the precheck grep covers the code level (no AppleScript/IMCore/Return).
@MainActor
@Suite internal struct StowerMessagesDropperTests {
    @Test("(I5) copies then opens the conversation — never a send or auto-paste")
    internal func dropsWithDeepLink() throws {
        let effects = Mutex<[StowerMessagesDropEffect]>([])
        let dropper = StowerMessagesDropper(
            perform: { effect in effects.withLock { $0.append(effect) } }
        )
        let url = try #require(URL(string: "sms:+15551234567"))

        dropper.drop(text: "hi there", deepLink: url)

        #expect(
            effects.withLock { $0 } == [
                .copyToClipboard("hi there"),
                .openConversation(url)
            ]
        )
    }

    @Test("a nil deep link still copies to the clipboard (fallback) and stops")
    internal func nilDeepLinkCopiesOnly() {
        let effects = Mutex<[StowerMessagesDropEffect]>([])
        let dropper = StowerMessagesDropper(
            perform: { effect in effects.withLock { $0.append(effect) } }
        )

        dropper.drop(text: "stranded?", deepLink: nil)

        #expect(effects.withLock { $0 } == [.copyToClipboard("stranded?")])
    }
}
