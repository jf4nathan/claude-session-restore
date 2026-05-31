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
