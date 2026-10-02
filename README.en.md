# DSCodex Windows Maintenance

[中文](README.md)

Windows companion scripts for [DSCodex](https://github.com/fish2lab/DSCodex): keep the loopback router running, refresh the native GPT catalog, and follow the desktop app's CLI path from a terminal.

DSCodex provides GPT / DeepSeek coexistence and model-based routing. This repository contains maintenance scripts, not the router or a modified Codex app.

## What it does

- The watchdog checks the router's TCP port approximately every 20 seconds and starts it when unavailable. It launches a catalog check approximately every 10 minutes.
- The refresh script runs on first use, when `CODEX_CLI_PATH` changes, or when the last successful refresh is 14 days old. Failed attempts have a 30-minute cooldown unless `-Force` is supplied.
- A temporary `CODEX_HOME` without a custom catalog lets the native CLI discover GPT models. The resulting cache is copied to the normal home, then DSCodex `sync` merges it.
- The optional `codex.cmd` reads the configured CLI path on each invocation. It requires a single-quoted `CODEX_CLI_PATH` value and does not start the router.

**Ten minutes is the check interval, not a guarantee that every new model appears within ten minutes.** If a server-side model release does not change the CLI path, the 14-day condition applies. Fully quit and reopen the desktop app after a successful catalog refresh.

## Requirements

Windows, Windows PowerShell 5.1+, CIM/WMI, an installed and working DSCodex checkout, a supported Node.js runtime, ChatGPT login in the default `~/.codex/auth.json`, and a valid app-maintained `CODEX_CLI_PATH` in `~/.codex/config.toml`.

Follow the upstream DSCodex README to install its runtime dependencies and verify both GPT and DeepSeek first. This companion repository adds no npm dependencies. Custom Codex home directories are not supported.

## Run

```powershell
git clone https://github.com/wangchenwj/dscodex-windows-maintenance.git
cd dscodex-windows-maintenance
$repoPath = (Get-Location).Path
$dsPath = 'D:\tools\DSCodex'             # Your existing DSCodex checkout
$nodePath = 'D:\tools\node24\node.exe'   # Your supported Node runtime

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$repoPath\scripts\refresh-models.ps1" -DscodexPath $dsPath -NodePath $nodePath -Force
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$repoPath\scripts\dscodex-watchdog.ps1" -DscodexPath $dsPath -NodePath $nodePath
```

Use `-Port` on the watchdog if the router uses a port other than `10110`. Use absolute directory paths without a trailing backslash. The refresh probe intentionally requests a nonexistent model, so an inference failure is expected; success means a valid catalog was obtained and DSCodex `sync` succeeded. This avoided successful GPT inference in the original deployment; future quota accounting is not guaranteed.

Check `~/.codex/dscodex/refresh.log` for `refreshed: ... catalog synced`, then restart the app. A single backup of the old cache is written to `~/.codex/models_cache.json.pre-refresh.bak`. Proxy selection prefers DSCodex's stored proxy, then Windows user proxy settings, otherwise the inherited network environment.

See the [Chinese setup guide](README.md) for login startup registration, optional terminal shim installation, logs, and removal. Run only one watchdog and do not run concurrent manual refreshes. Never set the desktop app's `CODEX_CLI_PATH` to this `.cmd` file; Windows desktop integration requires the native executable.

## Credentials and validation

The refresh process temporarily copies ChatGPT credentials to a unique directory with a current-user-only ACL and removes it on normal completion or a caught error. Forced termination or power loss can leave `%TEMP%\dscodex-refresh-*`; remove these directories manually once no refresh process is running. Do not publish runtime logs, state, caches, `auth.json`, or DSCodex's private configuration.

The original deployment used Windows 11, desktop app 26.903.8094.0 and Node.js 24.19.0. This published version parameterizes paths and restricts temporary credentials; it has received static syntax and publication-content checks, not a clean-machine end-to-end installation or upgrade validation. Future native CLI changes may require adaptation. TCP availability alone does not establish full router health.

## Attribution and license

GPT / DeepSeek coexistence is provided by [fish2lab/DSCodex](https://github.com/fish2lab/DSCodex). These companion scripts document a Windows maintenance workflow and make no claim to have invented model routing or automatic catalog refresh.

Scripts and documentation: [MIT](LICENSE). DSCodex is separately distributed under its upstream MIT license; no router source is redistributed here.
