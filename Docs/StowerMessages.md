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
  carries direction and resolved sender attribution for the thread view.

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
- Attachment content, tapbacks, edited-message history, and group deep links.
- Incremental indexing and recall beyond the 180-day bulk window.

## See also

- Plan: `PLAN.md`
- Apple data-access constraints (Section 7 chat.db schema, Section 8
  attributedBody/Madrid, Section 13 FDA): `tmp/research/2026-05-12-apple-data-access.md`
