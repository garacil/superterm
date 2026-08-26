# Changelog

## 4.2.1 - 2026-08

### Original copyleft alien-hacker desktop artwork

The legacy `goody.art` compatibility slot now contains an original alien
hacker created for SuperTerm instead of the Opera Soft loading screen. Its
checked-in RGBA source is distributed with the project under GPLv3, and fades
to transparency on all four edges. The deterministic background generator
turns that alpha gradient into ordered cell dithering, so the picture dissolves
into any desktop colour without a hard rectangular slab. Existing profiles
keep working because the installed filename and configuration identifier do
not change. An optional bounded logical-width field preserves the full 128x46
transparent canvas without trailing whitespace; regression coverage rebuilds
all generated backgrounds and asks the real Pascal loader for that geometry.
Generated scenes now use filled RGB cells that the terminal paints as
backgrounds, rather than font-rendered shade glyphs. This removes the visible
horizontal and vertical seams that some terminal fonts left between cells;
the hand-built half-block tile patterns retain their intended detail.

### Standard SSH clients can open SuperTerm over encrypted TCP

SuperTerm can now publish its interactive UI through a dedicated instance of
the system OpenSSH server. A normal client connects with a normal command,
for example `ssh -p 8022 user@server`; OpenSSH provides the TCP listener,
cryptography, Unix-account authentication, PAM and the outer PTY, then a
restricted `ForceCommand` starts the regular SuperTerm client. From there the
existing private Unix-socket protocol attaches to exactly the same session
daemon as a local client. A network loss, terminal close or Detach therefore
removes only that viewer and the live desktop remains available for reattach.

This TCP listener is deliberately independent of the host's ordinary SSH
service. It has its own process, service, addresses, ports and PID. Its
configuration, host key and managed public-key store live under
`/etc/superterm/sshd`; setup never edits `/etc/ssh/sshd_config`, replaces the
normal host keys, restarts the normal `sshd` or takes port 22. The two
listeners may run together, using the same installed and audited OpenSSH
binary. The dedicated instance may accept PAM-backed passwords, centrally
managed public keys and/or each account's existing `authorized_keys`; root is
public-key-only and must be enabled explicitly.

The service is configured with an explicit list of TCP interfaces and ports
and is administered through idempotent `ssh-server setup`, `check`, `enable`,
`disable`, `restart`, `status`, `authorize`, `list-keys`, `revoke` and
`uninstall-service` commands. Candidate configurations are published
atomically only after both SuperTerm's checks and the installed `sshd -t/-T`
accept them; failed service updates roll back. systemd and launchd use the
same source-level policy and keep all persistent service state across package
updates.

The entry is intentionally an interactive SuperTerm service, not a second
general-purpose shell service: UDP, remote commands, sessions without a PTY,
SFTP/SCP, subsystems, forwarding, X11, agent forwarding and client-supplied
environment are not supported. Keep the ordinary `sshd` for those facilities.
The complete security boundary, authentication matrix, installation and
diagnostic procedure is documented in `docs/SSH_SERVER.md`.

### Sessions and profiles can be created safely at runtime

The Sessions menu can create another named session at any time and asks which
profile supplies its initial desktop, including an explicit empty choice. The
Profiles manager can likewise create an empty profile before any panes exist.
Profile and class catalog updates now use a process-safe lock, generation
checks and atomic file replacement, so concurrent clients either observe one
complete update or receive a real conflict instead of overwriting one another.

An SSH entry routes each account to its last live SSH session by default, or
to the configured default session/profile chain. The first connection uses a
per-user session lock so simultaneous logins attach to one published daemon
rather than starting duplicate desktops. Reconnecting receives the exact live
shared geometry, panes, focus and terminal contents already owned by that
daemon.

### Process ownership and network backpressure are hardened

The detached daemon is now the real parent and reaper of the initial panes,
including panes created by the first SSH client. PTY spawning has a bounded,
nonblocking result channel and validates process birth identity before any
signal; shutdown and test cleanup cannot target a reused PID or process group.
Daemon startup uses an isolated double-fork/`setsid` path, cancellation cleans
partially published sockets, and dead pane children are reaped without
blocking the session reactor. A deliberately empty desktop remains live for
later pane creation.

Every viewer also has a bounded nonblocking output queue. A client which
stops reading can be disconnected independently without stalling panes,
other clients or the global command FIFO. Discovery sidecars and mutable
configuration are written with validated ownership and atomic replacement on
GNU/Linux and macOS.

### Fullscreen no longer consumes physical F5

Fullscreen/restore moved to the configurable `prefix f` chord (`Ctrl-Q f` by
default), which is safe inside browser-hosted terminals. Physical F5 is now
delivered to the focused pane during normal input and raw passthrough. The
status line, menus, help, nested-SuperTerm forwarding and shared-client
animation path all use the same binding; Exit is no longer exposed on the
status bar, leaving Detach as the safe everyday action.

### Contextual command-line help is a complete navigable reference

`superterm --help` is now an index whose topic links lead to dedicated pages
for startup, targets, sessions, pane I/O, every window operation, standard SSH
clients, dedicated SSH administration and automation details. Every page gives
the exact syntax, accepted aliases and options, behavior, limits and copyable
examples; `--help all` emits the full deterministic plain-text reference for
people, scripts and AI agents.

`--help TOPIC`, `help TOPIC` and `COMMAND --help` use the same implementation,
including all English and Spanish aliases. Help never attaches, enters the TUI,
requires root or mutates user/service state; unknown topics return usage status 2.
The parser and reference now agree on the documented `--no-enter` and
`--sin-intro` forms, while a literal `help` or `--help` after `send --` remains
terminal input. A black-box index crawler checks every page and alias, compares
release/test output, validates deterministic formatting and proves the input
semantics against a real detached session.

### Release and regression boundaries are explicit

The administrative path overrides used by SSH tests exist only in the
separate, non-installed `bin/superterm-test`; the release binary rejects them
even when run as root. The suite now covers configuration publication,
authentication policy, standard OpenSSH transport, uninstall preservation,
session first-creation races, concurrent profile edits, daemon/PID identity,
PTY spawn failure, pane reaping and stalled-client backpressure. CI builds and
tests the shared implementation on GNU/Linux and both macOS architectures,
then exercises a real isolated OpenSSH listener in a privileged disposable
fixture.

## 3.5.2 - 2026-08

One live session is now exactly one shared desktop.  The daemon owns the
single pane tree, window geometry, PTY sizes, minimized/maximized state and
focus; every attached client sees those same values.  A differently sized
host used for attach is only a viewport: it clips or pads the desktop and
never silently reshapes it.  A later physical resize is an explicit shared
operation: the actor's new host size becomes the canonical desktop and every
window and PTY changes in the same transaction.  Detaching every viewer leaves
the live desktop exactly as it was for the next attach.

Client commands enter one bounded global FIFO and are applied by the reactor
in arrival order.  Visual mutations take a short per-pane lease (or the one
desktop lease for tree-wide operations), while terminal input remains ordered
and live.  Layout commits and synchronized terminal updates now present only
the authoritative result, removing the stale-snapshot flashes around move,
resize, minimize/restore, F5 and profile replacement.

The desktop may contain zero to sixteen panes.  It can close all panes and
create the first one again; attempts beyond sixteen report the real limit.
New panes created from a class are resolved completely by the daemon and
become visible only with their final title, size and position.  Class changes
are reloaded by a daemon that is already running.

Palette changes repaint the complete UI immediately and terminal-host resizes
preserve the selected palette.  There is one interactive Exit command: it is
client-local while other viewers remain, and the final Exit closes and removes
the session.  Detach is the separate operation that deliberately keeps it
alive.

F5 uses raw passthrough in every viewer when all attached hosts have the same
geometry.  With different geometries it remains inside the IDE and uses one
shared fullscreen viewport sized to the smallest host, so every viewer still
sees the same cells and the normal canonical desktop remains available on
restore.

Normal IDE maximize now follows the same common-viewport invariant while
retaining the menu, status line and window frame. If a later, larger client
has grown the canonical desktop, a new maximize and its PTY are capped to the
smallest host connected at commit time and restore still returns to the exact
larger pre-maximize rectangle. The daemon recomputes that size at commit time,
so a concurrent attach or host resize cannot install a stale oversized grid.
Later membership changes do not rewrite an already committed maximum: every
client renders its one canonical grid and a smaller late viewer simply clips
it. Direct and concurrent hand-offs also leave exactly one maximized pane;
the target owns the shared focus, commit-time size normalization is a valid
acknowledgement, and malformed maxima without restore geometry are rejected.

Double-clicking a window title follows the same serialized pane operation as
its zoom button: normal and IDE-maximized sizes alternate, the original
rectangle and focus are preserved, and every viewer receives one transition.

Live gestures now belong to the shared view too. While one client moves or
resizes a window, every other viewer receives the same bounded 60 Hz content
or wireframe path under that pane's lease. The optional eight-step maximize
and F5 outline is relayed in both directions as well, using each viewer's
active palette. Minimize/restore has no invented intermediate geometry: its
one atomic transition reaches every viewer. These previews are cosmetic and
ordered: they never change a revision, focus or PTY, cancellation rolls back
once, and only the final canonical commit changes the session.

The post-commit animation tail now carries an explicit presentation barrier:
an observer paints the authoritative restored IDE before its first contraction
ring even when both frames arrive in one socket batch. Session discovery
sidecars are likewise built privately and replaced with one atomic rename, so
concurrent attach/detach and CLI enumeration cannot collide on a half-written
INI file; a metadata read error safely falls back to the live socket identity.

Attach protocol v15 keeps those visuals correct when different clients hold
different panes at the same time. `FRAME_LAYOUT_PEER_EV` carries a
viewer-relative preserve mask: an owner applies a peer's committed panes,
focus and lock display immediately without replacing its own in-flight pane
or advancing that pane's older lease base. The two commits then merge as
successive canonical revisions. Preview `CLEAR` is also presentation-atomic:
the renderer retains the last transient frame until the following canonical
layout can replace it in the same output transaction, even when the socket
drain budget separates the two frames across event-loop ticks.

The regression suite now exercises multi-client ordering, attach/detach churn,
shared focus and geometry, atomic visual transitions, empty/maximum desktops,
class creation, palette preservation and heap/debug stress runs. A dedicated
three-viewer concurrent-gesture oracle releases two same-revision pane leases
in both orders, with content and wireframe dragging, and rejects any
`final -> old -> final` presentation while checking the two merged PTY sizes.

## 3.5.1 - 2026-08

A daemon that blocks on nothing, panes that may spread across cores, and a
viewport that belongs to each client alone.

### Nothing in the session daemon blocks any more

The detached daemon is a single poll(2) reactor now. The listener, half-made
connections, attached clients and the pane PTYs are all nonblocking and
served from one `fpPoll` loop with per-tick budgets, so no single peer can
park the process. A connection that sends half a header expires after a
second; a client that keeps half a megabyte waiting and makes no progress
for ten seconds is cut loose while everyone else continues; input queued for
a program that stopped reading its terminal waits for its own POLLOUT
without delaying another pane or socket; a frame header promising more than
the protocol allows drops that peer on sight; and descriptors above the old
select() ceiling of 1023 are simply descriptors.

### Panes may spread across cores

`[session] multithread=1` -- the default -- keeps the daemon exactly as it
was: one thread, one reactor. `multithread=auto`, or a total thread cap,
lets busy panes run on their own `fpPoll` workers, created when a pane
appears and removed when it closes, while the socket reactor remains the
single owner of every client and session structure. The effective cap never
exceeds the CPUs available to the process, `SUPERTERM_MULTITHREAD` overrides
the file for one launch, and a running daemon keeps the mode it started
with. GNU/Linux and macOS.

### Each attached client owns its geometry

Attaching or resizing a smaller terminal no longer changes the one real PTY
size and reflows every other client. The default `resize_policy=session`
keeps one canonical daemon screen and gives each UI a private viewport into
it, including cursor following and translated mouse/copy coordinates. Window
geometry and focus stay local; shared titles and explicit CLI window commands
still propagate. `resize_policy=smallest` retains the former common-minimum
behaviour. The pane menu can explicitly fit the shared PTY to the current
window when that is what the user wants.

An interactive exit is now client-local while other viewers remain attached.
`Alt-X` still saves and `Alt-Q` still skips saving, but neither can terminate
another active UI; the last client closes the session. Explicit CLI `kill`
remains session-wide.

### Smaller notes

- F5 passthrough stays geometrically safe when the attached clients use
  different terminal sizes, and the FreeVision cursor repaint no longer
  leaks into raw mode.
- The macOS build is back to zero compiler hints: the darwin libproc buffers
  are initialized where the data-flow analysis cannot see `Move` and
  `proc_pidinfo` filling them.
- Every push now builds and runs the full suite on GNU/Linux x86_64, macOS
  Apple Silicon and macOS Intel.
- The daemon's new manners have their own coverage: fragmented frames,
  stalled peers, pending-slot overflow, oversize headers, descriptors past
  1023, the per-client viewports, and the multicore reactors under load.

## 3.5.0 - 2026-08

Text that moves between panes, a pane that keeps its colours when you look
away, and the tracing written down at last.

### Clipboard history across local and SSH panes

The new `Clipboard` / `Portapapeles` menu keeps the ten most recent items in
memory and lets one be selected for paste. `Ctrl-Q [` enters pane copy mode,
`Ctrl-Q ]` pastes the newest item, and `Ctrl-Q h` opens the history. Host
terminal paste is captured atomically with bracketed-paste mode, while pane
copies and pane-generated OSC 52 writes reach the host clipboard without
allowing a pane to query and read it. UTF-8, scrollback, attached sessions,
and mouse selection use the same client-local history.

### Focus changes the border, not the terminal

An unfocused pane no longer has its terminal cells darkened into greyscale.
Every pane keeps the application's exact foreground, background and text
attributes whether focused or not; only the window border/title and terminal
cursor indicate focus. Because the pane interior is unchanged, focus switches
also leave those cells out of the terminal delta instead of retransmitting
content over a local or SSH connection.

### Minimize or restore every window

The `Windows` / `Ventanas` menu now contains `Minimize all windows` and
`Restore all windows`. Both commands update the complete workspace together;
individual minimize and restore entries remain in `Panes` / `Paneles`.

### How to trace superterm, written down

`docs/DEBUGGING.md` is new. It says what `SUPERTERM_DEBUG` and
`SUPERTERM_DEBUG_FULL` turn on, that a debug build traces by itself while a
release build only traces when asked, and how to read a line of trace and the
prefixes it uses. It documents the crash report -- reason, role, pid, uptime,
a backtrace with file and line, and the last of the trace -- and that the
release build keeps `-gl` so that backtrace still names a line. It explains
how to trace a session someone else is attached to, and how to drive a
reproduction from a script with `test/stlib.py`, the same harness the suite
runs on. It ends with three ways of measuring that quietly lie: a shell that
echoes the marker you are waiting for, a line ending in a carriage return that
the next prompt paints over, and a picture read from where it is installed
rather than from the tree you just edited.

## 3.4.3 - 2026-08

What an afternoon of real use asked for, and the crash it found.

### The mouse died after moving the focus away from Claude Code or Codex

Open a full-screen program that wants hover -- Claude Code, Codex -- in a
pane, click on another window, come back, and after a round or two the
pointer turned from an arrow into an I-beam and not one click reached the
window manager again. Only restarting superterm brought it back, and only
until the next time. `top` and `htop` never showed it.

That is the shape of the bug. Those two ask the terminal for **any-motion**
tracking, `?1003h`, which `top` and `htop` do not; superterm passes it on to
the host terminal while such a pane has the focus, and takes it back with
`?1003l` when the focus moves. xterm keeps the three tracking modes as
independent flags, so taking the highest one back leaves `?1000`/`?1002`
standing. Konsole -- and it is not alone -- holds ONE mouse mode, so the same
sequence leaves it reporting nothing at all.

The base modes are re-asserted immediately after now. Three sequences, a
no-op on a terminal that kept them, and the difference between a working
pointer and a dead one everywhere else.

### A picture is painted by the terminal, not by the font

The desktop pictures were drawn with the full block glyph, U+2588, in the
cell's colour. That should look like a solid rectangle and does not: the
block comes from the terminal's font, and a font whose U+2588 does not quite
fill its cell -- most of them, once the terminal stretches or hints it --
leaves hairlines between one cell and the next, so a picture made of them
reads as blurred.

Every whole cell is a SPACE on a coloured background now. The terminal paints
that itself, exactly, whatever the font is doing. The picture files do not
change: it is the drawing that does.

The word left in the grid is still the block, on purpose. That word is the
overlay's oracle -- what says a cell is still the picture's -- and "a space in
some attribute" is a word every dialog and menu writes too, so registering the
picture under it made a dialog drawn on top match by coincidence and bring the
picture back through its own body. Dialogs looked transparent for as long as
that lasted, which was one build. `test/dialog_opaque_test.py` opens three of
them over a picture, in colour and in monochrome, and counts what shows
through.

### Every picture is typed with one character

A picture is drawn with the dark shade block, `▓`, in the cell's own colour --
every cell of every picture, always the same character. The colours are
exactly the ones the filled version had; what you gain is seeing the grid a
picture is made of. There is one Goody, and it is this one.

The grid behind it still gets the full block, whatever the picture is drawn
with: that word is what tells the renderer a cell is still the picture's, and
it has to be a word nothing else on the screen writes. A space in some
attribute is written by every dialog; the shade blocks are written by every
scrollbar trough. Both were tried, and both let a picture show through the
body of a dialog -- the second one in exactly the column its scrollbar was
in. `test/dialog_opaque_test.py` opens three dialogs over a picture, in
colour and in monochrome, and counts what comes through.

### A pane created in the daemon got no window of its own

Attached to a session, creating a pane -- from a class, from the menu, from
the CLI -- made the focus jump to a window that was already open, and closing
that window killed the client with a segmentation fault in `SyncScrollBar`.

The client mirrors the daemon's panes in four parallel arrays. Inserting one
shifts them up, and the slot the shift vacates has to be cleared. Three of
them were: `Panes`, `Scr` and `PaneTerm`. `Win` was not, so it still held the
pointer the shift had just copied up -- the neighbour's window, now in the
array twice. `CreateWindowForPane` refuses to build a window where `Win` is
not nil, so the new pane never got one, the focus landed on the neighbour's,
and closing either index freed the shared window through one slot and left
the other dangling. The next repaint walked into it and died.

The local path had always cleared all four. Only the remote one had not,
which is why it took a daemon to see it, and only when the new pane landed in
the middle of the order -- appended at the end, nothing shifts and nothing
breaks. `test/remote_newpane_test.py` reproduces exactly that.

### Maximising a window is not the same as taking the terminal

Any zoom put the pane into passthrough, so maximising a window with its own
icon threw the whole IDE off the screen. They are two things now:

- **Maximise** -- the window's `[↑]` icon, or `Panes > Maximize/restore` --
  fills the desktop and leaves the frame, the menu bar and the status line
  exactly where they are.
- **`F5`** -- and only `F5` -- hands the whole terminal to the pane, which is
  what a full-fidelity TUI wants. `F5` again puts the window back where it
  was.

### Closing the last window empties the desktop, it does not end the program

It used to quit. Now the menu bar, the status line and the picture stay
exactly where they were and the desktop is simply empty; `Classes`, or
`Panes > Split`, open a pane again -- the session, local or in a daemon, is
perfectly happy holding none. A detached session with nothing alive in it and
nobody attached still closes itself after the usual grace period, so nothing
is left lying around.

Leaving is something you ask for, and `Panes` carries a way out of its own
now -- `Exit superterm`, `Alt-X` -- next to where the hand already is after
closing everything.

Also: entering passthrough turned any-motion mouse reporting off at the
terminal without recording that it had, so superterm and the terminal could
disagree about it afterwards. The flag now says what is true.

## 3.4.2 - 2026-08

The desktop: its pictures, its colour, and the shadows cast on it.

### Menu labels that were being cut in silence

A screenshot caught the Options menu reading "Show contents while dragg".
FreeVision's menu item type is `String[31]` (vendor/fv322/menus.pas:91), so a
longer label is truncated where it is built, with no diagnostic, and the box
is then sized to the cut text -- nothing looks wrong except the missing
letters. Five were over, counting the `(*) ` an on/off item carries and the
`~` that mark the hotkey, and so was the "Restore N title" line whenever a
window title was long.

### One long-standing test flake, gone

`passthrough_test` failed about two runs in eight, and had done since before
any of this. Both faults were in the test: the rich line it prints ended in a
carriage return, so the shell's next prompt landed on top of it and the
assertion depended on the renderer emitting a frame in the gap -- which it
coalesces on purpose; and the wait was for a word the shell's own echo of the
command carries, so the slice under test could be the echo. Six runs in a row
pass now.

### The pictures are drawn for the screen they live on

At 1024x768 with the classic 8x16 console cell the terminal is 128x48
characters and the desktop is that less the menu and status rows: 128x46.
The pictures were 74x22, barely a third of the width, so they were either
stretched or stranded in a corner. They are drawn at 128x46 now by
`tools/mkbackgrounds.py`, which is in the tree so they can be redrawn or
added to rather than hand-edited.

Two of them are converted from real artwork rather than drawn: the 7kas
phoenix, from the brand's own vector file, and Goody, the Opera Soft loading
screen, which is new.

### Only the full block, never a half one

Half blocks, quadrants and the shade characters all come apart the moment
the terminal font is stretched -- which is what a maximised window, or
simply a different console font, does to them. Every picture is now drawn
with two glyphs and no others: the full block, in one colour, and the space
where there is nothing at all. Stretching samples whole cells, so a
stretched picture is made of whole blocks too.

That halves the pixels a picture has, so the drawing earns them back
elsewhere: ordered dithering where a colour is snapped to the palette (sixty
-two colours cannot hold a long gradient and snapping banded it), textures
that blend rather than toss a coin per pixel, and a soft pass over the
layers that should read as continuous. Alaska's snow settles by altitude on
the range instead of by a threshold per column; London is rebuilt around
Westminster, with the Eye as a true circle rather than an ellipse of spider
web.

One old bug came out with it: the reader takes a row from its third
character, which is what the hand-written tile patterns have always been
written for, and the generated pictures had no space after the marker. Every
one of them had its first column eaten and the rest shifted one to the left.

### The desktop's colour is a choice

The desktop was filled with attribute 0 -- black, always. `Options >
Desktop colour...` now opens a picker with the sixteen text-mode colours as
swatches. Black stays the default, and the colour fills the desktop and the
empty cells of a picture alike.

A picture keeps its own colours in every palette, including black and white
and monochrome. It was tried the other way -- no picture at all outside the
colour palette -- and it is worse: what shows through between the windows is
the picture the user chose, and taking it away is not what a palette is for.

### The ground is ours to paint

A screenshot showed superterm tinted green from top to bottom -- panes,
menus and status line alike -- and nothing here emits green. It was the host
terminal answering for the parts superterm did not answer for itself: a cell
whose background is the palette's black went out as "colour 0", which a
themed terminal paints as whatever it calls black, and a pane cell whose
background is the terminal default went out with no background at all, which
on a transparent terminal is a hole straight through the application.

Every background is explicit now. Only black is forced, so a themed terminal
keeps its own blue and cyan, and the text colour is never touched -- it is
the ground that has to be solid, not the letters. `Options > Solid
background` turns it off for anyone who wants that transparency.

### A shadow over a picture looks like a shadow

FreeVision casts a shadow by keeping the character underneath and forcing
its attribute to the shadow one. The rich overlay gates every cell on the
buffer word the pane wrote there still standing, so that attribute change
dropped the cell to its CP437 fallback: the shadow of a menu over a desktop
picture came out as the picture's own block characters in dark grey, which
is how it had looked from the beginning. The cell is now recognised for what
it is, kept, and darkened -- over a picture and over a pane's own truecolor
output alike.

## 3.4.1 - 2026-08

Everything the history needed to actually work, found by using it.

### The history was empty in a session opened from a profile

There was no scrollbar and nothing scrolled, because those panes were
created with a scrollback ring of **zero lines**: the profile reader
defaulted the per-pane `scrollback` key to 0 while the window-class reader
defaults it to 10000. The writer only stores that key when it is greater
than zero, so a missing key never meant a deliberate zero -- it meant "not
stated". It now means the normal default, and a pane is never created with
no ring at all whatever the caller passed.

### The scrollbar drove another pane after opening or closing a window

Clicking the bar moved the thumb and it snapped straight back, and the text
never moved -- while the wheel worked. A window points at its pane from
three places: itself, the terminal view and the scrollbar. Panes are
renumbered whenever one is inserted or closed, and the six sites that do it
updated the first two and left the scrollbar on the old index, so it scrolled
a different pane's viewport. All six now move the three together.

### The scrollbar is there from the start

Hiding it until the first line scrolled off made a window with a fresh shell
look like a build without the feature -- which is exactly how it was
reported. It now shows with the thumb filling the trough, as every terminal
does, and still goes away on an icon, on a window too short for it, and while
an application owns the alternate screen.

Plain `PgUp`/`PgDn` scroll as well now, but only where nothing else wants
them: on the normal screen, and only once there is history. An application on
the alternate screen keeps them, and so does a shell before anything has
scrolled off.

### Opening a window never touches the ones already open

`F2`/`F3` still split the focused window in two in 3.4: the new pane took
half of it. That is still "creating a window changed the window I was
using", and repeating it halves a window until nothing fits -- measured
going from 28 columns to 25 in six rounds. There is now one rule for every
way of opening a window: centred, at the size its class asks for, on top,
and nothing already open is moved or resized. Tiling stays on demand:
`Windows -> Tile`, or prefix + `t`.

## 3.4 - 2026-08

Four things you asked for, and the repairs they turned up on the way.

### Opening a window no longer resizes the ones already open

Creating a pane ended in a full re-tile: opening a third window resized the
two you had and sent each of their programs a size change. Every other
operation had already been taught not to do this -- minimize, restore, close
and leaving a maximised pane all leave the rest alone. Creation was the last
one left.

- **One rule, every way of opening a window.** It appears centred, at the
  size its class asks for, on top of whatever is there, and nothing already
  open is moved or resized -- `F2`/`F3` included. Splitting the focused
  window in two was tried first and is not what is wanted: creating a window
  must not change the window you were using, and repeated splits halve a
  window until it is unusable. Classes gain
  `cols` and `rows` in cells, editable in the class dialog; unset, they fall
  back to `[ui] newwincols`/`newwinrows`, and unset too, to two thirds of the
  desktop. The first window of a session still takes the whole desktop.
- **Tiling is one keystroke away** when you want it: `Windows -> Tile`, or
  prefix + `t`.

### The history is reachable

The scrollback engine was complete and nothing let you use it: the only way
in was an undocumented `Alt-PgUp`.

- **A scrollbar** in each window's right frame column. It costs the pane no
  column and no resize, and appears only while there is history and the
  application is not on the alternate screen.
- **The mouse wheel**, three lines a notch, without taking the focus. On the
  alternate screen -- `less`, `man`, `vim` -- it sends arrow keys instead,
  which is what makes the wheel work there at all.
- **`Alt-PgUp`/`PgDn`/`Home`/`End`**, with `Ctrl-` and `Shift-` aliases for
  terminals that let them through. Any key meant for the application returns
  the view to live first.
- **The view stays where you are reading** while output keeps arriving,
  instead of being dragged toward the bottom.
- History rows are stored trimmed, which cuts the memory a long history costs
  by roughly six times and ships less in an attach snapshot. The wire format
  is unchanged.

### The arrow keys work in `top` and `htop`

Every curses program puts the terminal in application cursor keys mode and
from then on expects `ESC O A` for Up, ignoring the form superterm was
sending. The emulator now follows that mode, and the keypad modes with it.

### superterm inside a superterm pane

Nesting was refused outright, because a pane attaching to its own session
mirrors forever. It is now refused by identity rather than by presence: each
pane carries the chain of sessions it lives inside, each daemon publishes its
own, and only the sessions on that chain are rejected -- at any depth,
including a loop that goes out through a second session and back. A new
session, or a different one, is as safe from a pane as from any terminal.

And **the mouse reaches the application inside a pane**: presses, releases,
drags, hover and the wheel, re-encoded at pane coordinates in the protocol
the application asked for. The frame, the title bar, the menu and the status
line stay superterm's, with no rule to learn -- so a nested superterm's own
window manager works inside the pane.

### Repairs found on the way

- **superterm could hang at startup, before its first line ran.** On a
  terminal the RTL does not recognise it tried to reach gpm with a blocking
  connect during unit initialisation; with gpm installed but not accepting,
  that never returned. superterm now installs its own mouse driver: every
  terminal gets a mouse, and on the console gpm is probed without blocking.
  That is also why the console had no mouse at all before.
- **A client could lose visible content when another client resized a pane.**
  It resized its own copy optimistically instead of waiting for the daemon's
  answer, and shrinking sends the top rows to the history.
- **`Restore all` left the restored windows behind the big one.**
- The middle and right mouse buttons were crossed against the RTL's numbering.
- The 4096-column "stale corners" reported in 3.3 was the test sampling the
  screen before the resize had finished painting. There is no such defect; see
  the correction under 3.3.1.

### Upgrading

Sessions from 3.3.x reattach unchanged: no frame changed shape and
`ATTACH_PROTO_VER` stays at 3.

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
