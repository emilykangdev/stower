# Crash Reporting

## Why

Crash-only reporting for the Mac app: enough to know the app is crashing and where,
without ever collecting a message body, contact, file path that names a person, or
any other PII. The subsystem lives in `Sources/StowerMacUI/CrashReporting/` and is
**app-internal**: it sits above the engine-adapter wall (`MacAppContract.md` §9) and
imports no engine module. The single third-party dependency, Sentry (sentry-cocoa
xcframework), is quarantined to two files plus their two test files.

It shares the consent/identity seam with the analytics subsystem (see
[Analytics.md](Analytics.md)): the same `StowerDiagnosticsConsent` gate decides
whether either backend starts, and the umbrella facade `StowerDiagnostics`
(`Sources/StowerMacUI/Diagnostics/StowerDiagnostics.swift`) is the single launch
entry point that starts both. Crash reporting attaches **no** identity to reports
(no `setUser`), so it does not read `StowerDiagnosticsIdentity`.

## Launch order (Sentry FIRST)

`StowerDiagnostics.initialize()` reads consent once. When enabled it starts Sentry
crash reporting FIRST — `StowerCrashReporting.start(consent:)` — for the earliest
possible crash coverage (JC3), then starts the TelemetryDeck analytics backend.
When consent is off, neither backend starts: no `SentrySDK.start`, no crash handler.

## The only `SentrySDK.start` site

`StowerCrashReporting.start(consent:)` is the **only** `SentrySDK.start` call site in
Stower (enforced by precheck 6l, below). It is a no-op when consent is disabled (a
defence-in-depth re-check on top of the facade's gate). When enabled it configures a
hardened `Options`:

- `enableCrashHandler = true` — the only integration wanted.
- Every non-crash integration is disabled by an individual `enable*=false` flag
  (the xcframework public API does **not** expose `options.integrations`, so this is
  a per-feature deny-list, not an allowlist): `enableAutoSessionTracking`,
  `enableWatchdogTerminationTracking`, `enableAppHangTracking`,
  `enableNetworkBreadcrumbs`, `enableAutoBreadcrumbTracking`,
  `enableAutoPerformanceTracing`, `enableNetworkTracking`, `enableFileIOTracing`,
  `enableSwizzling`, `enableMetricKit` — all `false`.
- Enrichment flags pinned as drift guards (not left to default-infer):
  `sendDefaultPii = false` (the PII landmine — Sentry's quickstart sets it `true`),
  `attachStacktrace = false`, `tracesSampleRate = 0`.
- `beforeBreadcrumb = { _ in nil }` — no breadcrumb bodies in v1.
- `beforeSend = { StowerSentryScrubber.scrub($0) }` — the last-guardrail scrubber.
- `options.debug = true` only inside `#if DEBUG` (enforced by precheck 6m).
- No `setUser` — v1 attaches no identity to crash reports (brief Decision 4).
- No `SentrySDK.capture*` — v1 is crash-handler-only.

The EU-region DSN (`ingest.de.sentry.io`, EU data residency) is the only credential
in source; it is public/committable (client SDKs always ship the DSN). The
`sentry-cli` auth token is NOT in the repo (ops-gated).

## Kill switch (never-start, with best-effort mid-session `close()`)

Unlike TelemetryDeck, Sentry has a real stop: `StowerCrashReporting.stop()` calls
`SentrySDK.close()` (a no-op guarded by `SentrySDK.isEnabled` when the SDK never
started). The primary guarantee remains **"never started for an opted-out user at
launch"** (JC3); `close()` is defence-in-depth so crashes after a mid-session toggle
are not collected.

- Mid-session opt-out: `StowerDiagnostics.setEnabled(false)` → `StowerCrashReporting.stop()`.
- License opt-out: `StowerDiagnostics.reconcileLicenseConsent(licenseOptOut:)` (called
  on each license check-in) → `StowerCrashReporting.stop()` when the license record
  carries `diagnostics_opt_out = true`. "Off wins" — this never auto-re-enables.

**Re-enable note:** `SentrySDK.start` is one-shot per process and cannot be re-called
after `close()`. Re-enabling mid-session restores analytics but does NOT restart the
crash handler; crash coverage resumes on the next app launch.

## The scrubber (`beforeSend` last guardrail)

`StowerSentryScrubber.scrub(_:)` is a pure, side-effect-free function (safe on the
SDK's background thread) wired as `beforeSend`. Four steps, in order:

1. **Drop non-crash events** — `isCrashEvent` requires at least one exception with a
   non-nil `mechanism`; everything else returns `nil` (defence-in-depth backstop for
   anything that slips past the disabled integrations or a future SDK default).
2. **Rebuild `exceptions[].value`** — THE load-bearing step (spike A5, verified
   2026-06-29). KSCrash memory introspection promotes notable-address strings
   (which can include message/contact text from C/CFString buffers) wholesale into
   `exception.value`. The scrubber replaces that field with a content-free string
   built only from `ex.type` and the signal/mach context from `mechanism.meta` — a
   deterministic field-replace, NOT content-detection, so it cannot miss.
3. **Redact home-directory paths** (`/Users/<name>/` → `/Users/<redacted>/`) in every
   frame's `fileName` and `package` (binary image path) across both per-thread and
   per-exception stacktraces, and in every `SentryDebugMeta.codeFile`.
4. **Backstop-drop** the whole event if a hard-stop token survives in any scanned
   string field (`chat.db`, Photos paths, `license_key=`, `lmnt_`,
   `device_fingerprint`, or an email / E.164 phone shape). Dropping is safer than
   partial redaction for tokens that cannot be deterministically scrubbed.

## Vendor quarantine (precheck 6l / 6m / 6n)

- **6l** — Sentry is imported by EXACTLY FOUR files: `StowerCrashReporting.swift`,
  `StowerSentryScrubber.swift`, and their two test files
  (`StowerCrashReportingTests.swift`, `StowerSentryScrubberTests.swift`). A fifth
  `import Sentry` anywhere fails the build, keeping the SDK surface behind the
  app-owned seam.
- **6m** — `options.debug` may appear only inside a `#if DEBUG` region in
  `StowerCrashReporting.swift`; an unguarded assignment would ship debug logging in
  a Release archive.
- **6n** — No string interpolation (`\(…)`) inside
  `fatalError`/`preconditionFailure`/`assertionFailure`/`precondition`/`assert`
  messages or `DispatchQueue(label:)` strings in `Sources/`, because the KSCrash
  notable-address converter promotes those strings into `exception.value` (A5).
  First-party code must never inject user data there; the scrubber covers
  dependency-originated content.
