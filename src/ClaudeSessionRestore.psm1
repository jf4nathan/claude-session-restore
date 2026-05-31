# ClaudeSessionRestore.psm1
# Save and restore a WezTerm window full of Claude Code panes.
# Exports: Save-ClaudeSession (claude-save), Restore-ClaudeSession (claude-restore),
#          Get-ClaudeSession. Operates entirely on ~/.claude/ — no install-path knowledge.

function Resolve-PaneEntries {
    param(
        [object[]]$WindowPanes,
        $MuxOrigin,
        [string]$ClaudeRoot = (Join-Path $HOME '.claude')
    )

    # Build per-CWD session lists (slug, mtime desc). Used to disambiguate when
    # a pane's title isn't a real session slug.
    $cwdSessions = @{}

    function Get-CwdSessions {
        param([string]$Cwd)
        if (-not $Cwd) { return @() }
        if ($cwdSessions.ContainsKey($Cwd)) { return $cwdSessions[$Cwd] }

        $resolved = (Resolve-Path -LiteralPath $Cwd -ErrorAction SilentlyContinue)
        if (-not $resolved) { $cwdSessions[$Cwd] = @(); return @() }
        # Match Claude's project-dir naming: every non-alphanumeric char -> '-'.
        # Do NOT trim a trailing separator first: Claude encodes it (e.g. 'Z:\' -> 'Z--',
        # two dashes for colon+backslash). Trimming produced 'Z-' and the dir never matched.
        # The old class '[:\\/ ]' also missed '.', so '.claude' mismatched ('-.claude' vs '--claude').
        $projectSlug = ($resolved.Path -replace '[^a-zA-Z0-9]', '-')
        $projectDir = Join-Path (Join-Path $ClaudeRoot 'projects') $projectSlug
        if (-not (Test-Path -LiteralPath $projectDir)) {
            $cwdSessions[$Cwd] = @(); return @()
        }

        # Each entry is a PSCustomObject with SessionId (UUID, the canonical resume handle)
        # and Slug (auto-generated label, for display only). Sorted by mtime desc.
        $list = @()
        $files = Get-ChildItem -LiteralPath $projectDir -Filter '*.jsonl' -File |
            Sort-Object LastWriteTime -Descending
        foreach ($f in $files) {
            $sessionId = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            $slugVal = $null
            $reader = [System.IO.StreamReader]::new($f.FullName)
            try {
                $lineNum = 0
                while ($lineNum -lt 100 -and ($line = $reader.ReadLine())) {
                    $lineNum++
                    if ($line -match '"slug"\s*:\s*"([^"]+)"') {
                        $slugVal = $matches[1]; break
                    }
                }
            } finally { $reader.Dispose() }
            $list += [PSCustomObject]@{
                SessionId = $sessionId
                Slug      = $slugVal
            }
        }
        $cwdSessions[$Cwd] = $list
        return $list
    }

    function Use-CwdSession {
        param([string]$Cwd, [string]$PreferredSlug)
        $list = Get-CwdSessions -Cwd $Cwd
        if ($list.Count -eq 0) { return $null }
        $picked = $null
        if ($PreferredSlug) {
            $picked = $list | Where-Object { $_.Slug -eq $PreferredSlug } | Select-Object -First 1
        }
        if (-not $picked) {
            $picked = $list[0]
        }
        $cwdSessions[$Cwd] = @($list | Where-Object { $_.SessionId -ne $picked.SessionId })
        return $picked
    }

    # Locate a session UUID's home: the project dir its <uuid>.jsonl actually lives in,
    # plus the launch cwd recorded inside that file. A pane's terminal cwd often differs
    # from where its Claude session was launched (e.g. the pane cd'd into a plugin dir, or
    # an MCP server changed cwd), so we can't assume the session lives under the pane's cwd.
    # Returns @{ SessionId; Slug; Cwd } (Cwd = the real launch dir to resume from), or $null.
    function Get-SessionHome {
        param([string]$SessionId)
        if ($SessionId -notmatch '^[0-9a-fA-F-]{36}$') { return $null }
        $hit = Get-ChildItem -Path (Join-Path (Join-Path $ClaudeRoot 'projects') "*\$SessionId.jsonl") -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $hit) { return $null }

        $homeCwd = $null; $slugVal = $null
        $reader = [System.IO.StreamReader]::new($hit.FullName)
        try {
            $lineNum = 0
            while ($lineNum -lt 100 -and ($line = $reader.ReadLine())) {
                $lineNum++
                if (-not $homeCwd -and $line -match '"cwd"\s*:\s*"([^"]+)"') {
                    # JSON-unescape: '\\' -> '\'. (Windows session cwds carry no other escapes.)
                    $homeCwd = $matches[1].Replace('\\', '\')
                }
                if (-not $slugVal -and $line -match '"slug"\s*:\s*"([^"]+)"') { $slugVal = $matches[1] }
                if ($homeCwd -and $slugVal) { break }
            }
        } finally { $reader.Dispose() }
        if (-not $homeCwd) { return $null }

        return [PSCustomObject]@{ SessionId = $SessionId; Slug = $slugVal; Cwd = $homeCwd }
    }

    # Pane-map lookup: returns the session the SessionStart hook recorded for this pane —
    # an exact, deterministic mapping — resolved to its real home dir. Marks the session
    # consumed in its HOME cwd list so the most-recent fallback can't double-assign it to
    # another pane that happens to sit in that same dir. $null if no mapping or the mapped
    # session's jsonl no longer exists anywhere.
    function Use-PaneMappedSession {
        param([int]$PaneId)
        $mapFile = Join-Path (Join-Path $ClaudeRoot 'pane-map') "$PaneId.session"
        if (-not (Test-Path -LiteralPath $mapFile)) { return $null }

        # Reject a map file from a previous WezTerm generation (reused pane ID): if it
        # was last written before the current mux started, the pane it described is gone.
        if ($muxOrigin -and (Get-Item -LiteralPath $mapFile).LastWriteTime -lt $muxOrigin) {
            Write-Warning ("  pane {0}: pane-map is stale (predates current WezTerm); ignoring, will guess by cwd/title." -f $PaneId)
            return $null
        }

        $sessionId = (Get-Content -LiteralPath $mapFile -Raw -ErrorAction SilentlyContinue).Trim()
        if (-not $sessionId) { return $null }

        $sess = Get-SessionHome -SessionId $sessionId
        if (-not $sess) { return $null }

        # Consume from the session's home cwd list (best-effort; cache is keyed by cwd
        # string, so a differently-spelled cwd elsewhere may not see the consumption).
        $list = Get-CwdSessions -Cwd $sess.Cwd
        if ($list.Count -gt 0) {
            $cwdSessions[$sess.Cwd] = @($list | Where-Object { $_.SessionId -ne $sessionId })
        }
        return $sess
    }

    # Group by tab_id, preserve tab insertion order
    $tabIds = $windowPanes | Select-Object -ExpandProperty tab_id -Unique
    $tabs = @()
    foreach ($tid in $tabIds) {
        $tabPanes = $windowPanes |
            Where-Object { $_.tab_id -eq $tid } |
            Sort-Object top_row, left_col

        $paneEntries = @()
        $prev = $null
        foreach ($p in $tabPanes) {
            # Strip leading symbols/glyphs/whitespace that Claude prepends to pane titles.
            # Pattern is pure ASCII; .NET regex resolves \uXXXX at regex-compile time so the
            # source file's encoding doesn't matter (PS 5.1 reads no-BOM .ps1 as Win-1252).
            # Covers Misc Symbols (2600-26FF), Dingbats (2700-27BF), Braille (2800-28FF).
            $rawTitle = if ($null -ne $p.title) { [string]$p.title } else { '' }
            $title = ($rawTitle -replace '^[\u2600-\u27BF\u2800-\u28FF\s]+', '').Trim()
            if (-not $title) { $title = "<untitled>" }

            $cwd = $null
            if ($p.cwd) {
                # cwd is a file:// URI like file:///C:/Users/jonat/Desktop/...
                # Trim trailing slash: a trailing backslash before a closing quote
                # becomes a backslash-escaped quote in Windows command-line parsing,
                # corrupting the wezterm --cwd argument at restore time.
                $u = [System.Uri]$p.cwd
                $cwd = [System.Uri]::UnescapeDataString($u.AbsolutePath).TrimStart('/').Replace('/', '\').TrimEnd('\')
            }

            $direction = $null
            if ($prev) {
                if ($p.top_row -eq $prev.top_row -and $p.left_col -gt $prev.left_col) {
                    $direction = "right"
                } elseif ($p.top_row -gt $prev.top_row) {
                    $direction = "bottom"
                } else {
                    Write-Warning ("Tab {0}: unusual layout for pane {1}, defaulting to 'right'." -f $tid, $p.pane_id)
                    $direction = "right"
                }
            }

            # Resolve a session for this pane. We store the SessionId (UUID) since
            # `claude --resume <name>` only matches user-set names, not auto-generated
            # slugs — but `claude --resume <uuid>` always works.
            #   1. Check the SessionStart-hook pane-map (~/.claude/pane-map/<id>.session)
            #      — exact, deterministic mapping if present
            #   2. Fall back to title-slug match in this CWD
            #   3. Final fallback: next-most-recent unassigned session in this CWD
            # A pane whose title is an exe name/path (e.g. 'powershell.EXE',
            # 'C:\...\powershell.EXE', 'where.exe') or is untitled is a plain shell —
            # Claude has exited there. Match only an '.exe' suffix or '<untitled>': a
            # full exe path still ends in '.exe', while a session-summary title that
            # merely contains a slash (e.g. 'Refactor src/utils') is NOT a shell.
            $looksLikeShell = ($title -match '\.exe$') -or ($title -eq '<untitled>')

            # $resumeCwd is the directory restore will spawn from. For a pane-mapped
            # session it's the session's REAL home dir (which may differ from the pane's
            # terminal cwd); otherwise it's the pane's own cwd.
            $picked = $null
            $resumeCwd = $cwd
            if (-not $looksLikeShell) {
                # Tier-a (pane-map): an exact, recorded mapping for a live Claude pane —
                # honour it regardless of whether the session lives under this pane's cwd.
                $picked = Use-PaneMappedSession -PaneId $p.pane_id
                if ($picked) {
                    if ($picked.Cwd) { $resumeCwd = $picked.Cwd }
                } elseif ($cwd) {
                    # Tier-b/c: no pane-map — guess by title-slug / most-recent in this cwd.
                    $picked = Use-CwdSession -Cwd $cwd -PreferredSlug $title
                }
            }

            $entry = [ordered]@{
                title               = $title
                cwd                 = if ($picked) { $resumeCwd } else { $cwd }
                split_from_previous = $direction
            }
            if ($picked) {
                $entry.resume = $picked.SessionId
                if ($picked.Slug) { $entry.resume_slug = $picked.Slug }
            } elseif ($looksLikeShell) {
                # No session to resume; open a fresh claude rather than --continue
                # (which would silently grab this cwd's newest unrelated session).
                $entry.fresh = $true
            } else {
                # Couldn't pin a specific session. If this cwd still has an unassigned
                # session, --continue (newest) is a defensible guess. But if every
                # session here is already claimed by another pane, --continue would
                # just reopen one of them — N panes collapsing onto one session — so
                # open fresh instead.
                $remaining = @(Get-CwdSessions -Cwd $cwd)
                if ($remaining.Count -gt 0) { $entry.continue = $true } else { $entry.fresh = $true }
            }
            $paneEntries += $entry
            $prev = $p
        }

        # Tab title heuristic: first pane's directory leaf
        $tabTitle = if ($tabPanes[0].cwd) {
            $u = [System.Uri]$tabPanes[0].cwd
            $decoded = [System.Uri]::UnescapeDataString($u.AbsolutePath).TrimEnd('/')
            ($decoded -split '/')[-1]
        } else { "tab-$tid" }

        $tabs += [ordered]@{
            tab_title = $tabTitle
            panes     = $paneEntries
        }
    }

    return $tabs
}

function Save-ClaudeSession {
    [CmdletBinding()]
    param(
        [string]$Profile = "default",
        [string]$ManifestPath = "$HOME\.claude\sessions.json",
        [int]$WindowId = -1   # -1 means: use the window with the active pane
    )

    if (-not (Get-Command wezterm.exe -ErrorAction SilentlyContinue)) {
        Write-Error "wezterm.exe not found on PATH."
        return
    }

    $listJson = & wezterm.exe cli list --format json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $listJson) {
        Write-Error "wezterm cli list failed. Is WezTerm running?"
        return
    }

    $panes = $listJson | ConvertFrom-Json
    if (-not $panes) {
        Write-Error "wezterm cli list returned no panes."
        return
    }

    # WezTerm reuses pane IDs across restarts, but the SessionStart-hook pane-map files
    # (~/.claude/pane-map/<id>.session) persist on disk. A map file written by a PRIOR
    # WezTerm generation points at a long-dead session, so trusting it would resume the
    # wrong session with false confidence. Anchor "current" to the mux that owns pane IDs:
    # the earliest-started wezterm-mux-server (if running) or wezterm-gui process. A map
    # file older than that mux belongs to a previous generation and is ignored.
    $muxOrigin = $null
    try {
        $muxOrigin = (Get-Process wezterm-mux-server, wezterm-gui -ErrorAction SilentlyContinue |
            Sort-Object StartTime | Select-Object -First 1).StartTime
    } catch { $muxOrigin = $null }

    # Pick window: explicit, or the one containing the active pane
    if ($WindowId -lt 0) {
        $activePane = $panes | Where-Object { $_.is_active } | Select-Object -First 1
        if (-not $activePane) {
            $WindowId = ($panes | Select-Object -First 1).window_id
        } else {
            $WindowId = $activePane.window_id
        }
    }

    $otherWindows = $panes | Where-Object { $_.window_id -ne $WindowId } | Select-Object -ExpandProperty window_id -Unique
    if ($otherWindows) {
        Write-Warning ("Saving window {0} only. Other windows ignored: {1}" -f $WindowId, ($otherWindows -join ', '))
    }

    $windowPanes = $panes | Where-Object { $_.window_id -eq $WindowId }

    $tabs = Resolve-PaneEntries -WindowPanes $windowPanes -MuxOrigin $muxOrigin -ClaudeRoot (Join-Path $HOME '.claude')
    # Load existing manifest (preserve other profiles), or start fresh
    $manifest = $null
    if (Test-Path -LiteralPath $ManifestPath) {
        try {
            $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
        } catch {
            Write-Warning "Existing manifest at $ManifestPath is unparseable. Backing it up and starting fresh."
            $bak = "$ManifestPath.corrupt.$((Get-Date).ToString('yyyyMMdd-HHmmss')).bak"
            Copy-Item $ManifestPath $bak -Force
            $manifest = $null
        }
    }

    if (-not $manifest) {
        $manifest = [ordered]@{ profiles = [ordered]@{} }
    } else {
        # Convert PSCustomObject back to ordered hashtable so we can mutate
        $newManifest = [ordered]@{ profiles = [ordered]@{} }
        if ($manifest.profiles) {
            foreach ($prop in $manifest.profiles.PSObject.Properties) {
                $newManifest.profiles[$prop.Name] = $prop.Value
            }
        }
        $manifest = $newManifest
    }

    $profileEntry = [ordered]@{
        saved_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        tabs     = $tabs
    }
    $manifest.profiles[$Profile] = $profileEntry

    # Pretty-print JSON
    $json = $manifest | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $ManifestPath -Value $json -Encoding UTF8

    $paneCount = ($tabs | ForEach-Object { $_.panes.Count } | Measure-Object -Sum).Sum
    Write-Host "Saved profile '$Profile' to $ManifestPath" -ForegroundColor Green
    Write-Host ("  Window {0}: {1} tabs, {2} panes" -f $WindowId, $tabs.Count, $paneCount)
    foreach ($t in $tabs) {
        $titles = ($t.panes | ForEach-Object { $_.title }) -join ' | '
        Write-Host ("    {0}: {1}" -f $t.tab_title, $titles)
    }
}

function Get-ClaudeSession {
    [CmdletBinding()]
    param(
        [string]$Path = (Get-Location).Path,
        [int]$Top = 10
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path.TrimEnd('\','/')
    $slug = ($resolved -replace '[:\\/ ]', '-')
    $projectDir = Join-Path "$HOME\.claude\projects" $slug

    if (-not (Test-Path -LiteralPath $projectDir)) {
        Write-Warning "No Claude Code session history found for: $resolved"
        Write-Warning "Looked in: $projectDir"
        return
    }

    $files = Get-ChildItem -LiteralPath $projectDir -Filter '*.jsonl' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $Top

    if (-not $files) {
        Write-Warning "No .jsonl session files in $projectDir"
        return
    }

    $rows = foreach ($f in $files) {
        $sessionId = $null
        $slugVal = $null

        # Read up to first 100 lines to find sessionId (line 1) and slug (later lines)
        $reader = [System.IO.StreamReader]::new($f.FullName)
        try {
            $lineNum = 0
            while ($lineNum -lt 100 -and ($line = $reader.ReadLine())) {
                $lineNum++
                if (-not $sessionId -and $line -match '"sessionId"\s*:\s*"([^"]+)"') {
                    $sessionId = $matches[1]
                }
                if (-not $slugVal -and $line -match '"slug"\s*:\s*"([^"]+)"') {
                    $slugVal = $matches[1]
                }
                if ($sessionId -and $slugVal) { break }
            }
        } finally {
            $reader.Dispose()
        }

        [PSCustomObject]@{
            Name         = if ($slugVal) { $slugVal } else { '<unnamed>' }
            LastActivity = $f.LastWriteTime
            SessionId    = $sessionId
            FilePath     = $f.FullName
        }
    }

    $rows | Format-Table -AutoSize Name, LastActivity, SessionId
}

function Restore-ClaudeSession {
    [CmdletBinding()]
    param(
        [string]$Profile = "default",
        [string]$ManifestPath = "$HOME\.claude\sessions.json",
        [switch]$ListProfiles,
        [switch]$DryRun
    )

    if (-not (Get-Command wezterm.exe -ErrorAction SilentlyContinue)) {
        Write-Error "wezterm.exe not found on PATH."
        return
    }
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        Write-Error "Manifest not found: $ManifestPath. Run Save-ClaudeSession (claude-save) first."
        return
    }

    try {
        $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    } catch {
        Write-Error ("Manifest is unparseable: {0}" -f $_.Exception.Message)
        return
    }

    if ($ListProfiles) {
        Write-Host "Profiles in ${ManifestPath}:" -ForegroundColor Cyan
        foreach ($p in $manifest.profiles.PSObject.Properties) {
            $tabCount = ($p.Value.tabs | Measure-Object).Count
            $paneCount = ($p.Value.tabs | ForEach-Object { $_.panes.Count } | Measure-Object -Sum).Sum
            Write-Host ("  {0}  ({1} tabs, {2} panes, saved {3})" -f $p.Name, $tabCount, $paneCount, $p.Value.saved_at)
        }
        return
    }

    $profileEntry = $manifest.profiles.$Profile
    if (-not $profileEntry) {
        $available = ($manifest.profiles.PSObject.Properties | ForEach-Object Name) -join ', '
        Write-Error ("Profile '{0}' not found. Available: {1}" -f $Profile, $available)
        return
    }

    foreach ($tab in $profileEntry.tabs) {
        if (-not $tab.panes -or $tab.panes.Count -eq 0) {
            Write-Warning ("Tab '{0}' has no panes; skipping." -f $tab.tab_title)
            continue
        }

        $previousPaneId = $null
        for ($i = 0; $i -lt $tab.panes.Count; $i++) {
            $pane = $tab.panes[$i]

            # Validate
            $modes = @()
            if ($pane.resume)   { $modes += 'resume' }
            if ($pane.continue) { $modes += 'continue' }
            if ($pane.fresh)    { $modes += 'fresh' }
            if ($modes.Count -ne 1) {
                Write-Warning ("Pane '{0}' must have exactly one of resume/continue/fresh; skipping." -f $pane.title)
                continue
            }

            if (-not $pane.cwd -or -not (Test-Path -LiteralPath $pane.cwd)) {
                Write-Warning ("Pane '{0}' cwd missing or invalid: {1}; skipping." -f $pane.title, $pane.cwd)
                continue
            }

            # Strip trailing backslashes. Windows command-line parsing treats a backslash
            # immediately before a closing double-quote as an ESCAPED quote (e.g. "C:\foo\"
            # becomes literal C:\foo"), which corrupts wezterm's --cwd argument when the
            # path has a trailing slash. Without this, all spawned panes silently default
            # to the user's home directory.
            $cleanCwd = $pane.cwd.TrimEnd('\','/')

            # Resolve mode + validate session id for resume
            $effectiveMode = $modes[0]
            $resumeName = $pane.resume
            if ($effectiveMode -eq 'resume') {
                if (-not (Test-SessionId -Cwd $pane.cwd -Id $resumeName)) {
                    # Launch fresh, NOT --continue. --continue silently loads the most-recently
                    # modified session in this cwd, which is almost never the one we meant to
                    # resume — that produced the "restored the wrong session" symptom.
                    Write-Warning ("  '{0}': session id not found in history; launching fresh (refusing --continue, which would load an unrelated session)." -f $resumeName)
                    $effectiveMode = 'fresh'
                }
            }

            # Build the inner powershell command. Env var must be set BEFORE the profile is
            # sourced (the auto-launch block in the profile reads it).
            $envSetup = switch ($effectiveMode) {
                'resume'   { $safe = $resumeName -replace "'", "''"; "`$env:CLAUDE_RESTORE_NAME='$safe'" }
                'continue' { "`$env:CLAUDE_RESTORE_CONTINUE='1'" }
                'fresh'    { "" }   # no env var; bare claude will run via auto-launch
            }
            $pwshCmd = if ($envSetup) { "$envSetup; . `$PROFILE" } else { ". `$PROFILE" }

            # CRITICAL: pass the command as -EncodedCommand (base64 UTF-16 LE).
            # PowerShell 5.1's native-command argument passing mangles strings that
            # contain spaces, single quotes, and dollar signs all together; an
            # encoded command is one clean token with none of those characters.
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($pwshCmd))

            # Decide spawn vs split
            if ($i -eq 0) {
                $action = "spawn (new tab) -> $($pane.title) [$effectiveMode]"
                $args = @('cli', 'spawn', '--cwd', $cleanCwd, '--', 'powershell.exe', '-NoProfile', '-NoExit', '-EncodedCommand', $encoded)
            } else {
                $direction = $pane.split_from_previous
                if ($direction -notin @('right', 'bottom')) {
                    Write-Warning ("Pane '{0}' has invalid split_from_previous '{1}'; defaulting to right." -f $pane.title, $direction)
                    $direction = 'right'
                }
                $action = "split --$direction from pane $previousPaneId -> $($pane.title) [$effectiveMode]"
                $splitFlag = if ($direction -eq 'right') { '--right' } else { '--bottom' }
                $args = @('cli', 'split-pane', '--pane-id', $previousPaneId, $splitFlag, '--cwd', $cleanCwd, '--', 'powershell.exe', '-NoProfile', '-NoExit', '-EncodedCommand', $encoded)
            }

            if ($DryRun) {
                Write-Host ("  DRY-RUN: {0}" -f $action) -ForegroundColor Yellow
                Write-Host ("    wezterm.exe " + ($args -join ' ')) -ForegroundColor DarkGray
                # Pretend pane id sequence so subsequent splits make sense in dry-run output
                $previousPaneId = "<pane-$i>"
                continue
            }

            Write-Host ("  {0}" -f $action) -ForegroundColor Green
            $output = & wezterm.exe @args 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning ("    wezterm command failed: {0}" -f $output)
                continue
            }

            # Output is the new pane id (a number), maybe with trailing whitespace
            $newPaneId = ($output | Select-Object -First 1).ToString().Trim()
            if ($newPaneId -notmatch '^\d+$') {
                Write-Warning ("    Unexpected wezterm output: '{0}'" -f $output)
                $previousPaneId = $null
                continue
            }
            $previousPaneId = $newPaneId
        }
    }

    if (-not $DryRun) {
        Write-Host "Restore complete." -ForegroundColor Green
    }
}

# Helper: returns $true if a session JSONL named <Id>.jsonl exists in the project dir for $Cwd.
# The "Id" is a session UUID (the JSONL filename), which is the canonical handle for
# `claude --resume <id>`. Auto-generated slugs are NOT valid resume keys, so we don't
# try to match them.
function Test-SessionId {
    param([string]$Cwd, [string]$Id)
    if (-not $Id) { return $false }
    $resolved = (Resolve-Path -LiteralPath $Cwd -ErrorAction SilentlyContinue)
    if (-not $resolved) { return $false }
    # Match Claude's project-dir naming: every non-alphanumeric char -> '-'.
    # Do NOT trim a trailing separator first: Claude encodes it (e.g. 'Z:\' -> 'Z--',
    # two dashes for colon+backslash). Trimming produced 'Z-' and the dir never matched.
    # The old class '[:\\/ ]' also missed '.', so '.claude' mismatched ('-.claude' vs '--claude').
    $projectSlug = ($resolved.Path -replace '[^a-zA-Z0-9]', '-')
    $projectDir = Join-Path "$HOME\.claude\projects" $projectSlug
    if (-not (Test-Path -LiteralPath $projectDir)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $projectDir "$Id.jsonl"))
}

Set-Alias -Name claude-save    -Value Save-ClaudeSession
Set-Alias -Name claude-restore -Value Restore-ClaudeSession

if ($MyInvocation.MyCommand.ScriptBlock.Module) {
    Export-ModuleMember -Function Save-ClaudeSession, Restore-ClaudeSession, Get-ClaudeSession `
                        -Alias claude-save, claude-restore
}
