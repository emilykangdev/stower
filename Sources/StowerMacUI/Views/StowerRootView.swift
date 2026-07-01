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

    /// Cached active-trial badge data, resolved when entering the board state.
    ///
    /// Nil means "no active trial" (paid/perpetual); it is NOT cleared on banner
    /// dismissal, so the gear-menu Buy path persists. Banner visibility is tracked
    /// separately by `trialBannerDismissed`.
    @State private var trialBadge: StowerTrialBadge?

    /// Whether the user has dismissed the trial banner this session.
    ///
    /// Seeded from the persisted dismissal flag on board entry. Hides the banner
    /// only; `trialBadge` — and therefore the gear-menu Buy — is unaffected.
    @State private var trialBannerDismissed = false

    /// Drives the one-time purchase-confirmation alert.
    @State private var showPurchaseThanks = false

    /// Guards the confirmation alert to once per session, so re-activations after a
    /// purchase don't re-show it (a fresh paid launch never triggers it — there is
    /// no trial→paid transition).
    @State private var purchaseThanksShown = false

    /// Whether the analytics disclosure card is currently showing.
    ///
    /// Set to `true` after ~60 seconds of foreground board time, once, if the
    /// card has never been shown. Cleared when the user makes a choice.
    @State private var showConsentCard = false
    @State private var consentCardTask: Task<Void, Never>?

    /// The consent state accessor shared by the disclosure card and the settings toggle.
    ///
    /// A single instance covers both surfaces so they never desync (the Keychain record
    /// is the underlying source of truth — shared across all readers).
    private let consent = StowerDiagnosticsConsent()

    private let settings: StowerSystemSettingsOpener

    /// The dismissal seam for the trial badge.
    ///
    /// Reads and writes the UserDefaults flag that hides the badge persistently
    /// across launches. The production path uses `UserDefaults.standard`; tests
    /// inject a fake.
    private let badgeDismissal: any StowerTrialBadgeDismissing

    /// Builds the production root wired to the shared engine-backed composition and
    /// the real Edge-Function-backed license gate.
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
            analyticsReporter: composition.analyticsReporter,
            licenseGate: StowerLicenseGate(reporter: composition.analyticsReporter),
            settings: StowerSystemSettingsOpener(),
            badgeDismissal: StowerUserDefaultsBadgeDismissal(),
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
        analyticsReporter: any StowerAnalyticsReporting = StowerNoOpAnalyticsReporter(),
        licenseGate: any StowerLicenseGating,
        settings: StowerSystemSettingsOpener = StowerSystemSettingsOpener(),
        badgeDismissal: any StowerTrialBadgeDismissing = StowerUserDefaultsBadgeDismissal(),
        flusher: StowerTerminationFlusher? = nil
    ) {
        let startupModel = StowerStartupModel(
            provider: startup,
            licenseGate: licenseGate,
            reporter: analyticsReporter
        )
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
            analyticsReporter: analyticsReporter,
            onFailure: { failure in startupModel.handleBoardFailure(failure) }
        )
        _boardModel = State(initialValue: boardModel)
        flusher?.onFlush { [weak boardModel] in await boardModel?.flushAll() }
        self.settings = settings
        self.badgeDismissal = badgeDismissal
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
        case .needsLicense(let context):
            StowerLicenseEntryView(
                context: context,
                onBuy: { openCheckout(licenseID: $0) },
                onRetry: { model.checkAgain() }
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
            ZStack(alignment: .bottom) {
                StowerBoardView(
                    model: boardModel,
                    trial: trialBadge,
                    showsTrialBanner: !trialBannerDismissed,
                    onBuy: { openCheckout(licenseID: $0) },
                    onDismissTrial: {
                        badgeDismissal.dismiss()
                        trialBannerDismissed = true
                    }
                )
                if showConsentCard {
                    StowerAnalyticsConsentCard { enabled in
                        StowerDiagnostics.setEnabled(enabled)
                        consent.markDisclosureShown()
                        showConsentCard = false
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: Self.crossFade), value: showConsentCard)
            .onAppear {
                trialBadge = model.trialBadge()
                trialBannerDismissed = badgeDismissal.isDismissed
                scheduleConsentCardIfNeeded()
            }
            // Leaving the board (or the app backgrounding) cancels the disclosure
            // countdown so it only accrues foreground board time (JC7).
            .onDisappear { consentCardTask?.cancel() }
            .onReceive(Self.willResignActive) { _ in consentCardTask?.cancel() }
            // Returning to the app (e.g. back from the Lemon Squeezy checkout)
            // re-checks the license so a completed purchase reflects instantly: the
            // refreshed lease clears the trial badge, and an expired trial routes to
            // the paywall — no full startup re-run, no "Loading Stower…" flash.
            .onReceive(Self.didBecomeActive) { _ in
                Task {
                    let wasTrial = trialBadge != nil
                    await model.refreshLicenseIfOnBoard()
                    trialBadge = model.trialBadge()
                    // Trial badge cleared while still on the board ⇒ the re-check
                    // picked up a completed purchase (paid licenses have no trial
                    // expiry). Confirm it explicitly, exactly once per session.
                    let purchaseDetected =
                        wasTrial && trialBadge == nil && !purchaseThanksShown
                        && model.state == .connectedPreparingBoard
                    if purchaseDetected {
                        purchaseThanksShown = true
                        showPurchaseThanks = true
                    }
                }
                // Re-arm the disclosure countdown for this foreground board session.
                scheduleConsentCardIfNeeded()
            }
            .alert(Self.purchaseThanksTitle, isPresented: $showPurchaseThanks) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(Self.purchaseThanksMessage)
            }
        case .failed(let failure):
            StowerFailureView(failure: failure, onRetry: { model.checkAgain() })
        }
    }

    /// Schedules the analytics consent card to appear after ~60 seconds of
    /// foreground board time, shown at most once ever (JC7).
    ///
    /// The countdown is cancelled when the app backgrounds or the board screen
    /// leaves the hierarchy, and rescheduled on return — so the card honors
    /// *foreground board* time, never firing while backgrounded or off-board.
    /// The shown-flag is stored in `UserDefaults` by `StowerDiagnosticsConsent` so
    /// the card never reappears after the user has made a choice.
    private func scheduleConsentCardIfNeeded() {
        guard !consent.hasShownDisclosure else { return }
        consentCardTask?.cancel()
        consentCardTask = Task { @MainActor in
            try? await Task.sleep(for: Self.consentCardDelay)
            guard !Task.isCancelled, !consent.hasShownDisclosure else { return }
            consent.markDisclosureShown()
            withAnimation { showConsentCard = true }
        }
    }

    /// Opens the Lemon Squeezy checkout bound to `licenseID`.
    ///
    /// The purchase webhook then upgrades this exact device license. A no-op if the
    /// URL won't build.
    private func openCheckout(licenseID: String) {
        guard let url = StowerLicenseCheckInClient.checkoutURL(licenseID: licenseID) else { return }
        NSWorkspace.shared.open(url)
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

    /// Fires when the app returns to the foreground; drives the on-board license
    /// re-check so a purchase completed in the browser reflects without a restart.
    private static let didBecomeActive = NotificationCenter.default.publisher(
        for: NSApplication.didBecomeActiveNotification
    )

    /// Fires when the app leaves the foreground; cancels the disclosure-card
    /// countdown so it accrues only foreground board time (JC7).
    private static let willResignActive = NotificationCenter.default.publisher(
        for: NSApplication.willResignActiveNotification
    )

    /// The Stower major a purchase unlocks — a placeholder string until real
    /// version wiring lands (the Sparkle work after this merges); matches the
    /// "Buy Stower v0" affordance the gear menu shows on an active trial.
    private static let purchasedVersionLabel = "v0"
    private static let purchaseThanksTitle = "Thank you for your purchase"
    private static let purchaseThanksMessage =
        "You've purchased the license for Stower \(purchasedVersionLabel). "
        + "Please check your email for the receipt."

    /// The delay before showing the analytics consent card after the board appears.
    ///
    /// ~60 seconds of foreground board time (JC7 — after the user has seen value,
    /// not at startup or at the FDA permission cliff).
    private static let consentCardDelay: Duration = .seconds(60)

    private static let minWidth: CGFloat = 520
    private static let minHeight: CGFloat = 360
    private static let crossFade: Double = 0.2
}
