# Stower — Environment Variables (Licensing)

Every env var the licensing system reads, what it's for, and what changes between
**test** and **prod**. Grounded in source: the Edge Function reads them in
`supabase/functions/license/` (`index.ts`, `config.ts`), and `config.ts`'s
`REQUIRED_ENV` is the canonical "can't boot without these" list — `GET /health`
reports any that are unset (by name, never value).

> **Scope.** This covers the **Edge Function** (the licensing brain), which is
> built. The Mac-app-side config (Edge Function URL, Keygen public key, checkout
> URL) is now **wired by Plan B** but still placeholder values until prod ops
> (G10) — see §3. The local Keygen CE test harness has its own separate env,
> documented in [`Scripts/Keygen/README.md`](../Scripts/Keygen/README.md), not here.

---

## 1. All Edge Function env vars

**Required** — `config.ts` `REQUIRED_ENV`; if any is unset, `/health` returns
`503 {status:"degraded", missingEnv:[...]}` and the function can't operate.

| Var | What it is | Read at |
|-----|-----------|---------|
| `SUPABASE_URL` | The Supabase project the function reads/writes state in (`device_trials`, `purchases`, `trial_extension_grants`) | `index.ts:99` |
| `SUPABASE_SERVICE_ROLE_KEY` | Service-role key for that project (full DB access; server-only secret) | `index.ts:99` |
| `KEYGEN_ACCOUNT` | Keygen account (tenant) UUID — the license authority | `index.ts:287` |
| `KEYGEN_TOKEN` | Keygen **admin** token; mints/validates/upgrades licenses, checks out signed machine files. Never ships in the app | `index.ts:288` |
| `KEYGEN_V0_ENTITLEMENT` | The Keygen entitlement **resource id** (UUID) attached to a license on a v0 purchase. Missing → throws at boot (never ships a paid license with no major stamp) | `index.ts:291` |
| `KEYGEN_TRIAL_POLICY` | The trial policy id new trial licenses are minted under (any-version unlock; length is `TRIAL_DURATION_SECONDS` below, default 30 days) | `index.ts:344` |
| `KEYGEN_PAID_POLICY` | The paid policy id a license flips to on purchase (no expiry) | `index.ts:365` |
| `LS_WEBHOOK_SECRET` | Lemon Squeezy webhook signing secret; passed (injected) into `verifyLemonSqueezySignature` (`handlers.ts`) to verify the `order_created` webhook is genuine | `index.ts:563` |
| `LS_PAID_VARIANT_ID` | The Lemon Squeezy **variant** id that counts as "bought v0". Any other variant in a webhook is ignored | `index.ts:564` |

**Optional** — GitHub releases feed the once-per-major +7-day trial extension. If
`GITHUB_REPO` is unset, the extension is simply skipped (no error).
`TRIAL_DURATION_SECONDS` shortens the trial clock for staging smoke tests; unset →
the 30-day default (it is **deliberately NOT in `REQUIRED_ENV`** so prod boots with
it unset).

| Var | What it is | Default if unset | Read at |
|-----|-----------|------------------|---------|
| `TRIAL_DURATION_SECONDS` | Trial length in seconds (a DEBUG/staging lever — e.g. `60` to expire trials in a minute). Empty / non-numeric / `≤0` also falls back to the default. A non-default value is echoed by `GET /health` (`trialDurationSeconds` + `warning`) so a prod leak is loud | unset → `2592000` (30 days) | `config.ts trialDurationMs`, called at `index.ts:333` (mint) + `trialDurationHealthFields` at `index.ts:674` (`/health`) |
| `GITHUB_REPO` | `owner/name` of the repo whose releases define "current latest major" | unset → extension disabled | `index.ts:583` |
| `GITHUB_API_BASE` | GitHub API base URL (override for testing/enterprise) | `https://api.github.com` | `index.ts:591` |
| `GITHUB_TOKEN` | GitHub token to raise the releases-API rate limit | unset → unauthenticated requests | `index.ts:596` |

**Not env vars** (hardcoded, identical everywhere): `KEYGEN_BASE_URL`
(`https://api.keygen.sh`) and the default GitHub base, both constants in `index.ts`.
Only override Keygen's base by editing code (e.g. to point at a local Keygen CE).

---

## 2. What differs between test and prod

Set up a **separate Lemon Squeezy test-mode webhook** pointing at a **test/staging
deploy** of the function (or a Supabase branch) so test orders never touch real
licenses. Then only these values change:

| Var | Test | Prod | |
|-----|------|------|--|
| `LS_PAID_VARIANT_ID` | The **test** product's **variant** id | The **live** product's variant id | ⚠️ variant, not product, id |
| `LS_WEBHOOK_SECRET` | The **test-mode** webhook's signing secret | The **live-mode** webhook's secret | LS test & live secrets are separate |
| `SUPABASE_URL` | Test/staging project (or branch) URL | Prod project URL | differs |
| `SUPABASE_SERVICE_ROLE_KEY` | That test project's key | Prod project's key | differs |
| `KEYGEN_ACCOUNT` | Same — staging + production **share one Keygen account** (account-level keypair, commit `3d39142`); test/prod are isolated by distinct **Supabase** projects + policies, not by account | Same account | **same** — test trials accrue as harmless orphans under the trial policy (see `licensing-test-coverage.md`); differs only if prod moves to its own account |
| `KEYGEN_TOKEN` | Admin token for the test account | Prod admin token | differs |
| `KEYGEN_V0_ENTITLEMENT` | Entitlement id in the test setup | Prod entitlement id | differs (account-specific UUID) |
| `KEYGEN_TRIAL_POLICY` | Test trial policy id | Prod trial policy id | differs |
| `KEYGEN_PAID_POLICY` | Test paid policy id | Prod paid policy id | differs |
| `GITHUB_REPO` | Same — or **leave unset** in test to skip the +7d extension | `owner/name` of the real repo | usually same |
| `GITHUB_API_BASE` | Same (usually unset) | unset (uses default) | same |
| `GITHUB_TOKEN` | Same/optional | optional | same |
| `TRIAL_DURATION_SECONDS` | `60` on **staging** to smoke-test expiry in a minute | **unset** → 30 days | differs — ⚠️ NEVER set it on the prod project (silent 60-second trials); `/health` echoes a non-default value so a leak is caught by one curl |

Rule of thumb: **everything that points at money (Lemon Squeezy) or at license
state (Supabase + Keygen) differs; the GitHub "latest version" signal is shared.**
A clean way to keep the two sets apart is dotenvx multi-environment files
(`.env.test` / `.env.production`) or Supabase per-environment secrets.

---

## 3. App-side config (not env vars — one `StowerLicenseConfig`, public values)

The Mac app doesn't read OS env vars for licensing; the three values it needs live
in one place: **`StowerLicenseConfig`** (`Sources/StowerMacUI/Startup/StowerLicenseConfig.swift`).
All three are **public** — the vendor-split invariant (§3 of `licensing-contract.md`):
every secret (the Keygen admin `KEYGEN_TOKEN`, `SUPABASE_SERVICE_ROLE_KEY`,
`LS_WEBHOOK_SECRET` — all in §1 above) lives **only** in the Edge Function env and
**never ships in the binary**. The app holds only public values.

`StowerLicenseConfig` resolves in two layers: the compiled default
(`staging` in a `DEBUG` build, `production` otherwise) → a per-field
`STOWER_*` `ProcessInfo` override applied **in DEBUG only**. So a Debug build points
at the test deployment automatically and can be redirected with `STOWER_*` env vars;
a **Release** build pins the compiled `production` config and **ignores** `STOWER_*`
(`effectiveConfig(allowOverrides:)` passes `false` in Release — `StowerLicenseConfig.swift:77-99`), so a launch-environment variable can't swap the pinned Keygen trust anchor or endpoints.

| # | Value | `StowerLicenseConfig` field | What it is | Differs test↔prod? |
|---|-------|-----------------------------|-----------|--------------------|
| 1 | Edge Function base URL | `functionBaseURL` (override `STOWER_FUNCTION_URL`) | the public endpoint the app mints/checks-in against | yes — `staging` = the test Supabase ref; `production` = placeholder until prod ops |
| 2 | Keygen account **public** key (hex) | `keygenPublicKeyHex` (override `STOWER_KEYGEN_PUBLIC_KEY`) | the Ed25519 **public** key that verifies a signed machine file **offline** (`load()`/`offlineAuthority`, I6). Public — NOT the admin `KEYGEN_TOKEN` | **same** — account-level keypair, so staging + production share it (one Keygen account); differs only if prod moves to its own account |
| 3 | Lemon Squeezy **checkout URL** | `checkoutBaseURL` (override `STOWER_CHECKOUT_URL`) | the public product/variant Buy link; the app appends `checkout[custom][license_id]=<licenseID>` | yes (test vs live product/variant) |

`production` is the prod-ops checklist (G10): fill its three fields before paid
sales. `/health` does not cover them (they're app-side). Until `production` is set,
a Release first run can't reach the function and lands on `.connectOnce`.

> **No store/product IDs anymore.** The old Lemon Squeezy `/activate` path
> (`expectedStoreID`/`expectedProductID` on the deleted `StowerLemonSqueezyLicenseGate`)
> is gone — the app no longer calls Keygen or Lemon Squeezy directly. Purchase
> attribution is now the `license_id` carried in the checkout URL → the
> `order_created` webhook → `handleWebhook` (server-side).

---

## 4. Lemon Squeezy test webhook — quick setup

1. In Lemon Squeezy **test mode**, grab the test product's **variant** id and add a
   webhook (test mode has its own signing secret).
2. Point that webhook at a **test deploy** of the function's `…/ls-webhook` route.
3. On that test deploy, set `LS_PAID_VARIANT_ID` + `LS_WEBHOOK_SECRET` to the test
   values above, with test Supabase + Keygen config. Leave prod untouched.

See [`Lifecycle.md`](./Lifecycle.md) for the purchase flow and
[`licensing-contract.md`](./licensing-contract.md) for the webhook seam contract.
