import AppKit
import SwiftUI

/// The app's whole composition API: a public, no-argument root view.
///
/// `init()` builds the real `StowerMessagesStartupAdapter` and owns the
/// `StowerStartupModel`, so the app target (`StowerMac`) imports only
/// `StowerMacUI` — never the adapter, the provider, or `StowerMessages`. It
/// switches on the startup state, cross-fading between screens, and reruns the
/// flow on Check Again.
public struct StowerRootView: View {
    @State private var model: StowerStartupModel
    private let settings: StowerSystemSettingsOpener

    /// Builds the production root wired to the real engine-backed provider.
    public init() {
        self.init(
            provider: StowerMessagesStartupAdapter(),
            settings: StowerSystemSettingsOpener()
        )
    }

    /// Injects a provider (and optionally a settings opener) for tests/previews.
    internal init(
        provider: any StowerStartupProviding,
        settings: StowerSystemSettingsOpener = StowerSystemSettingsOpener()
    ) {
        _model = State(initialValue: StowerStartupModel(provider: provider))
        self.settings = settings
    }

    /// The startup screen for the current state, cross-fading on change.
    public var body: some View {
        screen
            .frame(minWidth: Self.minWidth, minHeight: Self.minHeight)
            .animation(.easeInOut(duration: Self.crossFade), value: model.state)
            .task { model.start() }
            .onDisappear { model.cancel() }
    }

    @ViewBuilder private var screen: some View {
        switch model.state {
        case .checkingModel, .checkingMessages:
            StowerCheckingView(state: model.state)
        case .modelUnavailable(let reason):
            StowerModelUnavailableView(
                reason: reason,
                onCheckAgain: { model.checkAgain() },
                onOpenAppleIntelligence: { settings.openPane(.appleIntelligence) }
            )
        case .needsFullDiskAccess(let path):
            fdaView(path: path, stillMissing: false)
        case .needsFullDiskAccessStillMissing(let path):
            fdaView(path: path, stillMissing: true)
        case .connectedPreparingBoard:
            StowerConnectedLoadingView()
        case .failed(let failure):
            StowerFailureView(failure: failure, onRetry: { model.checkAgain() })
        }
    }

    private func fdaView(path: String, stillMissing: Bool) -> some View {
        StowerFDAOnboardingView(
            path: path,
            stillMissing: stillMissing,
            onOpenSettings: { settings.openPane(.fullDiskAccess) },
            onCheckAgain: { model.checkAgain() },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
    }

    private static let minWidth: CGFloat = 520
    private static let minHeight: CGFloat = 360
    private static let crossFade: Double = 0.2
}
