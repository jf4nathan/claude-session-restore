# Worktree-Resume.Tests.ps1 — plain-PowerShell tests (no Pester).
# Run: pwsh -File tests/Worktree-Resume.Tests.ps1   (exit 0 = all pass)
#
# Covers worktree-aware resume: Test-IsWorktree, worktree detection in Resolve-PaneEntries
# (Get-SessionHome LastCwd), the restore banner/marker helpers, and the SessionStart-hook
# auto-offer. Module-private functions are invoked in module scope via `& (Get-Module ...) {}`.
$ErrorActionPreference = 'Stop'
$script:fails = 0
function Assert($cond, $msg) { if ($cond) { "  PASS: $msg" } else { "  FAIL: $msg"; $script:fails++ } }

Import-Module "$PSScriptRoot\..\src\ClaudeSessionRestore.psm1" -Force
$mod = Get-Module ClaudeSessionRestore

function New-GitWorktreeFixture {
    $base = Join-Path ([System.IO.Path]::GetTempPath()) ("csr-wt-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $repo = Join-Path $base 'main'
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    & git -C $repo init -q
    & git -C $repo -c user.email=t@t.dev -c user.name=tester commit -q --allow-empty -m init
    $wt = Join-Path $base 'wt-feature'
    & git -C $repo worktree add -q -b wtbranch $wt
    $plain = Join-Path $base 'plain'
    New-Item -ItemType Directory -Force -Path $plain | Out-Null
    return @{ Base=$base; Repo=$repo; Worktree=$wt; Plain=$plain }
}

Write-Host "=== Test-IsWorktree: linked worktree true, main repo false, non-git false ==="
$g = New-GitWorktreeFixture
$isWt   = & $mod { param($p) Test-IsWorktree -Path $p } $g.Worktree
$isMain = & $mod { param($p) Test-IsWorktree -Path $p } $g.Repo
$isPlain= & $mod { param($p) Test-IsWorktree -Path $p } $g.Plain
$isGone = & $mod { param($p) Test-IsWorktree -Path $p } (Join-Path $g.Base 'does-not-exist')
Assert ($isWt   -eq $true)  "linked git worktree is detected as a worktree"
Assert ($isMain -eq $false) "main working tree is NOT a worktree"
Assert ($isPlain -eq $false) "non-git directory is NOT a worktree"
Assert ($isGone -eq $false) "missing path is NOT a worktree"
Remove-Item -Recurse -Force $g.Base -ErrorAction SilentlyContinue

# --- Helpers for Resolve-PaneEntries worktree detection -----------------------------------
function New-Pane($paneId, $tabId, $title, $cwdPath, $top, $left) {
    $uri = 'file:///' + ($cwdPath -replace '\\','/') + '/'
    [PSCustomObject]@{ pane_id=$paneId; tab_id=$tabId; title=$title; cwd=$uri; top_row=$top; left_col=$left; window_id=0; is_active=$false }
}
function Set-PaneMap($root, $paneId, $uuid) {
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'pane-map') | Out-Null
    Set-Content -LiteralPath (Join-Path (Join-Path $root 'pane-map') "$paneId.session") -Value $uuid -NoNewline
}
# Write a session jsonl whose FIRST cwd is $homeCwd and LAST cwd is $lastCwd, mimicking a
# session that started at the repo root and entered a worktree mid-session. A leading envelope
# line carries no cwd (like real sessions); later lines embed a decoy "cwd" inside a string
# value to prove the parser reads the top-level field, not raw-text matches.
function Add-MultiCwdSession($root, $homeCwd, $lastCwd, $uuid, $slug) {
    $dir = Join-Path (Join-Path $root 'projects') ($homeCwd -replace '[^a-zA-Z0-9]','-')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $h = $homeCwd.Replace('\','\\'); $l = $lastCwd.Replace('\','\\')
    $decoy = ($lastCwd + '\nope').Replace('\','\\')
    $lines = @(
        '{"type":"summary","summary":"s"}'
        '{"cwd":"' + $h + '","slug":"' + $slug + '","sessionId":"' + $uuid + '"}'
        '{"type":"user","cwd":"' + $h + '","message":"ran with \"cwd\":\"' + $decoy + '\" in output"}'
        '{"type":"assistant","cwd":"' + $l + '"}'
    )
    Set-Content -LiteralPath (Join-Path $dir "$uuid.jsonl") -Value $lines
}
function Resolve-Entries($panes, $mux, $root) {
    $tabs = & $mod { param($wp,$mo,$cr) Resolve-PaneEntries -WindowPanes $wp -MuxOrigin $mo -ClaudeRoot $cr } $panes $mux $root
    ,@($tabs | ForEach-Object { $_.panes })
}

$mux = (Get-Date).AddMinutes(-5)
$U_WT='44444444-4444-4444-8444-444444444444'; $U_ROOT='55555555-5555-4555-8555-555555555555'

Write-Host "=== Resolve-PaneEntries: EnterWorktree-mid-session pane gets worktree=last, cwd=root ==="
$g2 = New-GitWorktreeFixture
$claude2 = Join-Path $g2.Base 'claude'
New-Item -ItemType Directory -Force -Path (Join-Path $claude2 'projects'),(Join-Path $claude2 'pane-map') | Out-Null
Add-MultiCwdSession $claude2 $g2.Repo $g2.Worktree $U_WT 'wtsess'
Set-PaneMap $claude2 30 $U_WT
$entryWt = (Resolve-Entries @((New-Pane 30 1 'Working in a worktree' $g2.Repo 0 0)) $mux $claude2)[0]
Assert ($entryWt.resume -eq $U_WT) "worktree session resumes by uuid"
Assert ($entryWt.cwd.TrimEnd('\') -eq $g2.Repo.TrimEnd('\')) "resume cwd is the ROOT (where --resume finds the session)"
Assert ($entryWt.worktree) "entry has a worktree field"
Assert ($entryWt.worktree -and $entryWt.worktree.TrimEnd('\') -eq $g2.Worktree.TrimEnd('\')) "worktree field is the LAST cwd (the worktree), not the decoy"

Write-Host "=== Resolve-PaneEntries: session that never left root has NO worktree field ==="
Add-MultiCwdSession $claude2 $g2.Repo $g2.Repo $U_ROOT 'rootsess'
Set-PaneMap $claude2 31 $U_ROOT
$entryRoot = (Resolve-Entries @((New-Pane 31 1 'Plain root session' $g2.Repo 0 0)) $mux $claude2)[0]
Assert ($entryRoot.resume -eq $U_ROOT) "root session resumes by uuid"
Assert (-not $entryRoot.Contains('worktree')) "no worktree field when first cwd == last cwd"
Remove-Item -Recurse -Force $g2.Base -ErrorAction SilentlyContinue

Write-Host "=== Set-WorktreeMarker: writes <session-id> = path, prunes markers older than 24h ==="
$mroot = Join-Path ([System.IO.Path]::GetTempPath()) ("csr-mk-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path (Join-Path $mroot 'worktree-restore') | Out-Null
$staleMarker = Join-Path (Join-Path $mroot 'worktree-restore') 'old-session-id'
Set-Content -LiteralPath $staleMarker -Value 'C:\old\wt' -NoNewline
(Get-Item $staleMarker).LastWriteTime = (Get-Date).AddHours(-30)
$SID = 'aeaa89bb-670d-404b-8663-cc7695fc10d8'
$markerPath = & $mod { param($r,$s,$p) Set-WorktreeMarker -ClaudeRoot $r -SessionId $s -WorktreePath $p } $mroot $SID 'C:\repo\.worktrees\sc-99'
Assert (Test-Path -LiteralPath $markerPath) "marker file written"
Assert ((Get-Content -LiteralPath $markerPath -Raw).Trim() -eq 'C:\repo\.worktrees\sc-99') "marker content is the worktree path"
Assert ((Split-Path -Leaf $markerPath) -eq $SID) "marker filename is the session id"
Assert (-not (Test-Path -LiteralPath $staleMarker)) "marker older than 24h is pruned"
Remove-Item -Recurse -Force $mroot -ErrorAction SilentlyContinue

Write-Host "=== Update-PaneMap hook: marker present -> additionalContext + one-shot delete ==="
# Invoke the hook as a child process (how Claude Code runs it). Clear WEZTERM_PANE so the child
# skips the pane-map write (we are inside a real pane — must not touch the live pane-map), and
# point the marker dir at a temp location via the marker-only override.
$hookPath = Join-Path $PSScriptRoot '..\hooks\Update-PaneMap.ps1'
$hk = Join-Path ([System.IO.Path]::GetTempPath()) ("csr-hk-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$mkdir = Join-Path $hk 'worktree-restore'
New-Item -ItemType Directory -Force -Path $mkdir | Out-Null
$savedPane = $env:WEZTERM_PANE; $savedMk = $env:CLAUDE_WORKTREE_MARKER_DIR
$env:WEZTERM_PANE = ''
$env:CLAUDE_WORKTREE_MARKER_DIR = $mkdir
try {
    $sidHit = '66666666-6666-4666-8666-666666666666'
    Set-Content -LiteralPath (Join-Path $mkdir $sidHit) -Value 'C:\repo\.worktrees\sc-77' -NoNewline
    $outHit = (('{"session_id":"' + $sidHit + '","source":"resume"}') | & pwsh -NoProfile -File $hookPath | Out-String)
    Assert ($outHit -match 'additionalContext') "hook emits additionalContext when a marker is present"
    Assert ($outHit -match 'sc-77') "additionalContext names the worktree leaf"
    Assert ($outHit -match 'switch-worktree') "additionalContext names the switch-worktree skill"
    Assert ($outHit -match 'automatically' -and $outHit -match 'without asking') "additionalContext directs an automatic re-entry (not just an offer)"
    Assert (-not (Test-Path -LiteralPath (Join-Path $mkdir $sidHit))) "marker is deleted after emission (one-shot)"

    $sidMiss = '77777777-7777-4777-8777-777777777777'
    $outMiss = (('{"session_id":"' + $sidMiss + '","source":"resume"}') | & pwsh -NoProfile -File $hookPath | Out-String).Trim()
    Assert ($outMiss -eq '{}') "hook emits bare {} when no marker present"
} finally {
    $env:WEZTERM_PANE = $savedPane
    $env:CLAUDE_WORKTREE_MARKER_DIR = $savedMk
    Remove-Item -Recurse -Force $hk -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fails -eq 0) { "ALL TESTS PASSED"; exit 0 } else { "FAILED: $script:fails assertion(s)"; exit 1 }
