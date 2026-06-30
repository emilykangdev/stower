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
minted once and persisted in the Keychain (`StowerDiagnosticsKeychainKeys.service =
com.stower.analytics.identity`). It is **not** hardware-derived, **not** IDFV/IDFA,
and has no cross-device or cross-app meaning. The UUID never travels the network:
TelemetryDeck double-hashes it (a stable app salt + SHA-256, then its own on-wire
hash) before any signal leaves the device. The salt (`StowerAnalytics.stableSalt`)
exists only for hash stability — anonymity comes from the random UUID, not the salt —
and must never change, or every existing user would look new. The UUID and the
cached opt-out share one Keychain item (`DiagnosticsInstallRecord`) so they can't desync.

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
**immediately** this session even if the Keychain cache write failed.
Re-enabling clears the latch; if the SDK never started this launch its backend is
started then, otherwise a live reporter is restored (the SDK can't be re-initialized).
(Sentry's kill switch differs — it has a real `SentrySDK.close()`; see
[CrashReporting.md](CrashReporting.md).)

## Consent (default-on with disclosure, "off wins")

Analytics is **default-on**. `StowerDiagnosticsConsent.isEnabled` returns `true` when
no record exists yet (fresh install). The user is shown the
`StowerAnalyticsConsentCard` once, after ~60 seconds of *foreground board* time
(`StowerRootView.consentCardDelay`, JC7) — after they've seen value, never at startup
or at the FDA permission cliff. The countdown cancels on resign-active / board
disappearance and re-arms on return; the shown-once flag lives in `UserDefaults`
(`StowerDiagnosticsConsent.shownDefaultsKey`). One-click off also lives in a Privacy
pane (`StowerSettingsView` → `StowerPrivacySettingsView`) in the app's `Settings { }`
scene.

Consent is **license-scoped** (JC8): the license record's `diagnostics_opt_out` is the
durable authority and the Keychain `enabled` field is the fast local cache.
**Precedence is "off wins"** — analytics is off if either source says off, and
`reconcile(licenseOptOut:)` (called on each license check-in) only ever turns the
cache *off*, never back on. Only an explicit user opt-in re-enables.

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
| `licenseGateReached(context:)` | `license_gate_reached` | per-occurrence | `StowerStartupModel.commit` (returning-user funnel) |
| `fdaPermissionRequested` | `fda_permission_requested` | per-run | `StowerStartupModel.commit` (`.needsFullDiskAccess`) |
| `fdaPermissionResolved(granted:)` | `fda_permission_resolved` | per-run | only at `.connectedPreparingBoard` (board proves access) |
| `boardReached` | `board_reached` | per-launch | `StowerStartupModel.commit` (latched once) |
| `boardItemClicked(itemType:)` | `board_item_clicked` | per-occurrence | board view models |
| `featureUsed(feature:surface:)` | `feature_used` | per-occurrence | board view models (e.g. voluntary "buy") |

Funnel events are driven off `StowerStartupModel.commit` (not `onAppear` or
adjacent-state matching). `fda_permission_resolved` fires only when a run that entered
an FDA state reaches `.connectedPreparingBoard` — `.checkingMessages` commits
optimistically and can still fall back to `.needsFullDiskAccessStillMissing`, so the
board load is the only proof access actually works. FDA *denial* is therefore measured
as a `fda_permission_requested` with no following `fda_permission_resolved`.

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
