# DSCodex watchdog v2: keeps the loopback router on 127.0.0.1:10110 alive.
# Started at logon via HKCU\...\Run. Checks the port every 20s,
# restarts the router when it is down, and survives its own failures.
# Also launches refresh-models.ps1 detached every ~10 min (and shortly after
# logon): that script fast-exits unless the app updated or the catalog is old,
# so new GPT models reach the picker without manual steps.
# Pure ASCII on purpose: Windows PowerShell 5.1 misreads UTF-8-no-BOM scripts.

param(
    [Parameter(Mandatory = $true)][string]$DscodexPath,
    [string]$NodePath = 'node.exe',
    [ValidateRange(1, 65535)][int]$Port = 10110
)

$ErrorActionPreference = 'Continue'

$node = (Get-Command $NodePath -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$repo = (Resolve-Path -LiteralPath $DscodexPath -ErrorAction Stop).Path
$cli = Join-Path $repo 'src\cli.mjs'
if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw 'DscodexPath must contain src\cli.mjs.' }
$stateDir = Join-Path $env:USERPROFILE '.codex\dscodex'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$log = Join-Path $env:USERPROFILE '.codex\dscodex\watchdog.log'
$refresh = Join-Path $PSScriptRoot 'refresh-models.ps1'

function Write-Log($msg) {
    $line = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') + ' ' + $msg
    Add-Content -LiteralPath $log -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

Write-Log 'watchdog v2 started'
$heartbeat = 0
$refreshTick = 29

while ($true) {
    try {
        $up = $false
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $client.BeginConnect('127.0.0.1', $port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(1500, $false)) {
                $client.EndConnect($iar)
                $up = $true
            }
            $client.Close()
        } catch {
            $client.Close()
        }

        if (-not $up) {
            Write-Log 'router down, starting...'
            & $node $cli start --port $Port *>> $null
            Start-Sleep -Seconds 6
        } elseif ($heartbeat -ge 15) {
            Write-Log 'alive'
            $heartbeat = 0
        }
        $heartbeat++
        if ($refreshTick -ge 30) {
            $refreshTick = 0
            # Spawn via WMI, not Start-Process: from this hidden WMI-launched
            # process Start-Process failed silently in the original deployment.
            try {
                $commandLine = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $refresh + '" -DscodexPath "' + $repo.TrimEnd('\') + '" -NodePath "' + $node + '"'
                $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine }
                if ($r.ReturnValue -eq 0) { Write-Log 'refresh triggered' } else { Write-Log ('refresh spawn failed, return ' + $r.ReturnValue) }
            } catch {
                Write-Log ('refresh spawn error: ' + $_.Exception.Message)
            }
        }
        $refreshTick++
    } catch {
        Write-Log ('watchdog error: ' + $_.Exception.Message)
    }
    Start-Sleep -Seconds 20
}
