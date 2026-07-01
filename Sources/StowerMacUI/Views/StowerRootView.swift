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

    /// The typed text in the key-entry screen; a `@State` on the stable root so
    /// it survives an in-flight activate and any error re-render.
    @State private var licenseKey = ""

    /// Cached active-trial badge data, resolved when entering the board state.
    ///
    /// Nil means "no active trial" (licensed, or expired); it is NOT cleared on
    /// banner dismissal, so the gear-menu Buy/Enter-key path persists.
    @State private var trialBadge: StowerTrialBadge?

    /// Whether the user has dismissed the (pre-F3) trial banner this session.
    ///
    /// Seeded from the persisted dismissal flag on board entry. Only suppresses
    /// the `.trialBadge` banner state — F2/F3 are never suppressed by this flag,
    /// since they are higher-intent moments than the quiet status badge.
    @State private var trialBannerDismissed = false

    /// F2: set when the user taps Buy; cleared once a license is stored.
    ///
    /// Drives the "Finished your purchase? Enter the license key" banner on
    /// return.
    @State private var boughtThisSession = false

    /// Drives the F1 purchase-confirmation alert.
    @State private var showPurchaseThanks = false

    /// Whether the analytics disclosure card is currently showing.
    ///
    /// Set to `true` after ~60 seconds of foreground board time, once, if the
    /// card has never been shown. Cleared when the user makes a choice.
    @State private var showConsentCard = false
    @State private var consentCardTask: Task<Void, Never>?

    /// Sleeps until the active trial's `expiry`, then re-checks the license so
    /// a continuously-foregrounded session (never backgrounded/foregrounded
    /// again) still routes to the paywall the moment the 7-day trial elapses,
    /// instead of only on the next `didBecomeActive`.
    @State private var trialExpiryTask: Task<Void, Never>?

    /// The consent state accessor shared by the disclosure card and the settings toggle.
    ///
    /// A single instance covers both surfaces so they never desync (the Keychain record
    /// is the underlying source of truth — shared across all readers).
    private let consent = StowerDiagnosticsConsent()

    private let settings: StowerSystemSettingsOpener
    private let analyticsReporter: any StowerAnalyticsReporting

    /// The dismissal seam for the trial badge.
    ///
    /// Reads and writes the UserDefaults flag that hides the (pre-F3) badge
    /// persistently across launches. The production path uses
    /// `UserDefaults.standard`; tests inject a fake.
    private let badgeDismissal: any StowerTrialBadgeDismissing

    /// Builds the production root wired to the shared engine-backed composition and
    /// the real Lemon-Squeezy-backed license gate.
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
            licenseGate: StowerLemonSqueezyLicenseGate(),
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
        self.analyticsReporter = analyticsReporter
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
        case .needsLicense(let error):
            StowerLicenseEntryView(
                key: $licenseKey,
                error: error,
                onActivate: { activate(key: $0) },
                onBuy: { openCheckout() },
                isActivating: model.isActivating
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
                    bannerState: currentBannerState,
                    onBuy: { openCheckout() },
                    onEnterKey: { jumpToKeyEntry() },
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
                scheduleTrialExpiryRecheckIfNeeded()
            }
            // Leaving the board (or the app backgrounding) cancels the disclosure
            // countdown so it only accrues foreground board time (JC7), and the
            // trial-expiry timer (re-armed on the next appear/foreground instead).
            .onDisappear {
                consentCardTask?.cancel()
                trialExpiryTask?.cancel()
            }
            .onReceive(Self.willResignActive) { _ in consentCardTask?.cancel() }
            // Returning to the app (e.g. back from the Lemon Squeezy checkout)
            // re-checks the license so an elapsed trial reflects instantly — a
            // pure local read (no network); activation itself only happens when
            // the user pastes the key and taps Activate (JC3).
            .onReceive(Self.didBecomeActive) { _ in
                Task {
                    await model.refreshLicenseIfOnBoard()
                    trialBadge = model.trialBadge()
                    scheduleTrialExpiryRecheckIfNeeded()
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

    /// The board's current bottom-banner state (F2/F3), recomputed on every
    /// render from the cached trial badge, the F2 session flag, and whether the
    /// pre-F3 badge has been dismissed.
    ///
    /// The board is reached only when licensed or on an active trial, so a nil
    /// `trialBadge` here always means licensed.
    private var currentBannerState: StowerBoardBannerState {
        let resolved = StowerBoardBannerState.resolve(
            hasStoredLicense: trialBadge == nil,
            boughtThisSession: boughtThisSession,
            trialBadge: trialBadge,
            now: Date()
        )
        // The quiet trial badge alone (not F2/F3) honors the dismiss flag.
        if case .trialBadge = resolved, trialBannerDismissed {
            return .none
        }
        return resolved
    }

    /// Activates `key` via the model, then — on success — jumps straight to the
    /// F1 confirmation alert (the model's `.activate` reruns startup into the
    /// board).
    private func activate(key: String) {
        Task {
            await model.activate(key: key)
            await model.activeRun?.value
            if model.state == .connectedPreparingBoard {
                licenseKey = ""
                boughtThisSession = false
                showPurchaseThanks = true
            }
        }
    }

    /// Jumps to the key-entry screen from the board (gear menu / F2 banner,
    /// JC5) without waiting for the trial to expire.
    private func jumpToKeyEntry() {
        model.showLicenseEntry()
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

    /// Sleeps until `trialBadge.expiry`, then re-checks the license so the
    /// board routes to the paywall the moment the trial elapses even if the
    /// app stays foregrounded the whole time (no intervening `didBecomeActive`).
    ///
    /// A no-op when licensed (`trialBadge == nil`) or already past expiry —
    /// the next foreground/appear re-check handles that case. Re-armed on
    /// every appear/foreground so the sleep duration is always fresh.
    private func scheduleTrialExpiryRecheckIfNeeded() {
        trialExpiryTask?.cancel()
        guard let expiry = trialBadge?.expiry, expiry > Date() else { return }
        trialExpiryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(expiry.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            await model.refreshLicenseIfOnBoard()
            trialBadge = model.trialBadge()
        }
    }

    /// Opens the static Lemon Squeezy checkout URL and sets the F2 session flag.
    ///
    /// A return to the app with no license yet stored then shows the "Enter
    /// license key" banner. A no-op if the configured URL won't build (fails
    /// closed rather than opening a malformed URL).
    private func openCheckout() {
        guard let url = URL(string: StowerLicenseConfig.resolved.checkoutURL) else { return }
        boughtThisSession = true
        analyticsReporter.report(.checkoutOpened)
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
    /// re-check so an elapsed trial reflects without a restart.
    private static let didBecomeActive = NotificationCenter.default.publisher(
        for: NSApplication.didBecomeActiveNotification
    )

    /// Fires when the app leaves the foreground; cancels the disclosure-card
    /// countdown so it accrues only foreground board time (JC7).
    private static let willResignActive = NotificationCenter.default.publisher(
        for: NSApplication.willResignActiveNotification
    )

    /// F1 — the post-activation confirmation alert copy.
    private static let purchaseThanksTitle = "You're all set."
    private static let purchaseThanksMessage =
        "Thanks for buying Stower — your license is active on this Mac. Enjoy."

    /// The delay before showing the analytics consent card after the board appears.
    ///
    /// ~60 seconds of foreground board time (JC7 — after the user has seen value,
    /// not at startup or at the FDA permission cliff).
    private static let consentCardDelay: Duration = .seconds(60)

    private static let minWidth: CGFloat = 520
    private static let minHeight: CGFloat = 360
    private static let crossFade: Double = 0.2
}
