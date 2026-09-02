# Outstanding Work

The current release build and the complete `make test` suite pass. The items
below are remaining follow-up work, not currently failing regressions.

## macOS (native port)

superterm builds and runs natively on macOS from the same source tree (see
`docs/MACOS.md`); the full `make test` suite passes on macOS (103 checks).
Remaining macOS follow-ups:

- `DarwinProcArgv` captures pane command lines via `sysctl KERN_PROCARGS2` and
  `DarwinProcCwd` reads `libproc PROC_PIDVNODEPATHINFO`; keep verifying parity
  with the Linux `/proc` behavior as new pane/command cases appear.
- Mouse works via self-enabled xterm SGR reporting (`{$IFDEF DARWIN}` in
  `vendor/fv322/drivers.pas`, since the FPC RTL mouse unit is a NOMOUSE stub on
  Darwin). Revisit if a future FPC ships a working Darwin mouse unit.

## Compiler Diagnostics

- Resolved. This entry used to claim 28 standing `Note` diagnostics from
  `vendor/fv322`, non-inlined inline calls and `FpRead`/`FpWrite`. Measured on
  2026-09-01 against the current tree, all four build modes (release, debug,
  test-runtime, debug-heap) compile 63089 lines with **zero** errors, warnings,
  notes and hints. The count was stale, not the code.
- `-Sewnh` now makes any diagnostic fatal, so the property is enforced instead
  of merely reported. If a future FPC introduces a new note, the build stops
  and it is fixed or suppressed with `-vm<number>` and a comment saying why.

## Test Coverage

- Add a maintained automated `top` integration test. The manual isolated-PTY
  smoke test passes, but the installed pyte parser raises on private CSI
  margin sequences emitted by `top`.
- Add automated remote/SSH attach coverage. Local detach, reattach, pane
  survival, input, socket cleanup, and permanent close are covered.
- Add protocol and snapshot corruption tests for malformed session frames,
  truncated screen data, invalid layouts, and unexpected client disconnects.
- Exercise the custom wide-screen video driver against real Konsole/tmux and
  terminals other than the xterm-compatible pyte test surface.

## Runtime Review

- Audit detached-server child reaping and pane-exit reporting under repeated
  child termination and server/client disconnect races.
- Review remote-session failure recovery and resize behavior after a lost
  connection.
- Expand the CP437-to-Unicode mapping in `src/st_video.pas` if additional
  FreeVision glyphs are needed by menus, dialogs, or non-English locales.
- Measure wide-screen redraw cost at several thousand columns; the custom
  flush fixes the FPC 3.2.2 short-string truncation but still emits changed
  cell runs directly to the terminal.

## Verification

- `make test`: passing.
- `test/large_screen_test.py`: passing at 4096 columns and the 8192-column
  draw-buffer limit, including normal/bright background fills and resize/restore.
- Plain interactive `top`: manually passing in an isolated PTY; no `nice`
  wrapper was used.

## Client threading (branch `newsupertermc`)

- `test/layout_transition_test.py` counts the intermediate frames of a maximize
  (8 show + 8 hide rings). The client output reactor may now legitimately
  coalesce superseded frames, so the count is no longer guaranteed. Decide
  which it is by watching the animation, not the log: either the test is
  asserting an implementation detail the reactor is entitled to collapse, or
  the zoom is genuinely dropping visible steps. Everything else the reactor
  regressed is fixed; this is the last open item.

## Resolved Quirks

- The RTL unix keyboard driver treated a lone ESC as an Alt prefix and
  blocked forever waiting for the next key, so bare Esc never reached the
  app and prefix chords written in a single PTY write could be swallowed.
  Fixed by st_kbd.pas: a custom keyboard driver (SetKeyboardDriver) that
  decodes stdin itself with a 50 ms ESC timeout and handles CSI/SS3 keys
  plus X10/SGR mouse.
