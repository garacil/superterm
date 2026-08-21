# superterm on macOS

superterm builds and runs natively on macOS (Apple Silicon and Intel) from the
**same source tree** as GNU/Linux. macOS and GNU/Linux are both POSIX systems, so
the FreeVision UI, VT engine, layout, configuration, SQLite templates, and the
session server — including the 3.0 always-server mode, the bilingual control
CLI and multi-client attach, which are plain UNIX sockets, `fork` and
`select` — are shared without change. (The nonblocking client sends use the
platform's `MSG_DONTWAIT` value, selected at compile time.) The 3.0 server
features have their regression suite run on GNU/Linux; a validation pass on
macOS hardware is still pending. The only platform-conditional
unit is `src/st_pty.pas`, which selects its PTY/process backend at compile time
with `{$IFDEF DARWIN}`. Free Pascal auto-defines `DARWIN` for a macOS host, so
there are no special build flags.

## Build

```sh
# One-time: install the Free Pascal compiler (libsqlite3 ships with macOS)
brew install fpc        # or: make install-deps   (auto-detects macOS/Homebrew)

# Build (identical to GNU/Linux)
./configure
make release            # -> bin/superterm  (Mach-O arm64/x86_64)
```

`make debug` produces `bin/superterm-debug` with symbols and range checks.
`make info` prints the selected compiler, target, and paths.

The compiler ships with the aarch64-darwin RTL (FreeVision is vendored in
`vendor/fv322`), so no extra Free Pascal packages are required.

## Running in Terminal.app / iTerm2

Run it like any terminal program:

```sh
bin/superterm
```

Recommended terminal profile settings:

- **Encoding: UTF-8** (the default). superterm draws box/line glyphs as UTF-8,
  so a UTF-8 profile with a monospace font that has them (Menlo, SF Mono) renders
  the borders cleanly.
- **Use Option as Meta key** (Terminal.app: *Profiles → Keyboard*; iTerm2:
  *Profiles → Keys → Left/Right Option key → Esc+*) so Alt/Meta shortcuts and
  the `Ctrl-B` prefix behave as on GNU/Linux.
- **Mouse**: works out of the box — clicks (menus, pane focus, split) and
  drag-to-resize. superterm enables xterm SGR mouse reporting itself on macOS
  because the FPC RTL mouse driver is a `NOMOUSE` stub on Darwin (see the
  `{$IFDEF DARWIN}` block in `vendor/fv322/drivers.pas`). Nothing to configure.

## Platform notes (how macOS differs internally)

| Concern | GNU/Linux | macOS |
| --- | --- | --- |
| PTY allocation | `posix_openpt`/`grantpt`/`unlockpt`/`ptsname` | `openpty()` + `login_tty()` (libc) |
| Process titles / cwd | `/proc/<pid>/{stat,cmdline,cwd}` | `libproc` (`proc_listchildpids`, `proc_pidinfo`) + `sysctl` (`KERN_PROCARGS2`) |
| Detach/attach server | `fork` + AF_UNIX socket | identical (works unchanged) |
| Config directory | `$HOME/.superterm` | identical |

Everything else — splits, windows, templates, session save/restore, SSH panes,
scrollback — is the shared code path and behaves identically.

## Known differences and tips

- **`sshpass`** is not installed on macOS by default. Prefer SSH keys or an SSH
  agent (safer, and the default recommendation). If you specifically need
  password-authenticated SSH panes, `brew install sshpass`.
- **Local shell** defaults to your login shell (`$SHELL`, typically `/bin/zsh`).
- **`/usr/bin/bash` does not exist on macOS** (bash is `/bin/bash`). If you write
  a terminal definition with an explicit shell path, use `/bin/zsh`, `/bin/bash`,
  or a bare `bash` (resolved via `PATH`).

## Verifying the build

The Python regression suite (`test/*.py`, driven through a real PTY with `pyte`)
runs on macOS:

```sh
python3 -m pip install --user pyte     # once
make test
```

The suite exercises rendering, local shell panes (the macOS `openpty` path),
splits, detach/attach, session restore (the `libproc` command capture), and the
wizard.
