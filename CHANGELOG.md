# Changelog

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
