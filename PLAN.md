# Stower plan

Local-first AI recall over Apple data (Photos + iMessages). Voice query →
hybrid FTS5+embedding search → top matches + summary. Native Mac app v1;
phone PWA hitting a local Mac server v2; iOS Photos-only MAS app v3.

## Status

- 2026-06-25: **Supabase licensing backend — the Edge Function is now the licensing brain (mint + check-in + webhook).**
  Decision (Emily, firm, 2-way door): the licensing brain is the existing `supabase/functions/license/`
  Edge Function, **not** a new Railway service (Railway plan superseded). Extended the function in place:
  `/mint-trial` now activates the Keygen machine + checks out a 7-day signed machine file and returns
  `{minted, licenseKey, licenseID, machineID, machineFile}` (wire field renamed `key`→`licenseKey`);
  NEW `POST /check-in` (reachable-launch gate authority — per-license JC5 signature, once-per-major +7d
  extension via record-before-patch to a frozen target (I11, idempotent under crash/retry), validate +
  machine repair, entitlement OR in code (I4), fresh signed-file checkout (I13), never returns the key);
  NEW `GET /health`; `/ls-webhook` now attaches `STOWER_V0` + records `purchased_major`/`entitlement_code`.
  New modules: `github.ts` (current-latest-stable-major for the +7d decision; 5-min cache; null-on-failure),
  `requestSignature.ts` (JC5 verifier via Web Crypto, 120s window, committed parity vector in `fixtures/`).
  Migration `20260625_license_checkin.sql` (additive: `device_trials` columns + `trial_extension_grants`
  + `purchases` columns). JC7 for v0: the required entitlement is the flat `STOWER_V0` constant (no major
  derivation yet; per-major `STOWER_V${major}` from `purchased_major` returns at v1); JC9 keeps the
  `STOWER_V0` *code* a per-runtime constant (only the `KEYGEN_V0_ENTITLEMENT` UUID is env). **A2 resolved
  (one-way door):** Keygen's `include=` entitlements + license expiry live INSIDE the Ed25519-signed `enc`
  payload — the CI integration test now decodes `enc` and asserts it. Deleted the dead, unwired
  `StowerKeygenClient.swift` (+ its test) — that surface is server-side now. Contract → v1.13, `Docs/Lifecycle.md`
  reversed (brain = Edge Function), both diagrams updated. 55 Deno tests green; `swift build` green.
  **Still open:** mint rate-limiting (risk #8), explicit outbound-fetch timeouts (item B), `pg_cron` orphan
  sweep (item C), and the ops cutover (point the LS webhook at `…/ls-webhook`, set Plan B's base URL).
- 2026-06-18: **License core — fingerprint, lease store, Keygen + mint clients, Supabase function (Bucket A, board-independent).**
  Ships the trial-and-upgrade machinery as four injected, unit-tested seams plus a Deno Edge Function —
  nothing wired into the app yet (the gate that composes them is Plan B). `StowerDeviceFingerprint`
  (`IOPlatformUUID` via IOKit → SHA-256 hex; Keychain-UUID fallback; `nonisolated`, injected readers).
  `StowerLicenseLeaseStore` (Keychain generic-password seam `StowerLeaseStorage`/`StowerKeychainItem`,
  `kSecAttrAccessibleAfterFirstUnlock`, no iCloud) verifies a machine-file's Ed25519 signature over
  `"machine/"+enc` against an embedded public key on every load — a tampered cache loads as `nil` (I7).
  `StowerKeygenClient` (raw `URLSession` JSON:API to `api.keygen.sh`: activate / check-out(ttl) /
  validate-key; `Authorization: License <key>`; transport throw surfaced, 5xx → `.server`).
  `StowerTrialMintClient` (POST fingerprint → `mint-trial` → `.minted`/`.retryShortly`/`.unreachable`,
  never `{null,null}`). `supabase/`: `device_trials` + `purchases` migrations and a `license` function
  (`handlers.ts` pure logic + `index.ts` wiring) — `mint-trial` is row-idempotent with crash recovery
  (I3) and `ls-webhook` verifies the LS HMAC (I9), validates variant, `PUT /policy` trial→paid, records
  only on success, replay/forged-id safe (I8/I15). Hardened through a Codex ship loop: per-claim
  token on `device_trials` (a stalled winner can't overwrite a reclaimed row), `created_at`-guarded
  reclaim, orphan-storm guard (a post-create DB failure keeps the claim), paid upgrade also clears the
  trial expiry (perpetual), DB-lookup errors 500 (never a silent ack), RLS on both tables, and
  `config.toml verify_jwt=false` so the webhook + anonymous mint reach the function. 22 Swift tests +
  20 Deno tests; `Scripts/precheck.sh` green (212 tests). **O2 resolved:** trial = 30d (function),
  machine-file checkout TTL = 7d
  (`StowerKeygenClient.machineFileTTL`, the single offline-validity boundary — the gate must read the
  file's own expiry, not add a second window). **Still open (tracked, out of this slice):** B1 — the
  `mint-trial` endpoint is unauthenticated; needs an abuse control (Supabase rate-limit / proof-of-work
  / App Attest) before public launch. Embedded Keygen Ed25519 public key is an all-zero placeholder
  until Plan B wires the real account key.
- 2026-06-18: **Lemon Squeezy license-entry gate (activate-once, store, no recurring validate).**
  Stower is now paid from first launch. After the model-availability check and before the FDA gate,
  `StowerStartupModel` checks a new `StowerLicenseGating` seam: a stored license (`hasStoredLicense`,
  pure local `UserDefaults` read) proceeds with zero network; otherwise `.needsLicense(nil)` shows the
  new `StowerLicenseEntryView` (focused monospaced field, inline error, help row), and `submitLicense`
  runs `runActivation` under the existing generation token + shared do/catch — `.checkingLicense`
  spinner, `activate` (pure), then a generation-guarded `persistLicense` so a superseded activation
  never writes. The only network egress is `StowerLemonSqueezyClient` POSTing once to
  `/v1/licenses/activate` (percent-encoded form body; decodes `{activated, instance.id,
  meta.store_id, meta.product_id}` and requires the store/product IDs to match Stower's — a key for
  any other Lemon Squeezy product is `.invalid`; never decodes `customer_email`/`customer_name`;
  transport-throw/5xx/undecodable → `.couldNotReach`; 15s timeout). `{key, instance_id}` is
  stored plaintext in `StowerLicenseStore`; no `clear()`/`/validate` in v1 (next ticket). New states
  `.checkingLicense` / `.needsLicense(StowerLicenseGateError?)`; `StowerCheckingView` switch is now
  exhaustive (no `default:`). `StowerTrustBlock` copy owns the one call honestly. `precheck.sh` step
  6g bans logging in `StowerMacUI` (key/PII). `Scripts/precheck.sh` green. Open / config Emily must set before selling:
  `StowerLemonSqueezyLicenseGate.expectedStoreID`/`expectedProductID` are PLACEHOLDER `0`s (the
  product check fails closed — no key activates until set to the real dashboard IDs); the
  support/product URLs in `StowerLicenseEntryView` are placeholders; O2 `instance_name` is a fixed
  "Stower" label; O1 paid-vs-trial kept as paid.
- 2026-06-18: **StowerMac v1 debt-board surface (board slice).** Built the reply-debt board on the
  merged engine + onboarding slice. New app-owned `Board/` group in `StowerMacUI`: view-models
  (`StowerBoardRow`/`StowerThreadLine` — `Identifiable` by `chatID`/GUID, no confidence exposed),
  `StowerBoardModel` (+`StowerBoardDirection`), `StowerDayPreset` (7/14/28/60/90, default 7),
  `StowerLastMessageKind` mirror + the pure `StowerLastMessageSummary` non-text rule (placeholder
  italic + angle-bracketed), `StowerBoardRefreshOutcome`, the `StowerBoardDataSource` seam (untyped
  `throws`), `@MainActor @Observable` `StowerBoardViewModel` (load/refresh split, generation guard on
  load only, `isRefreshing`-guarded re-issue loop) + `StowerThreadViewModel`, and an injectable
  `StowerMessagesLinkOpener`. Three new engine-coupled files join the adapter: `StowerMessagesMapping`
  (shared maps incl. the moved `mapError`/`mapConfig`/`mapReason`/`mapAvailability`),
  `StowerLiveBoardDataSource`, and `StowerMessagesComposition` (ONE `StowerDebtBoardProvider` injected
  into both adapters). Views: `StowerBoardView` (toggle + day filter + manual refresh + preparing /
  rows / caught-up / error), `StowerNoReplyRowView`, `StowerThreadView` (bubbles + Open in Messages).
  `StowerRootView` renders the board at `.connectedPreparingBoard` via a `@State` board VM whose
  `onFailure` calls the new `StowerStartupModel.handleBoardFailure` — `StowerStartupState` gains NO
  board cases. One permitted engine change: doc-comment sweep pinning `recentMessages` "newest
  `limit`, oldest-first" across the three sibling comments + the `StowerConversationFactsReading`
  one-reader fix, plus `StowerDebtBoardThreadOrderTests` pinning the order. `precheck.sh` 6b widened
  to the four engine importers (sorted-set compare). `Scripts/precheck.sh` green (204 tests). The
  human Xcode shell wiring (Task 5 of the prior slice) is already merged.
- 2026-06-17: **StowerMac FDA-onboarding slice + judge-owned model id.** Task 0 moved the
  cache-invalidation epoch off the app surface: `StowerDebtBoardProvider` no longer takes or
  exposes `modelIdentity`, and `StowerFoundationModelReplyJudge` owns a `static modelIdentity`
  folded into `judgeVersion()` — the judge owns its prompt AND its model id; behavior unchanged
  (the verdict cache still auto-invalidates on a prompt/model change). New tested `StowerMacUI`
  library with an app-owned startup boundary the SwiftUI views never leave: `StowerStartupProviding`,
  `StowerStartupModelAvailability` / `StowerStartupModelUnavailableReason`, `StowerStartupDebtConfig`
  (`appDefault` `unansweredForDays: 3`), `StowerStartupFailure`, `StowerStartupState`, and a
  `@MainActor @Observable StowerStartupModel` with Task+generation re-entrancy (cancel-before-replace;
  `CancellationError` never routes to `.failed`). Only `StowerMessagesStartupAdapter` imports
  `StowerMessages`, mapping the seven-case `StowerMessagesError` + availability + config 1:1. FDA-first
  views (`StowerRootView` is the lone `public` symbol; FDA / model-unavailable / checking /
  connected-loading / failure) per the UI Contract, plus one isolated System Settings opener (FDA +
  Apple Intelligence panes, `guard let` + general fallback). Access-granted parks at an honest
  `.connectedPreparingBoard` loading state — the board + `refreshJudgments` lifecycle are the next
  slice. `precheck.sh` Step 6 now gates the StowerMacUI import boundary, the Messages-probe ban, and
  the app-entry imports. `Scripts/precheck.sh` green (163 tests). **Still blocked at Task 5 (human
  Xcode step): add the local package, link the `StowerMacUI` product, App Sandbox off, macOS-only,
  render `StowerRootView()`, delete `ContentView.swift`.**
- 2026-06-15: Relationship-debt engine went **FM-only and judged-only**
  (remove-heuristic-reply-judge). The heuristic judge
  (`StowerHeuristicReplyJudge`), the judge-mode concept (`StowerReplyJudgeMode` /
  `StowerDebtConfig.judgeMode`), the `.heuristic` verdict-source token, and the
  standalone reply-debt measurement CLI subcommand are deleted — there is **no
  heuristic fallback**;
  on an unsupported Mac the engine throws rather than degrading. The board is
  judged-only: a conversation reaches Neglected or Ghosted only once the on-device
  model has judged it and a trusted verdict is cached (no pending row). Both lists
  gate on the model's should-respond verdict, differing only by direction —
  `StowerNoReplyPolicy` (Neglected, counterpart-last) gates on the boolean;
  `StowerGhostedPolicy` (Ghosted, you-last) keeps an additional `ghostGateThreshold`
  confidence gate. The public row `StowerDebtItem` collapsed to display fields +
  `replyExpectationConfidence` (dropped `verdictSource`, `expectsReply`, `reason`).
  Availability is typed: `modelAvailability() async -> StowerModelAvailability`
  routes at startup, and `loadDebtBoard` throws
  `StowerMessagesError.languageModelUnavailable(reason)`
  (`StowerModelUnavailableReason`) BEFORE opening `chat.db` on an unavailable
  device. `refreshJudgments` is `async throws -> StowerRefreshSummary?` (`nil` =
  coalesced; throws `languageModelUnavailable` when unavailable); the summary
  carries `changedChatIDs`, `judgedCount`, `failedCount`, `totalCount`, and the app
  clears its cold-start loading screen at `judged + failed == total` and reloads
  when `changedChatIDs` is non-empty. Each record is judged under a per-record FM
  timeout; the judge's own `modelIdentity` epoch folds into the judge version and the
  input hash fingerprints the raw message text. `Scripts/precheck.sh` green.
- 2026-06-14: Relationship-debt engine groundwork in `StowerMessages` (feature 5).
  Two-layer, pure, reads only the local 180-day window on the existing read-only
  snapshot — index path untouched. Layer 1 is a neutral facts extractor
  (`StowerConversationState` / `StowerConversationStateExtractor`): true last act
  + `lastMessageKind` from a chronology read over all content types, recent
  reciprocity, and tapback-clearing via chat-provenance reactions with
  prefix-normalized (`p:N/`, `bp:`) target GUIDs. Layer 2 is the Neglected policy
  over those facts (`StowerNoReplyPolicy`): 1:1 → recency-gated mutuality →
  counterpart-last → not tapback-cleared → ≥ threshold, ranked
  most-recently-unanswered first. 21 new tests; `Scripts/precheck.sh` green.
  Deferred to v1.1: precise attachment kind via the `attachment`-table UTI,
  per-contact dedupe.

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
