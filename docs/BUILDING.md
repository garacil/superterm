# Building superterm

## Source tree

`src/` contains the application code:

- `src/superterm.lpr` is the program entry point.
- `src/st_fvui.pas` contains the FreeVision application, menus, panes, windows, and event routing.
- `src/st_pty.pas` owns PTYs and child processes.
- `src/st_config.pas` reads terminal definitions and user settings.
- `src/st_templates.pas` reads INI and SQLite templates.
- `src/st_session.pas` persists the fallback session layout.
- `src/st_layout.pas` calculates pane split trees.
- `src/st_screen.pas` interprets terminal output for each pane.
- `src/st_server.pas` owns detached PTYs and the Unix-socket attach protocol.

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
- A POSIX host: GNU/Linux (with `/proc`) or macOS (Apple Silicon or Intel).

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

The release executable is `bin/superterm`.

The debug build uses level-1 optimization, debug symbols, line information,
and the `DEBUG` define:

```sh
make debug
```

The debug executable is `bin/superterm-debug`.

For extra compiler flags:

```sh
make MODE=debug FPCFLAGS_EXTRA='-Sa'
```

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

The tests launch isolated PTYs. They do not attach to, restart, or modify a
user's tmux server. The detach test starts superterm's own per-user server,
checks that a pane survives the client exit, reattaches it, and then closes it
permanently. The mouse tests cover both normal xterm `TERM` values and
`tmux-256color`.

## Install

System installation normally requires root:

```sh
./configure --prefix=/usr/local --sysconfdir=/etc
make release
sudo make install
```

The installation contains:

- `PREFIX/bin/superterm`.
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

The application writes optional runtime diagnostics when `SUPERTERM_DEBUG` is
set:

```sh
SUPERTERM_DEBUG=/tmp/superterm-debug.log bin/superterm
```

The log includes PTY creation, terminal sizes, pane focus, key routing, and
template activation. Do not put passwords in debug logs or command lines.

## Platform support

superterm is a single cross-platform codebase that builds and runs natively on
GNU/Linux and macOS. Both are POSIX systems using `fork/exec`, `select`, POSIX
PTYs, and the bundled FreeVision text UI. The only conditionally compiled unit
is `src/st_pty.pas`, which selects the PTY/process backend with `{$IFDEF DARWIN}`:

- GNU/Linux: `posix_openpt`/`grantpt`/`unlockpt`/`ptsname` and `/proc` process titles.
- macOS: `openpty` + `login_tty` and `libproc`/`sysctl` process titles. Free
  Pascal auto-defines `DARWIN`, so the compile line, `configure`, and `make` are
  identical to GNU/Linux. Run in Terminal.app or iTerm2. See
  [`MACOS.md`](MACOS.md) for terminal setup and platform notes.

No other unit is platform-conditional, so a change merged on one OS applies to
both. Windows support would require a separate PTY backend based on ConPTY, plus
Windows process, resize, signal, and configuration-path implementations; WSL is
the practical way to run superterm on Windows today.
