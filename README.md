# claude-session-restore

Save and restore a WezTerm window full of Claude Code panes. Quit WezTerm, run one
command later, and every tab and pane split comes back resumed to the session it was
running. Windows-only (PowerShell 5.1 / 7 + WezTerm + Claude Code).

## How it works

`Save-ClaudeSession` reads `wezterm cli list`, figures out which Claude session each
pane is running, and writes `~/.claude/sessions.json`. It resolves the session in 3 tiers:

1. The SessionStart pane-map (`~/.claude/pane-map/<pane-id>.session`), an exact mapping
   written by the `hooks/Update-PaneMap.ps1` hook. Trusted across directories, but ignored
   if the file predates the current WezTerm process (WezTerm reuses pane IDs).
2. A title-slug match in the pane's project dir.
3. The most-recent unassigned session in that dir.

A pane it can't pin to a session is marked `fresh` (open a bare `claude`) rather than
`--continue`, which would silently load an unrelated newest session.

`Restore-ClaudeSession` (alias `claude-restore`) reads the manifest and spawns each
tab/pane through `wezterm cli`. Each pane sets an env var, sources the PowerShell profile,
and the profile's auto-launch block runs `claude --resume <id>`, `claude --continue`, or
bare `claude`.

## Layout

| Path | Purpose |
|------|---------|
| `src/ClaudeSessionRestore.psm1` | the module: `Save-ClaudeSession`, `Restore-ClaudeSession`, `Get-ClaudeSession` (+ aliases `claude-save`, `claude-restore`) |
| `hooks/Update-PaneMap.ps1` | SessionStart hook: records pane -> session, prunes stale maps |
| `install/Install.ps1` | registers/removes the `ClaudeCode-AutoSave-WezTerm` task |
| `install/Uninstall.ps1` | removes the task, hook, this repo, and the manifest |
| `install/Save-ClaudeAuto.ps1` | scheduled wrapper that saves every 5 min |
| `install/Run-SaveClaudeAuto.vbs` | launches the wrapper hidden, so no window flashes |
| `docs/Watch-ConsoleSpawns.ps1` | debug helper for the console-window-flash issue |

The scripts self-locate (`$PSScriptRoot`), so you can clone this repo anywhere.

## Install

1. Clone anywhere, then import the module from your PowerShell profile
   (`$PROFILE`). Add:

   ```powershell
   $ClaudeSessionRestoreModule = "<path-to-clone>\src\ClaudeSessionRestore.psm1"
   if (Test-Path $ClaudeSessionRestoreModule) { Import-Module $ClaudeSessionRestoreModule }
   ```

2. Add the auto-launch block to your **Windows PowerShell 5.1** profile
   (`~/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1`) — restore spawns
   `powershell.exe` (5.1), which is what reads this:

   ```powershell
   if ($env:CLAUDE_RESTORE_NAME) {
       claude --resume $env:CLAUDE_RESTORE_NAME
   } elseif ($env:CLAUDE_RESTORE_CONTINUE -eq "1") {
       claude --continue
   }
   ```

3. Register the SessionStart hook in `~/.claude/settings.json` so pane->session
   mappings are recorded:

   ```json
   {
     "hooks": {
       "SessionStart": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"<path-to-clone>\\hooks\\Update-PaneMap.ps1\""
             }
           ]
         }
       ]
     }
   }
   ```

4. (Optional) Enable the 5-minute auto-save:

   ```powershell
   <path-to-clone>\install\Install.ps1
   ```

## Data lives elsewhere

The scripts read and write under `~/.claude/`, not in the repo:

- `~/.claude/sessions.json` (the manifest)
- `~/.claude/pane-map/` (per-pane session pointers)
- `~/.claude/projects/` (Claude's own session jsonls)
- `~/.claude/backups/*.log`

Moving this repo doesn't change those paths.

## Commands

```powershell
claude-restore                        # restore the 'default' profile
claude-save                           # save the current WezTerm window
Restore-ClaudeSession -ListProfiles   # list saved profiles
Restore-ClaudeSession -DryRun         # print the wezterm commands without spawning
Get-ClaudeSession                     # list resumable sessions for the current dir
install\Install.ps1                   # register the 5-min auto-save task
install\Install.ps1 -Uninstall        # remove just the task
```

## Uninstall

```powershell
install\Uninstall.ps1                 # restores your profile backup, removes task/hook/repo
```
