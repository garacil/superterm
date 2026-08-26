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
- `src/st_clipboard.pas` keeps the ten-item client history and OSC 52 helpers.
- `src/st_kbd.pas` decodes keyboard, mouse, and bracketed-paste input.
- `src/st_cli.pas` parses the bilingual control CLI and talks to session daemons.
- `src/st_cli_help.pas` is the single structured presentation source for the
  contextual command-line reference.
- `src/st_server.pas` owns detached PTYs and the Unix-socket attach protocol.
- `src/st_ssh_server.pas` builds and administers the isolated OpenSSH service.
- `src/st_ssh_entry.pas` is the restricted `ForceCommand` adapter into the
  ordinary Unix-socket session client.

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
- Free Pascal FV, FCL, DB, and POSIX thread units (`fp-units-misc` supplies
  `PThreads` on Debian/Ubuntu).
- GNU make.
- A POSIX host: GNU/Linux (with `/proc`) or macOS (Apple Silicon or Intel).

Required only for the regression suite:

- Python 3.
- Python packages `pyte` and Pillow.
- `rsvg-convert` (`librsvg2-bin` on Debian/Ubuntu, `librsvg` with Homebrew),
  used to prove that the checked-in artwork reproduces from its sources.

Needed for remote features:

- `openssh-client` for SSH terminals.
- The operating system's OpenSSH server for the optional dedicated encrypted
  TCP entry described in [SSH_SERVER.md](SSH_SERVER.md): `openssh-server` on
  Debian/Ubuntu and the `/usr/sbin/sshd` included with macOS. It uses isolated
  state under `/etc/superterm/sshd` and does not modify the host's ordinary
  `/etc/ssh` configuration.
- `sshpass` only for an outgoing SSH pane explicitly configured with a
  password. SSH keys or an SSH agent are safer and preferred. Incoming
  password authentication through the dedicated SuperTerm service is handled
  by system OpenSSH/PAM and does not use `sshpass`.

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

`make test` also builds `bin/superterm-test` in a separate unit directory.
Only that non-installed executable contains the compile-time hooks used to
redirect SSH paths and service-manager programs into isolated test fixtures;
the release binary rejects those overrides even when invoked as root. Never
install or use `superterm-test` as a service binary.

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

For memory audits, `make debug-heap` builds the separate
`bin/superterm-debug-heap` executable with FPC HeapTrc and per-process memory
reports. See [HEAP_DEBUGGING.md](HEAP_DEBUGGING.md) for the required variables,
report lifecycle and stress-test examples.

The compatibility wrapper is still available:

```sh
./compile.sh
./compile.sh -B
```

It configures the tree when needed and delegates to `make`. Use `make` when
selecting a build mode or installation path.

## Tests

Build the release binary and run every Python regression test:

```sh
make test
```

Each suite has an independent 15-minute deadline. A timed-out suite and its
process group are terminated, the remaining suites still run, and the final
summary lists every failure. Override the per-suite deadline when required:

```sh
SUPERTERM_TEST_TIMEOUT=1200 make test
```

The runner is implemented in Python and works on GNU/Linux and macOS; it does not
depend on the GNU `timeout` utility.

The ordinary suite uses `bin/superterm-test` for isolated administrative path
overrides, but passes `bin/superterm` separately to an unprivileged boundary
test which proves that the release cannot enable those hooks. A real OpenSSH
listener needs root for account/session setup, so an unprivileged local run
reports that integration as skipped rather than claiming partial coverage. CI
repeats only that listener test under `sudo`, with disposable keys,
configuration and a non-root target account on every platform.

The tests launch isolated PTYs. They do not attach to, restart, or modify a
user's tmux server. The detach test starts superterm's own per-user server,
checks that a pane survives the client exit, reattaches it, and then closes it
permanently. The mouse tests cover both normal xterm `TERM` values and
`tmux-256color`.

The contextual help contract has its own black-box test. It crawls every topic
from the printed index, checks all English/Spanish command aliases and required
options, compares release and test binaries, verifies side-effect-free SSH help
and exercises `--no-enter`, `--sin-intro`, their compatibility spellings and
literal `--help` against a real isolated session:

```sh
make release test-runtime
SUPERTERM_RELEASE_BIN="$PWD/bin/superterm" \
SUPERTERM_TEST_BIN="$PWD/bin/superterm-test" \
python3 test/cli_help_test.py
```

`make test` performs both builds automatically. When this test is invoked
directly, naming both binaries is important: it verifies that release help and
the test-only runtime publish byte-identical public help while retaining their
different privileged-feature boundaries.

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
- Every Markdown file under `docs/`, including `SSH_SERVER.md`.
- `SYSCONFDIR/superterm/superterm.ini.example`, only when no example exists.

An existing configuration is never overwritten by `make install`.
Copying the binary does not silently enable the optional root SSH service;
`sudo superterm ssh-server setup` prepares or refreshes it explicitly.

For a user-local install:

```sh
./configure --prefix="$HOME/.local" \
  --sysconfdir="$HOME/.config/superterm"
make install
```

Then ensure `$HOME/.local/bin` is in `PATH`.

`make uninstall` first removes a recognized root SSH service when it is run as
root, then removes the package files while preserving `/etc/superterm/sshd`
keys and configuration. A user-local, unprivileged uninstall cannot own such a
service and therefore touches no host service. A `DESTDIR` uninstall only
changes the staging tree.

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
GNU/Linux and macOS. Both are POSIX systems using `fork/exec`, `poll`, POSIX
PTYs, and the bundled FreeVision text UI. The detached server registers its
listener, handshakes, clients and PTY masters through `BaseUnix.fpPoll`, with no
external event-library dependency and no `FD_SETSIZE` ceiling. The principal
platform adapters are the PTY/process and CPU-count backends plus the optional
SSH service manager; a few small POSIX type/constant branches remain beside
their shared call sites:

- GNU/Linux: `posix_openpt`/`grantpt`/`unlockpt`/`ptsname` and `/proc` process titles.
- macOS: `openpty` + `login_tty` and `libproc`/`sysctl` process titles. Free
  Pascal auto-defines `DARWIN`, so the compile line, `configure`, and `make` are
  identical to GNU/Linux. Run in Terminal.app or iTerm2. See
  [`MACOS.md`](MACOS.md) for terminal setup and platform notes.
- `src/st_cpu.pas` uses GNU/Linux affinity or macOS `hw.activecpu` for worker
  limits; `src/st_ssh_server.pas` uses systemd or launchd for its optional
  dedicated OpenSSH instance.

The session engine, UI, configuration and SSH entry protocol remain shared.
Windows support would require a separate PTY backend based on ConPTY, plus
Windows process, resize, signal, configuration-path and service-manager
implementations; WSL is the practical way to run superterm on Windows today.
