# Stower plan

Local-first AI recall over Apple data (Photos + iMessages). Voice query →
hybrid FTS5+embedding search → top matches + summary. Native Mac app v1;
phone PWA hitting a local Mac server v2; iOS Photos-only MAS app v3.

## Status

- 2026-06-14: Relationship "no-reply" engine in `StowerMessages` (feature 5).
  Two-layer, pure, reads only the local 180-day window on the existing read-only
  snapshot — index path untouched. Layer 1 is a neutral facts extractor
  (`StowerConversationState` / `StowerConversationStateExtractor`): true last act
  + `lastMessageKind` from a chronology read over all content types, recent
  reciprocity, and tapback-clearing via chat-provenance reactions with
  prefix-normalized (`p:N/`, `bp:`) target GUIDs. Layer 2 is the first policy over
  those facts (`StowerNoReplyPolicy` / `noReplyCandidates`): 1:1 → recency-gated
  mutuality → counterpart-last → not tapback-cleared → ≥ threshold, ranked
  most-recently-unanswered first. `stower no-reply` CLI is the local measurement
  vehicle. 21 new tests; `Scripts/precheck.sh` green. Deferred to v1.1: precise
  attachment kind via the `attachment`-table UTI, per-contact dedupe.

- 2026-06-13: Hybrid retrieval substrate + permanent `stower` CLI (feature 4).
  `StowerCore` gained: `StowerEmbeddingStore` on its own `embeddings.sqlite`
  (survives `replaceAll` and FTS schema-version erases; per-batch resumable
  upserts; safe `loadUnaligned` BLOB decode), `StowerEmbedder` (async/Sendable
  model-agnostic seam) + `StowerCoreMLEmbedder` (compile-to-`.mlmodelc` cache,
  manifest-driven pooling/prefix, post-tokenization skip), `StowerRetriever`
  (brute-force cosine over a flat vector cache + RRF, deterministic total order,
  single-sourced constants), and `StowerIndex.items(ids:)`/`count()`.
  `Scripts/convert-embedding-model.py` (PEP 723 / `uv`) converts any HF model to
  a batched Core ML package + `manifest.json` with an in-script parity check.
  New `stower` CLI: `index` (delta-embed, resumable, timed), `search` (hybrid /
  fts / semantic with per-arm provenance), `eval` (3-arm HIT/MISS over a
  gitignored pre-registered TSV, scored gate, preflight). All invariants covered
  by Swift Testing; no Core ML in unit tests (model exercised via the CLI).
  Remaining human step: convert the model, grant FDA+Contacts, run the 10-query
  gate against Messages.app on the real 180-day window.
- 2026-06-11 (later): Pre-landing review pass fixed all findings. Highlights:
  WAL recovery for the copied snapshot (a raw copy of the live WAL-mode
  `chat.db` could not be opened read-only — `PRAGMA journal_mode=DELETE` on
  the private copy now folds frames in; regression test uses a WAL fixture),
  a real balloon-message filter with a URL-preview exception (the old test
  passed only because the fixture row had no text), ingest-window filters
  pushed into SQL, `ingest` renamed to the explicit `replaceAll(with:)`,
  snapshot retry errors surfaced, and an `invalidArgument` error case.
- 2026-06-11: Implemented the Core index and Messages ingestion foundation.
  `StowerCore` now has a source-namespaced `StowerIndexedItem` contract,
  transactional GRDB 7 FTS5 external-content index, safe Porter/Unicode61
  search, weighted group-title ranking, snippets, schema-version rebuilds, and
  rank-preserving grouping. `StowerMessages` now pins Madrid 0.4.0, decodes
  attributed bodies without its lossy convenience property, resolves Contacts
  with deterministic raw-handle fallback, copies and validates a read-only
  ephemeral Source DB snapshot, filters non-message rows, and supports both the
  180-day ingest path and unbounded newest-N thread reads. Synthetic tests cover
  the architecture and edge cases. The manual FDA run, real-window timings, and
  10-query comparison against Messages.app remain a human evaluation step
  because they require the user's private data and query judgments.
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
