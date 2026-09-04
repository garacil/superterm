@echo off
setlocal EnableExtensions
rem ---------------------------------------------------------------------------
rem  Build the Windows executables with one double-click (or one command),
rem  from the repository root:
rem      bin\superterm.exe        the console client / session server
rem      bin\superterm-tray.exe   the notification-area helper (if present on
rem                               this branch)
rem
rem  Uses fpc directly with the project's strict contract, so it needs neither
rem  Git Bash nor make. For a full release (installer + zip + checksums) or a
rem  VERSION bump, use packaging\windows\release.ps1 instead, which also
rem  regenerates the version resource.
rem
rem  Override the compiler location by setting SUPERTERM_FPC before running:
rem      set SUPERTERM_FPC=C:\path\to\fpc.exe
rem ---------------------------------------------------------------------------

if defined SUPERTERM_FPC (
  set "FPC=%SUPERTERM_FPC%"
) else (
  set "FPC=D:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe"
)
if not exist "%FPC%" (
  echo [error] fpc not found at "%FPC%".
  echo         Set SUPERTERM_FPC to your fpc.exe and run again, e.g.:
  echo             set SUPERTERM_FPC=C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe
  exit /b 1
)

rem This .bat lives in the repository root; build from here (bin\ hangs off it).
pushd "%~dp0" || (echo [error] cannot enter "%~dp0" & exit /b 1)

set "FLAGS=-B -Mobjfpc -Sh -Sewnh -vewnh -vm11030,11031 -O4 -gl -FEbin"
if not exist "bin" mkdir "bin"
if not exist "build\units\win-release" mkdir "build\units\win-release"

echo === [1/2] superterm.exe ===
"%FPC%" %FLAGS% -Fuvendor\fv322 -FUbuild\units\win-release -obin\superterm.exe src\superterm.lpr
if errorlevel 1 goto :fail

if exist "src\traytool\superterm-tray.lpr" (
  echo === [2/2] superterm-tray.exe ===
  if not exist "build\units\tray" mkdir "build\units\tray"
  "%FPC%" %FLAGS% -FUbuild\units\tray -obin\superterm-tray.exe src\traytool\superterm-tray.lpr
  if errorlevel 1 goto :fail
) else (
  echo === [2/2] superterm-tray.exe: no source on this branch, skipping ===
)

echo.
echo === OK: built into bin\ ===
popd
endlocal
exit /b 0

:fail
echo.
echo === BUILD FAILED ===
echo If the message was "Can't create executable ... error code 5", a running
echo SuperTerm is locking the file. Close it and run again:
echo     taskkill /F /IM superterm.exe /IM superterm-tray.exe
popd
endlocal
exit /b 1
