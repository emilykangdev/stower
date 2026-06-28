# Licensing smoke runbook — trial → expiry → upgrade

A from-cold, runnable-in-one-sitting checklist for the revenue-critical licensing
lifecycle. The **60-second expiry smoke** needs **zero Lemon Squeezy setup** and is
runnable today; the **real-payment smoke** is a separate, LS-gated section so it
never blocks the expiry test.

This is the step-by-step *how-to*. For the bird's-eye **coverage map** (what's
automated vs. manual vs. can't-be-automated) see
[`licensing-test-coverage.md`](./licensing-test-coverage.md). For the env-var
reference see [`EnvironmentVariables.md`](./EnvironmentVariables.md).

> **Secrets:** this runbook names env-var **names** and LS test-mode references
> only — never a secret value or real customer data.

---

## 1. How the launch args actually reach the app (the DX gotcha)

`StowerMac` is a SwiftUI `@main` app in `StowerMac/StowerMac.xcodeproj`. The DEBUG
launch levers (`StowerLicenseDebugArguments`, `#if DEBUG` only) are read from
`CommandLine.arguments` in `StowerLicenseGate.init()`. So:

- **`swift run` does NOT launch the app** — it builds SPM products, not the Xcode
  app target. Use Xcode or `open`.
- **A Finder/Dock double-click drops the args silently** — you'll get a default
  launch with no fingerprint pin and wonder why expiry never reproduces.

Pick one of these two paths:

- **Xcode scheme (recommended for iterating):** Product → Scheme → Edit Scheme →
  Run → **Arguments** → *Arguments Passed On Launch* → add `--fingerprint dev-1`
  (and `--clear-lease-on-start` only when you want a fresh mint). ⚠️ Scheme args
  **persist across runs** — remove `--clear-lease-on-start` before the expiry test.
- **`open --args` (cold launch only):**
  `open /path/to/StowerMac.app --args --fingerprint dev-1`
  (add `--clear-lease-on-start` for a fresh mint). `--args` is honored only when
  `open` actually launches the app cold; if it's already running, quit it first.

A **malformed** known flag (e.g. `--fingerprint` with no value) makes the DEBUG
build refuse to start with `stower: --fingerprint requires a value …` on stderr —
that's the deterministic refusal, not a crash. An **unknown** arg is ignored.

## 2. Flag cheat-sheet

| Goal | Flags | Effect |
|------|-------|--------|
| **Observe expiry** | `--fingerprint <v>` only (NO `--clear-lease-on-start`) | Holds one identity; the stored lease survives relaunch so `/check-in` reports `expired`. |
| **Fresh trial** | `--fingerprint <v>` **+ `--clear-lease-on-start`** (one launch) | Bump `<v>` AND clear once: clears the lease so the next `currentStatus` mints a new trial under the new identity. |
| ⚠️ Bump alone | `--fingerprint <newV>` (lease still stored) | **NOT a fresh trial.** `/check-in` sends the old `licenseID` with the new fingerprint → server `fingerprint_mismatch` (`handlers.ts`) → app degrades to `.couldNotReach`. |

**Troubleshooting:** expiry behaving oddly → check the scheme isn't still passing
`--clear-lease-on-start`; the canonical expiry smoke wants it **OFF** on the
relaunch so it exercises the stored-lease `/check-in` path. (Leaving it on does not
*hide* expiry — with the same held fingerprint, mint also returns `.trialExpired`
from the server's reused expired row, `StowerLicenseGate.swift:162-163` — but it
routes through mint and re-mints every launch, which is not the canonical path.)

## 3. Preflight — reaching the board

The license gate runs only **after** the earlier startup gates pass
(`StowerStartupModel`: Apple-Intelligence availability → license → Messages/FDA).
On a cold staging Mac you can be blocked before ever seeing licensing. Clear these
first so the smoke runs in one sitting:

1. **Apple Intelligence available** — macOS 26 + Apple Intelligence on (the model
   availability gate, B-I11) — else you land on `StowerModelUnavailableView`.
2. **Full Disk Access** granted to the app (Messages/`chat.db` load) — else the FDA
   onboarding pane blocks before the board.
3. **Messages** has at least loaded — the board renders after Messages/FDA succeed.

## 4. "Is the harness armed?" — check BEFORE the 65s wait

There is no logging in `StowerMacUI` (precheck 6g), so the **startup route UI is the
readout**. Watch `StowerCheckingView`'s sub-label
(`StowerCheckingView.swift:27-30`):

- A **clear-mint first launch** commits `.checkingLicense(.startingTrial)` →
  **"Starting your free trial…"**.
- A **relaunch on the same held fingerprint** commits `.checkingLicense(.revalidating)`
  → **"Checking your license…"**.

Seeing the wrong copy = a flag typo, a stale `--clear-lease-on-start`, or
`TRIAL_DURATION_SECONDS` not set on the linked staging project — caught **before**
the wait, not after.

## 5. The 60-second expiry smoke (zero LS setup)

1. **Set the staging secret** (procedure below) — `TRIAL_DURATION_SECONDS=60` on the
   staging Supabase project **only**.
2. Launch with `--fingerprint dev-1 --clear-lease-on-start` (one fresh mint).
3. Pass preflight (§3); confirm the **"Starting your free trial…"** copy (§4) and
   reach the board (the trial badge shows "Free trial · ends …").
4. **Remove `--clear-lease-on-start`** from the scheme (keep `--fingerprint dev-1`).
5. Wait **~65 seconds**, then **⌘Q and relaunch** (same held `dev-1`, no clear).
6. **Expect:** the `StowerLicenseEntryView` `.trialExpired` screen
   (`StowerLicenseEntryView.swift:28`). The active-trial badge is gone — on a
   `.trialExpired` verdict the gate clears the lease (`StowerLicenseGate.swift:76`).

The on-screen `.trialExpired` state is the readout (no logging, no badge once
expired) — this is the manual leg I-H8 the automated suite can't cover.

### Staging-secret procedure (REQUIRED — read before `secrets set`)

```bash
# 1. CONFIRM you are linked to STAGING, not prod. A wrong link gives prod 60-second
#    trials silently (TRIAL_DURATION_SECONDS is intentionally NOT in REQUIRED_ENV,
#    so /health stays "ok" — the leak is caught only by the canary field, step 4).
supabase projects list          # the linked ref MUST be qxsrnsxvsgofaeblbmmv

# 2. Set the staging secret (applies on the next function invocation — no redeploy).
supabase secrets set TRIAL_DURATION_SECONDS=60

# 3. RECOVERY when done — restore the 30-day default:
supabase secrets unset TRIAL_DURATION_SECONDS

# 4. Canary: a non-default duration is echoed by /health (default omits it).
curl -s https://qxsrnsxvsgofaeblbmmv.supabase.co/functions/v1/license/health
#   → {"status":"ok","trialDurationSeconds":60,"warning":"non-default trial duration"}
#   With the secret unset → {"status":"ok"} (field absent). If you EVER see the
#   trialDurationSeconds field on the PROD /health, unset it immediately (step 3).
```

## 6. The real-payment smoke (LS-gated — separate)

One-time prerequisite: a Lemon Squeezy **test-mode** variant + a test webhook
pointed at the staging `…/ls-webhook` route, with `LS_PAID_VARIANT_ID` +
`LS_WEBHOOK_SECRET` set to the test values (see
[`EnvironmentVariables.md`](./EnvironmentVariables.md) §4). Then:

1. On an active trial, open the board toolbar **gear menu → "Buy Stower v0"**
   (`StowerBoardViewTriage.swift:38` `licenseMenu`) — this opens the LS checkout
   bound to this device's `license_id`.
2. Complete a **test-mode** purchase.
3. The `order_created` webhook upgrades the license (`handleWebhook` → `upgradeToPaid`
   + `attachV0`); on the next `/check-in` the app stays `.valid` and the trial badge
   disappears (paid → no `attributes.expiry`).

## 7. Appendix — JC-T1 signed-webhook e2e

The webhook **signature gate is now covered by an automated real-HMAC Deno test**
(not faked): `supabase/functions/license/index.test.ts` exercises the real
`verifyLemonSqueezySignature` (`handlers.ts`) — a genuinely HMAC-SHA256-signed
`order_created` is accepted and drives the upgrade; a tampered body is `401` with no
money-path side effects (I-H9). Run it with `cd supabase/functions/license &&
deno test`.

Optional zero-touch smoke against a deployed staging function: POST a test
`order_created` body to `…/ls-webhook` with a genuine `X-Signature` HMAC over the
raw body under the staging `LS_WEBHOOK_SECRET`, and confirm a `200` + the upgrade in
Keygen. (Not required — the Deno test covers the gate; this only exercises the
deployed wiring.)
