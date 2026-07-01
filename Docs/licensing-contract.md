# Stower — Licensing Contract

> The stable engineering contract for the licensing system. Customer-facing terms
> live in `licensing.md`; this is the facade every implementation plan signs
> against. Grounded in source; updated when the **contract** changes, not when
> code changes. If a plan describes a seam shape that contradicts this file, the
> plan is wrong — not this file.
>
> **Verification lives here too:** the test-coverage map (§9) and the smoke runbook
> (§10) are operational docs — not part of the version-pinned contract (§1–§8) —
> and may change without a contract version bump. Plans still sign against the
> §1–§8 contract version only.

**Version:** 2.0 · **Last updated:** 2026-07-01 · **Canonical home:** this file.

When the contract changes: edit here, bump the version, record the change in
§Changelog. Plans reference this file by version number.

> **Note (2026-07-01): this is a major-version bump (1.21 → 2.0), not an
> incremental sync.** The entire Keygen + Supabase Edge Function licensing
> backend described by every earlier version of this file — `supabase/functions/license/`,
> `Scripts/Keygen/`, all DB migrations, and every Swift client that talked to
> them — has been **deleted**. It is replaced by a client-only Lemon Squeezy
> activate-once flow plus a local 7-day trial clock. Sections §1–§5 below
> describe the new as-built system from scratch. The full history of the
> deleted Keygen/Supabase design lives in §Changelog entries 1.0–1.21 (kept
> for archaeology; none of it is live).

## Sequencing

```text
Lemon Squeezy migration ✓ (done — Keygen/Supabase backend deleted,
  StowerLemonSqueezyClient + StowerLicenseStore + StowerTrialClock landed)
  → prod ops (real Lemon Squeezy store id / product id / checkout URL, G1)
  → enable paid sales
```

The migration is merged: the app's only licensing network call is a direct
`POST` to Lemon Squeezy's public `/v1/licenses/activate`, backed by a local
7-day trial clock and plaintext `UserDefaults` license storage. The only
remaining pre-sales step is prod ops: Emily supplying the real Lemon Squeezy
`store_id`, `product_id`, and buyable checkout URL (§"Open questions" / G1);
`StowerLicenseConfig.production` currently ships placeholders that fail every
activation closed.

---

## 1. The Stower model (stable)

The parts that don't move between plans. If a plan contradicts any of these,
the plan is wrong.

- **7-day, card-free local trial, one per install.** First launch seeds a
  local first-launch date (`StowerTrialClock`, `UserDefaults` key
  `com.stower.trial.firstLaunch`); the trial is active for
  `StowerTrialClock.trialDuration` (7 days) from that date, and never moves
  once seeded (I3).
- **No online trial provisioning.** There is no server call to start a trial —
  `StowerTrialClock.state(now:)` is a pure local computation. "One per
  install" is enforced only by the local `UserDefaults` first-launch date; it
  is resettable by wiping app data or via the DEBUG `--reset-trial` lever
  (§Non-goals).
- **One-time Lemon Squeezy purchase, activate once, trust forever.** Buying
  Stower gets you a Lemon Squeezy license key (delivered by email). Entering
  that key in `StowerLicenseEntryView` calls `/v1/licenses/activate` exactly
  once; on success the key + the returned Lemon Squeezy `instance.id` are
  stored locally (`StowerLicenseStore`, plaintext `UserDefaults`) and the app
  runs fully offline forever after — no periodic re-check, no `/validate`
  call, ever (see Non-goals).
- **No per-major-version entitlement gating today.** `StowerLemonSqueezyClient`
  checks only that an `/activate` response's `meta.store_id` /
  `meta.product_id` match Stower's configured `StowerLicenseConfig.storeID`
  / `.productID` — i.e. "is this a Stower license at all," not "which major
  version does it unlock." A stored license (`StowerLicenseState.licensed`)
  runs any build forever. See §"Business-model note" below — this is a
  deliberate simplification of Emily's longer-term per-major pricing
  philosophy, not a business decision this contract makes unilaterally.
- **The gate checks local state at launch, not a server.** `StowerLicenseGating.licenseState(now:)`
  is a synchronous, local, no-network read: a stored license → `.licensed`;
  no stored license and the trial clock is active → `.trial(expiry:)`; no
  stored license and the trial clock has elapsed → `.expired`. Only
  `.expired` routes to the paywall (`StowerStartupModel.route(licenseState:)`).
- **Exactly one network call in the whole licensing system.** `StowerLicenseGating.activate(key:)`
  → `StowerLemonSqueezyClient.activate(key:instanceName:)` → `POST
  https://api.lemonsqueezy.com/v1/licenses/activate`. Nothing else in the
  licensing path ever touches the network — not the trial clock, not the
  license-state read, not app-open/foreground re-checks.
- **Downloading is free; *running past the trial* is what's licensed.** The
  repo is open and the app is shareable. The trial gives 7 days of full
  local use before a key is required.

---

## 2. Vendor split (stable)

| Vendor | Role | Issues licenses? |
|--------|------|-------------------|
| **Lemon Squeezy** | Merchant of record — takes money, handles tax/refunds, issues and validates license keys via its own hosted `/v1/licenses/activate` endpoint. Owns payments, refunds, and webhooks entirely; Stower's app never receives a webhook | **Yes** (the sole license authority) |

There is no second vendor. There is no Stower-operated backend of any kind —
no Supabase project, no Edge Function, no Postgres, no Keygen account. Lemon
Squeezy is both the payment processor and the license-key authority; the app
talks to it directly and only at activation time.

---

## 3. The facade contract — seam shapes (as-built)

This is the boundary consumers depend on. **Stable at the seam; free to churn
behind it.**

**The startup license seam** — `Sources/StowerMacUI/Startup/StowerLicenseGating.swift`

```swift
internal protocol StowerLicenseGating: Sendable {
    func licenseState(now: Date) -> StowerLicenseState
    func activate(key: String) async -> StowerLicenseActivation
    func persist(key: String, instanceID: String)
}
```

- `StowerLicenseState`: `.licensed` | `.trial(expiry: Date)` | `.expired`
  (`Sources/StowerMacUI/Startup/StowerLicenseGating.swift`)
- `StowerTrialBadge { expiry: Date }` — the badge data for an active trial;
  present only on `.trial`, never constructed for `.licensed`
- `StowerLicenseActivation`: `.activated(instanceID: String)` | `.invalid` |
  `.couldNotReach` (`Sources/StowerMacUI/Startup/StowerLicenseActivation.swift`)
- `StowerLicenseGateError`: `.invalid` | `.couldNotReach` — the entry-screen
  error carried by `StowerStartupState.needsLicense(StowerLicenseGateError?)`
- Production conformer: **`StowerLemonSqueezyLicenseGate`**
  (`Sources/StowerMacUI/Startup/StowerLemonSqueezyLicenseGate.swift`), wired
  at `StowerRootView.swift:95` (`StowerLemonSqueezyLicenseGate()`)
- Consumed by: `StowerStartupModel` (calls `licenseState(now:)` on every
  startup run and on `refreshLicenseIfOnBoard()`; calls `activate(key:)` +
  `persist(key:instanceID:)` from `activate(key:)`, under a generation guard
  so a superseded activation attempt never persists, I4)

**Lemon Squeezy activate client** — `Sources/StowerMacUI/Startup/StowerLemonSqueezyClient.swift`

```swift
internal struct StowerLemonSqueezyClient: Sendable {
    func activate(key: String, instanceName: String) async -> StowerLicenseActivation
}
```

- The app's **only** licensing network call: `POST https://api.lemonsqueezy.com/v1/licenses/activate`,
  form-encoded body `license_key` + `instance_name`. Needs no API key —
  `/activate` is a public Lemon Squeezy endpoint that verifies the key and
  enforces `activation_limit` server-side.
- Decodes only a minimal shape: `activated: Bool`, `instance.id`, and the
  product-identity `meta.store_id` / `meta.product_id`. Never decodes, stores,
  or logs `meta.customer_email` / `customer_name` (I1).
- `/activate` is global across Lemon Squeezy: a valid key for **any** LS
  store/product returns `activated: true`. The client requires the response's
  `meta.store_id` == `StowerLicenseConfig.storeID` **and** `meta.product_id`
  == `StowerLicenseConfig.productID` before returning `.activated` — otherwise
  a key for a different product would unlock Stower. A mismatch is `.invalid`
  (I2).
- A transport error, a `5xx` response, or an undecodable body is
  `.couldNotReach` — recoverable, and also the offline-first-run case.
  `activated: false`, or a store/product mismatch, is `.invalid`.
- 15-second request timeout so a blackholed network fails fast instead of
  hanging on `URLSession`'s ~60s default.

**License storage** — `Sources/StowerMacUI/Startup/StowerLicenseStore.swift`

```swift
internal struct StowerStoredLicense: Sendable, Equatable {
    let key: String
    let instanceID: String
}
```

- Plaintext `UserDefaults` under keys `com.stower.license.key` /
  `com.stower.license.instanceID` (`StowerLicenseStore.read()` /
  `.write(_:)` / `.clear()`).
- **Deliberately plaintext, not Keychain** (I5) — see §"Storage & threat
  model" below.
- `instanceID` is the Lemon Squeezy `instance.id` returned by `/activate`;
  captured for a possible future `/validate`/`/deactivate` call, but no launch
  logic reads it today — there is no `/validate` call anywhere in this
  system.

**Trial clock** — `Sources/StowerMacUI/Startup/StowerTrialClock.swift`

```swift
internal struct StowerTrialClock: Sendable {
    func state(now: Date) -> StowerTrialClockState  // .active(expiry:) | .expired
    func reset()
}
```

- `UserDefaults`-backed, key `com.stower.trial.firstLaunch`. The first-launch
  date is written once, on the first `state(now:)` call, and never moves
  afterward (I3) — so a relaunch, a slow first read, or a clock skew can
  never silently reset or extend the trial.
- `StowerTrialClock.trialDuration`: `Duration.seconds(7 * 24 * 60 * 60)` — 7
  days, card-free.
- `reset()` clears the first-launch date; used only by the DEBUG
  `--reset-trial` launch-argument lever (§Non-goals), compile-stripped from
  Release.

**Production gate composition** — `Sources/StowerMacUI/Startup/StowerLemonSqueezyLicenseGate.swift`

`StowerLemonSqueezyLicenseGate` composes the three collaborators above:

```swift
internal func licenseState(now: Date) -> StowerLicenseState {
    guard store.read() == nil else { return .licensed }
    switch trialClock.state(now: now) {
    case .active(let expiry): return .trial(expiry: expiry)
    case .expired: return .expired
    }
}
```

A stored license always wins over the trial clock — once activated, the app
never re-derives trial state. The DEBUG-only `init()` convenience applies
`StowerLicenseDebugArguments` (`--clear-license` clears the store,
`--reset-trial` resets the clock) **before** constructing the gate, so a
developer can force either path without touching `UserDefaults` by hand;
`#if DEBUG`-stripped from Release.

**App-side config** — `Sources/StowerMacUI/Startup/StowerLicenseConfig.swift`

```swift
internal struct StowerLicenseConfig: Sendable, Equatable {
    let checkoutURL: String
    let storeID: Int
    let productID: Int
}
```

- All three fields are **public** — no secret ships in the binary, because
  `/activate` needs no API key. `storeID`/`productID` are load-bearing only
  in that a placeholder `0` fails every activation closed, not because they
  are secret.
- Resolution: compiled default (`staging` in `DEBUG`, `production`
  otherwise) → optional `STOWER_CHECKOUT_URL` / `STOWER_STORE_ID` /
  `STOWER_PRODUCT_ID` `ProcessInfo` override, applied **only in DEBUG**
  (`effectiveConfig(allowOverrides:)`; Release always pins the compiled
  config). See `EnvironmentVariables.md` §1.
- **Both `.production` and `.staging` currently ship placeholders**
  (`checkoutURL: ""`, `storeID: 0`, `productID: 0`) — a known pending release
  gate (§"Open questions" G1), not a bug. Activation fails closed
  (`.invalid`, since `0` never matches a real product) until Emily supplies
  the real values.

**DEBUG launch-argument levers** — `Sources/StowerMacUI/Startup/StowerLicenseDebugArguments.swift`

```swift
internal struct StowerLicenseDebugArguments: Equatable {
    let clearLicense: Bool  // --clear-license
    let resetTrial: Bool    // --reset-trial
}
```

`#if DEBUG`-only; the whole seam (parser + gate wiring) is compile-stripped
from a Release archive, so a customer build has no path to these levers. The
old Keygen-era `--fingerprint` / `--clear-lease-on-start` flags no longer
exist anywhere in this codebase.

**Startup routing** — `Sources/StowerMacUI/Startup/StowerStartupModel.swift` /
`StowerStartupState.swift`

- `StowerStartupState.needsLicense(StowerLicenseGateError?)` — the
  paywall/key-entry screen, carrying the last activation error (if any) so a
  re-render after a failed attempt still shows it. There is no separate
  `.checkingLicense` state — the license read is synchronous and local, so
  there is nothing to show a spinner for.
- `route(licenseState:)`: `.licensed` and `.trial` both proceed into the
  board probe (`.checkingMessages` → `.connectedPreparingBoard`); `.expired`
  routes straight to `.needsLicense(nil)`.
- `activate(key:)` is called from the key-entry view under a generation
  token (I4): only the current-generation activation result may persist a
  license or commit a state, so a superseded/stale activation never
  overwrites a newer one.
- `refreshLicenseIfOnBoard()` is a **pure local re-read** (no network),
  called on `didBecomeActive` (e.g. returning from the Lemon Squeezy
  checkout in the browser). It only routes away from the board if the trial
  just expired (`.expired` → `.needsLicense(nil)`); `.licensed` and `.trial`
  leave the board untouched.
- `showLicenseEntry()` lets the user jump to the key-entry screen mid-trial
  (JC5 — the gear menu's "Enter license key…" item and the F2 board banner
  both call it), without waiting for the trial to expire.

**Paywall / key-entry screen** — `Sources/StowerMacUI/Views/StowerLicenseEntryView.swift`

- `@Binding var key: String`, `error: StowerLicenseGateError?`, `onActivate:
  (String) -> Void`, `onBuy: () -> Void`.
- `StowerLicenseEntryView.normalize(_:)` — paste-forgiveness: trims
  whitespace/newlines, then strips a leading `key:` / `license key:` /
  `license_key=` label or an `https://…/` URL prefix, so a key pasted with
  copy-paste junk around it isn't falsely rejected.
- This is the **only** screen from which the app makes a network call, and
  its copy says so ("Stower connects once to verify your purchase, then
  works entirely offline").

**Root view wiring** — `Sources/StowerMacUI/Views/StowerRootView.swift`

- Constructs `StowerLemonSqueezyLicenseGate()` (line 95).
- `openCheckout()` opens `StowerLicenseConfig.resolved.checkoutURL` via
  `NSWorkspace.shared.open` and sets a `boughtThisSession` flag (drives the F2
  banner state below).
- On a successful `model.activate(key:)`, shows an alert: "You're all set." /
  "Thanks for buying Stower — your license is active on this Mac. Enjoy."
  (F1).

**Board banner** — `Sources/StowerMacUI/Views/StowerBoardBannerState.swift` /
`StowerBoardBannerView.swift`

The board's one bottom-banner slot is a 4-state machine
(`StowerBoardBannerState.resolve(...)`):

| Case | When | Behavior |
|------|------|----------|
| `.none` | Licensed, or trial expired | No banner |
| `.trialBadge(expiry:)` | Active trial, more than 1 day left | Quiet, dismissible, shows the trial end date |
| `.buyNudge(expiry:)` | Active trial, ≤1 day left (F3) | Non-dismissible: "Your free trial ends tomorrow — Buy Stower to keep your board." + Buy button |
| `.enterKey` | Returned from checkout this session (`boughtThisSession`) with no license stored yet (F2) | "Finished your purchase? Enter the license key from your email." + Enter-license-key button |

**Board gear menu** — `Sources/StowerMacUI/Views/StowerBoardViewTriage.swift`

- "Buy Stower" + "Enter license key…" (JC5), shown only while `trial != nil`
  (i.e. only during an active trial). Once licensed, the menu renders with no
  items (control disabled rather than an empty dead-end).

**Analytics funnel** — `Sources/StowerMacUI/Analytics/StowerAnalyticsEvent.swift`

- `trialStarted` — fires once per install: the single launch whose license
  read seeds the trial clock (`isFirstTrialObservation(now:)`), with the
  per-launch `trialStartedThisLaunch` latch kept as defense-in-depth.
- `paywallReached(error:)` — fires on the forced-paywall `.needsLicense`
  commits: startup's expired-trial routing and the on-board expiry re-check
  (`refreshLicenseIfOnBoard()`). The voluntary jump (`showLicenseEntry()`)
  and failed-activation error re-commits pass `emitsFunnelEvent: false` and
  do not fire it.
- `checkoutOpened` — fires from `openCheckout()`.
- `activated` — fires on a successful `activate(key:)` outcome, **after**
  `persist(key:instanceID:)` is called.
- The old Keygen-era `licenseGateReached` / `licenseUnreachable` events and
  `StowerLicenseEndpoint` type no longer exist.

---

## 4. Storage & threat model (as-built)

- **License** (`StowerStoredLicense`: `key`, `instanceID`) — plaintext
  `UserDefaults`, keys `com.stower.license.key` / `com.stower.license.instanceID`.
- **Trial first-launch date** — plaintext `UserDefaults`, key
  `com.stower.trial.firstLaunch`.
- **Neither uses Keychain (I5).** A license key is a low-value bearer token
  the user already holds in their purchase email; this is an
  anti-casual-copy gate, not tamper-proof DRM. It is deliberately resettable
  by wiping app data (or, in DEBUG, `--clear-license`/`--reset-trial`) — an
  honest tradeoff, not an oversight.
- **No revocation, no re-check, ever (I6).** There is no `/validate` call
  and no periodic re-check of any kind. Once `StowerLicenseStore.read()`
  returns a stored license, the app trusts it forever, offline, for the
  rest of its life. A refunded or chargeback'd purchase therefore keeps
  local access — an accepted tradeoff, not a bug: Lemon Squeezy (the
  merchant of record) owns refunds/chargebacks/disputes; the app has no
  server-side hook to revoke anything even if it wanted to.
- **No device binding beyond Lemon Squeezy's own `activation_limit`.** The
  app does not compute or send a hardware fingerprint. Lemon Squeezy's
  `instance_name` label is purely descriptive ("Stower"); enforcement of
  "how many machines can activate this key" is entirely Lemon Squeezy's
  server-side `activation_limit`, not anything the app enforces or checks.

---

## 5. Non-goals / judgment calls already made

- **No `/validate` or periodic re-check, ever.** Activate-once, trust local
  storage forever. A refunded user keeps access — accepted tradeoff (§4).
- **No server of any kind.** Lemon Squeezy owns payments, tax, refunds, and
  webhooks; the app owns only local activation state. There is no Stower
  backend to operate, deploy, or monitor.
- **No per-major-version entitlement gating in code today.** See
  §"Business-model note" below.
- **Trial + license storage is plaintext `UserDefaults`, not Keychain.**
  Anti-casual-copy, not DRM, and deliberately resettable (§4).
- **No `try!`/force-unwrap anywhere in this seam** (repo-wide rule, verified
  by `swiftlint`/`swift-signal-review`, not specific to licensing).

### Business-model note — read before touching pricing/trial-length claims

`Docs/licensing.md` (customer-facing terms) was written against the **old**
Keygen/Supabase design and describes a **30-day trial**, entitlement
stacking across majors (`STOWER_V0`/`STOWER_V1`/etc.), and "$30 one-time per
major version." The as-built Lemon Squeezy system described in this file:

- runs a **7-day** trial (`StowerTrialClock.trialDuration`), not 30 days;
- checks only `store_id`/`product_id` (I2) — i.e. "is this a Stower license
  at all," not "which major version" — so there is **no per-major-version
  unlock mechanism in code** today.

This contract does **not** decide whether that's the permanent business
model or a temporary v0 simplification — that is Emily's call, not an
engineering one. `licensing.md` carries an explicit "As-built (v0)" note
where its claims diverge from the code; this file states the code fact only.
See "Open questions" below.

---

## 6. How plans sign against this

1. A plan opens with the exact contract version it signs against, e.g.
   "Signs against `licensing-contract.md` v2.0."
2. A plan may build behind the facade (internal impl) or migrate the facade
   (seam shape change). A facade migration is a **one-way door** —
   deliberate, versioned, and updates every downstream consumer in the same
   pass.
3. A plan that asserts a seam shape must match §3. If it contradicts §3, the
   plan is wrong.
4. A plan that asserts a model fact must match §1–§2. If it contradicts
   them, the plan is wrong.
5. When a plan changes the contract (new seam, new invariant, model
   evolution), it updates **this file** first, bumps the version, then
   reflects the scoped slice in its own Tasks. Never re-define the contract
   in a plan.

---

## 7. Load-bearing invariants

If any of these break, paying customers get locked out, a non-Stower key
unlocks the app, or a secret leaks. Plans must not violate these.

| # | Invariant | Why it's load-bearing |
|---|-----------|----------------------|
| I1 | `StowerLemonSqueezyClient` decodes only `activated`/`instance.id`/`meta.store_id`/`meta.product_id` — never `meta.customer_email`/`customer_name` | A wider decode risks logging or otherwise leaking PII the app has no reason to hold |
| I2 | `/activate`'s response `meta.store_id`/`meta.product_id` must match `StowerLicenseConfig.storeID`/`.productID` before `.activated` is returned | `/activate` is global across Lemon Squeezy — without this check, a valid key for a *different* LS product would unlock Stower |
| I3 | `StowerTrialClock`'s first-launch date is written once and never moves | Otherwise a relaunch, slow first read, or clock skew could silently reset or extend the trial |
| I4 | `StowerStartupModel.activate(key:)` persists/commits only under the current generation token | A superseded activation attempt (e.g. the user retried, or navigated away) must never overwrite a newer result |
| I5 | License + trial storage is plaintext `UserDefaults`, not Keychain | Deliberate: anti-casual-copy, not DRM; must stay easily resettable by design, not accidentally insecure |
| I6 | There is no `/validate`/revocation call anywhere in the licensing path | Once activated, the app is offline-forever by design; adding a hidden re-check would silently change the trust model this contract documents |
| I7 | The app's only licensing network egress is `api.lemonsqueezy.com` | No Keygen/Supabase/Edge-Function host or route may reappear — enforced by `Scripts/precheck.sh`'s `6o` static guard |

---

## 8. Open questions (release gate, not engineering debt)

| # | What | Status | Owned by |
|---|------|--------|----------|
| G1 | Real Lemon Squeezy `store_id` / `product_id` / buyable checkout URL (`StowerLicenseConfig.production`/`.staging` currently placeholders) | **not supplied yet** | Emily |
| G2 | A test-mode Lemon Squeezy license key to verify activation end-to-end | **not supplied yet** | Emily |
| G3 | Lemon Squeezy store/product approval status (can it accept live payments yet) | **not supplied yet** | Emily |
| G4 | Whether the 7-day trial / no-per-major-gating shape is the permanent business model or a v0 simplification | **business decision, not engineering** | Emily — see §"Business-model note" |

Until G1–G3 are resolved, every `/activate` call fails closed
(`storeID`/`productID` of `0` never matches a real Lemon Squeezy response) —
this is intentional fail-closed behavior, not a bug to fix in code.

---

## 9. Test coverage map

> Operational doc. Not part of the version-pinned contract (§1–§8).

What is verified automatically vs. by a human on a real build, for the
trial → paywall → activate lifecycle.

### 9.1 What IS automated

- **`Scripts/precheck.sh`** (every commit): swift-format, swiftlint, `swift
  build`, `swift test`, and the static source guard **`6o`** — asserts no
  `supabase`/`keygen`/`/check-in`/`mint-trial`/`mint_trial` token exists
  anywhere in `Sources/` (the deleted backend can't silently reappear, I7),
  and that `api.lemonsqueezy.com` still appears somewhere in `Sources/` (the
  guard can't pass vacuously if the client's host literal moves or is
  deleted).
- **Swift unit tests** covering: `StowerLemonSqueezyClient.activate` (the
  store/product match, the `.couldNotReach`/`.invalid`/`.activated`
  classification, malformed-body handling), `StowerLicenseStore`
  read/write/clear, `StowerTrialClock.state(now:)` (seed-once behavior,
  active vs. expired boundary), `StowerLicenseConfig.resolve`/`effectiveConfig`
  (env override precedence, DEBUG vs. Release gating, malformed-int
  fallback), `StowerLicenseDebugArguments.parse` (flag matrix), and
  `StowerLicenseEntryView.normalize(_:)` (paste-forgiveness prefixes).
- **`StowerStartupModel` tests**: the generation-guard invariant (I4) — a
  superseded `activate(key:)` result never persists or commits; the
  `.licensed`/`.trial`/`.expired` routing; `refreshLicenseIfOnBoard()`'s
  board-only, expired-only-routes-away behavior.

### 9.2 What a human verifies by hand on a real build

- **The debug levers are absent in Release** — a Release archive ignores
  `--clear-license`/`--reset-trial` (the `StowerLicenseDebugArguments` seam
  is `#if DEBUG`-only and compile-stripped). Confirm a Release build does
  not react to them.
- **The 7-day trial expires on-screen** → `StowerLicenseEntryView` shows,
  and the trial badge/banner disappears.
- **A real Lemon Squeezy test-mode purchase activates the license** —
  paywall/gear menu → Buy → complete a test-mode checkout → paste the key →
  Activate.
- **The board banner's 4-state matrix** (`.none`/`.trialBadge`/`.buyNudge`/`.enterKey`)
  — verified by eye; this repo forbids ViewInspector/XCUITest, so it is not
  on the automated tier.

### 9.3 What CANNOT be automated (by design)

- **The on-screen trial-expiry observation** — no injection seam for "watch
  the actual UI transition."
- **The real Lemon Squeezy payment money path** — a one-time test-mode
  purchase, by definition manual.
- **Release-archive QA** — that the shipped binary behaves correctly
  (levers absent, `production` config pinned).

---

## Changelog

| Version | Date | Change |
|---------|------|--------|
| 1.0–1.21 | 2026-06-24 – 2026-07-01 | **Historical — describes the deleted Keygen/Supabase backend.** Documented the Keygen Account→Product→Policy→License→Machine model, the Supabase Edge Function (`supabase/functions/license/`) as the licensing brain (`/mint-trial`, `/check-in`, `/ls-webhook`, `/health`), the once-per-major +7-day trial extension, machine-file/entitlement/offline-authority mechanics, the JC5 request-signature scheme, and the full gap/invariant tracking (G1–G13, I1–I19) for that system. None of this is live; kept only for archaeology. See the pre-2.0 revision of this file in git history for the full text. |
| 2.0 | 2026-07-01 | **Full rewrite — Keygen/Supabase backend deleted, replaced by client-only Lemon Squeezy activate-once + local 7-day trial.** Removed: the Keygen model primer, the Edge Function seam contracts, machine-file/entitlement/policy sections, mint/check-in/webhook flows, offline-authority/lease-store material, and the old §9 test-coverage map — none of that code exists anymore. Added: the as-built seam (`StowerLicenseGating`/`StowerLemonSqueezyClient`/`StowerLicenseStore`/`StowerTrialClock`/`StowerLemonSqueezyLicenseGate`/`StowerLicenseConfig`/`StowerLicenseDebugArguments`), the new invariants I1–I7, the storage/threat model (§4), the business-model note flagging the 30-day-trial/per-major-entitlement claims in `licensing.md` as not (yet) matched by code, and a fresh Open Questions table (G1–G4) for the pending Lemon Squeezy store/product/checkout-URL release gate. Grounded in `StowerLemonSqueezyClient.swift`, `StowerLicenseStore.swift`, `StowerLicenseActivation.swift`, `StowerTrialClock.swift`, `StowerLicenseGating.swift`, `StowerLemonSqueezyLicenseGate.swift`, `StowerLicenseConfig.swift`, `StowerLicenseDebugArguments.swift`, `StowerLicenseDebugArguments.swift`, `StowerStartupModel.swift`, `StowerStartupState.swift`, `StowerLicenseEntryView.swift`, `StowerRootView.swift`, `StowerBoardBannerState.swift`, `StowerBoardViewTriage.swift`, `StowerAnalyticsEvent.swift`, and `Scripts/precheck.sh`'s `6o` guard. |
