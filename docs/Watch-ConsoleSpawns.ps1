# Watch-ConsoleSpawns.ps1
# Polls every 250ms for new console-host process instances. When Windows Terminal
# or OpenConsole spawns (the visible-window cause), dumps a snapshot of every
# process started in the prior ~3 seconds so the COM client can be identified.
#
# Start (detached, hidden), from this file's folder:
#   Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$PSScriptRoot\Watch-ConsoleSpawns.ps1" -WindowStyle Hidden
#
# Stop:
#   Stop-Process -Id (Get-Content "$HOME\.claude\backups\console-spawn.pid")

$ErrorActionPreference = 'SilentlyContinue'

$backupDir = Join-Path $HOME '.claude\backups'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$logPath = Join-Path $backupDir 'console-spawn.log'
$pidPath = Join-Path $backupDir 'console-spawn.pid'

$PID | Set-Content -LiteralPath $pidPath

$targets = @(
    'wt.exe','WindowsTerminal.exe','OpenConsole.exe',
    'cmd.exe','powershell.exe','pwsh.exe','conhost.exe',
    'python.exe','python3.exe','pythonw.exe',
    'wscript.exe','cscript.exe',
    'bash.exe','wsl.exe','wslhost.exe'
)
$nameClause = ($targets | ForEach-Object { "Name='$_'" }) -join ' OR '

$terminalNames = @('wt.exe','WindowsTerminal.exe','OpenConsole.exe')

# Don't log the watcher's own pid or anything already running at startup.
$startupPids = @{}
Get-CimInstance Win32_Process -Filter $nameClause | ForEach-Object { $startupPids[[int]$_.ProcessId] = $true }
$startupPids[[int]$PID] = $true

Add-Content -LiteralPath $logPath -Value ("==== Watcher v2 started {0} (pid={1}, 250ms polling, ignoring {2} startup pids) ====" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $startupPids.Count)

$seen = @{}
$lastHeartbeat = Get-Date

while ($true) {
    try {
        $procs = Get-CimInstance Win32_Process -Filter $nameClause -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            $procPid = [int]$p.ProcessId
            if ($startupPids.ContainsKey($procPid)) { continue }
            if ($seen.ContainsKey($procPid)) { continue }
            $seen[$procPid] = $true

            $parent = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $p.ParentProcessId) -ErrorAction SilentlyContinue

            $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
            $cmd = if ($p.CommandLine) { $p.CommandLine } else { '<no cmdline>' }
            $parentName = if ($parent) { $parent.Name } else { '?' }
            $parentCmd = if ($parent -and $parent.CommandLine) { $parent.CommandLine } else { '<no parent cmdline>' }

            $entry = "{0} | {1} pid={2} ppid={3} parent={4}`n    cmd : {5}`n    pcmd: {6}" -f $now, $p.Name, $procPid, $p.ParentProcessId, $parentName, $cmd, $parentCmd
            Add-Content -LiteralPath $logPath -Value $entry

            # When Windows Terminal or OpenConsole spawns, snapshot all recently-created
            # processes so the COM activator (which usually dies fast) is captured.
            if ($terminalNames -contains $p.Name) {
                $cutoff = (Get-Date).AddSeconds(-3)
                Add-Content -LiteralPath $logPath -Value ("  >>> Terminal spawn snapshot (procs created in last 3s):")
                try {
                    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                        Where-Object { $_.CreationDate -and $_.CreationDate -gt $cutoff -and $_.ProcessId -ne $procPid } |
                        Sort-Object CreationDate |
                        ForEach-Object {
                            $line = "      [{0}] {1} pid={2} ppid={3} cmd={4}" -f
                                $_.CreationDate.ToString('HH:mm:ss.fff'),
                                $_.Name,
                                $_.ProcessId,
                                $_.ParentProcessId,
                                $(if ($_.CommandLine) { $_.CommandLine } else { '<no cmdline>' })
                            Add-Content -LiteralPath $logPath -Value $line
                        }
                } catch {
                    Add-Content -LiteralPath $logPath -Value ("      ERR snapshotting: " + $_.Exception.Message)
                }
                Add-Content -LiteralPath $logPath -Value "  <<< end snapshot"
            }
        }

        # Trim seen-set occasionally so it doesn't grow forever
        if ($seen.Count -gt 5000) { $seen = @{} }

        # Heartbeat every 10 minutes so we know the watcher is alive
        if ((New-TimeSpan -Start $lastHeartbeat -End (Get-Date)).TotalMinutes -ge 10) {
            Add-Content -LiteralPath $logPath -Value ("-- heartbeat {0} --" -f (Get-Date -Format 'HH:mm:ss'))
            $lastHeartbeat = Get-Date
        }
    } catch {
        Add-Content -LiteralPath $logPath -Value ("ERR: " + $_.Exception.Message)
    }

    Start-Sleep -Milliseconds 250
}
