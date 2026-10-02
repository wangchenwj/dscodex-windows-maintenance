# DSCodex model-catalog auto-refresh: keeps ~/.codex/models_cache.json (and the
# DSCodex catalog snapshot built from it) in sync with the account's server-side
# model list. The Codex app stops refreshing models_cache.json while
# model_catalog_json is set, so new GPT models never reach the picker without this.
#
# How: run the app's own codex.exe in a throwaway CODEX_HOME. The model turn is
# intentionally invalid ("not supported when using Codex with a ChatGPT account",
# HTTP 400) to avoid a successful GPT inference, but the models fetch still lands in the
# throwaway home. Fast-exits unless the app updated (CODEX_CLI_PATH changed) or
# the last successful refresh is old; use -Force to refresh now.
# Pure ASCII on purpose: Windows PowerShell 5.1 misreads UTF-8-no-BOM scripts.

param(
    [Parameter(Mandatory = $true)][string]$DscodexPath,
    [string]$NodePath = 'node.exe',
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

$codexHome  = Join-Path $env:USERPROFILE '.codex'
$stateDir   = Join-Path $codexHome 'dscodex'
$log        = Join-Path $stateDir 'refresh.log'
$marker     = Join-Path $stateDir 'refresh-marker.json'
$execOut    = Join-Path $stateDir 'refresh-exec.log'
$syncLog    = Join-Path $stateDir 'refresh-sync.log'
$node       = (Get-Command $NodePath -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$cliRepo    = (Resolve-Path -LiteralPath $DscodexPath -ErrorAction Stop).Path
$maxAgeDays = 14
$tempRoot   = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tmpHome    = Join-Path $tempRoot ('dscodex-refresh-' + [guid]::NewGuid().ToString('N'))
if (-not (Test-Path -LiteralPath (Join-Path $cliRepo 'src\cli.mjs') -PathType Leaf)) {
    throw 'DscodexPath must point to the DSCodex repository containing src\cli.mjs.'
}
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

function Write-Log($msg) {
    Add-Content -LiteralPath $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $msg) -Encoding UTF8 -ErrorAction SilentlyContinue
}

# 1. Current app-managed CLI path (changes on every app update).
$configPath = Join-Path $codexHome 'config.toml'
$cliPath = $null
if (Test-Path -LiteralPath $configPath) {
    $m = Select-String -LiteralPath $configPath -Pattern '^\s*CODEX_CLI_PATH\s*=\s*([\x22\x27])(.+?)\1\s*(?:#.*)?$' | Select-Object -First 1
    if ($m) {
        $cliPath = $m.Matches[0].Groups[2].Value
        if ($m.Matches[0].Groups[1].Value -eq '"') { $cliPath = $cliPath.Replace('\\', '\') }
    }
}
if (-not $cliPath -or -not (Test-Path -LiteralPath $cliPath)) {
    Write-Log "skip: CODEX_CLI_PATH not found or missing on disk ($cliPath)"
    exit 1
}

# 2. Skip fast when nothing changed.
$last = $null
if (Test-Path -LiteralPath $marker) {
    try { $last = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json } catch { $last = $null }
}
$now = Get-Date
if (-not $Force -and $last) {
    $cliSame = ($last.cli_path -eq $cliPath)
    $freshSuccess = $false
    try { $freshSuccess = ((New-TimeSpan -Start ([datetime]$last.last_success) -End $now).TotalDays -lt $maxAgeDays) } catch { }
    $recentAttempt = $false
    try { $recentAttempt = ((New-TimeSpan -Start ([datetime]$last.last_attempt) -End $now).TotalMinutes -lt 30) } catch { }
    if ($cliSame -and $freshSuccess) { exit 0 }
    if ($recentAttempt) { exit 0 }
}

Write-Log "refresh start (cli=$cliPath)"
$succeeded = $false

try {
    # 3. Throwaway CODEX_HOME: ChatGPT auth + minimal config -> direct chatgpt.com.
    New-Item -ItemType Directory -Path $tmpHome -ErrorAction Stop | Out-Null
    # Restrict the temporary copy of ChatGPT credentials to the current user.
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $tmpHome -AclObject $acl -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $codexHome 'auth.json') -Destination (Join-Path $tmpHome 'auth.json') -Force -ErrorAction Stop
    Set-Content -LiteralPath (Join-Path $tmpHome 'config.toml') -Value 'model = "dscodex-refresh-probe"' -Encoding Ascii -ErrorAction Stop

    # 4. Proxy: the models fetch goes to chatgpt.com, which needs the same proxy the
    #    router uses. Prefer DSCodex's stored proxy (DPAPI blob in its config.json);
    #    fall back to the registry value if present.
    $proxy = $null
    $dsConfig = Join-Path $stateDir 'config.json'
    if (Test-Path -LiteralPath $dsConfig) {
        try {
            Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
            $cfg = Get-Content -LiteralPath $dsConfig -Raw | ConvertFrom-Json
            if ($cfg.proxy_url -and $cfg.proxy_encoding -eq 'dpapi') {
                $bytes = [Convert]::FromBase64String($cfg.proxy_url)
                $proxy = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
            } elseif ($cfg.proxy_url) {
                $proxy = [string]$cfg.proxy_url
            }
        } catch { }
    }
    if (-not $proxy) {
        $proxy = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue).ProxyServer
        if ($proxy -and $proxy -match '=') {
            $m = [regex]::Match($proxy, '(?:^|;)\s*https?=([^;]+)')
            if ($m.Success) { $proxy = $m.Groups[1].Value } else { $proxy = $null }
        }
    }
    if ($proxy) {
        if ($proxy -notmatch '^[a-z]+://') { $proxy = 'http://' + $proxy }
        $env:HTTPS_PROXY = $proxy
        $env:HTTP_PROXY = $proxy
        Write-Log 'proxy configured'
    } else {
        Write-Log 'no stored proxy found; using the inherited network environment'
    }
    $env:NO_PROXY = '127.0.0.1,localhost'
    $env:CODEX_HOME = $tmpHome

    # 5. Fetch: the turn is expected to fail (400, invalid model); the cache is what matters.
    $proc = Start-Process -FilePath $cliPath -ArgumentList @('exec', '--skip-git-repo-check', '-m', 'dscodex-refresh-probe', 'x') -PassThru -WindowStyle Hidden -RedirectStandardOutput $execOut -RedirectStandardError ($execOut + '.err') -ErrorAction Stop
    if (-not $proc.WaitForExit(180000)) {
        $proc.Kill()
        $proc.WaitForExit()
        Write-Log 'fetch timed out (180s)'
    } else {
        $fresh = Join-Path $tmpHome 'models_cache.json'
        if (-not (Test-Path -LiteralPath $fresh)) {
            Write-Log 'fetch produced no models_cache.json'
        } else {
            # Windows PowerShell 5.1 ConvertFrom-Json cannot parse this cache
            # (throws on valid JSON), so count models with node instead.
            $count = 0
            try {
                $countOut = & $node -e "const fs=require('fs');try{process.stdout.write(String((JSON.parse(fs.readFileSync(process.argv[1],'utf8')).models||[]).length))}catch(e){process.stdout.write('0')}" $fresh
                $count = [int]$countOut
            } catch { $count = 0 }
            if ($count -lt 5) {
                Write-Log "fresh cache suspicious ($count models); keeping current cache"
            } else {
                $real = Join-Path $codexHome 'models_cache.json'
                Copy-Item -LiteralPath $real -Destination ($real + '.pre-refresh.bak') -Force -ErrorAction SilentlyContinue
                Copy-Item -LiteralPath $fresh -Destination $real -Force -ErrorAction Stop
                # cli.mjs resolves the codex home from CODEX_HOME; point it back at the real one.
                $env:CODEX_HOME = $codexHome
                & $node (Join-Path $cliRepo 'src\cli.mjs') sync *> $syncLog
                if ($LASTEXITCODE -eq 0) {
                    $succeeded = $true
                    Write-Log "refreshed: $count native entries, catalog synced (restart the Codex app to see new models)"
                } else {
                    Write-Log "catalog sync failed (exit $LASTEXITCODE); see refresh-sync.log"
                }
            }
        }
    }
} catch {
    Write-Log ('refresh error: ' + $_.Exception.Message)
} finally {
    # Delete only this invocation's directory under the resolved temporary root.
    $resolvedTemp = [IO.Path]::GetFullPath($tmpHome)
    $expectedParent = $tempRoot.TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolvedTemp) -eq $expectedParent -and
        [IO.Path]::GetFileName($resolvedTemp) -match '^dscodex-refresh-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 6. Marker: on success move to the new CLI path; on failure keep the old one so the next cycle retries.
$markerObj = [ordered]@{
    cli_path     = $(if ($succeeded) { $cliPath } elseif ($last) { $last.cli_path } else { $null })
    last_success = $(if ($succeeded) { $now.ToString('o') } elseif ($last) { $last.last_success } else { $null })
    last_attempt = $now.ToString('o')
}
$markerObj | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding Ascii

if ($succeeded) { exit 0 } else { exit 1 }
