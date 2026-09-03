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
- **`st_server.pas` stub-block hint suppression.** Acceptable while the block is
  uniformly "unavailable on this platform". If Phase 2 gives some of those
  routines real bodies, the `{$push}{$hints off}` region must shrink to only
  what is still a stub.

---

## 4. Merge map — carrying `windows-support` into `main` behind compiler clauses

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
| `src/st_conpty.pas` | ConPTY backend: `CreatePseudoConsole`, `ResizePseudoConsole`, pipes, child process. Referenced only from `st_pty.pas` under `{$IFDEF WINDOWS}`. | Copy. Unix never sees it. |

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
| `st_server.pas` | Phase-1 stub block: every session/daemon/socket routine reports "unavailable on this platform"; `WaitHandle`/`WantsWrite` added for `main`'s reactor contract (1.2); POSIX units and nine socket fields under `UNIX`. | `{$IFDEF WINDOWS}` block, `{$push}{$hints off}` inside it (1.3) | Copy. Shrink the hint region when Phase 2 lands. |
| `st_debug.pas` | Log file through a Win32 handle, crash dir from `%TEMP%`; POSIX uses `fpOpen`, signals, `/tmp`. | `{$IFDEF WINDOWS}` / `{$ELSE}` | Copy. |
| `st_os.pas`, `st_config.pas`, `st_wclass.pas`, `st_cli_help.pas`, `st_artbg.pas` | Paths (`%ProgramData%`, `%LOCALAPPDATA%`), process helpers, help text naming Windows, background loading. | `{$IFDEF WINDOWS}` per hunk | Copy; each hunk is independent. `git diff main -- src/<unit>` lists them. |

### 4.3 Platform-neutral changes (the only ones that touch the Unix build)

| Where | Change | Why it is safe |
|---|---|---|
| `vendor/fv322/drivers.pas` | `GetTickCount` → `GetTickCount64`; `FVConsts` in `uses` only `{$IFNDEF OS_WINDOWS}` | Same value modulo the 49.7-day wrap; the unit is only used by the non-Windows branch. |
| `vendor/fv322/views.pas` | CP850 frame table declared under the same `{$ifdef unix}` that selects it; unused `Windows` unit removed | Declaration matches its only use; the unit was never referenced. |
| `vendor/fv322/app.pas`, `dialogs.pas`, `menus.pas`, `msgbox.pas` | Unused `Windows` unit removed; `-Sewnh` cleanups | No code path changes. |
| `src/*` `Unused(const A)` helpers, `{$push}{$hints off}` region | Diagnostic hygiene for `-Sewnh` (1.3) | No code path changes; the helper must stay local per unit (`Windows` exports a colliding `Unused`). |
| `Makefile.in`, `configure` | Windows target detection, `.exe` suffix, GNU Make 3.80 compatibility | Unix paths unchanged. |
| `packaging/windows/`, `docs/WINDOWS.md` | Installer, launcher, documentation | New files. |

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
