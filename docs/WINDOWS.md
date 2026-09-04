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

### Windows icon, version resource and installer

`src/superterm.rc` embeds the application icon
(`packaging/windows/alien-hacker.ico`) and the version resource that Explorer,
the UAC prompt and SmartScreen read: publisher, product, description,
copyright and the version numbers. The version comes from `VERSION`: the
Makefile writes it into `src/superterm_version.rh` and recompiles the
committed `src/superterm.res` with `windres` on every Windows build, so the
Details tab can never disagree with `--version`. To rebuild the resource by
hand after changing the icon:

```powershell
$Windres = 'D:\lazarus\fpc\3.2.2\bin\x86_64-win64\windres.exe'
Set-Location src; & $Windres -i superterm.rc -o superterm.res; Set-Location ..
```

The installer, the flat zip, the checksums and the upload to the GitHub
release are one command, documented in `packaging/windows/README.md`:

```powershell
powershell -ExecutionPolicy Bypass -File packaging\windows\release.ps1 [-Sign] [-Upload]
```

The installer is `dist\SuperTerm-5.2.2-windows-x64-setup.exe`; it installs
under `%LOCALAPPDATA%\Programs\SuperTerm` without elevation and includes the
executable, documentation, configuration example, and desktop backgrounds.
Compiling it alone, from PowerShell (never from Git Bash, which rewrites
ISCC's `/` switches as paths):

```powershell
& 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe' packaging\windows\superterm.iss
```

The Start-menu and desktop shortcuts use `superterm-launch.cmd`: it opens a new
120x52 Windows Terminal window when `wt.exe` is available (matching the default
120x50 desktop plus menu/status rows); SuperTerm then creates its initial 80x25
panel minimized inside that desktop. Otherwise it runs the console executable
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
The binary reports `superterm 5.2.2`.

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
| CLI help | Version and contextual `--help` pages run locally. Session-control commands (`list`, `attach`, `send`, `capture`, `kill`, window ops) work against the session server. |
| Detached sessions | Work. The server is a separate `superterm --session-daemon` process (no fork on Windows) that owns the ConPTY panes; detach, reattach, `list`, control commands and `kill` behave as on Unix, over the same AF_UNIX socket and protocol. See the section below. Multi-client sharing is unverified under load. |
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

## Console resize and input — verified

Resizing, maximizing, restoring and dragging the console window repaint by
themselves. Four pieces make that true, all behind `{$IFDEF WINDOWS}`:

- `st_video.WideSetVideoMode` accepts whatever size the console reports. The
  RTL Win32 driver only knew a table of legacy modes; it refused every other
  size, or commanded the console back to a table entry.
- `st_video.WideInitVideo` enters the alternate screen. The RTL Win32 driver
  emits no smcup, while `WideDoneVideo` always emitted `?1049l`. Windows
  Terminal clips the alternate buffer during a drag instead of reflowing every
  full-width row into two, and the shell's scrollback survives underneath.
- `st_kbd.CharRecordPending` consumes the console input records that carry no
  character before `ReadFile` is called. The console queues a
  `WINDOW_BUFFER_SIZE_EVENT` on every resize even with `ENABLE_WINDOW_INPUT`
  clear, and a `FOCUS_EVENT` on every focus change; both signal the input
  handle, and `ReadFile`, which only returns characters, would otherwise block
  the whole client until the next keystroke or click. That block was the
  "repaints only when I click" symptom: the frame was always correct, it was
  emitted when the click arrived.
- `TSuperApp.Idle` samples the console size every pass, applies it after
  120 ms of stillness or every 80 ms while it keeps changing, and paints one
  full frame.

Diagnostics, silent unless asked for: `SUPERTERM_DEBUG=path` logs `win: idle
alive` once a second, `win: console size seen/settled/repainted`, and `kbd:
consumed console records without characters: 4` (4 is window size, 16 is
focus). `SUPERTERM_TEE=path` copies every byte written to the console into
that file, with `path.idx` recording `offset length tick` per write, so a
frame can be replayed outside SuperTerm.

`test/windows/` drives all of this from a script — maximize, restore, drag,
injected keystrokes — and captures what Windows Terminal renders, so the check
needs nobody at the keyboard. `TORESOLVE.md` §2.1 is the full account and §4
the per-file merge map.

## Code signing and the SmartScreen warning

A downloaded `SuperTerm-<version>-windows-x64-setup.exe` is met by "Windows
protected your PC" (SmartScreen) and, if it gets past that, a "Publisher:
Unknown" prompt. Both come from one fact: the file carries no Authenticode
signature, so Windows has no publisher to name and no reputation to consult.
Nothing in the code can change that. What removes the warnings is signing
`superterm.exe`, the setup and its uninstaller with a **code-signing
certificate issued by a CA in Microsoft's trust program**, with an RFC 3161
timestamp so the signature outlives the certificate. The publisher Windows
then shows is the certificate's subject. A self-signed certificate does not
help outside machines where it has been installed by hand.

What to obtain, checked against the CA's current terms before buying:

- **Azure Trusted Signing** (Microsoft's cloud signing service): a monthly
  subscription with identity validation, no hardware token, and signatures
  that SmartScreen treats as coming from a known publisher. `signtool` uses it
  through `/dlib` with `Azure.CodeSigning.Dlib.dll` and a metadata JSON.
- **An OV or EV code-signing certificate** from a CA (DigiCert, Sectigo,
  GlobalSign, SSL.com, Certum and others). Since 2023 the private key must
  live on a hardware token or an HSM; the certificate then appears in the
  user's store and is selected by thumbprint. EV certificates have
  historically started with SmartScreen reputation; OV ones earn it as the
  signed files are downloaded. Certum offers a reduced-price certificate for
  open-source projects.

What the project already does, so that signing is one switch:

- `src/superterm.rc` gives `superterm.exe` a version resource: publisher,
  product, description, copyright and the version from `VERSION` (the
  Makefile regenerates `superterm.res` with `windres`). Explorer's Details
  tab, the UAC prompt and antivirus heuristics all read it.
- `packaging/windows/sign.ps1` signs and verifies files with `signtool`. The
  certificate comes from the environment: `SUPERTERM_SIGN_THUMBPRINT`, or
  `SUPERTERM_SIGN_PFX` with `SUPERTERM_SIGN_PFX_PASSWORD`, or
  `SUPERTERM_SIGN_DLIB` with `SUPERTERM_SIGN_METADATA` for Trusted Signing.
  Without one it refuses, so a signed build cannot come out unsigned.
- `packaging/windows/superterm.iss` signs the setup, the uninstaller and
  `superterm.exe` when compiled with `/DSIGN` and the sign tool hook:

```
ISCC.exe /DSIGN "/Ssuperterm=powershell.exe -NoProfile -ExecutionPolicy Bypass -File packaging\windows\sign.ps1 $f" packaging\windows\superterm.iss
```

- `packaging/windows/release.ps1` does the whole release: `make release`
  through Git's bash, the version checks, signing, the installer, the flat
  zip, the `.sha256` files, and with `-Upload` replaces the four Windows
  assets on the GitHub release `v<version>` using the token Git Credential
  Manager already holds.

```powershell
$env:SUPERTERM_SIGN_THUMBPRINT = '<thumbprint>'
powershell -ExecutionPolicy Bypass -File packaging\windows\release.ps1 -Sign -Upload
```

Until a certificate exists, `release.ps1` without `-Sign` produces the same
unsigned assets as before, and the warnings remain.

## Native Phase-1 limitations

- Detached sessions now work (see the section below). Multi-client sharing
  rides the same protocol but has not been driven under load on Windows;
  treat more than two simultaneous viewers as unverified for now.
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
- A window class post-connect command is dropped. `WizardCommand` delivers it
  by piping it into the connection's standard input with `printf` and a
  subshell; `cmd` and PowerShell provide neither, so the connection runs alone
  and the post-connect command is silently discarded.
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

## Detached sessions — a spawned server

Every workspace is a server from launch on Windows too (`[session]
server=always`, the default). Because Windows has no `fork` and a ConPTY
cannot change owner, the server is a separate process — this same executable
started as `superterm --session-daemon` with no console — that receives the
workspace on its standard input and creates the panes itself, so it is their
real parent and outlives the window you launched from. The visible UI is its
first client over an AF_UNIX socket (Windows 10 1803+), exactly the transport
and protocol the POSIX build uses; only the primitives beneath it (process
start, `WSAPoll`, the name lock, socket-file identity) have Windows bodies.

What works, and how to check it without any GUI:

- `superterm --session NAME` starts NAME as a server and attaches to it.
- prefix + `d` (default prefix Ctrl-Q) detaches: the window closes, the server
  and its shells keep running.
- `superterm list` / `attach NAME` / `send` / `capture` / `kill` behave as on
  Unix; sessions live under `%LOCALAPPDATA%\superterm\sessions`.
- `test\windows\session_smoke.ps1` drives the whole cycle (start, list,
  send, capture, detach, reattach, kill) and asserts each step.

Known Phase-2 gaps: the sessions directory and socket have no owner-only ACL
yet (`OsRestrictDir`/`OsRestrictFile` are no-ops); the `.create-<name>.lock`
file is left on disk after use; the POSIX fault-injection and stress suites
are not ported. `TORESOLVE.md` section 2.4 is the full design and section 4
the per-file merge map for carrying it toward `main`.

## Further runtime validation

The baseline local `cmd.exe` launch, input/output round trip, session save, and
clean Alt-X exit are complete. Continue with broader coverage:

1. Exercise PowerShell, `pwsh` if installed, and Git Bash profiles. Include
   executable paths, working directories, and commands containing spaces,
   quotes, pipes, and redirection.
2. Test Unicode input/output, bracketed paste, focus reporting, mouse
   forwarding, multiple panes, maximize/passthrough, and closing a pane with
   unread final output. Resize, maximize, restore and drag are covered by
   `test/windows/hosttest.ps1`.
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
