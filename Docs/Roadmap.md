# Stower roadmap

Local-first AI recall over Apple data (Photos + iMessages). Voice query →
hybrid FTS5 + embedding search → top matches + summary. Native Mac app v1;
phone PWA hitting a local Mac server v2; iOS Photos-only MAS app v3.

For *what shipped recently*, read `git log --oneline -20`. For the **current
release scope and date**, see the latest brief in `tmp/briefs/` (e.g.
`2026-06-09-v1-release-scope.md`). This file is the long-arc plan; it changes
when the strategy changes, not when code lands.

## Naming

- Repo: `stower`. Domain: `stower.app`.
- Swift modules: `StowerCore`, `StowerPhotos`, `StowerMessages`.
- App targets: `StowerMac` (v1), `StowerPhotosIOS` (v3 — not scaffolded yet).
- All public top-level declarations prefix `Stower` (swift-nio convention).

## Module boundaries

- `StowerCore` — search, embeddings, FTS5 store, voice (Whisper), LLM
  wrapper, `IndexedItem` protocol. Does NOT import PhotoKit, GRDB tables
  specific to chat.db, or Madrid.
- `StowerPhotos` — PhotoKit enumeration, FastVLM caption pipeline, Vision
  OCR. Produces `IndexedItem` values for `StowerCore`.
- `StowerMessages` — chat.db reader, Madrid attributedBody decoding,
  Contacts.app join. Produces `IndexedItem` values for `StowerCore`.

## Feature order

1. Scaffolding — DONE (commit `fb68e5c`).
2. `StowerCore.IndexedItem` + FTS5 store.
3. `StowerMessages` chat.db reader (read-only; uses Madrid for attributedBody).
4. Hybrid retriever (FTS5 + embeddings) in `StowerCore`.
5. `StowerPhotos` PhotoKit enumerator + FastVLM caption job runner.
6. Voice query: Whisper + query → retriever.
7. `StowerMac` UI: overlay window, global hotkey, results list, summary panel.
8. (v2) `StowerServer` Hummingbird HTTP API + PWA.
9. (v3) `StowerPhotosIOS` standalone MAS app.

## Decisions deferred

- Local LLM choice (Llama 3.1 8B vs Qwen 2.5 7B vs MLX-served): defer until
  we measure summarization latency on M-series hardware.
- Reply-sending: never in v1; revisit after recall loop ships.
- Face-identity recognition: out of scope v1.
