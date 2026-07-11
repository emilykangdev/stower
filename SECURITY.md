# Security

Stower reads sensitive data on your Mac — your Messages database — so security
questions deserve a straight answer, not marketing. This page covers both: what
went wrong once, and what protects your data every day.

## Past incident: a real credential was briefly committed

**Yes, this happened, and here's exactly what.** On 2026-06-28, a real Keygen
API token (plus some internal account/product identifiers) was accidentally
committed inside a template file (`Scripts/Keygen/remote-testing/.env.example`)
that was meant to hold only placeholder values.

What we did about it, same day:
- Rotated the exposed token immediately — the old one stopped working.
- Replaced the template file with unmistakable placeholder values so this
  can't happen again from that file.
- Scrubbed the affected branch history.

Shortly after, we went further than just rotating the key — **we deleted the
entire backend system that credential belonged to** (the Keygen + Supabase
licensing service) and rebuilt licensing on Lemon Squeezy instead. So the
exposed credential isn't just rotated, it's connected to nothing — that
system no longer exists at all.

We also added a permanent, automated guardrail so this specific class of
mistake can't quietly come back: every commit is mechanically checked to
confirm there is **no remaining reference anywhere in the app's source code**
to the old Keygen/Supabase backend. If anyone (human or AI) ever tried to
reintroduce it, the commit would fail automatically, not rely on someone
noticing in review.

**No user data, license keys, or customer information was ever involved** —
the exposed token belonged to internal test tooling for the (now-deleted)
licensing backend, not to anyone's account or Messages data.

## Ongoing practices

- **Commits are signed going forward** (SSH-based commit signing), as of
  this recent change — this narrows who could plausibly author a *future*
  commit without access to that key. It is not retroactive: commits made
  before this change are not signed, and a "Verified" badge you may see on
  an older merge commit on GitHub reflects **GitHub's own signature on the
  merge action**, not proof that the maintainer signed the underlying
  commit.
- **Release tags are pushed using 1Password**-backed credentials, not a
  loose key sitting in a config file.
- **App update signing key was rotated** as a precaution after a separate,
  unrelated exposure risk — see `Docs/release-notes/` for the timeline. The
  old signing key can no longer authorize anything.
- Every GitHub Action used in the release pipeline is pinned to an exact
  commit (not a movable version tag), which **reduces** (not eliminates)
  the risk of a supply-chain attack where a third-party Action's behavior
  changes underneath a moving version tag.

## What's built into the product itself

This is the part that matters most day to day — how Stower is designed so
there's less to trust in the first place:

- **Your message content never leaves your Mac.** Stower reads your Messages
  database and runs its AI judgment (deciding whether a text is a real
  question worth following up on) entirely on-device. There is no server
  that ever sees the content of your messages, a contact name, a phone
  number, a search query, or a file path — the analytics event types below
  are structurally incapable of carrying any of that (see
  `Docs/Analytics.md`).
- **But Stower is not fully offline, and you should know exactly what does
  leave the device:**
  - **Lemon Squeezy** (`api.lemonsqueezy.com`) — checks your license. The
    only network call in the licensing path; a mechanical build check
    confirms no other licensing backend can sneak back in (see the past
    incident above).
  - **TelemetryDeck** — anonymous funnel analytics (e.g. "did the app
    launch and reach the board"), tied to a random per-install ID that is
    hashed again before it leaves the device and carries no message
    content. **On by default.** The one-click opt-out lives in Settings →
    Privacy, and a disclosure card also surfaces in-app — but only after
    about a minute of use, so a few of these anonymous events can fire
    before you've seen or made that choice. Turning it off stops all
    future events immediately; it does not retroactively delete what
    already sent.
  - **Sentry** — crash reports only, not general telemetry. Also on by
    default, behind the same consent gate as TelemetryDeck above (so the
    same "may fire briefly before you've seen the opt-out" caveat
    applies). Attaches no identity, and every crash report is scrubbed
    before it's sent — message content, contact info, and file paths that
    could identify you are stripped or the whole report is dropped rather
    than sent partially redacted (see `Docs/CrashReporting.md`).
  - **A feedback relay**, only if you explicitly open the in-app feedback
    form and submit something — this one is not default-on. Along with
    the message you type (and an email address, only if you choose to add
    one), it also sends a few non-content identifiers: your app version,
    macOS version, coarse license status (e.g. trial/licensed), and an
    opaque license-instance ID if you have one. No message content,
    contacts, or file paths ride along.
- **Read-only access.** Stower reads your Messages database; it does not
  and cannot send messages on your behalf. Replying is always a manual,
  deliberate action you take yourself in the real Messages app.
- **Full Disk Access is scoped to what it's for.** Reading `chat.db` (where
  macOS stores your Messages) requires Full Disk Access — there's no way
  around that on macOS today, and it's the single biggest reason to be
  careful about which apps you grant it to. Unlike most permissions, macOS
  has no system prompt for Full Disk Access at all — Stower's onboarding
  screen walks you to System Settings to grant it manually, the same
  manual step every Mac app that needs this access requires — and Stower
  only uses it to read your Messages database.
- **Separate, isolated environments for development and daily use.**
  The version of Stower used for active development/testing never shares
  its data with the version you actually use day to day, so a bug being
  tested can't accidentally corrupt or mix with your real drafts, message
  history, or settings.
- **The source is public.** Unlike most apps that ask for this level of
  access, you don't have to take a company's word for what it does with it —
  the code is readable at
  [github.com/emilykangdev/stower](https://github.com/emilykangdev/stower).
  (Public and free to read/audit/run for noncommercial use — see
  [`LICENSE`](LICENSE) for the exact terms.)

## Reporting a concern

**Found something that could be exploited (a real vulnerability)?** Please
report it privately first — use GitHub's
["Report a vulnerability"](https://github.com/emilykangdev/stower/security/advisories/new)
(Security tab → Advisories) or reach out directly (see contact info on
[stower.app](https://stower.app)), rather than a public issue, so exploit
details aren't public before there's a fix.

For anything else — a question, a privacy concern, a doc that doesn't add
up — a [public GitHub issue](https://github.com/emilykangdev/stower/issues)
is completely fine. Genuine reports of either kind are welcome and taken
seriously.
