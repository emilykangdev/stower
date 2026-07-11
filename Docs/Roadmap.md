# Stower roadmap

Native macOS app (`StowerMac`) that surfaces the 1:1 iMessage conversations
you're letting slip — "Your turn" / "Maybe follow up" — with on-device
judgment, drafts, and deep-link-to-send (see `README.md`). Recall
(hybrid FTS5 + embedding search) exists as a library + internal CLI
(`Docs/StowerCore.md`, `Docs/StowerMessages.md`), not wired into the app.

For *what shipped recently*, read `git log --oneline -20`. For the **current
release scope and date**, see the latest brief in `tmp/briefs/` (e.g.
`2026-06-09-v1-release-scope.md`). This file is the long-arc plan; it changes
when the strategy changes, not when code lands. This is also the single
canonical home for Naming/Module boundaries/Feature order/Decisions deferred —
`PLAN.md` used to carry a duplicate copy of these sections; that duplicate is
gone, `PLAN.md` now owns only the dated build log.

## Naming

- Repo: `stower`. Domain: `stower.app`.
- Swift modules: `StowerCore`, `StowerPhotos`, `StowerMessages`.
- App targets: `StowerMac` (v1), `StowerPhotosIOS` (v3 — not scaffolded yet).
- All public top-level declarations prefix `Stower` (swift-nio convention).

## Module boundaries

- `StowerCore` — search, embeddings, FTS5 store, `StowerIndexedItem`
  protocol. Does NOT import PhotoKit, GRDB tables specific to chat.db, or
  Madrid. (No voice/Whisper code exists in this module — an earlier version
  of this doc claimed it did; it never was built.)
- `StowerPhotos` — PhotoKit enumeration, FastVLM caption pipeline, Vision
  OCR — a **scaffold only, not implemented** (see `Docs/StowerPhotos.md`,
  `AGENTS.md`'s "Photos — two different features"). Would produce
  `StowerIndexedItem` values for `StowerCore` if built.
- `StowerMessages` — chat.db reader, Madrid attributedBody decoding,
  Contacts.app join. Produces `StowerIndexedItem` values for `StowerCore`.

## Feature order (historical — 1-4 shipped as planned, 5+ superseded)

1. Scaffolding — DONE (commit `fb68e5c`).
2. `StowerCore`'s `StowerIndexedItem` + FTS5 store — DONE.
3. `StowerMessages` chat.db reader (read-only; uses Madrid for attributedBody) — DONE.
4. Hybrid retriever (FTS5 + embeddings) in `StowerCore` — DONE (library + CLI only).

What actually shipped next was **not** the original plan below — instead: the
relationship-debt engine (`Docs/MacAppContract.md`), the `StowerMac` board /
drafts / deep-link-to-send app (`README.md`), licensing (Lemon Squeezy),
analytics/crash reporting, and the Sparkle update pipeline. See `PLAN.md`'s
Status log for that actual build order.

The original plan's remaining steps, **superseded, not committed**:
- ~~`StowerPhotos` PhotoKit enumerator + FastVLM caption job runner~~ —
  per `AGENTS.md`, this is now "uncertain and currently unlikely... may
  never ship." Not a committed next step.
- ~~Voice query: Whisper + query → retriever~~ — no Whisper code was ever
  written; not committed.
- ~~`StowerMac` UI: overlay window, global hotkey, results list, summary
  panel~~ — superseded by the board/drafts/deep-link app that actually
  shipped.
- ~~(v2) `StowerServer` Hummingbird HTTP API + PWA~~ — `AGENTS.md` bans
  pulling in Hummingbird/swift-nio for v1; not committed.
- ~~(v3) `StowerPhotosIOS` standalone MAS app~~ — depends on `StowerPhotos`
  shipping first, which is itself uncertain.

## Decisions deferred

- Local LLM choice (Llama 3.1 8B vs Qwen 2.5 7B vs MLX-served): defer until
  we measure summarization latency on M-series hardware.
- Reply-sending: never in v1; revisit after recall loop ships.
- Face-identity recognition: out of scope v1.
