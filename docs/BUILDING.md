# Building superterm

## Source tree

`src/` contains the application code:

- `src/superterm.lpr` is the program entry point.
- `src/st_fvui.pas` contains the FreeVision application, menus, panes, windows, and event routing.
- `src/st_pty.pas` owns PTYs/ConPTY instances and child processes.
- `src/st_conpty.pas` implements the native Windows ConPTY backend.
- `src/st_config.pas` reads terminal definitions and user settings.
- `src/st_templates.pas` reads INI and SQLite templates.
- `src/st_session.pas` persists the fallback session layout.
- `src/st_layout.pas` calculates pane split trees.
- `src/st_screen.pas` interprets terminal output for each pane.
- `src/st_clipboard.pas` keeps the ten-item client history and OSC 52 helpers.
- `src/st_kbd.pas` decodes keyboard, mouse, and bracketed-paste input.
- `src/st_server.pas` owns detached PTYs and the Unix-socket attach protocol on
  POSIX; native Windows currently uses its single-process stubs.

`vendor/fv322/` is the local FreeVision source used by the build. It is not a
copy of application code. It provides the `Objects`, `Drivers`, `Views`,
`Menus`, `App`, `Dialogs`, and `MsgBox` units. It must appear before the system
FreeVision units in the compiler search path because superterm uses the local
wide-screen and mouse fixes.

`bin/` contains the executable and generated compiler files. `build/` contains
mode-specific Free Pascal units. Both are generated directories.

## Dependencies

Required:

- Free Pascal Compiler 3.2.2 or a compatible 3.x compiler.
- Free Pascal FV, FCL, and DB units.
- GNU make.
- GNU/Linux (with `/proc`), macOS (Apple Silicon or Intel), or Windows 10
  version 1809 or newer for ConPTY.
- Git Bash when building natively on Windows; it runs `configure` and the
  POSIX shell recipes in the generated Makefile.

Required only for the regression suite:

- Python 3.
- Python package `pyte`.

Needed for remote features:

- `openssh-client` for SSH terminals.
- `sshpass` only when password authentication is explicitly configured. SSH keys
  or an SSH agent are safer and preferred.

On Debian or Ubuntu (apt) or macOS (Homebrew), the project can install the
common packages explicitly:

```sh
./configure --install-deps
```

The same operation is available after configuration:

```sh
make install-deps
```

The scripts do not install packages implicitly during a normal build.

## Configure

The repository includes a self-contained POSIX `configure` script. It does not
require GNU Autoconf. It detects `fpc`, `make`, Python, and common runtime
commands, then creates the ignored `Makefile` from `Makefile.in`.

```sh
./configure
```

On native Windows, run the build from Git Bash and put the Free Pascal binary
directory first on `PATH`. The GNU Make 3.80 shipped with Free Pascal is
supported; use that `make.exe` explicitly if another tool (for example an
Embarcadero make) appears first on `PATH`:

```sh
export PATH="/path/to/fpc/bin:$PATH"
./configure --with-fpc="$(command -v fpc)"
make release
./bin/superterm.exe --version
```

For a user-local installation:

```sh
./configure \
  --prefix="$HOME/.local" \
  --sysconfdir="$HOME/.config/superterm"
```

Useful overrides:

```sh
./configure --with-fpc=/usr/local/bin/fpc
./configure --with-python=/usr/bin/python3
```

Inspect the selected paths with:

```sh
make info
```

## Build modes

The default release build uses Free Pascal level-4 optimization (`-O4`) and
keeps warnings enabled:

```sh
make release
```

The release executable is `bin/superterm` (`bin/superterm.exe` on Windows).

The debug build uses level-1 optimization, debug symbols, line information,
and the `DEBUG` define:

```sh
make debug
```

The debug executable is `bin/superterm-debug` (`bin/superterm-debug.exe` on
Windows).

For extra compiler flags:

```sh
make MODE=debug FPCFLAGS_EXTRA='-Sa'
```

For memory audits, `make debug-heap` builds the separate
`bin/superterm-debug-heap` executable (`.exe` on Windows) with FPC HeapTrc and
per-process memory reports. See [HEAP_DEBUGGING.md](HEAP_DEBUGGING.md) for the
required variables, report lifecycle and stress-test examples.

The compatibility wrapper is still available:

```sh
./compile.sh
./compile.sh -B
```

It configures the tree when needed and delegates to `make`. Use `make` when
selecting a build mode or installation path.

## Tests

Build the release binary and run every Python/pyte regression test:

```sh
make test
```

Each suite has an independent 15-minute deadline. A timed-out suite and its
process group are terminated, the remaining suites still run, and the final
summary lists every failure. Override the per-suite deadline when required:

```sh
SUPERTERM_TEST_TIMEOUT=1200 make test
```

The runner is implemented in Python and works on Linux and macOS; it does not
depend on the GNU `timeout` utility.

The regression harness uses POSIX `pty`, `fcntl`, and `termios` modules, so it
does not run in native Windows Python. On Windows, use `make release`, check
`bin/superterm.exe --version` or `--help`, and launch it for an interactive
ConPTY smoke test.

The tests launch isolated PTYs. They do not attach to, restart, or modify a
user's tmux server. The detach test starts superterm's own per-user server,
checks that a pane survives the client exit, reattaches it, and then closes it
permanently. The mouse tests cover both normal xterm `TERM` values and
`tmux-256color`.

## Install

On POSIX, system installation normally requires root:

```sh
./configure --prefix=/usr/local --sysconfdir=/etc
make release
sudo make install
```

The installation contains:

- `PREFIX/bin/superterm` (`superterm.exe` on Windows).
- `PREFIX/share/doc/superterm/README.md`.
- `PREFIX/share/doc/superterm/BUILDING.md`.
- `PREFIX/share/doc/superterm/CONFIGURATION.md`.
- `PREFIX/share/doc/superterm/WIZARD.md`.
- `SYSCONFDIR/superterm/superterm.ini.example`, only when no example exists.

An existing configuration is never overwritten by `make install`.

For a user-local install:

```sh
./configure --prefix="$HOME/.local" \
  --sysconfdir="$HOME/.config/superterm"
make install
```

Then ensure `$HOME/.local/bin` is in `PATH`.

## Debugging

The application writes runtime diagnostics when `SUPERTERM_DEBUG` names a
file, and a build made with `make debug` writes them without being asked:

```sh
SUPERTERM_DEBUG=/tmp/superterm-debug.log bin/superterm
bin/superterm-debug                       # traces to /tmp/st-crash.log
```

The log covers PTY creation, terminal sizes, pane focus, key routing, mouse
modes, passthrough and template activation, and a fatal signal leaves a report
with a backtrace that names the source file and line. Do not put passwords in
debug logs or command lines.

[`DEBUGGING.md`](DEBUGGING.md) covers the whole of it: what each kind of trace
line means, how to hand a traced session to somebody else, how to read the
crash report, and how to reproduce a problem from a script with the test
harness.

## Platform support

superterm is a single cross-platform codebase that builds and runs natively on
GNU/Linux, macOS, and Windows 10 1809 or newer. The FreeVision UI, VT engine,
layout, and configuration are shared, while compiler directives select the
terminal, process, input, console, and path implementations.

- GNU/Linux: `posix_openpt`/`grantpt`/`unlockpt`/`ptsname` and `/proc` process titles.
- macOS: `openpty` + `login_tty` and `libproc`/`sysctl` process titles. Free
  Pascal auto-defines `DARWIN`, so the compile line, `configure`, and `make` are
  identical to GNU/Linux. Run in Terminal.app or iTerm2. See
  [`MACOS.md`](MACOS.md) for terminal setup and platform notes.
- Windows: ConPTY, native console VT input/output, Windows process management,
  `%COMSPEC%` (normally `cmd.exe`) as the default shell, and configuration under
  `%APPDATA%\superterm`. See [`WINDOWS.md`](WINDOWS.md).

GNU/Linux and macOS provide the detached session daemon, multi-client attach,
session enumeration, and control CLI. Native Windows currently runs interactive
workspaces in one process; those detached-session features are not available
there yet.
