# Update-PaneMap.ps1
# Invoked as a Claude Code SessionStart hook. Reads the event JSON from stdin and:
#   1. (worktree-aware resume) If a one-shot marker ~/.claude/worktree-restore/<session-id> exists,
#      emits SessionStart additionalContext telling Claude the session was restored from the repo
#      root but last worked in a git worktree, and to offer /switch-worktree — then deletes the
#      marker. Runs regardless of WEZTERM_PANE (it concerns the session, not the pane).
#   2. (pane mapping) If WEZTERM_PANE is set, writes ~/.claude/pane-map/<WEZTERM_PANE>.session =>
#      <session-id>, which Save-Claude reads to record which session is in which pane, and prunes
#      pane-map files left over from previous WezTerm generations.
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

if (-not $raw) { Write-LogLine "skip: empty stdin (pane=$env:WEZTERM_PANE)"; '{}'; exit 0 }

try {
    $event = $raw | ConvertFrom-Json
} catch {
    Write-LogLine ("skip: stdin not JSON (pane=$env:WEZTERM_PANE): " + $_.Exception.Message)
    '{}'; exit 0
}

$sessionId = $event.session_id
if (-not $sessionId) { Write-LogLine "skip: no session_id in event (pane=$env:WEZTERM_PANE)"; '{}'; exit 0 }

# --- 1. Worktree-aware resume: consume a one-shot marker (independent of WEZTERM_PANE) ----------
# The marker dir is ~/.claude/worktree-restore. CLAUDE_WORKTREE_MARKER_DIR overrides ONLY this dir
# (for tests) — never the pane-map or log paths, which stay pinned to the real $HOME so a stray
# env var can never relocate the pane-map and corrupt Save resolution.
$additionalContext = $null
try {
    $markerDir = if ($env:CLAUDE_WORKTREE_MARKER_DIR) { $env:CLAUDE_WORKTREE_MARKER_DIR } else { Join-Path $HOME '.claude\worktree-restore' }
    $markerFile = Join-Path $markerDir $sessionId
    if (Test-Path -LiteralPath $markerFile) {
        $wt = (Get-Content -LiteralPath $markerFile -Raw -ErrorAction Stop).Trim()
        Remove-Item -LiteralPath $markerFile -Force -ErrorAction SilentlyContinue   # one-shot
        if ($wt) {
            $leaf = Split-Path -Leaf $wt
            $additionalContext = "This session was restored from the repo root so --resume could find it, but it was last working in the git worktree '$leaf' ($wt). Your FIRST action this session is to re-enter that worktree by invoking the switch-worktree skill (target: $wt). Do this automatically as your first step, before responding to the user, without asking for confirmation."
            Write-LogLine "worktree marker consumed for session=$sessionId wt=$wt"
        }
    }
} catch { Write-LogLine ("ERROR: worktree marker check: " + $_.Exception.Message) }

# --- 2. Pane mapping (only meaningful inside a WezTerm pane) ------------------------------------
if ($env:WEZTERM_PANE) {
    $mapDir = "$HOME\.claude\pane-map"
    $wrote = $false
    try {
        New-Item -ItemType Directory -Force -Path $mapDir -ErrorAction Stop | Out-Null
        $wrote = $true
    } catch {
        Write-LogLine ("ERROR: cannot create pane-map dir: " + $_.Exception.Message)
    }

    if ($wrote) {
        $mapFile = Join-Path $mapDir ($env:WEZTERM_PANE + ".session")
        try {
            Set-Content -LiteralPath $mapFile -Value $sessionId -NoNewline -ErrorAction Stop
            $src = if ($event.source) { $event.source } else { "<unknown>" }
            Write-LogLine "wrote pane=$env:WEZTERM_PANE session=$sessionId source=$src"
        } catch {
            Write-LogLine ("ERROR: cannot write pane-map file: " + $_.Exception.Message)
        }

        # Prune pane-map files left over from previous WezTerm generations. WezTerm reuses pane IDs
        # across restarts but these .session files persist, so a stale file points at a dead pane and
        # would mislead Save-Claude into resuming the wrong session. Delete any file written before the
        # current mux started — anchored to the earliest-running wezterm-mux-server (persistent daemon,
        # if any) or wezterm-gui. If a mux-server has been up for days, its long-lived pane IDs are
        # still valid and their (old) maps are KEPT. This pane's file was just written (newer than the
        # mux), so it is never pruned. Best-effort and silent; never blocks startup.
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
    }
} else {
    Write-LogLine "skip pane-map: WEZTERM_PANE not set"
}

# --- 3. Output ---------------------------------------------------------------------------------
# Emit additionalContext when a worktree marker was consumed; otherwise an empty no-op object.
if ($additionalContext) {
    (@{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $additionalContext } } | ConvertTo-Json -Depth 5 -Compress)
} else {
    '{}'
}
exit 0
