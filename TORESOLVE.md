# To resolve — `windows-support`

Working notes for the Windows branch. Written while merging `main` at 5.2.2
(`cad467b`) down into `windows-support`.

This file records two different things, and the difference matters:

- **Section 1** is what the merge actually required and what was done. It is
  history, not pending work.
- **Sections 2 and 3** are candidates. Some are changes made here that may
  belong in `main` once they are proven; some are gaps still open on Windows.
  Nothing here is promoted upstream until it has been seen to work.

`main` and every other branch stay untouched. `macos-support` and
`windows-support` receive tested changes from `main` and never send any back;
see **Branch direction** in `README.md`.

---

## 1. The 5.2.2 merge

`main` at 5.2.2 replaced the client output path with an event-driven
architecture: a bounded output queue drained by a `poll(2)` reactor thread on a
private non-blocking `/dev/tty`, plus a descriptor-driven idle wait in the UI.
All of it is POSIX. It also made every compiler warning, note and hint fatal
(`-Sewnh`), which is what turned most of the work below from "tolerated
diagnostic" into "build failure".

### 1.1 Files that conflicted

| File | Conflict | Resolution |
|---|---|---|
| `Makefile.in` | `BASE_FLAGS`: the branch had `-vewnh`, `main` added `-Sewnh` | Took `main`'s strict policy. A downstream platform branch adopts the upstream build contract and fixes its own platform code to meet it. |
| `src/st_mouse.pas` | Both sides edited the implementation `uses`: the branch guarded `BaseUnix, Sockets` for Unix, `main` added `Linux` for the gpm console | Combined: `Mouse` unconditional, `BaseUnix, Sockets` under `UNIX`, `Linux` under `LINUX`. |
| `src/st_video.pas` | The branch's Windows VT-console block landed exactly where `main` inserted the output reactor | Took `main`'s file whole, then re-applied the Windows changes on top. Nine of the ten Windows hunks re-applied unchanged; only the `uses` clause was rewritten by hand. |

### 1.2 Adapting the new architecture to Windows

The reactor degrades gracefully by design: on Unix, if `/dev/tty` cannot be
opened, `AsyncOutputActive` stays `False` and every producer takes the blocking
writer. Windows Phase 1 reuses exactly that path rather than inventing a
half-reactor.

- `src/st_video.pas` — reactor thread, ring buffer, wake/progress pipes,
  non-blocking descriptor helpers and the start/stop/fork-pause lifecycle are
  now `{$IFDEF UNIX}`. Windows gets honest stubs: `StartAsyncVideoOutput` logs
  that no reactor exists, `StopAsyncVideoOutput` reports a clean drain (nothing
  was ever queued), `SignalPipe`/`DrainPipe` are no-ops, and
  `QueueOutputTransaction` refuses. A small alias block (`cint`, `TFilDes`)
  keeps the shared declarations and call sites compiling unchanged.
- `src/st_fvui.pas` — `TSuperApp.Idle`'s new `WaitForActivity` is an `fpPoll`
  over stdin, the gpm socket, the video progress pipe and either the session
  socket or every pane master. None of that exists on Windows, where ConPTY
  output arrives on anonymous pipes that Win32 cannot wait on. The Windows
  implementation waits on the console input handle alone, through a local
  `kernel32` import in this unit's established style, and the pane loop skips
  the wait whenever it just moved bytes. **This replaces the old flat
  `Sleep(8)`**, so a keystroke now wakes the loop immediately instead of after a
  fixed delay.
- `src/st_server.pas` — `main` added `TSessionClient.WaitHandle` and
  `WantsWrite` to the client reactor contract; the Windows stub section had no
  implementation and the build failed on two unsolved forward declarations.
  Added: a Phase-1 client never attaches, so it offers no descriptor and never
  wants to write.
- `src/st_mouse.pas` — `main` added `MouseInputWaitHandle` (the gpm descriptor).
  The Windows branch had none; it now returns `-1`, the same answer a Unix
  terminal emulator gives. The Windows `HostMouseOn`/`HostMouseOff` also stopped
  using `Write(Output)` and now go through the installed `WriteMouseControl`
  writer, so mouse mode sequences share st_video's single physical output path
  instead of racing it through a separate buffered text file.

### 1.3 Meeting `-Sewnh` on Windows

Fixed at the source, per the project's own `e25d9bf` policy, with two
exceptions noted below.

- `vendor/fv322/drivers.pas` — `GetDosTicks` used the deprecated
  `GetTickCount`; now `GetTickCount64`, which also drops the 49.7-day wrap.
  `FVConsts` is used only by `GetSystemEvent`'s non-Windows branch, so its
  `uses` entry is now conditional.
- `vendor/fv322/views.pas` — the CP850 frame table is selected only under
  `{$ifdef unix}`; its declaration now carries the same guard. The `Windows`
  unit was an unused dependency here (and in `app.pas`, `dialogs.pas`,
  `menus.pas`) and was removed; `drivers.pas` genuinely uses it and keeps it.
- `src/st_conpty.pas` — `ReadFile` now takes `PByte(@Buf[0])^` so an `out`
  parameter is not read; the pseudo-console attribute value is passed through an
  `absolute` alias instead of an ordinal-to-pointer cast; two unused SDK
  declarations removed (one replaced by a comment recording where the SDK
  defines it).
- `src/st_cpu.pas`, `src/st_server.pas` — units used only by POSIX code moved
  under `{$IFDEF UNIX}`; nine `TSessionClient` socket/protocol fields likewise.
- `src/st_os.pas`, `src/st_pty.pas`, `src/st_wclass.pas`, `src/st_mouse.pas`,
  `src/st_video.pas` — parameters of fixed cross-platform signatures are named
  through a local `Unused(const A)` helper, the same one the vendored Free
  Vision units use. It must be declared locally in each unit: the `Windows` unit
  exports WinAPI DDE accessors of the same name that would otherwise win.

**The two exceptions**, both local `{$push}{$hints off}` regions with a comment
saying why:

1. `src/st_server.pas`, the whole Windows Phase-1 stub block (~360 lines). Every
   routine in it keeps a shared signature and has nothing to do with its
   arguments; naming all ~90 parameters would bury the stubs it documents.
2. `vendor/fv322`, none — vendor code was fixed properly.

Result: the Win64 release build is clean at `-Sewnh -vewnh`, both through the
direct FPC command and through `configure` + `make release`. `--version`,
`--help` and `--list-sessions` all answer, and report `superterm 5.2.2`.

---

## 2. Candidates for `main` — only after they are seen to work

Do not promote any of these yet.

### 2.1 Console resize corrupts the whole interface (root cause found, fixed here)

**Symptom, reported against 4.2.1 and still reproducible before this change:**
maximizing or dragging the console window while SuperTerm is running makes the
interface come apart — everything draws wrong.

**Cause.** `ApplyTerminalSize` reads the real console size and calls Free
Vision's `SetScreenVideoMode`, which calls the RTL's `Video.SetVideoMode`, which
calls the platform driver hook. SuperTerm installs its own video driver in
`InstallWideVideoOutput` but did **not** replace `SetVideoMode`, so on Windows
the RTL's `SysSetVideoMode` ran
(`fpc/3.2.2/source/packages/rtl-console/src/win/video.pp`). That routine only
recognises a fixed table of legacy modes — 40x25, 80x25, 80x30, 80x43, 80x50 —
and returns `False` for anything else.

A rejected mode is not harmless. `Video.ScreenWidth`/`ScreenHeight` keep their
old values and `AssignVideoBuf` never runs, so the video buffer keeps its old
geometry — while Free Vision goes on to `ChangeBounds` the application to the
new size and every view draws against a buffer that no longer matches. On this
branch it also meant `RichEnsureSize` never noticed a size change, so st_video's
own delta-tracking arrays stayed at the old dimensions too.

And in the rare case where the new size *did* match the table, the RTL would
command the console back to that geometry with `SetConsoleWindowInfo` and
`SetConsoleScreenBufferSize` and clear it — fighting the resize the user just
performed.

**Fix (in `src/st_video.pas`).** A Windows `WideSetVideoMode` hook that accepts
any positive size, sets `Video.ScreenWidth`/`ScreenHeight`/`ScreenColor`,
invalidates the frame, and commands the console nothing. SuperTerm never invents
a size — `ReadTerminalSize` asks the console what the user already made the
window — so every size is valid and nothing must be resized back. Reporting
success lets the RTL reallocate the buffer, which was the only missing step.

**Status of the video-mode fix: validated interactively.** Resizing no longer
breaks the interface, which it reliably did before. A second, smaller defect
remained on top of it, diagnosed below.

### 2.1b The settled resize was never repainted — the client was stuck in `ReadFile`

**Symptom after the video-mode fix:** a maximize or restore left the old
picture on screen (the previous layout in the top-left corner, nothing below it)
until any key or click, after which everything was perfect. `Desktop -> adapt
size` always produced a correct screen.

**What was actually happening.** Nothing was wrong with the painting. The
client was not running. On Windows the console queues a `WINDOW_BUFFER_SIZE_EVENT`
record on every resize of the window **even with `ENABLE_WINDOW_INPUT` clear**,
and a `FOCUS_EVENT` on every focus change. Those records signal the input
handle, so `WaitForActivity` woke, `KPoll` called `FillBuf`, and `FillBuf`
called `ReadFile` on the handle. `ReadFile` on a console input handle only
returns characters: it discards every other record by *waiting* for the next
one that carries a character. The whole client sat inside that call from the
moment of the resize until the user pressed a key or clicked. The settle logic
then ran, applied the geometry and painted — which is why the log always showed
a correct, complete frame "after the settle", and why the user always saw it
"after the click": they were the same event.

The heartbeat gave it away. With the one-per-second `win: idle alive` line, the
trace of a maximize followed by a click reads:

```
01:24:59.555  win: idle alive screen=120x30 bounds=120x30      (maximize at 01:25:00.2)
01:25:03.232  win: idle alive screen=120x30 bounds=120x30      (mouse-down at 01:25:03.2)
01:25:03.232  win: console size seen 423x108 (was 120x30)
01:25:03.349  win: console size settled 423x108
01:25:03.364  win: console size repainted screen=423x108 bounds=423x108
```

Three and a half seconds without a heartbeat, ending exactly at the click.

**How it was pinned down** (everything lives in `notes/local/resize-harness/`,
which is gitignored):

1. A PowerShell harness launches a program in a new Windows Terminal window,
   maximizes and restores it through `ShowWindow` (or drags it through
   `MoveWindow` in steps), and captures the window with `PrintWindow` at each
   step, so the host's rendering is observed directly instead of described.
2. A minimal probe that only paints on settle (`resizeprobe.lpr`) repainted by
   itself, with every combination of SuperTerm's console setup (alternate
   screen, VT input mode, UTF-8 code page). The host was fine.
3. A tee in `RawWriteBlocking` (`SUPERTERM_TEE=path`, Windows only) captured
   every byte SuperTerm wrote, with an index of offsets per write. A second
   probe (`replayprobe.lpr`) replayed those exact bytes on settle — and painted
   correctly without input. The bytes were fine.
4. The same replay, made to read its input the way SuperTerm does
   (`replayread.lpr`: `WaitForSingleObject` on the input handle, then
   `ReadFile`), reproduced the defect exactly. The process's input path was the
   difference, and the heartbeat gap said which call.

**Fix (in `src/st_kbd.pas`, Windows only).** `CharRecordPending` peeks the
console input queue with `PeekConsoleInputW` and consumes, with
`ReadConsoleInputW`, every leading record `ReadFile` would have discarded: any
record that is not a key-down carrying a character. `FillBuf` calls `ReadFile`
only when such a record is at the head of the queue. A timed poll that wakes
without one reports "nothing" and returns to the caller's loop; a blocking read
waits again. In a debug build the consumed record types are logged
(`kbd: consumed console records without characters: 4` — 4 is the window-size
record, 16 is focus).

**Two follow-ups for the drag case.** With the stall gone, dragging a window
edge still looked wrong *while* dragging: Windows Terminal reflows the main
screen buffer on every width change, so each full-width row wrapped into two
and the picture became alternating drawn and black lines until the next frame.

- SuperTerm on Windows never entered the alternate screen. On Unix the RTL
  driver's `InitDriver` does it (smcup); the Win32 driver knows no VT, yet
  `WideDoneVideo` already emitted `?1049l` on exit. `WideInitVideo` now emits
  `?1049h` on Windows after the RTL driver. In the alternate buffer the host
  clips instead of reflowing, and the shell's scrollback survives underneath.
- `RESIZE_REFRESH_MS` went from 750 to 80, so a drag that never pauses repaints
  about twelve times a second; `RESIZE_SETTLE_MS` (120) still issues the final
  frame once the gesture stops.

**Verification.** Under the harness, with no click at all, SuperTerm shows the
settled 423x108 screen 150 ms after the maximize and the 120x30 screen after
the restore; the heartbeat has no gaps; a simulated 24-step drag shows only a
clipped picture between frames; key records injected with `WriteConsoleInput`
reach the pane. The `ESC[H ESC[2J` nudge tried before the fix was unnecessary
and has been removed.

**Earlier conclusions in this file that were wrong, kept so nobody repeats
them:**

- "`ENABLE_WINDOW_INPUT` is cleared, so no resize records are queued and the
  input handle cannot be woken by a resize." False on this host (Windows 11
  26200, Windows Terminal 1.24 over ConPTY): the record is queued and signals
  the handle regardless of the flag. The code reading was right, the inference
  about the console was speculation, and only the experiment settled it.
- "The clicks produce no log activity, so they never reach SuperTerm." False.
  The click's VT bytes were exactly what unblocked `ReadFile`; the settle lines
  that followed *were* the click's effect. Mouse reporting works.

**The resize event does exist.** `WINDOW_BUFFER_SIZE_EVENT` arrives on every
console resize whether or not it was asked for. With the drain in place it
could become the trigger instead of a poll; today the poll on each idle pass
sees the change in the same pass that consumes the record, so there is nothing
to gain yet.

*Relevance to `main`:* the mechanism is Windows-only (`ReadFile` on a console
input handle has no POSIX counterpart: `select`/`poll` readiness on a tty means
bytes). What transfers is the method, see 2.1c.

*Relevance to `main` (from 2.1):* the video-mode bug is Windows-only — the Unix
video drivers neither resize the terminal nor reject sizes — so that fix does
not belong upstream. What might: `ApplyTerminalSize` trusts `SetScreenVideoMode`
without checking that `Video.ScreenWidth` actually became what was asked for. A
cheap post-condition there would have turned this into a visible failure instead
of silent corruption, on any platform whose driver can refuse a mode. That is a
real hardening candidate for `main`, independent of Windows.

### 2.1c Debug instrumentation added for the resize hunt

All of it is silent unless `SUPERTERM_DEBUG` (or `SUPERTERM_TEE`) is set.

| Where | Line / facility | Says |
|---|---|---|
| `TSuperApp.Idle` | `win: idle alive screen=WxH bounds=WxH moving=N` | once a second, unconditionally |
| `TSuperApp.Idle` | `win: console size seen WxH (was WxH)` | the poll observed a new geometry |
| `TSuperApp.Idle` | `win: console size settled WxH screen=WxH bounds=WxH` | the geometry is about to be applied (settle or periodic refresh) |
| `TSuperApp.Idle` | `win: console size repainted screen=WxH bounds=WxH` | the forced full frame has been issued |
| `st_kbd.CharRecordPending` | `kbd: consumed console records without characters: T T ...` | record types drained before a read (4 = window size, 16 = focus) |
| `st_video.RawWriteBlocking` | `SUPERTERM_TEE=path` | every byte written to the console, plus `path.idx` with `offset length tick` per write |

Two of these generalise and are worth carrying to `main`:

- **The heartbeat.** Every hypothesis in this hunt — "the event loop is
  blocked", "the poll never sees it", "the frame is coalesced" — looks identical
  in a trace that only logs when something happens: an absence. A once-a-second
  line that prints the geometry the application currently believes in
  separates "nothing happened" from "nothing ran". It eliminated two wrong
  hypotheses in one run and then exposed the real one as a 3.5 s gap.
- **The output tee.** A byte-exact capture of what the client sent, with write
  boundaries and timestamps, lets a trivial program replay the stream from a
  process that has none of the application's other behaviour. That single
  experiment partitions every terminal-side bug into "the bytes" or "the
  process". The POSIX variant is a few lines next to `RawWriteBlocking`'s
  `fpWrite` sibling, and it would sit naturally beside `SUPERTERM_DEBUG_FULL`.

The console-size lines and the record drain line are Windows-specific and stay
here.

### 2.2 The idle wait, generalised

The Windows `WaitForActivity` replaces a fixed `Sleep(8)` with a real bounded
wait on the console input handle. `main`'s Unix version is an `fpPoll` over a
descriptor set. Both are the same idea with a different wait primitive, but they
are two separate bodies inside one nested procedure.

If a third platform ever needs it, the shape worth extracting is "collect the
things worth waking for, wait up to N ms, return" — the collection differs per
platform, the contract does not. Not worth doing for two platforms today.

### 2.3 Vendor fixes that are platform-neutral

These were needed to satisfy `-Sewnh` on Windows, but none of them is
Windows-specific and all are safe on GNU/Linux:

- `GetTickCount` → `GetTickCount64` in `vendor/fv322/drivers.pas`.
- Dropping the unused `Windows` unit from `app.pas`, `dialogs.pas`, `menus.pas`.
- Guarding the CP850 frame table in `views.pas` with the `{$ifdef unix}` its
  only use already has.

They only matter to a Windows build, so there is no urgency; carry them upstream
only if the vendored tree is being touched for another reason.

### 2.4 Detached sessions on Windows — a spawned server instead of a fork

**What was missing.** `main`'s session model makes every workspace a server
from launch: the daemon owns the PTY masters and the terminal parsers, and the
visible UI is only its first client, so closing the window never kills a shell.
On Windows that whole layer was a wall of stubs (`st_server.pas`, the
`{$ELSE}` block): `StartDetachedServer` returned `dssFailed`, `EnumerateSessions`
returned nothing, `TSessionClient` refused to connect. Detach asked for a name
and then failed; `list`, `attach`, `send`, `capture`, `kill` all reported no
sessions. The port ran one workspace in one process, and losing that process
lost the shells.

**Why the POSIX design does not port directly.** The Unix daemon is a `fork`:
the child inherits the live `TPty` objects, their master file descriptors and
the `TScreen` parsers in memory, then calls `setsid` and reopens stdio on
`/dev/null`. Windows has no `fork`, and a ConPTY pseudo console cannot change
owner after `CreatePseudoConsole` — the handles belong to the process that
made them. So a live pane cannot be handed to another process at all.

**The Windows shape: start the server first, let it make the panes.** The
server is this same executable started again as `superterm --session-daemon`
with `DETACHED_PROCESS` (no console) and its own process group, so it outlives
the window the client runs in and a closed window never reaches it. The client
serialises the workspace — name, profile, split tree, per-window geometry and,
for every pane, the *recorded launch it has not performed yet* — into a
blueprint and writes it to the server's standard input; the server parses it,
creates the ConPTYs itself (so it is their real parent), publishes the socket
and reports one status byte on its standard output. The client then attaches to
that socket as an ordinary remote client, exactly as the forked parent
re-attaches on Unix. This is why `[session] server=always` is now the default
on Windows too, and why `DeferPaneSpawn` matters: at server-always startup the
UI only *configures* each `TPty` (`ConfigureShell`/`ConfigureArgv`) and never
spawns, so the blueprint carries a launch the server can run and the pane is
born in the server, never in the client.

**The transport is real, not emulated.** AF_UNIX stream sockets have existed on
Windows 10 since 1803, and FPC's `Sockets` unit already wraps
socket/bind/listen/accept/connect/send/recv over Winsock. `WSAPoll` is
`poll(2)` for sockets. So the ~7000 lines of daemon and client — the framing,
the command FIFO, the layout leases, the snapshot, the multi-client broadcast —
compile and run unchanged; only the handful of primitives beneath them get
Windows bodies (see the merge map, §4). `console_replay_probe`, `afunix_probe`
and `daemon_probe` in `test/windows/` established each of these facts before a
line of `st_server` was touched — the AF_UNIX/WSAPoll semantics, that a
`DETACHED_PROCESS` child keeps reading its ConPTY after the parent exits, and
the one ConPTY bug below.

**The one genuine bug found on the way.** A ConPTY child launched by a process
whose own standard handles are not a console (a pipe, or `NUL` for the detached
server) inherited *those* handles and its output never reached the pseudo
console. Fixed in `st_conpty.pas` by setting `STARTF_USESTDHANDLES` with no
handles supplied, which makes the child fall back to the pseudo console's — what
a pane always wants. This also fixes ConPTY output when SuperTerm's own stdout
is redirected, so it is a correctness fix beyond the daemon.

**What replaced each POSIX primitive** (all in `st_server.pas`, Windows islands
beside the POSIX code they stand in for):

| POSIX | Windows |
|---|---|
| `fork` + inherit live objects | `CreateProcessW(--session-daemon)` + a serialised **blueprint** on stdin (`BuildBlueprint`/`ParseBlueprint`, `TPty.ExportLaunch`/`ImportLaunch`) |
| ready pipe byte | the server's stdout pipe; `SignalReady` writes one byte, the launcher `PeekNamedPipe`s for it |
| `fpPoll` on the reactor | `WSAPoll` (`st_poll.pas` and the daemon's `TPollFD`); the WSAPOLLFD record is padded to 16 bytes or every entry after the first is misaligned |
| `pipe(2)` for wake/result | a connected AF_UNIX **socket pair** (`FpPipe`), so one `WSAPoll` still covers it |
| `poll` on the PTY master | none — a ConPTY pipe is not a socket, so panes are always served by a worker thread that `PeekNamedPipe`s and reads (`FThreadLimit` forced ≥ 2) |
| `waitpid` / `SIGCHLD` reaping | none — a closed pane's kill-on-close job takes its tree down and leaves no zombie; `TrackRetiredChild`/`ReapChildren` are no-ops |
| `fcntl(F_SETLK)` name lock | `CreateFileW` with no sharing; the open *is* the lock, released by the OS on death, `ERROR_SHARING_VIOLATION` is "busy" |
| socket dev/ino identity | the socket file's NTFS creation timestamp (a re-created path cannot match) |
| `SIGHUP`/`SIGPIPE` ignore, `/dev/null` stdio | not needed: no console, and `RunSessionDaemonChild` points the RTL text files at `NUL` before anything can print |
| `~/.superterm/sessions` (0700) | `%LOCALAPPDATA%\superterm\sessions` — non-roaming and short, because an AF_UNIX path is capped at 107 bytes |

**Verified, driven from `test/windows/hosttest.ps1` with no hands on the
keyboard.** A named session starts (`--session harness1`); `list` shows it with
one client; `capture` returns the shell banner and injected input; the detach
chord (`prefix d`, injected with `WriteConsoleInput`) exits the client while the
`--session-daemon` process keeps running; `list` then shows zero clients and
`send`/`capture` still reach the live shell; a second window (`attach harness1`)
shows the earlier output plus new input; `kill` terminates the daemon and
removes the socket and sidecar.

**Still Phase-1 limited, deliberately:** the client waits on its console input
handle plus the session socket (a `WSAEventSelect` event, added to the
`WaitForMultipleObjects` set in `st_fvui.Idle`); everything else — leases,
previews, multi-client host summary — rides the shared protocol untouched.

*Relevance to `main`:* nothing here changes the Unix build's behaviour, but the
refactor that makes it possible is the thing to weigh for `main`. Today one
giant `{$IFDEF UNIX} … {$ELSE stubs} … {$ENDIF}` split `st_server`; this work
turned that into per-concern islands — the pure protocol/wire/FIFO/lease code is
now shared, and only transport, process model, reaping, locking and identity
branch. That is strictly better structure for `main` too, and it is the
precondition for the eventual "one daemon, three platforms" state. The Windows
bodies themselves stay Windows-only. See §4 for the exact per-hunk map.

### 2.5 Windows session experience: tray, auto-start, window sizing, the lock fix

Four changes made after 2.4 landed, all Windows-guarded or new files, all
candidates for `main` on the same terms as 2.4.

**The layout-lock fix (a real bug, not a nicety).** Adapting the desktop, and
moving, dragging or resizing a window, all take the daemon's layout lock first;
`LockLayout` polls the session socket for the grant. On Windows that poll asked
`WSAPoll` for `POLLIN or POLLHUP` in the *events* field, and `WSAPoll` fails the
whole call (`WSAEINVAL`, returns −1) on any bit but the read/write-normal ones —
`POLLHUP`/`POLLERR`/`POLLNVAL` are output-only status bits. So the poll returned
−1 every time, `LockLayout` burned its attempt budget in microseconds without
ever waiting, and every layout operation reported "The shared desktop is busy".
Typing and focus worked because they take no lock. Fix: `PollFd` and
`WaitSocketReady` mask *events* to `POLLIN or POLLOUT` on Windows, keeping the
status bits only for the *revents* test; `poll()` on Unix ignores them in
events, so that path is unchanged. *For `main`:* a `{$IFDEF WINDOWS}` mask in
those two helpers — copy.

**The session tray.** `superterm-tray.exe` (new file `src/traytool/`) is a
separate GUI program in the notification area: a detached session's client
leaves no window behind, so the tray is what shows a session is alive and
reopens or closes it. Right-click gives a per-session Attach/Close submenu plus
Exit; left double-click attaches the lone session. It uses only `Windows` and
`ShellApi` (`Shell_NotifyIconW`), links no project unit, launches
`superterm.exe` by path, and is built by a Windows-only `traytool` Make target
that is never part of `all`/`release`. *For `main`:* a new file plus a guarded
Make target — the same rule as `st_conpty.pas`; it cannot affect a Unix build.

**Auto-start.** On an interactive Windows launch `superterm.exe` starts the
tray if it sits next to the executable and is not already running (it opens the
tray's named mutex to tell) — `MaybeStartTray` in `superterm.lpr`, guarded, run
only after the CLI and daemon dispatch have returned. The installer adds a
checked-by-default "start the tray at sign-in" task (an `HKCU\…\Run` entry,
removed on uninstall). *For `main`:* the `MaybeStartTray` island is
Windows-only; the installer task is packaging, compiled into nothing.

**Reopen at the last size, centred.** Attaching used to open at Windows
Terminal's default size. Now the daemon records the last client physical size
as `[terminal] cols/rows` in the session sidecar (`st_server`), and the tray
reads it and launches a fresh `wt` window with `--size cols,rows` (a fresh
window, or `wt` ignores `--size`), then centres it on the monitor's work area —
or maximises it if it fills ~90%+ (closed maximised). Position is not restored:
SuperTerm cannot read the host window's screen position under ConPTY, so
centring is the deliberate comfortable placement. *For `main`:* the sidecar
write is a small guarded `st_server` hunk; the placement lives in the tray.

The installer also closes a running SuperTerm (client, session server or tray)
before replacing files — warning and confirming interactively, closing silently
under `/SILENT` for the Store — entirely inside `packaging/windows/superterm.iss`.

---

## 3. Still open on Windows

Beyond the Phase-1 limitations already listed in `docs/WINDOWS.md`:

- **Post-connect commands are dropped.** `WizardCommand` delivers the
  post-connect command by piping it into the connection's standard input with
  `printf` and a subshell. `cmd` and PowerShell provide neither, so on Windows
  the connection runs alone and the post-connect command is silently discarded.
  It needs a native equivalent, and until then it should be reported to the user
  rather than ignored.
- **Interactive validation of the 5.2.2 merge.** The build is clean, the CLI
  answers, and resize (maximize, restore, drag) is now driven and verified
  under the harness (2.1b). Still not driven on the merged path: panes,
  passthrough, the mouse, paste. The Python test suite is POSIX-only and
  cannot cover it.
- **The published assets are unsigned.** SmartScreen, the browser download
  warning and the "Unknown publisher" prompt all come from that, and only a
  CA-issued code-signing certificate removes them. The project side is done
  (version resource in the executable, `/DSIGN` in the installer script,
  `packaging/windows/sign.ps1`, `release.ps1 -Sign -Upload`); what is missing
  is the certificate itself. `docs/WINDOWS.md`, "Code signing and the
  SmartScreen warning", lists what to obtain.
- **Detached-session hardening.** The Windows server works (2.4) but has not
  been driven under the fault-injection and stress suites the POSIX daemon has
  (`session_startup_atomic`, `nonblocking_server`, `multiclient_intensive`),
  which are POSIX-only. The `.create-<name>.lock` file is left on disk after
  release, harmless but not cleaned. `OsRestrictDir`/`OsRestrictFile` are still
  no-ops, so the sessions directory and socket have no owner-only ACL yet.

---

## 4. Merge map — carrying `windows-support` into `main` behind compiler clauses

> For the step-by-step merge procedure, the feasibility verdict and the
> acceptance checklist, see **`HOWTOMERGETOMAIN.md`**. This section is the
> per-hunk map that document plans around.

This is the section that makes the eventual upstream merge mechanical. The
rule on this branch is absolute: **every Windows change is either behind
`{$IFDEF WINDOWS}` / `{$IFDEF UNIX}` (or their `IFNDEF` forms) or lives in a
new unit that only a Windows build references.** A GNU/Linux or macOS build of
this branch must produce the same binary `main` produces. When a change is
platform-neutral (a vendor fix, a `-Sewnh` cleanup) it is listed as such and is
the only kind that changes the Unix build.

How to read the table: *guard* says what the Unix compiler sees; *merge* says
what to do when the hunk is carried to `main`. "Copy" means the hunk is
self-contained and can be applied verbatim; "needs X" names the other hunk it
depends on.

### 4.1 New units (Windows only, never compiled on Unix)

| Unit | Role | Merge |
|---|---|---|
| `src/st_conpty.pas` | ConPTY backend: `CreatePseudoConsole`, `ResizePseudoConsole`, pipes, child process. `Spawn` sets `STARTF_USESTDHANDLES` with no handles so the child uses the pseudo console's, not the launcher's stdio (2.4). `PeekAvailable` exposes pending output for the daemon's pane workers. Referenced only from `st_pty.pas` under `{$IFDEF WINDOWS}`. | Copy. Unix never sees it. |

| `src/traytool/superterm-tray.lpr` (+ `README.md`) | Notification-area helper: lists live sessions, reopens one at its last size centred (`--size` + centre/maximise), closes one; `--attach NAME` CLI mode. GUI subsystem, uses only `Windows`+`ShellApi`, links no project unit. Built by the Windows-only `traytool` Make target, never in `all`/`release`. | Copy. Unix never compiles it. |

### 4.2 Guarded hunks in shared units

| Unit | What the Windows side does | Guard | Merge |
|---|---|---|---|
| `st_kbd.pas` | `KInit`/`KDone`: put the console input handle in VT mode (`ENABLE_VIRTUAL_TERMINAL_INPUT`, no line/echo/processed input, no quick-edit, no mouse/window records requested), `SetConsoleCP(CP_UTF8)`. | `{$IFDEF WINDOWS}` inside the procedures | Copy. |
| `st_kbd.pas` | `FillBuf`: wait on the input handle with `WaitForSingleObject`, then `ReadFile`. **`CharRecordPending` (2.1b)** drains window-size, focus and character-less key records with `PeekConsoleInputW`/`ReadConsoleInputW` before any `ReadFile`, so the client can never block behind a resize. | `{$IFDEF WINDOWS}` (the Unix branch is the `fpSelect` + `FileRead` pair) | Copy. Needs `st_debug` in the Windows `uses` (already guarded). |
| `st_video.pas` | `EnableVTConsole`/`RestoreVTConsole`: `ENABLE_VIRTUAL_TERMINAL_PROCESSING` + `DISABLE_NEWLINE_AUTO_RETURN`, output code page UTF-8. Called from `InstallWideVideoOutput`. | `{$IFDEF WINDOWS}` | Copy. |
| `st_video.pas` | `WideSetVideoMode` (2.1): accept any size, set `Video.ScreenWidth/Height`, never command the console. Installed as `Driver.SetVideoMode`. | `{$IFDEF WINDOWS}` around the function and the assignment | Copy. |
| `st_video.pas` | `WideInitVideo`: enter the alternate screen (`?1049h`) after the RTL driver, because the Win32 driver emits no smcup (2.1b). | `{$IFDEF WINDOWS}` inside the procedure | Copy. |
| `st_video.pas` | Output reactor: thread, ring, wake/progress pipes, non-blocking helpers, fork pause/resume are Unix; Windows has stubs that report "no reactor" and a `cint`/`TFilDes` alias block so shared declarations compile. | Reactor `{$IFDEF UNIX}`, stubs `{$IFDEF WINDOWS}` | Copy both halves together; the stubs exist because the shared call sites are unconditional. |
| `st_video.pas` | `RawWriteBestEffort`: Windows variant is the blocking writer (only reachable after a teardown Windows cannot enter). | `{$IFDEF WINDOWS}` / `{$ELSE}` | Copy. |
| `st_video.pas` | `TeeWrite` (`SUPERTERM_TEE`, 2.1c) called first thing in `RawWriteBlocking`. | `{$IFDEF WINDOWS}` | Copy; a POSIX twin is a candidate (2.1c), not a requirement. |
| `st_video.pas` | `CaptureConsoleCursor`: read the cursor with `GetConsoleScreenBufferInfo` instead of a DSR round trip; `ReleaseConsoleInput`: `FlushConsoleInputBuffer` + `RestoreVTConsole` instead of `TCFlush`. | `{$IFDEF WINDOWS}` / `{$ELSE}` | Copy. |
| `st_fvui.pas` | `WaitForActivity`: wait on the console input handle (local `kernel32` import `StWaitForSingleObject`) instead of `fpPoll` over descriptors (1.2). | `{$IFDEF WINDOWS}` / `{$ELSE}` inside the nested procedure | Copy. |
| `st_fvui.pas` | `ReadTerminalSize`: `GetConsoleScreenBufferInfo` window rect on stdout, then stderr; Unix is `TIOCGWINSZ` on fds 0..2. | `{$IFDEF WINDOWS}` / `{$ELSE}` | Copy. |
| `st_fvui.pas` | `TSuperApp.Idle`: sample the console size every pass, apply after `RESIZE_SETTLE_MS` (120) of stillness or every `RESIZE_REFRESH_MS` (80) during a drag, then one forced full frame; heartbeat and trace lines (2.1c). The Unix 250 ms `SyncTerminalSize` poll and its `LastSizeCheck` are untouched. | New code `{$IFDEF WINDOWS}`, `LastSizeCheck` `{$IFNDEF WINDOWS}` | Copy. Needs `ReadTerminalSize` and `WideSetVideoMode`. |
| `st_fvui.pas` | Passthrough re-entry writes `?1049h` and re-asserts mouse modes; pane start/resize goes through `TPty` → `TConPty`. | Mixed; see the unit's own comments | Copy with `st_pty.pas`. |
| `st_pty.pas` | `TPty` wraps `TConPty` for shells, `cmd.exe /d /k`, PowerShell/`pwsh`, argv, resize, buffered input, kill-on-close. | `{$IFDEF WINDOWS}` / `{$ELSE}` per method | Copy with `st_conpty.pas`. |
| `st_mouse.pas` | `MouseInputWaitHandle` returns `-1`; `GpmWaitFd` is Unix; `HostMouseOn`/`HostMouseOff` write through `WriteMouseControl` (1.2). | `{$IFDEF UNIX}` / `{$IFDEF WINDOWS}` | Copy. |
| `st_server.pas` | **The session daemon and client, real on Windows now (2.4).** The pure protocol/wire/FIFO/lease/snapshot code is shared. Windows islands, each beside its POSIX twin: a Winsock AF_UNIX transport prologue (constants, `TUnixSockAddr`, `TPollFD`, `fpPoll`→`WSAPoll`, `FpClose`→`closesocket`, `FpPipe`→socket pair, `fpgeterrno`); `SetCloExec`/`SetNonBlocking`; blocking `WriteFull`/`ReadFull` over a non-blocking socket; `ConnectSocket`/`ProbeSocket`/`SocketIsRecent`/`SessionsDir`/`TryHoldSessionNameLock` (`CreateFileW` no-share)/`OwnsSocketPath` (NTFS creation stamp); `TSessionClient.WaitEvent`/`EndWait` (`WSAEventSelect`); worker-forced `FThreadLimit`; `ReadPaneEvent`/`TPanePollWorker.Execute` peek-based; `TrackRetiredChild`/`ReapChildren` no-ops; sidecar via `MoveFileEx`; `SignalReady` via the stdout pipe; and the whole `{$ELSE}` tail — `BuildBlueprint`/`ParseBlueprint`, `RunSessionDaemonChild`, and a `CreateProcessW(--session-daemon)` `StartDetachedServer`. | one `{$IFDEF UNIX}`/`{$ELSE}`/`{$ENDIF}` per island; the shared code is now outside them | Do NOT copy blindly. Carrying to `main` means keeping the same island split so the Unix bodies stay byte-identical; a Unix build must be diffed before and after. The Windows bodies are Windows-only. |
| `st_pty.pas` | `ExportLaunch`/`ImportLaunch` serialise a deferred launch (shared); `OutputAvailable` (Windows peeks the ConPTY, Unix always true). | `ExportLaunch`/`ImportLaunch` shared, `OutputAvailable` `{$IFDEF WINDOWS}`/`{$ELSE}` | Copy; the shared pair is harmless on Unix. |
| `st_poll.pas` | `WSAPoll` behind the same `TSuperPoll.Clear`/`Watch`/`Wait`; the WSAPOLLFD record is padded to 16 bytes. | `{$IFDEF WINDOWS}`/`{$ELSE}` throughout | Copy. |
| `superterm.lpr` | `--session-daemon` dispatches to `RunSessionDaemonChild` before the UI. | `{$IFDEF WINDOWS}` | Copy. |
| `st_debug.pas` | Log file through a Win32 handle, crash dir from `%TEMP%`; POSIX uses `fpOpen`, signals, `/tmp`. | `{$IFDEF WINDOWS}` / `{$ELSE}` | Copy. |
| `st_os.pas`, `st_config.pas`, `st_wclass.pas`, `st_cli_help.pas`, `st_artbg.pas` | Paths (`%ProgramData%`, `%LOCALAPPDATA%`), process helpers, help text naming Windows, background loading. | `{$IFDEF WINDOWS}` per hunk | Copy; each hunk is independent. `git diff main -- src/<unit>` lists them. |

| `st_server.pas` | `PollFd`/`WaitSocketReady` mask the `events` field to `POLLIN\|POLLOUT` for `WSAPoll` (status bits fail the call with −1); the fix for every layout op reporting "shared desktop is busy" (2.5). | `{$IFDEF WINDOWS}` / `{$ELSE}` in both helpers | Copy. |
| `st_server.pas` | `TDetachedSession` records the last client host size and writes `[terminal] cols/rows` in the sidecar (2.5), so a re-attach can restore the window size. | `{$IFDEF WINDOWS}`-guarded field/writes | Copy; the field is inert on Unix. |
| `superterm.lpr` | `--session-daemon` dispatch (2.4) and `MaybeStartTray` on interactive start (2.5); `{$R superterm.res}` and `Windows` in `uses`. | `{$IFDEF WINDOWS}` | Copy; qualify `SysUtils.GetEnvironmentVariable` (the `Windows` unit shadows it). |

### 4.3 Platform-neutral changes (the only ones that touch the Unix build)

Note (2.4): making `st_server` build on Windows moved several units in its
`uses` from the `{$IFDEF UNIX}` list to unconditional (`IniFiles`, `Sockets`,
`st_wclass`, `st_session`, `st_poll`, `st_cpu`, added `st_os`), and replaced
`fpGetPid` with `OsGetPid` in shared code. On Unix these are the same symbols
that were already linked; the effect is nil but the source is not
byte-identical, so a `main` merge of §2.4 must rebuild and diff the Unix binary
per §4.4 rather than assume it is untouched.

| Where | Change | Why it is safe |
|---|---|---|
| `vendor/fv322/drivers.pas` | `GetTickCount` → `GetTickCount64`; `FVConsts` in `uses` only `{$IFNDEF OS_WINDOWS}` | Same value modulo the 49.7-day wrap; the unit is only used by the non-Windows branch. |
| `vendor/fv322/views.pas` | CP850 frame table declared under the same `{$ifdef unix}` that selects it; unused `Windows` unit removed | Declaration matches its only use; the unit was never referenced. |
| `vendor/fv322/app.pas`, `dialogs.pas`, `menus.pas`, `msgbox.pas` | Unused `Windows` unit removed; `-Sewnh` cleanups | No code path changes. |
| `src/*` `Unused(const A)` helpers, `{$push}{$hints off}` region | Diagnostic hygiene for `-Sewnh` (1.3) | No code path changes; the helper must stay local per unit (`Windows` exports a colliding `Unused`). |
| `Makefile.in`, `configure` | Windows target detection, `.exe` suffix, GNU Make 3.80 compatibility | Unix paths unchanged. |
| `packaging/windows/`, `docs/WINDOWS.md`, `HOWTOMERGETOMAIN.md` | Installer (incl. its close-running-instance and sign-in auto-start `[Code]`/`[Tasks]`, compiled into nothing), launcher, `traytool`/size-restore notes, this merge guide | New files. |

### 4.4 The procedure

1. Carry a hunk only when 2.x says it has been seen to work here, with the
   evidence next to it.
2. Apply it with its guard exactly as it is on this branch. Never un-guard to
   "simplify": the guard is what proves the Unix build unchanged.
3. Build `main` on GNU/Linux at the strict contract and confirm the binary is
   byte-identical before and after (only 4.3 rows may change it, and each says
   how).
4. Build the Win64 target from `main` and run `notes/local/resize-harness/`
   (maximize, restore, drag, injected keys) on the result.
5. Record the promotion in this file: move the row from 2.x to 1.x history.
