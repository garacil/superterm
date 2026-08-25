# Configuration

## Files

There are two configuration roles:

- `~/.superterm/superterm.ini` is the user file. It stores preferences and
  the user's own window classes and profiles. The in-application class and
  profile managers save their changes here.
- `$SUPERTERM_INI`, or `/etc/superterm/superterm.ini` when the variable is
  not set, is the system file. It can provide shared window classes and
  profiles.

Both files use the same syntax and may be the same file, which is convenient
for a personal installation:

```sh
export SUPERTERM_INI="$HOME/.superterm/superterm.ini"
```

Window classes and profiles are loaded from both files and merged by name;
on a collision the user file wins. The application creates `~/.superterm`
with mode `700` automatically and rewrites its configuration, session, and
profile files atomically with mode `600`, because they may contain
credentials and commands.

## User settings

```ini
[autologin]
shell=/bin/bash
login=1

[keymap]
prefix=ctrl-q

[ui]
language=en
palette=color
background=phoenix
background_mode=center

[session]
server=always
autosave=1
autorestore=1
dragcontent=1
zoomanim=0
default_profile=daily
```

### [autologin]

- `shell` is the local shell for new panes. Default: `$SHELL`, or
  `/bin/bash` when unset.
- `login=1` starts it as a login shell (reads `.profile`); `login=0` starts
  an interactive non-login shell.
- `user` is informative; superterm runs as the already logged-in user.

### [keymap]

`prefix` selects the prefix key for tmux-style chords (`Ctrl-Q d` detach,
`Ctrl-Q c` open class, `Ctrl-Q s` session picker, `Ctrl-Q t` tile the
windows, `Ctrl-Q 1..9` go to window, `Ctrl-Q n`/`p` next/previous window,
`Ctrl-Q` arrows resize the pane, prefix twice sends one literal prefix
byte). Accepted values:

- `ctrl-a` .. `ctrl-z`, for example `prefix=ctrl-q`.
- A single letter `a` .. `z`, shorthand for the same Ctrl key.
- A number `1` .. `26`, the raw control code (`17` = Ctrl-Q).

The default is `Ctrl-Q`. Migration note: the numeric value `2` was the old
default (Ctrl-B) and is migrated to Ctrl-Q so the prefix does not collide
with a remote tmux. To really use Ctrl-B, write `prefix=ctrl-b` explicitly.
The application saves the setting back in the `ctrl-x` form.

### [ui]

`language` controls the interface language: `en` (English, the default) or
`es` (Spanish); `english`, `spanish`, and `espanol` are also accepted. The
same setting is available at runtime from `Options -> Language`
(`Opciones -> Idioma`); changing it updates the menus, status line, wizard,
help, and dialogs immediately and saves the selection.

`palette` selects the interface palette: `color` (the classic Turbo Pascal
palette, the default), `bw` (black and white), or `mono` (monochrome). Any
other value falls back to `color`. The same setting is available at runtime
from `Options -> Color palette` (`Opciones -> Paleta de colores`) and is
saved when changed. Selecting it repaints the whole interface immediately;
no pane click is needed. A later resize of the host terminal preserves the
selected palette while rebuilding the screen surface.

### [ui] new window size

- `newwincols`, `newwinrows` — size, in cells, of a window opened from a class
  that does not set its own `cols`/`rows`. `0` (the default) means two thirds
  of the desktop. The first window of a session always takes the whole
  desktop.

### [ui] desktop background

- `background` names the picture drawn on the desktop behind the windows, by
  file name without the extension; `none` leaves the plain pattern. Pictures
  are plain text files read at run time, searched in `$SUPERTERM_BACKGROUNDS`,
  then `~/.superterm/backgrounds`, then the directory installed beside the
  binary, then `/usr/local/share/superterm/backgrounds` and
  `/usr/share/superterm/backgrounds`, then `backgrounds/` in a source
  checkout. The first match wins, so your own file shadows an installed one of
  the same name, and a new file appears in the `Options` menu without
  rebuilding.
- `background_mode` is the layout: `center` (default), `tile`, `stretch` or
  `fit`. A picture may name the layout it was designed for -- the seamless
  patterns ask for `tile` -- and choosing it from the menu adopts that layout.
- Both are on the `Options` menu, which lists whatever is on disk.

A picture file is a palette plus three parallel lines per row:

```
name: City at night
name.es: Ciudad de noche
mode: tile
palette: 0E1430 1B2450 26325F FFD866
>    333   33333
:    111   22222
.    000   00000
```

`>` is a row of glyphs: a space leaves the cell empty so the desktop shows
through, `1` `2` `3` are the upper half, lower half and full block, `4` `5` `6`
the light, medium and dark shades, and anything else is drawn literally. `:`
and `.` give the foreground and background palette index of each cell, as
`0`-`9`, then `a`-`z`, then `A`-`Z`. Because a cell can carry two colours
through a half block, a picture has twice the vertical resolution of the
character grid.

### [session]

- `server=always` (default) starts a session server on every launch: the
  visible terminal attaches to it as a client, the session gets an
  automatic name (`--session NAME`, else the active profile, else
  `session`), and the whole workspace can be driven from another shell
  with the control CLI (see [`CLI.md`](CLI.md)). `server=detach` restores
  the classic behaviour where the server only exists after detaching with
  the prefix + `d`.
- `multithread=1` (default) keeps the session daemon on its original single
  event-reactor thread. `multithread=N` sets the maximum **total** daemon
  threads, including the permanent client/socket reactor; the effective cap
  is also limited by the CPUs available to the process. `multithread=auto`
  uses that CPU limit automatically. Pane workers are created on demand and
  removed as panes close, so with `N=8` and two panes the daemon has three
  threads, not eight. `SUPERTERM_MULTITHREAD=1|auto|N` overrides the file for
  one launch, which is useful for deterministic debugging. Existing session
  daemons keep the mode they started with until they are restarted.
- A session has exactly one daemon-owned desktop and one PTY geometry per
  pane. Positions, sizes, minimize, zoom and fullscreen are shared by every
  viewer, as is the focused pane. Input from every viewer remains enabled and
  is processed in arrival order. Attaching a client never changes that state:
  a small terminal clips it and a large one leaves margin. A later physical
  resize of any attached host is an explicit shared operation; it atomically
  replaces the canonical desktop, proportionally scales its windows and
  updates the PTYs for every viewer. Explicit window operations and CLI
  `resize` likewise change the common geometry.
  A new normal IDE maximize is a shared exception to clipping: its complete
  frame and PTY fit the smallest host connected when the action commits while
  the larger canonical desktop remains intact for restore. A later attach does
  not recalculate that committed geometry. F5 uses the smallest host's complete
  terminal instead because it removes the IDE chrome.
  Detach performs no save/reload; the daemon keeps the live object untouched.
- `autosave=1` (default) saves the fallback session on exit.
- `autorestore=1` (default) restores `~/.superterm/session.ini` at startup
  when no profile takes priority. Set it to `0` when every startup must
  create fresh profile connections.
- `dragcontent=1` (default) draws a window's contents while it is being
  dragged. The client holding that pane's gesture lease publishes its live
  positions (capped at 60 Hz) through the daemon FIFO, so every attached
  viewer sees the same movement while it happens; only the final release
  changes canonical geometry and resizes the PTY. Set it to `0` for a shared
  wireframe drag: the window is hidden for the duration of the gesture and
  only its outline moves, so the desktop and the windows behind it stay
  visible through it and each step sends just the strip the outline vacates
  plus the one it takes. On a 53x29 window that is about 29 cells per step
  instead of redrawing the interior, which is worth having on a slow or
  high-latency link, or with a pane full of content.
  Different clients may hold and move different panes concurrently. Each
  viewer applies peer commits while preserving only its own in-flight pane,
  so releasing either mouse cannot roll the other gesture back.
- `zoomanim=0` (default) makes IDE maximize and `F5` switch instantly. Set it
  to `1` for a short expanding and contracting outline between the pane and
  its target (about 350 ms). The eight outline frames are relayed to every
  viewer and use that viewer's active theme. They are purely cosmetic: the
  pre-commit frames cannot change a PTY or revision, and the short contraction
  tail begins only after the canonical layout acknowledgement. The instant
  transition remains the fast path.
- All four flags can also be toggled at runtime from the `Options` menu.
- Pane focus is deliberately not a content effect: focused and unfocused
  terminal interiors keep identical colors and attributes. Only the window
  border/title and cursor change, so unchanged pane cells are not sent again.
- `default_profile` names the profile activated at startup.
- The legacy keys `default_template`, `default_session`, and
  `default_window` are still read. The startup profile is resolved as
  `default_profile`, then `default_template`, then
  `default_template/default_session` (the name produced by template
  flattening). `default_window` selects the starting window of the profile
  by name.

## Full-screen passthrough

Maximizing a pane (F5) makes it own the whole terminal and streams its raw
output straight through, so a truecolor/emoji TUI (e.g. Claude Code) renders
at full fidelity instead of being approximated to the CP437 grid. This raw
path is also valid with several clients when all physical host geometries are
equal. If they differ, F5 stays in the synchronized IDE renderer and uses one
shared fullscreen area sized to the smallest host. Press F5 again to restore
the normal canonical desktop and the window's previous bounds.

## Clipboard and SSH

The `Clipboard` / `Portapapeles` menu owns a client-local, in-memory history
of ten UTF-8 items. It is deliberately absent from `superterm.ini`, session
files, snapshots, debug logs, and the daemon protocol, so attaching from a
second host does not expose the first host's clipboard.

The outer terminal's normal Paste action is captured with bracketed-paste
mode, added to history, and sent to the focused pane. If that pane requested
DECSET 2004, SuperTerm restores the bracketed-paste delimiters before sending
the text. A pane copy writes OSC 52 to the outer terminal; this supports an
SSH pane and SuperTerm itself running across SSH when the final terminal
emulator permits OSC 52 clipboard writes. Pane-generated OSC 52 writes are
also recorded and forwarded. OSC 52 clipboard-read queries from panes are
discarded and never receive host clipboard contents.

## Window classes

A window class is a reusable, named pane definition: what to run, where to
connect, and what to send after connecting. Classes replace the old `[t-*]`
terminal definitions. Sections are named `[class.NAME]`:

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
cols=100
rows=30

[class.monitor]
name=monitor
enabled=1
cmd=htop
```

Fields:

- `name` — canonical name; defaults to the section suffix.
- `enabled` — `1`/`0` (also `true`/`yes`/`on`); default `1`.
- `title` — default window title for panes opened from this class; empty
  falls back to the class name. A pane's title can be changed at runtime with
  `Panes -> Rename title...`; a renamed title is kept and is written into a
  profile or session when it is saved.
- `shell` — local shell for the pane; empty means the `[autologin]` shell.
- `cmd` — command run when the pane opens (locally, or as the SSH remote
  command when there is no `postconnect`).
- `cwd` — working directory; `~/` is expanded.
- `host`, `user`, `port`, `key` — structured SSH connection fields.
- `password` — base64-encoded SSH password; requires `sshpass`; base64 is
  storage encoding, not encryption. Prefer a key or an agent.
- `connect` — free connection command; takes precedence over `host`.
- `postconnect` — command sent after connecting; see the semantics below.
- `scrollback` — scrollback lines; default `10000`, maximum `100000`.
- `cols`, `rows` — preferred size, in cells, of a window opened from this
  class. `0` (the default) falls back to `[ui] newwincols`/`newwinrows`, and
  when those are unset too, to two thirds of the desktop. The window frame
  adds one cell on each side, and the size is clamped to the desktop.

Every way of opening a window behaves the same: it appears centred on the
desktop at that size, on top of whatever is there, and nothing already open is
moved or resized -- `F2`/`F3` included. Tiling is on demand (`Windows -> Tile`,
or prefix + `t`).

The class type is derived when loading and is never stored:

- `connect` present -> command class (free connection command).
- otherwise `host` present -> SSH class (structured).
- otherwise -> local class.

The old `type=` key is ignored; the fields alone decide the type.

### SSH classes (structured)

For an SSH class, superterm builds a structured argument list itself:

```text
ssh -tt [-p port] [-i key] -o StrictHostKeyChecking=accept-new [user@]host [command]
```

The remote command is a single argument, executed by the remote login
shell. Its precedence, when a profile pane uses the class, is: pane
`postconnect`, then class `postconnect`, then pane `cmd`, then class `cmd`.
This makes persistent consoles natural:

```ini
postconnect=tmux new -A -s main
```

SSH authenticates, starts the remote command, and keeps the PTY attached
while it runs. If the command should end in an interactive shell, start
one explicitly:

```ini
postconnect=cd /srv/app && ./daily-command; exec bash -l
```

When `password` is set and `sshpass` is on `PATH`, the connection is wrapped
with `sshpass` (the password is handed over on a private file descriptor,
not on the command line).

### Command classes and postconnect delivery

A class with `connect` runs that command under the local shell. The
effective `postconnect` is delivered on the connection's standard input as
it starts, equivalent to:

```sh
printf '%s\n' '<postconnect>' | (<connect>)
```

This suits interactive PTY programs such as `ssh -tt`, `mosh`, `tmux
attach`, and telnet-like commands. Programs that read a password from the
same input may consume the injected line, so key-based login is
recommended.

### Local classes

A local class runs `cmd` under `shell` in `cwd`. If `postconnect` is also
set, it is fed to `cmd` through standard input as above. If only
`postconnect` is set, it runs first and then leaves an interactive shell in
the same pane (`exec <shell> -l` for a login shell, `-i` otherwise).

### Pane overrides

Profile panes may override class fields: pane `cmd`, `cwd`, `connect`,
`postconnect`, and `scrollback` (when greater than `0`) replace the class
values for that pane only.

### Legacy [t-*] sections

Any section whose name starts with `t` (except `[template.*]`) is still
read as a window class with the same keys, so old `[t-production]`
definitions keep working. The first time the class manager saves the user
file, those sections are absorbed and rewritten as `[class.*]`.

## Profiles

A profile is a named workspace: a collection of windows, each with a pane
layout, where every pane can reference a window class. Profiles replace the
old three-level `[template.*]` model (its extra "session" level is gone).
The model has three section levels:

1. `[profile.NAME]` — the profile header: `name`, `enabled`,
   `focused_window` (0-based index), and `windows` (comma-separated list of
   window names).
2. `[profile.NAME.window.W]` — one section per window: `enabled`, `layout`,
   `focused_pane` (0-based index), and `panes` (comma-separated list of
   pane names).
3. `[profile.NAME.window.W.pane.P]` — one section per pane: `enabled`,
   `class` (window class reference; empty means an ad-hoc pane), and the
   overrides `cmd`, `cwd`, `connect`, `postconnect`, `scrollback`.
   `terminal` is accepted as a legacy synonym of `class`.

A full realistic example using the classes defined above:

```ini
[profile.daily]
name=daily
enabled=1
focused_window=0
windows=servers,logs

[profile.daily.window.servers]
enabled=1
layout=V:500;L;L
focused_pane=0
panes=prod,mon

[profile.daily.window.servers.pane.prod]
enabled=1
class=production

[profile.daily.window.servers.pane.mon]
enabled=1
class=monitor

[profile.daily.window.logs]
enabled=1
layout=L
focused_pane=0
panes=logs

[profile.daily.window.logs.pane.logs]
enabled=1
class=production
; pane fields override the class: this pane opens a different tmux session
postconnect=tmux new -A -s logs
```

`layout` uses the same grammar as `session.ini`: a `;`-separated preorder
list of nodes where `L` is one pane and `V:ratio` / `H:ratio` are splits.
`V` places the two subtrees side by side, `H` stacks them vertically. The
ratio ranges from `0` to `1000` (`500` = half) and is clamped to
`150..850`. `V:500;L;L` is two panes side by side; plain `layout=L` is a
single pane.

At runtime, use the `Profiles` menu to activate a profile, `Save current as
profile...` to capture the current workspace, and `Manage profiles...` to
edit them. `Ctrl-Q 1..9`, `Ctrl-Q n`/`p`, and `F8`/`F9` switch between the
windows of the active profile.

## Detached sessions

Since 3.0 every session lives in a per-user background server from launch
(`[session] server=always`), named automatically: `--session NAME`, else the
active profile, else `session`. `Ctrl-Q d` (or `Sessions -> Detach...`)
simply disconnects the client, instantly and with no dialog:

- Socket: `~/.superterm/sessions/<name>.sock` (directory mode `700`).
- Metadata sidecar: `~/.superterm/sessions/<name>.ini` with the session
  name, profile, pane count, server PID, and creation time (mode `600`).

Session names are sanitized to `A-Z a-z 0-9 . _ -`; other characters become
`-`, leading dots and dashes are stripped, and names are limited to 64
characters. Several named sessions can exist at the same time.

To return:

```sh
superterm --attach            # one session: direct; several: picker
superterm --attach NAME       # attach by name
superterm --list-sessions     # table of live sessions (purges orphans)
```

Inside the application, `Ctrl-Q s` (or `Sessions -> Attach / manage
sessions...`) opens the same picker to attach to or permanently close other
sessions. The single `~/.superterm/session.sock` used by older builds is
still recognized and listed as an unnamed session.

## Fallback session

When no profile takes priority, `~/.superterm/session.ini` stores the
current split tree and the pane `cmd`, `cwd`, and class identity. With
`autosave=1` it is written on exit (and on `Ctrl-S`), and with
`autorestore=1` it is restored at startup.

## Legacy compatibility

Old configurations keep working without manual edits:

- `[t-*]` terminal sections are read as window classes and are migrated to
  `[class.*]` the first time the class manager saves the user file. The
  old `type=` key is ignored; the class type is derived from the fields.
- `[template.*]` sections are read and flattened into profiles: a template
  with one session becomes a profile with the template's name; a template
  with several sessions becomes one profile per session, named
  `template/session`. An explicit `[profile.*]` with the same name wins.
  Saving profiles from the application absorbs the user's `[template.*]`
  sections.
- SQLite template storage (`[storage]` with `backend=sqlite` and
  `directory=templates`, resolved relative to the configuration file) is
  still read as a legacy template source and flattened the same way.
- `[keymap]` `prefix=2` (the old numeric default, Ctrl-B) is migrated to
  Ctrl-Q; write `prefix=ctrl-b` to keep Ctrl-B on purpose.
- `[session]` `default_template`, `default_session`, and `default_window`
  still select the startup profile and window as described above.
- The old single `~/.superterm/session.sock` detached session is still
  recognized by the picker and `--attach`.
