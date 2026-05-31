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
