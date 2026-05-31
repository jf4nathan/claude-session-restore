# Resolve-PaneEntries.Tests.ps1 — plain-PowerShell tests (no Pester).
# Run: pwsh -File tests/Resolve-PaneEntries.Tests.ps1   (exit 0 = all pass)
#
# Resolve-PaneEntries is module-PRIVATE, so we Import-Module and invoke it inside the
# module's scope via `& (Get-Module ...) { ... }` (dot-sourcing a .psm1 does NOT define
# its functions in the caller scope).
$ErrorActionPreference = 'Stop'
$script:fails = 0
function Assert($cond, $msg) { if ($cond) { "  PASS: $msg" } else { "  FAIL: $msg"; $script:fails++ } }

Import-Module "$PSScriptRoot\..\src\ClaudeSessionRestore.psm1" -Force
$mod = Get-Module ClaudeSessionRestore
function Invoke-Resolve($panes, $mux, $root) {
    & $mod { param($wp, $mo, $cr) Resolve-PaneEntries -WindowPanes $wp -MuxOrigin $mo -ClaudeRoot $cr } $panes $mux $root
}

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
Set-PaneMap $f.Root 10 $EMP1   # empty (no jsonl) - sorted FIRST
Set-PaneMap $f.Root 11 $REAL   # valid
Set-PaneMap $f.Root 12 $EMP2   # empty (no jsonl)
$panes = @(
    (New-Pane 10 1 'Doing some empty thing' $f.Work 0 0),
    (New-Pane 11 1 'The real session'        $f.Work 0 1),
    (New-Pane 12 1 'Another empty thing'     $f.Work 0 2)
)
$entries = Get-Entries (Invoke-Resolve $panes $mux $f.Root)
$resumeIds = @($entries | Where-Object { $_.resume } | ForEach-Object { $_.resume })
$dups = @($resumeIds | Group-Object | Where-Object Count -gt 1)
Assert ($dups.Count -eq 0) "no duplicate resume IDs (got: $($resumeIds -join ', '))"
Assert (@($resumeIds | Where-Object { $_ -eq $REAL }).Count -eq 1) "the one real session resumes exactly once"
Assert ((@($entries | Where-Object { $_.fresh }).Count) -eq 2) "the two empty-startup panes are fresh"
Remove-Item -Recurse -Force $f.Base -ErrorAction SilentlyContinue

Write-Host "=== Case 2: control - three valid distinct maps each resume their own session ==="
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
$ids2 = @((Get-Entries (Invoke-Resolve $panes2 $mux $f2.Root)) | Where-Object { $_.resume } | ForEach-Object { $_.resume })
Assert ($ids2.Count -eq 3) "all three panes resume (got $($ids2.Count))"
Assert ((@($ids2 | Sort-Object -Unique).Count) -eq 3) "three DISTINCT sessions resumed"
Remove-Item -Recurse -Force $f2.Base -ErrorAction SilentlyContinue

Write-Host ""
if ($script:fails -eq 0) { "ALL TESTS PASSED"; exit 0 } else { "FAILED: $script:fails assertion(s)"; exit 1 }
