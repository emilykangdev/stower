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
    @State private var licenseKey = ""
    private let settings: StowerSystemSettingsOpener

    /// Builds the production root wired to the shared engine-backed composition and
    /// the real Lemon Squeezy license gate.
    ///
    /// Throws only when an essential store can't be opened (a true disk-level draft
    /// store failure) — the same posture as any other essential-store startup fault.
    ///
    /// - Parameters:
    ///   - flusher: Wired to the board's `flushAll()` so the app delegate can drain
    ///     in-flight draft writes on quit. Optional so previews omit it.
    ///   - undoManager: The app-owned `UndoManager` (A4) the app target also binds ⌘Z
    ///     to; defaults to a fresh instance so previews/tests need not supply one.
    /// - Throws: When an essential store (the precious drafts database) can't be
    ///   opened on a true disk-level fault.
    public init(
        flusher: StowerTerminationFlusher? = nil,
        undoManager: UndoManager = UndoManager()
    ) throws {
        let composition = try StowerMessagesComposition()
        self.init(
            startup: composition.startup,
            board: composition.board,
            draftStore: composition.draftStore,
            interactions: composition.interactions,
            triage: composition.triageStore,
            undoManager: undoManager,
            dropper: composition.dropper,
            contacts: composition.contacts,
            licenseGate: StowerLemonSqueezyLicenseGate(),
            settings: StowerSystemSettingsOpener(),
            flusher: flusher
        )
    }

    /// Injects both boundaries plus the license gate (and optionally a Contacts
    /// access + settings opener) for tests and previews; production builds the
    /// boundaries from the shared composition.
    ///
    /// The board's `onFailure` is wired to `StowerStartupModel.handleBoardFailure`,
    /// so a mid-session board error re-enters onboarding rather than showing an
    /// empty board. `contacts` defaults to a denied no-op so previews/tests never
    /// prompt.
    internal init(
        startup: any StowerStartupProviding,
        board: any StowerBoardDataSource,
        draftStore: any StowerDraftStoring = StowerInMemoryDraftStore(),
        interactions: any StowerInteractionRecording = StowerNoOpInteractionRecorder(),
        triage: any StowerTriageStoring = StowerInMemoryTriageStore(),
        undoManager: UndoManager = UndoManager(),
        dropper: StowerMessagesDropper = StowerMessagesDropper(
            perform: { _ in },
            isAccessibilityTrusted: { false }
        ),
        contacts: StowerContactsAccess = .denied,
        licenseGate: any StowerLicenseGating,
        settings: StowerSystemSettingsOpener = StowerSystemSettingsOpener(),
        flusher: StowerTerminationFlusher? = nil
    ) {
        let startupModel = StowerStartupModel(provider: startup, licenseGate: licenseGate)
        _model = State(initialValue: startupModel)
        let boardModel = StowerBoardViewModel(
            dataSource: board,
            draftStore: draftStore,
            interactions: interactions,
            triage: triage,
            undoManager: undoManager,
            dropper: dropper,
            contacts: contacts,
            settings: settings,
            onFailure: { failure in startupModel.handleBoardFailure(failure) }
        )
        _boardModel = State(initialValue: boardModel)
        flusher?.onFlush { [weak boardModel] in await boardModel?.flushAll() }
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
        case .checkingModel, .checkingLicense, .checkingMessages:
            StowerCheckingView(state: model.state)
        case .needsLicense(let error):
            StowerLicenseEntryView(
                key: $licenseKey,
                error: error,
                onActivate: { model.submitLicense($0) }
            )
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
