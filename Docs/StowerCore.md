# StowerCore

## Why

Source-agnostic search and index. The model: every adapter (`StowerPhotos`,
`StowerMessages`, future Notes/Calendar/etc.) produces values that conform
to `StowerIndexedItem`. `StowerCore` flattens them into namespaced
`StowerStoredItem` rows and indexes body and group-title text with FTS5.

`StowerCore` must never import `StowerPhotos`, `StowerMessages`, PhotoKit, or
`chat.db`-specific GRDB types. The dependency arrow points *into* this module,
never out of it. This keeps it testable without PhotoKit or `chat.db` in the
loop and lets us add new sources without churn.

## Public API surface

- `StowerIndexedItem` — the eight-field adapter contract: native id, source,
  body, timestamp, metadata, deep link, group id, and group title.
- `StowerIndex` — actor-isolated file-backed or in-memory Index DB with
  rebuild-only ingestion and safe tokenized search.
- `StowerSearchResult` — stored item, marked snippet, and bm25 score, with
  rank-preserving grouping by group id.

## Index design

- `item` is the durable content table. Core namespaces ids as
  `<source>:<native-id>` so adapters cannot collide.
- `item_fts` is an FTS5 external-content table over `text` and `group_title`,
  joined to `item` by SQLite rowid only during keyword search.
- The tokenizer is Porter over Unicode61, providing English stemming and
  diacritic folding.
- Search uses `FTS5Pattern(matchingAllTokensIn:)`, never raw FTS syntax.
- Body text has weight `1.0`; group title has weight `0.25`.
- Ingestion deletes all `item` rows, inserts the new set, and runs FTS
  `rebuild` in one transaction. v1 intentionally has no incremental path.
- A stale `schema_version` erases and recreates the Index DB.

## Open questions

- Embedding model: `all-MiniLM-L6-v2` via CoreML vs. on-device sentence
  transformer via MLX. Defer until we have measured latency on M-series.
- Embedding storage format: float16 quantized vs. float32. Defer.
- v1.1 embeddings should join to stable `item.id`, never the FTS rowid.

## See also

- Plan: `PLAN.md`
- LLM trace schema: `Docs/LocalLLMTrace.md`
- Eval suite: `Docs/EvalSuite.md`
- Apple data-access constraints: `tmp/research/2026-05-12-apple-data-access.md`
