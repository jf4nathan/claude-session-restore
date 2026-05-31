# Update-PaneMap.ps1
# Invoked as a Claude Code SessionStart hook. Reads the event JSON from stdin,
# extracts the session_id, and (if WEZTERM_PANE is set) writes:
#   ~/.claude/pane-map/<WEZTERM_PANE>.session  =>  <session-id>
# Save-Claude reads this map at save time to record which session is in which pane.
#
# Silent on any error: never blocks Claude startup. Logs to ~/.claude/backups/pane-map.log.

$ErrorActionPreference = 'SilentlyContinue'
$logPath = "$HOME\.claude\backups\pane-map.log"
$ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

function Write-LogLine {
    param([string]$Message)
    try { Add-Content -LiteralPath $logPath -Value "$ts $Message" } catch { }
}

# Rotate log if oversized (keep last 500 lines)
try {
    if (Test-Path $logPath) {
        $f = Get-Item $logPath
        if ($f.Length -gt 100000) {
            $tail = Get-Content -LiteralPath $logPath -Tail 500
            Set-Content -LiteralPath $logPath -Value $tail
        }
    }
} catch { }

# Always read stdin to drain it (avoids blocking Claude)
$raw = ""
try { $raw = [Console]::In.ReadToEnd() } catch { }

# Hook only matters when running inside a WezTerm pane
if (-not $env:WEZTERM_PANE) {
    Write-LogLine "skip: WEZTERM_PANE not set"
    exit 0
}

if (-not $raw) {
    Write-LogLine "skip: empty stdin (pane=$env:WEZTERM_PANE)"
    exit 0
}

try {
    $event = $raw | ConvertFrom-Json
} catch {
    Write-LogLine ("skip: stdin not JSON (pane=$env:WEZTERM_PANE): " + $_.Exception.Message)
    exit 0
}

$sessionId = $event.session_id
if (-not $sessionId) {
    Write-LogLine "skip: no session_id in event (pane=$env:WEZTERM_PANE)"
    exit 0
}

$mapDir = "$HOME\.claude\pane-map"
try {
    New-Item -ItemType Directory -Force -Path $mapDir -ErrorAction Stop | Out-Null
} catch {
    Write-LogLine ("ERROR: cannot create pane-map dir: " + $_.Exception.Message)
    exit 0
}

$mapFile = Join-Path $mapDir ($env:WEZTERM_PANE + ".session")
try {
    Set-Content -LiteralPath $mapFile -Value $sessionId -NoNewline -ErrorAction Stop
    $src = if ($event.source) { $event.source } else { "<unknown>" }
    Write-LogLine "wrote pane=$env:WEZTERM_PANE session=$sessionId source=$src"
} catch {
    Write-LogLine ("ERROR: cannot write pane-map file: " + $_.Exception.Message)
}

# Prune pane-map files left over from previous WezTerm generations. WezTerm reuses
# pane IDs across restarts but these .session files persist, so a stale file points at
# a dead pane and would mislead Save-Claude into resuming the wrong session. Delete any
# file written before the current mux started — anchored to the earliest-running
# wezterm-mux-server (persistent daemon, if any) or wezterm-gui. If a mux-server has been
# up for days, its long-lived pane IDs are still valid and their (old) maps are KEPT.
# This pane's file was just written (newer than the mux), so it is never pruned.
# Best-effort and silent; never blocks startup.
try {
    $muxOrigin = (Get-Process wezterm-mux-server, wezterm-gui -ErrorAction SilentlyContinue |
        Sort-Object StartTime | Select-Object -First 1).StartTime
    if ($muxOrigin) {
        $stale = Get-ChildItem -LiteralPath $mapDir -Filter '*.session' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $muxOrigin }
        foreach ($s in $stale) { Remove-Item -LiteralPath $s.FullName -Force -ErrorAction SilentlyContinue }
        if ($stale.Count -gt 0) {
            Write-LogLine ("pruned {0} stale pane-map file(s) older than mux start {1}" -f $stale.Count, $muxOrigin.ToString('yyyy-MM-dd HH:mm:ss'))
        }
    }
} catch { }

# Empty JSON output so Claude treats it as a successful no-op hook
'{}'
