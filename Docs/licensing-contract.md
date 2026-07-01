# Stower — Licensing Contract

> The stable engineering contract for the licensing system. Customer-facing terms
> live in `licensing.md`; this is the facade every implementation plan signs
> against. Grounded in source; updated when the **contract** changes, not when
> code changes. If a plan describes a seam shape that contradicts this file, the
> plan is wrong — not this file.
>
> **Verification lives here too:** the test-coverage map (§9) and the smoke runbook
> (§10) were folded into this file (v1.20). They are operational docs — not part of
> the version-pinned contract (§1–§8) — and may change without a contract version
> bump. Plans still sign against the §1–§8 contract version only.

**Version:** 1.21 · **Last updated:** 2026-07-01 · **Canonical home:** this file.

When the contract changes: edit here, bump the version, record the change in
§Changelog. Plans reference this file by version number.

## Sequencing

```
Plan A ✓ (done, superseded) → bootstrap plan (Keygen structures script)
  → Plan 2 (local Keygen CE harness)
  → Plan Beta ✓ (Edge Function licensing brain: mint + check-in + webhook)
  → Plan B ✓ (gate + entitlement check + LS deletion)
  → prod ops (real Edge Function URL + real buyable checkout URL)
  → enable paid sales
```

Plan A is merged (license core exists). The bootstrap plan stamps paid
licenses with their major. Plan 2 is the regression net. Plan Beta is the
**Supabase Edge Function** (`supabase/functions/license/`, Deno) — the licensing
**brain** that owns runtime license reasoning (mint-with-machine, `/check-in`,
LS webhook handling, the once-per-major +7d extension, Keygen admin calls). The
**Railway** plan was cancelled/superseded — Supabase is now brain + state store.
Plan B is the facade rewrite that makes the gate enforce entitlements and consume
the Edge Function — now landed. The remaining pre-sales step is prod ops: wire the
real Edge Function base URL and the real buyable Lemon Squeezy checkout URL (G10);
then sales open.

Each slice lands on its own branch in order. Plan B starts from `main` only
after the bootstrap script branch, Plan 2, and Plan Beta have landed, so
Plan B treats `STOWER_TRIAL` policy setup, `STOWER_V0` webhook stamping, and the
Edge Function licensing brain as landed dependencies, not work it owns. The Mac
app does not call Keygen or Supabase Postgres directly for online licensing; its
only online licensing surface is the Edge Function base URL.

The old Lemon Squeezy license-entry plan
(`tmp/archive-plans/2026-06-17-license-entry-screen.md`) is superseded history,
not executable ready work. The active license-entry screen work is Plan B's
context-driven `StowerLicenseEntryView` routing under this Keygen contract.

---

## 1. Keygen model primer (stable)

Keygen's core hierarchy is:

```text
Account
  Product
    Policy
      License
        Machine
```

- **Account** is the Keygen tenant.
- **Product** is the app being licensed (`Stower`).
- **Policy** is the rule template for licenses. It has the larger surface area:
  signing scheme, authentication strategy, trial duration/default expiry behavior,
  `maxMachines`, machine uniqueness, transfer behavior, and other Keygen-enforced
  rules.
- **License** is the concrete credential issued for one device/customer. In
  Stower, a license is born under the Trial policy and later flips to the Paid
  policy in place.
- **Machine** is the activated device/fingerprint under the license.
- **Entitlement** is a reusable permission/unlock label. It answers "what may
  this license run?" not "what rules govern this license?"

Entitlements are not nested under only one hierarchy level. Keygen explicitly lets
the same kind of entitlement resource attach to either a policy or a license:

```text
POST /v1/accounts/{account}/policies/{id}/entitlements
POST /v1/accounts/{account}/licenses/{id}/entitlements
GET  /v1/accounts/{account}/licenses/{id}/entitlements
```

`GET /licenses/{id}/entitlements` returns the license's **effective**
entitlements: both policy-inherited entitlements and entitlements attached
directly to that license.

Stower uses both attachment levels deliberately:

```text
STOWER_TRIAL_POLICY
  has entitlement STOWER_TRIAL

Trial license
  uses STOWER_TRIAL_POLICY
  therefore effectively has STOWER_TRIAL

After purchase
  same license moves to STOWER_PAID_POLICY
  expiry becomes null
  direct entitlement STOWER_V0 is attached to the license
```

The policy-level `STOWER_TRIAL` attachment is good for "all trial licenses can
run any current Stower major." The direct license-level `STOWER_V0` attachment is
good for "this exact license bought v0." Future paid unlocks such as `STOWER_V1`
attach directly to the same license so paid majors add up over time.

Use distinct names for policies and entitlements to avoid dashboard/config
ambiguity:

```text
Policies:     STOWER_TRIAL_POLICY, STOWER_PAID_POLICY
Entitlements: STOWER_TRIAL, STOWER_V0, STOWER_V1, ...
```

---

## 2. Stower model (stable)

The parts that don't move between plans. If a plan contradicts any of these,
the plan is wrong.

- **30-day device-bound trial, one per Mac.** First launch mints a Keygen
  license with a 30-day expiry, keyed to a hashed hardware fingerprint. One
  trial per device — no re-trials on the same machine.
- **Trial runs the latest major, not a fixed one.** The trial license carries
  `STOWER_TRIAL` — a generic "any version" unlock every build accepts.
- **+7-day trial extension on a new major, once per major.** If a new major
  version is released during a user's 30-day trial, the trial is extended by a
  flat 7 days so the user has time to try it. One extension per new major —
  the trial does not restart. **Keygen cannot enforce this** (it has no
  rules/scheduling engine), so the extension is **backend runtime logic**: the
  Supabase Edge Function (`supabase/functions/license/`) that, on trial
  `/check-in`, reads Supabase state, compares the major the trial started under
  against the current latest stable major (derived from GitHub releases), and
  once per new major `PATCH`es the Keygen license expiry forward by 7 days. The
  `trial_extension_grants` table (PK `(keygen_license_id, major)`) keeps it
  idempotent and capped at once per major. See §5 "/check-in" and §5a.
- **Per-major paid unlock, perpetual, adds up.** Buying v0 attaches
  `STOWER_V0` to the license. Buying v1 later attaches `STOWER_V1` to the same
  license. You keep every major you paid for; nothing you didn't.
- **One license per device, born Trial, flipped to Paid in place.** Same
  license id and key throughout. Purchase clears expiry to `null` (perpetual)
  and attaches the major's entitlement.
- **The gate checks version possession at launch.** A build runs only if its
  license holds that build's major unlock (`STOWER_V0` for the v0 app) **OR**
  `STOWER_TRIAL`. No matching unlock → buy/upgrade screen.
- **Online + offline enforcement, both signed.** Online: the Mac app calls the
  Edge Function, and the Edge Function calls Keygen/Supabase/Lemon Squeezy as
  needed. Offline: the Mac app verifies a Keygen-signed machine-file locally
  (Ed25519). You can't edit the file to fake "paid" — the signature won't match.
- **Downloading is free; *running* is what's licensed.** The repo is open and
  the app is shareable. The right to *run* a major is what you're buying.

---

## 3. Vendor split (stable)

| Vendor | Role | Issues licenses? |
|--------|------|-------------------|
| **Keygen** | License authority — mints, validates, signs machine-files, enforces `maxMachines`, holds entitlements | **Yes** (the sole authority) |
| **Lemon Squeezy** | Payment processor — takes money, returns the customer to its own web confirmation (no deep link into the Mac app today; see §5b), and sends `order_created` to the Edge Function (`/ls-webhook`) — the webhook, not any browser redirect, is how it tells Stower the payment succeeded | **No** (payment-only) |
| **Supabase Edge Function** (`supabase/functions/license/`, Deno) | The app-facing licensing **brain** — mints trials (and activates the machine + checks out the signed file), validates/checks in (`/check-in`), checks out Keygen machine files, receives Lemon Squeezy webhooks, reasons over trial expiry/major-extension eligibility/current-latest-major, reads/writes Supabase Postgres, and calls Keygen admin/license APIs. Keygen admin secrets live in its env, never in the app binary | No (orchestrator) |
| **Supabase** (Postgres) | State store for `device_trials`/`purchases`/`trial_extension_grants`; the Edge Function (above) runs in the same Supabase project | No (state store) |

Keygen is used in **both** phases (trial + paid), not "only during the trial."

---

## 4. Entitlement codes (stable)

| Code | Lives on | Meaning |
|------|----------|---------|
| `STOWER_TRIAL` | `STOWER_TRIAL_POLICY` (attached by the bootstrap script) | Any-version trial unlock — every build accepts it; goes away on purchase |
| `STOWER_V0` | **License** (attached per-license by the webhook on purchase) | v0 paid unlock |
| `STOWER_V1` | License (future) | v1 paid unlock |

**Keygen `validate-key` `scope.entitlements` is AND-semantics** — it cannot
express "v0 OR trial" in one scoped call. The Edge Function must validate plain
(fingerprint scope), read the license's entitlements, and apply the online OR
server-side (I4; `checkIn` in `handlers.ts`). The Mac app also applies the same
OR locally when it is offline, using only entitlement codes from the signed
machine file.

The build's required code is a named Swift constant on the gate
(`requiredEntitlementCode = "STOWER_V0"`; v1 build uses `"STOWER_V1"`), not a
literal.

**JC9 — the entitlement *code* is a per-runtime constant, not a Supabase env
var.** The code string `STOWER_V0` is hardcoded in three runtimes that must
agree: the Swift `requiredEntitlementCode` (offline gate), the Deno
`STOWER_V0_ENTITLEMENT_CODE` constant in `handlers.ts` (used by both the webhook
attach and the check-in OR), and `bootstrap-keygen.ts`'s `V0_ENTITLEMENT_CODE`.
For v0 the check-in **required** entitlement is simply the `STOWER_V0` constant
— there is only one product, so the server no longer derives it from any major
(neither a client-claimed `appMajor` nor a DB `started_major`); the app does NOT
send a `requiredEntitlement`. The per-major derivation (`STOWER_V${major}`,
sourced from `purchased_major` for paid users — the only consumers of `required`)
returns at v1 (JC7). Only the Keygen entitlement **resource id**
`KEYGEN_V0_ENTITLEMENT` (a UUID) is an env var, because it is account-specific.
The CI integration test pins all runtimes to the same string.

---

## 5. The facade contract — seam shapes

This is the boundary consumers depend on. **Stable at the seam; free to churn
behind it.** The Edge-Function-backed Keygen redesign (§5b) is now **as-built**:
Plan B landed (see §Changelog 1.19), so §5b's seam spec is the live contract. §5a
below documents that as-built shape; the §5c gap is now closed except for the G10
prod-ops URLs.

### 5a. As-built (what exists in code today)

The wired Swift gate is **`StowerLicenseGate`** (`StowerRootView.swift:89`,
`StowerLicenseGate(reporter:)`). The Edge-Function licensing brain
(`supabase/functions/license/`) is **built and landed** (Plan Beta), and the Swift
seams that consume it (`StowerLicenseCheckInClient`, the Keygen-backed
`StowerLicenseGate`) are now **wired** (Plan B).

**The startup license seam** — `Sources/StowerMacUI/Startup/StowerLicenseGating.swift`

```swift
internal protocol StowerLicenseGating: Sendable {
    func hasLease() -> Bool
    func currentStatus(now: Date) async -> StowerLicenseStatus
    func trialBadge() -> StowerTrialBadge?
}
```

- `StowerLicenseStatus`: `.valid` | `.trialExpired(licenseID:)` | `.wrongVersion(licenseID:)` | `.couldNotReach` | `.needsTrialOnline`
- `StowerLicenseEntryContext`: `.trialExpired(licenseID:)` | `.upgradeRequired(licenseID:)` | `.connectOnce` | `.couldNotReach`
- Wired conformer: `StowerLicenseGate` (`StowerRootView.swift:89`)
- Consumed by: `StowerStartupModel` (calls `hasLease`, `currentStatus(now:)`,
  `trialBadge`)

The Swift `StowerKeygenClient` (machine activate/checkout/validate) has been
**DELETED** — that surface now lives server-side in the Edge Function's
`keygenAdmin` (`index.ts`: `activateMachine`, `checkoutMachineFile`, `validate`,
`createTrialLicense`, `upgradeToPaid`, `attachV0`, `effectiveEntitlements`,
`currentExpiry`, `patchExpiry`).

**Lease store** — `Sources/StowerMacUI/Startup/StowerLicenseLeaseStore.swift`

```swift
internal struct StowerLicenseLease: Sendable, Equatable, Codable {
    let licenseKey: String
    let licenseID: String
    let machineFile: String
    let validatedAt: Date
}
```

- **The lease carries no entitlement codes by design** — entitlements live inside
  the Ed25519-signed machine-file `enc` payload and are decoded via
  `StowerLicenseLeaseStore.offlineAuthority(...)` into `StowerOfflineAuthority`
  (which holds `entitlementCodes`), never on the lease.
- Stored in the macOS **Keychain** as a generic-password item (`StowerKeychainItem`,
  service `com.stower.license.lease`, account `machine-file`). See "On-device
  storage & threat model" below.
- The verify key is injected via `init(publicKeyHex:)` — the production gate passes
  `StowerLicenseConfig.resolved.keygenPublicKeyHex` (the single app-side config home;
  both `staging` and `production` carry the real account key, since it is account-level
  and they share one Keygen account; the Edge Function URL is the remaining G10 placeholder).
- Verifies the machine-file's Ed25519 signature on every `load()` (I6); the
  signed payload is `"machine/" + enc`.

**Device fingerprint** — `Sources/StowerMacUI/Startup/StowerKeychainFingerprint.swift`

- SHA-256 of a random, app-scoped install UUID stored in the login Keychain
  (service `com.stower.license.fingerprint`, account `install-uuid`). No
  `IOPlatformUUID` read, no hardware fallback anywhere.
- It never identifies the machine and is user-resettable (regenerating the
  Keychain install UUID) — an app-scoped, non-correlating install identity, not a
  hardware binding.

**Trial mint client** — `Sources/StowerMacUI/Startup/StowerTrialMintClient.swift`

```swift
internal struct StowerTrialMintClient: Sendable {
    func mint(fingerprint: String) async -> StowerTrialMint
}
```

- `StowerTrialMint`: `.minted(licenseKey:licenseID:machineFile:)` | `.retryShortly` | `.unreachable(StowerLicenseUnreachableReason)`
- Decodes the renamed wire field `licenseKey` (was `key`) plus the signed
  `machineFile`. Composed into `StowerLicenseCheckInClient` (Plan B) as its mint
  base — wired into the production `StowerLicenseGate`.

**Supabase Edge Function** — `supabase/functions/license/` (the licensing brain;
landed via Plan Beta). `Deno.serve` routes (`index.ts`):

- `POST /mint-trial` `{fingerprint}` → mints (or returns the
  existing) Trial-policy license (30d expiry), **activates the machine**, and
  **checks out the signed machine file**, returning
  `{minted, licenseKey, licenseID, machineID, machineFile}` (the reply field was
  renamed from the as-built `key` to **`licenseKey`**). `400` (no fingerprint) /
  `503` (retry) on failure; crash-recoverable claim (I9).
- `POST /check-in` `{licenseID, fingerprint}` + signed
  headers — the reachable-launch gate authority (§5 "/check-in"). Never returns
  the license key.
- `POST /ls-webhook` — `order_created`: `upgradeToPaid` (PUT policy → Paid +
  PATCH expiry → null), **attaches `STOWER_V0`** via `keygenAdmin.attachV0`
  (license-level), then records `purchased_major`/`entitlement_code` on the
  `purchases` row. Validates/upgrades before recording (B7/I10).
- `GET /health` → env-aware deploy-readiness canary, no DB, no secret *values* in the
  body. `200 {status:"ok"}` when every required env var is set; `503
  {status:"degraded", missingEnv:[...]}` listing the unset required vars by **name
  only** when any is missing (`missingRequiredEnv` over `REQUIRED_ENV` in
  `config.ts`: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `KEYGEN_ACCOUNT`,
  `KEYGEN_TOKEN`, `KEYGEN_V0_ENTITLEMENT`, `KEYGEN_TRIAL_POLICY`,
  `KEYGEN_PAID_POLICY`, `LS_WEBHOOK_SECRET`, `LS_PAID_VARIANT_ID`). One curl after a
  deploy surfaces a misconfig before the first mint fails.
- `KeygenAdmin` (in `index.ts`) holds the admin token from env and never logs it;
  it owns `createTrialLicense`, `upgradeToPaid`, `attachV0`, `activateMachine`,
  `checkoutMachineFile`, `validate`, `effectiveEntitlements`, `currentExpiry`,
  `patchExpiry`.
- `TrialStore`: `device_trials` (fingerprint PK; `status` lifecycle
  `pending`→`active`; `claim_id` for crash recovery; plus `keygen_machine_id`,
  `started_major`, `updated_at`, `last_check_in_at`) and `trial_extension_grants`
  (PK `(keygen_license_id, major)`).
- `PurchaseStore`: `purchases` (`ls_order_id` PK, FK to
  `device_trials.keygen_license_id`, plus `purchased_major`/`entitlement_code`).

### 5 (cont). The `/check-in` seam shape (as-built, server-side)

`/check-in` is the reachable-launch gate authority (`checkIn` in `handlers.ts`,
wired in `index.ts`). Request: `POST /check-in` with body
`{licenseID, fingerprint}` and three headers:
`X-Stower-Timestamp` (unix seconds), `X-Stower-Nonce`, `X-Stower-Signature`
(lower-case hex). Status table:

| HTTP | `status` | extra fields | → `StowerLicenseStatus` (Plan B) |
|------|----------|--------------|----------------------------------|
| 200 | `ok` | `trialExtended, extendedForMajor, currentLatestMajor, licenseID, machineFile` | `.valid` |
| 200 | `wrong_version` | `licenseID, currentLatestMajor` | `.wrongVersion(licenseID:)` |
| 200 | `expired` | `licenseID` | `.trialExpired(licenseID:)` |
| 401 | `bad_signature` | — (non-secret diagnostic logged) | `.couldNotReach` |
| 404 | `unknown_license` | — | clear stale lease, then enter the shared mint flow (JC6); only a post-clear mint transport failure maps to `.needsTrialOnline` |
| 409 | `fingerprint_mismatch` | `licenseID` | device changed — transient retry; migration out of scope (support email) |
| 503 | `retry_shortly` / `unreachable` | — | `.couldNotReach` |

Check-in **never returns `keygen_license_key`**. On the `ok` path it returns a
freshly checked-out signed `machineFile` (I13).

**JC5 per-license request signature** (`requestSignature.ts`): the app signs each
check-in with the license's own secret key. The signature is HTTP-header-based,
not body-embedded (a body-embedded signature is circular — you can't re-serialize
the body canonically to re-hash it). The signed message is:

```text
sig = HMAC-SHA256(key = keygen_license_key,
                  msg = "{METHOD}\n{path}\n{timestamp}\n{nonce}\n{sha256hex(rawBody)}")
```

- `METHOD` upper-case; `path` is the canonical constant `"/check-in"`
  (`CHECK_IN_SIGNING_PATH` in `index.ts`) — NOT the raw request pathname, which
  carries Supabase's function prefix.
- `timestamp` is unix seconds; the server rejects `|now − ts| > 120s` (replay
  bound).
- `signature` is lower-case hex; verified constant-time.
- Implemented with Web Crypto (`crypto.subtle`), never `node:crypto`.
- Committed parity vector: `supabase/functions/license/fixtures/jc5-signature-vector.json`.
  Plan B's Swift signer must reproduce `signature` byte-for-byte.

### 5 (cont). On-device storage & threat model (as-built)

The license lease (`StowerLicenseLease`: `licenseKey`, `licenseID`,
`machineFile`, `validatedAt`) is stored in the macOS **Keychain** as a
generic-password item — `StowerKeychainItem`, service `com.stower.license.lease`,
account `machine-file` (`StowerLicenseLeaseStore.swift`). Stored with
`kSecAttrAccessibleAfterFirstUnlock` and `kSecAttrSynchronizable: false`
(device-bound, never roams to iCloud).

Two **independent** guarantees protect different things:

- The **Keychain** protects the license *key* — a bearer secret — from theft by
  other processes/users.
- The **Ed25519 signature** protects the *entitlements + expiry* from tampering;
  it is re-verified on every `load()` (I6), against the embedded
  `keygenPublicKeyHex`.

These compose so that editing the Keychain lease to fake "paid / never-expires"
gains nothing: the forged blob fails the signature check and `load()` returns
`nil`. A user can only **delete** their own lease (which forces a reconnect) or
**read** their own key. The Keygen **admin** secret never ships in the binary —
it lives only in the Edge Function env.

**Trial dedupe (one trial per device).** The dedupe key is the device
fingerprint (`device_trials.fingerprint` PK); the client sends `SHA-256` of its
random app-scoped Keychain install UUID (§5a `StowerKeychainFingerprint`), and the
server stores whatever the client sends.
`mintTrial` is **idempotent on the fingerprint**: a device that already has a row
gets its *existing* license back — same `licenseID`/`licenseKey`, same
server-side trial clock — never a fresh trial. So the JC6 `unknown_license`
self-heal (clear the local lease + re-mint) **cannot reset the trial**: it returns
the device's existing — possibly already `trialExpired` — license, which the next
`/check-in` re-verdicts to the paywall. A *forged* lease never reaches re-mint at
all (it fails the `load()` Ed25519 check, I6). The guarantee is therefore **per
device, not per human**. Under the Keychain-only identity model the reset vector
is simply resetting/regenerating the app-scoped Keychain install UUID (or using a
different Mac), and v0 deliberately accepts this rather than hardening it
pre-launch — no hardware fingerprint exists to bind, so there is no fallback to
close. The specific reset procedures are kept out of this repo on purpose.

### 5b. As-built (the Edge-Function-backed Keygen redesign)

This seam is now **as-built** — the **startup license seam + check-in client +
gate** below were **built by Plan B** (`StowerLicenseGating` /
`StowerCheckInSignature` / `StowerLicenseCheckInClient` / `StowerLicenseGate`, see
§Changelog 1.19). The only remaining future is G10 prod ops: the real Edge
Function base URL and the real buyable Lemon Squeezy checkout URL.

**Rewritten startup license seam** (Plan B):

```swift
internal protocol StowerLicenseGating: Sendable {
    func hasLease() -> Bool                    // pure-local Keychain read (replaces hasStoredLicense)
    func currentStatus(now: Date) async -> StowerLicenseStatus  // NEW
    func trialBadge() -> StowerTrialBadge?     // pure-local; decoded from the signed machine file
}
```

- `StowerLicenseStatus`: `.valid` | `.trialExpired(licenseID:)` | `.wrongVersion(licenseID:)` | `.couldNotReach` | `.needsTrialOnline`
  - `.wrongVersion` is the gate state for a license that is valid (paid, unexpired, good signature) but does not hold this build's required entitlement. Without it, the gate can't distinguish "trial expired, buy it" from "you have a valid license, just not for this major" — the version-unlock model (§1) is unenforceable without this branch.
- `StowerLicenseEntryContext`: `.trialExpired(licenseID:)` | `.upgradeRequired(licenseID:)` | `.connectOnce` | `.couldNotReach`
  - `.upgradeRequired` is the entry-screen context `.wrongVersion` routes to. It carries the `licenseID` so the buy screen can build the upgrade checkout URL. Distinct from `.trialExpired` (first-time purchase vs. cross-major upgrade — different copy, different checkout target).
- `StowerCheckingLicenseReason`: `.startingTrial` | `.revalidating`
- New conformer: an Edge-Function-backed `StowerLicenseGate` (composes the Plan-A
  local seams and talks to the Edge Function for online licensing)
- Deleted (done, Plan B): `StowerLemonSqueezyLicenseGate`, `StowerLicenseStore`, `StowerLemonSqueezyClient`
- Delete the manual key activation UI/seam for Plan B. The landed Edge Function
  has no app-facing route that can turn an arbitrary pasted key into
  `{licenseID, licenseKey, machineFile}`, and the Mac app must not call Keygen
  directly. A future recovery route can reintroduce manual key/license repair as a
  separate backend-backed slice.

**Check-in client** (§C):

- `StowerLicenseCheckInClient` (Plan B; built on the `StowerTrialMintClient`
  base) is the only online licensing client used by the Mac app. It calls the
  Edge Function for trial mint, reachable-launch `/check-in` (JC5-signed), and
  Re-check after purchase. It may also expose a pure local Lemon Squeezy checkout
  URL builder that carries the existing `licenseID`; there is no Edge Function
  checkout-URL route.
- The Edge Function (server-side, already built) validates with Keygen, reads
  effective entitlements, applies the OR rule, activates machines, and checks out
  signed machine files using `include=license.entitlements,license.policy,license`.
- The Edge Function returns the signed machine file and minimal gate status to the
  Mac app. The app does not call Keygen directly on the online path.

**Lease extension** (§C):

- `StowerLicenseLease` carries entitlement codes from the signed machine-file,
  so offline launches enforce the OR-check from the file, not the network.

**Machine-file lifecycle** (§C):

Keygen validation and Keygen machine-file checkout are separate operations.
`validate-key` does not automatically return a signed offline lease. The Edge
Function must explicitly check out a signed machine file whenever the app needs
refreshed offline authority, then return that signed file to the Mac app for
storage. (Server-side this is already built: `mintTrial` and `checkIn` both call
`keygenAdmin.checkoutMachineFile`; the Plan B work is the Swift consumption.)

**Offline boundary = the machine file's TTL (`meta.expiry`), for both trial and
paid.** This follows Keygen's official guidance: assert `meta.expiry > now` on
every launch; if past its TTL, the user must reconnect to check out a fresh file.
No grace window beyond the TTL. The license's own expiry
(`included[license].attributes.expiry`) is carried in the signed payload but is
**not** the offline boundary — it's the trial clock (30 days) or `null` (paid
perpetual). The TTL is the offline gate; the license expiry is server-side
state that propagates through fresh check-outs.

Stower uses a **7-day machine-file TTL** (`604800` seconds —
`MACHINE_FILE_TTL_SECONDS` in `index.ts`). Keygen's checkout API takes `ttl` in
seconds and uses it to calculate `meta.expiry`. The TTL is not a refresh
heuristic. If the app can reach the Edge Function when it opens, the function
validates/checks in with Keygen and checks out a fresh 7-day machine file every
time. If the app cannot reach the Edge Function, it falls back to the cached
signed file only until that file's `meta.expiry`.

1. **First trial start (online):** the app calls the Edge Function (`/mint-trial`);
   the function mints or returns the trial license, activates the Keygen machine,
   checks out a signed machine file with
   `include=license.entitlements,license.policy,license`, and returns the signed
   file for local storage.
2. **App open while online/reachable (trial or paid):** the app calls the Edge
   Function (`/check-in`); the function validates the license with Keygen, applies
   any trial-extension logic, then checks out and returns a fresh signed machine
   file with `ttl=604800` before the app proceeds. The cached file is refreshed on
   every reachable launch.
3. **App open while offline/unreachable (trial or paid):** verify the local signed machine
   file's Ed25519 signature, assert `meta.expiry > now` (TTL not expired), and
   check the signed entitlements include `STOWER_TRIAL` or the build's required
   paid entitlement. If the TTL has expired → blocked, show the connect screen.
   No grace. No "use the license expiry instead of the TTL."

**Device identity**:

- Identity is the Keychain-only `StowerKeychainFingerprint` (SHA-256 of a random
  app-scoped Keychain install UUID — no hardware binding, no fail-hard needed).
  The old `PAR-36` fingerprint reversal was **cancelled as obsolete** (it assumed
  a hardware `IOPlatformUUID` fingerprint that no longer exists).

**Purchase webhook extension** (Edge Function `/ls-webhook` — built server-side):

- The paid-upgrade path attaches `STOWER_V0` via `keygenAdmin.attachV0`
  (`POST /licenses/{id}/entitlements` with `KEYGEN_V0_ENTITLEMENT`). 422/409
  "already attached" → success (idempotent).
- Missing `KEYGEN_V0_ENTITLEMENT` → fail loudly at boot (I7; never ship a paid
  license with no major stamp).

**v0 purchase detection**:

- Checkout targets the existing device license id carried by
  `.trialExpired(licenseID:)` / `.upgradeRequired(licenseID:)`.
- The app opens the Lemon Squeezy product checkout URL with
  `checkout[custom][license_id]=<licenseID>` appended. Lemon Squeezy includes that
  value in webhook `meta.custom_data.license_id`, which `handleWebhook` reads.
- The Lemon Squeezy webhook handled by the Edge Function is the only component
  that mutates the license to paid: policy → Paid, expiry → `null`, direct
  `STOWER_V0` entitlement attached.
- The app does not infer purchase completion from Lemon Squeezy UI state. For
  v0, the paywall exposes an explicit Re-check action; that action calls the Edge
  Function (`/check-in`). The function validates the same Keygen license, reads
  effective entitlements, observes `STOWER_V0`, checks out a fresh signed machine
  file, and returns it to the app.
- If the webhook has not completed yet, Re-check leaves the user on the paywall
  with retry copy. Background polling, deep-link return, and automatic checkout
  completion detection are future UX improvements, not required for v0.

**Bootstrap script** (§A — `Scripts/Keygen/bootstrap-keygen.ts`):

- Idempotent find-or-create: Product `stower`, policies `STOWER_TRIAL_POLICY`
  + `STOWER_PAID_POLICY`
  (`ED25519_SIGN`, `LICENSE`, `maxMachines:1`, `UNIQUE_PER_PRODUCT`; Paid: no
  `duration` + `RESET_EXPIRY`), entitlements `STOWER_TRIAL` (→ Trial policy) +
  `STOWER_V0` (unattached). Prints JSON ids to stdout.

**Trial-extension service** (Edge Function `/check-in` — built server-side):

- **Why it exists:** `licensing.md` promises a +7-day trial extension when a
  new major ships during a user's trial. Keygen has no rules/scheduling engine,
  so this is Edge Function runtime logic, not a Keygen capability and not app
  logic.
- **What it does:** on `/check-in`, the function (`applyExtension` in
  `handlers.ts`) reads Supabase trial state, compares the major the trial started
  under against the current latest stable major (derived from GitHub releases),
  and once per new major patches the Keygen license expiry forward by 7 days
  (target-state PATCH to a frozen absolute expiry, not a `+= 7d` delta).
- **State required:** the `trial_extension_grants` table (PK
  `(keygen_license_id, major)`; `previous_expires_at`, `target_expires_at`,
  `patched_at`, `created_at`) keeps the extension idempotent and capped at once
  per major. Recorded BEFORE the Keygen patch so a crash re-converges to +7
  exactly once (I11).
- **App→backend seam:** the extension is driven by the app's request-driven
  app-open `/check-in` call, not cron: the Mac app opens, calls the Edge
  Function, the function reads Supabase and patches Keygen if the once-per-major
  extension applies. (The Swift `/check-in` caller is Plan B; the server logic is
  built.) Cron can be a later reconciliation tool, not the load-bearing expiry
  mechanism.
- **Does not restart the trial.** The extension adds 7 days to the existing
  expiry; it does not reset the clock. A trial that's day-25 of 30 becomes
  day-25 of 37, not day-0 of 7.

### 5c. The gap (what the plans are building)

| # | What | Status | Owned by |
|---|------|--------|----------|
| G1 | Facade rewrite (`StowerLicenseGating` → Edge-Function-backed Keygen shape) | **done** | Plan B |
| G2 | Edge-Function-backed `StowerLicenseGate` (new conformer + §C entitlement check) | **done** | Plan B |
| G3 | `StowerLicenseCheckInClient` returns gate status + signed machine file from the Edge Function | **done** | Plan B (§C) |
| G4 | Offline launches enforce entitlements from the signed machine-file | **done** (via the signed machine-file `enc`/`StowerOfflineAuthority`, not lease fields) | Plan B (§C) |
| G5 | The new gate implements the machine-file lifecycle in §5b | **done** | Plan B (§C) |
| G6 | Fingerprint fallback deleted (PAR-36) | **cancelled/obsolete** (PAR-36 cancelled; identity is Keychain-only `StowerKeychainFingerprint`, no fallback exists) | — |
| G7 | Delete `StowerLemonSqueezyLicenseGate` + `StowerLicenseStore` | **done** | Plan B |
| G8 | Webhook attaches `STOWER_V0` (§B) | **done** | Plan Beta (Edge Function `/ls-webhook`) |
| G9 | Bootstrap script creates structures (§A) | not started | Bootstrap plan |
| G10 | Real Edge Function base URL + real buyable Lemon Squeezy checkout URL (`keygenPublicKeyHex` already the real account key, §5a) | not started | Prod ops |
| G11 | Local Keygen CE harness (regression net) | not started | Plan 2 |
| G12 | Edge Function licensing brain (runtime `/check-in` + server +7d on new major + `/health`) | **done** | Plan Beta |
| G13 | `trial_extension_grants` Supabase state + idempotent once-per-major cap | **done** | Plan Beta |

---

## 6. Load-bearing invariants

If any of these break, paying customers get locked out or the model is
vaporware. Plans must not violate these.

| # | Invariant | Why it's load-bearing |
|---|-----------|----------------------|
| I1 | §C must not go live before §A + §B | A gate checking for `STOWER_V0` before the webhook stamps it rejects every paying customer |
| I2 | Trial and Paid policies are policy-change-compatible | trial→paid `PUT /policy` 422s if they differ on crypto scheme / encrypted / pooled / fingerprint-strategy |
| I3 | `STOWER_V0` is license-level, not policy-level | License-level is the only shape that lets unlocks "add up" across majors |
| I4 | The Edge Function applies the online OR (effective entitlements include `STOWER_TRIAL` OR the derived code) and the Mac app applies the offline OR from the signed file | Keygen `scope.entitlements` is AND-only; an AND scope can't express "v0 OR trial". For v0 the required code is the flat `STOWER_V0` constant; the per-major derivation (`STOWER_V${major}`, sourced from `purchased_major`) returns at v1 (JC7) |
| I5 | The offline path enforces entitlements from the signed file | Otherwise an offline `STOWER_V0` lease could run a future v1 build |
| I6 | Machine-file signature is verified on every `load()` | A tampered cache must be rejected, not trusted |
| I7 | The Edge Function's paid-upgrade path fails loudly on missing `KEYGEN_V0_ENTITLEMENT` (throws at boot in `keygenAdmin()`) | A silent skip ships paid licenses with no recorded major — the exact regression this work exists to prevent |
| I8 | One license per device (born Trial, flipped to Paid in place) | Same license id/key throughout; the paywall needs the `licenseID` to build the upgrade URL |
| I9 | `device_trials` claim is crash-recoverable | A mint that dies mid-flow neither double-mints nor returns nulls |
| I10 | Webhook validates before marking processed | A bad variant is never recorded; a transient Keygen failure stays retryable |
| I11 | The +7-day extension is idempotent and capped at once per new major | Without the `trial_extension_grants` PK `(keygen_license_id, major)` + record-before-patch to a frozen target, a check-in could double-extend or extend every launch |
| I12 | The extension adds to the existing expiry; it does not restart the trial | A restart would break the "one trial per device" promise and let a user reset their clock by downloading a new major |
| I13 | Online validation and machine-file checkout stay separate inside the Edge Function | `validate-key` is not an offline lease; without explicit checkout, offline launch decisions use stale or missing signed state |
| I14 | The machine file TTL (`meta.expiry`) is the hard offline boundary for both trial and paid — no grace | Per Keygen's guidance: assert `meta.expiry > now`; machine-file past its TTL → blocked, must reconnect. A grace window (Plan B's `paidGraceAllows`) would let revoked/suspended licenses run indefinitely offline and enable clock-tampering to extend use |
| I15 | The license's own expiry (`included[license].attributes.expiry`) is NOT the offline boundary | The TTL gates offline access; the license expiry is server-side state (30-day trial clock / `null` perpetual) that propagates through fresh check-outs, not a second offline clock the app honors independently |
| I16 | `/check-in` requires a valid JC5 per-license signature (HMAC-SHA256 over `{METHOD}\n{path}\n{timestamp}\n{nonce}\n{sha256hex(body)}`, key = `keygen_license_key`), carried in the `X-Stower-*` headers (not the body), and replay-bounded to `|now − ts| ≤ 120s` | An unsigned/forged check-in could let an attacker impersonate a device; a body-embedded signature is non-canonical; without the replay bound a captured request replays forever. The committed `fixtures/jc5-signature-vector.json` keeps the Swift signer and Deno verifier byte-for-byte identical |
| I17 | `/check-in` NEVER returns `keygen_license_key` | The key is a bearer secret already on the device; echoing it on every launch widens its exposure for no benefit |
| I18 | The Edge Function never logs secrets, even on error paths | Signature diagnostics carry only a nonce prefix + skew; bad-signature/DB/Keygen failures log ids and verdicts, never the key, body, or full signature |
| I19 | The entitlement *code* `STOWER_V0` is a per-runtime constant pinned across Swift / Deno / bootstrap; only the Keygen entitlement *resource id* `KEYGEN_V0_ENTITLEMENT` (a UUID) is env (JC9) | A code drift between the offline gate, the webhook attach, and the check-in OR would silently mis-gate; the resource id is account-specific so it must stay env |

---

## 7. How plans sign against this

1. A plan opens with the exact contract version it signs against, e.g.
   "Signs against `licensing-contract.md` v1.13."
2. A plan may build behind the facade (internal impl) or migrate the facade
   (seam shape change). A facade migration is a **one-way door** — deliberate,
   versioned, and updates every downstream consumer in the same pass.
3. A plan that asserts a seam shape must match §5. If it contradicts §5, the
   plan is wrong.
4. A plan that asserts a model fact must match §1-§4. If it contradicts them,
   the plan is wrong.
5. When a plan changes the contract (new seam, new invariant, model evolution),
   it updates **this file** first, bumps the version, then reflects the scoped
   slice in its own Tasks. Never re-define the contract in a plan.

---

## 8. Changelog

| Version | Date | Change |
|---------|------|--------|
| 1.0 | 2026-06-24 | Initial extraction. Documents the as-built Lemon Squeezy facade (§4a), the intended Keygen facade (§4b), and the 10-item gap between them (§4c). Consolidates invariants I1–I10. Supersedes the "canonical home" pattern in archived parent plan `tmp/archive-plans/2026-06-18-keygen-trial-supabase.md` — the contract now lives here, not inside a plan. |
| 1.1 | 2026-06-24 | Added the +7-day trial-extension-on-new-major model fact (§1), the trial-extension service as a new unbuilt seam (§4b), gap items G11–G12, and invariants I11–I12 (once-per-major idempotency; extension adds, never restarts). Supabase row in §2 updated to include the trial-extension role. Grounded in `tmp/briefs/2026-06-23-keygen-bootstrap-script.md:131-132,155-160` and `Docs/licensing.md:35-37`. |
| 1.2 | 2026-06-24 | Added the first explicit machine-file lifecycle (§4b): first trial start checks out a signed file, online trial launches validate/check in and refresh it, offline trial launches trust only the signed unexpired file with `STOWER_TRIAL`, and paid launches were initially described as offline-first until stale/expired/missing the paid entitlement. Added gap G5 and invariant I13 to keep `validate-key` separate from explicit checkout. Grounded in Keygen `machines/{id}/actions/check-out` docs. Later narrowed by v1.7's reachable-launch validation rule. |
| 1.3 | 2026-06-24 | Added `.wrongVersion(licenseID:)` to `StowerLicenseStatus` and `.upgradeRequired(licenseID:)` to `StowerLicenseEntryContext` (§4b) — the gate state and entry-screen context for a valid license that doesn't hold this build's required entitlement. Added `StowerCheckingLicenseReason` to the seam. Fixed §4b: was listing `StowerStartupState` cases (`.licensed`, `.needsLicense`) as if they were `StowerLicenseStatus` cases — now lists the actual `StowerLicenseStatus` cases Plan B defines. Reassigned G6 (fingerprint fallback deletion) from "Plan B" to "PAR-36 ticket" — Plan B's Non-goals explicitly exclude it; the bootstrap brief files it as a separate ticket. Grounded in Plan B `:65` and bootstrap brief `:165-170`. |
| 1.4 | 2026-06-24 | Added the §Sequencing section at the top: Plan A (done) → bootstrap → Plan 2 → Plan B → PAR-36 Slice A → PAR-36 Slice B → prod ops → enable paid sales. Replaces the stale sequencing chain in the bootstrap plan (`:10`), which omitted PAR-36. PAR-36 lands after Plan B (both slices need the gate) and before paid sales (protects identity + makes `maxMachines:1` humane). |
| 1.5 | 2026-06-24 | Ruled on the paid-offline-grace discrepancy: **no grace**. Follow Keygen's official guidance — the machine file TTL (`meta.expiry`) is the hard offline boundary for both trial and paid. Rewrote §4b machine-file lifecycle: one policy for both (verify signature → assert `meta.expiry > now` → check entitlements → proceed; expired TTL → blocked, must reconnect). Removed the trial-vs-paid offline split (trial was bounded by license expiry; paid was offline-first with assumed grace). Added invariants I14 (TTL is the boundary, no grace) and I15 (license's own expiry is NOT the offline boundary). Grounded in Keygen cryptography docs: "a time-to-live (TTL) that must be respected," "assert that `expiry` is not less than the current time," "a license file's expiry is separate from the license's expiry." **Plan B impact:** `paidGraceAllows` branch (`:111,118`) must be removed; trial-offline-bounded-by-license-expiry (`:103-106`) must change to TTL-bounded. |
| 1.6 | 2026-06-24 | Made branch sequencing and v0 purchase detection explicit. Plan B starts from `main` after the bootstrap script/webhook branch merges, so `STOWER_TRIAL` policy setup and `STOWER_V0` webhook stamping are dependencies, not Plan B work. Purchase completion is detected by explicit app Re-check against the same Keygen license; webhook mutation is authoritative; background polling/deep-link auto-advance are deferred. |
| 1.7 | 2026-06-24 | Archived the old Lemon Squeezy license-entry plan as superseded history and made the online/offline launch rule explicit: reachable trial or paid launches validate and refresh the signed machine file; unreachable launches may fall back only to a valid signed machine file whose `meta.expiry` is still in the future and whose entitlements allow the build. Also fixed the machine-file checkout include contract to require `license.entitlements,license.policy,license`. |
| 1.8 | 2026-06-24 | Added Railway to the vendor split as the backend licensing service that reasons over Supabase license/trial state and calls Keygen admin APIs for runtime decisions such as once-per-major trial extension. Supabase remains the Postgres state store and current Edge Function host for `mint-trial`/`ls-webhook`; the trial-extension service is now explicitly a Railway follow-up. |
| 1.9 | 2026-06-24 | Added the Keygen model primer at the beginning: Account→Product→Policy→License→Machine, policy vs license vs entitlement responsibilities, policy-level and license-level entitlement attach endpoints, effective entitlement reads, and the Stower naming convention (`STOWER_TRIAL_POLICY`/`STOWER_PAID_POLICY` for policies; `STOWER_TRIAL`/`STOWER_V0`/future majors for entitlements). |
| 1.10 | 2026-06-24 | Pinned Stower's machine-file checkout TTL in the intended lifecycle: `ttl=604800` seconds (7 days), matching `StowerKeygenClient.machineFileTTL`. Reachable app opens always validate/check in and check out a fresh 7-day machine file; unreachable/offline opens may use the cached signed file only until its `meta.expiry`. |
| 1.11 | 2026-06-24 | Inserted Plan Beta before Plan B: a Railway licensing backend now owns request-driven app-open check-in, once-per-major trial extension, and Supabase/Keygen runtime reasoning. Plan B must treat Railway as a landed dependency, not optional "when present" behavior. |
| 1.12 | 2026-06-24 | Tightened the online boundary: after Plan Beta, the Swift app talks only to Railway for online licensing. Railway owns Keygen validation/activation/machine-file checkout, Supabase state, Lemon Squeezy webhook handling, and checkout URL creation. The Mac app only stores and locally verifies signed Keygen machine files for offline use. |
| 1.14 | 2026-06-26 | `/health` is now **env-aware** (§5a): was `{status:"ok"}`, now a deploy-readiness canary — `200 {status:"ok"}` when every `REQUIRED_ENV` var is set, else `503 {status:"degraded", missingEnv:[...]}` listing the unset required vars by **name only** (never values), no DB. New `config.ts` (`REQUIRED_ENV` + pure injected `missingRequiredEnv`). Verified all §5a/§5b function names still match source: `KeygenAdmin` (`createTrialLicense`, `upgradeToPaid`, `attachV0`, `activateMachine`, `checkoutMachineFile`, `validate`, `effectiveEntitlements`, `currentExpiry`, `patchExpiry`) and handlers (`mintTrial`, `checkIn`, `handleWebhook`, `applyExtension`, `entitlementForMajor`). Machine-file checkout now uses the **admin** token (the license-scoped token is 403'd from `include=`) — already consistent with `keygenAdmin.checkoutMachineFile` owning the admin token; no seam change. Also tightened the §3 Lemon Squeezy vendor row: LS returns the customer to its own web confirmation (no deep link into the Mac app today — consistent with §5b deferring deep-link return); the `/ls-webhook` webhook, not a browser redirect, is how LS signals "paid". Grounded in `config.ts`, `index.ts` (`/health` route), `handlers.ts`. |
| 1.13 | 2026-06-25 | **Railway superseded — the licensing brain is the existing Supabase Edge Function** (`supabase/functions/license/`, Deno); Supabase is now brain + Postgres state store, and the app's only online licensing surface is the Edge Function base URL. Swept all ~47 Railway mentions to the Edge Function (vendor split §3, model §2, sequencing, §4, §5a/§5b/§5c, invariants I4/I7/I13). As-built (§5a, landed via Plan Beta): `/mint-trial` now activates the machine + checks out the signed file and renames the wire reply `key`→`licenseKey` (returns `{minted, licenseKey, licenseID, machineID, machineFile}`); NEW `POST /check-in` (gate authority, status table in §5) + NEW `GET /health` (`{status:"ok"}`, no secrets/DB); `/ls-webhook` now attaches `STOWER_V0` via `keygenAdmin.attachV0` and records `purchased_major`/`entitlement_code`. Added the `/check-in` seam shape + status table, the JC5 per-license signature (HMAC over `{METHOD}\n{path}\n{timestamp}\n{nonce}\n{sha256hex(body)}`, header-based, 120s replay bound, committed vector `fixtures/jc5-signature-vector.json`, canonical `CHECK_IN_SIGNING_PATH` `/check-in`), JC7 (server-derived required entitlement via `entitlementForMajor`), and JC9 (entitlement *code* is a per-runtime constant, only `KEYGEN_V0_ENTITLEMENT` UUID is env) to §4. Added the "On-device storage & threat model" note: the lease lives in the macOS Keychain (`StowerKeychainItem`, service `com.stower.license.lease`, account `machine-file`) — Keychain protects the key, the Ed25519 signature protects entitlements+expiry (re-verified every `load()`, I6); a forged lease fails the signature check. New DB (`20260625_license_checkin.sql`): `device_trials` gains `keygen_machine_id/started_major/updated_at/last_check_in_at/observed_major/observed_build`; new `trial_extension_grants` (PK `(keygen_license_id, major)`); `purchases` gains `purchased_major/entitlement_code`. A2 confirmed — entitlements + license expiry live INSIDE the Ed25519-signed machine-file `enc` payload (CI integration test decodes `enc` and asserts). Added invariants I16 (JC5 signature required, header-based, replay-bounded, committed vector), I17 (check-in never returns the key), I18 (secrets never logged), I19 (entitlement code is a pinned constant). `Sources/StowerMacUI/Startup/StowerKeygenClient.swift` **deleted** (server-side now); the wired Swift gate is still `StowerLemonSqueezyLicenseGate` and `StowerTrialMintClient` is still unwired (Plan B rewires). Grounded in `index.ts`, `handlers.ts`, `requestSignature.ts`, `github.ts`, `fixtures/jc5-signature-vector.json`, `20260625_license_checkin.sql`, `StowerLicenseLeaseStore.swift`. |
| 1.15 | 2026-06-26 | **Deleted the premature version scaffolding** (`appMajor`/`appBuild`) from the licensing backend — YAGNI, two-way door, pre-launch, zero live clients. Wire shrinks: `/mint-trial` body is now `{fingerprint}` and `/check-in` body is `{licenseID, fingerprint}` (both lose `appMajor`/`appBuild`). The check-in `required` entitlement is now the flat `STOWER_V0` constant — the server no longer derives it from any major (deleted `ENTITLEMENT_BY_MAJOR`, `entitlementForMajor`, `StowerUnknownMajorError`, and the `400 bad_request` forged-major path in `handlers.ts`). DB: `device_trials` drops `observed_major`/`observed_build` (write-only, never read; deleted from `20260625_license_checkin.sql` in place — nothing applied yet) and `TrialStore.recordObservedVersion` is gone. The JC5 parity vector (`fixtures/jc5-signature-vector.json`) was regenerated to the post-cleanup `/check-in` body via the same algorithm (`requestSignature.test.ts` parity still passes). Entitlement gate behavior is **unchanged today** (`required` is `STOWER_V0` either way). The per-major derivation (`STOWER_V${major}`, sourced from `purchased_major` for paid users — the only consumers of `required`) returns at v1; `purchased_major` is KEPT (the future entitlement source). Grounded in `handlers.ts`, `index.ts`, `index.test.ts`, `20260625_license_checkin.sql`, `fixtures/jc5-signature-vector.json`. |
| 1.16 | 2026-06-26 | **Disambiguated "expired"** — the word was overloaded across the licensing seam (the trial-expiry verdict vs. the machine-file TTL vs. the license `expiry` attribute), which I15 already warns about. Swift symbols collapsed to one greppable token: `StowerLicenseStatus.expired(licenseID:)` **and** the wire-response enum case → `.trialExpired(licenseID:)` (both layers, matching the existing `.wrongVersion` two-layer pattern), and `StowerLicenseEntryContext.trialEnded(licenseID:)` → `.trialExpired(licenseID:)`. The JSON wire verb `expired` returned by `/check-in` is **unchanged** (Deno-owned — renaming it is a server code change, out of scope). `meta.expiry` (the 7-day offline TTL, I14) is decoded into the lease property `machineFileExpiry`; the wire key stays literal. Normative prose no longer says bare "expired"/"expiry" — always "trial expiry" or "machine-file TTL (`meta.expiry`)". Docs-only, no behavior change (I14/I15 meaning unchanged); lands **before** Plan B so Plan B is authored in the final vocabulary. Grounded in this file + `tmp/ready-plans/2026-06-26-plan-B-startup-integration-supabase.md`. |
| 1.17 | 2026-06-26 | **Documented the trial-dedupe abuse-resistance guarantee** in §5 (cont): `mintTrial` is idempotent on the device fingerprint (`device_trials.fingerprint` PK), so the JC6 `unknown_license` self-heal returns a device's *existing* license — clearing or tampering the local lease **cannot reset the trial clock** (a forged lease fails the `load()` signature check, I6). States the guarantee is **per-device, not per-human**, and that v0 accepts the residual reset vectors (a second Mac / `IOPlatformUUID` spoof / the Keychain fingerprint fallback) with hardening deferred to **PAR-36** (G6) before paid sales — a two-way-door call (no paid users; premature to harden pre-launch). No code/behavior change — documents existing `mintTrial` + fingerprint-PK behavior; the bypass procedures are intentionally kept out of the repo (local notes only). Grounded in `handlers.ts` (`mintTrial`), `20260618120000_license_core.sql` (`device_trials` PK), `StowerDeviceFingerprint.swift`. |
| 1.18 | 2026-06-26 | Removed the unsupported manual key activation fallback from the intended Plan B seam. The app-facing Edge Function routes are `/mint-trial`, `/check-in`, `/ls-webhook`, and `/health`; none can turn an arbitrary pasted key into a persisted signed lease, and the Mac app must not call Keygen directly. Plan B therefore deletes the old Lemon Squeezy activation UI/seam and keeps purchase recovery to Buy + explicit Re-check. Also corrected the `/check-in` status table for `unknown_license`: a stored-lease 404 clears the stale lease and re-enters the shared mint flow (JC6), rather than mapping directly to `.needsTrialOnline`. |
| 1.19 | 2026-06-26 | **Plan B landed — the Swift gate is wired to the Edge Function.** The §5b startup seam is now as-built: `StowerLicenseGating` is `hasLease()` + `currentStatus(now:)` (the old `activate`/`persistLicense`/manual-key path is deleted); new `StowerCheckInSignature` reproduces the JC5 parity vector (`fixtures/jc5-signature-vector.json`) byte-for-byte; new `StowerLicenseCheckInClient` (built on `StowerTrialMintClient`) does mint + JC5-signed `/check-in` (mapping the §5 status table) + a pure LS checkout-URL builder carrying `checkout[custom][license_id]`; new `StowerLicenseGate` composes the check-in client + `StowerLicenseLeaseStore` + `StowerDeviceFingerprint` (mint-on-first-run, reachable check-in stores the fresh signed file, offline fallback bounded by `meta.expiry` (I14) + the signed `STOWER_TRIAL`/`STOWER_V0` OR (I5), JC6 `unknown_license` self-heal). `StowerTrialMintClient` now decodes `licenseKey`/`machineFile`; `StowerLicenseLeaseStore` gained `offlineAuthority(now:)` decoding the signed `enc` payload. `StowerStartupState` cases keep their names with new payloads (`needsLicense(StowerLicenseEntryContext)`, `checkingLicense(StowerCheckingLicenseReason)`); `StowerRootView` builds `StowerLicenseGate()`. Deleted: `StowerLemonSqueezyClient`, `StowerLemonSqueezyLicenseGate`, `StowerLicenseStore`/`StowerStoredLicense` + their tests. Remaining future (all G10/prod ops): the real `keygenPublicKeyHex`, the Edge Function base URL, and the Lemon Squeezy product/variant checkout URL (the placeholder `…/checkout` does not resolve to a buyable product — Buy completes only once these are real; zero paid users until then), plus the PAR-36 fingerprint reversal. Grounded in the new Swift sources + `fixtures/jc5-signature-vector.json`. |
| 1.20 | 2026-06-30 | **Docs-structure only — consolidated the licensing doc set from 4 files to 2.** Folded `licensing-test-coverage.md` → §9 and `license-smoke.md` → §10 into this file (their internal section numbers became §9.1–§9.3 and §10.1–§10.7; cross-refs renumbered). `licensing.md` (customer-facing terms) stays separate by audience. No contract/invariant/seam/model change — plans signed against ≤1.19 remain valid. Repointed the two external inbound refs: `EnvironmentVariables.md` (was `licensing-test-coverage.md` → now `licensing-contract.md` §9) and `StowerLicenseDebugArguments.swift` (was `Docs/license-smoke.md` → now `Docs/licensing-contract.md` §10). |
| 1.21 | 2026-07-01 | **Doc sync: Plan B is as-built; PAR-36 cancelled.** Collapsed the §5 as-built(LemonSqueezy)/intended(Keygen)/gap framing now that Plan B landed — the wired gate is `StowerLicenseGate` (`StowerRootView.swift:89`), the current `StowerLicenseGating` is `hasLease()`/`currentStatus(now:)`/`trialBadge()`, and `StowerLemonSqueezyLicenseGate`/`StowerLemonSqueezyClient`/`StowerLicenseStore`/`StowerKeygenClient` are deleted. Device identity is the Keychain-only `StowerKeychainFingerprint` (SHA-256 of a random app-scoped Keychain install UUID; no `IOPlatformUUID`, no hardware fallback). **PAR-36 cancelled as obsolete** — both slices rested on the removed IOPlatformUUID-hardware-fingerprint + direct-`StowerKeygenClient` premises; the live paid-downgrade residual is tracked in PAR-43. §5c gap table G1–G5/G7 marked done (Plan B), G6 cancelled. Remaining pre-sales work is G10 prod ops (real Edge Function URL + real buyable checkout URL). Grounded in `StowerLicenseGate.swift`, `StowerLicenseGating.swift`, `StowerLicenseLeaseStore.swift`, `StowerKeychainFingerprint.swift`, `StowerRootView.swift`. |

---

## 9. Test coverage map

> Operational doc folded in at v1.20 (was `licensing-test-coverage.md`). Not part of
> the version-pinned contract (§1–§8). The step-by-step *how-to* for the manual legs
> is §10 (the smoke runbook below).

What is verified automatically, what a human verifies by hand on a real build, and
what **cannot** be automated for the trial → upgrade → expiry lifecycle. This is the
coverage *map*; the step-by-step *how-to* for the manual legs is §10.

The lifecycle is a revenue + trust boundary (a bug means we don't get paid, or we
wrongly lock out a paying customer), so the cheap high-value layers — the server
state machine, the webhook signature gate, and the pure client levers — are
automated, and only the irreducibly-manual legs (on-screen expiry, a real payment)
stay human.

### 9.1 Manual Release checklist (a human, on a real build)

- **The debug levers are absent in Release.** A Release archive ignores
  `--fingerprint` / `--clear-lease-on-start` — the `StowerLicenseDebugArguments`
  seam is `#if DEBUG`-only and compile-stripped (I-H5/I-H11). Confirm a Release
  build does not react to them.
- **The 60-second staging trial expires on-screen** → the `StowerLicenseEntryView`
  `.trialExpired` screen, and the trial badge disappears (I-H8). See §10.5.
- **A one-time real Lemon Squeezy payment upgrades the license** (A3) — board gear
  menu → "Buy Stower v0" → test-mode checkout → webhook upgrade. See §10.6.
- **The launch-arg flow only works via the Xcode scheme / `open --args`** — a
  Finder/Dock double-click drops the args. See §10.1.
- **The badge view-visibility matrix** (board overlay × gear-menu enable/disable ×
  dismissal) — verified by eye; this repo forbids ViewInspector/XCUITest, so it is
  not on the automated tier.

### 9.2 What IS automated

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

### 9.3 What CANNOT be automated (by design)

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

---

## 10. Smoke runbook — trial → expiry → upgrade

> Operational doc folded in at v1.20 (was `license-smoke.md`). Not part of the
> version-pinned contract (§1–§8).

A from-cold, runnable-in-one-sitting checklist for the revenue-critical licensing
lifecycle. The **60-second expiry smoke** needs **zero Lemon Squeezy setup** and is
runnable today; the **real-payment smoke** is a separate, LS-gated section so it
never blocks the expiry test.

This is the step-by-step *how-to*. For the bird's-eye **coverage map** (what's
automated vs. manual vs. can't-be-automated) see §9 above. For the env-var
reference see [`EnvironmentVariables.md`](./EnvironmentVariables.md).

> **Secrets:** this runbook names env-var **names** and LS test-mode references
> only — never a secret value or real customer data.

### 10.1 How the launch args actually reach the app (the DX gotcha)

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

### 10.2 Flag cheat-sheet

| Goal | Flags | Effect |
|------|-------|--------|
| **Observe expiry** | `--fingerprint <v>` only (NO `--clear-lease-on-start`) | Holds one identity; the stored lease survives relaunch so `/check-in` reports `expired`. |
| **Fresh trial** | `--fingerprint <v>` **+ `--clear-lease-on-start`** (one launch) | Bump `<v>` AND clear once: clears the lease so the next `currentStatus` mints a new trial under the new identity. |
| ⚠️ Bump alone | `--fingerprint <newV>` (lease still stored) | **NOT a fresh trial.** `/check-in` sends the old `licenseID` with the new fingerprint → server `fingerprint_mismatch` (`handlers.ts`) → app degrades to `.couldNotReach`. |

**Troubleshooting:** expiry behaving oddly → check the scheme isn't still passing
`--clear-lease-on-start`; the canonical expiry smoke wants it **OFF** on the
relaunch so it exercises the stored-lease `/check-in` path. (Leaving it on does not
*hide* expiry — with the same held fingerprint, mint also returns `.trialExpired`
from the server's reused expired row, in `StowerLicenseGate.mintFlow(now:)` — but it
routes through mint and re-mints every launch, which is not the canonical path.)

### 10.3 Preflight — reaching the board

The license gate runs only **after** the earlier startup gates pass
(`StowerStartupModel`: Apple-Intelligence availability → license → Messages/FDA).
On a cold staging Mac you can be blocked before ever seeing licensing. Clear these
first so the smoke runs in one sitting:

1. **Apple Intelligence available** — macOS 26 + Apple Intelligence on (the model
   availability gate, B-I11) — else you land on `StowerModelUnavailableView`.
2. **Full Disk Access** granted to the app (Messages/`chat.db` load) — else the FDA
   onboarding pane blocks before the board.
3. **Messages** has at least loaded — the board renders after Messages/FDA succeed.

### 10.4 "Is the harness armed?" — check BEFORE the 65s wait

There is no logging in `StowerMacUI` (precheck 6g), so the **startup route UI is the
readout**. Watch `StowerCheckingView`'s sub-label
(`StowerCheckingView.subLabel`):

- A **clear-mint first launch** commits `.checkingLicense(.startingTrial)` →
  **"Starting your free trial…"**.
- A **relaunch on the same held fingerprint** commits `.checkingLicense(.revalidating)`
  → **"Checking your license…"**.

Seeing the wrong copy = a flag typo, a stale `--clear-lease-on-start`, or
`TRIAL_DURATION_SECONDS` not set on the linked staging project — caught **before**
the wait, not after.

### 10.5 The 60-second expiry smoke (zero LS setup)

1. **Set the staging secret** (procedure below) — `TRIAL_DURATION_SECONDS=60` on the
   staging Supabase project **only**.
2. Launch with `--fingerprint dev-1 --clear-lease-on-start` (one fresh mint).
3. Pass preflight (§10.3); confirm the **"Starting your free trial…"** copy (§10.4) and
   reach the board (the trial badge shows "Free trial · ends …").
4. **Remove `--clear-lease-on-start`** from the scheme (keep `--fingerprint dev-1`).
5. Wait **~65 seconds**, then **⌘Q and relaunch** (same held `dev-1`, no clear).
6. **Expect:** the `StowerLicenseEntryView` `.trialExpired` screen. The active-trial
   badge is gone — on a `.trialExpired` verdict `StowerLicenseGate.currentStatus(now:)`
   clears the lease.

The on-screen `.trialExpired` state is the readout (no logging, no badge once
expired) — this is the manual leg I-H8 the automated suite can't cover.

#### Staging-secret procedure (REQUIRED — read before `secrets set`)

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

### 10.6 The real-payment smoke (LS-gated — separate)

One-time prerequisite: a Lemon Squeezy **test-mode** variant + a test webhook
pointed at the staging `…/ls-webhook` route, with `LS_PAID_VARIANT_ID` +
`LS_WEBHOOK_SECRET` set to the test values (see
[`EnvironmentVariables.md`](./EnvironmentVariables.md) §4). Then:

1. On an active trial, open the board toolbar **gear menu → "Buy Stower v0"**
   (`StowerBoardView.licenseMenu`) — this opens the LS checkout
   bound to this device's `license_id`.
2. Complete a **test-mode** purchase.
3. The `order_created` webhook upgrades the license (`handleWebhook` → `upgradeToPaid`
   + `attachV0`); on the next `/check-in` the app stays `.valid` and the trial badge
   disappears (paid → no `attributes.expiry`).

### 10.7 Appendix — JC-T1 signed-webhook e2e

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
