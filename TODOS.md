# TODOS

Deferred work with context, written by the 2026-06-12 /autoplan review of
`tmp/ready-plans/2026-06-12-stowercore-embeddings-hybrid-retrieval.md`.

- [ ] **CLI privacy posture (1.0.1)** — redaction-by-default + `--reveal` flag for
  `search`/`judge` output. Why: a permanent CLI printing intimate message text creates
  shell-history/screen-share/log leakage paths; today it's a single-user dev tool so
  readable output is the point (eval requires it). Start: `Sources/StowerCLI/`. (Codex
  CEO finding 12.) Effort: S.
- [ ] **Thread-chunk embedding experiment (v1.1)** — message-level embedding may be the
  wrong retrieval unit ("the pizza place Sam mentioned" needs surrounding turns/sender).
  If tonight's gate fails specifically on context-dependent queries, this is the first
  suspect. Compare message vs short-conversational-chunk embeddings in the eval harness.
  (Codex CEO finding 3.) Effort: M. Depends on: stower-eval existing.
- [ ] **Generation-staged embedding cache (v1.1, only if the Mac app needs it)** — the
  accepted stale-vector window (between `replaceAll` and embed completion) is fine for a
  single-user CLI; an app with background indexing may want generation-tagged vectors
  promoted atomically. (Codex eng finding 3; Decision Audit Trail row 20.) Effort: M.
- [ ] **MLX micro-LLM judges (stretch / 1.0.1)** — extend `ReplyJudge` with
  Qwen3-0.6B / Llama-3.2-1B via mlx-swift to widen the judge-off beyond Apple FM. The
  interface is pluggable; one new type per judge. Effort: M (dependency + model downloads).
- [ ] **Harden `import Hub` ban via harden-guardrail** — the plan adds a validation grep
  (no `import Hub` in `Sources/`); per AGENTS.md, route it through the
  `harden-guardrail` skill so it lands in `precheck.sh` as a mechanical gate, not a
  convention. Effort: S.
- [ ] **All-history / incremental indexing (v1.1, already on roadmap)** — tonight's eval
  tags out-of-window losses; if the window dominates the losses, this item's priority
  rises sharply (the cache makes all-history a one-time cost). Effort: L.
- [ ] **Non-destructive eval window switching (`eval --days` / named index profiles)** —
  today, comparing 180d vs 365d means destructive re-index each way. Fine for tonight;
  annoying for repeated experiments. (Codex DX finding 2.) Effort: S-M.
- [ ] **Precise attachment kind via the `attachment`-table UTI (relationship-debt engine, v1.1)** —
  v1 `lastMessageKind` labels any media as a generic `attachment` (read from the
  `message.cache_has_attachments` flag alone). To say "photo" / "voice note" / "video" /
  "file" / "sticker" instead, join the `attachment` table via `message_attachment_join`
  and read its `uti` / `mime_type` (metadata only, never the file bytes — e.g.
  `public.jpeg`→photo, `public.audio`→voice note, `public.movie`→video). Verify the
  attachment-table schema with `stower-chatdb-inspector` (`Sources/StowerChatDBInspector/`)
  before relying on column names (same verify-first lesson as the
  `associated_message_guid` prefix). Also splits
  sticker-vs-photo. Decided coarse for v1 on 2026-06-13. Effort: S-M.
  Depends on: relationship-debt engine landed.
- [ ] **`conversationStates` should decode only last-act bodies, not the whole window** —
  it reuses `ingestWindow`, which `attributedBody`-decodes every message in the window just
  to recover the last-act text per chat (cost ≈ one `stower index` ingest). Tolerable for a
  one-off load, but it is on the hot path now that the Mac app consumes the relationship-debt
  engine. Fix: read `activityRows` first, then fetch+decode only the
  last-act message body per chat (and the title) instead of the full window. (Codex
  ship-with-codex P2→P3, 2026-06-14.) Effort: M.
- [ ] **Move the snapshot `chat.db` copy off the cooperative thread pool (relationship-debt engine, own plan)** —
  `readerFactory()` (in `StowerDebtBoardProvider.sharedReader`/`refreshedReader`) constructs
  `StowerChatDatabaseReader`, whose `init` synchronously copies the entire `chat.db` (+ `-wal`/
  `-shm`) via `StowerChatSnapshot.copyDatabaseFiles` (`FileManager.copyItem`). That runs inside
  the actor's async methods (`loadDebtBoard`, `refreshJudgments`, `recentMessages`), so a copy
  of a multi-hundred-MB–GB database blocks the actor executor AND occupies a Swift-concurrency
  cooperative-pool thread for the whole copy — concurrent calls like `modelAvailability()` queue
  behind it. Warrants its own plan, not a surgical patch: run the copy off the cooperative pool
  (e.g. `withCheckedThrowingContinuation` + `DispatchQueue.global`), make `sharedReader`/
  `refreshedReader` `async`, `await` at the three call sites, and decide the first-open
  reentrancy the new suspension point introduces (two concurrent first-loads could each build a
  reader — benign double-copy, last writer wins, but consider coalescing). The seam is already
  safe: `StowerConversationFactsReading` is `Sendable` and `StowerChatDatabaseReader` is an
  `actor`, so the reader crosses isolation cleanly. (Fusion audit P2, qwen judge, 2026-06-16,
  conf 9.) Effort: M.

- [ ] **MLX / other-SLM judge experiments + eval harness (future)** — FM is the v0 judge;
  the `StowerReplyExpectationJudge` protocol is the swap seam. Experiment with MLX
  (Qwen3-0.6B / Llama-3.2-1B) or other small models behind the seam as separate conformers,
  each measured by its own eval harness. Build a purpose-built baseline/eval type at that
  point — do NOT resurrect the deleted `StowerHeuristicReplyJudge` (bad name; the regex
  baseline was nuked on purpose). Different prompts/models are cache-isolated automatically via
  `judgeVersion` (prompt+model hash). Surface future CLI measurement under a dedicated
  `experiment` command namespace, not the production engine API. (2026-06-15 /autoplan.) Effort: M.
- [ ] **Retry cap / permanent give-up marker for terminally-failed verdicts (future)** — v1
  counts a record it can't judge in `failedCount` (so loading still clears via
  `judged + failed == total`), but it writes no verdict for that record, so the next refresh
  pass re-attempts it — a record that always fails FM is re-judged forever. Honest and fine for
  v1. Later: cap retries (e.g. N attempts) or persist a permanent un-judgeable marker so refresh
  stops re-attempting it. (2026-06-15 /quizme follow-up.) Effort: S-M.
- [ ] **StowerMac loading / unsupported / "all caught up" UI + retry scheduling (StowerMac)** —
  the engine is FM-only and judged-only, so the app owns the surrounding states: a cold-start
  loading screen that fills as `refreshJudgments` reports `judged`/`failed`/`total` (cleared at
  `judged + failed == total`), an unsupported/onboarding screen routed off
  `modelAvailability()` / `StowerModelUnavailableReason`, and an empty-but-done "all caught up"
  state distinct from "still judging". Plus retry scheduling with backoff for a transient
  `.modelNotReady` and for failed records. These live in a separate StowerMac app branch.
  (2026-06-15 /autoplan CEO finding #4 / Eng perf.) Effort: M.
- [ ] **Cold-start FM warm-up: workload cap / cancellation / progress estimate (StowerMac)** —
  on a cold cache, both lists stay empty while serial on-device FM inference warms verdicts
  across potentially thousands of threads. The engine refreshes most-recently-active threads
  first; the app-side controls (cap per pass, cancellation policy, time estimate) belong in
  StowerMac. (2026-06-15 /autoplan CEO finding #4 / Eng perf.) Effort: M.
- [ ] **Enable the repo-wide `no_magic_numbers` swiftlint gate (own follow-up)** — AGENTS.md
  bans magic numbers/literals as a convention, but `no_magic_numbers` is not in
  `.swiftlint.yml`'s `opt_in_rules`, so nothing mechanically enforces it. Route it through
  `harden-guardrail` as its own plan: turn it on, sweep existing violations, and decide the
  exemptions (test fixtures, etc.). Out of scope for this branch. Effort: M.
