import SwiftUI

/// The compact checking surface shown while startup resolves model availability
/// and then attempts the board load.
///
/// The sub-label tracks the phase ("Checking Apple Intelligence…" →
/// "Activating your license…" → "Checking Messages…"). The minimum on-screen
/// time that prevents a flash lives in `StowerStartupModel`, not here. The switch
/// is exhaustive (no `default:`) so a new state can't silently show stale copy.
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
        case .checkingModel:
            return "Checking Apple Intelligence…"
        case .checkingLicense:
            return "Activating your license…"
        case .checkingMessages:
            return "Checking Messages…"
        // The remaining states render their own screens, never this one; the
        // arm exists only so a future state is a compile error here, not a
        // silent mislabel.
        case .modelUnavailable, .needsLicense, .needsFullDiskAccess,
            .needsFullDiskAccessStillMissing, .connectedPreparingBoard, .failed:
            return "Checking Apple Intelligence…"
        }
    }
}
