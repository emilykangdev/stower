# Stower — Product Vision

The product-level "why" and job-to-be-done for Stower. Subsystem docs
(`StowerCore.md`, `StowerMessages.md`, …) describe *how*; this describes *what
we are building and for whom*, so scope decisions trace back to a goal instead
of drifting. Last clarified 2026-06-15.

> **Reframed 2026-06-15.** v0 is the **relationship-debt board** — who you owe,
> who ghosted you. Fast search + an in-app thread read are the **capability** you
> act through, not the product. (Through 2026-06-09 this doc had it inverted —
> search/read as the product, triage explicitly cut. Every commit since built the
> debt board; the doc now follows the code.)

## What Stower is (one line)

Stower will help you reason and take action based on your Photos and especially your iMessages. In the initial V0 release, it'll just focus on nailing iMessages. 

A paid **consumer** Mac app that shows you which iMessage relationships you're
letting slip — who you owe a reply, who ghosted you — and drops you straight into
the thread to act.

## The core problem

Apple Messages is one recency-sorted list with **no memory of intent.** The asks
you meant to answer scroll off the top and you forget them; the people you texted
who never wrote back disappear just the same. A thread leaving the top of the
list isn't "handled" — it's just *out of sight*. Relationships decay not because
you stopped caring but because the inbox forgets, and there's no surface that
says "you still owe this person." (And when you *do* remember someone, reaching
their thread still means scrolling or fighting a slow, exact-match search.)

## Job to be done (v1)

> "Show me who I'm dropping the ball on, and get me into that conversation to
> fix it."

Two lenses over your 1:1 conversations:

- **Neglected** — the other person acted last; you owe at least an
  acknowledgment. Ranked, never hidden (a real question floats above chit-chat).
- **Ghosted** — you acted last on a *real ask* and got no reply. Gated to the
  genuine asks (an on-device model decides "this expected an answer" vs small
  talk), so it surfaces signal, not every "I texted last."

The **act**: tap a row → read the thread *inside Stower* → (until v2) jump to
Messages.app to reply. The **capability that serves it**: fast search +
jump-to-conversation, so you can also reach any thread directly and so recall
("what address did Sarah send?") falls out of the same machinery. Search is a
power tool *within* the product; the product is the debt board.

## Who it's for — and not for

- **For:** individual consumers who text a lot and quietly worry they're letting
  people slip — the dropped reply, the friend they ghosted without meaning to.
- **Not for:** businesses / high-volume customer comms. Owners have different
  needs and already use email + dedicated B2B services. Different audience,
  different technology — not our target.

## Success bar for v1

Two bars, both required:

1. **The judgment is trustworthy.** The debt board is only worth opening if it
   understands intent — "wondering if you're free Saturday" with no `?` is a real
   ask; "lol" is not. Apple's on-device **FoundationModels** judge supplies that
   (heuristic fallback on machines that can't run it). The judgment *is* the
   product; a `?`-matcher behind a paywall fails the value test.
2. **It feels instant.** On-device inference can't sit on the hot path. The
   load/refresh split + a persistent verdict cache exist precisely so the board
   paints immediately (heuristic/cached) and upgrades to model verdicts in the
   background. "Real judgment" and "felt speed" are not a tradeoff here — the
   architecture buys both.

(The pre-2026-06-15 bar said "craft and visible speed, *not* AI depth." Retired:
the on-device judgment is the depth — kept invisible-fast, not cut.)

## Why people pay (consumer-utility levers)

1. **Felt value** — "am I dropping the ball on someone who matters" is a real,
   recurring anxiety; a tool that quietly tracks it and is *right* earns trust.
   **Honest caveat to validate:** this is a lower-frequency surface than
   many-times-daily search — likely a daily/weekly "who am I forgetting" glance,
   higher value-per-use but fewer uses. The original doc cut triage on a
   felt-frequency argument; that risk didn't vanish when we decided to build it.
   Confirm the felt pain with real users early.
2. **Visibly does what Apple can't** — Messages has *no* concept of relationship
   debt at all. Bigger daylight than "our search is faster."
3. **Privacy / local-first** — all judgment is on-device, no plaintext leaves the
   machine. The launch angle.
4. **Craft / polish.**

## Roadmap horizon

- **v1 (ship target):** the debt board — **Neglected** (ranked) + **Ghosted**
  (gated) over on-device conversation facts + FoundationModels reply-expectation
  judgment, backed by a disposable verdict cache. Fast keyword search (FTS5 bm25
  + stemming + contact-name folding) and in-app thread read are the **capability**
  you act through. 1:1 only, Messages-only, read-only (reply via Messages.app).
- **v1.1:** semantic / natural-language search (embeddings widen matching to
  paraphrase); **live board re-gating** (`ghostedBorderline` + an
  `AsyncStream<StowerDebtBoard>` that refines under the user's eyes) — reserved
  out of v1 by the engine plan. An on-device Apple `NaturalLanguage` embedding
  path is the de-risked search candidate.
- **v2 — north star: send & edit from Stower.** Make Stower the client you *act*
  in — compose, send, edit/unsend — so it's where you live. **Maintenance-gated,
  not a commitment:** macOS 26 Tahoe already broke AppleScript group-send (the
  `any;-;` GUID change) and IMCore injection is fragile, so every release is a
  potential break to chase. Read-only ships first precisely because it carries
  none of that risk.

## Explicitly out of scope (and why)

- **Group conversations** — 1:1 only in v1; the facts extractor already filters to
  `isOneToOne`. Group debt is a later widening, not a v1 cut corner.
- **Business / CRM inbox** — wrong audience (see above).
- **Photos, voice, LLM summaries** — heavier toolchain (MLX / Whisper); quality-
  gated v1.1+, not date-gated.
- **Reply-sending (any AppleScript / IMCore path)** — v2 territory; v1 is
  recall-and-read only.

## How this constrains the build

- **The debt board is the home surface.** The app opens onto Neglected + Ghosted;
  search and the thread view exist to *act on* a row, not as the front door.
- **The board must never block on the model.** `loadDebtBoard` is structural-speed
  and model-free; `refreshJudgments` backfills in the background and reports what
  changed. This two-phase loop is the "feels instant" guarantee — see
  [`MacAppContract.md`](MacAppContract.md) §5.
- **Dual read paths in `StowerMessages`.** (a) windowed *bulk* read for facts +
  the search index; (b) a targeted *single-chat recent-history* read for the
  thread view, unbounded by the bulk window. Both already exist.
- **Conversation-first UX.** Both lenses and search results group by conversation;
  the **readable thread view is the hero of the act**, not a flat results list.
- **"Open in Messages.app" is a secondary escape hatch** (used to reply, until v2
  sending exists), not the core action — which de-risks the unreliable group-chat
  deep-link URL scheme.

## See also

- The engine that backs the board: `Docs/StowerMessages.md`, and the app-facing
  seam in [`MacAppContract.md`](MacAppContract.md).
- Strategic scope + day-by-day: `tmp/briefs/2026-06-09-v1-release-scope.md`,
  `tmp/briefs/2026-06-09-june15-daily-outline.md`
- `Docs/Roadmap.md`, `Docs/StowerCore.md`, `Docs/StowerMessages.md`
