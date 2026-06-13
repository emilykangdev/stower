#!/usr/bin/env bash
# inspect-chatdb-shapes.sh — read-only, redacted chat.db shape diagnostic.
#
# Answers two empirical questions blocking the no-reply / relationship-debt
# engine, against the REAL chat.db, while emitting only structural aggregates:
#   1. How is a reaction's target stored? Is associated_message_guid bare
#      (== message.guid) or prefix-encoded (p:0/<guid>, bp:<guid>)? This decides
#      whether normalizeAssociatedGUID must strip a prefix.
#   2. How does a Maps/URL link land? URLBalloonProvider (indexed) vs an app
#      balloon (excluded)? This decides what counts as a "last message."
#
# SAFETY (see the plan's INV1-INV5):
#   - The live Messages database is NEVER handed to the query engine. It is
#     copied with `cp` (a filesystem copy, not a checkpoint-capable database
#     connection); only the copy is opened, read-only + immutable.
#   - Every SELECT names ONLY structural columns (counts, balloon_bundle_id,
#     associated_message_type, derived prefix heads, NULL-ness booleans). No
#     message body, attributedBody, handle, chat identifier, or full GUID value
#     is ever selected. Section 4 joins on GUIDs but emits only integer counts.
#   - The full report is buffered and scanned by a fail-closed redaction guard;
#     nothing prints if the guard trips.
#   - The temp copy is removed on every exit path by a trap.
#
# Usage:
#   ./Scripts/inspect-chatdb-shapes.sh            # run the report (needs FDA)
#   ./Scripts/inspect-chatdb-shapes.sh --self-test  # prove the guard works, no real data
#   ./Scripts/inspect-chatdb-shapes.sh --help

set -euo pipefail

# ── Section headers (static; report scaffold renders these even with no rows) ──
SECTION_1="Section 1 — balloon_bundle_id histogram  (Maps link: URLBalloonProvider vs app balloon)"
SECTION_2="Section 2 — reaction associated_message_type histogram"
SECTION_3="Section 3 — associated_message_guid prefix-shape histogram"
SECTION_4="Section 4 — reaction target match: bare vs prefix-strip  (does normalizeAssociatedGUID need to strip?)"
SECTION_5="Section 5 — attachment-only / body-empty row count"

# ── Redaction guard ──────────────────────────────────────────────────────────
# Returns 0 (success) when the input CONTAINS something content-shaped, 1 when
# clean. The caller treats "contains" as fail-closed (abort, print nothing).
# Patterns: an email address, an international phone number (E.164 leading +),
# a hyphenated hex UUID, or a long opaque run (>=25 alnum) that contains a digit
# (base64/hex/bare GUID). Structural output — bundle ids split by dots, small
# counts, short prefix heads like "p:<redacted>", and all-letter identifier
# words like "MSMessageExtensionBalloonPlugin" — matches none of these.
report_has_content() {
    if printf '%s\n' "$1" | grep -Eq "$GUARD_PATTERN"; then
        return 0
    fi
    # A long opaque run is content only if it carries a digit (see GUARD_LONGTOKEN).
    printf '%s\n' "$1" | grep -Eo "$GUARD_LONGTOKEN" | grep -Eq '[0-9]'
}

# ── SQL (allowlisted structural columns only) ─────────────────────────────────
# Reaction rows live in associated_message_type 2000-2999 (added) and 3000-3999
# (removed); a real message is type 0. See Docs/DataModel.md.

SQL_BUNDLE_HIST="SELECT '  ' || COALESCE(balloon_bundle_id, '(null)') || ' = ' || count(*)
FROM message
GROUP BY balloon_bundle_id
ORDER BY count(*) DESC;"

SQL_REACTION_TYPE="SELECT '  type ' || associated_message_type
  || CASE
       WHEN associated_message_type BETWEEN 2000 AND 2999 THEN ' (added)'
       WHEN associated_message_type BETWEEN 3000 AND 3999 THEN ' (removed)'
       ELSE ''
     END
  || ' = ' || count(*)
FROM message
WHERE associated_message_type >= 2000 AND associated_message_type < 4000
GROUP BY associated_message_type
ORDER BY associated_message_type;"

# Emits only the structural head up to and including the first '/' or ':', with
# the remainder replaced by the literal '<redacted>'. The tail (the GUID) never
# leaves SQLite. A value with no delimiter reports as '(bare)'.
SQL_PREFIX_SHAPE="SELECT '  ' || shape || ' = ' || n
FROM (
  SELECT
    CASE
      WHEN associated_message_guid IS NULL THEN '(null)'
      WHEN instr(associated_message_guid, ':') = 0
           AND instr(associated_message_guid, '/') = 0 THEN '(bare)'
      ELSE substr(
             associated_message_guid, 1,
             CASE
               WHEN instr(associated_message_guid, ':') = 0
                 THEN instr(associated_message_guid, '/')
               WHEN instr(associated_message_guid, '/') = 0
                 THEN instr(associated_message_guid, ':')
               ELSE min(instr(associated_message_guid, ':'),
                        instr(associated_message_guid, '/'))
             END
           ) || '<redacted>'
    END AS shape,
    count(*) AS n
  FROM message
  WHERE associated_message_type >= 2000 AND associated_message_type < 4000
  GROUP BY shape
)
ORDER BY n DESC;"

# Joins reaction targets against message.guid but SELECTs only integer counts.
# 'tail' = the value after the single delimiter ('/' for p:N/<guid>, ':' for
# bp:<guid>); it is used only inside the join, never emitted.
SQL_MATCH_COUNTS="WITH reac AS (
  SELECT
    associated_message_guid AS g,
    CASE
      WHEN instr(associated_message_guid, '/') > 0
        THEN substr(associated_message_guid, instr(associated_message_guid, '/') + 1)
      WHEN instr(associated_message_guid, ':') > 0
        THEN substr(associated_message_guid, instr(associated_message_guid, ':') + 1)
      ELSE associated_message_guid
    END AS tail
  FROM message
  WHERE associated_message_type >= 2000 AND associated_message_type < 4000
    AND associated_message_guid IS NOT NULL
)
SELECT
  '  reaction rows (non-null target): '
    || (SELECT count(*) FROM reac) || char(10) ||
  '  match bare (target equals message guid as-is): '
    || (SELECT count(*) FROM reac
        WHERE EXISTS (SELECT 1 FROM message t WHERE t.guid = reac.g)) || char(10) ||
  '  match ONLY after prefix-strip: '
    || (SELECT count(*) FROM reac
        WHERE g <> tail
          AND EXISTS (SELECT 1 FROM message t WHERE t.guid = reac.tail)
          AND NOT EXISTS (SELECT 1 FROM message t WHERE t.guid = reac.g)) || char(10) ||
  '  no match either way: '
    || (SELECT count(*) FROM reac
        WHERE NOT EXISTS (SELECT 1 FROM message t WHERE t.guid = reac.g)
          AND NOT EXISTS (SELECT 1 FROM message t WHERE t.guid = reac.tail));"

SQL_ATTACHMENT_ONLY="SELECT '  attachment-only / body-empty rows: ' || count(*)
FROM message
WHERE cache_has_attachments = 1
  AND text IS NULL
  AND attributedBody IS NULL;"

# Parallel arrays so --diagnose can walk the same five sections.
SECTION_HEADERS=("$SECTION_1" "$SECTION_2" "$SECTION_3" "$SECTION_4" "$SECTION_5")
SECTION_QUERIES=("$SQL_BUNDLE_HIST" "$SQL_REACTION_TYPE" "$SQL_PREFIX_SHAPE" "$SQL_MATCH_COUNTS" "$SQL_ATTACHMENT_ONLY")

# Patterns that are unambiguously real content wherever they appear: an email,
# an E.164 phone number, or a hyphenated hex UUID (a message GUID's shape).
GUARD_PATTERN='([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})|(\+[0-9 ()-]{6,})|([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})'
# A long opaque run (>=25 of [A-Za-z0-9_-]) is treated as content ONLY when it
# also contains a digit — that catches base64/hex blobs and bare GUIDs while NOT
# flagging readable all-letter identifier words like Apple's bundle-id segments
# (e.g. "MSMessageExtensionBalloonPlugin"), which gotcha #4 confirms are safe.
GUARD_LONGTOKEN='[A-Za-z0-9_-]{25,}'

# ── Read-only query helper ────────────────────────────────────────────────────
# Opens the COPY only, read-only + immutable (immutable ignores any WAL, so no
# shared-memory file is needed and the copy is treated as a frozen snapshot).
# Falls back to plain -readonly if this sqlite3 build lacks URI filenames. The
# live path is never passed here.
run_sql() {
    local db="$1" query="$2"
    if sqlite3 -readonly "file:${db}?immutable=1" "$query" 2>/dev/null; then
        return 0
    fi
    sqlite3 -readonly "$db" "$query"
}

emit_section() {
    local header="$1" query="$2" result
    result="$(run_sql "$DBCOPY" "$query")"
    printf '%s\n%s\n\n' "$header" "${result:-  (none)}"
}

build_report() {
    printf 'chat.db shape inspector — redacted structural report\n'
    printf '(no message text, handles, chat ids, or full GUIDs are ever shown)\n\n'
    emit_section "$SECTION_1" "$SQL_BUNDLE_HIST"
    emit_section "$SECTION_2" "$SQL_REACTION_TYPE"
    emit_section "$SECTION_3" "$SQL_PREFIX_SHAPE"
    emit_section "$SECTION_4" "$SQL_MATCH_COUNTS"
    emit_section "$SECTION_5" "$SQL_ATTACHMENT_ONLY"
    printf 'Reading: Section 4 — if "match ONLY after prefix-strip" dominates,\n'
    printf 'normalizeAssociatedGUID MUST strip the prefix; if "match bare"\n'
    printf 'dominates, the bare comparison is already correct.\n'
}

# ── Self-test: prove the guard catches content and passes structural lines ────
# Uses ONLY synthetic, fabricated strings. No chat.db, no real data, no DDL.
run_self_test() {
    local fails=0 bad clean header
    # Positives — each must trip the guard: phone, email, hex UUID, and a long
    # opaque run that carries a digit.
    for bad in \
        '+14155550100' \
        'tester@example.com' \
        '4F2AE8B0-1234-5678-9ABC-DEF012345678' \
        'AB12CD34EF56GH78IJ90KL12MN34'; do
        if report_has_content "$bad"; then
            printf 'ok: guard caught a synthetic %s-shaped value\n' \
                "$(printf '%s' "$bad" | head -c 1)"
        else
            printf 'FAIL: guard MISSED a synthetic content value\n' >&2
            fails=1
        fi
    done
    # Negatives — each must PASS: a clean structural line, and a long all-letter
    # identifier word (an Apple bundle-id segment is not content).
    for clean in \
        'com.apple.messages.URLBalloonProvider = 128   p:<redacted> = 40   type 2000 (added) = 12' \
        '  com.apple.messages.MSMessageExtensionBalloonPlugin = 73'; do
        if report_has_content "$clean"; then
            printf 'FAIL: guard false-positived on clean structural output\n' >&2
            fails=1
        else
            printf 'ok: guard passed a clean structural line\n'
        fi
    done
    # INV5 — the five section headers (esp. 1 and 4) render in the scaffold.
    for header in "$SECTION_1" "$SECTION_2" "$SECTION_3" "$SECTION_4" "$SECTION_5"; do
        if [ -z "$header" ]; then
            printf 'FAIL: a section header is empty\n' >&2
            fails=1
        fi
    done
    if [ "$fails" -ne 0 ]; then
        printf 'self-test FAILED\n' >&2
        exit 1
    fi
    printf 'self-test passed: redaction guard works and all five sections are defined\n'
    exit 0
}

# ── Diagnose: locate which section trips the guard, leaking nothing ───────────
# For each section that trips, prints the offending tokens with every letter
# replaced by 'A' and every digit by '9' (punctuation kept). This reveals SHAPE
# — e.g. an all-letter bundle-id word (A...A) vs a hex GUID (9A9A-9999-...) —
# without ever printing a real value. Masking is one-way and unrecoverable.
run_diagnose() {
    local i header query result
    printf 'DIAGNOSE — class-masked shapes only (letter->A, digit->9, symbols kept).\n'
    printf 'No real values are printed. Use this to tell a safe bundle id from a leak.\n\n'
    for i in "${!SECTION_HEADERS[@]}"; do
        header="${SECTION_HEADERS[$i]}"
        query="${SECTION_QUERIES[$i]}"
        result="$(run_sql "$DBCOPY" "$query")"
        if report_has_content "$result"; then
            printf '%s\n  TRIPS guard — masked offending tokens:\n' "$header"
            {
                printf '%s\n' "$result" | grep -Eo "$GUARD_PATTERN" || true
                printf '%s\n' "$result" | grep -Eo "$GUARD_LONGTOKEN" | grep -E '[0-9]' || true
            } | sed -e 's/[A-Za-z]/A/g' -e 's/[0-9]/9/g' \
                | sort -u | sed 's/^/    /'
            printf '\n'
        else
            printf '%s\n  clean\n\n' "$header"
        fi
    done
}

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

# ── Argument handling ─────────────────────────────────────────────────────────
MODE=report
case "${1:-}" in
    --self-test) run_self_test ;;
    --diagnose) MODE=diagnose ;;
    --help | -h) usage; exit 0 ;;
    '') ;;
    *)
        printf 'ERROR: unknown argument: %s\n' "$1" >&2
        printf 'Try --help, --self-test, --diagnose, or no argument.\n' >&2
        exit 1
        ;;
esac

# ── Locate the live DB (fail loud if absent — never a silent empty run) ───────
DB_LIVE="${HOME}/Library/Messages/chat.db"
if [ ! -f "$DB_LIVE" ]; then
    printf 'ERROR: chat.db not found at %s\n' "$DB_LIVE" >&2
    printf '  This script reads the local Messages database; it must exist.\n' >&2
    exit 1
fi

# ── Copy to a temp dir; remove it on every exit path ──────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DBCOPY="${TMP}/chat.db"

# `cp` is a filesystem copy — it never opens a checkpoint-capable sqlite
# connection to the live WAL database. A failure here is the read denial we want
# to surface (almost always Full Disk Access), so it fails loud (INV4).
copy_err="$(cp "$DB_LIVE" "$DBCOPY" 2>&1 1>/dev/null)" || {
    printf 'ERROR: could not read chat.db (copy failed).\n' >&2
    [ -n "$copy_err" ] && printf '  %s\n' "$copy_err" >&2
    case "$copy_err" in
        *"not permitted"*)
            printf '  This is almost certainly Full Disk Access. Grant your terminal\n' >&2
            printf '  Full Disk Access in System Settings > Privacy & Security, retry.\n' >&2
            ;;
    esac
    exit 1
}

# Copy the WAL/SHM sidecars too (immutable=1 ignores them, but keep the snapshot
# complete in case the fallback -readonly path is used).
for suffix in -wal -shm; do
    if [ -f "${DB_LIVE}${suffix}" ]; then
        cp "${DB_LIVE}${suffix}" "${DBCOPY}${suffix}" || {
            printf 'ERROR: failed to copy %s sidecar\n' "$suffix" >&2
            exit 1
        }
    fi
done

# ── Diagnose mode: report which section trips the guard, then stop ────────────
if [ "$MODE" = diagnose ]; then
    run_diagnose
    exit 0
fi

# ── Build, guard, then print ──────────────────────────────────────────────────
REPORT="$(build_report)"

if report_has_content "$REPORT"; then
    printf 'ERROR: redaction guard tripped — content-shaped data detected in the\n' >&2
    printf '  report. Output withheld; nothing was printed. This is fail-closed\n' >&2
    printf '  behavior: investigate the queries before re-running.\n' >&2
    exit 1
fi

printf '%s\n' "$REPORT"
