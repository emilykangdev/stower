import Foundation

/// The typed taxonomy of anonymous analytics events for Stower.
///
/// Each case maps to a `signalName` and a PII-safe `parameters` dictionary.
/// No case accepts a raw `String` parameter that could carry a message body,
/// contact name, phone number, search query, or file path — those values never
/// reach this type.
///
/// Per-launch vs. per-occurrence semantics are documented per case.
internal enum StowerAnalyticsEvent: Sendable {

    // MARK: — Session lifecycle

    /// The app finished launching and analytics are enabled.
    ///
    /// Emitted once per launch at `StowerMacApp` startup. **Per-launch.**
    case appLaunched

    /// The user quit the app.
    ///
    /// Emitted in `applicationShouldTerminate`; flushes on next launch via SDK
    /// buffering. Do **not** `await` in the quit path — the SDK queues to disk.
    /// **Per-launch.**
    case sessionEnded

    // MARK: — Startup funnel

    /// The on-device model availability check resolved.
    ///
    /// Emitted every time `onCommit` sees the model-availability result —
    /// including after a Check Again. **Per-occurrence.**
    ///
    /// - Parameters:
    ///   - supported: Whether the device passed the hardware check.
    ///   - reason: A coarse failure token when `supported` is false, or `nil`.
    case hardwareChecked(supported: Bool, reason: String?)

    /// The trial clock started (first-ever local trial read seeded a
    /// first-launch date).
    ///
    /// Emitted once per install, the first time `StowerTrialClock.state(now:)`
    /// seeds the first-launch date. **Per-install.**
    case trialStarted

    /// The paywall / key-entry screen appeared because the trial ended (or
    /// there was never a license).
    ///
    /// Emitted when `onCommit` commits `.needsLicense(error)`. **Per-occurrence**
    /// (fires on every `.needsLicense` commit, since a failed activation
    /// re-commits it with an error).
    ///
    /// - Parameter error: The activation error carried by this paywall visit,
    ///   or `nil` on the first (non-error) visit.
    case paywallReached(error: StowerLicenseGateError?)

    /// The user tapped Buy and the Lemon Squeezy checkout opened in the browser.
    ///
    /// Emitted from `openCheckout()`. **Per-occurrence.**
    case checkoutOpened

    /// A license key was successfully activated and persisted.
    ///
    /// Emitted from `StowerStartupModel.activate(key:)` on `.activated`, before
    /// persisting. **Per-occurrence** (once per successful activation).
    case activated

    /// FDA permission was just requested (the FDA onboarding screen appeared).
    ///
    /// Emitted once per startup run when `onCommit` first commits
    /// `.needsFullDiskAccess`. **Per-run** (the `wasAwaitingFDA` latch prevents
    /// double-firing under Check Again).
    case fdaPermissionRequested

    /// The user returned from the FDA screen and access was confirmed.
    ///
    /// Emitted via the `wasAwaitingFDA` latch when a run that was ever in an FDA
    /// state reaches `.connectedPreparingBoard` — the board load is what proves
    /// access actually works (`.checkingMessages` commits optimistically and can
    /// still fall back to `.needsFullDiskAccessStillMissing`). **Per-run** (latch
    /// resets after emission). FDA *denial* is measured as
    /// `fdaPermissionRequested` without a following `fdaPermissionResolved`, so
    /// `granted` is always `true` in v1; the parameter is retained for forward
    /// compatibility.
    ///
    /// - Parameter granted: Whether Full Disk Access was granted.
    case fdaPermissionResolved(granted: Bool)

    /// The board finished loading for the first time this launch.
    ///
    /// Emitted when `onCommit` commits `.connectedPreparingBoard`. **Per-launch**
    /// (guarded by a `boardReachedThisLaunch` latch in the startup hook).
    case boardReached

    // MARK: — Board interactions

    /// The user opened or interacted with a board row.
    ///
    /// Emitted from `StowerBoardViewModel` action methods. **Per-occurrence.**
    ///
    /// - Parameter itemType: A coarse token for the kind of item tapped
    ///   (e.g. `"message_row"`, `"muted_sender_entry"`). Never a raw contact
    ///   name, phone number, or message content.
    case boardItemClicked(itemType: String)

    /// The user invoked a named feature.
    ///
    /// Used for the voluntary buy-anytime path (`feature: "buy"`, `surface:
    /// "trial_badge"` or `"menu"`) and for any future named features. Never the
    /// forced paywall — that emits `paywallReached`. **Per-occurrence.**
    ///
    /// - Parameters:
    ///   - feature: A coarse feature token (e.g. `"buy"`).
    ///   - surface: The surface the user triggered it from.
    case featureUsed(feature: String, surface: String)

    // MARK: — Signal mapping

    /// The TelemetryDeck signal name for this event (dot-separated namespace).
    internal var signalName: String {
        switch self {
        case .appLaunched: return "app_launched"
        case .sessionEnded: return "session_ended"
        case .hardwareChecked: return "hardware_checked"
        case .trialStarted: return "trial_started"
        case .paywallReached: return "paywall_reached"
        case .checkoutOpened: return "checkout_opened"
        case .activated: return "activated"
        case .fdaPermissionRequested: return "fda_permission_requested"
        case .fdaPermissionResolved: return "fda_permission_resolved"
        case .boardReached: return "board_reached"
        case .boardItemClicked: return "board_item_clicked"
        case .featureUsed: return "feature_used"
        }
    }

    /// PII-safe key/value parameters for the signal.
    ///
    /// All continuous values are bucketed; no raw query/path/message/contact/
    /// phone/email strings appear here.
    internal var parameters: [String: String] {
        switch self {
        case .appLaunched, .sessionEnded, .fdaPermissionRequested, .boardReached, .trialStarted,
            .checkoutOpened, .activated:
            return [:]

        case .hardwareChecked(let supported, let reason):
            var params: [String: String] = ["supported": supported ? "true" : "false"]
            if let reason { params["reason"] = reason }
            return params

        case .paywallReached(let error):
            var params: [String: String] = [:]
            if let error { params["error"] = Self.gateErrorToken(error) }
            return params

        case .fdaPermissionResolved(let granted):
            return ["granted": granted ? "true" : "false"]

        case .boardItemClicked(let itemType):
            return ["item_type": itemType]

        case .featureUsed(let feature, let surface):
            return ["feature": feature, "surface": surface]
        }
    }

    /// Maps a `StowerLicenseGateError` to an anonymous token.
    private static func gateErrorToken(_ error: StowerLicenseGateError) -> String {
        switch error {
        case .invalid: return "invalid"
        case .couldNotReach: return "could_not_reach"
        }
    }
}
