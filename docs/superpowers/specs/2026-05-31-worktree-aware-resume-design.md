# Worktree-aware session resume — design

**Date:** 2026-05-31
**Status:** approved (design)
**Topic:** Restore a Claude session that was last working in a git worktree so the user knows it, and is offered a one-step way back into the worktree.

## Problem

When a session is started in the repo root and then enters a git worktree mid-session
(via `EnterWorktree` / `cd` into `.worktrees\<name>`), resuming it lands the user back in
the **root**, not the worktree. The user often does not even know the session had been in a
worktree, and their current workaround is to remember to run `/switch-worktree` by hand.

### Why we cannot just spawn in the worktree

Claude Code's `--resume <id>` is **cwd-bound** (upstream issue #5768, confirmed live on this
Windows build 2026-05-31): it only finds a session when launched from the cwd whose
project-folder hash matches where the session is indexed. A session that started in the root
is indexed under the **root** project folder, regardless of where it later worked. Probe
evidence:

- `claude --resume <root-indexed-id>` from an unrelated cwd → `No conversation found`.
- Same id from the root folder → session found, resumes (control passed).

Related upstream issues:

- #5768 — resume only works from the directory the session started in (open, PR #39148).
- #28769 — `--resume` loses context when `--worktree` was used (closed).
- #30906 — worktree cwd not restored on resume (closed as duplicate of #5768).

Net: claude must launch from **root** to find the session, and it does not re-enter the
worktree on its own. So the worktree re-entry has to happen **inside** the resumed session
(claude offering `/switch-worktree`), never by `cd`-ing the shell before launch (which would
break `--resume`).

### Two worktree cases (only one needs new work)

1. **Started inside the worktree** (`cd worktree && claude`): the session is indexed under a
   worktree-derived project folder; first cwd == last cwd == worktree. `--resume` already
   works from the worktree and the existing tool already records `cwd` = worktree. **No change
   needed** — this case self-excludes from detection below.
2. **Started in root, entered worktree mid-session** (the broken case): indexed under root;
   jsonl first cwd = root, last cwd = worktree. This is the case this feature addresses.

## Goal / success criterion

On restore of a case-2 session: claude resumes reliably **from root** (so `--resume` finds it),
then **automatically re-enters the worktree on its first turn** via the `switch-worktree` skill —
no manual step. We do not change resume/findability behavior.

**Revision (2026-06-01):** the original design printed an in-pane banner + had the hook *offer*
`/switch-worktree`. Live testing showed (a) the pre-launch banner is wiped when Claude's TUI clears
the screen, so it only flashes; (b) a SessionStart offer is latent — Claude holds it in context but
neither speaks nor acts until the user's first message, and even then only *offered*. So the user's
restored pane sat in the root with nothing visible. Changed to: **no banner**, and the hook directs
Claude to re-enter the worktree **automatically as its first action, without asking**.

**Revision 2 (2026-06-01) — zero-touch:** to remove even the one-message latency, Restore also injects
a positional first prompt. For a worktree pane it sets `CLAUDE_RESTORE_PROMPT='/switch-worktree'`; the
profile auto-launch block passes it as the resumed session's positional prompt
(`claude --resume <id> /switch-worktree`), so Claude invokes the skill on resume with no user input.
A positional `/switch-worktree` is honored as a skill invocation (verified). The hook's
`additionalContext` still fires — it names the exact target worktree path (disambiguating which
worktree) and is the fallback if the profile doesn't consume `CLAUDE_RESTORE_PROMPT`.

**Profile dependency:** the prompt-injection half lives in the PowerShell 5.1 profile auto-launch
block (`Microsoft.PowerShell_profile.ps1`); the block reads `CLAUDE_RESTORE_PROMPT` and appends it to
the `claude --resume` call. `install/Install.ps1` now manages this block idempotently between sentinel
markers (`Install-ClaudeProfileBlock` + the pure `Merge-ProfileBlock`), so it survives reinstalls; a
legacy *unmarked* block is left untouched with a warning (to avoid a double-launch). Cost: a synthetic
`/switch-worktree` first turn in each restored worktree session's history, and one eager API turn per
worktree pane on restore.

## Approach (selected: A — Save detects → manifest field → Restore marker → hook auto-switches)

Detection lives where the code already reads session jsonl (Save). The manifest carries a
durable record. Restore writes a one-shot marker (no banner). The existing
SessionStart hook turns the marker into an in-session offer. The banner still works even if the
hook half is disabled.

## Components

### 1. Detection (Save side, `src/ClaudeSessionRestore.psm1`)

- Extend `Get-SessionHome` to return both `Cwd` (first cwd — home/index) and `LastCwd` (last
  cwd in the jsonl). Today it returns only the first.
- Add `Test-IsWorktree -Path`:
  - authoritative: `git -C <path> rev-parse --git-common-dir` resolves to a path different from
    `git -C <path> rev-parse --git-dir` (true only for a linked worktree; equal for the main
    working tree);
  - fallback when git is unavailable: path contains `\.worktrees\`;
  - returns false for non-git paths.
- A session is **worktree-resumed** iff: `LastCwd -ne Cwd` **and** `Test-IsWorktree(LastCwd)`
  **and** `LastCwd` exists on disk.
- When true, the resolved pane entry keeps `cwd` = home/root (so `--resume` finds the session)
  and gains `worktree` = `LastCwd`.

### 2. Manifest schema

Add an optional per-pane field `worktree: <LastCwd>`. `cwd` is unchanged (root). The field is
absent for non-worktree panes. Backward-compatible: an older restore ignores unknown fields.

### 3. Restore side (`src/ClaudeSessionRestore.psm1`)

For a `resume`-mode pane that has `worktree` (skip for fresh/continue):

- Spawn cwd unchanged (root / `cleanCwd`).
- **One-shot marker:** write `~/.claude/worktree-restore/<session-id>` (the `resume` id) containing
  the worktree path. No banner (the 2026-06-01 revision removed it — see Goal).
- **Re-check at restore time:** if `worktree` no longer exists on disk (pruned since save), write
  **no** marker (nothing to switch into; Claude just resumes in root).
- **`-DryRun`:** write no marker.
- **Hygiene:** prune marker files older than 24h when writing a new one.

### 4. Hook side (`hooks/Update-PaneMap.ps1`)

The marker check runs **independent of `WEZTERM_PANE`** (it concerns the session, not the pane),
after parsing `session_id`; the pane-map write stays gated on `WEZTERM_PANE`. The marker dir is
`~/.claude/worktree-restore`, with a `CLAUDE_WORKTREE_MARKER_DIR` override scoped to **that dir
only** — never the pane-map or log paths, so a stray env var can't relocate the pane-map and break
Save resolution. (Used by tests; `$HOME` does not relocate via env on Windows pwsh.)

Check `~/.claude/worktree-restore/<session_id>`:

- if present: emit `hookSpecificOutput.additionalContext` (instead of the bare `{}`) stating
  the session last worked in worktree `<path>`, that the terminal launched from root so
  `--resume` could find the session, and that claude's **first action must be to re-enter that
  worktree via the `switch-worktree` skill — automatically, before responding, without asking**;
  then **delete the marker** (one-shot);
- if absent: unchanged `{}` output.

Marker presence is the sole gate, so the hook never misfires on normal/unrelated sessions. All
paths stay best-effort and silent on error, matching the existing hook.

## Data flow

```
Save:    panes -> Resolve-PaneEntries -> Get-SessionHome (first+last cwd) -> Test-IsWorktree -> manifest.pane.worktree
Restore: manifest.pane.worktree -> spawn pwsh [banner + write marker], cwd=root -> claude --resume
Hook:    SessionStart(resume) -> marker exists? -> additionalContext (offer /switch-worktree) -> delete marker
```

## Error handling

- jsonl unreadable or single cwd → no `worktree` field (current behavior preserved).
- git missing → fall back to the `\.worktrees\` path heuristic; neither → treat as not-a-worktree.
- worktree pruned by restore time → degraded banner, no marker, no auto-offer.
- hook marker read/parse failure → fall back to `{}`.
- marker collision impossible: keyed by unique session_id, deleted one-shot.

## Testing (plain pwsh, no Pester; extends `tests/`)

- `Test-IsWorktree`: temp git repo + `git worktree add` → true; main repo path → false; non-git
  path → false.
- `Get-SessionHome`: synthetic 2-cwd jsonl → distinct first/last; 1-cwd jsonl → equal.
- `Resolve-PaneEntries`: pane mapped to a session whose last cwd is a worktree → entry has
  `worktree` set and `cwd` = home; started-in-worktree session (first == last) → no `worktree`
  field.
- Hook: event JSON with an existing marker → output contains `additionalContext` and the marker
  is deleted; no marker → `{}`.
- Restore: dry-run asserts the banner and marker write; optional live smoke with a throwaway
  worktree.

## Scope guard (YAGNI)

- Only the started-in-root-then-entered-worktree case is new work.
- We offer `/switch-worktree`; we do not auto-run it.
- We do not alter `--resume` findability or attempt to make claude resume directly into the
  worktree (that depends on upstream #5768 / PR #39148).
