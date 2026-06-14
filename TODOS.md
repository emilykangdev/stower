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
- [ ] **Precise attachment kind via the `attachment`-table UTI (no-reply engine, v1.1)** —
  v1 `lastMessageKind` labels any media as a generic `attachment` (read from the
  `message.cache_has_attachments` flag alone). To say "photo" / "voice note" / "video" /
  "file" / "sticker" instead, join the `attachment` table via `message_attachment_join`
  and read its `uti` / `mime_type` (metadata only, never the file bytes — e.g.
  `public.jpeg`→photo, `public.audio`→voice note, `public.movie`→video). Verify the
  attachment-table schema with `Scripts/inspect-chatdb-shapes.sh` before relying on column
  names (same verify-first lesson as the `associated_message_guid` prefix). Also splits
  sticker-vs-photo. Decided coarse for v1 on 2026-06-13. Effort: S-M.
  Depends on: no-reply engine landed.
