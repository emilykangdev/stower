# Stower — Licensing & Pricing

There is no guarantee that there will be a v1 or v2. However, this is the licensing strategy document set in stone, out of consideration for major releases that might happen.

Last Updated Date: 2026-07-02.

> **What ships in v0 vs. the intended model.** This page states two things:
> the **pricing model Emily intends** (value-based, per-major, no subscription
> — §1, §3, §6) and the **simpler mechanism v0 actually ships**. As
> built today, v0 is a **client-only Lemon Squeezy** activate-once flow with a
> **7-day** local trial and a single unlock that runs every build — not the
> 30-day trial or per-major entitlement stacking the intended model describes.
> "As shipped in v0" callouts mark each place the two differ. Whether the
> 30-day / per-major mechanics land in a future version is a business decision
> not yet made. The engineering facts live in
> [`licensing-contract.md`](./licensing-contract.md); the runtime picture in
> [`Lifecycle.md`](./Lifecycle.md).

---

## 1. The model

### Definitions

Stower uses Semver as the standard for assigning every update a version number. https://semver.org/ 

The major version number is shown by the first number: X.y.z means major version X. A real number example: 0.1.2 would be major version 0.

The minor version number is shown by the second number. For example: x.Y.z. Thus, 0.1.0 < 0.2.0 < 0.2.9, etc.

Patch versions will use the third number: x.y.Z. Thus, 0.1.5 < 0.1.6.

Stower will only "upgrade" to the major version X+1 and start releasing new minor updates based on X+1 if significant new capabilities are added. These will be documented. Users are not obligated to pay for any future major version.

### Payment model

> **As shipped in v0:** the trial is **7 days**
> (`StowerTrialClock.trialDuration`), a purely local `UserDefaults` clock with
> no network call, and there is no trial-extension mechanism — the "new major
> ships → +7 days" behavior below is part of the intended model, not something
> v0's trial clock does (v0 has no concept of "major" at all). The
> 30-day/extension text is Emily's stated pricing intent.

Every customer gets **30 days to try Stower before paying** — whether you're new or
an existing customer. Existing customers also get a **discount on upgrades**, as a
thank-you for sticking with it. Stower can offer this because it's sold **directly,
not through the Mac App Store**.

> **[Flagged for Emily's review — not silently rewritten.]** This paragraph
> previously justified selling outside the Mac App Store as a technical
> necessity tied to the old blanket-disk-access permission model, which Mac
> App Store submission disallowed. That technical premise is gone: the app now
> reads Messages via App Sandbox + a security-scoped bookmark, which Mac App
> Store submission does allow (see `Docs/StowerMessages.md`). Whether to
> actually pursue Mac App Store distribution is a separate, undecided business
> call (tracked by issue #64, `Docs/StowerMessages.md`'s Non-goals) — the
> upgrade-discount and direct-relationship reasoning above may still hold on
> its own merits, but that's Emily's call to make, not this migration's to
> assert.

The App Store also can't do the upgrade discounts described below.

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
  **honestly as an early/alpha-but-functional** release, sold at full price.
    - What makes that fair: the **trial** lets you verify it works for you
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

> **As shipped in v0:** exactly the flow described here — a local trial, a
> one-time key activation, no server. The intended per-major upgrade mechanics
> (§3) are not yet wired: v0 has a single unlock, so "buying" simply moves you
> from trial to a stored license that runs every build.

The whole flow, with the exact pieces in parentheses:

- **Each install gets one free local trial.** The first time Stower opens, it
  seeds a local first-launch date and runs for the trial window with **no
  network call at all** — the trial is 100% on-device. (`StowerTrialClock`,
  `UserDefaults` key `com.stower.trial.firstLaunch`; the window is
  `StowerTrialClock.trialDuration`.)

- **Buying gets you a license key by email; you paste it in once.** You buy on
  Lemon Squeezy's own checkout page, Lemon Squeezy emails you a license key,
  and you paste that key into Stower. (`StowerLicenseEntryView` →
  `StowerLemonSqueezyClient.activate` makes a single `POST` to Lemon Squeezy's
  public `/v1/licenses/activate`.)

- **Activate once, then trust local storage forever.** On success the app
  stores the key locally and never checks again — no periodic re-validation, no
  server. (`StowerLicenseStore`, plaintext `UserDefaults`; the only network
  call in the entire licensing system is that one activation.)

- **Lemon Squeezy is the only backend.** It's the merchant of record (payments,
  tax, refunds) *and* the license authority (it issues keys and verifies them at
  `/activate`, and enforces how many machines a key can activate via its own
  `activation_limit`). Stower operates no server of any kind.

## 3. Which version a license unlocks

> **As shipped in v0:** there is **no per-major-version gating** in code. The
> app checks only that an activated key belongs to Stower's Lemon Squeezy store
> and product (`meta.store_id` / `meta.product_id`) — i.e. "is this a Stower
> license," not "which major." A stored license unlocks every build. The
> per-major model below is the intended shape; whether it returns in a future
> version is an open business decision — see `licensing-contract.md`
> §"Open questions."

The intended model is that **each major version is bought separately, and you keep
exactly what you paid for**:

- **Buy v0 → you own v0.** Later buy v1 → you own both. A purchase *adds* the new
  major to what you already own; it never drops a major you already paid for.
- **Trials run the latest major.** During your trial you can use whatever the newest
  major is, not a fixed one.
- **Each build checks for its own major at startup, from day one.** Even though v0 is
  the only version today, building the per-major check in from v0 keeps the promise
  honest and makes a future v1 a small change instead of a new system rushed out under
  pressure.
- **A patch to an old version still works for its owners.** A 0.x bug-fix is still a
  v0 release, so v0 owners get it free, and it doesn't unlock v1.

## 4. How the license is enforced

> **As shipped in v0:** enforcement is a **local check at every launch** —
> a stored license, else a 7-day local trial clock, else the paywall. The
> **only** network call in the whole system is the one-time `POST` to Lemon
> Squeezy's `/v1/licenses/activate` when you enter a key. There is no
> online/offline distinction because there is no ongoing network check after
> that one activation.

- **Downloading is free; *using* it is what's checked.** Anyone can download any
  build — the repo is open and the app is freely shareable — so locking downloads
  would be pointless. What's enforced is a **license check when the app starts**: it
  runs only if you hold a valid license, or you're inside the trial window. The
  download is free; the right to *run* it past the trial is what you're buying.
- **The check is local.** At launch the app reads local state: a stored license runs
  fully; an active trial runs fully; an elapsed trial with no license routes to the
  paywall. Verifying a purchase is the one moment it talks to Lemon Squeezy — once,
  when you paste the key.
- **It's a strong lock for normal use, not an unbreakable one.** Because the check
  runs on your own machine, it stops the realistic stuff — sharing a key beyond the
  activation limit, editing the saved license, faking paid. It does *not* stop a
  developer who recompiles the open source with the check removed (that breaks the
  license terms, but it's technically possible). For a $30 app aimed at regular Mac
  users that doesn't matter — people pay for a signed, working, supported app, not
  for the source being secret.

## 5. Support & bug fixes

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

## 6. Why this works

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
> the runtime topology (who talks to whom — just the app talking directly to
> Lemon Squeezy's `/v1/licenses/activate`, once) lives in
> [`Lifecycle.md`](./Lifecycle.md). There is no Stower-operated backend.
> Implementation plans sign against the contract file by version; this doc is
> the customer-facing terms.
