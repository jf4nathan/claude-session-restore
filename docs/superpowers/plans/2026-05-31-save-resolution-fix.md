# Save Resolution Duplicate-Session Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (tasks are tightly coupled in one module + test). Steps use checkbox (`- [ ]`) syntax.

**Goal:** Stop `Save-ClaudeSession` from assigning the same session to multiple panes (and from cwd-guessing when a pane's mapped session is an empty startup session), so the manifest faithfully reflects on-screen panes.

**Architecture:** Extract the pane→entry resolution into a pure, testable module-private function `Resolve-PaneEntries` (injectable `ClaudeRoot` + `WindowPanes` + `MuxOrigin`). Task 1 is a behavior-preserving move; Task 2 writes a failing test then adds two guards — reserve pane-mapped sessions from cwd-guessing, and treat an unresolvable pane-map as `fresh`. Restore is untouched.

**Tech Stack:** PowerShell module (`.psm1`), plain-PowerShell test (no Pester).

**Branch:** Work on the current branch `reorg-public-repo`. **Do NOT push** (user pushes via another agent). No worktree.

**Spec:** `docs/superpowers/specs/2026-05-31-save-resolution-fix-design.md`

**Current code reference (module `src/ClaudeSessionRestore.psm1`):**
- `Save-ClaudeSession` lines 6–~343. The resolution to extract = **lines 60–294**: `$cwdSessions = @{}`, the nested helpers `Get-CwdSessions` / `Use-CwdSession` / `Get-SessionHome` / `Use-PaneMappedSession`, and the tab/pane loop ending with `$tabs` assembled. Manifest load/merge/write follows (296+).
- Export line near end: `Export-ModuleMember -Function ... -Alias ...`.

**Key PowerShell fact:** variable names are case-insensitive, so the moved code's `$muxOrigin` and `$windowPanes` references resolve to the new params `$MuxOrigin` / `$WindowPanes` with no edit needed.

---

## Task 1: Testability refactor — extract `Resolve-PaneEntries` (PURE move, no behavior change)

**Files:** Modify `src/ClaudeSessionRestore.psm1`

- [ ] **Step 1: Wrap lines 60–294 in a new module-private function.** Place `function Resolve-PaneEntries { ... }` immediately above `function Save-ClaudeSession`. Move the current lines 60–294 (from `$cwdSessions = @{}` through the end of the tab loop that assembles `$tabs`) into it **verbatim**, then apply ONLY these three path substitutions and add a `return`:

  - Function signature:
    ```powershell
    function Resolve-PaneEntries {
        param(
            [object[]]$WindowPanes,
            $MuxOrigin,
            [string]$ClaudeRoot = (Join-Path $HOME '.claude')
        )
        $cwdSessions = @{}
        # ... (moved helpers + tab loop verbatim, with the 3 substitutions below) ...
        return $tabs
    }
    ```
  - Substitution A — in `Get-CwdSessions`, change
    `$projectDir = Join-Path "$HOME\.claude\projects" $projectSlug`
    to
    `$projectDir = Join-Path (Join-Path $ClaudeRoot 'projects') $projectSlug`
  - Substitution B — in `Get-SessionHome`, change
    `$hit = Get-ChildItem -Path (Join-Path "$HOME\.claude\projects" "*\$SessionId.jsonl") -ErrorAction SilentlyContinue |`
    to
    `$hit = Get-ChildItem -Path (Join-Path (Join-Path $ClaudeRoot 'projects') "*\$SessionId.jsonl") -ErrorAction SilentlyContinue |`
  - Substitution C — in `Use-PaneMappedSession`, change
    `$mapFile = "$HOME\.claude\pane-map\$PaneId.session"`
    to
    `$mapFile = Join-Path (Join-Path $ClaudeRoot 'pane-map') "$PaneId.session"`

  Everything else (the `Use-CwdSession` body, the `Use-PaneMappedSession` staleness/resolve/consume logic, the per-pane resolution block, the entry-building, the tab-title heuristic) is moved **unchanged**. Do not add guards yet.

- [ ] **Step 2: Make `Save-ClaudeSession` delegate.** Delete the moved lines (old 60–294) from `Save-ClaudeSession`. In their place — right after `$windowPanes = $panes | Where-Object { $_.window_id -eq $WindowId }` — insert:

  ```powershell
    $tabs = Resolve-PaneEntries -WindowPanes $windowPanes -MuxOrigin $muxOrigin -ClaudeRoot (Join-Path $HOME '.claude')
  ```

  The manifest load/merge/write block that follows stays exactly as-is.

- [ ] **Step 3: Guard the `Export-ModuleMember` line** so the file can be dot-sourced by tests without throwing:

  ```powershell
  if ($MyInvocation.MyCommand.ScriptBlock.Module) {
      Export-ModuleMember -Function Save-ClaudeSession, Restore-ClaudeSession, Get-ClaudeSession `
                          -Alias claude-save, claude-restore
  }
  ```

- [ ] **Step 4: Verify parse + import + surface + private function present**

  Run (PowerShell tool):
  ```powershell
  $errs=$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path src\ClaudeSessionRestore.psm1).Path,[ref]$null,[ref]$errs)|Out-Null; "parse errors: $($errs.Count)"
  Remove-Module ClaudeSessionRestore -ErrorAction SilentlyContinue
  Import-Module "$PWD\src\ClaudeSessionRestore.psm1" -Force
  (Get-Command -Module ClaudeSessionRestore | Sort-Object Name | Select-Object -Expand Name) -join ', '
  "Resolve-PaneEntries present (private): " + [bool](& (Get-Module ClaudeSessionRestore) { Get-Command Resolve-PaneEntries -ErrorAction SilentlyContinue })
  ```
  Expected: `parse errors: 0`; exported = `claude-restore, claude-save, Get-ClaudeSession, Restore-ClaudeSession, Save-ClaudeSession` (Resolve-PaneEntries NOT in the exported list); `Resolve-PaneEntries present (private): True`.

- [ ] **Step 5: Commit**
  ```bash
  git add src/ClaudeSessionRestore.psm1
  git commit -m "Refactor: extract testable Resolve-PaneEntries from Save-ClaudeSession"
  ```

---

## Task 2: Failing test, then the two guards (red → green)

**Files:** Create `tests/Resolve-PaneEntries.Tests.ps1`; Modify `src/ClaudeSessionRestore.psm1`

- [ ] **Step 1: Write the test** `tests/Resolve-PaneEntries.Tests.ps1` (plain PowerShell, fully synthetic fixtures — no real session data):

```powershell
# Resolve-PaneEntries.Tests.ps1 — plain-PowerShell tests (no Pester).
# Run: pwsh -File tests/Resolve-PaneEntries.Tests.ps1   (exit 0 = all pass)
$ErrorActionPreference = 'Stop'
$script:fails = 0
function Assert($cond, $msg) { if ($cond) { "  PASS: $msg" } else { "  FAIL: $msg"; $script:fails++ } }

# Dot-source the module (Export guard permits this without erroring); exposes private fns.
. "$PSScriptRoot\..\src\ClaudeSessionRestore.psm1"

function New-Fixture {
    $base = Join-Path ([System.IO.Path]::GetTempPath()) ("csr-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $root = Join-Path $base 'claude'
    $work = Join-Path $base 'work'
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'pane-map') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'projects') | Out-Null
    return @{ Root = $root; Work = $work; Base = $base }
}
function Add-RealSession($root, $work, $uuid, $slug) {
    $projSlug = ($work -replace '[^a-zA-Z0-9]', '-')
    $dir = Join-Path (Join-Path $root 'projects') $projSlug
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $escaped = $work.Replace('\','\\')
    Set-Content -LiteralPath (Join-Path $dir "$uuid.jsonl") -Value ('{"cwd":"' + $escaped + '","slug":"' + $slug + '","sessionId":"' + $uuid + '"}')
}
function Set-PaneMap($root, $paneId, $uuid) {
    Set-Content -LiteralPath (Join-Path (Join-Path $root 'pane-map') "$paneId.session") -Value $uuid -NoNewline
}
function New-Pane($paneId, $tabId, $title, $work, $top, $left) {
    $uri = 'file:///' + ($work -replace '\\','/') + '/'
    [PSCustomObject]@{ pane_id=$paneId; tab_id=$tabId; title=$title; cwd=$uri; top_row=$top; left_col=$left; window_id=0; is_active=$false }
}
function Get-Entries($tabs) { @($tabs | ForEach-Object { $_.panes }) }

$REAL='11111111-1111-4111-8111-111111111111'; $EMP1='22222222-2222-4222-8222-222222222222'; $EMP2='33333333-3333-4333-8333-333333333333'
$mux = (Get-Date).AddMinutes(-5)

Write-Host "=== Case 1: empty-mapped panes must NOT collapse onto the one real session ==="
$f = New-Fixture
Add-RealSession $f.Root $f.Work $REAL 'realsess'
Set-PaneMap $f.Root 10 $EMP1   # empty (no jsonl) — sorted FIRST
Set-PaneMap $f.Root 11 $REAL   # valid
Set-PaneMap $f.Root 12 $EMP2   # empty (no jsonl)
$panes = @(
    (New-Pane 10 1 'Doing some empty thing' $f.Work 0 0),
    (New-Pane 11 1 'The real session'        $f.Work 0 1),
    (New-Pane 12 1 'Another empty thing'     $f.Work 0 2)
)
$entries = Get-Entries (Resolve-PaneEntries -WindowPanes $panes -MuxOrigin $mux -ClaudeRoot $f.Root)
$resumeIds = @($entries | Where-Object { $_.resume } | ForEach-Object { $_.resume })
$dups = @($resumeIds | Group-Object | Where-Object Count -gt 1)
Assert ($dups.Count -eq 0) "no duplicate resume IDs (got: $($resumeIds -join ', '))"
Assert (@($resumeIds | Where-Object { $_ -eq $REAL }).Count -eq 1) "the one real session resumes exactly once"
Assert ((@($entries | Where-Object { $_.fresh }).Count) -eq 2) "the two empty-startup panes are fresh"
Remove-Item -Recurse -Force $f.Base -ErrorAction SilentlyContinue

Write-Host "=== Case 2: control — three valid distinct maps each resume their own session ==="
$f2 = New-Fixture
$R1='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'; $R2='bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'; $R3='cccccccc-3333-4333-8333-cccccccccccc'
$w1=Join-Path $f2.Base 'w1'; $w2=Join-Path $f2.Base 'w2'; $w3=Join-Path $f2.Base 'w3'
New-Item -ItemType Directory -Force -Path $w1,$w2,$w3 | Out-Null
Add-RealSession $f2.Root $w1 $R1 's1'; Add-RealSession $f2.Root $w2 $R2 's2'; Add-RealSession $f2.Root $w3 $R3 's3'
Set-PaneMap $f2.Root 20 $R1; Set-PaneMap $f2.Root 21 $R2; Set-PaneMap $f2.Root 22 $R3
$panes2 = @(
    (New-Pane 20 1 'one'   $w1 0 0),
    (New-Pane 21 1 'two'   $w2 0 1),
    (New-Pane 22 1 'three' $w3 0 2)
)
$ids2 = @((Get-Entries (Resolve-PaneEntries -WindowPanes $panes2 -MuxOrigin $mux -ClaudeRoot $f2.Root)) | Where-Object { $_.resume } | ForEach-Object { $_.resume })
Assert ($ids2.Count -eq 3) "all three panes resume (got $($ids2.Count))"
Assert ((@($ids2 | Sort-Object -Unique).Count) -eq 3) "three DISTINCT sessions resumed"
Remove-Item -Recurse -Force $f2.Base -ErrorAction SilentlyContinue

Write-Host ""
if ($script:fails -eq 0) { "ALL TESTS PASSED"; exit 0 } else { "FAILED: $script:fails assertion(s)"; exit 1 }
```

- [ ] **Step 2: Run the test — expect RED** (proves the bug reproduces after the pure refactor)

  Run: `pwsh -File tests/Resolve-PaneEntries.Tests.ps1`
  Expected: Case 1 FAILS — "no duplicate resume IDs" fails. With the unguarded code, pane 10 (empty map, sorted first) cwd-guesses and grabs `$REAL`; pane 11 (valid map) also resumes `$REAL` → duplicate. Case 2 passes. Exit 1.

- [ ] **Step 3: Implement the two guards** in `src/ClaudeSessionRestore.psm1`. Four edits:

  **(3a) Add `Get-PaneMappedId`** as a module-private function (place just above `Resolve-PaneEntries`):
  ```powershell
  function Get-PaneMappedId {
      # The session UUID the SessionStart hook recorded for this pane, or $null
      # ($null if no/empty map, or the map predates the current WezTerm generation).
      param([int]$PaneId, $MuxOrigin, [string]$ClaudeRoot)
      $mapFile = Join-Path (Join-Path $ClaudeRoot 'pane-map') "$PaneId.session"
      if (-not (Test-Path -LiteralPath $mapFile)) { return $null }
      if ($MuxOrigin -and (Get-Item -LiteralPath $mapFile).LastWriteTime -lt $MuxOrigin) {
          Write-Warning ("  pane {0}: pane-map is stale (predates current WezTerm); ignoring, will guess by cwd/title." -f $PaneId)
          return $null
      }
      $sessionId = (Get-Content -LiteralPath $mapFile -Raw -ErrorAction SilentlyContinue).Trim()
      if (-not $sessionId) { return $null }
      return $sessionId
  }
  ```

  **(3b) Add the reservation pre-pass** in `Resolve-PaneEntries`, immediately after `$cwdSessions = @{}`:
  ```powershell
      # Reserve every session a (non-stale) pane-map claims in this window, so cwd-guessing
      # can never grab a session another pane legitimately owns (prevents N-panes-on-1-session).
      $reserved = @{}
      foreach ($wp in $WindowPanes) {
          $rid = Get-PaneMappedId -PaneId $wp.pane_id -MuxOrigin $MuxOrigin -ClaudeRoot $ClaudeRoot
          if ($rid) { $reserved[$rid] = $true }
      }
  ```

  **(3c) Replace `Use-CwdSession`** (reserved-aware picking) and **delete the `Use-PaneMappedSession` function entirely**:
  ```powershell
      function Use-CwdSession {
          param([string]$Cwd, [string]$PreferredSlug)
          $list = Get-CwdSessions -Cwd $Cwd
          $cands = @($list | Where-Object { -not $reserved.ContainsKey($_.SessionId) })
          if ($cands.Count -eq 0) { return $null }
          $picked = $null
          if ($PreferredSlug) { $picked = $cands | Where-Object { $_.Slug -eq $PreferredSlug } | Select-Object -First 1 }
          if (-not $picked) { $picked = $cands[0] }
          $cwdSessions[$Cwd] = @($list | Where-Object { $_.SessionId -ne $picked.SessionId })
          return $picked
      }
  ```

  **(3d) Replace the per-pane resolution block** (the old `$picked = $null; $resumeCwd = $cwd; if (-not $looksLikeShell) { $picked = Use-PaneMappedSession ... }` block) with:
  ```powershell
              $picked = $null
              $resumeCwd = $cwd
              $mappedUnresolved = $false
              if (-not $looksLikeShell) {
                  $mid = Get-PaneMappedId -PaneId $p.pane_id -MuxOrigin $MuxOrigin -ClaudeRoot $ClaudeRoot
                  if ($mid) {
                      $sess = Get-SessionHome -SessionId $mid
                      if ($sess) {
                          # Tier-1: exact pane-map hit, resolved to its real home dir.
                          $picked = $sess
                          if ($picked.Cwd) { $resumeCwd = $picked.Cwd }
                          $hlist = Get-CwdSessions -Cwd $sess.Cwd
                          if ($hlist.Count -gt 0) { $cwdSessions[$sess.Cwd] = @($hlist | Where-Object { $_.SessionId -ne $mid }) }
                      } else {
                          # GUARD 2: mapped to a session with no jsonl (empty startup session).
                          # Do NOT cwd-guess (that collapses onto an unrelated session). Open fresh.
                          $mappedUnresolved = $true
                      }
                  } elseif ($cwd) {
                      # Tier-2/3: no pane-map — guess by title-slug / most-recent (reserved excluded).
                      $picked = Use-CwdSession -Cwd $cwd -PreferredSlug $title
                  }
              }
  ```

  **(3e) Replace the entry-building block** with (adds `-or $mappedUnresolved`, reserved-aware `$remaining`):
  ```powershell
              $entry = [ordered]@{
                  title               = $title
                  cwd                 = if ($picked) { $resumeCwd } else { $cwd }
                  split_from_previous = $direction
              }
              if ($picked) {
                  $entry.resume = $picked.SessionId
                  if ($picked.Slug) { $entry.resume_slug = $picked.Slug }
              } elseif ($looksLikeShell -or $mappedUnresolved) {
                  $entry.fresh = $true
              } else {
                  $remaining = @(Get-CwdSessions -Cwd $cwd | Where-Object { -not $reserved.ContainsKey($_.SessionId) })
                  if ($remaining.Count -gt 0) { $entry.continue = $true } else { $entry.fresh = $true }
              }
  ```

- [ ] **Step 4: Run the test — expect GREEN**

  Run: `pwsh -File tests/Resolve-PaneEntries.Tests.ps1`
  Expected: `ALL TESTS PASSED`, exit 0.

- [ ] **Step 5: Commit module + test**
  ```bash
  git add src/ClaudeSessionRestore.psm1 tests/Resolve-PaneEntries.Tests.ps1
  git commit -m "Fix Save resolution: reserve pane-mapped sessions; unresolvable map -> fresh"
  ```

---

## Task 3: Final verification + reset guidance

**Files:** none (verification only)

- [ ] **Step 1: Re-run the test clean** — `pwsh -File tests/Resolve-PaneEntries.Tests.ps1` → `ALL TESTS PASSED`.

- [ ] **Step 2: Parse + public surface unchanged**
  ```powershell
  $errs=$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path src\ClaudeSessionRestore.psm1).Path,[ref]$null,[ref]$errs)|Out-Null; "parse errors: $($errs.Count)"
  Remove-Module ClaudeSessionRestore -ErrorAction SilentlyContinue
  Import-Module "$PWD\src\ClaudeSessionRestore.psm1" -Force
  (Get-Command -Module ClaudeSessionRestore | Sort-Object Name | Select-Object -Expand Name) -join ', '
  ```
  Expected: `parse errors: 0`; exported = `claude-restore, claude-save, Get-ClaudeSession, Restore-ClaudeSession, Save-ClaudeSession`.

- [ ] **Step 3: Live smoke — Save to a throwaway profile, check for duplicates (WezTerm running)**
  ```powershell
  Import-Module "$PWD\src\ClaudeSessionRestore.psm1" -Force
  $wez = Get-Process wezterm-gui -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($wez) { $env:WEZTERM_UNIX_SOCKET = Join-Path $HOME ".local\share\wezterm\gui-sock-$($wez.Id)" }
  Save-ClaudeSession -Profile diag-test -ManifestPath "$HOME\.claude\sessions.json" *> $null
  $m = Get-Content -Raw "$HOME\.claude\sessions.json" | ConvertFrom-Json
  $ids = @($m.profiles.'diag-test'.tabs.panes | Where-Object { $_.resume } | ForEach-Object { $_.resume })
  "resume ids: $($ids.Count) total, $((@($ids | Sort-Object -Unique)).Count) distinct, dups=$((@($ids | Group-Object | Where-Object Count -gt 1)).Count)"
  ```
  Expected: `dups=0`. (Writes a throwaway `diag-test` profile; the real `default` profile is untouched.)

- [ ] **Step 4: One-time reset of the live `default` manifest (operational; user-driven pane close)**

  With WezTerm open and the spurious fathom-mcp panes closed **by the user** (do not kill panes automatically):
  ```powershell
  Import-Module "$PWD\src\ClaudeSessionRestore.psm1" -Force
  $wez = Get-Process wezterm-gui -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($wez) { $env:WEZTERM_UNIX_SOCKET = Join-Path $HOME ".local\share\wezterm\gui-sock-$($wez.Id)" }
  claude-save
  Restore-ClaudeSession -DryRun
  ```
  Expected: `DryRun` lists only on-screen panes, no duplicate resume IDs, no fathom-mcp panes.

- [ ] **Step 5: Clean tree (local; do NOT push)**
  ```bash
  git status --porcelain && git log --oneline -3
  ```
  Expected: clean tree; refactor commit + fix commit present. No push.

---

## Self-review notes

- Task 1 is a pure move (case-insensitive var names mean `$muxOrigin`/`$windowPanes` bind to the new params; only 3 path literals change) → the Task 2 RED test genuinely reproduces the dup before the guards land.
- Restore, the SessionStart hook, and the manifest format are untouched. No new dependency.
- `diag-test` profile (Task 3 Step 3) is a throwaway to avoid clobbering `default` during verification.
