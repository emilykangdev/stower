import SwiftUI

/// The compact checking surface shown while startup resolves model availability
/// and then attempts the board load.
///
/// The sub-label tracks the phase ("Checking Apple Intelligence…" →
/// "Checking Messages…"). The minimum on-screen time that prevents a flash lives
/// in `StowerStartupModel`, not here.
internal struct StowerCheckingView: View {
    internal let state: StowerStartupState

    internal var body: some View {
        StowerOnboardingPane(title: "Setting up Stower", message: subLabel) {
            ProgressView()
                .controlSize(.large)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private var subLabel: String {
        switch state {
        case .checkingMessages:
            return "Checking Messages…"
        default:
            return "Checking Apple Intelligence…"
        }
    }
}
