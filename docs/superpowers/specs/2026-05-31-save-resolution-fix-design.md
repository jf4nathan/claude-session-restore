# Design: faithful Save resolution (fix the cwd-collapse / duplicate-session defect)

**Date:** 2026-05-31
**Status:** approved (pending spec review)
**Affects:** `src/ClaudeSessionRestore.psm1` (`Save-ClaudeSession` only). Restore is unchanged.

## Problem (root cause, verified)

`Save-ClaudeSession` resolves each WezTerm pane to a session via three tiers:
1. pane-map (`~/.claude/pane-map/<pane-id>.session`, written by the SessionStart hook),
2. title-slug match in the pane's cwd,
3. most-recent unassigned session in the pane's cwd.

Tier-1 resolution runs `Get-SessionHome`, which locates the mapped session's
`<uuid>.jsonl` and reads its launch cwd. **If the mapped session has no jsonl
yet** — an *empty startup session* (bare `claude` auto-launched in a pane, never
interacted with, so nothing was persisted) — `Get-SessionHome` returns `$null`,
tier-1 silently fails, and the pane falls through to tier-2/3 **cwd-guessing**.

When several such panes share a cwd that contains exactly one real session, they
all collapse onto it. Worse, tier-1 honors its own mapped session regardless of
what tier-3 already grabbed, so the **same session UUID is assigned to multiple
panes** (`DUP`). On Restore this spawns several panes in that directory, multiple
resuming the same session — sessions the user never opened. Because the manifest
is then re-saved and re-restored (with the profile's auto-launch re-running
`claude`), it becomes a self-sustaining loop that accretes panes each cycle.

**Observed instance:** three live panes with cwd `…\plugins\fathom-mcp`; one
pane-mapped to a real 11-day-old session (`a78fdc9f`), two pane-mapped to
jsonl-less startup sessions (`920fe7e4`, `0e0fec5e`). The manifest recorded
`a78fdc9f` as a **duplicate resume** plus a stray `fresh` fathom pane. This is a
pre-existing logic defect — the reorg consolidation preserved the resolution
functions byte-for-byte; the reboot merely created the empty startup sessions
that triggered it.

## Scope

Fix Save so it captures only what is truly on screen (no duplicate resumes, no
collapse onto an unrelated session), plus a one-time manifest reset to break the
current stuck loop. **Out of scope (YAGNI):** stale-session heuristics
(age/generation-based rejection), changes to Restore, changes to the SessionStart
hook, Pester or any new dependency.

## Section 1 — Testability refactor (no behavior change)

Extract the pane→entry resolution from `Save-ClaudeSession` into a new
module-private function:

```
Resolve-PaneEntries -WindowPanes <object[]> -MuxOrigin <datetime?> `
                    -ClaudeRoot <string = "$HOME\.claude"> -> $tabs
```

- The existing nested helpers (`Get-CwdSessions`, `Get-SessionHome`,
  `Use-CwdSession`, and the pane-map read currently inside `Use-PaneMappedSession`)
  move into `Resolve-PaneEntries` and read under `$ClaudeRoot` —
  `Join-Path $ClaudeRoot 'projects'` and `Join-Path $ClaudeRoot 'pane-map'` —
  instead of hard-coding `"$HOME\.claude\…"`.
- `Save-ClaudeSession` keeps all WezTerm I/O (`wezterm cli list`, window
  selection, `$muxOrigin` computation) and the manifest read/merge/write, then
  delegates the tab/pane construction to `Resolve-PaneEntries`.
- The `$cwdSessions` cache stays local to `Resolve-PaneEntries`.
- All resolution logic (slug regex `[^a-zA-Z0-9]`, glyph-title stripping, file://
  cwd parsing, split-direction inference, mux-origin staleness rule) is preserved
  exactly. Only the Section-2 guards change behavior.
- **Export guard:** wrap the module's `Export-ModuleMember` line in
  `if ($MyInvocation.MyCommand.ScriptBlock.Module) { … }` so the file can be
  dot-sourced by the test without throwing "Export-ModuleMember can only be
  called from inside a module." Import-Module behavior is unchanged.

Result: `Resolve-PaneEntries` is pure (filesystem-only under an injectable root,
no WezTerm calls, no manifest write) and unit-testable with fixtures.

## Section 2 — The two guards (the fix)

Inside `Resolve-PaneEntries`:

**Guard 1 — reserve pane-mapped sessions.** A pre-pass over *all* `WindowPanes`
reads each pane's pane-map id (applying the existing `$MuxOrigin` staleness rule —
stale maps are ignored and NOT reserved) and collects the set of claimed UUIDs
into `$reserved`. Tier-2/3 then excludes any candidate whose `SessionId` is in
`$reserved`:
- `Use-CwdSession` skips reserved candidates when picking.
- The `continue` fallback computes `$remaining` as the cwd's sessions **minus**
  `$reserved`; if empty → `fresh`.

This is localized to the tier-2/3 decision points; `Get-CwdSessions` still returns
the full list and tier-1 consumption is unchanged (reservation is the backstop
that holds even if cwd-string cache keys differ).

**Guard 2 — unresolvable pane-map → `fresh`.** Split the current
`Use-PaneMappedSession` into:
- `Get-PaneMappedId -PaneId -MuxOrigin -ClaudeRoot` → returns the mapped UUID
  (respecting staleness) or `$null`; no resolution, no consumption.
- resolution in the main loop:

```
if ($mappedId) {
    $sess = Get-SessionHome -SessionId $mappedId
    if ($sess) {
        # tier-1 resolved: resume; resumeCwd = $sess.Cwd; consume from home cwd list (as today)
    } else {
        # mapped but no jsonl (empty startup session): mark this pane FRESH, do NOT cwd-guess
    }
} elseif ($cwd -and -not $looksLikeShell) {
    # tier-2/3 guess, excluding $reserved
}
```

**Edge cases (all covered):**
- Pane with no pane-map (hook never fired), not a shell, has cwd → tier-2/3 as
  today, minus reserved.
- Pane with a *stale* map → ignored and not reserved (existing behavior).
- Shell pane (`*.exe` / `<untitled>` title) → `fresh` (existing behavior, unchanged).
- `continue` would have collapsed onto a reserved session → now `fresh`.

## Section 3 — Tests, reset, verification

**Test:** `tests/Resolve-PaneEntries.Tests.ps1` — plain PowerShell, no framework.
It dot-sources `src/ClaudeSessionRestore.psm1` (permitted by the Export guard),
builds a temp `ClaudeRoot` fixture with **fully synthetic** data (fake UUIDs, fake
paths — no real session content), and asserts behavior. Fixture reproduces the
bug:
- `projects/C--fix-fathom/<UUID_REAL>.jsonl` containing a line
  `{"cwd":"C:\\fix\\fathom", …}` (one real session).
- `pane-map/2.session` → `UUID_REAL` (valid).
- `pane-map/3.session` → `UUID_EMPTY_A` (no jsonl anywhere).
- `pane-map/4.session` → `UUID_EMPTY_B` (no jsonl anywhere).
- `WindowPanes`: three panes (ids 2,3,4), all `cwd = file:///C:/fix/fathom/`,
  non-shell titles, same tab.
- `MuxOrigin = (Get-Date).AddMinutes(-5)` so the freshly-written map files are
  not stale.

Assertions:
1. **Fix (green):** exactly one entry resumes `UUID_REAL`; the two empty-session
   panes are `fresh`; **no duplicate resume id** across entries.
2. **Control:** a separate fixture with three panes validly mapped to three
   distinct real sessions still resumes all three correctly (no regression).
3. The test is written to **fail against the current code** (which produces the
   duplicate) and **pass after** the guards — the red→green sequencing is the
   plan's job.

Test runner: `pwsh -File tests/Resolve-PaneEntries.Tests.ps1` exits non-zero on
any failed assertion, prints a one-line PASS/FAIL summary per case.

**One-time reset (operational, independent of the code change):** in the live
WezTerm, close the spurious fathom-mcp panes, then run `claude-save` to overwrite
the `default` profile with the true on-screen state. Breaks the current loop
immediately; can be done before or after the code fix.

**Verification after the code fix:**
1. `pwsh -File tests/Resolve-PaneEntries.Tests.ps1` → all PASS.
2. `Import-Module src/ClaudeSessionRestore.psm1 -Force` still exports exactly
   `Save-ClaudeSession`, `Restore-ClaudeSession`, `Get-ClaudeSession`,
   `claude-save`, `claude-restore` (refactor didn't change the public surface).
3. After the reset, `Restore-ClaudeSession -DryRun` shows no duplicate resume IDs
   and no fathom-mcp panes.

## Files

- Modify: `src/ClaudeSessionRestore.psm1` (extract `Resolve-PaneEntries`, add
  `Get-PaneMappedId`, the two guards, the Export guard).
- Create: `tests/Resolve-PaneEntries.Tests.ps1`.
- (Optional) note the fix in the README/docs if warranted — decide during the plan.

## Out of scope (YAGNI)

- Stale/age-based session rejection (the deferred option-2/3 from brainstorming).
- Restore-side changes.
- SessionStart hook changes.
- Pester / any new dependency.
