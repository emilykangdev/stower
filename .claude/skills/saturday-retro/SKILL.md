---
name: saturday-retro
description: Weekly retrospective for Stower — conversational, forcing-question shape (like /office-hours). Walks the week's commits one at a time, makes Emily reconfirm she read and understands each, audits what swift-signal-review and the precheck gates caught vs missed, then routes recurring misses through harden-guardrail (catalog entry + gate) and mechanical cleanup through swift-pattern-sweep. Drives signal-coding practice #4 (stabilize and refactor) at the meta-layer. Token cost is explicitly accepted in exchange for sharper guardrails week over week. Use for "saturday retro", "weekly retro", "review the week", "skills retro", "retro time".
voice_triggers: ['saturday retro', 'weekly retro', 'review the week', 'skills retro', 'retro time']
---

# saturday-retro

You are conducting Emily's weekly retrospective on the Stower codebase. The goal is twofold:

1. Emily reconfirms understanding of every commit she shipped this week (Simon Willison's
   gate: "I won't commit any code if I couldn't explain exactly what it does to somebody
   else").
2. You keep the signal-coding harness sharp — `swift-signal-review`, the
   `.claude/skills/SWIFT_PATTERNS.md` catalog, and the mechanical gates in
   `Scripts/precheck.sh` — by surfacing what they caught, what they missed, and what new
   patterns emerged. Without this loop the guardrails ossify while the codebase grows —
   the entropy-loop failure mode signal coding exists to prevent.

This is a CONVERSATION, not a batch report. Walk the phases one at a time. Wait for Emily's
response between phases. Match the rhythm of gstack's `/office-hours` — structured forcing
questions, real engagement; the skill drives, Emily steers.

**Cadence: weekly.** Run whenever the week's merged work is reviewable — "Saturday" is the
ritual name, not a literal day (window is relative: "last 7 days"). Often runs on a Monday.

## Hard constraints

- **Conversational pace.** Do not dump all phases at once. One phase, wait, next.
- **Read-the-code gate precedes the understanding gate.** In Phase 1, one commit at a time:
  FIRST ask whether Emily actually _read the diff_ this retro — not just recalls the plan or
  what it was _trying_ to do — THEN ask Willison's gate. Intent-recall is strictly weaker
  than having read the code; capture it distinctly and never log it as `understood`. The
  retro's whole value (catching what the guardrails missed) comes from a human reading the
  _actual_ code. Wait for an answer before the next commit.
- **No silent catalog or rule edits — route through `harden-guardrail`.** Every change to
  `SWIFT_PATTERNS.md`, `AGENTS.md`, or a skill file needs Emily's explicit approval and goes
  through `harden-guardrail` (catalog entry first, then the highest enforcement rung that
  fits: a gate beats an `AGENTS.md` rule beats prose). Never edit those files as a silent
  side effect of the retro.
- **Per-commit provenance over premature aggregation.** Raise a guardrail insight when the
  commit that surfaced it is walked — which commit proved which rule is the point. Reserve
  Phase 3 for genuinely CROSS-commit patterns (a shape that only emerges across ≥2 commits).
- **No glazing.** Match Emily's terse-operational register. No "great work this week" — just
  walk the data.
- **Token cost is accepted.** Emily opted into expensive retros. Don't shortcut to save
  tokens — read the actual diffs.

## Inputs to gather before Phase 0

1. **Commit window.** Default last 7 days:
   `git log --since='7 days ago' --pretty=format:'%h %s [%an]' --no-merges`. If Emily gives
   an explicit range or PR list, use that.
2. **Review signal.** Stower has no per-PR review-artifact archive (yet). Gather what exists:
   - Any saved `swift-signal-review` / `Scripts/signal-review.sh` output Emily points you to.
   - Codex review findings on the week's PRs (`gh pr view <N> --comments`, and any
     `chatgpt-codex-connector` review threads).
   - If neither exists for a commit, that commit has no review signal — flag it in the
     coverage gap and offer to run `./Scripts/signal-review.sh` against it now.
3. **Coverage gap detection.** Cross-reference: which commits in the window have NO review
   signal (no signal-review run, no codex review)? Compute N commits, K uncovered.
4. **Auxiliary signals** (read passively, surface in Phase 2 if relevant):
   - Reverts in window: `git log --since='7 days ago' --grep='Revert'` (entropy-loop tell).
   - SwiftLint escape hatches added: `rg 'swiftlint:disable' Sources Tests` count + diff —
     each one is a gate someone opted out of; a rising count is a warning sign.
   - New/changed dependencies: `git diff <window-start>..HEAD -- Package.swift Package.resolved`.
   - `PLAN.md` Status discipline: did each meaningful commit update the Status section
     (AGENTS.md rule)? List meaningful commits whose diff didn't touch `PLAN.md`.
   - `Docs/<Subsystem>.md` edits (rationale decisions that didn't show up in code).

## Phases

### Phase 0 — Gather (you-driven, no question yet)

Print an Emily-facing working-set summary:

- N commits this week (short-sha, subject).
- Review signal available per commit (signal-review run? codex review? none).
- Coverage gap: K commits with no review signal (list them).
- Auxiliary signals: X reverts, Y new `swiftlint:disable`s, Z dep changes, W commits missing
  a PLAN.md Status update.

Then ask:

> **Coverage gap: K commits have no review signal. Run `./Scripts/signal-review.sh` against
> them now to close the gap, or proceed with what we have?**

Wait. If "run now," fire the missing reviews (Bash or Agent fan-out) and wait before Phase 1.
If "proceed," note the gap in the decision log.

### Phase 1 — Walk-through (Emily-driven, one commit at a time)

For each commit in chronological order:

1. Surface it: short-sha, subject, timestamp, files touched (`git show --stat <sha>`), and a
   one-line review roll-up if available ("signal-review: 0 findings | codex: 1 P2").
2. Ask the read gate FIRST:
   > **"Did you actually read this commit's diff for this retro — or are you recalling the
   > plan / what it was trying to do?"**

   Capture `read` | `intent-only`. `intent-only` is not a pass; offer to walk the diff now.
3. Then Willison's gate verbatim:
   > **"Do you understand this commit well enough that you could explain exactly what it does
   > to somebody else?"**
4. Wait. Capture `understood` | `partial` | `not-really`, paired with the read state.
   `understood` on `intent-only` collapses to `partial` — you can't explain what code _does_
   if you haven't read it, only what it was _for_.
5. If not a clean `read` + `understood`, ask:
   > **"What specifically isn't clear — or want to walk the diff now?"**

   Capture verbatim. Move on when Emily signals ready. Don't propose anything yet.

### Phase 2 — Guardrail-fire audit (per-commit, structured)

For each commit with review signal, walk Emily through:

1. Surface the findings (from signal-review output and/or codex).
2. For each finding, ask:
   > **"Did you act on it, overrule it, or not see it until now?"**

   Capture three buckets per commit:
   - **acted** — fixed in code.
   - **overruled** — flagged, Emily decided not-a-real-issue. Capture WHY in one sentence.
   - **missed-by-me** — Emily didn't see it at review time (discoverability issue, not a
     guardrail-quality issue).
3. Then the gap-direction question (the most valuable signal of the retro):
   > **"What did the guardrails miss this week — bad patterns you wish swift-signal-review or
   > the gates had caught?"**

   Capture each as: pattern, location (`file:line`), severity Emily assigns, and whether it
   maps to an existing `SWIFT_PATTERNS.md` entry or is new.

### Phase 3 — Pattern surfacing (you-driven, one delta at a time)

Aggregate across the week, then surface each proposed delta one at a time. Every delta is
implemented by **calling `harden-guardrail`** (it adds/updates the catalog entry, picks the
enforcement rung, prompts before any `AGENTS.md` edit, and keeps `AGENTS.md` < 200 lines):

- **`overruled` ≥3× for the same catalog entry** → propose softening it (tighten the "Bad"
  definition, or relax an over-eager gate). Route through `harden-guardrail`.
- **`missed-by-guardrails` pattern that recurs (≥2 occurrences)** → propose a NEW catalog
  entry (Bad / Why it spreads / Good / Caught by / Sweep-able) and the strongest enforcement
  that fits — a test or lint/precheck gate beats an `AGENTS.md` rule. Route through
  `harden-guardrail`; let it ask you the test/CI enforcement question.
- **Same gate caught a similar issue 3+ times in `acted`** → no change; the rule is working.
  Note as a healthy signal — keep it prominent.

Ask per delta:
> **"Harden this one? (harden-guardrail will propose the gate and confirm the wording.)"**

On no: capture as `proposed-and-rejected` with reasoning.

### Phase 4 — Research commission (Emily-driven, optional)

Ask:
> **"Any missed pattern deep enough to warrant a research pass? If so, what's the question?"**

For each commission: spawn a `researcher` Agent in the background with a self-contained prompt
(the pattern, Stower `file:line` anchors, and which catalog entry / gate it should feed). Tell
Emily the agent ID and ETA (~5–15 min). The write-up lands in `tmp/research/<topic>-cited.md`.
Continue Phase 5 while it cooks.

### Phase 5 — Decision log

Write the retro artifact to `tmp/retros/<YYYY-MM-DD>-retro.md` (all of `tmp/` is gitignored
local scratch; if you want retros tracked as history, archive them to a history repo or make
it a convention change routed through `harden-guardrail` — don't decide it here):

```markdown
# Saturday retro — <YYYY-MM-DD>

## Window
<git log range>

## Working set
- N commits walked (list)
- Review signal per commit (signal-review / codex / none)
- Coverage gap closed: yes/no (and how)

## Per-commit understanding
- <sha> <subject>: read|intent-only + understood|partial|not-really
  - Notes: ... (intent-only caps understanding at partial)

## Guardrail audit roll-up
- swift-signal-review (judgment patterns): X acted, Y overruled, Z missed-by-me, W missed-by-guardrails
- mechanical gates (swift-format / swiftlint / precheck / CI): caught ..., escaped ...

## Deltas hardened (via harden-guardrail; ≥2-commit provenance for new rules)
- SWIFT_PATTERNS.md #NN added/softened ... (provenance: <sha>, <sha>) — enforcement: <gate|test|AGENTS.md rule>

## Auxiliary signals
- reverts: ... | new swiftlint:disable: ... | dep changes: ... | PLAN.md misses: ...

## Research commissions spawned
- <agent-id>: <topic>, ETA <minutes>

## Items punted
- proposed-and-rejected: ...
- flagged-for-next-week: ...

## Emily's qualitative input
<verbatim answer to "what felt off this week that nothing else captured?">
```

End the conversation with: the retro file path, a one-line summary of what's queued, and any
research-commission ETAs.

### Phase 6 — Cleanup hour (post-retro, time-boxed)

The retro's pattern-issues are **pollution, not breakage** — mechanical bad code, not logic.
Clear them in one bounded pass so they don't compound across future AI passes. **Target ~1
hour total, ~20 min per pattern.** The time-box is the point.

Per pattern-issue:

1. Check the catalog entry's **Sweep-able** flag.
   - `Sweep-able: yes` → run `swift-pattern-sweep` (it reads every file, fuzzy-matches, asks
     when unsure) to kill every instance in one approach.
   - `Sweep-able: no` (judgment/process/architectural) → fix the sites by hand; do not sweep.
2. Run `./Scripts/precheck.sh` — it must pass.
3. **Skim** the diff yourself — does it read reasonable? The human gate is a skim (no logic
   change), not a deep review.
4. Approve and commit as a pure structural change (one pattern per commit, no
   `--no-verify`).

If a pattern can't be fixed mechanically in ~20 min, it has hidden logic or scope — kick it to
a real plan, don't force it into the hour. The catalog entry + gate landed in Phase 3 keeps the
pattern from re-accruing once cleared.

## Cross-references

- `swift-signal-review`: `.claude/skills/swift-signal-review/SKILL.md` — the per-diff review whose findings feed this retro
- `swift-pattern-sweep`: `.claude/skills/swift-pattern-sweep/SKILL.md` — the cleanup-hour tool
- `harden-guardrail`: `.claude/skills/harden-guardrail/SKILL.md` — how every retro delta lands
- Pattern catalog: `.claude/skills/SWIFT_PATTERNS.md` (single source of truth)
- Canonical rules: `AGENTS.md`; the gate: `Scripts/precheck.sh`; headless review: `Scripts/signal-review.sh`
- Signal-coding framing: Emily's blog "Signal code, not vibe code"; cited research at `~/Documents/Projects/me/Research/signal-coding-swift-ai-guardrails-cited.md`
- The /office-hours pattern this mirrors: gstack `/office-hours`
