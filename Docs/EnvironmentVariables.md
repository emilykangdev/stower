# Stower — Environment Variables (Licensing)

> **What this file is.** The complete app-side config surface for licensing.
> There is no server of any kind: Lemon Squeezy is the merchant of record and
> the app's only network call is a direct, keyless `POST` to
> `https://api.lemonsqueezy.com/v1/licenses/activate`.

The licensing system reads **no OS environment variables in Release** and no
server-side env vars at all — there is no server. In a **DEBUG** build only,
three `STOWER_*` `ProcessInfo` values can override the compiled
`StowerLicenseConfig` defaults, for local dev/test/CI. Grounded in
`Sources/StowerMacUI/Startup/StowerLicenseConfig.swift`.

---

## 1. `StowerLicenseConfig` — the one app-side config surface

The Mac app doesn't read a licensing backend's env; the three values it needs
live in one place, `StowerLicenseConfig`
(`Sources/StowerMacUI/Startup/StowerLicenseConfig.swift`). All three are
**public** — `/v1/licenses/activate` itself needs no API key, so nothing here
is a secret to protect.

| Field | What it is | DEBUG override env var |
|-------|-----------|------------------------|
| `checkoutURL` | The Lemon Squeezy checkout URL the Buy action opens | `STOWER_CHECKOUT_URL` |
| `storeID` | Stower's Lemon Squeezy `store_id`; an `/activate` response's `meta.store_id` must match this before the key is accepted | `STOWER_STORE_ID` |
| `productID` | Stower's Lemon Squeezy `product_id`; an `/activate` response's `meta.product_id` must match this before the key is accepted | `STOWER_PRODUCT_ID` |

`StowerLicenseConfig` resolves in two layers:

1. **Compiled default** — `StowerLicenseConfig.staging` in a `DEBUG` build,
   `StowerLicenseConfig.production` otherwise (`compiledDefault`).
2. **`STOWER_*` `ProcessInfo` override, DEBUG only** — `effectiveConfig(environment:compiled:allowOverrides:)`
   applies `STOWER_CHECKOUT_URL` / `STOWER_STORE_ID` / `STOWER_PRODUCT_ID` over
   the compiled default only when `allowOverrides` is `true`. `StowerLicenseConfig.resolved`
   passes `allowOverrides: true` in `DEBUG`, `false` otherwise — so a **Release**
   build always pins the compiled `production` config and **ignores** these env
   vars entirely (`STOWER_*` cannot swap the store/product identity a shipped
   binary trusts).

An unset or empty string override falls back to the compiled field; a
`STOWER_STORE_ID` / `STOWER_PRODUCT_ID` value that fails to parse as `Int`
also falls back rather than crash.

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
  `production` `StowerLicenseConfig` compiled default (§1) plus the DEBUG-only
  `STOWER_*` overrides, both of which point at the same public Lemon Squeezy
  `/activate` endpoint — only the store/product/checkout values differ, and
  only in DEBUG.

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
unrelated to the `STOWER_*` config overrides in §1.

---

See [`licensing-contract.md`](./licensing-contract.md) for the full seam
contract and [`licensing.md`](./licensing.md) for the customer-facing terms.
`Scripts/precheck.sh`'s `6o` guard keeps any server-backed licensing config
from reappearing in `Sources/` and asserts `api.lemonsqueezy.com` stays the
sole licensing egress.
