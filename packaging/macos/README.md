# macOS packaging and release

superterm runs natively on macOS from the same sources as GNU/Linux. There is no separate
port and no macOS-only source tree: every darwin difference lives behind `{$IFDEF DARWIN}`
in the shared files, and all of it is already merged into `main`.

Written against superterm 5.2.2 on macOS 15.6 / Apple Silicon, FPC 3.2.4.

## What `macos-support` actually adds over `main`

Twelve lines in `Makefile.in`, and nothing else:

```make
ifeq ($(shell uname -s),Darwin)
BASE_FLAGS += -vm6058 -k-w
endif
```

- `-vm6058` mutes the ~69 *"inline is not inlined"* notes the aarch64-darwin RTL emits for
  `FillChar`/`Move` inside vendored FreeVision. GNU/Linux never produces them, so the flag
  is guarded rather than global. The generated code is identical either way.
- `-k-w` passes `-w` to the linker, silencing the duplicate `-lc` warning FPC 3.2.4 hands
  to Xcode's ld64. GNU ld has no `-w`, hence the guard again.

Everything else — the PTY, the mouse, the process helpers — is in `main`. **If you build
`main` on a Mac it works**; you only get the build noise this block removes. That is the
whole delta, and keeping it that small is the point: see `DIFFERENCES.md` for what the
shared sources do differently on darwin and why.

## Build

```sh
./configure
make                       # release  -> bin/superterm
make debug                 # -> bin/superterm-debug
```

A clean build is **0 errors, 0 warnings, 0 notes, 0 hints**. Treat any diagnostic as a
regression: the last three were real (`O_NOFOLLOW` and the `Users` unit are Linux-only, and
`QWord(GetThreadID)` is a pointer cast on darwin).

The one line ld still prints, `-macosx_version_min has been renamed`, is an FPC 3.2.4
artifact and is not suppressible without changing compiler.

Building from a detached tag, where the Darwin block may not exist yet, needs the flags by
hand:

```sh
make FPCFLAGS_EXTRA="-vm6058 -k-w"
```

**Never build with `sudo`.** A root-owned `build/` or `bin/` then fails with *"Can't create
assembler file"* or silently produces a stale binary. If it happens:
`sudo chown -R "$USER":staff /opt/superterm`.

## Release

`./release.sh <version>` does the whole thing and refuses to continue if anything is off.
It builds arm64, cross-builds x86_64, makes the universal binary with `lipo`, ad-hoc signs
both, packages the two tarballs with their `.sha256`, and **extracts each tarball to check
the binary inside reports the expected version** — a failed copy once shipped a 27 KB
tarball with no binary in it at all.

Upload is deliberately a separate step, so the release notes and the GNU assets can land
first:

```sh
./release.sh 5.2.2                       # build + package + verify
./release.sh 5.2.2 --upload              # the same, then gh release upload --clobber
```

Assets produced, matching the naming the GNU side uses:

```
superterm-<version>-macos-arm64.tar.gz      + .sha256
superterm-<version>-macos-universal.tar.gz  + .sha256
```

After uploading, add the macOS section to the release notes if it is not there —
`notes-snippet.md` is the block we use, with the version substituted.

## Where the version lives

`VERSION` at the repo root, injected into `src/st_version.inc` by the Makefile. The release
script reads `VERSION` and refuses to package if the argument you gave it disagrees, which
is what stops a 5.2.1 tarball carrying a 5.2.2 binary.

## Signing

The binaries are **ad-hoc signed** (`codesign --force -s -`), not signed with a Developer ID
and not notarised. That is enough to run, but Gatekeeper will quarantine anything downloaded
through a browser, so the install instructions tell the user to clear it:

```sh
xattr -dr com.apple.quarantine superterm
```

`lipo` invalidates the signatures of the slices it joins, so the universal binary **must** be
signed after `lipo`, not before. The script already does this in the right order.

If we ever want a notarised build, that needs a paid Developer ID, `codesign --timestamp
--options runtime`, and `notarytool submit --wait` followed by stapling. Not done today, on
purpose — nobody has asked and it adds an Apple account to the release path.

## Things that bite

- **`/etc` and `/var` are symlinks** to `/private/etc` and `/private/var`. Anything that
  refuses paths crossing a symlink rejects every canonical location on this platform. This
  cost us hours in a sibling tool.
- **There is no `/proc`.** Pane titles and child-process discovery use libproc
  (`proc_listchildpids`, which returns a **count**, not a byte size, and `proc_pidinfo` with
  `PROC_PIDVNODEPATHINFO`) plus `sysctl KERN_PROCARGS2`.
- **Firmlinks:** a captured cwd comes back as `/private/tmp/...` where the user typed
  `/tmp/...`. We strip the `/private` prefix.
- **`fsync()` does not flush to stable media** on macOS; durability needs
  `fcntl(fd, F_FULLFSYNC)`.
- **SIP** makes `/usr`, `/bin`, `/sbin` and `/System` unwritable even as root. `/usr/local`
  is writable, which is why installs go there.
- **The filesystem is case-insensitive** by default.
- **launchd, not systemd.** No `Restart=on-failure` semantics, and the environment is
  minimal — no user `PATH`, no shell profile.
- **`timeout(1)` does not exist**, and `xcrun simctl`-style tools are not on the default
  `PATH`. Homebrew lives at `/opt/homebrew/bin`.
- **zsh does not word-split unquoted variables.** `for f in $LIST` iterates once over the
  whole string. Use an explicit list or `${=LIST}`. This silently shipped a tarball missing
  its README and LICENSE.

## Status

Verified on Apple Silicon: clean build, `bin/superterm --version` correct, and the full
suite runs. When triaging test failures here, **run the suite directly** —
`python3 test/<name>_test.py` — before believing `run_tests.py`: under its parallel load
several suites fail on this machine purely from contention and pass in isolation.

macOS assets have shipped for 2.1, 3.0, 3.0.1, 3.2, 3.3, 3.4.1, 3.4.2, 3.4.3, 3.5.0, 3.5.1,
3.5.2 and 5.2.2.
