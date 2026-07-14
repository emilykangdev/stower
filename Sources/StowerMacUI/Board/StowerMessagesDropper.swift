import AppKit

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
}

/// The "Reply in Messages" bridge: copy the draft and open the conversation,
/// leaving the compose field for the user to paste into manually.
///
/// App Sandbox blocks `CGEventPost` entirely, so Stower no longer posts a
/// synthetic ⌘V and no longer requests Accessibility at all (I5). The
/// clipboard write happens first and unconditionally, so the draft is never
/// stranded even when there's no deep link to open.
///
/// The effects run through an injected sink so tests use a spy and never write
/// the real pasteboard or open a real URL.
internal struct StowerMessagesDropper: Sendable {
    private let perform: @MainActor @Sendable (StowerMessagesDropEffect) -> Void

    /// Creates a dropper.
    ///
    /// - Parameter perform: Carries out one effect (defaults to the live AppKit
    ///   implementation; tests inject a recorder).
    internal init(
        perform: @escaping @MainActor @Sendable (StowerMessagesDropEffect) -> Void = {
            StowerMessagesDropper.performLive($0)
        }
    ) {
        self.perform = perform
    }

    /// Copies the draft and opens the conversation.
    ///
    /// - Parameters:
    ///   - text: The draft body to drop into Messages.
    ///   - deepLink: The conversation's `sms:` link; `nil` skips the open (the
    ///     clipboard write still happens, so the text is never stranded).
    @MainActor internal func drop(text: String, deepLink: URL?) {
        // Clipboard first — the guaranteed manual fallback, even if the row has no
        // deep link.
        perform(.copyToClipboard(text))
        guard let deepLink else { return }
        perform(.openConversation(deepLink))
    }

    @MainActor private static func performLive(_ effect: StowerMessagesDropEffect) {
        switch effect {
        case .copyToClipboard(let text):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .openConversation(let url):
            NSWorkspace.shared.open(url)
        }
    }
}
