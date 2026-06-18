import AppKit
import SwiftUI

/// The app's whole composition API: a public, no-argument root view.
///
/// `init()` builds the shared `StowerMessagesComposition` — ONE
/// `StowerDebtBoardProvider` injected into both the startup adapter and the board
/// adapter — and owns the `StowerStartupModel` and `StowerBoardViewModel` as
/// `@State` so the screen switch never reconstructs them. The app target
/// (`StowerMac`) imports only `StowerMacUI` — never the adapters, the provider, or
/// `StowerMessages`. It switches on the startup state, cross-fading between
/// screens, hands off to the board at `.connectedPreparingBoard`, and reruns the
/// flow on Check Again.
public struct StowerRootView: View {
    @State private var model: StowerStartupModel
    @State private var boardModel: StowerBoardViewModel
    private let settings: StowerSystemSettingsOpener

    /// Builds the production root wired to the shared engine-backed composition.
    public init() {
        let composition = StowerMessagesComposition()
        self.init(
            startup: composition.startup,
            board: composition.board,
            contacts: composition.contacts,
            settings: StowerSystemSettingsOpener()
        )
    }

    /// Injects both boundaries (and optionally a Contacts access + settings opener)
    /// for tests and previews; production builds them from the shared composition.
    ///
    /// The board's `onFailure` is wired to `StowerStartupModel.handleBoardFailure`,
    /// so a mid-session board error re-enters onboarding rather than showing an
    /// empty board. `contacts` defaults to a denied no-op so previews/tests never
    /// prompt.
    internal init(
        startup: any StowerStartupProviding,
        board: any StowerBoardDataSource,
        contacts: StowerContactsAccess = .denied,
        settings: StowerSystemSettingsOpener = StowerSystemSettingsOpener()
    ) {
        let startupModel = StowerStartupModel(provider: startup)
        _model = State(initialValue: startupModel)
        _boardModel = State(
            initialValue: StowerBoardViewModel(
                dataSource: board,
                contacts: contacts,
                settings: settings,
                onFailure: { failure in startupModel.handleBoardFailure(failure) }
            )
        )
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
            StowerBoardView(model: boardModel)
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
