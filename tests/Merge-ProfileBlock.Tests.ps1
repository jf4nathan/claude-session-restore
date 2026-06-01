# Merge-ProfileBlock.Tests.ps1 — plain-PowerShell tests (no Pester).
# Run: pwsh -File tests/Merge-ProfileBlock.Tests.ps1   (exit 0 = all pass)
#
# Merge-ProfileBlock lives in install/Install.ps1. Dot-sourcing Install.ps1 defines its functions
# without running the installer (the bottom guard only runs when NOT dot-sourced).
$ErrorActionPreference = 'Stop'
$script:fails = 0
function Assert($cond, $msg) { if ($cond) { "  PASS: $msg" } else { "  FAIL: $msg"; $script:fails++ } }

. "$PSScriptRoot\..\install\Install.ps1"

$BEGIN = '# >>> claude-session-restore (managed) >>>'
$END   = '# <<< claude-session-restore <<<'
# A block containing $env: — must survive verbatim (no regex $-group mangling).
$block = @'
$ClaudeSessionRestoreModule = "C:\repo\src\ClaudeSessionRestore.psm1"
if ($env:CLAUDE_RESTORE_PROMPT) { claude --resume $env:CLAUDE_RESTORE_NAME $env:CLAUDE_RESTORE_PROMPT }
'@

Write-Host "=== absent markers -> block appended, original preserved ==="
$orig = "function claude { 'x' }`nSet-Alias cc claude`n"
$r1 = Merge-ProfileBlock -Content $orig -Block $block -BeginMarker $BEGIN -EndMarker $END
Assert ($r1 -match [regex]::Escape('function claude')) "original content preserved"
Assert ($r1 -match [regex]::Escape($BEGIN) -and $r1 -match [regex]::Escape($END)) "markers added"
Assert ($r1 -match [regex]::Escape('$env:CLAUDE_RESTORE_PROMPT')) "block body present verbatim (no \$ mangling)"
Assert ((([regex]::Matches($r1, [regex]::Escape($BEGIN))).Count) -eq 1) "exactly one begin marker"

Write-Host "=== present markers -> content between markers replaced, not duplicated ==="
$newBlock = "claude --resume `$env:CLAUDE_RESTORE_NAME   # v2"
$r2 = Merge-ProfileBlock -Content $r1 -Block $newBlock -BeginMarker $BEGIN -EndMarker $END
Assert ((([regex]::Matches($r2, [regex]::Escape($BEGIN))).Count) -eq 1) "still exactly one begin marker (no duplicate block)"
Assert ($r2 -match [regex]::Escape('# v2')) "new block content present"
Assert (-not ($r2 -match [regex]::Escape('ClaudeSessionRestoreModule'))) "old block content replaced"
Assert ($r2 -match [regex]::Escape('function claude')) "surrounding content still preserved"

Write-Host "=== idempotent: merging same block twice is stable ==="
$a = Merge-ProfileBlock -Content $orig -Block $block -BeginMarker $BEGIN -EndMarker $END
$b = Merge-ProfileBlock -Content $a    -Block $block -BeginMarker $BEGIN -EndMarker $END
Assert ($a -eq $b) "second merge of identical block is a no-op"

Write-Host ""
if ($script:fails -eq 0) { "ALL TESTS PASSED"; exit 0 } else { "FAILED: $script:fails assertion(s)"; exit 1 }
