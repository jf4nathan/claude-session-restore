# Install.ps1
# Installs (or removes) the Windows scheduled task that runs the auto-save VBS wrapper
# (Run-SaveClaudeAuto.vbs -> Save-ClaudeAuto.ps1) every N minutes (default: 5). Idempotent.
# Self-locating: works regardless of where the repo is cloned.

function Merge-ProfileBlock {
    # Idempotently splice $Block between $BeginMarker/$EndMarker in $Content. Replace the region if
    # the markers are already present, else append. Pure string ops (IndexOf/Substring) — never regex
    # replace, so a block body containing '$env:...' / '$1' survives verbatim (no group-ref mangling).
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$Block,
        [Parameter(Mandatory)][string]$BeginMarker,
        [Parameter(Mandatory)][string]$EndMarker
    )
    $wrapped = $BeginMarker + "`n" + $Block.Trim() + "`n" + $EndMarker
    $bi = $Content.IndexOf($BeginMarker)
    if ($bi -ge 0) {
        $ei = $Content.IndexOf($EndMarker, $bi)
        if ($ei -gt $bi) {
            $before = $Content.Substring(0, $bi).TrimEnd()
            $after  = $Content.Substring($ei + $EndMarker.Length).Trim()
            $out = if ($before) { $before + "`n`n" + $wrapped } else { $wrapped }
            if ($after) { $out += "`n`n" + $after }
            return $out + "`n"
        }
    }
    $base = $Content.TrimEnd()
    if ($base) { return $base + "`n`n" + $wrapped + "`n" }
    return $wrapped + "`n"
}

function Install-ClaudeProfileBlock {
    # Ensure the WezTerm auto-launch block (module import + restore-aware claude launch, including
    # CLAUDE_RESTORE_PROMPT for zero-touch worktree switch) exists in the profile. Idempotent via
    # sentinel markers. Targets the Windows PowerShell 5.1 CurrentUserCurrentHost profile, because
    # Restore spawns panes with powershell.exe (5.1) whose $PROFILE is this file — the installer
    # itself may run under pwsh 7, so $PROFILE here would be the wrong file.
    [CmdletBinding()]
    param(
        [string]$ProfilePath = (Join-Path $HOME 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
        [switch]$PreviewOnly
    )
    $repoRoot   = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path.TrimEnd('\','/')
    $modulePath = Join-Path $repoRoot 'src\ClaudeSessionRestore.psm1'
    $begin = '# >>> claude-session-restore (managed by install/Install.ps1) >>>'
    $end   = '# <<< claude-session-restore <<<'

    $block = @"
`$ClaudeSessionRestoreModule = "$modulePath"
if (Test-Path `$ClaudeSessionRestoreModule) { Import-Module `$ClaudeSessionRestoreModule }
if (`$env:TERM_PROGRAM -eq "WezTerm" -and -not `$env:CLAUDE_NO_AUTOLAUNCH) {
    if (`$env:CLAUDE_RESTORE_NAME) {
        if (`$env:CLAUDE_RESTORE_PROMPT) {
            claude --resume `$env:CLAUDE_RESTORE_NAME `$env:CLAUDE_RESTORE_PROMPT
        } else {
            claude --resume `$env:CLAUDE_RESTORE_NAME
        }
    } elseif (`$env:CLAUDE_RESTORE_CONTINUE -eq "1") {
        claude --continue
    } else {
        claude
    }
}
"@

    $existing = if (Test-Path -LiteralPath $ProfilePath) { (Get-Content -LiteralPath $ProfilePath -Raw) } else { "" }
    if (-not $existing) { $existing = "" }

    # Guard: a legacy UNMARKED auto-launch would double-launch claude if we appended ours.
    if (($existing.IndexOf($begin) -lt 0) -and ($existing -match 'CLAUDE_RESTORE_NAME')) {
        Write-Warning "Profile has an unmarked CLAUDE_RESTORE_NAME auto-launch block: $ProfilePath"
        Write-Warning "Leaving it untouched (appending would double-launch). To let the installer manage it,"
        Write-Warning "wrap that block in these two lines, then re-run:"
        Write-Warning "    $begin"
        Write-Warning "    $end"
        return
    }

    $merged = Merge-ProfileBlock -Content $existing -Block $block -BeginMarker $begin -EndMarker $end
    if ($merged -eq $existing) { Write-Host "Profile auto-launch block already current: $ProfilePath" -ForegroundColor DarkGray; return }
    if ($PreviewOnly) { Write-Host "--- would write to $ProfilePath ---" -ForegroundColor Yellow; Write-Host $merged; return }

    $dir = Split-Path -Parent $ProfilePath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path -LiteralPath $ProfilePath) {
        $backupDir = Join-Path $HOME '.claude\backups'
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $ProfilePath -Destination (Join-Path $backupDir "Microsoft.PowerShell_profile.ps1.$stamp.bak") -Force
    }
    Set-Content -LiteralPath $ProfilePath -Value $merged -NoNewline
    Write-Host "Updated auto-launch block in $ProfilePath" -ForegroundColor Green
}

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

    # Ensure the profile auto-launch block (idempotent; backs up + guards against legacy duplicates).
    Install-ClaudeProfileBlock

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
