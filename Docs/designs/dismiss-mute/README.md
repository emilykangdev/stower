# Dismiss / Mute — approved design references

Committed visual + textual references for the board-triage feature (dismiss a message,
mute a contact). These are the **approved** directions only — rejected variants are not
copied here. Source briefs:
`tmp/briefs/2026-06-18-stowermac-dismiss-mute.md` and the ready plan
`tmp/ready-plans/2026-06-25-stowermac-dismiss-mute.md`. The implementer should read this
file (text) alongside the PNGs (visual) — the text is the greppable, durable spec; the
PNGs are the look reference.

## 1. `muted-senders-toolbar-popover.png` — mute management (variant A, approved)

A low-salience **`Muted Senders…` bell control** at the right of the window toolbar (a new
`ToolbarItem` in the existing NavigationStack `.toolbar`; there is no NSToolbar). Clicking it
opens a small **anchored popover** listing each muted sender as a soft duotone monogram + name
(or phone number) + a quiet inline **Unmute** button.

- **No count chip** anywhere on the board — the count, if shown at all, lives only inside the
  popover/menu label, never as a board badge (an exclusion list should not pull attention).
- The control is **hidden entirely when zero contacts are muted**.
- Popover rows sorted **alphabetically by resolved name** (fallback: handle); the popover
  **stays open across unmutes** and closes on outside click.
- Chosen over variant B (`•••` menu → centered modal sheet — too heavy for unmuting one
  person) and variant C (a `Muted` pill on the tab row — reads as a 4th tab). Aesthetic stays
  in the calm "Etude" family: humanist, soft, not bold.

## 2. `muted-senders-zero-state.png` — the conditional repair line (variant D, approved)

The empty **"You're all caught up."** state with one quiet secondary line beneath it:
**"Muted senders are hidden from this board. Manage…"** where **Manage…** opens the same
popover. This line appears **only** when a lens is empty AND at least one sender is muted —
it is the one place a visible muted state earns its keep (it explains an otherwise confusing
empty board). Attaches to the **per-lens `StowerBoardNotice`**, not the global caught-up
screen, so the all-muted case never falsely claims "all caught up."

## 3. `batch-dismiss-select-mode.png` — manual batch dismiss (hybrid D, approved)

The **Apple Mail "Edit" model**. The list is clean at rest (no checkboxes). A header
**Select** control enters Select mode → checkboxes appear on every row of the current lens →
the user selects via click + select-all + shift-click range → a single **Dismiss N** applies
the whole set with one reflow → back to the clean list. (Prefer SwiftUI `List(selection:)`
for free, accessible multi-select.) The orange "N look like ones you usually dismiss" banner
and pre-checked rows shown in the mockup are the **PAR-32 ML auto-select layer — deferred**;
v1 ships the same Select mode with empty checkboxes the user ticks manually.

## Undo (applies to single + batch, not pictured)

Dismiss shows a quiet **draining-line undo bar** ("Dismissed · Undo", ~3s single / ~5s batch,
pause on hover or keyboard focus, then gone) backed by an app-owned `UndoManager` ⌘Z for the
session. No persistent undo button and **no dismiss-history screen** — the ephemerality is
deliberate (protects decision closure). See the plan's JC3 and the cited research at
`~/Documents/Projects/me/Research/toasts-desktop-placement-and-closure-cited.md`.
