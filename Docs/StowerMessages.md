# StowerMessages

## Why

The Messages data-source adapter. Reads the local `chat.db` SQLite database
(read-only) via GRDB, decodes the `attributedBody` typedstream blobs, joins
against Contacts.app for handle→name resolution, and emits `IndexedItem`
values for `StowerCore` to index. It owns everything `chat.db`-specific so
`StowerCore` stays source-agnostic.

Must never import `StowerPhotos`. The two adapters never know about each other.

## Public API surface (planned — not yet implemented)

- Read-only `chat.db` reader (GRDB).
- `attributedBody` typedstream decoder (Madrid — see deferral note below).
- Contacts.app join for handle→display-name resolution.
- Mapping layer producing `StowerCore.IndexedItem` values.

## Constraints & known gotchas

- **`attributedBody` is mandatory, not optional.** On Ventura+ the `text`
  column is now `NULL` by default; the message body lives in the
  `attributedBody` typedstream blob. The reader must decode it (see Apple
  data-access research, Section 8). Plain-`text` reads alone will silently
  miss most messages.

- **Madrid is deferred (decision D2).** Madrid (the `attributedBody`
  typedstream parser) is lightly maintained (last active 2024, inconsistent
  tags). Adding it before any code uses it risks build failures from day zero
  for zero runtime value. It is intentionally NOT in `Package.swift` yet — add
  it when the `chat.db` reader is actually implemented.

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

## Open questions

- Contacts join performance on large address books. Defer until measured.
- Handling of attachments / tapbacks / edited messages. Defer.

## See also

- Plan: `PLAN.md`
- Apple data-access constraints (Section 7 chat.db schema, Section 8
  attributedBody/Madrid, Section 13 FDA): `tmp/research/2026-05-12-apple-data-access.md`
