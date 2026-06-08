# StowerCore

## Why

Source-agnostic search and index. The model: every adapter (`StowerPhotos`,
`StowerMessages`, future Notes/Calendar/etc.) produces values that conform
to `IndexedItem`. `StowerCore` ingests them, runs embeddings + FTS5,
exposes a hybrid retriever, and wraps the local LLM for summarization.

`StowerCore` must never import `StowerPhotos`, `StowerMessages`, PhotoKit, or
`chat.db`-specific GRDB types. The dependency arrow points *into* this module,
never out of it. This keeps it testable without PhotoKit or `chat.db` in the
loop and lets us add new sources without churn.

## Public API surface (planned — not yet implemented)

- `protocol IndexedItem` — `id`, `kind`, `text`, `timestamp`, `sourceMetadata`
- `actor StowerIndex` — `func ingest(_:)`, `func search(query:) -> [IndexedItem]`
- `struct StowerSearchResult`

## Open questions

- Embedding model: `all-MiniLM-L6-v2` via CoreML vs. on-device sentence
  transformer via MLX. Defer until we have measured latency on M-series.
- Embedding storage format: float16 quantized vs. float32. Defer.
- GRDB major version: pinned to 6.x today (Swift 5.x line). GRDB 7.x requires
  Swift 6 strict concurrency project-wide — revisit when we commit to that.

## See also

- Plan: `PLAN.md`
- LLM trace schema: `Docs/LocalLLMTrace.md`
- Eval suite: `Docs/EvalSuite.md`
- Apple data-access constraints: `tmp/research/2026-05-12-apple-data-access.md`
