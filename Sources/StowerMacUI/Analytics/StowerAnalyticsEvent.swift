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

    /// The forced license-entry wall appeared (conversion funnel).
    ///
    /// Emitted when `onCommit` commits `.needsLicense(context)`. This is the
    /// **returning-user** conversion funnel (first-run users typically skip it
    /// because a trial is auto-minted silently). The voluntary buy-anytime path
    /// from the board emits `featureUsed`, not this event.
    ///
    /// **Per-occurrence** (fire on every `.needsLicense` commit, since a
    /// Check Again can move through it again).
    case licenseGateReached(context: StowerLicenseEntryContext)

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
    /// forced license wall — that emits `licenseGateReached`. **Per-occurrence.**
    ///
    /// - Parameters:
    ///   - feature: A coarse feature token (e.g. `"buy"`).
    ///   - surface: The surface the user triggered it from.
    case featureUsed(feature: String, surface: String)

    // MARK: — Licensing operational errors

    /// A license check could not reach a verdict ("can't connect").
    ///
    /// Emitted from `StowerLicenseGate` on a genuine-unreachable or local-failure
    /// resolution — first-run mint and returning-user check-in — never on a
    /// reachable-but-rejected verdict (401/409). **Per-occurrence.**
    ///
    /// Both associated values are bounded enums mapped to stable, PII-safe tokens;
    /// the URL, license key, license id, and fingerprint never appear.
    ///
    /// - Parameters:
    ///   - reason: The coarse cause (transport / HTTP status / decode / bad URL /
    ///     local-store / unauthorized).
    ///   - endpoint: Which licensing call failed (`mintTrial` or `checkIn`).
    case licenseUnreachable(
        reason: StowerLicenseUnreachableReason,
        endpoint: StowerLicenseEndpoint
    )

    // MARK: — Signal mapping

    /// The TelemetryDeck signal name for this event (dot-separated namespace).
    internal var signalName: String {
        switch self {
        case .appLaunched: return "app_launched"
        case .sessionEnded: return "session_ended"
        case .hardwareChecked: return "hardware_checked"
        case .licenseGateReached: return "license_gate_reached"
        case .fdaPermissionRequested: return "fda_permission_requested"
        case .fdaPermissionResolved: return "fda_permission_resolved"
        case .boardReached: return "board_reached"
        case .boardItemClicked: return "board_item_clicked"
        case .featureUsed: return "feature_used"
        case .licenseUnreachable: return "license_unreachable"
        }
    }

    /// PII-safe key/value parameters for the signal.
    ///
    /// All continuous values are bucketed; no raw query/path/message/contact/
    /// phone/email strings appear here.
    internal var parameters: [String: String] {
        switch self {
        case .appLaunched, .sessionEnded, .fdaPermissionRequested, .boardReached:
            return [:]

        case .hardwareChecked(let supported, let reason):
            var params: [String: String] = ["supported": supported ? "true" : "false"]
            if let reason { params["reason"] = reason }
            return params

        case .licenseGateReached(let context):
            return ["context": Self.licenseContextToken(context)]

        case .fdaPermissionResolved(let granted):
            return ["granted": granted ? "true" : "false"]

        case .boardItemClicked(let itemType):
            return ["item_type": itemType]

        case .featureUsed(let feature, let surface):
            return ["feature": feature, "surface": surface]

        case .licenseUnreachable(let reason, let endpoint):
            return ["reason": Self.reasonToken(reason), "endpoint": endpoint.token]
        }
    }

    /// Maps a `StowerLicenseEntryContext` to an anonymous token.
    private static func licenseContextToken(_ context: StowerLicenseEntryContext) -> String {
        switch context {
        case .trialExpired: return "trial_expired"
        case .upgradeRequired: return "upgrade_required"
        case .connectOnce: return "connect_once"
        case .couldNotReach: return "could_not_reach"
        }
    }

    /// Maps a `StowerLicenseUnreachableReason` to a coarse, bounded, PII-safe token.
    ///
    /// The HTTP-status case embeds only the integer status code, never a
    /// URL/key/id/fingerprint.
    private static func reasonToken(_ reason: StowerLicenseUnreachableReason) -> String {
        switch reason {
        case .transport: return "transport"
        case .httpStatus(let code): return "http_\(code)"
        case .decodeFailure: return "decode_failure"
        case .badURL: return "bad_url"
        case .localStoreFailure: return "local_store_failure"
        case .machineFileUnauthorized: return "machine_file_unauthorized"
        }
    }
}

/// Which licensing call could not reach a verdict, for
/// `StowerAnalyticsEvent.licenseUnreachable(reason:endpoint:)`.
///
/// A bounded enum mapped to a stable token — never a raw URL.
internal enum StowerLicenseEndpoint: Sendable, Equatable {
    /// The first-run trial-mint call (`…/license/mint-trial`).
    case mintTrial

    /// The returning-user check-in call (`…/license/check-in`).
    case checkIn

    /// The stable, PII-safe analytics token for this endpoint.
    internal var token: String {
        switch self {
        case .mintTrial: return "mint_trial"
        case .checkIn: return "check_in"
        }
    }
}
