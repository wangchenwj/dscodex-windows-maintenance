@echo off
setlocal
rem codex shim -> reads CODEX_CLI_PATH from config.toml at every call, so app
rem updates are followed when the app updates that single-quoted path.
set "CODEX_EXE="
for /f "tokens=2 delims='" %%a in ('findstr /b /c:"CODEX_CLI_PATH" "%USERPROFILE%\.codex\config.toml" 2^>nul') do set "CODEX_EXE=%%a"
if not defined CODEX_EXE (
  echo codex shim: could not read CODEX_CLI_PATH from %%USERPROFILE%%\.codex\config.toml 1>&2
  exit /b 1
)
"%CODEX_EXE%" %*
