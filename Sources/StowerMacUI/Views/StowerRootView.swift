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
    @State internal var model: StowerStartupModel
    @State private var boardModel: StowerBoardViewModel

    /// The typed text in the key-entry screen; a `@State` on the stable root so
    /// it survives an in-flight activate and any error re-render.
    @State internal var licenseKey = ""

    /// Cached active-trial badge data, resolved when entering the board state.
    ///
    /// Nil means "no active trial" (licensed, or expired); it is NOT cleared on
    /// banner dismissal, so the gear-menu Buy/Enter-key path persists.
    ///
    /// `internal` (not `private`) — along with the other licensing/trial/banner
    /// `@State` below — so `StowerRootViewLicensing.swift`'s extension methods
    /// can read/write them; a stored property can't live in an extension.
    @State internal var trialBadge: StowerTrialBadge?

    /// Whether the user has dismissed the (pre-F3) trial banner this session.
    ///
    /// Seeded from the persisted dismissal flag on board entry. Only suppresses
    /// the `.trialBadge` banner state — F2/F3 are never suppressed by this flag,
    /// since they are higher-intent moments than the quiet status badge.
    @State internal var trialBannerDismissed = false

    /// F2: set when the user taps Buy; cleared once a license is stored.
    ///
    /// Drives the "Finished your purchase? Enter the license key" banner on
    /// return.
    @State internal var boughtThisSession = false

    /// Drives the F1 purchase-confirmation alert.
    @State internal var showPurchaseThanks = false

    /// Whether the analytics disclosure card is currently showing.
    ///
    /// Set to `true` after ~60 seconds of foreground board time, once, if the
    /// card has never been shown. Cleared when the user makes a choice.
    @State internal var showConsentCard = false
    @State internal var consentCardTask: Task<Void, Never>?

    /// Sleeps until the active trial's `expiry`, then re-checks the license so
    /// a continuously-foregrounded session (never backgrounded/foregrounded
    /// again) still routes to the paywall the moment the 7-day trial elapses,
    /// instead of only on the next `didBecomeActive`.
    @State internal var trialExpiryTask: Task<Void, Never>?

    /// Forces a `body` re-render at the F3 threshold.
    ///
    /// Bumped when `scheduleTrialExpiryRecheckIfNeeded`'s F3-threshold timer
    /// fires, so `currentBannerState` re-renders at `expiry - 1 day` even
    /// though `trialBadge` itself hasn't changed — the value is never read
    /// for its own sake, only to force the diff.
    @State internal var bannerRecomputeTick = Date()

    /// The consent state accessor shared by the disclosure card and the settings toggle.
    ///
    /// A single instance covers both surfaces so they never desync (the Keychain record
    /// is the underlying source of truth — shared across all readers). `internal` so
    /// `StowerRootViewLicensing.swift`'s `scheduleConsentCardIfNeeded()` can read it.
    internal let consent = StowerDiagnosticsConsent()

    internal let settings: StowerSystemSettingsOpener
    internal let analyticsReporter: any StowerAnalyticsReporting

    /// The dismissal seam for the trial badge.
    ///
    /// Reads and writes the UserDefaults flag that hides the (pre-F3) badge
    /// persistently across launches. The production path uses
    /// `UserDefaults.standard`; tests inject a fake.
    internal let badgeDismissal: any StowerTrialBadgeDismissing

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
            // F1 lives at the root, not inside the board case: a successful
            // activation's startup rerun can stop short of the board (FDA
            // onboarding, model unavailable), and the confirmation must present
            // over whichever screen the rerun lands on.
            .alert(Self.purchaseThanksTitle, isPresented: $showPurchaseThanks) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(Self.purchaseThanksMessage)
            }
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
            .onReceive(Self.willResignActive) { _ in
                consentCardTask?.cancel()
                trialExpiryTask?.cancel()
            }
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

    private static let minWidth: CGFloat = 520
    private static let minHeight: CGFloat = 360
    private static let crossFade: Double = 0.2
}
