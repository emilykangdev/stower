<!--
THE ONLY FILE YOU EDIT PER REPO.

The workflow (.github/workflows/codex-review.yml) is byte-for-byte identical in
every repo. To customize the review for a repo, edit THIS file — plain review
instructions, no YAML, no ${{ }} templating. The workflow prepends the PR's diff
commands and feeds your text below to Codex.

To reuse in another repo: copy codex-review.yml unchanged, then replace
everything below this comment with that repo's review rubric.
-->

Run Stower's `swift-signal-review` skill. This is NOT a generic code review —
review ONLY against this repo's own catalog, by its own rules.

1. Read `.claude/skills/swift-signal-review/SKILL.md` and follow it.
2. Read `.claude/skills/SWIFT_PATTERNS.md` — the single source of truth. The
   entries marked `gate` are already enforced by `Scripts/precheck.sh` (and
   ci.yml); do NOT re-report those. Review the diff against the `judgment`
   entries that have no automated check: #5 over-broad public access, #9
   bypassing IndexedItem, #11 mixed structural + behavioral change in one
   commit, #12 real Photos/Messages data in fixtures/logs/prompts, #13
   catch-and-ignore, #15 naming by type instead of role.
3. Reject-on-sight, independent of the catalog: an unexpected loop,
   functionality nobody asked for, or a test weakened/skipped/deleted to make
   something pass.

Output using this format exactly:

  ## swift-signal-review
  Scope: <N files, M hunks>
  ### Must fix
  - file:line — [#entry] one-line issue + one-line fix (note if it recurs)
  ### Consider
  - ...
  ### Verdict
  <ship | fix-then-ship | reject> — <one sentence>

This is ADVISORY. Be concise and specific. If the diff is clean against the
judgment catalog, say so plainly and give a `ship` verdict.
