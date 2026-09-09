# What the shared sources do differently on macOS

Every difference is a `{$IFDEF DARWIN}` branch inside a file GNU/Linux also compiles. There
is no macOS-only unit and no fork. This file explains *why* each branch exists, because the
code says what it does and not what it is avoiding.

Counts as of 5.2.2: `src/st_pty.pas` has 13 darwin conditionals, `vendor/fv322/drivers.pas`
has 3. `macos-support` adds nothing to either — they are in `main`.

## The PTY: `openpty()` instead of the SysV dance — `src/st_pty.pas`

Linux allocates a pty with `posix_openpt` / `grantpt` / `unlockpt` / `ptsname`, then the
child opens the slave **by name** and claims it with `setsid` + `TIOCSCTTY`. That sequence
does not work on darwin. The darwin branch calls `openpty()` once, keeps both fds, and the
child calls `login_tty()`, which is setsid, controlling-terminal and the three `dup2`s in
one call. The parent closes the slave after the fork.

This has a consequence far from the PTY code, and it is worth knowing before it confuses
someone: **the child starts sooner on macOS.** Both fds already exist at fork time, so a
program that writes immediately (`echo TOKEN; exec bash`) can produce output before the
tiler has finished sizing the pane. On Linux the open-by-name path is slow enough that the
resize lands first. That ordering difference is what exposed a genuine shared bug in
`TScreen.Resize`, fixed in 3.5.0 by shrinking into the blank rows below the cursor before
scrolling content into the scrollback. The bug was never macOS-specific; macOS just made it
happen every time.

## Process introspection: libproc and sysctl instead of `/proc`

There is no `/proc` on macOS, so the helpers that give a pane its title are re-implemented:

- `DarwinDeepestChild` walks `proc_listchildpids`. **It returns a count of pids, not a byte
  size** — reading it as bytes is the mistake to avoid, and we made it once.
- `DarwinProcArgv` reads `sysctl KERN_PROCARGS2`, whose buffer starts with `argc` as a raw
  `cint`.
- `DarwinProcCwd` uses `proc_pidinfo` with `PROC_PIDVNODEPATHINFO`, taking `vip_path` at
  offset 152.

`DarwinProcCwd` also **strips a leading `/private`**: because `/tmp` and `/var` are
firmlinks, the kernel reports `/private/tmp/x` for a directory the user knows as `/tmp/x`.

Two of these needed explicit initialisation (`argc := 0`, `buf := Default(...)`) not for
correctness but because the compiler's flow analysis cannot see through `Move` and the
syscall, and the build must stay at zero hints.

## The mouse: FreeVision's RTL driver is a stub on darwin — `vendor/fv322/drivers.pas`

Darwin is a BSD, so FPC's `Mouse` unit compiles as `NOMOUSE`: `DetectMouse` returns 0 and
nothing ever enables xterm reporting. The darwin branches in `DetectMouse` /
`EnableTmuxMouse` (with the `IsXtermClass` helper) emit the SGR-1006 enable sequences
themselves for xterm-class terminals, so clicks and drags work in Terminal.app and iTerm2.
Incoming sequences are decoded by the RTL **keyboard** unit, which is not stubbed, so only
the enabling side was missing.

This is the only change inside vendored FreeVision, and it is documented in
`vendor/fv322/README.md` as well.

## Button shadows: soft ink on darwin only — `vendor/fv322/dialogs.pas`

`TButton.Draw` paints its shadow with CP437 half blocks (#220/#223) whose ink resolves to
pure black over the dialog's light grey. A DOS VGA cell read that as a soft shade; a modern
terminal font renders a solid black bar. The darwin branch keeps the glyphs and lifts only
the ink to dark grey (`(Bc and $F0) or $08`), matching the window shadows (`ShadowAttr
$08`). Compile-time, automatic, and compiled out on GNU/Windows: their binaries stay
byte-identical. Chosen over a config option on purpose — nobody should have to know this.

## The mouse pointer shape: a host limitation, tested and settled

In Terminal.app the pointer stays an I-beam over the whole window even while superterm has
full mouse tracking enabled (`?1000h ?1002h ?1003h ?1006h` — clicks and drags work). There
is a standard escape to request an arrow (`OSC 22 ; left_ptr`), and we tested it
empirically on macOS 15.6: **Terminal.app ignores it**, with tracking active and the
pointer over the window (screenshot taken with the cursor included). **iTerm2 behaves the
same** — tested with the sessions dialog open and full tracking active: the pointer stays
an I-beam over the content there too. The pointer shape is drawn by the host terminal, and
neither of the two stock choices on macOS lets an application change it. Terminals that
honour OSC 22 (kitty, WezTerm, Ghostty, xterm) can show an arrow; nothing superterm emits
will change the others. Not fixable from inside superterm — documented so nobody chases it
again.

## Transports that do not exist here

`enum TransportType { TCP, WS }` — there is no UDP transport in the vendored SIP stack, and
the TCP socket connects in the clear (the secure branch is commented out). Nothing macOS
specific, but it comes up whenever configuration asks for `udp` or `tls`.

## Not a difference, but the reason a Mac finds bugs first

Three real, shared defects were discovered here before anywhere else, all for the same
reason — timing and environment differ enough to turn "usually fine" into "always broken":

1. `TScreen.Resize` scrolling a pane's first line into scrollback (3.5.0).
2. The daemon shutting down correctly but being left as a **zombie**, because on darwin it
   stays a child of the client instead of being reparented, so a liveness check using
   `kill(pid, 0)` counts it as alive.
3. `/bin/bash` here is **3.2.57**, from 2007. It predates bracketed paste (added in 4.4) and
   its default prompt is ~40 columns wide. Two test failures traced back to that alone, and
   neither was a product bug.

When something fails only on macOS, suspect the environment before the product — and prove
it either way before reporting it.
