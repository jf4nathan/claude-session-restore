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
