# Changelog

## 3.3.1 - 2026-08

A maintenance release: the session daemon no longer dies under heavy output,
and the debug build now explains itself when something does go wrong.

### The daemon survives a flood, and the interface stays alive with it

Running something that writes without pause -- `ls -R /` from the root, a large
build -- could kill the session daemon and take every pane down with it, leaving
attached clients saying only "connection lost". Two independent faults were
behind it.

- **The daemon detached with its standard descriptors closed.** The first write
  to a freed descriptor raised an error, whose own reporting wrote to the same
  descriptor, and so on until the process died. Descriptors 0, 1 and 2 are now
  reopened on `/dev/null`, which is what every well-behaved daemon does.
- **The main loop had no guard.** An unexpected error anywhere inside it ended
  the process. The body now catches, records what happened, writes a report and
  carries on; fifty consecutive failures still stop the session, so a genuinely
  broken daemon does not spin forever.
- **The interface froze while the flood lasted.** The client drained every
  pending frame in one pass and repainted per frame, so keyboard and mouse were
  never read: Ctrl-C did not arrive, the menu did not open, a window could not be
  minimised. The drain is now bounded -- at most 32 frames or 20 ms -- and marks
  which panes changed, repainting each one once at the end.

### A debug build that explains itself

- **Crash reports.** With `make debug`, a fatal signal writes
  `/tmp/superterm-crash-<role>-<pid>-<time>.log` before the process goes down:
  the signal, how long it had been running, a backtrace with file and line, and
  the last few hundred trace lines from a ring buffer that is kept even when
  tracing is switched off. The default handler is then restored and the signal
  re-raised, so the system core dump still happens.
- **A quieter flow log.** `SUPERTERM_DEBUG` records the milestones; the chatty
  per-read, per-frame detail moved behind `SUPERTERM_DEBUG_FULL=1`, so a long
  trace stays readable.

### Leaving superterm no longer leaves the mouse reporting

Quitting or detaching could drop you back at the shell prompt and then, as
soon as you moved the mouse, fill it with line noise like
`35;65;64M35;64;64M`. Those are mouse reports: the terminal was still being
told to send them.

The RTL's mouse driver turns only two of the tracking modes on and off, but
superterm enables two more by hand when it reclaims the screen from a
maximised pane, and nothing turned those back off. Every mode superterm can
enable is now disabled on the way out, and whatever the terminal already
reported is flushed instead of being read by the shell as typed input.

### Also

- **A desktop with no picture costs exactly what it did before 3.3.** The
  background code now short-circuits on `none` instead of walking every cell.
- The README links the project site, <https://www.superterm.org>.

## 3.3 - 2026-08

### A picture on the desktop, behind the windows

The desktop can show ASCII art instead of the plain pattern. Colours are real
RGB and reach the terminal through the rich renderer added in 3.2, so a picture
is not confined to the 16-colour grid.

- **Pictures are plain text files, not compiled in.** Drop one in
  `~/.superterm/backgrounds/` and it appears in the menu without rebuilding.
  A file is a palette plus three parallel lines per row -- glyphs, foreground
  indexes and optional background indexes -- and the glyph alphabet includes
  the half-block and shade characters, so a cell can carry two colours and a
  picture gets twice the vertical resolution.
- **Eight ship with it.** The 7kas phoenix, sampled from the brand artwork and
  the default; the London skyline; an Alaska range under an aurora; an open
  field at golden hour; a boat at sunset; and three patterns designed for the
  tiled layout that are seamless on all four sides -- a stone wall, interlocking
  Truchet loops and a circuit board.
- **The classic layouts:** centred, tiled, stretched or fitted. A picture can
  name the layout it was made for, so choosing a seamless pattern from the menu
  also tiles it.
- **Chosen from `Options`**, which lists whatever is on disk, and remembered per
  profile in `[ui] background` and `[ui] background_mode`.
- **Searched** in `$SUPERTERM_BACKGROUNDS`, then `~/.superterm/backgrounds`,
  then the installed directory relative to the binary (so any `--prefix`
  works), then the usual system paths, then the source checkout. First match
  wins, so your own file shadows an installed one of the same name.
  `make install` creates and populates the installed directory.

FreeVision is untouched, as ever: the desktop, its background and the
application's desktop factory are all virtual, so they are replaced by
subclassing.

### Correction to the 3.3 notes

3.3 shipped with a "known issue" saying that a 4096-column restore left a
stale window border. There is no such defect. The test sampled the screen a
fixed 1.2 seconds after the resize, and a resize that wide takes a little
over two seconds to reach its final paint: what it read was the previous
layout, still on screen. The test now waits for the layout instead of for a
clock, and every assertion passes. The resize is genuinely slow at those
widths, which is a performance matter and is being worked on separately.

## 3.2 - 2026-08

### Every pane now renders in full fidelity, not just the maximized one

3.1 gave a maximized pane the whole terminal so a rich TUI could render
untouched. 3.2 does the same for panes that are **tiled or windowed**, without
modifying the vendored FreeVision.

- **Rich pane renderer.** A pane used to reach the screen through FreeVision's
  VGA text grid: one CP437 byte and 16 colours per cell, so anything outside
  that repertoire became `?` and every colour collapsed to the nearest of 16.
  Each pane now also registers every cell in a parallel overlay -- the full
  UTF-8 glyph, the exact colour, and the attributes -- keyed by its global
  screen position, with the grid word it wrote there kept as an oracle. The
  screen driver then decides per cell: the rich pane cell when its oracle still
  stands (so it is the visible top cell), otherwise the CP437/16-colour chrome
  for frames, menu, status line and covered cells. The same single-write,
  delta-per-cell model as before, so overlapping windows and the window manager
  keep rendering exactly as they did.
- **Truecolor is preserved end to end.** `38/48;2;R;G;B` was downsampled to 16
  colours in the parser, before it could ever reach a cell. Cells now carry the
  colour itself and the renderer emits it verbatim.
- **256-colour palette indexes are preserved too.** Every `38/48;5;N` was
  approximated to one of 16 colours and the index discarded, so four distinct
  shades of an application's palette rendered as the same grey. Indexes 16..255
  are now carried and emitted as-is; 0..15 stay unpinned so they keep honouring
  the user's own terminal theme.
- **The colon form of an extended colour is parsed correctly.** `38:2:R:G:B`
  follows ITU T.416 and carries a colour-space field the semicolon form does
  not, so reading the channels at the wrong offset turned a dusty pink into a
  saturated green. Emitters that use subparameters are no longer miscoloured.
- **Emoji and combining marks occupy their real width.** Everything that was
  not CJK was assumed one column wide, so a line containing an emoji shifted
  everything to its right. Emoji are now two columns; combining marks,
  variation selectors and zero-width joiners are zero columns and attach to the
  glyph they modify, and a `U+FE0F` selector promotes its base to two columns
  (the usual way a warning or check symbol is sent).
- **A two-column glyph is never split across a pane edge.** Its two halves were
  classified independently, so a pane edge between them let the right half land
  on the window frame -- which the delta then never repaired -- or left an
  orphan column blank forever.
- **Malformed UTF-8 can no longer corrupt the screen.** Cell bytes are written
  straight to the terminal now, so one stray byte made the terminal's decoder
  swallow the escape sequence that followed. Only well-formed, printable
  sequences are emitted; anything else renders as `?`, exactly as before.
- **Bold and bright are no longer the same bit.** One attribute bit served as
  both the SGR 1/22 weight and the high bit of the 16-colour foreground, so
  "normal intensity" also demoted the colour -- an application's grey text
  turned pure black -- and `SGR 38` silently changed the weight. They are now
  separate, and the on-screen result of `1;32` is unchanged.
- **Faint (`SGR 2`) is honoured** and `SGR 22` clears it, so an application's
  secondary text is no longer painted at exactly the same weight as its primary
  text.
- **Concealed text (`SGR 8`) is no longer displayed.** Text an application
  explicitly hides -- password fields, form widgets -- was rendered in clear.
  Both renderers now draw it blank, and `SGR 28` reveals it again.
- **A pane only claims the cells it actually owns.** Registration followed draw
  order, so with overlapping windows the one behind could overwrite the entries
  of the one in front for every shared cell.

### Terminal emulation fixes

- **Attributes no longer leak out of a full-screen application.** Leaving the
  alternate screen (`?1049l`), `DECRC` (`ESC 8`) and `CSI u` restored only the
  cursor position. A real terminal restores the graphic rendition too, which is
  why an application may exit without an explicit reset -- and several do,
  ending with bold set. That bold then applied to everything the shell printed
  afterwards. All three now save and restore the rendition, the alternate
  screen in its own slot as in xterm.
- **`reset` clears the screen again.** `ESC c` (RIS, what `reset` sends) was
  treated as a soft reset: the cursor homed and attributes came back, but the
  old contents stayed. RIS now also erases the screen, leaves the alternate
  buffer and drops the scrollback.
- **The alternate screen no longer pollutes the scrollback.** Every full-screen
  application that scrolled -- an editor, a pager, a TUI repainting itself --
  pushed its transient frames into the pane's history and buried the real shell
  output.
- **Stray characters on application exit are gone.** Two classes of escape
  sequence were not fully consumed: DCS/SOS/PM/APC strings (a capability query
  such as XTGETTCAP had its payload printed as text), and private CSIs
  introduced by `<`, `=` or `>` (modifyOtherKeys, the kitty keyboard protocol),
  whose remainder leaked as text or was wrongly applied as an attribute.
- **A restored cursor is clamped to the current geometry.** A cursor saved
  before a resize could be restored outside the grid, after which every write
  was silently dropped and the pane looked dead.

### Faster, especially over SSH

- **Window drags no longer resend the whole screen.** FreeVision asks for a
  forced full repaint on every bounds change, and a window is a group, so each
  step of a drag re-sent every cell. Measured on a real session over SSH at
  163x64: 802 of 1639 frames were full repaints, 9.9 MB of the 10.2 MB emitted
  while dragging a window in circles. The forced flag is now ignored -- the
  per-cell delta is always correct on its own -- and the few places that truly
  need a repaint ask for one explicitly. **13926 -> 1810 bytes per drag step,
  and 23x fewer cells per frame.**
- **Frames are coalesced when more input is already waiting.** A mouse drag
  produces events far faster than a frame can cross an SSH link, and each one
  produced its own frame -- a round trip whose result the next event
  immediately superseded. A frame is now skipped when input is already queued,
  bounded at 40 ms so the screen can never be starved. On a burst drag:
  **148355 -> 69696 bytes and 45 of 132 frames saved**, and the same applies to
  the wireframe mode.
- **Startup paints once.** The whole build, promote and re-attach sequence is
  buffered and flushed a single time, instead of redrawing the screen four
  times. Routine repaints redraw only the changed cells; a forced full repaint
  is kept only for real size changes, returning from passthrough, and the
  explicit refresh.
- **`F5` is a single step in both directions.** Zooming was visible in two
  stages -- the window maximized inside the interface, then passthrough took
  the screen on the next tick -- which read as an unintended animation and cost
  an extra full screen of traffic. Entering fullscreen now costs no repaint at
  all from the multiplexer; leaving costs exactly one.

### New options

Both are per-profile, saved in `superterm.ini`, and toggled from the Options
menu like autosave and autorestore.

- **Show contents while dragging** (`[session] dragcontent`, default on). With
  it off, a dragged window shows only its frame: the window is hidden for the
  gesture, so the desktop and the windows behind it stay visible through it,
  and only the moving outline travels. Each step touches just the difference
  between the two outlines -- the strip the frame vacates and the one it takes
  -- which is **29 cells per step** on a 53x29 window instead of redrawing the
  interior. Worth turning on for a slow link or a content-heavy pane.
- **Zoom transition** (`[session] zoomanim`, default off). A short expanding
  and contracting outline when `F5` maximizes or restores a pane, about 350 ms.
  Purely cosmetic: the instant transition remains the default because it is the
  fast one.

### Passthrough refinements

- **The mouse works again after un-maximizing.** Leaving passthrough turned
  mouse reporting off, while FreeVision -- which enables it once at startup and
  never re-emits it -- still believed it on, so clicks stopped reaching the
  menu, status line and frames. The pointer also stayed an I-beam instead of an
  arrow.
- **The mouse belongs to the application while maximized.** A click on the
  hidden-but-still-logical menu row used to pop the menu and drop out of zoom,
  and a drag could not select text. The pane now owns the mouse; only `F5`
  leaves.
- **A restored pane keeps its own size.** Un-zooming re-tiled every window, so
  a window the user had sized by hand came back filling the screen as if it had
  stayed maximized.

### Session protocol

- **The attach protocol is versioned (v3).** The pane snapshot serialises cells
  by their record size, which per-cell colour grew from 14 to 24 bytes. A
  daemon outlives its clients and the two can be different builds, so a
  mismatch made every cell be read at the wrong offset. Both sides now refuse a
  mismatch, and the refusal explains itself instead of silently starting a
  fresh local session.
- **Wide panes can be attached again.** The snapshot validator refused any
  screen wider than 4096 columns although the application itself allows 8192,
  so such a pane could be saved and never loaded back. The limits are named in
  one place and the producer clamps to them as well.
- **A full scrollback fits again.** The frame ceiling is a budget in cells, and
  the larger cell silently cut it by 40%: a pane over roughly 280 columns with
  a full history could no longer be attached at all.

### Startup

- **Synchronized output (DECSET 2026) is opt-in** (`SUPERTERM_SYNC=1`). It
  presents each frame atomically, but it also holds the frame until released
  and some terminals do not present it until the next input, which looked like
  nothing being painted until a key was pressed. The single write per frame --
  the actual win over SSH -- stays unconditional.
- **The startup session picker renders while you choose.** The
  one-flush-at-end startup buffered it too, so it came up blank until a key was
  pressed.

## 3.1 - 2026-08

### Full-fidelity passthrough for maximized panes
- Maximizing a pane (F5) now hands it the **whole host terminal** and writes
  its raw PTY bytes straight through, bypassing the CP437/16-color grid. A
  rich TUI (Claude Code and the like) renders untouched: truecolor, emoji,
  wide glyphs and box drawing exactly as the app intended, instead of
  collapsed to `?` and 16 colors. F5 again un-maximizes and the window
  manager reclaims the screen. Every window operation (restore, minimize,
  switch, close, split) leaves passthrough automatically. While a pane is
  passed through, every key reaches it except the prefix (still detaches)
  and F5 (the way out). Assumes a single attached client.

### Smoother window manager over SSH
- The screen driver now emits each frame as a **single write wrapped in
  synchronized output (DECSET 2026)** instead of hundreds of tiny writes.
  Over SSH this collapses the per-frame TCP segments into one and lets the
  terminal paint atomically, so moving and resizing windows is noticeably
  faster and no longer tears.

### No more accidental nesting
- Launching the interactive UI (`superterm` or `superterm attach`) from
  inside a superterm pane is now refused, the way tmux guards `$TMUX`:
  otherwise the pane attached to its own session and mirrored forever. The
  control CLI (`list`/`send`/`capture`/...) still works from inside a pane;
  set `SUPERTERM_ALLOW_NESTED=1` to force nesting on purpose.

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
