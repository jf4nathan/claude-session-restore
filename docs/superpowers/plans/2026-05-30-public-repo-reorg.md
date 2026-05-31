# Public-Repo Reorganization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize `claude-session-restore` into a clean, clone-anywhere public repo (folders, a consolidated PowerShell module, renamed commands, MIT license, rewritten README) without breaking the author's already-wired live setup.

**Architecture:** Three core scripts merge into one self-contained module `src/ClaudeSessionRestore.psm1` that operates only on `~/.claude/` (no path knowledge needed). Install/auto-save/hook helpers locate their siblings via `$PSScriptRoot` (and, for the scheduled task, a path resolved to absolute at install time). Strategy is **copy-new → re-wire-live → delete-old**, so the live setup keeps working right up to the moment it is pointed at the new locations.

**Tech Stack:** PowerShell 5.1 + 7 (`.psm1`), VBScript launcher, Windows Task Scheduler, Claude Code SessionStart hook.

**Verification model:** This is infrastructure, not application code — there is no test framework in the repo and adding one (Pester) is out of scope. Each task ends with concrete verification commands and their expected output, then a commit. "Red/green" here means: run the command, confirm the expected output, then commit.

**Source of truth for code being moved:** The existing root files (`Save-ClaudeSessions.ps1`, `Restore-ClaudeSessions.ps1`, `Get-ClaudeSessions.ps1`, `Update-PaneMap.ps1`, etc.) are the canonical content. Where a task says "copy with edits," copy the *current* file content and apply the listed edits exactly. Originals are deleted only in Task 9, after live re-wiring.

**Rename map (applies throughout):**

| Old function | New function | Notes |
|---|---|---|
| `Save-Claude` | `Save-ClaudeSession` | alias `claude-save` |
| `Restore-Claude` | `Restore-ClaudeSession` | alias `claude-restore` |
| `Get-ClaudeSessions` | `Get-ClaudeSession` | no alias |
| `Test-SessionId` | `Test-SessionId` | unchanged; module-private (not exported) |

Old PascalCase names are **dropped** — no back-compat aliases for them.

**Author's live wiring (machine-specific, edited in Task 8):**
- PowerShell 7 profile: `~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1` lines 20-23 (comment + 3 dot-source lines). No auto-launch block here.
- Windows PowerShell 5.1 profile: `~/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1` lines 5-8 (comment + 3 dot-source lines). **Lines 10-18 contain the `claude --resume` auto-launch block — DO NOT TOUCH.**
- `~/.claude/settings.json`: SessionStart hook command references `...\claude-session-restore\Update-PaneMap.ps1`.
- Scheduled task `ClaudeCode-AutoSave-WezTerm` runs the root `Run-SaveClaudeAuto.vbs`.

**Repo root (author's clone):** `C:\Users\jonat\Desktop\Cursor Projects\claude-session-restore`. Run all `git` commands from there.

> **DO NOT run this plan in a git worktree.** Use a branch *in place* in the canonical clone above. Task 8 deliberately wires this clone's **absolute path** into state that outlives any worktree: the profile `Import-Module` line (Step 1/2) hardcodes the main-clone path, and the scheduled task (Step 5) is pinned to `$PWD\install\Run-SaveClaudeAuto.vbs`. In a worktree, `$PWD` ≠ the path written into the profile, and the task would point at a directory that gets auto-deleted on worktree cleanup — silently breaking auto-save. A branch in place gives clean repo-side rollback without that hazard.

---

## Task 1: Safety backups of live external files

**Files:**
- Create: `~/.claude/backups/reorg-<timestamp>/` (backups of both profiles, settings.json, sessions.json)

- [ ] **Step 1: Back up the two profiles, settings.json, and the manifest**

Run (PowerShell tool):

```powershell
$bak = Join-Path $HOME (".claude\backups\reorg-" + (Get-Date).ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $bak | Out-Null
$targets = @(
  "$HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1",
  "$HOME\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1",
  "$HOME\.claude\settings.json",
  "$HOME\.claude\sessions.json"
)
foreach ($t in $targets) { if (Test-Path -LiteralPath $t) { Copy-Item -LiteralPath $t -Destination $bak -Force } }
Get-ChildItem $bak | Select-Object Name, Length
```

Expected: lists `Microsoft.PowerShell_profile.ps1` (twice — note both land in the same folder; the second overwrites the first, so ALSO copy with a prefix below), `settings.json`, `sessions.json`.

- [ ] **Step 2: Fix the name collision (both profiles share a filename)**

Run:

```powershell
Copy-Item "$HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"        (Join-Path $bak "PowerShell7_profile.ps1") -Force
Copy-Item "$HOME\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1" (Join-Path $bak "WindowsPowerShell_profile.ps1") -Force
Get-ChildItem $bak | Select-Object Name
```

Expected: both `PowerShell7_profile.ps1` and `WindowsPowerShell_profile.ps1` present (plus settings.json, sessions.json). No commit (these live outside the repo).

---

## Task 2: Create folder skeleton, LICENSE, and .gitignore

**Files:**
- Create: `src/`, `hooks/`, `install/`, `docs/` (created implicitly by file writes)
- Create: `LICENSE`
- Modify: `.gitignore`

- [ ] **Step 1: Write LICENSE (MIT)**

Create `LICENSE`:

```
MIT License

Copyright (c) 2026 Jonathan Tang

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Replace `.gitignore`**

Overwrite `.gitignore` with:

```gitignore
# Editor / OS cruft
*.bak
*.bak.*
Thumbs.db
.DS_Store

# PowerShell module build/cruft (guard for public contributors)
*.psd1.bak

# This tool's runtime data lives under ~/.claude/, never in the repo.
# Listed here only as a guard in case anything is ever copied in by mistake.
sessions.json
pane-map/
*.log
```

- [ ] **Step 3: Commit**

```bash
git add LICENSE .gitignore
git commit -m "Add MIT license; tidy .gitignore for public repo"
```

---

## Task 3: Create the consolidated module `src/ClaudeSessionRestore.psm1`

**Files:**
- Create: `src/ClaudeSessionRestore.psm1`
- Source content from: `Save-ClaudeSessions.ps1`, `Restore-ClaudeSessions.ps1`, `Get-ClaudeSessions.ps1` (still at repo root — do not delete yet)

- [ ] **Step 1: Build the module file**

Create `src/ClaudeSessionRestore.psm1` with this exact structure:

1. A header comment block (below).
2. The full body of `Save-ClaudeSessions.ps1` **starting at its `function Save-Claude {` line** (omit that file's top file-level comment), with `function Save-Claude` renamed to `function Save-ClaudeSession`.
3. The full body of `Get-ClaudeSessions.ps1` starting at its `function Get-ClaudeSessions {` line, with `function Get-ClaudeSessions` renamed to `function Get-ClaudeSession`.
4. The full body of `Restore-ClaudeSessions.ps1` starting at its `function Restore-Claude {` line through the end of the `Test-SessionId` function, with `function Restore-Claude` renamed to `function Restore-ClaudeSession`. **Omit the trailing `Set-Alias claude-restore Restore-Claude` line** (re-added in the footer). `Test-SessionId` is included verbatim.
5. The footer (below).

Header to prepend:

```powershell
# ClaudeSessionRestore.psm1
# Save and restore a WezTerm window full of Claude Code panes.
# Exports: Save-ClaudeSession (claude-save), Restore-ClaudeSession (claude-restore),
#          Get-ClaudeSession. Operates entirely on ~/.claude/ — no install-path knowledge.
```

Footer to append (after all three functions + Test-SessionId):

```powershell
Set-Alias -Name claude-save    -Value Save-ClaudeSession
Set-Alias -Name claude-restore -Value Restore-ClaudeSession

Export-ModuleMember -Function Save-ClaudeSession, Restore-ClaudeSession, Get-ClaudeSession `
                    -Alias claude-save, claude-restore
```

No other edits to the function bodies — internal helper functions (`Get-CwdSessions`, `Use-CwdSession`, `Get-SessionHome`, `Use-PaneMappedSession`) are nested inside `Save-ClaudeSession` and need no changes. `Test-SessionId` stays module-private (not in the export list) but remains callable by `Restore-ClaudeSession` within module scope.

- [ ] **Step 2: Verify the module imports and exports exactly the right commands**

Run (PowerShell tool):

```powershell
$m = "$PWD\src\ClaudeSessionRestore.psm1"
Import-Module $m -Force
"--- exported ---"
Get-Command -Module ClaudeSessionRestore | Select-Object CommandType, Name | Sort-Object Name
"--- old names should be GONE (module side) ---"
'Save-Claude','Restore-Claude','Get-ClaudeSessions' | ForEach-Object {
  "{0}: {1}" -f $_, ((Get-Module ClaudeSessionRestore).ExportedCommands.ContainsKey($_))
}
```

Expected:
- Exported list contains exactly: `Function Get-ClaudeSession`, `Function Restore-ClaudeSession`, `Function Save-ClaudeSession`, `Alias claude-restore`, `Alias claude-save`.
- All three old names print `: False`.

- [ ] **Step 3: Verify -DryRun works through the module**

Run:

```powershell
Restore-ClaudeSession -DryRun
```

Expected: prints `DRY-RUN: spawn ...` / `split ...` lines and `wezterm.exe cli ...` commands for the saved `default` profile (reads the real manifest; spawns nothing). If the manifest has no `default` profile this prints a "Profile 'default' not found" error — acceptable; the point is the command resolves and runs.

- [ ] **Step 4: Commit**

```bash
git add src/ClaudeSessionRestore.psm1
git commit -m "Add consolidated ClaudeSessionRestore module with renamed commands"
```

---

## Task 4: Create `hooks/Update-PaneMap.ps1`

**Files:**
- Create: `hooks/Update-PaneMap.ps1` (verbatim copy of root `Update-PaneMap.ps1` — content needs no change; it only touches `~/.claude/`)

- [ ] **Step 1: Copy the hook into `hooks/`**

Create `hooks/Update-PaneMap.ps1` with the exact current content of the root `Update-PaneMap.ps1` (no edits — it has no self-path or sibling dependencies).

- [ ] **Step 2: Verify content is byte-identical to the original**

Run (PowerShell tool):

```powershell
(Get-FileHash hooks\Update-PaneMap.ps1).Hash -eq (Get-FileHash Update-PaneMap.ps1).Hash
```

Expected: `True`.

- [ ] **Step 3: Commit**

```bash
git add hooks/Update-PaneMap.ps1
git commit -m "Add SessionStart pane-map hook under hooks/"
```

---

## Task 5: Create `install/Save-ClaudeAuto.ps1` and `install/Run-SaveClaudeAuto.vbs` (self-locating)

**Files:**
- Create: `install/Save-ClaudeAuto.ps1`
- Create: `install/Run-SaveClaudeAuto.vbs`

- [ ] **Step 1: Write `install/Save-ClaudeAuto.ps1`**

Copy the current root `Save-ClaudeAuto.ps1` content, then replace the dot-source + call block (lines 46-53 of the original) with a module import + new command name. The new file:

```powershell
# Save-ClaudeAuto.ps1
# Invoked by the Windows scheduled task 'ClaudeCode-AutoSave-WezTerm'.
# Silently captures current WezTerm state every N minutes, never errors loudly.
# Logs to ~/.claude/backups/save-auto.log (rotated when oversized).
#
# Note on WEZTERM_UNIX_SOCKET: scheduled tasks don't inherit per-pane env vars,
# so we reconstruct the socket path from the running wezterm-gui PID.

$ErrorActionPreference = 'SilentlyContinue'
$logPath = "$HOME\.claude\backups\save-auto.log"
$ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

function Write-LogLine {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $logPath -Value "$ts $Message"
    } catch { }
}

# Rotate log if oversized (keep last 1000 lines when it crosses ~200 KB)
try {
    if (Test-Path $logPath) {
        $f = Get-Item $logPath
        if ($f.Length -gt 200000) {
            $tail = Get-Content -LiteralPath $logPath -Tail 1000
            Set-Content -LiteralPath $logPath -Value $tail
        }
    }
} catch { }

# Locate wezterm-gui; skip silently if not running
$wezProc = Get-Process -Name wezterm-gui -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $wezProc) {
    Write-LogLine "skip: wezterm-gui not running"
    exit 0
}

# Reconstruct the per-PID socket path that interactive panes get via env var
$sockPath = Join-Path $HOME ".local\share\wezterm\gui-sock-$($wezProc.Id)"
if (-not (Test-Path -LiteralPath $sockPath)) {
    Write-LogLine "skip: socket not found at $sockPath (wezterm-gui PID $($wezProc.Id))"
    exit 0
}
$env:WEZTERM_UNIX_SOCKET = $sockPath

try {
    # Self-locate the module relative to this script (install/ -> ../src/).
    Import-Module (Join-Path $PSScriptRoot '..\src\ClaudeSessionRestore.psm1') -Force
    Save-ClaudeSession -Profile "default" -ManifestPath "$HOME\.claude\sessions.json" *> $null
    Write-LogLine "saved profile 'default'"
} catch {
    Write-LogLine ("ERROR: " + $_.Exception.Message)
    exit 1
}
```

- [ ] **Step 2: Write `install/Run-SaveClaudeAuto.vbs` (resolves sibling, no hardcoded path)**

```vbscript
' Run-SaveClaudeAuto.vbs
' Wrapper invoked by the ClaudeCode-AutoSave-WezTerm scheduled task.
' Runs Save-ClaudeAuto.ps1 (its sibling) with mode 0 (hidden) so
' STARTUPINFO.wShowWindow=SW_HIDE is set before CreateProcess, which suppresses
' the Win11 default-terminal handover that flashes a Windows Terminal window.
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(scriptDir, "Save-ClaudeAuto.ps1")
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """", 0, False
```

- [ ] **Step 3: Verify the auto-save wrapper runs end-to-end (writes the manifest)**

Run (PowerShell tool) — this exercises the real wrapper while WezTerm is running:

```powershell
$before = (Get-Item "$HOME\.claude\sessions.json" -ErrorAction SilentlyContinue).LastWriteTime
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PWD\install\Save-ClaudeAuto.ps1"
$after  = (Get-Item "$HOME\.claude\sessions.json").LastWriteTime
"manifest touched: " + ($after -ne $before)
Get-Content "$HOME\.claude\backups\save-auto.log" -Tail 2
```

Expected: `manifest touched: True` and a recent `saved profile 'default'` log line (assuming WezTerm is running; if not, log shows `skip: wezterm-gui not running`, which still proves the script path/import resolved).

- [ ] **Step 4: Commit**

```bash
git add install/Save-ClaudeAuto.ps1 install/Run-SaveClaudeAuto.vbs
git commit -m "Add self-locating auto-save wrapper and VBS launcher under install/"
```

---

## Task 6: Rewrite `install/Install.ps1` and `install/Uninstall.ps1`

**Files:**
- Create: `install/Install.ps1` (was `Install-ClaudeAutoSave.ps1`)
- Create: `install/Uninstall.ps1` (was `Uninstall-ClaudeRestore.ps1`)

- [ ] **Step 1: Write `install/Install.ps1`**

Self-locates the VBS via `$PSScriptRoot`, resolves to an absolute path, and registers the scheduled task with that absolute path (Task Scheduler cannot expand `$PSScriptRoot` at run time, so resolution happens now). Re-running re-resolves, so moving the clone + re-running fixes the task.

```powershell
# Install.ps1
# Installs (or removes) the Windows scheduled task that runs the auto-save VBS wrapper
# (Run-SaveClaudeAuto.vbs -> Save-ClaudeAuto.ps1) every N minutes (default: 5). Idempotent.
# Self-locating: works regardless of where the repo is cloned.

function Install-ClaudeAutoSave {
    [CmdletBinding()]
    param(
        [int]$IntervalMinutes = 5,
        [switch]$Uninstall
    )
    $taskName = "ClaudeCode-AutoSave-WezTerm"

    # Always remove existing first (idempotent re-install)
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Removed existing scheduled task: $taskName" -ForegroundColor DarkYellow
    }

    if ($Uninstall) {
        Write-Host "Auto-save disabled." -ForegroundColor Green
        return
    }

    if ($IntervalMinutes -lt 1 -or $IntervalMinutes -gt 1440) {
        Write-Error "IntervalMinutes must be between 1 and 1440 (24h)."
        return
    }

    # Resolve the VBS sibling to an absolute path NOW. The task stores this literal path,
    # so cloning elsewhere + re-running this installer re-points the task automatically.
    $vbs = Join-Path $PSScriptRoot "Run-SaveClaudeAuto.vbs"
    if (-not (Test-Path -LiteralPath $vbs)) {
        Write-Error "Run-SaveClaudeAuto.vbs not found at $vbs"
        return
    }
    $vbs = (Resolve-Path -LiteralPath $vbs).Path

    $action  = New-ScheduledTaskAction -Execute "wscript.exe" -Argument ('"' + $vbs + '"')
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Error ("Failed to create scheduled task: " + $_.Exception.Message)
        return
    }

    Write-Host ""
    Write-Host "Installed scheduled task: $taskName" -ForegroundColor Green
    Write-Host ("  Runs:     every {0} minute(s) while you're logged in" -f $IntervalMinutes)
    Write-Host  "  Action:   $vbs -> Save-ClaudeAuto.ps1 -> ~/.claude/sessions.json (profile 'default')"
    Write-Host  "  Log:      ~/.claude/backups/save-auto.log"
    Write-Host ""
    Write-Host "Verify with:    schtasks /Query /TN $taskName /V /FO LIST"
    Write-Host "Run on demand:  schtasks /Run /TN $taskName"
    Write-Host "Disable later:  install\Install.ps1 -Uninstall"
}

# Run if invoked directly (not dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    Install-ClaudeAutoSave @args
}
```

- [ ] **Step 2: Write `install/Uninstall.ps1`**

Derives the repo dir from `$PSScriptRoot` (parent of `install/`) instead of the hardcoded Desktop path. The settings.json matcher already keys on `*Update-PaneMap.ps1*`, which still matches the new `hooks/` path, so it is unchanged.

```powershell
# Uninstall.ps1
# Restores the PowerShell profile from the timestamped backup, then removes the repo dir
# (derived from this script's location). Optionally removes ~/.claude/sessions.json.

function Uninstall-ClaudeRestore {
    [CmdletBinding()]
    param(
        [string]$BackupPath,
        [switch]$Force,
        [switch]$KeepManifest
    )

    # The repo lives one level above install/.
    $repoDir = Split-Path -Parent $PSScriptRoot

    # Locate backup if not explicitly given: most recent .bak in ~/.claude/backups/
    if (-not $BackupPath) {
        $candidates = Get-ChildItem -LiteralPath "$HOME\.claude\backups" -Filter "Microsoft.PowerShell_profile.ps1.*.bak" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        if (-not $candidates) {
            Write-Error "No profile backup found in $HOME\.claude\backups\. Pass -BackupPath explicitly or restore manually."
            return
        }
        $BackupPath = $candidates[0].FullName
        Write-Host "Using most recent backup: $BackupPath" -ForegroundColor Cyan
    }

    if (-not (Test-Path -LiteralPath $BackupPath)) {
        Write-Error "Backup file does not exist: $BackupPath"
        return
    }

    if (-not $Force) {
        Write-Host ""
        Write-Host "About to:" -ForegroundColor Yellow
        Write-Host "  1. Remove scheduled task 'ClaudeCode-AutoSave-WezTerm' (if present)"
        Write-Host "  2. Remove SessionStart pane-map hook from ~/.claude/settings.json (if present)"
        Write-Host "  3. Delete: $HOME\.claude\pane-map\ (if present)"
        Write-Host "  4. Restore profile from: $BackupPath"
        Write-Host "  5. Delete: $repoDir"
        if (-not $KeepManifest) {
            Write-Host "  6. Delete: $HOME\.claude\sessions.json (use -KeepManifest to skip)"
        }
        $resp = Read-Host "Proceed? (y/N)"
        if ($resp -notmatch '^(y|Y|yes|YES)$') {
            Write-Host "Aborted." -ForegroundColor Yellow
            return
        }
    }

    # 1. Remove scheduled task (BEFORE deleting the repo — the task references files in it)
    $taskName = "ClaudeCode-AutoSave-WezTerm"
    & schtasks.exe /Query /TN $taskName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & schtasks.exe /Delete /TN $taskName /F | Out-Null
        Write-Host "Removed scheduled task: $taskName" -ForegroundColor Green
    }

    # 2. Remove SessionStart pane-map hook from settings.json (preserves all other hooks)
    $settingsPath = "$HOME\.claude\settings.json"
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $tsBak = (Get-Date).ToString('yyyyMMdd-HHmmss')
            Copy-Item $settingsPath "$HOME\.claude\backups\settings.json.preuninstall.$tsBak.bak" -Force -ErrorAction SilentlyContinue
            $raw = Get-Content -Raw -LiteralPath $settingsPath
            $settings = $raw | ConvertFrom-Json
            if ($settings.hooks -and $settings.hooks.SessionStart) {
                $filtered = @($settings.hooks.SessionStart | Where-Object {
                    $entry = $_
                    $hasPaneMap = $false
                    if ($entry.hooks) {
                        foreach ($h in $entry.hooks) {
                            if ($h.command -and $h.command -like '*Update-PaneMap.ps1*') { $hasPaneMap = $true }
                        }
                    }
                    -not $hasPaneMap
                })
                if ($filtered.Count -lt @($settings.hooks.SessionStart).Count) {
                    $settings.hooks.SessionStart = $filtered
                    $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
                    Write-Host "Removed SessionStart pane-map hook from settings.json." -ForegroundColor Green
                }
            }
        } catch {
            Write-Warning ("Could not auto-edit settings.json: " + $_.Exception.Message + ". Remove the Update-PaneMap.ps1 hook entry manually.")
        }
    }

    # 3. Remove pane-map directory
    $paneMapDir = "$HOME\.claude\pane-map"
    if (Test-Path -LiteralPath $paneMapDir) {
        Remove-Item -LiteralPath $paneMapDir -Recurse -Force
        Write-Host "Removed $paneMapDir." -ForegroundColor Green
    }

    # 4. Restore profile
    Copy-Item -LiteralPath $BackupPath -Destination $PROFILE -Force
    Write-Host "Profile restored from backup." -ForegroundColor Green

    # 5. Remove sessions.json (optional)
    if (-not $KeepManifest) {
        if (Test-Path -LiteralPath "$HOME\.claude\sessions.json") {
            Remove-Item -LiteralPath "$HOME\.claude\sessions.json" -Force
            Write-Host "Removed sessions.json." -ForegroundColor Green
        }
    }

    # 6. Remove the repo directory (last, since this script lives inside it)
    if (Test-Path -LiteralPath $repoDir) {
        $tmpSelf = Join-Path $env:TEMP "Uninstall-ClaudeRestore.exiting.ps1"
        Copy-Item -LiteralPath $PSCommandPath -Destination $tmpSelf -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $repoDir -Recurse -Force
        Write-Host "Removed $repoDir." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Uninstall complete." -ForegroundColor Green
    Write-Host "Reload your profile in any open shell with:  . `$PROFILE" -ForegroundColor Cyan
    Write-Host "(New shells will get the original behavior automatically.)"
}

# Run the function if this script is invoked directly rather than dot-sourced.
if ($MyInvocation.InvocationName -ne '.') {
    Uninstall-ClaudeRestore @args
}
```

- [ ] **Step 3: Verify both scripts parse without executing**

Run (PowerShell tool) — parse-only check using the PS parser:

```powershell
foreach ($s in 'install\Install.ps1','install\Uninstall.ps1') {
  $errs = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $s).Path, [ref]$null, [ref]$errs) | Out-Null
  "{0}: {1} parse error(s)" -f $s, $errs.Count
}
```

Expected: both report `0 parse error(s)`.

- [ ] **Step 4: Commit**

```bash
git add install/Install.ps1 install/Uninstall.ps1
git commit -m "Add self-locating Install/Uninstall under install/"
```

---

## Task 7: Move docs and debug helper into `docs/`

**Files:**
- Create: `docs/ROLLBACK.md` (verbatim copy of root `ROLLBACK.md`)
- Create: `docs/Watch-ConsoleSpawns.ps1` (copy with updated usage-comment paths)

- [ ] **Step 1: Copy `ROLLBACK.md` into `docs/`**

Create `docs/ROLLBACK.md` with the exact current content of root `ROLLBACK.md`.

- [ ] **Step 2: Write `docs/Watch-ConsoleSpawns.ps1`**

Copy the current root `Watch-ConsoleSpawns.ps1` and update only the two usage-comment lines (7 and 10) so the start command uses a self-relative path. Replace the comment block (lines 1-10 of the original) with:

```powershell
# Watch-ConsoleSpawns.ps1
# Polls every 250ms for new console-host process instances. When Windows Terminal
# or OpenConsole spawns (the visible-window cause), dumps a snapshot of every
# process started in the prior ~3 seconds so the COM client can be identified.
#
# Start (detached, hidden), from this file's folder:
#   Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$PSScriptRoot\Watch-ConsoleSpawns.ps1" -WindowStyle Hidden
#
# Stop:
#   Stop-Process -Id (Get-Content "$HOME\.claude\backups\console-spawn.pid")
```

Leave the rest of the file (from `$ErrorActionPreference = 'SilentlyContinue'` onward) byte-for-byte unchanged.

- [ ] **Step 3: Verify ROLLBACK.md is identical and the watcher parses**

Run (PowerShell tool):

```powershell
"ROLLBACK identical: " + ((Get-FileHash docs\ROLLBACK.md).Hash -eq (Get-FileHash ROLLBACK.md).Hash)
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path docs\Watch-ConsoleSpawns.ps1).Path, [ref]$null, [ref]$errs) | Out-Null
"watcher parse errors: " + $errs.Count
```

Expected: `ROLLBACK identical: True` and `watcher parse errors: 0`.

- [ ] **Step 4: Commit**

```bash
git add docs/ROLLBACK.md docs/Watch-ConsoleSpawns.ps1
git commit -m "Move rollback notes and console-spawn debug helper under docs/"
```

---

## Task 8: Re-wire the author's live setup to the new locations

This is the moment the live setup switches from old → new. Backups already exist (Task 1).

**Files:**
- Modify: `~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1` (lines 20-23)
- Modify: `~/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1` (lines 5-8 only — NOT 10-18)
- Modify: `~/.claude/settings.json` (hook command path)
- Modify: scheduled task `ClaudeCode-AutoSave-WezTerm` (re-register via Install.ps1)

- [ ] **Step 1: Replace the 3 dot-source lines in the PowerShell 7 profile**

In `~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1`, replace the 4-line block (comment + 3 `if (Test-Path ...) { . ... }` lines) with:

```powershell
# Claude Code session helpers (Save-ClaudeSession / Restore-ClaudeSession / Get-ClaudeSession)
$ClaudeSessionRestoreModule = "$HOME\Desktop\Cursor Projects\claude-session-restore\src\ClaudeSessionRestore.psm1"
if (Test-Path $ClaudeSessionRestoreModule) { Import-Module $ClaudeSessionRestoreModule }
```

- [ ] **Step 2: Replace the 3 dot-source lines in the Windows PowerShell 5.1 profile — leave the auto-launch block intact**

In `~/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1`, replace ONLY the 4-line block at lines 5-8 (comment + 3 dot-source lines) with the same 3 lines as Step 1. **Do not modify lines 10-18 (the `if ($env:CLAUDE_RESTORE_NAME) { claude --resume ... }` auto-launch block).**

- [ ] **Step 3: Repoint the SessionStart hook path in settings.json**

In `~/.claude/settings.json`, in the hook command string, change:

```
...\claude-session-restore\Update-PaneMap.ps1
```
to:
```
...\claude-session-restore\hooks\Update-PaneMap.ps1
```

(The surrounding command — `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "..."` — is unchanged; only the path gains `\hooks` before the filename.)

- [ ] **Step 4: Verify settings.json is still valid JSON and the hook points at hooks/**

Run (PowerShell tool):

```powershell
$s = Get-Content -Raw "$HOME\.claude\settings.json" | ConvertFrom-Json
($s.hooks.SessionStart | ForEach-Object { $_.hooks.command }) -join "`n"
```

Expected: prints the hook command containing `\claude-session-restore\hooks\Update-PaneMap.ps1` and parses without error.

- [ ] **Step 5: Re-register the scheduled task at the new path**

Run (PowerShell tool):

```powershell
& "$PWD\install\Install.ps1"
schtasks /Query /TN ClaudeCode-AutoSave-WezTerm /V /FO LIST | Select-String "Task To Run"
```

Expected: "Installed scheduled task" message, and the Task-To-Run line shows `wscript.exe "...\claude-session-restore\install\Run-SaveClaudeAuto.vbs"`.

- [ ] **Step 6: Verify a fresh shell loads the module and resolves new commands (old names gone) — BOTH pwsh 7 and 5.1**

pwsh 7 is the author's daily-driver interactive shell, so this is the primary check; `powershell.exe` 5.1 is the restore-spawn path. Run each in a *fresh* shell so in-memory leftovers from this session can't skew the result.

Run (PowerShell tool):

```powershell
$probe = "Get-Command Restore-ClaudeSession,claude-restore,claude-save -ErrorAction SilentlyContinue | Select-Object -Expand Name; 'old present: ' + [bool](Get-Command Save-Claude -ErrorAction SilentlyContinue)"
"=== pwsh 7 ==="
if (Get-Command pwsh -ErrorAction SilentlyContinue) { pwsh -NoLogo -Command $probe } else { "pwsh not on PATH" }
"=== powershell 5.1 ==="
powershell.exe -NoLogo -Command $probe
```

Expected (both shells): `Restore-ClaudeSession`, `claude-restore`, `claude-save` listed; `old present: False`.

No repo commit here — these files live outside the repo. (Commit happens implicitly via the live edits being durable on disk.)

---

## Task 9: Delete the superseded root files

Now that the live setup points entirely at the new locations, remove the originals.

**Files:**
- Delete: `Save-ClaudeSessions.ps1`, `Restore-ClaudeSessions.ps1`, `Get-ClaudeSessions.ps1`, `Update-PaneMap.ps1`, `Save-ClaudeAuto.ps1`, `Run-SaveClaudeAuto.vbs`, `Install-ClaudeAutoSave.ps1`, `Uninstall-ClaudeRestore.ps1`, `Watch-ConsoleSpawns.ps1`, `ROLLBACK.md`

- [ ] **Step 1: Remove the old root files via git**

```bash
git rm Save-ClaudeSessions.ps1 Restore-ClaudeSessions.ps1 Get-ClaudeSessions.ps1 \
       Update-PaneMap.ps1 Save-ClaudeAuto.ps1 Run-SaveClaudeAuto.vbs \
       Install-ClaudeAutoSave.ps1 Uninstall-ClaudeRestore.ps1 \
       Watch-ConsoleSpawns.ps1 ROLLBACK.md
```

- [ ] **Step 2: Verify the new tree is exactly the intended layout**

Run (PowerShell tool):

```powershell
git ls-files | Where-Object { $_ -notlike 'docs/superpowers/*' }
```

Expected (order may vary): `.gitignore`, `LICENSE`, `README.md`, `docs/ROLLBACK.md`, `docs/Watch-ConsoleSpawns.ps1`, `hooks/Update-PaneMap.ps1`, `install/Install.ps1`, `install/Run-SaveClaudeAuto.vbs`, `install/Save-ClaudeAuto.ps1`, `install/Uninstall.ps1`, `src/ClaudeSessionRestore.psm1`. No `*.ps1` or `*.vbs` at the repo root.

- [ ] **Step 3: Commit**

```bash
git commit -m "Remove superseded root scripts after reorg"
```

---

## Task 10: Rewrite README for the new layout

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Overwrite `README.md`**

```markdown
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
| `docs/ROLLBACK.md` | rollback notes |
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
```

- [ ] **Step 2: Verify the README references no obsolete root paths**

Run (Grep tool or PowerShell):

```powershell
Select-String -Path README.md -Pattern 'Save-ClaudeSessions\.ps1|Restore-ClaudeSessions\.ps1|Save-Claude\b|Restore-Claude\b|Install-ClaudeAutoSave' -AllMatches | Select-Object LineNumber, Line
```

Expected: no matches (empty output). The only `claude-restore` / `claude-save` references are the aliases, which are intended.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Rewrite README for new layout and module-based install"
```

---

## Task 11: Final end-to-end verification

**Files:** none (verification only)

- [ ] **Step 1: Module import + command surface (fresh module load)**

Run (PowerShell tool):

```powershell
Remove-Module ClaudeSessionRestore -ErrorAction SilentlyContinue
Import-Module "$PWD\src\ClaudeSessionRestore.psm1" -Force
Get-Command -Module ClaudeSessionRestore | Sort-Object Name | Select-Object CommandType, Name
"--- old names absent from module export ---"
'Save-Claude','Restore-Claude','Get-ClaudeSessions' | ForEach-Object {
  "{0} exported: {1}" -f $_, ((Get-Module ClaudeSessionRestore).ExportedCommands.ContainsKey($_))
}
```

Expected: the 3 new functions + 2 aliases; each old name `exported: False`.
(Check export membership, NOT `Get-Command` in this session — if this session ever dot-sourced the old files, those functions linger in memory and would false-fail a `Get-Command` probe. The fresh-shell `Get-Command` check lives in Task 8 Step 6.)

- [ ] **Step 2: ListProfiles + DryRun read the real manifest**

```powershell
Restore-ClaudeSession -ListProfiles
Restore-ClaudeSession -DryRun
```

Expected: profile list printed; dry-run prints `wezterm.exe cli ...` lines, spawns nothing.

- [ ] **Step 3: Scheduled task points at the new VBS**

```powershell
schtasks /Query /TN ClaudeCode-AutoSave-WezTerm /V /FO LIST | Select-String "Task To Run|Repeat: Every"
```

Expected: Task-To-Run contains `install\Run-SaveClaudeAuto.vbs`; repeat every 5 minutes.

- [ ] **Step 4: Live profile loads cleanly in fresh shells (pwsh 7 primary, 5.1 secondary)**

```powershell
$chk = "Get-Command claude-restore -ErrorAction SilentlyContinue | Select-Object -Expand Name; 'profile errors: ' + $Error.Count"
"=== pwsh 7 ==="
if (Get-Command pwsh -ErrorAction SilentlyContinue) { pwsh -NoLogo -Command $chk } else { "pwsh not on PATH" }
"=== powershell 5.1 ==="
powershell.exe -NoLogo -Command $chk
```

Expected (both): `claude-restore` listed; `profile errors: 0`.

- [ ] **Step 5: Confirm clean working tree and intended file list**

```bash
git status --porcelain
git ls-files | grep -v '^docs/superpowers/'
```

Expected: empty `git status` (all committed); file list matches Task 9 Step 2.

- [ ] **Step 6 (REQUIRED acceptance gate — author-run, manual): full round-trip**

This is the only real acceptance test; the automated steps above prove structure/import/registration but not that restore actually works. The reorg is NOT "verified" until this passes. Requires manual WezTerm interaction, so the author runs it:

With a WezTerm window of Claude panes open: run `claude-save`, quit WezTerm, reopen, run `claude-restore`, and confirm every tab/pane returns resumed to its session. Do not declare the reorg complete before this gate passes.

---

## Notes / out of scope (YAGNI)

- No PSGallery manifest (`.psd1`) / `Publish-Module`.
- No macOS/Linux support.
- `Get-ClaudeSession` keeps its existing (slightly different) slug regex `[:\\/ ]`; this reorg preserves behavior and does not "fix" it. If the author later wants the slug logic unified with `Save`'s `[^a-zA-Z0-9]` regex, that is a separate change.
```
