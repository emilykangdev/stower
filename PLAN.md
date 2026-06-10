# Stower plan

Local-first AI recall over Apple data (Photos + iMessages). Voice query →
hybrid FTS5+embedding search → top matches + summary. Native Mac app v1;
phone PWA hitting a local Mac server v2; iOS Photos-only MAS app v3.

## Status

- 2026-05-13: Scaffolding complete. Three library targets (StowerCore,
  StowerPhotos, StowerMessages) + guardrail governance + lint configs + CI.
  No business logic yet. Mac app shell (StowerMac) deferred to its own plan.
- 2026-06-09: Added signal-coding guardrails (PR #2). `AGENTS.md` is now the
  canonical cross-agent rule set; `CLAUDE.md` imports it via `@AGENTS.md`. Three
  project skills + a shared pattern catalog live in `.claude/skills/`, mirrored to
  `.agents/skills/` for Codex: `swift-signal-review` (notice), `swift-pattern-sweep`
  (eradicate sweep-able patterns), `harden-guardrail` (turn a recurrence into a
  gate), and `SWIFT_PATTERNS.md` (bad→good catalog). CI now runs
  `Scripts/precheck.sh` directly so the gate has one definition shared with the
  pre-commit hook. Still no business logic.

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

1. Scaffolding (this plan) — DONE on commit
2. `StowerCore.IndexedItem` + FTS5 store
3. `StowerMessages` chat.db reader (read-only; uses Madrid for attributedBody)
4. Hybrid retriever (FTS5 + embeddings) in `StowerCore`
5. `StowerPhotos` PhotoKit enumerator + FastVLM caption job runner
6. Voice query: Whisper + query → retriever
7. `StowerMac` UI: overlay window, global hotkey, results list, summary panel
8. (v2) `StowerServer` Hummingbird HTTP API + PWA
9. (v3) `StowerPhotosIOS` standalone MAS app

## Decisions deferred

- Local LLM choice (Llama 3.1 8B vs Qwen 2.5 7B vs MLX-served): defer until
  we measure summarization latency on M-series hardware.
- Reply-sending: never in v1; revisit after recall loop ships.
- Face-identity recognition: out of scope v1.
