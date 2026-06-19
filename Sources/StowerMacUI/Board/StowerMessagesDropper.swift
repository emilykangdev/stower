import AppKit
import ApplicationServices

/// One externally-observable effect of "Reply in Messages", in execution order.
///
/// The dropper emits these to an injected sink so a test can assert exactly what it
/// did — and, crucially, that there is no send/Return effect at all (I-NoAutoSend):
/// the set of cases is the structural guarantee that the bridge populates but never
/// sends.
internal enum StowerMessagesDropEffect: Equatable, Sendable {
    /// Write the draft body to the general pasteboard (the guaranteed fallback).
    case copyToClipboard(String)

    /// Open the conversation's Messages deep link.
    case openConversation(URL)

    /// Lazily request Accessibility (first intent), staying copy-only until granted.
    case requestAccessibility

    /// Post a synthetic ⌘V into the frontmost Messages compose field. NEVER a Return.
    case pasteIntoMessages
}

/// The "Reply in Messages" bridge: copy the draft, open the conversation, and —
/// when Accessibility is granted — auto-paste the draft into the compose field,
/// leaving it populated but UNSENT.
///
/// Stower is a non-sandboxed Developer-ID app, so it may post a synthetic ⌘V via
/// `CGEvent` once granted Accessibility. The clipboard write happens first and
/// unconditionally, so a denied or misfired paste degrades to a manual ⌘V — never a
/// lost draft (A7). It posts ONLY ⌘V, never a Return, so a misfire can never send.
///
/// The effects run through an injected sink so tests use a spy and never write the
/// real pasteboard or post real keystrokes.
internal struct StowerMessagesDropper: Sendable {
    private let perform: @MainActor @Sendable (StowerMessagesDropEffect) -> Void
    private let isAccessibilityTrusted: @Sendable () -> Bool

    /// Creates a dropper.
    ///
    /// - Parameters:
    ///   - perform: Carries out one effect (defaults to the live AppKit/CGEvent
    ///     implementation; tests inject a recorder).
    ///   - isAccessibilityTrusted: Whether the process may post synthetic events
    ///     (defaults to `AXIsProcessTrusted()`).
    internal init(
        perform: @escaping @MainActor @Sendable (StowerMessagesDropEffect) -> Void = {
            StowerMessagesDropper.performLive($0)
        },
        isAccessibilityTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.perform = perform
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    /// Copies the draft, opens the conversation, and best-effort auto-pastes it.
    ///
    /// - Parameters:
    ///   - text: The draft body to drop into Messages.
    ///   - deepLink: The conversation's `sms:` link; `nil` skips open + paste (the
    ///     clipboard write still happens, so the text is never stranded).
    @MainActor internal func drop(text: String, deepLink: URL?) {
        // Clipboard first — the guaranteed manual fallback, even if the row has no
        // deep link or everything below misfires.
        perform(.copyToClipboard(text))
        guard let deepLink else { return }
        perform(.openConversation(deepLink))
        guard isAccessibilityTrusted() else {
            // Lazily ask for Accessibility on first intent (JC7); copy-only until then.
            perform(.requestAccessibility)
            return
        }
        perform(.pasteIntoMessages)
    }

    /// The 'v' virtual key code, for the synthetic ⌘V.
    private static let vKeyCode: CGKeyCode = 9

    /// The Accessibility-prompt option key (the literal value of the non-Sendable
    /// `kAXTrustedCheckOptionPrompt` global).
    private static let axTrustedPromptOption = "AXTrustedCheckOptionPrompt"

    /// A beat for Messages to come frontmost after the deep link opens, so the
    /// synthetic paste lands in its compose field and not in Stower.
    private static let pasteDelay: Duration = .milliseconds(200)

    /// Messages' bundle identifier, the only app a synthetic paste may target.
    private static let messagesBundleID = "com.apple.MobileSMS"

    @MainActor private static func performLive(_ effect: StowerMessagesDropEffect) {
        switch effect {
        case .copyToClipboard(let text):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .openConversation(let url):
            NSWorkspace.shared.open(url)
        case .requestAccessibility:
            // The literal value of `kAXTrustedCheckOptionPrompt` (a non-Sendable
            // global under Swift 6); using the string avoids the concurrency error.
            let options = [Self.axTrustedPromptOption: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .pasteIntoMessages:
            Task { @MainActor in
                try? await Task.sleep(for: Self.pasteDelay)
                // Only paste if Messages actually came frontmost. If the open was slow
                // or another app stole focus, the private draft must NOT land in the
                // wrong app — the clipboard already holds it, so this degrades to a
                // manual ⌘V into Messages, never a leak.
                guard
                    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                        == Self.messagesBundleID
                else {
                    return
                }
                Self.postCommandV()
            }
        }
    }

    /// Posts a synthetic ⌘V key-down/up.
    ///
    /// Posts ONLY ⌘V — never a Return — so a misfire can populate the wrong field but
    /// can never send a message.
    @MainActor private static func postCommandV() {
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.vKeyCode,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.vKeyCode,
                keyDown: false
            )
        else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
