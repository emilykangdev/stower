# Licensing test-coverage map

What is verified automatically, what a human verifies by hand on a real build, and
what **cannot** be automated for the trial → upgrade → expiry lifecycle. This is the
coverage *map*; the step-by-step *how-to* for the manual legs is
[`license-smoke.md`](./license-smoke.md).

The lifecycle is a revenue + trust boundary (a bug means we don't get paid, or we
wrongly lock out a paying customer), so the cheap high-value layers — the server
state machine, the webhook signature gate, and the pure client levers — are
automated, and only the irreducibly-manual legs (on-screen expiry, a real payment)
stay human.

## 1. Manual Release checklist (a human, on a real build)

- **The debug levers are absent in Release.** A Release archive ignores
  `--fingerprint` / `--clear-lease-on-start` — the `StowerLicenseDebugArguments`
  seam is `#if DEBUG`-only and compile-stripped (I-H5/I-H11). Confirm a Release
  build does not react to them.
- **The 60-second staging trial expires on-screen** → the `StowerLicenseEntryView`
  `.trialExpired` screen, and the trial badge disappears (I-H8). See
  [`license-smoke.md`](./license-smoke.md) §5.
- **A one-time real Lemon Squeezy payment upgrades the license** (A3) — board gear
  menu → "Buy Stower v0" → test-mode checkout → webhook upgrade. See §6.
- **The launch-arg flow only works via the Xcode scheme / `open --args`** — a
  Finder/Dock double-click drops the args. See §1.
- **The badge view-visibility matrix** (board overlay × gear-menu enable/disable ×
  dismissal) — verified by eye; this repo forbids ViewInspector/XCUITest, so it is
  not on the automated tier.

## 2. What IS automated

- **`Scripts/precheck.sh`** (every commit): swift-format, swiftlint, `swift build`,
  `swift test`, the Deno license tests, and the static source guards —
  **`6h`** (`StowerLicenseDebugArguments` is `#if DEBUG`-contained, I-H5),
  **`6i`** (`/health` calls `trialDurationHealthFields`, I-H10),
  **`6j`** (no `DEBUG` in any Xcode **Release** config, I-H11).
- **`.github/workflows/ci.yml`**: `swift build -c release` — a Release reference to a
  `#if DEBUG`-only symbol is a hard compile error (the authoritative I-H5 gate; the
  `6h` source guard is the fast local canary).
- **Deno `config.test.ts`**: `trialDurationMs` (I-H1..I-H4 — default / `60`→`60000` /
  empty·`abc`·`-5`·`0`→default / not-in-`REQUIRED_ENV`) and `trialDurationHealthFields`
  (I-H10 — default omits the field, non-default surfaces it + a warning).
- **Deno `index.test.ts`**: the webhook **signature gate** via the real extracted
  `verifyLemonSqueezySignature` (I-H9 — a genuine HMAC `order_created` upgrades; a
  tampered body is `401` with no money-path side effects), plus the existing
  upgrade-logic / idempotent-replay coverage.
- **Swift `StowerLicenseDebugArgumentsTests`**: the parser matrix (I-H7 — dangling /
  flag-eating / empty / whitespace / duplicate `--fingerprint` refuse; unknown args
  ignored) and the hashed-fingerprint invariant (I-H6 — only `SHA-256(value)` ever
  leaves the device).
- **Swift `StowerLicenseGateTests` / `StowerLicenseLeaseStoreTests` /
  `StowerTrialBadgeViewTests`**: the badge's pure/model branches (I-H12 —
  `endLabel(for:)` formatting, `trialExpiry(forMachineFile:)` signature-fail,
  `trialBadge()` on an unloadable lease, plain-ISO parse) and the
  `EXPIRED → .trialExpired` mapping (`expiredMapsToTrialExpired`).
- **The `keygen-integration` real-CE tier** (`Scripts/Keygen/integration`, CI-only):
  exercises a real Keygen CE for the mint/upgrade attribute contract.

## 3. What CANNOT be automated (by design)

These have **no injection seam**, so forcing coverage would mean a brittle,
global-mutating test — stated here so no one writes one:

- **The on-screen expiry observation** (I-H8) — the no-arg `StowerLicenseGate.init()`
  reads `CommandLine.arguments` + builds a real Keychain-backed store; only the live
  UI shows the `.trialExpired` screen.
- **The real Lemon Squeezy payment money path** (A3) — a one-time test-mode purchase.
- **The `init()` glue + the `trialDurationMs` call site** — the gate wiring
  (`clearLeaseOnStart → leaseStore.clear()`, the fingerprint pin, the
  `.failure → stderr + exit` refusal) and `index.ts`'s `trialDurationMs(...)` call
  (the Deno test stubs `createTrialLicense`) have no injection point. Covered by the
  runbook, not a unit test.
- **Release-archive QA** — that the shipped binary behaves correctly (levers absent,
  `production` config pinned).
