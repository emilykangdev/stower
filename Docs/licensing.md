# Stower — Licensing & Pricing

There is no guarantee that there will be a v1 or v2. However, this is the licensing strategy document set in stone, out of consideration for major releases that might happen.

Last Updated Date: 2026-06-23.

> **Note (2026-07-01): the shipped v0 mechanism is simpler than described
> below.** The Keygen + Supabase licensing backend this document was written
> against has been deleted and replaced with a client-only Lemon Squeezy
> activate-once flow plus a **7-day** local trial clock — not the 30-day
> trial or per-major-version entitlement stacking described in §2–§5 below.
> See "As-built (v0)" callouts near each affected section for what the code
> actually does today. This page's pricing philosophy (§1, §6, §7) is kept
> as Emily's stated intent; whether the 30-day/per-major mechanics return in
> a future version is a business decision, not yet made — see
> `licensing-contract.md` §"Open questions."

---

## 1. The model

### Definitions

Stower uses Semver as the standard for assigning every update a version number. https://semver.org/ 

The major version number is shown by the first number: X.y.z means major version X. A real number example: 0.1.2 would be major version 0.

The minor version number is shown by the second number. For example: x.Y.z. Thus, 0.1.0 < 0.2.0 < 0.2.9, etc.

Patch versions will use the third number: x.y.Z. Thus, 0.1.5 < 0.1.6.

Stower will only "upgrade" to the major version X+1 and start releasing new minor updates based on X+1 if significant new capabilities are added. These will be documented. Users are not obligated to pay for any future major version.

### Payment model

> **As-built (v0) note (2026-07-01):** the shipped trial is **7 days**, not
> 30 (`StowerTrialClock.trialDuration`), it is a purely local `UserDefaults`
> clock with no server involved, and there is no trial-extension mechanism —
> the "new major ships → +7 days" behavior described below does not exist in
> code today (there is no concept of "major" the trial clock reasons about
> at all). The aspirational 30-day/extension text below is kept as Emily's
> stated pricing intent, not a description of the current build.

Every customer gets **30 days to try Stower before paying** — whether you're new or
an existing customer. Existing customers also get a **discount on upgrades**, as a
thank-you for sticking with it. Stower can offer this because it's sold **directly,
not through the Mac App Store**. It needs Full Disk Access to read your iMessages,
which the App Store doesn't allow (and the App Store can't do upgrade discounts
anyway).

Your 30 days are **version-agnostic**: the trial runs whatever the latest major
version is, not a fixed one.

**If a new major version is released during your trial, your trial is extended by a
flat 7 days so you have time to try it. There is one extension per new major. Your trial
doesn't restart.** In reality, it would be very unlikely for there to be more than one major version update within 30 days.

To customers:

- **Every major version is a separate paid purchase.**
- Your **paid** license is **perpetual for the major version you bought** — it's
  version-locked. It never expires and lets you run that major forever, locally, but
  it only unlocks *that* major version.
- **Free minor/patch updates within a major.** For example, a license for 0.x only
  works for 0.x, and you get every update for version 0 — but it won't get you 1.x,
  and so on.
- **No cadence guarantee between majors.** Majors ship when there's enough *new
  value* to charge for — never on a calendar. This is deliberately **value-based,
  not time-based**: no subscription, no treadmill, no promise of continuous output.
- **Price: as of 6/23/2026, $30, one-time, per major — full price at v0.** v0 ships
  **honestly as an early/alpha-but-functional** release (§8), sold at full price.
    - What makes that fair: the **30-day trial** lets you verify it works for you
      *before* paying, and the perpetual license + free `0.x` updates mean you're
      buying the whole v0 line, not a frozen alpha.
    - The price for future versions may change based on customer demand.

### Why this shape

Stower is a long-term **stability/depth** product. Rather than adding feature bloat, Stower aims to become solid with better AI judgments, ensure there are less bugs over time, and ship fixes based on Apple API changes.

By making pricing based on value and major versions, Stower aims to deliver real value to customers, and it should be sustainable for one developer to build and maintain.


### Commitments

Emily Kang, the sole developer of this product, will do their best to fix any bugs or breaking API changes that come up for each major version. Those bug fixes may also be applied to other major versions, depending on how versioning proceeds, and if bugs are present across major versions. 

There will not necessarily be ongoing support for an old version like v0. It'll be determined on a case-by-case basis based on customer feedback. All updates will still be publicly documented on this Github repository through the codebase and releases, as well as any blogs Emily write about her decision-making process regarding Stower. Feel free to criticize her on the Internet and DM her if you believe she did/does unethical things to customers. Emily will also do their best to be ethical and address feedback.

## 2. How a trial becomes a paid license

> **As-built (v0) note (2026-07-01):** the Supabase Edge Function, Keygen
> licenses, `device_trials` table, and `/mint-trial`/`/ls-webhook` routes
> described below have all been **deleted**. There is no server-minted
> trial and no webhook. The real v0 flow is: the app starts a **local,
> 7-day** trial clock on first launch (no network call); buying sends you a
> Lemon Squeezy license key by email; you paste that key into the app, which
> makes a single `POST` to Lemon Squeezy's own `/v1/licenses/activate`
> endpoint to verify it, then stores it locally and never checks again. See
> `licensing-contract.md` §1 and §3 for the grounded mechanism. The
> paragraphs below describe the **retired** design, kept for history.

Plain version, with the exact pieces in parentheses.

- **Each Mac gets one free 30-day trial.** The first time Stower opens, it asks Stower's
  server for a trial tied to that Mac, so the same machine can't keep starting new
  trials. (Stower's **Supabase Edge Function** — `supabase/functions/license/`,
  route `POST /mint-trial`, handler `mintTrial` in `handlers.ts` — creates a Keygen
  license with a 30-day expiry, one per device, keyed to a hashed hardware ID in the
  `device_trials` table. The app talks only to this Edge Function, never to Keygen
  directly; the Edge Function is the only thing holding Keygen admin secrets.)

- **The trial runs the *latest* version, not a fixed one.** During your 30 days you
  can use whatever the newest major is. (The trial license carries a generic unlock,
  `STOWER_TRIAL`, that every build accepts — instead of being locked to one version.)

- **Buying upgrades the license you already have — nothing to re-enter.** Your
  purchase turns your trial into a paid license: the expiry is removed so it never
  runs out, and the version you bought gets unlocked. (Lemon Squeezy sends its
  `order_created` webhook to the Edge Function's `POST /ls-webhook` route — handler
  `handleWebhook` in `handlers.ts` — which clears the license's expiry to `null` and
  attaches that major's unlock — e.g. `STOWER_V0` — picked from the purchased
  `ls_variant_id`. Same license id and key throughout.)

- **Buying another major later just adds it to the same license.** Own v0 and later
  buy v1? Stower adds v1's unlock to your existing license — you keep both, still one
  key. (It *attaches* the new entitlement; it doesn't swap the policy, which would drop the
  major you already own.)

- **You keep exactly what you paid for.** A paid license never expires and unlocks
  only the major(s) you bought.

## 3. Keygen primitives (reference) `[RETIRED — see note]`

> **As-built (v0) note (2026-07-01):** Keygen is no longer part of this
> system at all — no account, no policies, no entitlements. Kept for
> history only.

- **Policy = the template/rules** (crypto scheme, encrypted/pooled flags,
  `maxMachines`, expiration strategy, fingerprint strategy). You create a few:
  **Trial** and **Paid**. **License = an instance** issued under a policy (a secret
  key + a resource id + an expiry, bound to machines). Many licenses share one
  policy.
- **Trial and Paid policies MUST be policy-change-compatible** or the trial→paid
  `PUT /policy` 422s. Identical except expiry on all four of: **Ed25519** scheme,
  **unencrypted** key, **unpooled**, and Paid's **fingerprint strategy no stricter
  than Trial's**. (`maxMachines` may differ — Trial = 1.)

## 4. How "you only get the version you bought" works

> **As-built (v0) note (2026-07-01):** there is no per-major-version
> entitlement mechanism in the shipped code. `StowerLemonSqueezyClient`
> checks only that an activated key's Lemon Squeezy `store_id`/`product_id`
> match Stower's — i.e. "is this a Stower license," not "which major
> version." A stored license unlocks every build, forever, today. Whether
> per-major gating (`STOWER_V0`/`STOWER_V1`-style unlock codes) comes back in
> a future version is an open business decision — see
> `licensing-contract.md` §"Open questions" — not something this section's
> Keygen-based description still does.

Stower uses Keygen **entitlements** — think of them as **unlock codes**. Each major
version has its own: `STOWER_V0`, `STOWER_V1`, and so on. A license can only run a
version if it holds that version's unlock.

- **Trials get a special "any version" unlock.** A trial license carries
  `STOWER_TRIAL`, which every Stower build accepts — that's what lets the trial run
  the latest major, whatever it is. The trial unlock comes from the Trial rulebook,
  so it goes away the moment you buy.
- **Paid unlocks live on your license, and they add up.** Buy v0 → `STOWER_V0` is
  added to your license. Later buy v1 → `STOWER_V1` is added to the *same* license.
  You keep both: your license collects the versions you've paid for, and nothing
  you didn't.
- **Each Stower build checks for its own unlock at startup.** The v0 app needs
  `STOWER_V0` (or `STOWER_TRIAL`); a future v1 app needs `STOWER_V1` (or
  `STOWER_TRIAL`). No matching unlock → it asks you to buy or upgrade. Online, the
  app's `POST /check-in` call (handler `checkIn` in `handlers.ts`) has the Edge
  Function run Keygen's `validate-key` and read the license's entitlements; offline,
  the app reads the same unlock from the locally-cached Keygen-signed machine file.
- **This is built from v0, not bolted on later.** Even though v0 is the only version
  today, the v0 app already checks for its unlock. That keeps the promise honest from
  day one, and makes a future v1 a one-line change instead of a new system rushed out
  under pressure.
- **A patch to an old version still works for its owners.** A 0.x bug-fix is still a
  v0 release, so v0 owners (who hold `STOWER_V0`) get it free, and it doesn't unlock
  v1.

## 5. How the license is actually enforced

> **As-built (v0) note (2026-07-01):** the "signed Keygen machine file" /
> online-Edge-Function / offline-signature-verification design below is
> retired. The real v0 enforcement is much simpler: the app checks **local**
> state at every launch (a stored license, else a 7-day local trial clock);
> the **only** network call in the entire licensing system is the one-time
> `POST` to Lemon Squeezy's `/v1/licenses/activate` when you enter a key.
> There is no ongoing online/offline distinction because there is no
> ongoing network check at all after that one activation. See
> `licensing-contract.md` §1/§3/§4.

- **Downloading is free; *using* it is what's checked.** Anyone can download any
  build — the repo is open and the app is freely shareable — so locking downloads
  would be pointless. What's enforced is a **license check when the app starts**: it
  runs only if you hold a valid license with the right version unlock. The download
  is free; the right to *run* a major is what you're buying.
- **Two ways the check happens, both signed by Keygen so they can't be faked:**
  - **Online:** the app calls Stower's licensing service — the Supabase Edge
    Function (`supabase/functions/license/`, `POST /check-in`) — which asks Keygen
    "is this license valid for this version?" and returns Keygen's signed answer plus
    a fresh signed machine file (needs internet). The app's only online licensing
    surface is this Edge Function.
  - **Offline:** the app keeps a Keygen-signed file on your Mac and verifies it
    locally, so it works on a plane. You can't edit that file to fake "paid" — the
    signature won't match.
- **It's a strong lock for normal use, not an unbreakable one.** Because the check
  runs on your own machine, it stops the realistic stuff like: sharing a key, editing the
  saved license, faking paid, running a version you didn't buy. It does *not* stop a
  developer who recompiles the open source with the check removed (that breaks the
  license terms, but it's technically possible). For a $30 app aimed at regular Mac
  users that doesn't matter — people pay for a signed, working, supported app, not
  for the source being secret.

## 6. Support & bug fixes

The rule of thumb: **promise a little, do more.** AI makes the actual code fix cheap,
but shipping a fix for an *old* major still means rebuilding, re-signing,
re-notarizing it, and checking it still runs on today's macOS — and Apple controls
the on-device model, so a future macOS could break an old version in a way that
isn't a quick fix.

So:
- **By default, fixes go into the current version.** No promise to backport
  features. When v1 ships, v0 is frozen — one version under active work at a time.
- **What Emily publicly promises:** security and critical fixes for the **current** major.
- **What Emily will actually try to do (goodwill, not a contract):** patch serious bugs in older
  majors too, when it's feasible for as long as she can. 

## 7. Why this works

- **The real moat is trust and reliability, not feature count.** People keep a tool
  that reads their messages and photos because it *just works* and respects their
  privacy. That compounds. Piling on features doesn't.
- **What makes each paid major fair:** since the goal is "rock-solid," not "more
  buttons," a paid major version has to be a genuine leap — a much smarter engine, a
  new data source (Photos, calendar), or a new platform (phone, iOS). The minor polish and
  bug-fixes are the *free* updates within a major.
- **"Learning from users" without spying:** Stower's whole pitch is that your data
  never leaves your Mac, so Emily can't (and won't) watch how you use it. Improvement
  comes from developer-generated test sets, opt-in feedback through TelemetryDeck which doesn't collect any personal data, and Emily using it herself.

Note to dev: see private repo me/Business/Plans/stower-strategy.md for further details.

> **Engineering contract:** the stable facade shapes, seam contracts, and
> load-bearing invariants live in [`licensing-contract.md`](./licensing-contract.md);
> the runtime topology (who talks to whom — as of v2.0 of that contract, just the
> app talking directly to Lemon Squeezy's `/v1/licenses/activate`, once) lives in
> [`Lifecycle.md`](./Lifecycle.md). There is no Edge Function or other Stower-operated
> backend anymore. Implementation plans sign against the contract file by version;
> this doc is the customer-facing terms.
