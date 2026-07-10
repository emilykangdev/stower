# Stower — Environment Variables (Licensing)

> **What this file is.** The complete app-side config surface for licensing.
> There is no server of any kind: Lemon Squeezy is the merchant of record and
> the app's only network call is a direct, keyless `POST` to
> `https://api.lemonsqueezy.com/v1/licenses/activate`.

The licensing system reads **no OS environment variables at all, in any
build** — there is no server, and (as of PAR-62) no `STOWER_*` `ProcessInfo`
override mechanism either. `StowerLicenseConfig` resolves to one of two
compiled constants selected by `StowerEnvironment.current` (`StowerCore`),
full stop. Grounded in
`Sources/StowerMacUI/Startup/StowerLicenseConfig.swift`.

---

## 1. `StowerLicenseConfig` — the one app-side config surface

The Mac app doesn't read a licensing backend's env; the three values it needs
live in one place, `StowerLicenseConfig`
(`Sources/StowerMacUI/Startup/StowerLicenseConfig.swift`). All three are
**public** — `/v1/licenses/activate` itself needs no API key, so nothing here
is a secret to protect.

| Field | What it is |
|-------|-----------|
| `checkoutURL` | The Lemon Squeezy checkout URL the Buy action opens |
| `storeID` | Stower's Lemon Squeezy `store_id`; an `/activate` response's `meta.store_id` must match this before the key is accepted |
| `productID` | Stower's Lemon Squeezy `product_id`; an `/activate` response's `meta.product_id` must match this before the key is accepted |

`StowerLicenseConfig.resolved` is exactly `compiledDefault(for: .current)`:
`StowerLicenseConfig.staging` in a `DEBUG` build, `StowerLicenseConfig.production`
otherwise. There is no override layer — a `STOWER_CHECKOUT_URL` /
`STOWER_STORE_ID` / `STOWER_PRODUCT_ID` `ProcessInfo` override mechanism
(`effectiveConfig(environment:compiled:allowOverrides:)`) existed here before
PAR-62 and was deleted as dead code (a full-repo grep found zero real callers
outside its own definition/tests); DEBUG and Release both simply pin their
compiled default now.

**G1 resolved (2026-07-01):** both `StowerLicenseConfig.production` and
`.staging` ship real values — a live `store_id`/`product_id`/checkout URL,
not placeholders. What's still open is a test-mode license key to verify
activation end-to-end (G2) and confirming store/product approval status for
live payments (G3) — see `licensing-contract.md` §"Open questions."

---

## 2. Why there is no test/prod split table

Licensing has no server, so there is almost nothing to configure per
environment:

- There is no backend, so there is nothing to deploy to a "staging" vs "prod"
  project — no service URLs, secrets, or webhook config exist.
- The 7-day trial length (`StowerTrialClock.trialDuration`) is a compiled
  Swift constant, not an env-var-overridable duration — there is no
  `TRIAL_DURATION_SECONDS` smoke-test lever. Shortening the trial for manual
  testing means changing the constant locally, not setting an env var.
- The only remaining "test vs. prod" distinction is the `staging` vs.
  `production` `StowerLicenseConfig` compiled default (§1), both of which
  point at the same public Lemon Squeezy `/activate` endpoint — only the
  store/product/checkout values differ.

---

## 3. DEBUG-only launch-argument levers (not env vars)

Separate from `StowerLicenseConfig`, two `#if DEBUG`-only launch arguments
(parsed by `StowerLicenseDebugArguments`, `Sources/StowerMacUI/Startup/StowerLicenseDebugArguments.swift`)
let a developer exercise the trial/license lifecycle without waiting 7 real
days:

| Flag | Effect |
|------|--------|
| `--clear-license` | Wipes the stored license (`StowerLicenseStore.clear()`) before the gate runs, forcing the trial/paywall path on next launch |
| `--reset-trial` | Resets the trial clock's first-launch date (`StowerTrialClock.reset()`), restarting the 7-day window |

These are parsed from `CommandLine.arguments` in `StowerLemonSqueezyLicenseGate.init()`
and are compile-stripped from a Release build — a customer build has no path
to them. They are launch arguments, not environment variables, and are
unrelated to `StowerLicenseConfig` (§1).

---

See [`licensing-contract.md`](./licensing-contract.md) for the full seam
contract and [`licensing.md`](./licensing.md) for the customer-facing terms.
`Scripts/precheck.sh`'s `6o` guard keeps any server-backed licensing config
from reappearing in `Sources/` and asserts `api.lemonsqueezy.com` stays the
sole licensing egress.
