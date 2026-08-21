# Changelog

## 3.0.1 - 2026-08

- Attaching a client no longer bounces pane sizes across the session.
  While the attach builds its windows (tile positions first, saved
  geometry afterwards) it now stays silent and sends a single size
  request per pane once the geometry is final, so the other clients'
  screens are not shrunk and re-grown in between and the visible content
  of every pane stays on screen instead of sliding into the scrollback.

## 3.0 - 2026-08

Superterm becomes a true client/server multiplexer, tmux-style but driven
from the command line in two languages.

### Always-server sessions
- Every session starts a server at launch (`[session] server=always`, the
  default); the visible terminal is just the first attached client.
  `server=detach` keeps the classic detach-only flow.
- Automatic session names without dialogs: `--session NAME`, else the
  active profile name, else `session`, with `-2`/`-3` suffixes on
  collision. Detaching with the prefix + `d` no longer prompts.
- Exits keep their meaning: Alt-X closes the session and the daemon saves
  `session.ini` server-side; Alt-Q closes without saving; Ctrl-S while
  attached saves server-side. Killing the client process leaves the
  session running.
- The daemon derives live pane titles (running command or directory),
  keeps manual renames fixed across saves, and closes itself when every
  pane is dead and nobody has been attached for a minute.

### Bilingual control CLI
- New commands, accepted in English AND Spanish with `--help`/`--ayuda`
  everywhere: `list/listar`, `send/enviar` (text, named keys, raw stdin),
  `capture/capturar` (visible screen, last N lines or the full
  scrollback, pipe-clean UTF-8), `kill/matar`, and full window
  management: `new/nueva`, `close/cerrar`, `focus/foco`,
  `rename/renombrar`, `resize/tamano`, `minimize/minimizar`,
  `restore/restaurar`, `zoom/ampliar`, `organize/organizar`
  (grid/tile/cascade). See `docs/CLI.md`.
- Friendly targets: `SESSION:PANE` by 1-based index or unique title
  substring, and `.` for the only live session. Exit codes 0/1/2/3.
- Control requests ride ephemeral connections that never occupy an
  interactive slot, so the CLI works while clients are attached and the
  daemon spawns new panes itself (window classes resolve server-side;
  SSH secrets never travel over the socket).

### Multi-user sessions
- Up to 8 interactive clients attached to one session with output
  broadcast, live window events (layout, titles, focus, new and closed
  panes), and per-pane smallest-size negotiation.
- Client writes are buffered and never block the daemon: output pauses
  via flow control while a client catches up and a stalled client is
  dropped after a grace period. Killing a session notifies every capable
  client. Pre-3.0 clients still attach exclusively, bit for bit as
  before.

## 2.1 - 2026-08

The Superterm 2.0 plan (phases F0-F6) landed in this release, restructuring
the application around three clean concepts and rebuilding the interface in
the classic Turbo Vision style.

### Window classes, profiles and sessions
- Window classes `[class.*]` unify connection setup (structured SSH or a
  free connect command, optional open command and postconnect). Legacy
  `[t-*]` sections are read and migrated on save.
- Named profiles `[profile.*]` describe repeatable workspaces of windows and
  panes; legacy `[template.*]` sections are flattened automatically.
- Multiple named detachable sessions: each detach creates
  `~/.superterm/sessions/<name>.sock` with a metadata sidecar. A session
  picker appears at startup, on `--attach`, and via the prefix `s` chord.
- CLI: `--attach [name]` and `--list-sessions`.
- Window geometry of every window (moved, zoomed, minimized) round-trips
  exactly through both exit/restore and detach/attach.

### Keyboard and terminal
- Prefix key moved from Ctrl-B to Ctrl-Q so a remote tmux/screen inside a
  pane receives Ctrl-B untouched; the old numeric `prefix=2` migrates
  automatically and an explicit `ctrl-b` is respected.
- Custom keyboard driver: a lone Esc now works (50 ms timeout instead of
  being held as an Alt prefix), with full CSI/SS3 keys and X10/SGR mouse.
- SGR indexed 256-color and truecolor are approximated to the nearest
  ANSI-16 color instead of collapsing to the default; CP437 box, block,
  arrow and accented glyphs render correctly, including the bullets and
  spinner glyphs of modern CLIs so a remote tmux renders cleanly.

### Window titles
- Each window has a title under the user's control. Window classes carry a
  default `title`; `Panes -> Rename title...` renames the focused window; a
  custom title is never overwritten by the cwd/command refresh and is saved in
  the session and written into a profile when saved.

### Fixes
- SSH window classes with a password now connect: the `ssh` command word was
  missing before `-tt`, so `sshpass` rejected `-tt` as its own option
  (`invalid option -- 't'`) and the pane failed. The argv is now
  `sshpass -d 3 ssh -tt ... host`.
- Minimizing, restoring or closing a window no longer re-tiles the others.
  Every window keeps the size and position the user gave it; a restored
  window returns to its own previous bounds. Geometry changes only on
  explicit actions (Tile/Cascade/Organize or the move/resize keys).

### Interface (classic Turbo Pascal look)
- Menu tree: Panes, Windows, Classes, Profiles, Sessions, Options, Help.
- Windows menu: Tile, Cascade, Organize, List (Alt-0) and Refresh display.
- Minimized windows become Turbo Vision icon bars grouped at the bottom of
  the desktop; a click restores them.
- Options menu: persisted color palette selector (color / black-and-white /
  monochrome) plus autosave and autorestore toggles.
- Readable dialog palette (black text on the blue/cyan dialogs), authentic
  button shadows, double click on every list, Spanish with real accents.
- About dialog showing the version, author and GNU GPL v3, dedicated to
  Richard Stallman and the GNU project.

### Project
- Released under the GNU General Public License version 3 (`LICENSE`).
- The build injects the version from the `VERSION` file.
- Documentation rewritten: `docs/CONFIGURATION.md`, `docs/WIZARD.md`,
  `examples/superterm.ini.example` and the README.
