# Design: public-ready reorganization of `claude-session-restore`

**Date:** 2026-05-30
**Status:** approved (pending spec review)

## Goal

Reorganize the repo (folders, file names, gitignore, docs) so it is clean and
adaptable by anyone who clones it to any location — without breaking the
author's already-wired live setup. The repo is now public.

## Core problem

The install location `~/Desktop/Cursor Projects/claude-session-restore` is
hardcoded in 5 places, so a clone anywhere else breaks:

- `Install-ClaudeAutoSave.ps1` (VBS path + scheduled-task argument)
- `Run-SaveClaudeAuto.vbs` (path to `Save-ClaudeAuto.ps1`)
- `Save-ClaudeAuto.ps1` (dot-source of `Save-ClaudeSessions.ps1`)
- `Uninstall-ClaudeRestore.ps1` (`$binDir`)
- `Watch-ConsoleSpawns.ps1` (self-path in usage comment)

Decision: **self-location via `$PSScriptRoot`** (no env var, no runtime config
file). Each script resolves its siblings relative to itself. The one place that
cannot use `$PSScriptRoot` at run time — the Windows scheduled task — gets the
resolved absolute path written into it at install time.

## Target structure

```
claude-session-restore/
├─ README.md            # rewritten: clone-anywhere quickstart + prerequisites
├─ LICENSE              # NEW — MIT
├─ .gitignore           # keep runtime-data guards; add PS module cruft
├─ src/
│  └─ ClaudeSessionRestore.psm1   # consolidates Save + Restore + Get
├─ hooks/
│  └─ Update-PaneMap.ps1          # SessionStart hook (invoked by absolute path)
├─ install/
│  ├─ Install.ps1                 # was Install-ClaudeAutoSave.ps1
│  ├─ Uninstall.ps1               # was Uninstall-ClaudeRestore.ps1
│  ├─ Save-ClaudeAuto.ps1         # scheduled wrapper
│  └─ Run-SaveClaudeAuto.vbs      # hidden launcher
└─ docs/
   ├─ ROLLBACK.md
   └─ Watch-ConsoleSpawns.ps1     # debug helper
```

Install/Uninstall keep short names; their folder supplies the context.

## Module consolidation

The three core scripts merge into `src/ClaudeSessionRestore.psm1`, which
`Export-ModuleMember`s the renamed commands plus back-compat aliases. The module
operates entirely on `~/.claude/` and therefore needs no knowledge of its own
install path.

| Old command | New command | Alias shipped |
|---|---|---|
| `Save-Claude` | `Save-ClaudeSession` | `claude-save` |
| `Restore-Claude` | `Restore-ClaudeSession` | `claude-restore` |
| `Get-ClaudeSessions` | `Get-ClaudeSession` | (none) |

Only the two short convenience aliases ship. The old PascalCase names
(`Save-Claude`, `Restore-Claude`, `Get-ClaudeSessions`) are **dropped entirely** —
they were author-only back-compat and would be clutter in a public command
surface. Trade-off: any of the author's own scripts/habits that call the old
names will break and must move to the new names or `claude-save`/`claude-restore`.

Parameter surfaces are unchanged (`-Profile`, `-ManifestPath`, `-ListProfiles`,
`-DryRun`, etc.).

## Self-location mechanics

- `src/ClaudeSessionRestore.psm1` — no path knowledge needed.
- `install/Save-ClaudeAuto.ps1` — `Import-Module (Join-Path $PSScriptRoot '..\src\ClaudeSessionRestore.psm1')`, then call `Save-ClaudeSession`.
- `install/Run-SaveClaudeAuto.vbs` — resolve `Save-ClaudeAuto.ps1` as a sibling via `WScript.ScriptFullName` → parent folder (no `%USERPROFILE%` literal).
- `install/Install.ps1` — locate the VBS via `$PSScriptRoot`; resolve to an absolute path; register `ClaudeCode-AutoSave-WezTerm` with that absolute path as the `wscript.exe` argument. Re-running re-resolves and re-registers (idempotent), so moving the clone + re-running fixes the task.
- `install/Uninstall.ps1` — derive the repo dir from `$PSScriptRoot` (`Split-Path $PSScriptRoot -Parent`) instead of the hardcoded Desktop path.
- `docs/Watch-ConsoleSpawns.ps1` — update usage-comment path to `$PSScriptRoot`-relative.

## Re-wiring the author's live setup

Each external file is backed up to `~/.claude/backups/` (timestamped) before edit.

1. **PowerShell profiles** (`Documents\PowerShell\...profile.ps1` and
   `Documents\WindowsPowerShell\...profile.ps1`): replace the three dot-source
   lines with a single `Import-Module <repo>\src\ClaudeSessionRestore.psm1`.
   The `claude --resume` auto-launch block in the profile is **left untouched** —
   the profile is read first and edited surgically by matching only the
   dot-source lines.
2. **`~/.claude/settings.json`**: repoint the SessionStart hook command to
   `hooks/Update-PaneMap.ps1` (new absolute path).
3. **Scheduled task**: re-run `Install.ps1` so `ClaudeCode-AutoSave-WezTerm`
   points at the new `install/` path.

## Public polish

- **LICENSE**: MIT.
- **README**: rewritten — what it does, prerequisites (WezTerm, Claude Code,
  Windows 11, PowerShell 5.1+), clone-anywhere install (`Import-Module`,
  `Install.ps1`, settings.json hook snippet), command table with new names +
  aliases, "data lives under ~/.claude" note, uninstall.
- **.gitignore**: keep `sessions.json` / `pane-map/` / `*.log` guards and editor
  cruft; structure stays valid after the move (paths are filename-based).

## Verification ("without breaking anything")

After re-wiring:

1. `Import-Module <repo>\src\ClaudeSessionRestore.psm1 -Force` succeeds.
2. The new names + shipped aliases resolve: `Save-ClaudeSession`,
   `Restore-ClaudeSession`, `Get-ClaudeSession`, `claude-save`, `claude-restore`.
   The dropped names (`Save-Claude`, `Restore-Claude`, `Get-ClaudeSessions`)
   should NO LONGER resolve after the profile re-wire.
3. `Restore-ClaudeSession -DryRun` prints valid `wezterm cli` commands.
4. `Restore-ClaudeSession -ListProfiles` reads the existing manifest.
5. Re-registered scheduled task shows the new absolute VBS path
   (`schtasks /Query /TN ClaudeCode-AutoSave-WezTerm /V /FO LIST`).
6. A fresh PowerShell session loads the profile without error and the
   auto-launch block still fires.

## Out of scope (YAGNI)

- PSGallery publishing / `.psd1` manifest (Heavy option rejected).
- Cross-platform (macOS/Linux) support — Windows-only by design.
- CHANGELOG.md.
- Renaming the GitHub repo.
