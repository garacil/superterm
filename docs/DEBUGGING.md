# Debugging superterm

superterm traces itself. A build made with `make debug` writes what it is
doing to a file, and if it dies it leaves a report with a backtrace that names
the source file and line. This is how to turn that on, how to read it, and how
to reproduce a problem without a person sitting in front of the terminal.

## The debug build

```sh
make debug          # -> bin/superterm-debug
```

That build carries the runtime checks — range and overflow — and, more
importantly, **it traces on its own**: no environment variable to remember.
The release build in `bin/superterm` keeps line information too (`-gl`), so a
crash report from it also names files and lines; what it does not do is trace
unless asked.

## Turning tracing on

| variable | effect |
|---|---|
| `SUPERTERM_DEBUG=/path/to/file.log` | where to write. A release build traces only when this is set |
| `SUPERTERM_DEBUG_FULL=1` | add the per-frame detail (`video: update`, `draw pane`). `=0` removes it even from a debug build |

A debug build defaults to `/tmp/st-crash.log`, in full mode. Either variable
given from outside wins, `SUPERTERM_DEBUG_FULL=0` included.

The client and the session daemon write to the same file when they share the
variable, and every line carries the role and the pid, so the two can be told
apart afterwards. Give the client a different file to keep them separate from
the start.

## Tracing a session someone else is going to use

The daemon is a fork of the first client, so it inherits the tracing
variables. Create the session, detach it, and hand over the name: the daemon
stays alive and traces, and the other person attaches when they are ready.

```sh
python3 - <<'PY'
import sys
sys.path.insert(0, 'test')
import stlib
stlib.BIN = 'bin/superterm-debug'
c = stlib.Client('/root', w=120, h=40,
                 env={'SUPERTERM_DEBUG': '/tmp/st-dbg.log',
                      'SUPERTERM_DEBUG_FULL': '1'})
c.drain(3.5)
c.send(b'\x11', 0.5)      # the prefix key
c.send(b'd', 1.6)         # detach
c.send(b'\r', 2.0)
c.wait_exit(timeout=10)
c.close()
print(stlib.run_cli(['list'], '/root').stdout)
PY
```

Then they attach with a trace file of their own:

```sh
SUPERTERM_DEBUG=/tmp/st-dbg-client.log SUPERTERM_DEBUG_FULL=1 \
  bin/superterm-debug attach <session>
```

Two things worth knowing:

- **Sessions are found through `HOME`.** A session created with `HOME=/root`
  appears in that user's ordinary `superterm list`; one created with a
  different `HOME` does not, and the `HOME=` has to travel with the attach
  command.
- Full tracing grows quickly. It is meant for a reproduction, not for a day.

## Reading a trace

Lines are `HH:MM:SS.mmm [pid role] message`, where the role is `client` or
`daemon`. The per-frame lines are the bulk of it and rarely what you want
first:

```sh
grep -v "video: update\|draw pane=" /tmp/st-dbg.log | less
```

| prefix | what it tells you |
|---|---|
| `mouse:` | `TERM`, whether this is a console, and `ButtonCount` — **zero means no mouse at all** |
| `== BOOT:` | startup, followed by `init: sysini=... classes=N profiles=N` |
| `startpane i=N ... win=... term=... scr=WxH` | a pane created locally, with the objects behind it |
| `attach: panes=N geom=N desk=WxH focused=N` | this client attached to a daemon, i.e. it is in remote mode |
| `resize: pane=N ...`, `resize master=fd` | size negotiation, and the ioctl that reaches the pty |
| `pass: ENTER/EXIT pane=N` | passthrough: a pane owning the terminal |
| `scrollbar: ScrollDraw pane=N value=...` | the scrollbar, and which pane it believes it drives |
| `fvui: RepaintChanges` | an incremental repaint |
| `spawn ok master=fd pid=N program=...` | the program behind a pane |

## When it crashes

The trace ends with a line like:

```
*** FATAL SIGSEGV (invalid memory access) -- report in /tmp/superterm-crash-client-1670688-20260823-145144-6984A5.log
```

The name carries the role, the pid, the date and a hash, so several reports
coexist without overwriting each other. Inside:

- the reason, the role, the pid and the parent, and how long the process had
  been up;
- **a backtrace with file and line**, which is usually the whole answer;
- the last 400 lines of trace.

Read the backtrace from the bottom up: it is the path that led there.

```
SYNCSCROLLBAR,  line 1361 of src/st_fvui.pas    <- died here
REPAINTCHANGES, line 472 of src/st_fvui.pas
DOCLOSEPANE,    line 3940 of src/st_fvui.pas
CLOSE,          line 1532 of src/st_fvui.pas
```

If the backtrace is bare addresses with no names, the binary was built without
line information: rebuild and reproduce.

## Reproducing without a terminal in front of you

`test/stlib.py` is the harness the test battery is built on. It starts a real
client on a pty and reads it with `pyte`, so anything a person can do to
superterm can be done from a script — and measured.

```python
import sys
sys.path.insert(0, 'test')
import stlib

c = stlib.Client(HOME, w=110, h=34, lang='en')   # or args=['--attach', 'name']
c.drain(2.5)
c.send(b'\x1bOQ', 1.5)             # F2
print(c.text())                     # the screen as text
c.screen.buffer[y][x].fg            # a cell's colour: 'default', 'green', 'ff6400'
c.raw()                             # every byte the client wrote to the terminal
stlib.run_cli(['list', '.'], HOME)  # the control CLI against the same session
```

`c.raw()` is the right tool for anything about the terminal itself — mouse
modes, SGR sequences, what is emitted and what is not. `c.screen.buffer` is
the right one for what ends up on screen, cell by cell.

Useful keys: `\x1b[15~` F5, `\x1bOQ` F2, `\x1b[17~` F6, `\x1b[20;3~` Alt-F9,
`\x1b1` Alt-1, `\x11` the prefix key (Ctrl-Q by default), `\x1bx` Alt-X. Mouse
reports are SGR 1006: `\x1b[<0;COL;ROWM` presses and `...m` releases. Row 1 is
the menu bar — a click there opens a menu and swallows the keys that follow.

## Traps worth knowing before you measure

- **A shell echoes what is typed**, and the echo carries the same words as the
  output. Waiting for a marker that also appears in the command line measures
  the echo. Assemble the marker in the shell — `E=EN'D'`, then `printf '%s' "$E"`
  — so the word exists only in the output.
- **A line printed with a trailing `\r` and no newline is overwritten by the
  next prompt.** The renderer coalesces frames on purpose, so a line that only
  existed between two frames may never be emitted at all. End in `\n` when the
  point is to check what was painted.
- **Pictures are read from where they are installed** — `$SUPERTERM_BACKGROUNDS`,
  `~/.superterm/backgrounds`, then the system directory — before the source
  tree. After editing a `.art`, run `make install` or you will measure the old
  one.
