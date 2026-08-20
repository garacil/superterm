# Outstanding Work

The current release build and the complete `make test` suite pass. The items
below are remaining follow-up work, not currently failing regressions.

## Compiler Diagnostics

- A clean Free Pascal build still emits 28 `Note` diagnostics. They are not
  warnings or errors, but should be removed or deliberately suppressed if a
  completely quiet build is required.
- The notes come from legacy FreeVision code in `vendor/fv322`, inline calls
  that FPC 3.2.2 does not inline, and `FpRead`/`FpWrite` calls in project
  PTY/server/video code.

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
