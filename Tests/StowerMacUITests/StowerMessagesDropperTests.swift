import Foundation
import Synchronization
import Testing

@testable import StowerMacUI

/// "Reply in Messages" populates but NEVER sends (I-NoAutoSend).
///
/// The dropper's effects are recorded through an injected sink, so these assert
/// exactly what it does — clipboard first (the guaranteed fallback), open, then a
/// paste only when Accessibility is granted — and that no send/Return effect exists
/// at all. The `StowerMessagesDropEffect` enum has no send case, so "never sends" is
/// structural; the precheck grep covers the code level (no AppleScript/IMCore/Return).
@MainActor
@Suite internal struct StowerMessagesDropperTests {
    @Test("granted: copies, opens, and pastes — never a send (I-NoAutoSend)")
    internal func grantedDrops() throws {
        let effects = Mutex<[StowerMessagesDropEffect]>([])
        let dropper = StowerMessagesDropper(
            perform: { effect in effects.withLock { $0.append(effect) } },
            isAccessibilityTrusted: { true }
        )
        let url = try #require(URL(string: "sms:+15551234567"))

        dropper.drop(text: "hi there", deepLink: url)

        #expect(
            effects.withLock { $0 } == [
                .copyToClipboard("hi there"),
                .openConversation(url),
                .pasteIntoMessages
            ]
        )
    }

    @Test("denied: copies, opens, and requests Accessibility — never pastes (I-NoAutoSend)")
    internal func deniedDrops() throws {
        let effects = Mutex<[StowerMessagesDropEffect]>([])
        let dropper = StowerMessagesDropper(
            perform: { effect in effects.withLock { $0.append(effect) } },
            isAccessibilityTrusted: { false }
        )
        let url = try #require(URL(string: "sms:+15551234567"))

        dropper.drop(text: "draft", deepLink: url)

        #expect(
            effects.withLock { $0 } == [
                .copyToClipboard("draft"),
                .openConversation(url),
                .requestAccessibility
            ]
        )
        #expect(effects.withLock { $0 }.contains(.pasteIntoMessages) == false)
    }

    @Test("a nil deep link still copies to the clipboard (fallback) and stops")
    internal func nilDeepLinkCopiesOnly() {
        let effects = Mutex<[StowerMessagesDropEffect]>([])
        let dropper = StowerMessagesDropper(
            perform: { effect in effects.withLock { $0.append(effect) } },
            isAccessibilityTrusted: { true }
        )

        dropper.drop(text: "stranded?", deepLink: nil)

        #expect(effects.withLock { $0 } == [.copyToClipboard("stranded?")])
    }
}
