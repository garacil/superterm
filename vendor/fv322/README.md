These units are the Free Vision sources from Free Pascal 3.2.2
(source commit `0d122c49534b480be9284c21bd60b53d99904346`).

The system Free Vision units cap views at 255 columns and store the detected
screen dimensions in byte-sized fields. Superterm needs wider terminal panes,
so `views.pas` and `drivers.pas` use an 8192-column draw buffer and word-sized
screen dimensions. The remaining units are rebuilt with them because their
interfaces depend on the Free Vision view and driver units.

`drivers.pas` also carries a small `{$IFDEF DARWIN}` change: on macOS the FPC
RTL mouse unit compiles as a `NOMOUSE` stub (Darwin is a BSD), so it never
enables xterm mouse reporting and `DetectMouse` returns 0. The `{$IFDEF DARWIN}`
blocks in `DetectMouse`/`EnableTmuxMouse` (and the `IsXtermClass` helper) enable
xterm SGR mouse reporting for xterm-class terminals so clicks and drag work in
Terminal.app/iTerm2. Linux/other platforms are unaffected (the branch is
compiled out). The incoming SGR sequences are decoded by the RTL keyboard unit,
which is not stubbed.

`compile.sh` adds this directory before the installed Free Vision unit path;
the system package is not modified.

`views.pas` deliberately lets `TView.MakeLocal` walk the complete owner chain
even when an intermediate local coordinate is negative.  The upstream early
exit assumes that every owner starts inside its parent; SuperTerm's fixed
logical desktop uses a negative local origin for a client-side viewport.  The
complete traversal is the inverse of `MakeGlobal` and keeps mouse coordinates
correct while that viewport is scrolled.
