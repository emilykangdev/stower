# Stower — Product Vision

The product-level "why" and job-to-be-done for Stower. Subsystem docs
(`StowerCore.md`, `StowerMessages.md`, …) describe *how*; this describes *what
we are building and for whom*, so scope decisions trace back to a goal instead
of drifting. Last clarified 2026-06-09.

## What Stower is (one line)

A paid **consumer** Mac app that gives you a faster way to **get to and read
your iMessage conversations** than Apple's Messages app.

## The core problem

Apple Messages is one long, recency-sorted list. To reach a specific person or
group you scroll — and its search is slow, exact-match, and badly ranked across
threads. There's no fast "jump straight to that conversation." For someone who
texts a lot, navigation and recall are a daily papercut.

## Job to be done (v1)

> "Get me to the right conversation and let me read it — fast — without
> scrolling Apple's endless list."

- **Entry:** type a name or a snippet → land directly in the 1:1 or group
  thread.
- **Payoff:** read the conversation *inside Stower*.
- **Recall** ("what's the address Sarah sent? what did the contractor quote?")
  falls out of the same machinery — it's a side effect, not a separate product.

Search is the *entry mechanism*, not the product. The product is fast
navigation + a readable thread view.

## Who it's for — and not for

- **For:** individual consumers who text a lot and find Messages.app's
  navigation and search frustrating.
- **Not for:** businesses / high-volume customer comms. Owners have different
  needs and already use email + dedicated B2B services to manage customer and
  supply-chain interactions. Different audience, different technology — not our
  target.

## Success bar for v1

**Craft and visible speed**, not AI depth. It must feel instant and rank
obviously-right, clearly beating Messages.app's built-in search. The reason to
leave the free built-in app is that ours is *noticeably* faster and saner — so
the 6 days go into execution, not capability surface.

## Why people pay (consumer-utility levers)

Simple, well-executed consumer Mac utilities get paid for (clipboard managers,
window tilers, HoudahSpot). What decides paid success here is not capability
depth but:

1. **Felt frequency** — "jump to and read a conversation" is a many-times-daily
   need (stronger than occasional message-hunting).
2. **Visibly better than the free thing** — Apple's search is bad enough to
   leave daylight.
3. **Craft / polish.**
4. **Distribution** — the local-first / privacy story is the launch angle.

## Roadmap horizon

- **v1 (ship Jun 15 2026):** keyword search (FTS5 bm25 + stemming +
  contact-name folding) → fast jump → in-app thread read. Paid consumer
  utility, Messages-only, recall-only.
- **v1.1 — the "now it's smart" upgrade:** semantic / natural-language search
  via embeddings, which widens matching to paraphrase ("the thing at Sarah's
  place" → finds "come over Saturday"). Embedding a 40-day personal corpus is
  cheap; this was likely *over-cut* from v1 by being lumped with the heavy LLM
  summary. An on-device Apple `NaturalLanguage` embedding path (no model
  download) is the de-risked candidate — verify the API at v1.1 planning.
- **v2 — north star: send & edit from Stower.** Make Stower the client you
  *act* in — compose, send, edit/unsend — so it's where you live, not a pointer
  back into a bad app. **Maintenance-gated, not a commitment:** worth doing only
  if the write path proves sustainable against Apple's churn. macOS 26 Tahoe
  already broke AppleScript group-send (the `any;-;` GUID change) and IMCore
  injection is increasingly fragile, so every macOS release is a potential break
  to chase. We commit to v2 only after judging the upkeep is worth it —
  read-only ships first precisely because it carries none of this risk.

## Explicitly out of scope (and why)

- **Triage / "who did I leave on read"** — the dogfood user is on top of her
  messages, so it isn't a felt pain. Don't build a job the primary user
  doesn't have. (Reconsider only if real users ask.)
- **Business / CRM inbox** — wrong audience (see above).
- **Photos, voice, LLM summaries** — heavier toolchain (MLX / Whisper); quality-
  gated v1.1+ per the release-scope brief, not date-gated.

## How this constrains the build

- **Conversation-first UX.** Results group by conversation; the fast *jump* is
  the primary action; the **readable thread view is the hero** — not a flat
  search-results list.
- **Dual read paths in `StowerMessages`.** (a) 40-day windowed *bulk* ingest
  for the search index; (b) a targeted *single-chat recent-history* read for
  the thread view, unbounded by the 40-day window. Cheap to design in now,
  annoying to retrofit.
- **"Open in Messages.app" is a secondary escape hatch** (used to reply, until
  v2 sending exists), not the core action. This de-risks the unreliable
  group-chat deep-link URL scheme — reading happens in-app, so the deep link
  only matters when the user wants to reply.

## See also

- Strategic scope + day-by-day: `tmp/briefs/2026-06-09-v1-release-scope.md`,
  `tmp/briefs/2026-06-09-june15-daily-outline.md`
- Days 1–2 design detail: `tmp/briefs/2026-06-09-core-index-messages-ingestion.md`
- `Docs/Roadmap.md`, `Docs/StowerCore.md`, `Docs/StowerMessages.md`
