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

**Status: NOT yet validated at runtime.** It compiles clean and the reasoning is
traced end to end through the installed FPC 3.2.2 sources, but a console resize
is an interactive gesture and has not been performed against this build. Do that
first: maximize, restore, drag-resize slowly, drag-resize fast, and resize with
several panes open and with one maximized.

*Relevance to `main`:* the bug is Windows-only — the Unix video drivers do not
resize the terminal and do not reject sizes — so the fix itself does not belong
upstream. What might: `ApplyTerminalSize` currently trusts `SetScreenVideoMode`
without checking that `Video.ScreenWidth` actually became what was asked for. A
cheap post-condition there would have turned this into a visible failure instead
of silent corruption, on any platform whose driver can refuse.

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
- **Interactive validation of the 5.2.2 merge.** The build is clean and the CLI
  answers, but the merged interactive path has not been driven: panes,
  passthrough, the mouse, paste, and above all resize (2.1). The Python test
  suite is POSIX-only and cannot cover it.
- **`st_server.pas` stub-block hint suppression.** Acceptable while the block is
  uniformly "unavailable on this platform". If Phase 2 gives some of those
  routines real bodies, the `{$push}{$hints off}` region must shrink to only
  what is still a stub.
