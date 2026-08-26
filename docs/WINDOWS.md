# Windows port — status and handoff

Branch: **`windows-support`**. Goal: make superterm build and run natively on
Windows (in addition to the untouched GNU/Linux and macOS targets). This file
is the working log so the port can be resumed in a fresh session.

GNU/Linux and macOS behaviour must not change: every Windows change is behind
`{$IFDEF WINDOWS}` / `{$IFDEF UNIX}` or lives in a new Windows-only unit.

## Golden rule: read the implementation first

Never design, change, review, or explain a Windows/FPC integration from
memory. Before editing:

1. Read the SuperTerm caller and every related local unit.
2. Locate and read the exact FPC 3.2.2 declaration **and implementation** used
   by this installation. A declaration alone is not enough: queue ownership,
   initialization order, blocking behavior, and finalization live in the
   implementation files.
3. If the API is absent from the installed FPC sources (ConPTY is), read the
   matching locally installed Windows SDK header instead of inventing an FFI.
4. Compile the affected unit, build the complete Win64 program with `-B`, and
   run the smallest useful probe. Treat a successful compile as type/link
   evidence only, never as runtime proof.

Useful first searches:

```powershell
$FpcSrc = 'D:\lazarus\fpc\3.2.2\source'
rg -n --glob '*.{pp,pas,inc}' '\bSymbolName\b' $FpcSrc
rg -n '\bSymbolName\b' src vendor\fv322
```

This rule is permanent for the Windows port. In particular, do not use stale
paths cached by an installer (`B:\tmp_lazbuild64` and old `D:\fpc` entries
exist in Lazarus cache files but are not the active source tree).

## Local FPC/Lazarus source map

This is the verified installation on the Windows development machine. Full
scans of `C:` and `D:` found no second FPC/Lazarus installation.

| Purpose | Verified path |
|---|---|
| FPC driver | `D:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe` |
| Native compiler | `D:\lazarus\fpc\3.2.2\bin\x86_64-win64\ppcx64.exe` |
| FPC configuration | `D:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.cfg` |
| GNU Make 3.80 | `D:\lazarus\fpc\3.2.2\bin\x86_64-win64\make.exe` |
| Assembler/linker tools | `D:\lazarus\fpc\3.2.2\bin\x86_64-win64\` (`as.exe`, `ld.exe`, `ar.exe`, `windres.exe`, `fpcres.exe`, `ppudump.exe`) |
| Compiled Win64 units | `D:\lazarus\fpc\3.2.2\units\x86_64-win64` |
| FPC source root | `D:\lazarus\fpc\3.2.2\source` |
| RTL source | `D:\lazarus\fpc\3.2.2\source\rtl` |
| Package source | `D:\lazarus\fpc\3.2.2\source\packages` |
| Free Vision source | `D:\lazarus\fpc\3.2.2\source\packages\fv\src` |
| Windows console RTL | `D:\lazarus\fpc\3.2.2\source\packages\rtl-console\src\win` |
| Generic keyboard/mouse queues | `D:\lazarus\fpc\3.2.2\source\packages\rtl-console\src\inc` |
| Windows unit entry | `D:\lazarus\fpc\3.2.2\source\rtl\win64\windows.pp` |
| Shared WinAPI declarations | `D:\lazarus\fpc\3.2.2\source\rtl\win\wininc` |
| FCL process/pipes | `D:\lazarus\fpc\3.2.2\source\packages\fcl-process\src` |
| Extra WinAPI units | `D:\lazarus\fpc\3.2.2\source\packages\winunits-base\src` and `D:\lazarus\fpc\3.2.2\source\packages\winunits-jedi\src` |
| Lazarus 4.8 | `D:\lazarus\lazarus.exe` |
| Lazarus build tool | `D:\lazarus\lazbuild.exe` |
| Lazarus source | `D:\lazarus` |
| LCL Win32 source | `D:\lazarus\lcl\interfaces\win32` |
| GDB | `D:\lazarus\mingw\x86_64-win64\bin\gdb.exe` |

The installed source tree contains `rtl` and `packages`, but no FPC compiler
front-end/backend source directory. ConPTY, `STARTUPINFOEXW`, and process
attribute-list declarations are also absent from the installed Pascal source.
Use these local Windows 10 SDK headers for those APIs:

- `C:\Program Files (x86)\Windows Kits\10\Include\10.0.19041.0\um\consoleapi.h`
- `C:\Program Files (x86)\Windows Kits\10\Include\10.0.19041.0\um\wincontypes.h`
- `C:\Program Files (x86)\Windows Kits\10\Include\10.0.19041.0\um\WinBase.h`
- `C:\Program Files (x86)\Windows Kits\10\Include\10.0.19041.0\um\processthreadsapi.h`

Active user configuration lives under
`C:\Users\tecno\AppData\Local\lazarus\` (`environmentoptions.xml`,
`debuggeroptions.xml`, `fpcdefines.xml`, `includelinks.xml`) and
`C:\Users\tecno\AppData\Local\FreePascal\fppkg\`. Only the FPC binary
directory is on `PATH`; invoke `lazbuild.exe` and the bundled GNU Make by
absolute path. Bare `make` resolves to Embarcadero Make 5.43 and is not the
project build tool.

## Build and verify

### Platform contract

- **Minimum OS: Windows 10 version 1809 (build 17763).** ConPTY first shipped
  there. `st_conpty.pas` declares its ConPTY and process-attribute functions
  as static `kernel32.dll` imports, so the Windows loader must resolve them
  before any Pascal code runs. The current binary therefore cannot use
  `IsConPtyAvailable` to fail gracefully on older Windows versions.
- **Compiler:** FPC 3.2.2 for `x86_64-win64`, bundled with the Lazarus
  installation listed above.
- **Build shell:** run `configure` and GNU Make from Git Bash. The generated
  recipes require `/bin/sh` and POSIX utilities. PowerShell is suitable for
  the direct FPC verification command below, but not for invoking the Makefile
  recipes directly.

### Normal release build from Git Bash

From a fresh Git Bash prompt:

```sh
cd /d/sources/superterm
./configure \
  --with-fpc=/d/lazarus/fpc/3.2.2/bin/x86_64-win64/fpc
/d/lazarus/fpc/3.2.2/bin/x86_64-win64/make.exe info
/d/lazarus/fpc/3.2.2/bin/x86_64-win64/make.exe release
```

`Makefile.in` is compatible with the bundled GNU Make 3.80: its mode
selection uses nested conditionals, it adds `.exe` on Windows, and it
normalizes Git Bash's `/d/...` project and compiler paths to `D:/...` before
checking prerequisites or starting FPC. The release target compiles with
`-O4 -gl` and generates `src/st_version.inc` from `VERSION`. `make info`
should report:

```text
Target:    D:/sources/superterm/bin/superterm.exe
```

Always invoke the bundled Make by absolute path. Bare `make` on this machine
resolves to Embarcadero Make 5.43 and is not compatible with this project.
Also begin each Git Bash command sequence with
`cd /d/sources/superterm`; shell working directories persist between calls.

### Clean compiler verification from PowerShell

This bypasses Make and forces every Pascal source dependency to rebuild:

```powershell
Set-Location D:\sources\superterm
$Fpc = 'D:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe'
New-Item -ItemType Directory -Force `
  -Path 'build\units\win-release', 'bin' | Out-Null
& $Fpc -B -Mobjfpc -Sh -vewnh -vm11030,11031 -O4 -gl `
  -Fuvendor\fv322 -FUbuild\units\win-release -FEbin `
  -obin\superterm.exe src\superterm.lpr
if ($LASTEXITCODE -ne 0) { throw "FPC failed with exit code $LASTEXITCODE" }
& .\bin\superterm.exe --version
& .\bin\superterm.exe --help
& .\bin\superterm.exe --list-sessions
```

`-B` is intentional: it verifies the entire dependency graph instead of
accepting stale `.ppu` files.

### Windows icon and installer

The checked-in `packaging/windows/alien-hacker.ico` is the application icon. If
it is regenerated from `assets/alien-hacker.png`, rebuild the Windows resource
before compiling the executable:

```powershell
$Windres = 'D:\lazarus\fpc\3.2.2\bin\x86_64-win64\windres.exe'
& $Windres --target=pe-x86-64 -i src\superterm.rc -o src\superterm.res
```

With Inno Setup 6 installed, compile the per-user x64 installer from the
repository root:

```powershell
New-Item -ItemType Directory -Force dist | Out-Null
& 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe' packaging\windows\superterm.iss
```

The result is `dist\SuperTerm-4.2.1-windows-x64-setup.exe`; it installs under
`%LOCALAPPDATA%\Programs\SuperTerm` and includes the executable, documentation,
configuration example, and desktop backgrounds.

The Start-menu and desktop shortcuts use `superterm-launch.cmd`: it opens a new
80x27 Windows Terminal window when `wt.exe` is available (matching the default
80x25 desktop plus menu/status rows) and otherwise runs the console executable
inside the standard `cmd.exe` host. Launching `superterm.exe` from an already-
open terminal remains supported directly.

## Implementation approach

- `st_os.pas` isolates small platform services such as PID lookup, config
  location, and Unix permission tightening.
- `st_conpty.pas` owns the native pseudo console, pipes, child process, and
  kill-on-close job object.
- Existing OS-facing units select their native branch with
  `{$IFDEF WINDOWS}` while the established Unix implementations remain under
  `{$IFDEF UNIX}`.

## Verified current state

The current checkout completes a clean FPC `-B` Win64 build and produces the
native PE x86-64 executable `D:\sources\superterm\bin\superterm.exe`.
The binary reports `superterm 4.2.1`.

The native dependency graph compiles 23 of the 26 `src/st_*.pas` units.
`st_poll.pas` is the Unix daemon's `poll(2)` registry; `st_ssh_server.pas` and
`st_ssh_entry.pas` implement the POSIX dedicated-SSH service and
`ForceCommand` adapter. All three are excluded from the native Windows program
under `{$IFDEF UNIX}`. The portable `st_cli_help.pas` is included. The
following native CLI smoke checks return successfully:

```powershell
& .\bin\superterm.exe --version
& .\bin\superterm.exe --help
& .\bin\superterm.exe --list-sessions
```

Those checks prove native loader startup, linking, and CLI dispatch. The full
interactive Free Vision/ConPTY path has also passed the end-to-end smoke test
described below.

## Implemented native Phase 1

| Area | Current Windows implementation |
|---|---|
| Paths | `OsUserHome` uses `%USERPROFILE%` with fallbacks. `OsConfigDir` uses `%APPDATA%\superterm`, falling back to the user's roaming AppData directory. |
| Console display | `st_video` owns virtual-terminal output mode and the output code page, and uses Win32 console state for size and cursor handling. |
| Keyboard and mouse | `st_kbd` owns virtual-terminal input mode and the input code page, waits on the console handle, and reads the VT byte stream with `ReadFile`. The existing decoder handles keyboard, paste, focus, and VT mouse sequences. The vendored Free Vision driver disables FPC `SysMsg` on Windows so its `winevent` thread cannot consume those bytes first. |
| PTY backend | `TConPty` creates and resizes ConPTY, starts the child with `CreateProcessW`, and owns its input/output pipes and process handles. |
| Pane processes | `TPty` wraps `TConPty` for interactive shells, `cmd.exe /d /k` commands, PowerShell/`pwsh` commands, arbitrary argv, resize, buffered input, and kill-on-close. |
| Child environment | The child receives an inherited Unicode environment overlaid with pane values including `TERM=xterm-256color`, `COLORTERM=truecolor`, `SUPERTERM=1`, and `SUPERTERM_SESSION_CHAIN`. |
| Local UI | The native `st_fvui` idle path polls ConPTY output, feeds the terminal screen, flushes pending input, detects exit, and resizes panes. |
| CLI help | Version and contextual `--help` pages run locally. Session-control commands remain unavailable because they require the detached Unix server. |
| Detached sessions | `st_server` compiles Windows Phase-1 stubs. The local single-process terminal is the Phase-1 path; detach, reattach, daemon control, and multi-client sharing deliberately report unavailable. |
| SSH panes | Structured OpenSSH argv is used. Keys or `ssh-agent` are preferred; a configured secret is retained for the native password-prompt detector, but that path still needs real-host runtime validation. |

Windows process-tree inspection is intentionally not part of Phase 1:
`FindChildProcs`, `ProcArgs`, `ProcCmdLine`, and `ProcCwd` return no data.
Pane titles therefore retain their launch command and starting directory.

## FPC 3.2.2 and WinAPI gotchas

1. The FPC `Windows` unit exports the WinAPI overload
   `GetEnvironmentVariable(PChar; PChar; LongWord)`, which shadows the
   one-argument `SysUtils` function. Code using both units must call
   `SysUtils.GetEnvironmentVariable(...)` explicitly.
2. The installed FPC 3.2.2 `Windows` unit does not declare several APIs this
   port needs. Local declarations currently cover `GetActiveProcessorCount`,
   the ConPTY and process-attribute-list calls, job-object calls, and
   `SetUnhandledExceptionFilter`. Check the installed Pascal sources and SDK
   headers listed above before adding or changing any declaration.
3. `STARTUPINFOEXW` and the required job-object limit structures are also
   declared locally in `st_conpty.pas`. The JEDI source directory listed in
   the source map is useful for broader Windows declaration research, but it
   is not part of this build's unit path.
4. Console input and ConPTY child output are different handles with different
   ownership and wait semantics. Do not replace either path with Unix
   descriptors or assume that one Win32 wait strategy covers both.
5. Free Vision's Windows `SysMsg.InitSystemMsg` installs resize and focus
   handlers in FPC `winevent`. That starts a thread which calls
   `ReadConsoleInput` on the same input handle and discards key records when
   the stock keyboard handler is absent. SuperTerm conditionally disables
   that path in `vendor/fv322/drivers.pas`; `TSuperApp.SyncTerminalSize`
   already polls size, while `st_kbd` must remain the sole input reader.

## ConPTY backend — verified

An isolated native probe using `st_conpty.TConPty` has run successfully on
this machine. It created a pseudo console, started
`cmd.exe /c echo SUPERTERM_CONPTY_OK && ver`, read the marker and
`Microsoft Windows [Version 10.0.26200...]` through the output pipe, and
observed exit code 0.

The backend exposes `Spawn`, `ReadOutput`, `WriteInput`, `Resize`, `Alive`,
`ExitCode`, and `Close`. `Spawn` builds the private Unicode environment and
uses `EXTENDED_STARTUPINFO_PRESENT` with the pseudo-console attribute.
A kill-on-close job object tears down the child process tree when the pane is
closed.

The complete native executable has also been exercised end to end in a real
Windows console session. The Free Vision UI rendered, ConPTY started
`cmd.exe`, its Windows banner and prompt appeared, typing
`echo SUPERTERM_WINDOWS_FINAL_OK` reached the pane, the marker returned
through ConPTY and appeared on screen, and Alt-X shut down SuperTerm and its
child process tree with exit code 0. The smoke run used an isolated writable
`APPDATA` below `build` because this development workspace is sandboxed; it
also created and atomically saved `session.ini` there.

## Native Phase-1 limitations

- There is no Windows detached-session server, reattach, daemon control
  channel, or multi-client sharing. The Unix server depends on `fork` and
  inherited live PTY masters; Phase 2 needs a spawned-server and explicit
  handle/ownership design rather than a direct port of that lifecycle.
- The new dedicated incoming OpenSSH service administrator and
  `--ssh-entry` adapter are POSIX-only. Windows supports outgoing SSH panes,
  but does not install or administer the isolated SuperTerm `sshd` service.
- Contextual help is portable and its index has a Windows-specific tagline,
  but the complete cross-platform reference still includes detached-session
  and `ssh-server` pages. The Windows executable rejects those POSIX-only
  operations as unavailable.
- `st_poll.pas` remains Unix-only. Phase 1 does not need it because the local
  Windows UI polls each ConPTY output pipe with `PeekNamedPipe`.
- Process exit and final pipe output are separate events. The current
  single-threaded peek/read/`Alive` sequence may close a pane during a narrow
  teardown race before every final output byte has arrived.
- `TConPty.WriteInput` uses synchronous `WriteFile`. `TPty` bounds and chunks
  its pending input, but the UI can still block if a child stops draining its
  input pipe.
- `OsRestrictFile` and `OsRestrictDir` are no-ops on Windows. Files inherit
  the user's AppData ACLs; SuperTerm does not yet apply an explicit private
  ACL. Saved configuration passwords are base64 encoded, not encrypted.
- The repository's Python PTY test suite depends on POSIX modules such as
  `fcntl`, `pty`, and `termios`. It is not a native Windows regression suite;
  current Windows confidence comes from clean builds, CLI smoke checks, the
  isolated ConPTY probe, and the full interactive smoke test described above.
- Legacy SQLite template support requires a loadable `sqlite3.dll` at runtime.
  No such DLL was found on this development machine, so that optional path is
  not yet verified.
- Because ConPTY functions are static imports, pre-1809 Windows fails at
  process load time. Supporting older Windows would require dynamically
  loading every unavailable entry point and a separate non-ConPTY backend;
  neither is a Phase-1 goal.

## Further runtime validation

The baseline local `cmd.exe` launch, input/output round trip, session save, and
clean Alt-X exit are complete. Continue with broader coverage:

1. Exercise PowerShell, `pwsh` if installed, and Git Bash profiles. Include
   executable paths, working directories, and commands containing spaces,
   quotes, pipes, and redirection.
2. Test Unicode input/output, bracketed paste, focus reporting, mouse
   forwarding, multiple panes, maximize/passthrough, rapid resize, and closing
   a pane with unread final output.
3. Stress large child output and a child that stops reading stdin to measure
   the final-output race and synchronous-write backpressure before choosing a
   reader/writer thread design.
4. Test OpenSSH first with keys/`ssh-agent`, then with a real password or
   passphrase prompt to validate the native prompt detector.
5. Confirm first-run files under the real `%APPDATA%\superterm` outside the
   development sandbox. If legacy SQLite
   templates are required, install an architecture-matched `sqlite3.dll` and
   run the SQLite migration/load tests manually.
6. Treat detached sessions as a separate Phase-2 design: define the spawned
   server protocol and ConPTY ownership transfer before enabling any server
   command on Windows.
