# Windows console harness

The Python suite in `test/` is POSIX-only. This directory holds what the
native Windows build is checked with: a PowerShell harness that drives a
program in a real Windows Terminal window and captures what the host renders,
two small probes that isolate host behaviour from SuperTerm's, and helpers to
read a console buffer or feed it keystrokes from outside.

It exists because of the console-resize defect described in `TORESOLVE.md`
§2.1: SuperTerm's log proved it emitted a correct full frame after every
resize, and the screen still did not change until the user clicked. Only
observing the window directly, from a script, showed what the host was doing;
only replaying SuperTerm's exact bytes from a bare program showed that the
bytes were fine; and only making that bare program read its input the way
SuperTerm did reproduced the defect. Every step is repeatable from here.

## Requirements

- Windows 10 1809+ with Windows Terminal as the default terminal (the
  harness starts the program with `wt.exe -w -1 new-tab`; `-Conhost` uses the
  legacy console instead).
- Windows PowerShell 5.1 (`powershell.exe`), run with `-ExecutionPolicy
  Bypass`.
- A built `bin\superterm.exe` for the SuperTerm runs; Free Pascal for the
  probes.

The harness pops a window on the desktop, maximizes, restores or drags it,
and closes it. Do not touch the mouse or keyboard while it runs; a click of
your own is exactly the input that used to mask the defect.

## Maximize and restore

```powershell
powershell -ExecutionPolicy Bypass -File test\windows\hosttest.ps1 `
  -Exe D:\sources\superterm\bin\superterm.exe -Tag ST1 `
  -DebugLog $env:TEMP\st-ST1.log
```

Captures land in `test\windows\shots\ST1\` as `0-initial`, `1-maximized`,
`3-restored` (each with `-tl` and `-br` crops at full resolution). With
`-Click` the harness also clicks into the window after each resize and
captures `2-maximized-clicked` and `4-restored-clicked`, which is how the
pre-fix behaviour was recorded: correct only in the clicked captures.

The debug log is where the mechanism shows. Lines to look for:

| Line | Meaning |
|---|---|
| `win: idle alive screen=WxH bounds=WxH moving=N` | once a second while the client runs. A gap is a stall. |
| `kbd: consumed console records without characters: 4` | a window-size record (4) or focus record (16) was drained before reading input |
| `win: console size seen WxH (was WxH)` | the poll saw a new geometry |
| `win: console size settled WxH ...` | the geometry is applied (after 120 ms still, or every 80 ms during a drag) |
| `win: console size repainted ...` | one full frame was issued |

A healthy maximize reads: `consumed ... 4`, `seen`, `settled` about 120 ms
later, `repainted`, heartbeat continuous. The defect read: heartbeat stops at
the resize and resumes at the click, with `seen` in the same millisecond as
the click.

## Drag

```powershell
powershell -ExecutionPolicy Bypass -File test\windows\hosttest.ps1 `
  -Exe D:\sources\superterm\bin\superterm.exe -Tag DRAG1 -Drag `
  -DebugLog $env:TEMP\st-DRAG1.log
```

Grows the window in 24 steps of 48x28 pixels every 40 ms, then shrinks it
back, capturing mid-drag (`1-mid-grow`, `4-mid-shrink`), at the end of each
gesture, and 500 ms later. Mid-drag captures should show the previous frame
clipped or extended with blank space, never rows wrapped into two: that
wrapping is Windows Terminal reflowing the main buffer, and it is why the
Windows client now runs on the alternate screen.

## Keyboard through the new input path

```powershell
... -InjectText 'echo KEYS-OK'
```

Feeds key-down/key-up records with `WriteConsoleInput` into the program's
console before the first capture, independent of window focus. The text must
appear in the pane in `0-initial`. This is the regression check for
`CharRecordPending`: the drain must consume window-size and focus records and
nothing else.

## Looking inside conhost

`condump.ps1 -ProcId <pid> -Out file` attaches to the console of `<pid>` and
writes buffer size, window rectangle, cursor, output mode and every row with
its distinct attributes. It answers "did the bytes reach conhost" separately
from "did Windows Terminal render them". Pass it through `-Hook`:

```powershell
$hook = { param($stage)
  $p = Get-Process superterm | Select-Object -First 1
  powershell -NoProfile -ExecutionPolicy Bypass -File test\windows\condump.ps1 `
    -ProcId $p.Id -Out "test\windows\shots\ST1\condump-$stage.txt" }
... -Hook $hook
```

When the program was started through the harness's `-DebugLog`/`-Tee`
wrapper, attach to the wrapper `cmd.exe` instead (it shares the console).

## Detached sessions

`session_smoke.ps1` exercises the Windows session server end to end without a
person at the keyboard: it starts a named session in a Windows Terminal
window, detaches it by injecting the prefix chord with `WriteConsoleInput`,
confirms the `--session-daemon` process outlives the window, reattaches in a
second window, and kills the session, asserting every CLI answer.

```powershell
powershell -ExecutionPolicy Bypass -File test\windows\session_smoke.ps1
```

It leaves nothing behind on success. The session server design is in
`TORESOLVE.md` section 2.4.

## Probes

`console_resize_probe.pas` paints a numbered checkerboard on every settled
resize and never reads input. If it repaints by itself, the host is fine.
Flags `alt`, `vtin` and `utf8` add SuperTerm's console setup one piece at a
time.

`console_replay_probe.pas` replays a byte capture. Record one with
`-Tee $env:TEMP\st.bin`: SuperTerm copies every console write there, and
`st.bin.idx` lists `offset length tick` per write, so the frame after a
resize is easy to find (the largest write) and cut out:

```sh
tail -c +$((OFFSET+1)) st.bin | head -c LENGTH > big.bin
```

Run the probe with the prelude, the initial frame, the resize frame, the
7-byte nudge and the restore frame; with `readinput` as a sixth argument it
also reads its input the way the keyboard driver did before the fix, which
is the exact reproduction of the stall.

```sh
fpc -Mobjfpc -Sh -FUbuild/units/win-release -FEbin test/windows/console_resize_probe.pas
fpc -Mobjfpc -Sh -FUbuild/units/win-release -FEbin test/windows/console_replay_probe.pas
```

`analyze_frames.py` summarises what a cut frame contains (sequence kinds,
absolute positions, whether autowrap or cursor visibility is touched).

## Reading the captures

Open the PNGs, or feed them to anything that can look at an image. Judging
them takes two questions: does the picture fill the new window size without a
click, and does the pane text (a prompt, the injected text) sit where the
layout at that size puts it. The `-tl` crop is enough for both when the row
headers of the probe or the menu bar of SuperTerm are what matters.
