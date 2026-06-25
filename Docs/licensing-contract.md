# Stower — Licensing Contract

> The stable engineering contract for the licensing system. Customer-facing terms
> live in `licensing.md`; this is the facade every implementation plan signs
> against. Grounded in source; updated when the **contract** changes, not when
> code changes. If a plan describes a seam shape that contradicts this file, the
> plan is wrong — not this file.

**Version:** 1.12 · **Last updated:** 2026-06-24 · **Canonical home:** this file.

When the contract changes: edit here, bump the version, record the change in
§Changelog. Plans reference this file by version number.

## Sequencing

```
Plan A ✓ (done, superseded) → bootstrap plan (Keygen structures script)
  → Plan 2 (local Keygen CE harness)
  → Plan Beta (Railway licensing backend)
  → Plan B (gate + entitlement check + LS deletion)
  → PAR-36 Slice A (fail-hard fingerprint + unidentifiable-Mac UX)
  → PAR-36 Slice B (self-service migration)
  → prod ops (real Keygen account + public key)
  → enable paid sales
```

Plan A is merged (license core exists). The bootstrap plan stamps paid
licenses with their major. Plan 2 is the regression net. Plan Beta creates the
Railway licensing backend that owns runtime license reasoning. Plan B is the
facade rewrite that makes the gate enforce entitlements and consume the Railway
backend. PAR-36 lands after Plan B (both slices need the gate to route through)
and before paid sales (protects identity integrity + makes `maxMachines: 1`
humane). Prod ops wires the real account; then sales open.

Each slice lands on its own branch in order. Plan B starts from `main` only
after the bootstrap script branch, Plan 2, and Plan Beta have landed, so
Plan B treats `STOWER_TRIAL` policy setup, `STOWER_V0` webhook stamping, and the
Railway licensing backend as landed dependencies, not work it owns. The Mac app
does not call Keygen or Supabase directly for online licensing after Plan Beta;
its online licensing surface is Railway only.

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
  rules/scheduling engine), so the extension is **backend runtime logic**: a
  Railway-hosted licensing service that, on trial check-in, reads Supabase
  state, compares the major the trial started under against a backend "current
  latest major" config, and once per new major `PATCH`es the Keygen license
  `expiry += 7d`. New state on `device_trials` (`extended_for_majors`) keeps it
  idempotent and capped at once per major. See §5b "Trial-extension service."
- **Per-major paid unlock, perpetual, adds up.** Buying v0 attaches
  `STOWER_V0` to the license. Buying v1 later attaches `STOWER_V1` to the same
  license. You keep every major you paid for; nothing you didn't.
- **One license per device, born Trial, flipped to Paid in place.** Same
  license id and key throughout. Purchase clears expiry to `null` (perpetual)
  and attaches the major's entitlement.
- **The gate checks version possession at launch.** A build runs only if its
  license holds that build's major unlock (`STOWER_V0` for the v0 app) **OR**
  `STOWER_TRIAL`. No matching unlock → buy/upgrade screen.
- **Online + offline enforcement, both signed.** Online: the Mac app calls
  Railway, and Railway calls Keygen/Supabase/Lemon Squeezy as needed. Offline:
  the Mac app verifies a Keygen-signed machine-file locally (Ed25519). You can't
  edit the file to fake "paid" — the signature won't match.
- **Downloading is free; *running* is what's licensed.** The repo is open and
  the app is shareable. The right to *run* a major is what you're buying.

---

## 3. Vendor split (stable)

| Vendor | Role | Issues licenses? |
|--------|------|-------------------|
| **Keygen** | License authority — mints, validates, signs machine-files, enforces `maxMachines`, holds entitlements | **Yes** (the sole authority) |
| **Lemon Squeezy** | Payment processor — takes money, redirects/returns the customer, and sends `order_created` to Railway | **No** (payment-only) |
| **Railway** | The app-facing licensing backend — mints trials, validates/checks in, checks out Keygen machine files, creates checkout URLs, receives Lemon Squeezy webhooks, reasons over trial expiry/major-extension eligibility/current-latest-major config, reads/writes Supabase, and calls Keygen admin/license APIs | No (orchestrator) |
| **Supabase** | Postgres state store for `device_trials`/`purchases`; legacy/current Edge Function host only until Plan Beta moves/wraps those routes behind Railway | No (state store) |

Keygen is used in **both** phases (trial + paid), not "only during the trial."

---

## 4. Entitlement codes (stable)

| Code | Lives on | Meaning |
|------|----------|---------|
| `STOWER_TRIAL` | `STOWER_TRIAL_POLICY` (attached by the bootstrap script) | Any-version trial unlock — every build accepts it; goes away on purchase |
| `STOWER_V0` | **License** (attached per-license by the webhook on purchase) | v0 paid unlock |
| `STOWER_V1` | License (future) | v1 paid unlock |

**Keygen `validate-key` `scope.entitlements` is AND-semantics** — it cannot
express "v0 OR trial" in one scoped call. Railway must validate plain
(fingerprint scope), read the license's entitlements, and apply the online OR
server-side. The Mac app also applies the same OR locally when it is offline,
using only entitlement codes from the signed machine file.

The build's required code is a named Swift constant on the gate
(`requiredEntitlementCode = "STOWER_V0"`; v1 build uses `"STOWER_V1"`), not a
literal.

---

## 5. The facade contract — seam shapes

This is the boundary consumers depend on. **Stable at the seam; free to churn
behind it.** Two states are documented below: what exists in code today
(as-built) and what the redesign requires (intended). The gap is the work.

### 5a. As-built (what exists in code today)

The wired gate is **Lemon Squeezy**, not Keygen. The Keygen seams exist but are
**unwired** (no conformer, no startup integration).

**The startup license seam** — `Sources/StowerMacUI/Startup/StowerLicenseGating.swift`

```swift
internal protocol StowerLicenseGating: Sendable {
    func hasStoredLicense() -> Bool
    func activate(key: String) async -> StowerLicenseActivation
    func persistLicense(key: String, instanceID: String)
}
```

- `StowerLicenseActivation`: `.activated(instanceID:)` | `.invalid` | `.couldNotReach`
- `StowerLicenseGateError`: `.invalid` | `.couldNotReach`
- Wired conformer: `StowerLemonSqueezyLicenseGate` (`StowerRootView.swift:38`)
- Consumed by: `StowerStartupModel` (`:157,200,204` — calls `hasStoredLicense`,
  `activate`, `persistLicense`)

**Keygen client** — `Sources/StowerMacUI/Startup/StowerKeygenClient.swift`

```swift
internal struct StowerKeygenClient: Sendable {
    func activate(licenseKey: String, licenseID: String, fingerprint: String) async throws -> StowerKeygenActivation
    func checkOutMachineFile(machineID: String, licenseKey: String) async throws -> String
    func validate(licenseKey: String, fingerprint: String) async throws -> StowerKeygenValidation
}
```

- `StowerKeygenActivation`: `.activated(machineID:)` | `.limitReached`
- `StowerKeygenValidation`: `.valid` | `.invalid(code: String)` — decodes **only** `meta.valid` + `meta.code`. **Does not surface entitlement codes.**
- `machineFileTTL`: 7 days (`:216`)

**Lease store** — `Sources/StowerMacUI/Startup/StowerLicenseLeaseStore.swift`

```swift
internal struct StowerLicenseLease: Codable {
    let licenseKey: String
    let licenseID: String
    let machineFile: String
    let validatedAt: Date
}
```

- **No entitlement codes in the lease.**
- `keygenPublicKeyHex`: all-zeros placeholder (`:210-211`) — no production
  verification runs yet.
- Verifies Ed25519 signature on every `load()`.

**Device fingerprint** — `Sources/StowerMacUI/Startup/StowerDeviceFingerprint.swift`

- SHA-256 of `IOPlatformUUID`, **with a Keychain-cached fallback** when IOKit
  returns none (`keychainFallbackUUID`, `:79-90`).
- The redesign (PAR-36) **reverses this**: fail hard, delete the fallback. **Not done.**

**Trial mint client** — `Sources/StowerMacUI/Startup/StowerTrialMintClient.swift`

```swift
internal struct StowerTrialMintClient: Sendable {
    func mint(fingerprint: String) async -> StowerTrialMint
}
```

- `StowerTrialMint`: `.minted(key:licenseID:)` | `.retryShortly` | `.unreachable`

**Supabase Edge Function** — `supabase/functions/license/`

- `KeygenAdmin.createTrialLicense()` → POST license under Trial policy, 30d expiry
- `KeygenAdmin.upgradeToPaid(licenseID)` → PUT policy (→ Paid) + PATCH expiry (→ null). **No entitlement attach.**
- `TrialStore`: `device_trials` table (fingerprint PK, `status` lifecycle: `pending`→`active`, `claim_id` for crash recovery)
- `PurchaseStore`: `purchases` table (`ls_order_id` PK, FK to `device_trials.keygen_license_id`)

### 5b. Intended (the Railway-backed Keygen redesign — not yet implemented)

The facade the plans describe. **None of this exists in code yet.**

**Rewritten startup license seam** (Plan B):

```swift
internal protocol StowerLicenseGating: Sendable {
    func hasLease() -> Bool                    // pure-local Keychain read (replaces hasStoredLicense)
    func currentStatus(now: Date) async -> StowerLicenseStatus  // NEW
    func activate(key: String) async -> StowerLicenseActivation // drops instanceID
}
```

- `StowerLicenseStatus`: `.valid` | `.expired(licenseID:)` | `.wrongVersion(licenseID:)` | `.couldNotReach` | `.needsTrialOnline`
  - `.wrongVersion` is the gate state for a license that is valid (paid, unexpired, good signature) but does not hold this build's required entitlement. Without it, the gate can't distinguish "trial expired, buy it" from "you have a valid license, just not for this major" — the version-unlock model (§1) is unenforceable without this branch.
- `StowerLicenseEntryContext`: `.trialEnded(licenseID:)` | `.upgradeRequired(licenseID:)` | `.connectOnce` | `.couldNotReach` | `.activationFailed(StowerLicenseGateError)`
  - `.upgradeRequired` is the entry-screen context `.wrongVersion` routes to. It carries the `licenseID` so the buy screen can build the upgrade checkout URL. Distinct from `.trialEnded` (first-time purchase vs. cross-major upgrade — different copy, different checkout target).
- `StowerCheckingLicenseReason`: `.startingTrial` | `.activating` | `.revalidating`
- `StowerLicenseActivation`: `.activated` | `.invalid` | `.couldNotReach` (no `instanceID`)
- New conformer: `StowerRailwayLicenseGate` (composes the Plan-A local seams and
  talks to Railway for online licensing)
- Delete: `StowerLemonSqueezyLicenseGate`, `StowerLicenseStore`, `StowerLemonSqueezyClient`

**Railway client** (§C):

- `StowerRailwayLicenseClient` is the only online licensing client used by the
  Mac app. It calls Railway endpoints for trial mint, reachable launch check-in,
  checkout URL creation, manual key activation fallback, and Re-check after
  purchase.
- Railway validates with Keygen, reads effective entitlements, applies the OR
  rule, activates machines, and checks out signed machine files using
  `include=license.entitlements,license.policy,license`.
- Railway returns the signed machine file and minimal gate status to the Mac app.
  The app does not call Keygen directly on the online path.

**Lease extension** (§C):

- `StowerLicenseLease` carries entitlement codes from the signed machine-file,
  so offline launches enforce the OR-check from the file, not the network.

**Machine-file lifecycle** (§C):

Keygen validation and Keygen machine-file checkout are separate operations.
`validate-key` does not automatically return a signed offline lease. Railway
must explicitly check out a signed machine file whenever the app needs refreshed
offline authority, then return that signed file to the Mac app for storage.

**Offline boundary = the machine file's TTL (`meta.expiry`), for both trial and
paid.** This follows Keygen's official guidance: assert `meta.expiry > now` on
every launch; if expired, the user must reconnect to check out a fresh file.
No grace window beyond the TTL. The license's own expiry
(`included[license].attributes.expiry`) is carried in the signed payload but is
**not** the offline boundary — it's the trial clock (30 days) or `null` (paid
perpetual). The TTL is the offline gate; the license expiry is server-side
state that propagates through fresh check-outs.

Stower uses a **7-day machine-file TTL** (`604800` seconds). Keygen's checkout
API takes `ttl` in seconds and uses it to calculate `meta.expiry`; Railway must
keep passing `ttl=604800`. The TTL is not a refresh heuristic. If the app can
reach Railway when it opens, Railway validates/checks in with Keygen and checks
out a fresh 7-day machine file every time. If the app cannot reach Railway, it
falls back to the cached signed file only until that file's `meta.expiry`.

1. **First trial start (online):** the app calls Railway; Railway mints or
   returns the trial license, validates/activates the Keygen license for the
   device, explicitly checks out a signed machine file with
   `include=license.entitlements,license.policy,license`, and returns the signed
   file for local storage.
2. **App open while online/reachable (trial or paid):** the app calls Railway;
   Railway validates the license with Keygen, applies any trial-extension logic,
   then checks out and returns a fresh signed machine file with `ttl=604800`
   before the app proceeds. The cached file is refreshed on every reachable
   launch.
3. **App open while offline/unreachable (trial or paid):** verify the local signed machine
   file's Ed25519 signature, assert `meta.expiry > now` (TTL not expired), and
   check the signed entitlements include `STOWER_TRIAL` or the build's required
   paid entitlement. If the TTL has expired → blocked, show the connect screen.
   No grace. No "use the license expiry instead of the TTL."

**Fingerprint reversal** (PAR-36):

- `StowerDeviceFingerprint` fails hard when `IOPlatformUUID` is absent; the
  Keychain fallback is deleted.

**Purchase webhook extension** (Plan Beta Railway backend):

- Railway's paid-upgrade path adds a third step: `POST /licenses/{id}/entitlements` with
  `KEYGEN_V0_ENTITLEMENT`. 400 "already attached" → success (idempotent).
- Missing `KEYGEN_V0_ENTITLEMENT` → fail loudly (never ship a paid license
  with no major stamp).

**v0 purchase detection**:

- Checkout targets the existing device license id carried by
  `.trialEnded(licenseID:)` / `.upgradeRequired(licenseID:)`.
- The Lemon Squeezy webhook handled by Railway is the only component that mutates
  the license to paid: policy → Paid, expiry → `null`, direct `STOWER_V0`
  entitlement attached.
- The app does not infer purchase completion from Lemon Squeezy UI state. For
  v0, the paywall exposes an explicit Re-check action; that action calls
  Railway. Railway validates the same Keygen license, reads effective
  entitlements, observes `STOWER_V0`, checks out a fresh signed machine file,
  and returns it to the app.
- If the webhook has not completed yet, Re-check leaves the user on the paywall
  with retry copy. Background polling, deep-link return, and automatic checkout
  completion detection are future UX improvements, not required for v0.

**Bootstrap script** (§A — `supabase/functions/license/scripts/bootstrap-keygen.ts`):

- Idempotent find-or-create: Product `stower`, policies `STOWER_TRIAL_POLICY`
  + `STOWER_PAID_POLICY`
  (`ED25519_SIGN`, `LICENSE`, `maxMachines:1`, `UNIQUE_PER_PRODUCT`; Paid: no
  `duration` + `RESET_EXPIRY`), entitlements `STOWER_TRIAL` (→ Trial policy) +
  `STOWER_V0` (unattached). Prints JSON ids to stdout.

**Trial-extension service** (Plan Beta Railway backend):

- **Why it exists:** `licensing.md` promises a +7-day trial extension when a
  new major ships during a user's trial. Keygen has no rules/scheduling engine,
  so this is Railway backend runtime logic, not a Keygen capability and not app
  logic.
- **What it does:** on trial check-in, Railway reads Supabase trial state,
  compares the major the trial started under against a backend "current latest
  major" config; once per new major, it `PATCH`es the Keygen license
  `expiry += 7d`.
- **State required:** new column on `device_trials` (`extended_for_majors`,
  e.g. `text[]`) in Supabase to keep the extension idempotent and capped at
  once per major.
- **New app→backend seam:** today the app calls Supabase only once
  (`mint-trial`); the extension requires a Railway check-in call during trial
  launches. The primary trigger is request-driven app-open check-in, not cron:
  the Mac app opens, calls Railway, Railway reads Supabase and patches Keygen if
  the once-per-major extension applies. Cron can be a later reconciliation tool,
  but it is not the load-bearing expiry mechanism.
- **Does not restart the trial.** The extension adds 7 days to the existing
  expiry; it does not reset the clock. A trial that's day-25 of 30 becomes
  day-25 of 37, not day-0 of 7.

### 5c. The gap (what the plans are building)

| # | What | Status | Owned by |
|---|------|--------|----------|
| G1 | Facade rewrite (`StowerLicenseGating` → Railway-backed Keygen shape) | not started | Plan B |
| G2 | `StowerRailwayLicenseGate` (new conformer + §C entitlement check) | not started | Plan B |
| G3 | `StowerRailwayLicenseClient` returns gate status + signed machine file from Railway | not started | Plan B (§C) |
| G4 | `StowerLicenseLease` carries entitlements | not started | Plan B (§C) |
| G5 | `StowerRailwayLicenseGate` implements the machine-file lifecycle in §5b | not started | Plan B (§C) |
| G6 | Fingerprint fallback deleted (PAR-36) | not started | PAR-36 ticket (not Plan B — Plan B's Non-goals exclude it; must land before selling paid licenses) |
| G7 | Delete `StowerLemonSqueezyLicenseGate` + `StowerLicenseStore` | not started | Plan B |
| G8 | Webhook attaches `STOWER_V0` (§B) | not started | Plan Beta (Railway webhook) |
| G9 | Bootstrap script creates structures (§A) | not started | Bootstrap plan |
| G10 | `keygenPublicKeyHex` replaced with real key | not started | Prod ops |
| G11 | Local Keygen CE harness (regression net) | not started | Plan 2 |
| G12 | Railway licensing backend service (runtime check-in + backend +7d on new major) | briefed | Plan Beta |
| G13 | `device_trials.extended_for_majors` Supabase state + idempotent once-per-major cap | briefed | Plan Beta |

---

## 6. Load-bearing invariants

If any of these break, paying customers get locked out or the model is
vaporware. Plans must not violate these.

| # | Invariant | Why it's load-bearing |
|---|-----------|----------------------|
| I1 | §C must not go live before §A + §B | A gate checking for `STOWER_V0` before the webhook stamps it rejects every paying customer |
| I2 | Trial and Paid policies are policy-change-compatible | trial→paid `PUT /policy` 422s if they differ on crypto scheme / encrypted / pooled / fingerprint-strategy |
| I3 | `STOWER_V0` is license-level, not policy-level | License-level is the only shape that lets unlocks "add up" across majors |
| I4 | Railway applies the online OR and the Mac app applies the offline OR from the signed file | Keygen `scope.entitlements` is AND-only; an AND scope can't express "v0 OR trial" |
| I5 | The offline path enforces entitlements from the signed file | Otherwise an offline `STOWER_V0` lease could run a future v1 build |
| I6 | Machine-file signature is verified on every `load()` | A tampered cache must be rejected, not trusted |
| I7 | Railway's paid-upgrade path fails loudly on missing `KEYGEN_V0_ENTITLEMENT` | A silent skip ships paid licenses with no recorded major — the exact regression this work exists to prevent |
| I8 | One license per device (born Trial, flipped to Paid in place) | Same license id/key throughout; the paywall needs the `licenseID` to build the upgrade URL |
| I9 | `device_trials` claim is crash-recoverable | A mint that dies mid-flow neither double-mints nor returns nulls |
| I10 | Webhook validates before marking processed | A bad variant is never recorded; a transient Keygen failure stays retryable |
| I11 | The +7-day extension is idempotent and capped at once per new major | Without `extended_for_majors` state, a check-in could double-extend or extend every launch |
| I12 | The extension adds to the existing expiry; it does not restart the trial | A restart would break the "one trial per device" promise and let a user reset their clock by downloading a new major |
| I13 | Online validation and machine-file checkout stay separate inside Railway | `validate-key` is not an offline lease; without explicit checkout, offline launch decisions use stale or missing signed state |
| I14 | The machine file TTL (`meta.expiry`) is the hard offline boundary for both trial and paid — no grace | Per Keygen's guidance: assert `meta.expiry > now`; expired file → blocked, must reconnect. A grace window (Plan B's `paidGraceAllows`) would let revoked/suspended licenses run indefinitely offline and enable clock-tampering to extend use |
| I15 | The license's own expiry (`included[license].attributes.expiry`) is NOT the offline boundary | The TTL gates offline access; the license expiry is server-side state (30-day trial clock / `null` perpetual) that propagates through fresh check-outs, not a second offline clock the app honors independently |

---

## 7. How plans sign against this

1. A plan opens with the exact contract version it signs against, e.g.
   "Signs against `licensing-contract.md` v1.12."
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
