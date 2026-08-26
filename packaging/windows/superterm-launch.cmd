@echo off
setlocal
set "SUPERTERM_APP=%~dp0superterm.exe"

rem A graphical launch has no parent console. Prefer Windows Terminal when it
rem is installed, and retain cmd.exe as a universal Windows 10 fallback.
where wt.exe >nul 2>&1
if not errorlevel 1 (
  wt.exe -d "%~dp0" -- "%SUPERTERM_APP%" %*
  exit /b %errorlevel%
)

"%SUPERTERM_APP%" %*
