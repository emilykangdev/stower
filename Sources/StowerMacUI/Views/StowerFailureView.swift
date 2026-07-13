import SwiftUI

/// The app-owned failure screen for non-messages-access, non-model failures.
///
/// Copy is derived per error family — never a raw engine string — and the screen
/// always offers a retry, because `.failed` means "something went wrong this run,"
/// not "you can't use Stower." The messages-access and model-unavailable cases
/// never route here; they are handled with a generic recovery message
/// defensively.
internal struct StowerFailureView: View {
    internal let failure: StowerStartupFailure
    internal let onRetry: () -> Void

    internal var body: some View {
        StowerOnboardingPane(title: title, message: message) {
            StowerPaneIcon("exclamationmark.octagon", tint: .secondary)
        } actions: {
            Button("Check Again", action: onRetry)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var title: String {
        switch failure {
        case .sourceMissing:
            return "Messages isn't set up on this Mac"
        case .invalidConfig:
            return "Something's misconfigured"
        case .unreadable, .invalidData:
            return "Couldn't read your Messages"
        case .messagesAccessMissing, .modelUnavailable, .unexpected:
            return "Something went wrong"
        }
    }

    private var message: String {
        switch failure {
        case .sourceMissing:
            return "Stower couldn't find a Messages library on this Mac. Open Messages and "
                + "sign in, then check again."
        case .invalidConfig:
            return "This looks like a problem on our end, not yours. Try again, and contact "
                + "support if it persists."
        case .unreadable:
            return "Stower reached your Messages data but couldn't read it. Try again in a "
                + "moment."
        case .invalidData:
            return "Stower reached your Messages data but it looked malformed. Try again in a "
                + "moment."
        case .messagesAccessMissing, .modelUnavailable, .unexpected:
            return "Stower hit an unexpected problem during startup. Try again, and contact "
                + "support if it keeps happening."
        }
    }
}
