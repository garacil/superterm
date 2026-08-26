@echo off
setlocal
set "SUPERTERM_APP=%~dp0superterm.exe"

rem A graphical launch has no parent console. Prefer a new Windows Terminal
rem window sized to SuperTerm's 120x50 desktop plus menu/status rows, and retain
rem cmd.exe as a universal Windows 10 fallback.
where wt.exe >nul 2>&1
if not errorlevel 1 (
  wt.exe -w new --size 120,52 -d "%~dp0" -- "%SUPERTERM_APP%" %*
  exit /b %errorlevel%
)

"%SUPERTERM_APP%" %*
