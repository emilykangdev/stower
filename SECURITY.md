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

- **Every commit is signed** (SSH-based commit signing), so the history of
  changes to this repo is verifiably authored by the maintainer, not
  forgeable after the fact.
- **Release tags are pushed using 1Password**-backed credentials, not a
  loose key sitting in a config file.
- **App update signing key was rotated** as a precaution after a separate,
  unrelated exposure risk — see `Docs/release-notes/` for the timeline. The
  old signing key can no longer authorize anything.
- Every GitHub Action used in the release pipeline is pinned to an exact
  commit (not a movable version tag), which closes a common supply-chain
  attack where a third-party Action changes behavior after the fact.

## What's built into the product itself

This is the part that matters most day to day — how Stower is designed so
there's less to trust in the first place:

- **Nothing leaves your Mac.** Stower reads your Messages database and runs
  its AI judgment (deciding whether a text is a real question worth
  following up on) entirely on-device. There is no server that ever sees the
  content of your messages. The app's only network call in its licensing
  path goes to Lemon Squeezy (`api.lemonsqueezy.com`) to check your license —
  never anywhere else — and that is itself enforced automatically on every
  commit, not just promised in this document.
- **Read-only access.** Stower reads your Messages database; it does not
  and cannot send messages on your behalf. Replying is always a manual,
  deliberate action you take yourself in the real Messages app.
- **Full Disk Access is scoped to what it's for.** Reading `chat.db` (where
  macOS stores your Messages) requires Full Disk Access — there's no way
  around that on macOS today, and it's the single biggest reason to be
  careful about which apps you grant it to. Stower requests it through
  Apple's normal system permission flow (System Settings), the same gate
  every app goes through, and only uses it to read your Messages database.
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

Found something that looks like a security issue? Please open a
[GitHub issue](https://github.com/emilykangdev/stower/issues) or reach out
directly — see contact info on [stower.app](https://stower.app). Genuine
reports are welcome and taken seriously.
