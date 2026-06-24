# StowerMessages

## Why

The Messages data-source adapter. Reads the local `chat.db` SQLite database
(read-only) via GRDB, decodes the `attributedBody` typedstream blobs, joins
against Contacts.app for handle→name resolution, and emits `StowerIndexedItem`
values for `StowerCore` to index. It owns everything `chat.db`-specific so
`StowerCore` stays source-agnostic.

Must never import `StowerPhotos`. The two adapters never know about each other.

## Public API surface

- `StowerChatDatabaseReader.ingestWindow(days:now:)` reads the recent search
  window across chats.
- `StowerChatDatabaseReader.recentMessages(chatID:limit:)` reads the newest
  messages in one chat without the search-window cutoff, then returns them in
  chronological order.
- `StowerMessageItem` is the adapter's `StowerIndexedItem` conformer and also
  carries direction, resolved sender attribution, and an `isOneToOne` flag for
  the thread view.
- `StowerChatDatabaseReader.conversationStates(windowDays:now:)` returns neutral
  per-1:1 conversation facts (`StowerConversationState`): the true last act and
  its kind (from a chronology read over **all** content types, not just
  indexable text), recent reciprocity, and whether the user tapped back the last
  message. This is the facts boundary — a future "drift" policy reads the same
  states with no engine re-cut.
- `StowerDebtBoardProviding` is the seam the StowerMac app depends on for the
  relationship-debt board. `modelAvailability()` routes at startup;
  `loadDebtBoard(config:now:)` builds the two-lens, judged-only board at
  structural speed (it never runs the model); `refreshJudgments(config:now:)` is
  the background pass that judges and backfills the verdict cache. Two pure,
  stateless policies select the rows over the judged facts: `StowerNoReplyPolicy`
  (Neglected — the counterpart acted last) and `StowerGhostedPolicy` (Ghosted —
  you acted last). Both gate on the on-device model's should-respond verdict;
  Ghosted additionally keeps a confidence threshold. Mutuality is recency-gated
  (recent reciprocal exchanges, not a lifetime boolean), a tapback counts as a
  reply, and a non-text last act is surfaced with its `lastMessageKind`, never
  suppressed.

### Relationship-debt engine reads (not indexed)

The engine adds two read paths on the **same** read-only snapshot, never the
index: a chronology read (`activityRows`, every real message of any content type
— `associated_message_type = 0 AND item_type = 0`) for the true last act, and a
reaction read (`myReactionRows`, the user's own tapbacks `2000–3999`) for
mutuality and last-message clearing. Reactions carry their own chat provenance so
mutuality-by-reaction works even when the reacted-to message is non-indexable.
`associated_message_guid` is prefix-encoded on real data and is normalized to the
bare `message.guid` before comparison — see `Docs/AppleEncodings.md` §1 (GUID
prefix), §2 (reaction-type ranges), §3 (URL balloons). `style == 45` marks a 1:1
chat. Neither read produces `StowerIndexedItem`s; the content-only index is
untouched.

### Reply-expectation lifecycle (FM-only, judged-only)

The reply-expectation engine is **FoundationModels-only** and **judged-only** for
text. There is no heuristic *text* judge and no heuristic fallback: a text
conversation appears in Neglected or Ghosted only after the on-device model has
judged it and a trusted verdict is cached. The single non-model path is
*deterministic, not heuristic*: a counterpart's attachment-only last act (a
photo/file/voice note the text model can't read, but which plainly invites a
reply) gets a fixed trusted `.nonTextContent` verdict so it can reach the
Neglected lens. User-sent attachments take the model path and stay out of the
noisier Ghosted lens. Unjudged conversations are invisible — there is no pending
row.

- **Availability is a startup gate.** The app calls `modelAvailability() async ->
  StowerModelAvailability` before any board work. When the model can't run,
  `loadDebtBoard` throws `StowerMessagesError.languageModelUnavailable(reason)` —
  where `reason` is `StowerModelUnavailableReason` (`.deviceNotEligible` /
  `.appleIntelligenceNotEnabled` / `.modelNotReady` / `.unknown`) — **before** it
  opens `chat.db`. The app routes each state to an onboarding or unsupported
  screen rather than degrading to a heuristic board.
- **Cold start shows a loading screen.** `loadDebtBoard` serves only conversations
  with a trusted cached verdict, so a cold cache returns empty lists. The app
  shows a loading screen on first run, never an instant empty board.
- **Refresh reports progress.** `refreshJudgments(config:now:) async throws ->
  StowerRefreshSummary?` is the only model caller. It returns `nil` when coalesced
  (a pass is already in flight) and throws `languageModelUnavailable` when the
  model is unavailable. `StowerRefreshSummary` carries `changedChatIDs`,
  `judgedCount`, `failedCount`, and `totalCount`. The app clears its cold-start
  loading screen once `judgedCount + failedCount == totalCount` (never
  `judgedCount == totalCount` — a permanently failing record would hang the
  spinner) and reloads the board when `changedChatIDs` is non-empty. Each record
  is judged under a per-record timeout so one hung judge can't stall the pass.
- **Cache is the trust boundary.** Verdicts land in `StowerReplyVerdictCache`
  (`reply-verdicts.sqlite`), disposable and keyed by `(judge_version,
  message_guid)` with an `input_hash` over the raw last text. The judge's own
  model-identity epoch folds into the judge version, so a model-identity change
  invalidates stale verdicts. Bad payloads are rejected on write; an unknown
  source token is a miss on read.

## Constraints & known gotchas

- **`attributedBody` is mandatory, not optional.** On Ventura+ the `text`
  column is now `NULL` by default; the message body lives in the
  `attributedBody` typedstream blob. The reader must decode it (see Apple
  data-access research, Section 8). Plain-`text` reads alone will silently
  miss most messages.

- **Madrid 0.4.0 is pinned.** The decoder calls
  `TypedStreamDecoder.decode(_:)` and extracts the first NSString object
  directly. It does not use Madrid's lossy convenience text property, and its
  implementation file is the only source importing `TypedStream`.

- **The live Source DB is never opened.** The reader copies `chat.db` and any
  WAL sidecars into a unique system-temp directory, atomically promotes the
  copy, opens it with GRDB's read-only configuration, runs `PRAGMA quick_check`,
  and retries one torn copy. The snapshot is reused for both read paths and
  removed when the reader is released; snapshots older than one day are swept.

- **Messages dates use two units.** Modern values are nanoseconds since 2001;
  legacy rows use seconds. Zero is invalid. The SQL window filter and Swift
  mapping use the same `1e12` threshold.

- **Outgoing rows have no sender handle.** Chat participants are loaded in one
  set-based query and provide the title for sent messages. Incoming sender
  labels still use the row handle.

- **Noise rows are excluded.** Tapbacks, system rows, empty attachment rows,
  empty app-balloon rows, zero-date rows, and empty bodies do not become index
  items. A message joined to multiple chats is indexed once using deterministic
  query order.

- **Full Disk Access required.** `chat.db` access needs FDA, which is a
  user-granted TCC permission for a specific binary path — *not* an
  entitlement. The Mac app target therefore CANNOT enable App Sandbox
  (sandbox blocks FDA). This forfeits Mac App Store distribution for the
  unified app — an accepted tradeoff (see the brief and Apple data-access
  research, Section 13).

- **macOS 26 Tahoe AppleScript group-chat regression.** Out of scope for v1
  (no reply sending). Documented here so future contributors don't waste a day
  re-discovering it: sending to group chats via AppleScript regressed on
  Tahoe. v1 is recall-only; revisit if/when reply-sending is ever in scope.

## Deferred

- International phone normalization beyond exact E.164 and unambiguous
  last-ten-digit matching.
- Attachment content, edited-message history, and group deep links. (Tapbacks
  are no longer deferred — the relationship-debt engine reads them on a separate,
  non-indexed path.)
- Splitting the generic `attachment` last-message kind into photo/voice/video/
  file (needs the `attachment`-table `uti` join), and per-contact dedupe of a
  person's SMS + iMessage threads (needs a stable contact-identity key).
- Incremental indexing and recall beyond the 180-day bulk window.

## See also

- Plan: `PLAN.md`
- Apple data-access constraints (Section 7 chat.db schema, Section 8
  attributedBody/Madrid, Section 13 FDA): `tmp/research/2026-05-12-apple-data-access.md`
