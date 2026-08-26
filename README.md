# superterm 4

**Project site: [www.superterm.org](https://www.superterm.org)**

`superterm` is a terminal multiplexer written in Free Pascal. It provides a
Turbo Vision-style window and pane interface inside one terminal, while every
visible pane remains a real PTY/ConPTY-backed terminal.

It is designed for working with several local shells and remote SSH sessions
at once. Sessions can be restored automatically, named profiles can describe
repeatable workspaces, and the session wizard can launch a small ad-hoc
workspace without editing a configuration file.

On GNU/Linux and macOS, **every session is a client/server pair from the
moment it starts**: the terminal you see is just the first attached client.
That makes superterm far more than a window manager for shells — the entire workspace
can be driven from any other shell, script, cron job or automation tool,
with control commands and their command-local options accepted **in English
and in Spanish**:

```sh
superterm send prod:2 tail -f /var/log/syslog   # type into any pane
superterm capture prod:2 --history | grep ERROR # dump 100k lines of scrollback
superterm new prod --cmd htop -t Monitor        # open panes from outside
superterm focus prod:Monitor                    # move the focus
superterm organize prod grid                    # re-tile every window
superterm listar prod                           # the same CLI, en español
```

Meanwhile several people (or several of your own terminals) can be attached
to that same session at once, each seeing every keystroke, title change and
window operation live — and a slow or dead client can never stall the rest.
Full reference: [`docs/CLI.md`](docs/CLI.md).

The native Windows build runs the same interactive workspace locally through
ConPTY. Its detached server, multi-client attach, and control CLI are not yet
available.

![superterm four-pane workspace](screenshots/four-pane.png)

Four independent PTY/ConPTY-backed panes in a normal GNU/Linux, macOS, or
Windows terminal window: a process list, disk usage, a coloured application
log and a git history. Each pane keeps its own process, terminal state and
size; the session has one shared focus.

## Features

- Vertical and horizontal pane splits, focus navigation, mouse focus, resize,
  maximize, minimize, restore, and close operations.
- Up to 16 panes in one visible layout.
- Window classes (`[class.*]`): reusable named pane definitions for local
  commands and structured SSH connections with keys, agents, optional
  `sshpass` password support, and post-connect commands.
- Profiles (`[profile.*]`): named workspaces of windows and pane layouts
  whose panes reference window classes. Legacy `[t-*]` terminals and
  `[template.*]` templates (INI or SQLite) are still read and migrated.
- On GNU/Linux and macOS, every session is a server from launch (tmux-style):
  the visible terminal is just the first attached client, and the whole
  workspace can be driven from another shell with the control CLI.
  `[session] server=detach` restores the classic detach-only flow.
- Optional per-pane event reactors can parse independent PTY streams on
  multiple CPU cores. `[session] multithread=1` preserves the original
  single-threaded daemon; `auto` or a total thread limit enables dynamic
  workers, each with its own `fpPoll`, on GNU/Linux and macOS.
- On GNU/Linux and macOS, a bilingual control CLI (commands and documented
  long options accept English and Spanish without case/accent distinctions;
  short options stay exact and
  case-sensitive; output uses the configured UI language): `list/listar`,
  `send/enviar`, `capture/capturar` (visible screen, last N lines or the
  whole scrollback), `kill/matar`, plus full window management from the
  command line — `new/nueva`, `close/cerrar`, `focus/foco`,
  `rename/renombrar`, `resize/tamano`, `minimize/minimizar`,
  `restore/restaurar`, `zoom/ampliar` and `organize/organizar`. See
  [`docs/CLI.md`](docs/CLI.md). The built-in `--help` index links to a complete
  page for every command and option.
- On GNU/Linux and macOS, true multi-user sessions: up to 8 clients attached
  to the same session at once, with one daemon-owned desktop -- positions,
  sizes, minimize, zoom and
  fullscreen are identical for everyone, including the focused pane. Input
  from every client is delivered in arrival order. Window moves, incremental
  resizes and optional maximize/fullscreen outlines are also shown live in every
  viewer, not just in the client performing the action; minimize and restore
  are one atomic shared transition. Per-pane leases let different clients
  manipulate different panes concurrently without either pane jumping back,
  while each final canonical commit alone changes PTY geometry. Attaching
  from a differently sized terminal only clips or pads that desktop; a later
  physical resize is a shared operation which atomically adopts the new
  desktop and PTY geometry. Slow-client flow control ensures one stalled
  client never blocks the rest.
- On GNU/Linux and macOS, named multi-session detach: several live sessions
  under `~/.superterm/sessions/`, tmux-style `Ctrl-Q d` detach, a session picker
  (`Ctrl-Q s`), and `superterm --attach` / `--list-sessions`. Local and
  remote PTYs stay alive on the session server.
- On GNU/Linux and macOS, optional encrypted TCP entry through a dedicated
  system OpenSSH instance: isolated host keys/configuration under
  `/etc/superterm/sshd`, configurable Unix-account passwords and central or
  per-user authorized keys, a forced SuperTerm UI, and no changes to
  `/etc/ssh`. Standard interactive `ssh` clients attach to the same
  Unix-socket session engine.
  See [`docs/SSH_SERVER.md`](docs/SSH_SERVER.md).
- A configurable tmux-style prefix key (`[keymap]`, default `Ctrl-Q`), with
  `prefix f` (`Ctrl-Q f` by default) reserved for fullscreen/restore. During
  normal pane input, physical `F5` remains input for the focused pane instead
  of being a fullscreen shortcut.
- **ASCII art desktop backgrounds.** A picture behind the windows, in real RGB
  colour, chosen from `Options`. Pictures are plain text files read at run time
  -- nine ship, including the 7kas phoenix, the London skyline and three
  seamless patterns for the tiled layout -- so your own drops into
  `~/.superterm/backgrounds/` without rebuilding. Centred, tiled, stretched or
  fitted.
- Two per-profile display options in the Options menu: **show contents while
  dragging** (off gives a wireframe drag, where only the window outline moves
  and everything behind it stays visible -- much less traffic on a slow link)
  and an optional **zoom transition** for IDE maximize and fullscreen. Every attached
  viewer sees the same live path in its own active palette.
- Automatic local fallback save and restore through
  `~/.superterm/session.ini` on POSIX or
  `%APPDATA%\superterm\session.ini` on Windows.
- A quick session wizard for one to four panes. Each pane accepts a connection
  command and an optional command to feed to the connection after it starts.
- A custom keyboard driver: a lone `Esc` reaches the pane (timeout-based, not
  treated as an Alt prefix), with CSI/SS3 decoding and X10/SGR mouse support.
- **Full-fidelity pane rendering.** Truecolor and 256-color escape sequences
  are carried through to the terminal exactly as the application sent them,
  together with the real UTF-8 glyphs, emoji at their true two-column width,
  combining marks, faint, and concealed text. A pane is no longer flattened to
  one CP437 byte and 16 colors per cell, whether it is tiled, windowed or
  maximized. The vendored FreeVision is not modified: its grid is still drawn
  and decides what is visible.
- **Fullscreen (`Ctrl-Q f` by default) hands the pane the whole terminal** and writes its raw PTY
  bytes straight through when every attached host has the same geometry. With
  different geometries, every client instead gets the same IDE-rendered
  fullscreen area sized to the smallest host. The same prefix chord restores
  the window at the size it had.
- Normal window maximize (title button or double-click) keeps the IDE visible.
  At commit time its one shared frame and PTY fit the smallest connected host,
  even when a larger client previously grew the canonical desktop; restore
  returns to the exact pre-maximize rectangle. A later attach never derives a
  second local geometry from that canonical result.
- English application interface by default, with a runtime-selectable Spanish
  interface.
- Local FreeVision sources in `vendor/fv322`, including wide-screen and tmux
  mouse fixes. The system FreeVision installation is not modified.

## Encrypted TCP access with a standard SSH client

Release 4.2.1 can expose the same SuperTerm session engine through a dedicated
instance of the operating system's OpenSSH server. From a normal interactive
terminal, the client command stays familiar:

```sh
ssh -p 8022 user@server
```

No SuperTerm-specific client, private-key transfer or long list of SSH options
is required. OpenSSH discovers the client's usual keys and can fall back to a
PAM-approved Unix-account password when that policy is enabled. `-tt` is only
needed when `ssh` is launched without an interactive terminal and must be
forced to allocate a PTY.

This does **not** replace or reconfigure the host's ordinary `sshd`. Both
listeners can run at the same time:

| | Ordinary host SSH | Dedicated SuperTerm SSH |
|---|---|---|
| Typical endpoint | `server:22` | `server:8022` (configurable) |
| Configuration and host keys | `/etc/ssh` | `/etc/superterm/sshd` |
| Result after login | Normal shell/service | Forced SuperTerm UI |
| Intended facilities | Shell, commands, SCP/SFTP, tunnels | Interactive SuperTerm sessions |

`superterm ssh-server setup` creates a separate service, configuration, PID
and host identity and never edits, stops or restarts the normal SSH service.
It reuses the installed OpenSSH implementation for TCP, encryption,
authentication and PTY handling, then routes the authenticated client through
the existing private Unix socket. Detach, a dropped network connection or
closing the SSH terminal leaves the session daemon and its panes alive.

Listening interfaces and ports, password/key policy, root's public-key-only
exception, service installation, authorization and diagnostics are all
explicitly configurable. The entry accepts only an interactive PTY and rejects
remote commands, SCP/SFTP and forwarding; keep ordinary SSH for those uses.
See the complete, auditable procedure in
[`docs/SSH_SERVER.md`](docs/SSH_SERVER.md).

## Screenshots

**Copy and paste, with a history.** The `Clipboard` / `Portapapeles` menu keeps
the ten most recent items. `Ctrl-Q [` copies from the pane, `Ctrl-Q ]` pastes
the newest item, and `Ctrl-Q h` opens the history to choose one, each row saying
where it came from. It works the same when the pane is an SSH connection,
because a pane's own copy travels as OSC 52:

| The menu | The history |
|---|---|
| ![The Clipboard menu](screenshots/clipboard-menu.png) | ![Choosing an item to paste](screenshots/clipboard-history.png) |

**Focus changes the border, not the terminal.** An unfocused pane is no longer
darkened into greyscale. Both panes below ran the same output and keep the
application's exact colours; only the border and the title say which one has
the focus. Nothing in the pane interior changes, so moving the focus sends
nothing over a slow link:

![Two panes keeping their colours, focused and not](screenshots/focus-colour.png)

**Minimize, restore, or close every window at once**, from the `Windows` /
`Ventanas` menu. Closing all leaves the desktop and the live session attached;
either client can create the first pane again. The per-window entries stay in
`Panes` / `Paneles`:

![Minimize all and restore all in the Windows menu](screenshots/windows-menu.png)

**A picture on the desktop, behind the windows.** Nine ship, and your own drop
into `~/.superterm/backgrounds/` without rebuilding. The colours are real RGB,
not the 16-colour grid, and every generated picture is drawn with one stable
dark-shade glyph; its shape and colour survive terminal-font stretching.

![Alien hacker on the desktop, with a minimized pane](screenshots/desktop-goody.png)

They are picked from `Options > Desktop background`, and the desktop follows
the choice straight away:

![Choosing a desktop picture](screenshots/backgrounds.gif)

| | |
| --- | --- |
| ![Alien hacker](screenshots/bg-goody.png) | ![7kas phoenix](screenshots/bg-phoenix.png) |
| ![London skyline](screenshots/bg-london.png) | ![Alaska range](screenshots/bg-alaska.png) |
| ![Open field](screenshots/bg-field.png) | ![Sea at sunset](screenshots/bg-sea.png) |
| ![Stone wall, tiled](screenshots/bg-wall.png) | ![Truchet weave, tiled](screenshots/bg-weave.png) |

The last two, and the circuit board, are seamless patterns meant for the tiled
layout: they repeat across the desktop with no visible join.

**The desktop's colour is yours.** `Options > Desktop colour...` opens a picker
over the sixteen text-mode colours -- click one, or move with the arrows. Black
is the default, and it fills the desktop and the empty cells of a picture
alike:

![Choosing the desktop colour](screenshots/desktop-colour.gif)

**Three palettes, and the picture stays.** Colour, black and white, and
monochrome, switched from `Options > Color palette`. A picture keeps its own
colours in all three -- what shows between the windows is the picture you
chose:

![Switching the colour palette](screenshots/palette.gif)

**Menus and dialogs cast a real shadow** over whatever is behind them, picture
included:

![A menu over the desktop picture](screenshots/menu-shadow.png)

**The history is reachable** with the scrollbar in every window's right frame
column, the wheel, and `Alt-PgUp`/`PgDn`:

![Scrolling back through a pane's history](screenshots/scrollback.png)

**A workspace, and `Ctrl-Q f` giving one pane the whole terminal.**
Four windows share the desktop — a log tailer, a `watch` on disk usage, `top`
in the centre, and a fourth minimized to a title bar at the bottom. `Ctrl-Q f`
maximizes the focused pane and hands it the entire terminal, so `top` reflows
into the full screen; the same chord brings the desktop back with every window
where it was. Every attached viewer sees the expanding or contracting outline,
not only the client which pressed the key. It is the optional zoom transition
(`[session] zoomanim`, off by default — the instant switch is the fast one):

![The fullscreen zoom transition](screenshots/zoom-transition.gif)

**superterm in action — one capture per feature.**

Two clients attached to the same session at once: everything typed in client
A (left) appears live in client B (right), including the line injected from a
third shell with the control CLI:

![Two clients attached to one session](screenshots/multiuser.png)

A workspace built entirely from another shell — panes opened with `new`,
renamed with `rename`, re-tiled with `organize grid`, commands typed with
`send` — while the attached client watches it happen:

![A workspace driven from the CLI](screenshots/cli-windows.png)

Listing sessions and pane details (live command, size, scrollback lines,
focus flags) — note the English command with Spanish output, and the
Spanish `listar` alias:

![Session and pane listing](screenshots/cli-list.png)

Typing into a pane and capturing its screen or its whole scrollback from
another shell, pipe-clean:

![Send and capture round-trip](screenshots/cli-send-capture.png)

The bilingual built-in help (`--help` / `--ayuda`):

![The CLI help in Spanish](screenshots/cli-help.png)

Reusable window classes, named workspaces, and detachable sessions, all edited
in the app and stored in one INI file:

| Window classes | Profiles |
|---|---|
| ![Window class manager](screenshots/classes.png) | ![Profile manager](screenshots/profiles.png) |

| Detachable sessions | Quick session wizard |
|---|---|
| ![Session picker](screenshots/sessions.png) | ![Session wizard](screenshots/wizard.png) |

More captures are on the [Screenshots wiki page](https://github.com/garacil/superterm/wiki/Screenshots).

## Platform Support

`superterm` is a single cross-platform codebase that builds and runs natively on
**GNU/Linux, macOS (Apple Silicon and Intel), and Windows 10 version 1809 or
newer**. The UI, VT engine, layout, and configuration are shared; compiler
directives select the terminal, process, input, console, and path
implementations.

- **GNU/Linux** allocates the pseudo-terminal with the SysV `posix_openpt` sequence
  and reads process titles from `/proc`.
- **macOS** allocates it with BSD `openpty` + `login_tty` and reads process
  titles with `libproc`/`sysctl`. Free Pascal auto-defines `DARWIN`, so no build
  flag is required — run superterm in Terminal.app or iTerm2 exactly as on GNU/Linux.
- **Windows** uses ConPTY, native console VT input/output, Windows process
  management, `%COMSPEC%` (normally `cmd.exe`) as the default shell, and
  `%APPDATA%\superterm` for configuration.

On GNU/Linux and macOS, the optional dedicated SSH administrator selects the
native service manager in `src/st_ssh_server.pas`: systemd on GNU/Linux and
launchd on macOS. Its session, UI, and SSH-entry protocol code is shared
between those platforms; native Windows Phase 1 does not provide the dedicated
SSH service.

See [`docs/MACOS.md`](docs/MACOS.md) and [`docs/WINDOWS.md`](docs/WINDOWS.md)
for platform-specific build and terminal setup.

GNU/Linux and macOS provide the detached session daemon, multi-client attach,
session enumeration, and control CLI. Native Windows currently runs interactive
workspaces in one process, without those detached-session features.

## Technology Choice

`superterm` is intentionally written in Free Pascal. This is a project-specific
tradeoff, not a claim that Pascal is universally better than C:

- Free Pascal produces native binaries and provides access to POSIX, PTY, and
  SQLite APIs.
- FreeVision already supplies the terminal UI, event loop, and window controls
  needed by the application.
- Strong typing and ordinary Pascal memory management reduce implementation
  overhead for the layout, screen, session, and PTY code.
- The existing Pascal implementation works and its regression suite passes.

A complete C rewrite would have to recreate the UI, PTY handling, VT parser,
layout, session persistence, and tests without providing a concrete benefit for
the current requirements — including the persistent multi-client session server
and the bilingual control CLI, which are implemented in Pascal and covered by
the regression suite. For this cross-platform terminal multiplexer, continuing
in Pascal has a better benefit-to-risk ratio than rewriting it in C.

## Requirements

Build requirements:

- Free Pascal Compiler 3.2.2 or a compatible Free Pascal 3.x release.
- Free Pascal FV, FCL, and DB units.
- GNU make (including the 3.80 build bundled with Free Pascal on Windows).
- GNU/Linux (with `/proc`), macOS (Apple Silicon or Intel), or Windows 10
  version 1809 or newer for ConPTY.
- Git Bash for native Windows builds.

Test requirements:

- Python 3.
- Python packages `pyte` and Pillow.
- `rsvg-convert` (`librsvg2-bin` on Debian/Ubuntu, `librsvg` with Homebrew)
  for the reproducible artwork check.

Remote requirements:

- `openssh-client` for SSH connections.
- On GNU/Linux and macOS, the operating system's OpenSSH server for the
  optional dedicated encrypted TCP entry (`openssh-server` on Debian/Ubuntu;
  included with macOS). See [`docs/SSH_SERVER.md`](docs/SSH_SERVER.md).
- `sshpass` only for an outgoing SSH pane explicitly configured with a
  password. On GNU/Linux and macOS, incoming passwords for the dedicated
  SuperTerm service are handled by the system OpenSSH/PAM stack; SSH keys
  remain preferred.

## Build

The project includes a self-contained POSIX `configure` script. It is not
generated by GNU Autoconf. It detects the compiler and test tools, then creates
the ignored `Makefile` from `Makefile.in`. Run it from Git Bash on Windows.

```sh
./configure
make release
```

For a native Windows build, put the Free Pascal binary directory first on the
Git Bash `PATH`; this also avoids accidentally invoking a non-GNU `make.exe`:

```sh
export PATH="/path/to/fpc/bin:$PATH"
./configure --with-fpc="$(command -v fpc)"
make release
./bin/superterm.exe --version
```

The optimized release binary is `bin/superterm` (`bin/superterm.exe` on
Windows) and uses Free Pascal `-O4`.
The debug build is separate and uses symbols and line information:

```sh
make debug
```

The debug binary is `bin/superterm-debug` (`bin/superterm-debug.exe` on
Windows) and uses `-O1 -g -gl -dDEBUG`.

Useful configure options:

```sh
./configure --prefix="$HOME/.local" \
  --sysconfdir="$HOME/.config/superterm"
./configure --with-fpc=/usr/local/bin/fpc
./configure --with-python=/usr/bin/python3
```

On Debian/Ubuntu or macOS, dependencies can be installed explicitly:

```sh
./configure --install-deps
```

On macOS, this uses Homebrew for missing Free Pascal/Python tools;
`libsqlite3` and the system OpenSSH server already ship with macOS. The build
commands remain identical on both platforms.

The compatibility wrapper remains available:

```sh
./compile.sh
./compile.sh -B
```

Use `make info` to inspect the selected compiler, target, prefix, and paths.
See [`docs/BUILDING.md`](docs/BUILDING.md) for the source tree, vendor units,
build modes, installation, and platform boundaries, and
[`docs/DEBUGGING.md`](docs/DEBUGGING.md) for the tracing build, how to read a
trace, the crash report with its backtrace, and how to reproduce a problem
from a script.

## Tests

The tests launch isolated PTYs and do not attach to or restart a user's tmux
server.

```sh
make test
```

The suite covers pane operations, large terminal sizes, xterm and tmux mouse
input, focus routing, session restore, configured terminals, templates,
SQLite templates, the session wizard, language switching, window controls, and
the nonblocking session daemon under partial frames, stalled readers and file
descriptors above 1023. It also checks the isolated SSH configuration,
administration boundary, package removal and standard-client transport.
GitHub Actions runs it on GNU/Linux, macOS Apple Silicon and macOS Intel; the
real encrypted listener is repeated in an isolated privileged step on each.

The Python harness imports POSIX `pty`, `fcntl`, and `termios`, so it does not
run in native Windows Python. Use the release build plus `--version`, `--help`,
and an interactive ConPTY launch as the Windows smoke test.

Individual tests are also runnable directly:

```sh
python3 test/drive_test.py
python3 test/large_screen_test.py
python3 test/mouse_test.py
SUPERTERM_TEST_TERM=tmux-256color python3 test/mouse_test.py
python3 test/mouse_focus_test.py
python3 test/restore_test.py
python3 test/sysconfig_test.py
python3 test/template_test.py
python3 test/sqlite_test.py
python3 test/wizard_test.py
python3 test/language_test.py
python3 test/window_test.py
python3 test/detach_test.py
python3 test/nonblocking_server_test.py
```

The contextual-help test compares the release binary with the isolated
test-only runtime, so build and identify both when running it alone:

```sh
make release test-runtime
SUPERTERM_RELEASE_BIN="$PWD/bin/superterm" \
SUPERTERM_TEST_BIN="$PWD/bin/superterm-test" \
python3 test/cli_help_test.py
```

## Command-line help

The executable contains a structured, navigable reference. Its deterministic
plain-text output is suitable for terminals, scripts and AI agents, needs no
live session or privileges, and does not open the IDE or modify user/service
state:

```sh
./bin/superterm --help             # topic index
./bin/superterm --help sessions    # one functional area
./bin/superterm send --help        # one command, every option and example
./bin/superterm --help ssh         # standard SSH client entry
./bin/superterm --help ssh-server  # isolated OpenSSH administration
./bin/superterm --help all         # complete reference in one output
```

`help TOPIC`, `--help TOPIC`, `-h TOPIC`, the quoted `'-?' TOPIC` form and
`COMMAND --help` share the same pages.
Commands, topics and documented long control options have English and Spanish
aliases (`--ayuda sesiones`, `enviar --ayuda`), matched without case or accent
sensitivity. Short options remain exact (`-H` is history, while `-h` is help).
An unknown topic exits with status 2 instead of silently showing
an unrelated page. The longer narrative reference is
[`docs/CLI.md`](docs/CLI.md).

## Run

```sh
./bin/superterm
```

On Windows, launch `bin\superterm.exe` (for example
`.\bin\superterm.exe` from PowerShell).

On GNU/Linux and macOS, the session is named when it starts (`--session NAME`,
else the active profile, else `session`) and `Ctrl-Q d` detaches instantly,
with no dialog. To return to a live session:

```sh
./bin/superterm --attach            # one session: direct; several: picker
./bin/superterm --attach dev        # attach by name
./bin/superterm list                # sessions table (also --list-sessions)
```

Plain `superterm` also offers the session picker at startup when live
sessions exist. Every launch starts a per-user session server at
`~/.superterm/sessions/<name>.sock` with a `<name>.ini` metadata sidecar
(the pre-existing single `~/.superterm/session.sock` from older builds is
still recognized). The server owns the PTY masters, process groups,
terminal parsers, and scrollback, so leaving the client — or losing it —
does not close local shells or remote SSH connections. With several clients,
`Alt-X` closes only the client that requested the exit; the session ends when
its last attached client exits. A detached live session already is the saved
state, so there are no separate "save and exit" or "exit without saving"
paths. The explicit CLI `kill`
command remains an immediate session-wide close. Inside the app, `Ctrl-Q s`
opens the session picker to attach to or permanently close other sessions.
`Ctrl-Q d` only detaches the viewer: the single live desktop remains exactly
as it was, even with no viewers, and the next attach receives it directly.

On native Windows, the interactive workspace instead stays in the launching
process. Detach, attach, the session picker, and control CLI operations are not
available yet; exiting superterm ends its panes.

Optional diagnostics:

```sh
SUPERTERM_DEBUG=/tmp/superterm-debug.log ./bin/superterm
```

Do not put passwords in command lines or debug logs.

## Controls

`Ctrl-Q` is the default prefix key; `[keymap] prefix` can change it. After
the prefix, an unbound key sends the prefix byte plus that key to the pane.

| Key | Action |
| --- | --- |
| `F2` / `F3` | Open a window; it appears centred and nothing already open is moved or resized |
| `Alt-F3` / `Alt-F4` | Close the focused pane; closing the last one leaves an empty desktop |
| `F6` / `F7` | Next / previous pane |
| `Alt-1..9` | Go to pane N |
| `Alt-0` | Pane list: pick a pane, restoring it if minimized |
| `Ctrl-Q f` | Give the focused pane the whole terminal, or restore the IDE |
| `F5` | Send physical F5 to the focused pane (when the host/browser forwards it) |
| `Ctrl-F5` | Move or resize the focused pane |
| `Alt-F9` | Minimize the focused pane |
| `F8` / `F9` | Next / previous profile window |
| `Ctrl-Q 1..9` | Go to profile window N |
| `Ctrl-Q n` / `Ctrl-Q p` | Next / previous profile window |
| `Ctrl-Q` arrows | Resize the focused pane |
| `Ctrl-Q c` | Open a window class in a new pane |
| `Ctrl-Q s` | Session picker: attach to or close detached sessions (GNU/Linux and macOS) |
| `Ctrl-Q t` | Tile the windows (opening one no longer re-tiles) |
| `Ctrl-Q d` | Detach the live session; reattach with `superterm --attach` (GNU/Linux and macOS) |
| `Ctrl-Q [` | Enter pane copy mode. Move with arrows/PgUp/PgDn, press Space to start a selection and Enter to copy; mouse drag also copies |
| `Ctrl-Q ]` | Paste the newest clipboard-history item into the focused pane |
| `Ctrl-Q h` | Choose one of the ten most recent clipboard items to paste |
| Host terminal Paste | Add the pasted UTF-8 text to history and send it atomically to the focused local or SSH pane |
| `superterm` inside a pane | Works: a new session, or any session this pane does not live inside of. Attaching to the pane's own session (or one above it) is refused -- it would mirror forever. The picker never offers those |
| `Ctrl-Q Ctrl-Q` | Send one literal `Ctrl-Q` to the pane |
| `Ctrl-Q Ctrl-Q f` | Toggle fullscreen in a SuperTerm nested inside the focused pane |
| Mouse wheel | Scroll the pane's history (three lines a notch); on the alternate screen -- `less`, `vim` -- it sends arrow keys instead |
| Double-click a window title | Toggle that pane between its normal rectangle and IDE maximized size; the exact normal rectangle and focus are preserved |
| Mouse, inside a pane | An application that asks for the mouse (`htop`, `mc`, `vim` with `mouse=a`, another superterm) gets it: clicks, drags, the wheel, in the protocol it asked for, at pane coordinates. The frame, title bar, menu and status line always stay superterm's |
| `Alt-PgUp` / `Alt-PgDn` | History: a page back / forward (`Ctrl-PgUp`/`Ctrl-PgDn` and `Shift-PgUp`/`Shift-PgDn` do the same where the host terminal lets them through) |
| `Alt-Home` / `Alt-End` | History: oldest line / back to live |
| `Ctrl-S` | Save a local layout or profile selection (not needed or shown while attached to a live session) |
| `Alt-X` | Exit; the last attached viewer closes the live session |

Changing pane focus changes only the window border/title and cursor. Terminal
content keeps exactly the same colors and attributes in every pane, focused or
not, and unchanged interiors are not retransmitted on a focus switch.

The same actions are available from the `Panes`, `Windows`, `Classes`,
`Profiles`, `Sessions`, `Options`, `Clipboard`, and `Help` menus. The
`Windows` menu contains `Minimize all windows`, `Restore all windows`,
`Close all windows`, `Tile`, `Organize`, `Cascade`, `List`, and
`Refresh display`. `Options` holds the
language (`English`/`Espanol`, applied immediately), the color palette (color,
black and white, monochrome), and the autosave/autorestore toggles. In Spanish
mode the menus are `Paneles`, `Ventanas`, `Clases`, `Perfiles`, `Sesiones`,
`Opciones`, `Portapapeles`, and `Ayuda`.

Clipboard history is client-local, kept only in memory, deduplicated and
limited to ten UTF-8 items. Copying from a pane also writes the outer host
clipboard with OSC 52, so it works when the pane is an SSH connection and
when SuperTerm itself is reached over SSH, provided the terminal emulator
allows OSC 52 writes. OSC 52 writes produced by applications in a pane are
added to the same history; clipboard-read queries from panes are not answered.
The outer terminal's normal paste action is received through bracketed-paste
mode and is re-wrapped only when the focused application requested it.

## Session Wizard

Open `Sessions -> Quick session wizard`. In Spanish mode use
`Sesion -> Asistente nueva sesion`.

The wizard asks for one to four panes. For each pane enter:

1. A connection command, such as `ssh -tt alice@prod.example.com`,
   `mosh alice@host`, `tmux attach -t remote`, or a local command.
2. An optional command to feed to the connection after it starts, such as
   `tmux new-session -A -s production`.

The wizard collects all entries before replacing the current runtime, so
canceling leaves the current panes unchanged. It does not modify INI or SQLite
templates and does not store credentials. Commands run under the configured
login shell and are intentionally not parsed or validated.

For persistent remote consoles, SSH keys and a command such as this are
recommended:

```text
Connection command: ssh -tt alice@prod.example.com
After connecting:   tmux new-session -A -s alice-prod
```

The post-connect input is sent as the connection starts. Password prompts may
consume the same input, so key-based authentication is recommended.

## Configuration

There are two configuration roles:

- `~/.superterm/superterm.ini` stores user preferences (language, prefix key,
  autosave, default profile) and the user's own window classes and profiles.
- `$SUPERTERM_INI`, or `/etc/superterm/superterm.ini` when unset, can provide
  shared window classes and profiles.

They may be the same file for a personal installation:

```sh
export SUPERTERM_INI="$HOME/.superterm/superterm.ini"
```

Classes and profiles from both files are merged by name; the user file wins.
The application creates `~/.superterm` with mode `700` automatically and
writes its own files with mode `600`.

### User settings

```ini
[autologin]
shell=/bin/bash
login=1

[keymap]
prefix=ctrl-q               ; ctrl-a..ctrl-z, a letter, or 1..26

[ui]
language=en                 ; en (default) or es
palette=color               ; color (default), bw, or mono

[session]
autosave=1
autorestore=1               ; use 0 for a fresh profile startup
default_profile=daily
default_session=daily-ssh   ; optional dedicated SSH-entry session name
ssh_session=last            ; resume last SSH session; or default
```

The language value accepts `en`, `english`, `es`, `spanish`, or `espanol`.
The legacy `default_template`, `default_session`, and `default_window` keys
are still honored to select the startup profile and window. Configuration
keys and values such as `ini`, `sqlite`, `L`, `V`, and `H` are stable format
identifiers and must not be translated.

### Window classes

A window class (`[class.NAME]`) is a reusable pane definition. Its type is
derived from the fields: `connect` makes a free command class, `host` makes a
structured SSH class, and neither makes a local class. Legacy `[t-*]`
sections are still read and are migrated to `[class.*]` on save.

```ini
[class.production]
name=production
enabled=1
host=prod.example.com
user=alice
port=22
key=~/.ssh/id_ed25519
postconnect=tmux new -A -s main
scrollback=20000

[class.monitor]
name=monitor
enabled=1
cmd=htop
```

For SSH classes, `postconnect` is passed as the remote command, making
`tmux new -A` natural; `password` (base64) is supported through `sshpass`
but keys or an agent are preferred. For command and local classes,
`postconnect` is fed through the connection's standard input.

### Profiles

A profile (`[profile.NAME]`) is a named workspace: windows with pane layouts
whose panes reference window classes. Legacy `[template.*]` sections (INI or
SQLite `[storage]`) are still read and flattened into profiles.

```ini
[profile.daily]
name=daily
enabled=1
focused_window=0
windows=servers,logs

[profile.daily.window.servers]
enabled=1
layout=V:500;L;L            ; L = one pane; V side by side; H stacked
focused_pane=0
panes=prod,mon

[profile.daily.window.servers.pane.prod]
enabled=1
class=production

[profile.daily.window.servers.pane.mon]
enabled=1
class=monitor
```

Pane fields (`cmd`, `cwd`, `connect`, `postconnect`, `scrollback`) override
the referenced class. Layout ratios range from `0` to `1000`. Switch profile
windows with `Ctrl-Q 1..9`, `Ctrl-Q n`/`p`, or `F8`/`F9`.

See [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) for the complete
grammar, the SSH command structure, postconnect semantics, detached session
storage, and legacy compatibility (`[t-*]`, `[template.*]`, SQLite storage,
old `prefix=2`), and [`docs/WIZARD.md`](docs/WIZARD.md) for the wizard
behavior.

### Fallback session

When no profile takes priority, `~/.superterm/session.ini` stores the current
split tree and pane `cmd`, `cwd`, and class identity. With `autorestore=1`
(the default), the file is restored at startup. Set `autorestore=0` when a
default profile must create fresh daily connections.

## Source Layout

```text
src/
├── superterm.lpr   Program entry point and early SSH/TUI dispatch.
├── st_fvui.pas     FreeVision application, menus, panes, focus, and polling.
├── st_dialogs.pas  Class/profile managers, session picker, pane list.
├── st_layout.pas   Binary V/H split tree and pane rectangles.
├── st_pty.pas      Cross-platform PTY/ConPTY facade, I/O, resize, and cleanup.
├── st_conpty.pas   Native Windows ConPTY and child-process backend.
├── st_screen.pas   VT100/ANSI parser and virtual screen for each pane.
├── st_clipboard.pas Ten-item client clipboard history and OSC 52 helpers.
├── st_cli.pas      Bilingual control-command parser and daemon client.
├── st_cli_help.pas Structured contextual CLI help and examples.
├── st_server.pas   Detached session daemon, protocol and enumeration.
├── st_ssh_entry.pas Restricted OpenSSH ForceCommand session adapter.
├── st_ssh_server.pas Dedicated sshd configuration and service administration.
├── st_session.pas  Session serialization and restore.
├── st_wclass.pas   Window classes ([class.*], legacy [t-*] reader).
├── st_profiles.pas Profiles ([profile.*], legacy template flattening).
├── st_config.pas   User settings, prefix key, palette, and paths.
├── st_templates.pas Legacy INI and SQLite template loading.
├── st_kbd.pas      Custom keyboard driver (ESC timeout, CSI/SS3, mouse).
├── st_video.pas    Wide video output, CP437 glyph mapping, cursor restore.
├── st_keys.pas     FreeVision key codes to terminal escape sequences.
└── st_debug.pas    Optional runtime logging.
```

`vendor/fv322` is compiled locally before system FreeVision units. It contains
the `Objects`, `Drivers`, `Views`, `Menus`, `App`, `Dialogs`, and `MsgBox`
units plus the project-specific wide-screen and tmux mouse fixes.

## Installation

Prebuilt x86_64 packages for every release are on the
[releases page](https://github.com/garacil/superterm/releases/latest): a
portable tarball for any GNU/Linux, plus `.deb`, `.rpm` and Arch
`.pkg.tar.zst`. The only dependency is glibc, and each file ships with its
`.sha256`. macOS and ARM builds are published separately.

To build from source instead, for a system install:

```sh
./configure --prefix=/usr/local --sysconfdir=/etc
make release
sudo make install
```

The install contains the executable, README, all files under `docs/`, and an
example configuration. An existing configuration is never overwritten.
The optional TCP service is never enabled merely by copying files; prepare or
refresh it explicitly with `sudo superterm ssh-server setup` as described in
[`docs/SSH_SERVER.md`](docs/SSH_SERVER.md).

For a user-local install:

```sh
./configure --prefix="$HOME/.local" \
  --sysconfdir="$HOME/.config/superterm"
make install
```

Ensure `$HOME/.local/bin` is in `PATH`.

## Current Limits and Roadmap

Current limitations:

- Native Windows is currently single-process: detached sessions, multi-client
  attach, session enumeration, and the control CLI remain POSIX-only.
- The dedicated SSH entry is an interactive SuperTerm UI, not a general SSH
  shell: it deliberately rejects remote commands, SCP/SFTP and forwarding.
  Run the ordinary host `sshd` alongside it for those facilities.
- The visible layout supports 16 panes; the wizard intentionally limits a
  quick launch to four panes.
- FreeVision rendering uses its classic palette and approximates truecolor.
- Activating a profile recreates local PTYs; only detached sessions keep
  processes alive across a switch.
- SSH post-connect commands are passed through SSH as remote commands; the
  wizard feeds its optional command through the connection input stream.

Planned platform and runtime work includes the detached/control server on
Windows, native Windows CI coverage, better connection readiness/retry state,
and continued macOS parity polish.

## License and Author

Project site: <https://www.superterm.org> · Documentation:
[the wiki](https://github.com/garacil/superterm/wiki) · Releases:
[GitHub](https://github.com/garacil/superterm/releases)

Author: Germán Luis Aracil Boned — August 2026.

superterm is free software, released under the GNU General Public License
version 3 (see the `LICENSE` file). The bundled FreeVision fork in
`vendor/fv322` keeps its own licensing notices.
