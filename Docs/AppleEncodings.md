# Stower — Apple `chat.db` Encodings

A living reference for the **on-disk encodings Apple uses in `chat.db`** that
Stower has to decode. Apple's Messages schema stores several fields in shapes
that are not what they look like — a "date" that is nanoseconds since 2001, a
"body" that lives in an archived blob and not in `text`, a "reaction target"
that wraps the real GUID in a part-reference prefix. Each one is a place where a
naive read passes a fixture and then silently misbehaves on real data.

This doc records **what the encoding actually is, why it's shaped that way, and
how Stower decodes it** — separately from `Docs/DataModel.md` (which maps *which*
columns exist) and the adapter rationale in `Docs/StowerMessages.md`.

> **Living doc.** Update it when the rationale or the evidence changes — when we
> learn a new encoding, or re-measure and the shape shifts across an OS version.
> Don't update it for code refactors that don't change the encoding.

## How to (re-)measure — without leaking content

Every empirical claim below comes from `Scripts/inspect-chatdb-shapes.sh`, a
read-only, redaction-by-construction diagnostic that copies the live `chat.db`,
runs fixed aggregate queries against the copy, and prints **only structural,
redacted aggregates** (histograms, prefix shapes, counts) — never message text,
handles, chat ids, or full GUIDs. Re-run it to refresh the numbers here:

```bash
./Scripts/inspect-chatdb-shapes.sh --diagnose   # safety: every section "clean"
./Scripts/inspect-chatdb-shapes.sh              # the redacted shape report
```

**Last measured: 2026-06-13** (Emily's machine, macOS; `n = 18 383` message
rows, `2 706` reaction rows). Numbers below are from that run.

---

## 1. Reaction target GUID — `associated_message_guid`

**The encoding.** When you tapback a message, Apple does not record "reaction →
message X." It records "reaction → **part N of message X**." The target is
stored in `message.associated_message_guid` on the *reaction* row, wrapped in a
part-reference prefix:

```
p:0/A1B2C3D4-1111-2222-3333-444455556666
│ │ └───────────── the target message's guid (== some message.guid) ──┘
│ └─ part index (0 = first part)
└─── "p" = part reference
```

The trailing GUID is **byte-for-byte equal** to a row's `message.guid`. The
`p:N/` is metadata *around* that identifier, not part of the identity.

**Why a "part" wrapper exists.** An iMessage *message* row is not always one
bubble. A single message can carry **multiple parts** — e.g. a photo plus a
caption, or several stacked attachments. You can react to *one specific part*:
tapback just the photo, or just the text. So Apple must record not only *which
message* but *which part of it*, and `p:N/` is that "part N of…" pointer. A
reaction's identity is therefore `(part index, target message guid)`; the
message itself has only the guid, with no part wrapper.

**Consequence.** A raw string compare of `associated_message_guid` against
`message.guid` can never match a prefixed reaction. The part wrapper has to come
off first. This is invisible to fixtures: a fixture author naturally writes the
clean bare GUID, the test passes, and the prefixed reality on a real device is
never exercised — so tapback-clearing silently no-ops on real data.

**The three shapes we measured** (of 2 706 reaction rows):

| shape | count | % | decode |
| --- | ---: | ---: | --- |
| `p:N/<guid>` | 2 368 | 87.5% | strip `p:N/` → the guid after the last `/` |
| `bp:<guid>`  | 20    | 0.7%  | strip `bp:` → the guid after the `:` |
| bare `<guid>`| 318   | 11.8% | already the guid; matches as-is |

Cross-checked against `message.guid`: **2 387 reactions (88%) match ONLY after
prefix-strip**, 318 match bare, 1 matches neither (a target message that no
longer exists). The 318 bare rows line up exactly with the `(bare)` shape count —
these are reactions stored under an **older encoding** (the format has shifted
across macOS/iOS versions).

**Normalization rule** (`normalizeAssociatedGUID`): recover the bare guid by
taking the substring **after the last `/`** if present (handles `p:N/<guid>`),
else **after the `:`** if present (handles `bp:<guid>`), else the value
unchanged (bare). Compare *that* to `message.guid`.

> **Certainty.** The `p:` part-reference reading is well-established for
> `chat.db`. The `bp:` variant (20 rows, 0.7%) is rarer and its exact semantics
> beyond "same guid-after-delimiter shape" are not confirmed. The strip logic
> treats both identically, so it does not affect correctness — but before *using*
> the part index for anything (e.g. distinguishing which attachment was reacted
> to), verify the `bp:` case against real data first.

---

## 2. Reaction type — `associated_message_type`

A non-zero `associated_message_type` marks the row as a reaction rather than a
real message (`type = 0`). The value encodes **which** tapback, and whether it
was **added** or **removed**, by range:

- **`0`** — a real message (not a reaction).
- **`2000–2999`** — a tapback **added**.
- **`3000–3999`** — a tapback **removed** (offset of exactly `+1000` from its
  added counterpart).

Known subtypes (added range; subtract nothing / add 1000 for the removal):

| type | tapback |
| ---: | --- |
| 2000 | Loved (heart) |
| 2001 | Liked (thumbs up) |
| 2002 | Disliked (thumbs down) |
| 2003 | Laughed (haha) |
| 2004 | Emphasized (‼️) |
| 2005 | Questioned (?) |
| 2006 | custom emoji / sticker tapback (newer macOS/iOS) |

Measured distribution (added): 2000=1 689, 2001=622, 2006=315, 2004=59,
2003=14. Removed: 3000=4, 3001=2, 3006=1. The substantial 2006 count is
consistent with modern custom-emoji reactions; the `+1000` removal symmetry
(3000/3001/3006 mirror 2000/2001/2006) is visible in the data.

> **Certainty.** 2000–2005 is the long-documented standard set. 2006 / 3006 is
> the newer custom-emoji/sticker range — high confidence from the distribution,
> but the exact emoji-per-number mapping there is not pinned down.

For the engine, only the **ranges** matter: `type = 0` excludes reactions from
chronology reads (so they don't double-count as messages); `BETWEEN 2000 AND
3999` selects reactions; the added/removed split lets added-then-removed net out.

---

## 3. Balloon kind — `balloon_bundle_id`

`balloon_bundle_id` names the app/extension that rendered a special bubble. It is
an **app identifier** (reverse-DNS, sometimes with `:teamid:` segments), never
user content, so it is safe to print verbatim. `NULL` means an ordinary
text/attachment message.

Measured (18 383 rows):

| `balloon_bundle_id` | count | meaning |
| --- | ---: | --- |
| `(null)` | 17 953 | ordinary message (text and/or attachments) |
| `com.apple.messages.URLBalloonProvider` | 430 | a **link** — URL kept in the body, rendered as a rich preview |
| `com.apple.messages.MSMessageExtensionBalloonPlugin:…:com.apple.findmy.FindMyMessagesApp` | 1 | a third-party/extension app balloon (here: FindMy) |

**Link / Maps storage (resolved).** A shared link — including a Google/Apple
Maps link — lands as `URLBalloonProvider` with the **URL in the message body**,
so it is indexable as text. There is **no** separate Apple Maps *app-balloon*
bundle id in the data; only the single FindMy extension balloon. So a Maps link
is a URL balloon (indexed), **not** an excluded app balloon — the engine sees it
as a real "last message."

This is why `StowerMessageQuery.indexableMessagePredicate` admits
`balloon_bundle_id IS NULL OR = URLBalloonProvider` and excludes everything else:
app-extension balloons (stickers, payments, FindMy, …) carry no recall-worthy
body text.

---

## 4. Message date — `message.date`

`message.date` is **not** a Unix timestamp. It is offset from the **Cocoa /
Apple reference epoch, 2001-01-01 00:00:00 UTC**, and its *unit* depends on the
OS version:

- **Modern macOS/iOS** — **nanoseconds** since 2001 (a ~19-digit number).
- **Legacy** — **seconds** since 2001.

Stower disambiguates by magnitude: a threshold of `1_000_000_000_000` (1e12).
At/above it, the value is nanoseconds (divide by 1e9 to get seconds); below it,
it's already seconds. Then `Date(timeIntervalSinceReferenceDate:)` converts from
the 2001 epoch. A raw `0` is treated as "no date" (`nil`), not 2001-01-01.

See `StowerMessageDate` (`nanosecondsThreshold`, `date(from:)`) and the SQL
mirror `referenceSecondsExpression` in `StowerMessageQuery`.

---

## 5. Message body — `text` vs `attributedBody`

On Ventura and later, a message's body is frequently **`NULL` in `text`** and
lives instead in **`attributedBody`** — an archived `NSAttributedString` stored
as a **typedstream blob** (Apple's `NSKeyedArchiver`/`NSArchiver` binary
format), not plain UTF-8. Reading only `text` loses most modern message bodies.

Stower decodes the blob in `StowerAttributedBodyDecoder` and treats a row as
having a body when **`text IS NOT NULL OR attributedBody IS NOT NULL`**. The
"attachment-only / body-empty" rows (`cache_has_attachments = 1 AND text IS NULL
AND attributedBody IS NULL`) are the genuine no-text case — measured at just **7
rows**, i.e. a near-non-issue.

> Privacy: `text` and `attributedBody` are real content and are **never**
> selected by the inspector script (only their `IS NULL`-ness is, as a count).

---

## See also

- `Docs/DataModel.md` — which tables/columns exist and their lifecycle.
- `Docs/StowerMessages.md` — the adapter that consumes these encodings.
- `Scripts/inspect-chatdb-shapes.sh` — the read-only diagnostic that produced
  every number here.
- `Sources/StowerMessages/StowerMessageDate.swift`,
  `StowerMessageQuery.swift`, `StowerMessageMapper.swift`,
  `StowerAttributedBodyDecoder.swift` — the decoders.
