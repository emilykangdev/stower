import SwiftUI

/// The reason-specific "this Mac can't run it (yet)" screen.
///
/// Each of the four `StowerStartupModelUnavailableReason` values gets its own
/// treatment: `deviceNotEligible` is the one terminal dead end (no retry); the
/// others offer a deep link or a Check Again. See the four-reasons table in the
/// FDA-onboarding plan — the single source for this copy's intent.
internal struct StowerModelUnavailableView: View {
    internal let reason: StowerStartupModelUnavailableReason
    internal let onCheckAgain: () -> Void
    internal let onOpenAppleIntelligence: () -> Void

    internal var body: some View {
        StowerOnboardingPane(title: title, message: message) {
            StowerPaneIcon(iconName, tint: .secondary)
        } actions: {
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        switch reason {
        case .deviceNotEligible:
            EmptyView()
        case .appleIntelligenceNotEnabled:
            VStack(spacing: Self.actionSpacing) {
                Button("Open System Settings", action: onOpenAppleIntelligence)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Check Again", action: onCheckAgain)
                    .buttonStyle(.bordered)
            }
        case .modelNotReady, .unknown:
            Button("Check Again", action: onCheckAgain)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var iconName: String {
        switch reason {
        case .deviceNotEligible: return "xmark.circle"
        case .appleIntelligenceNotEnabled: return "apple.logo"
        case .modelNotReady: return "arrow.down.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    private var title: String {
        switch reason {
        case .deviceNotEligible: return "This Mac can't run Stower"
        case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence"
        case .modelNotReady: return "Apple Intelligence is still getting ready"
        case .unknown: return "On-device model unavailable"
        }
    }

    private var message: String {
        switch reason {
        case .deviceNotEligible:
            return "Stower runs entirely on-device and needs a Mac with Apple Intelligence "
                + "on macOS 26 or later."
        case .appleIntelligenceNotEnabled:
            return "Stower uses Apple's on-device model to judge your conversations. Turn on "
                + "Apple Intelligence in System Settings, then check again."
        case .modelNotReady:
            return "Apple Intelligence is still downloading or preparing on this Mac. Stower "
                + "will work as soon as it's ready."
        case .unknown:
            return "Stower couldn't reach the on-device model. Try again in a moment, or "
                + "contact support if this keeps happening."
        }
    }

    private static let actionSpacing: CGFloat = 8
}
