# Analytics

## Why

Anonymous funnel analytics for the Mac app: enough to see how many people launch,
clear the hardware/license/Full-Disk-Access gates, and reach the board — without
ever collecting anything that could identify a person or expose Messages data.
The whole subsystem lives in `Sources/StowerMacUI/Analytics/` and is **app-internal**:
it sits above the engine-adapter wall (`MacAppContract.md` §9) and imports no engine
module. The single third-party dependency, TelemetryDeck, is quarantined to one file.

Analytics shares a consent/identity seam with the crash-reporting subsystem (see
[CrashReporting.md](CrashReporting.md)). The shared types — `StowerDiagnosticsConsent`,
`StowerDiagnosticsIdentity`, `DiagnosticsInstallRecord` — live in
`Sources/StowerMacUI/Diagnostics/`, and the umbrella facade `StowerDiagnostics`
(`Sources/StowerMacUI/Diagnostics/StowerDiagnostics.swift`) is the single launch
entry point that starts both backends behind one consent gate.

## Identity (anonymous by construction)

`StowerDiagnosticsIdentity.clientUser()` returns a plain random per-install `UUID`,
minted once and persisted in `UserDefaults`
(`StowerDiagnosticsStorageLocation.defaultsKey`). It is **not** hardware-derived,
**not** IDFV/IDFA, and has no cross-device or cross-app meaning. The UUID never
travels the network: TelemetryDeck double-hashes it (a stable app salt + SHA-256,
then its own on-wire hash) before any signal leaves the device. The salt
(`StowerAnalytics.stableSalt`) exists only for hash stability — anonymity comes
from the random UUID, not the salt — and must never change, or every existing user
would look new. The UUID and the cached opt-out share one `UserDefaults` blob
(`DiagnosticsInstallRecord`) so they can't desync.

The install record lives **only** in `UserDefaults` — the app makes no Keychain
call at all. An earlier build migrated a pre-`UserDefaults` install's record forward
by reading a legacy Keychain item on the launch path, but that read raised the macOS
"allow access to your keychain" password dialog before the first window drew — for
cross-signature upgraders it **blocked the app from opening**. The migration was
removed; `clientUser()` now goes straight from a missing/undecodable record to minting
a fresh UUID (the handful of pre-`UserDefaults` testers lose analytics continuity and
re-toggle any opt-out in Settings — accepted). A `Scripts/precheck.sh` `6q` guard bans
Keychain-item APIs (`SecItem*` / item-query `kSec*`) in first-party Swift so the
launch-blocking read can never come back; legit `Security.framework` use
(`SecKey`/`SecTrust`/`SecCertificate`) stays allowed.

## Kill switch (never-start, not stop)

The Swift TelemetryDeck SDK has no `stop()`, so the analytics kill switch is **"never
start when disabled."** `StowerDiagnostics.initialize()` (which delegates to
`StowerAnalytics.startBackend`) is a complete no-op for analytics when consent is off:
it builds a `StowerNoOpAnalyticsReporter`, never calls the SDK init, and so never
emits TelemetryDeck's automatic `Session.started` signal. Two layers of defence:

1. The facade gates `initialize` on consent.
2. `StowerTelemetryDeckReporter.report` re-checks `consent.isEnabled` on every signal.

When a user opts out mid-session, `StowerDiagnostics.setEnabled(false)` →
`StowerAnalytics.setEnabled(false)` trips the process-wide in-memory
`StowerDiagnosticsKillLatch` (`latchOff()`), so every reporter fails closed
**immediately** this session even if the `UserDefaults` cache write failed.
Re-enabling clears the latch; if the SDK never started this launch its backend is
started then, otherwise a live reporter is restored (the SDK can't be re-initialized).
(Sentry's kill switch differs — it has a real `SentrySDK.close()`; see
[CrashReporting.md](CrashReporting.md).)

## Consent (default-on with disclosure, "off wins")

Analytics is **default-on**. `StowerDiagnosticsConsent.isEnabled` returns `true` when
no record exists yet (fresh install). The user is shown the
`StowerAnalyticsConsentCard` once, after ~60 seconds of *foreground board* time
(`StowerRootView.consentCardDelay`, JC7) — after they've seen value, never at startup
or at the messages-access permission cliff. The countdown cancels on resign-active / board
disappearance and re-arms on return; the shown-once flag lives in `UserDefaults`
(`StowerDiagnosticsConsent.shownDefaultsKey`). One-click off also lives in a Privacy
pane (`StowerSettingsView` → `StowerPrivacySettingsView`) in the app's `Settings { }`
scene.

The `UserDefaults` `enabled` field (`DiagnosticsInstallRecord`) is the durable consent
authority as-built. **Precedence is "off wins"** — `reconcile(licenseOptOut:)`
only ever turns the cache *off*, never back on, and only an explicit user opt-in
re-enables. The license-scoped reconcile hook (JC8,
`StowerDiagnostics.reconcileLicenseConsent(licenseOptOut:)`) has **no production
caller today**: the client-only Lemon Squeezy activate-once flow stores only a
license key locally, with no server-side license record carrying a
`diagnostics_opt_out` for the hook to reconcile against. The hook and its tests
survive unwired.

## UserDefaults keys

Analytics/diagnostics persist two independent `UserDefaults` blobs. They are kept
under separate keys on purpose so they can never desync or corrupt each other
(guarded by `analyticsStorageKeyNeverCollidesWithShownFlag`):

| Key | Symbol | Holds | Written / read by |
|-----|--------|-------|-------------------|
| `com.stower.analytics.install-record` | `StowerDiagnosticsStorageLocation.defaultsKey` | The `DiagnosticsInstallRecord` blob — the random per-install `UUID` + the `enabled` opt-out cache | `StowerDiagnosticsIdentity` (UUID) + `StowerDiagnosticsConsent` (opt-out) |
| `com.stower.analytics.shown` | `StowerDiagnosticsConsent.shownDefaultsKey` | A boolean: has the one-time `StowerAnalyticsConsentCard` disclosure been shown | `StowerDiagnosticsConsent.hasShownDisclosure` / `markDisclosureShown()` |

Both survive relaunch and uninstall→reinstall (`UserDefaults` persists in
`~/Library/Preferences`); a wiped domain or a different macOS user account starts
fresh on both.

## Event taxonomy (typed, PII-safe)

`StowerAnalyticsEvent` is a typed enum; no case accepts a raw string that could carry
a message body, contact name, phone number, search query, or file path. Each case maps
to a dot-namespaced `signalName` and a bucketed `parameters` dictionary
(continuous values are coarsened via `StowerAnalyticsBucket`).

| Event | Signal | Semantics | Source |
|---|---|---|---|
| `appLaunched` | `app_launched` | per-launch | `StowerMacApp.init` |
| `sessionEnded` | `session_ended` | per-launch | `applicationShouldTerminate` (sync, no `await`) |
| `hardwareChecked(supported:reason:)` | `hardware_checked` | per-occurrence | `StowerStartupModel.commit` |
| `trialStarted` | `trial_started` | once per trial life | `StowerStartupModel.emitTrialStartedIfNeeded` (the license read that seeds `StowerTrialClock`) |
| `paywallReached(error:)` | `paywall_reached` | per-occurrence | `StowerStartupModel.commit` (`.needsLicense`) |
| `checkoutOpened` | `checkout_opened` | per-occurrence | `StowerRootView.openCheckout()` (only after the browser actually opened) |
| `activated` | `activated` | per-occurrence | `StowerStartupModel.activate(key:)` (on `.activated`, before the rerun) |
| `messagesAccessRequested` | `messages_access_requested` | per-run | `StowerStartupModel.commit` (`.needsMessagesAccess`) |
| `messagesAccessResolved(granted:)` | `messages_access_resolved` | per-run | only at `.connectedPreparingBoard` (board proves access) |
| `boardReached` | `board_reached` | per-launch | `StowerStartupModel.commit` (latched once) |
| `boardItemClicked(itemType:)` | `board_item_clicked` | per-occurrence | board view models |
| `featureUsed(feature:surface:)` | `feature_used` | per-occurrence | board view models (e.g. voluntary "buy") |
| `feedbackOpened(licenseStatus:)` | `feedback_opened` | per-occurrence | `StowerFeedbackModel` — the user opened the in-app feedback sheet |
| `feedbackSent(licenseStatus:)` | `feedback_sent` | per-occurrence | `StowerFeedbackModel` — feedback accepted by the relay (HTTP 2xx) |

Startup funnel events are driven off `StowerStartupModel.commit` (not `onAppear` or
adjacent-state matching); the exceptions are `trial_started`, which fires from the
`runStartup` license read via `emitTrialStartedIfNeeded`, and
`checkout_opened`/`activated`, which fire at their action sites
(`StowerRootView.openCheckout()` / `StowerStartupModel.activate(key:)`).
`messages_access_resolved` fires only when a run that entered
a messages-access state reaches `.connectedPreparingBoard` — `.checkingMessages` commits
optimistically and can still fall back to `.needsMessagesAccessStillMissing`, so the
board load is the only proof access actually works. Denial is therefore measured
as a `messages_access_requested` with no following `messages_access_resolved`.

## Reporting seam

`StowerAnalyticsReporting` is a synchronous, non-throwing, `Sendable` protocol
(`session_ended` at quit must not block, and reports arrive from `@MainActor` view
models and the quit path alike). Conformers: `StowerTelemetryDeckReporter` (the live
one), `StowerNoOpAnalyticsReporter` (previews/tests), and
`StowerInMemoryAnalyticsReporter` (a lock-guarded spy for tests that assert which
events fired).

## TelemetryDeck quarantine (precheck 6k)

`StowerTelemetryDeckReporter` is the **only** file allowed to `import TelemetryDeck`.
`Scripts/precheck.sh` step **6k** fails the build if any other file imports it, so
the SDK surface stays behind the app-owned `StowerAnalyticsReporting` seam and the
facade never needs to name TelemetryDeck types.

## Verifying signals locally (DEBUG builds are "Test Mode")

A DEBUG build run from Xcode tags **every** signal as a TelemetryDeck **Test Signal**
— `StowerTelemetryDeckReporter.initializeSDK` builds `TelemetryDeck.Config(appID:salt:)`
with no explicit `testMode`, so it inherits the SDK's DEBUG-is-test default. The
TelemetryDeck dashboard **hides test data by default**, so signals appear only when you
flip the **"Test Mode"** toggle (next to the date filter). The SDK log line
`Sending N signals leaving a cache of 0 signals` confirms the signal flushed — so when
nothing shows in the dashboard it is the test-mode view filter, not a consent/init bug.
A Release build sends live (production) signals that show without the toggle. The app id
is `StowerAnalytics.appID` (DEBUG points the build at staging via `StowerLicenseConfig`,
but the analytics app id is the same).
