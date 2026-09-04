# Merging `windows-support` into `main`

A guide for the engineer who will carry the native Windows port up into
`main`. It says **what** the branch changed, **how** to merge each part, and
**whether it is safe** — grounded in the actual diff against `main`
(`git diff <merge-base>...windows-support`, 52 files, ~+8400/−730 at the time
of writing). The per-hunk detail lives in `TORESOLVE.md` §4; this document is
the plan and the verdict on top of it.

> **Do not treat this as a completed merge.** Nothing here has been merged into
> `main`. This is the analysis and the procedure only.

---

## 1. The one rule that makes it safe

`main` builds and ships GNU/Linux and macOS. The branch was written so that
**the Unix build's behaviour never changes**: every Windows change is either

- in a **new file** that only a Windows build ever compiles, or
- inside a `{$IFDEF WINDOWS}` / `{$IFDEF UNIX}` island in a shared unit, or
- a **platform-neutral** change small enough to inspect by eye.

The third category is the only one that can move a byte of the Unix binary, so
it is enumerated exhaustively in §4 below. If the merge preserves those three
shapes, the Unix build is unaffected *by construction*, and the verification in
§5 is there to prove it rather than to discover surprises.

Branch flow (see the project's branch-flow note): `main` flows **down** into
the platform branches; it never merges back automatically. This up-merge is a
deliberate, reviewed act — exactly what this document is for.

---

## 1b. What the merge actually required (done 2026-09-04)

The merge was carried out on this branch before fast-forwarding `main`, and
two things the sections below assumed turned out to be false. Recorded here so
the next up-merge checks them first instead of trusting the plan.

1. **The branch did not build on GNU/Linux.** Nobody had run the §5 gate
   before writing it. Under the strict contract FPC stopped, one unit at a
   time, on diagnostics that only appear off Windows: an unused local in
   `st_os.pas` (`Base`, used only in the Windows branch) and the hint *Unit
   "ctypes" not used* in `st_config.pas`, `st_debug.pas`, `st_pty.pas` and
   `st_server.pas` — on Unix every C type those units name already comes from
   `BaseUnix`, which is listed later and therefore wins, so `ctypes` is
   referenced by nothing. The fix is confined to `uses` clauses and one local
   declaration, every change under `{$IFDEF WINDOWS}`/`{$IFDEF UNIX}`, so the
   token stream the Windows compiler sees is the one that was verified on
   Windows. Rule for next time: **a unit whose types are also provided by a
   later unit in the same `uses` list is unused there** — guard it.
2. **`main`'s client activity notifications had been silently dropped.** The
   merge commit `c6bc07c` (2026-08-27) resolved a two-line conflict in
   `st_fvui.pas` by discarding the whole of `main`'s side of the file — the
   toast, the status-line tail, `cmToggleDesktopNotifications`, and in
   `st_server.pas` the daemon's `st_video.SuppressFlush := True` (commit
   `6dd697a`). Reproducing that merge with `git merge-tree` keeps all of it;
   the drop was manual and undocumented. `test/client_notifications_test.py`
   was still in the Makefile's `TESTS`, so `make test` on the branch would
   have failed. Restored under `{$IFDEF UNIX}` (the feature is Unix-only by
   decision; the Windows client never carried it), plus the `st_server`
   lines under the same guard.

The §4 procedure and §5 checklist still apply; the GNU/Linux gate was run on
the result (release and debug builds, `make test`).

## 2. Is it possible? — verdict

**Yes, and it is designed to be mechanical, with one mandatory gate.**

- The Windows-only new files (§3) carry no risk to Unix: they are never
  compiled there. They can be copied verbatim.
- The guarded hunks in shared units (§4.2 of `TORESOLVE.md`) do not change the
  Unix code paths: the Unix side of each `{$IFDEF}` is the original code. They
  can be copied, and the build proves it.
- The **only** things that touch the Unix build are the platform-neutral
  changes in §4 here (Makefile/configure, the vendored Free Vision cleanups,
  the `st_server` `uses`/`OsGetPid` refactor, metadata/docs). Each is
  behaviour-neutral, but the source is not byte-identical, so:

> **Mandatory gate:** build `main`+merge on GNU/Linux *and* macOS with the
> project's strict contract, run the POSIX test suite (`make test`), and
> confirm both pass exactly as `main` did. Only then is the merge accepted.

Nothing found on the branch is a fundamental blocker. The two things that
deserve a careful reviewer's eye, called out honestly:

1. **`st_server.pas` was refactored, not just extended.** Making the session
   daemon/client build on Windows meant lifting the shared protocol/FIFO/lease
   code out of a single `{$IFDEF UNIX}…{$ELSE}stubs…{$ENDIF}` split into
   per-concern islands. The diff is large (~+1300 lines) and the Unix bodies
   moved even though they did not change. This is a *review* cost, not a risk
   to behaviour — but it is why the Unix binary must be rebuilt and its tests
   re-run rather than assumed identical. See `TORESOLVE.md` §4.3.
2. **The vendored Free Vision tree changed** (`vendor/fv322/*`). These are
   `-Sewnh` cleanups and a `GetTickCount64` swap, all behaviour-neutral on the
   non-Windows branch, but they touch a third-party tree `main` also builds.

---

## 3. File inventory, by merge action

From the diff against `main`. Grouped by what the merger does with each.

### 3.1 New, Windows-only — copy verbatim, zero Unix impact

Compiled only by a Windows build; a GNU/Linux or macOS build never sees them.

| Path | What it is |
|---|---|
| `src/st_conpty.pas` | ConPTY backend; referenced only from `st_pty.pas` under `{$IFDEF WINDOWS}`. |
| `src/traytool/superterm-tray.lpr`, `src/traytool/README.md` | The notification-area helper program, built by the Windows-only `traytool` Make target; never part of `all`/`release`. |
| `src/superterm.rc`, `src/superterm.res`, `src/superterm_version.rh` | Version resource; linked via `{$R superterm.res}` under `{$IFDEF WINDOWS}` in `superterm.lpr`. |
| `packaging/windows/*` | Inno Setup script, `release.ps1`, `sign.ps1`, `trusted-signing.json`, `superterm-launch.cmd`, icon, README. Build/packaging only. |
| `test/windows/*` | PowerShell harness, FPC probes, `session_smoke.ps1`. Not part of the POSIX suite. |
| `docs/WINDOWS.md`, `TORESOLVE.md`, this file | Documentation. |

Action: add them as-is. Nothing to reconcile.

### 3.2 Shared units, guarded hunks — copy; Unix path is the original

Each change is inside `{$IFDEF WINDOWS}` (new Windows code) or `{$IFDEF UNIX}`
(the untouched original). The per-unit table is `TORESOLVE.md` §4.2; the
headline items:

| Unit | Windows-guarded change |
|---|---|
| `src/st_server.pas` | The whole detached daemon/client on Windows: AF_UNIX-over-Winsock transport, `WSAPoll`, name lock, socket identity, peek-based pane workers, `BuildBlueprint`/`RunSessionDaemonChild`/`CreateProcessW` server start. Plus two later fixes: `PollFd`/`WaitSocketReady` mask the `events` field for `WSAPoll` (a lock/close poll otherwise returned −1 → "shared desktop is busy"); and `[terminal] cols/rows` written to the sidecar so a re-attach can restore the window size. |
| `src/st_poll.pas` | `WSAPoll` backend behind the same `TSuperPoll` surface. |
| `src/st_pty.pas` | `TConPty` wrapper; `ExportLaunch`/`ImportLaunch` (shared) and `OutputAvailable`. |
| `src/st_kbd.pas`, `src/st_video.pas`, `src/st_mouse.pas` | Console VT setup, the resize/`WideSetVideoMode`/alt-screen path, mouse control. |
| `src/st_fvui.pas` | Windows idle/resize loop, `WaitForActivity`, `ReadTerminalSize`, passthrough, `MaybeStartTray` call site, the detach guard. |
| `src/superterm.lpr` | `--session-daemon` dispatch, `MaybeStartTray`, the `{$R}` resource, `Windows` in `uses`. |
| `src/st_config.pas` | Windows paths; `[session] server=always` as the Windows default. |
| `src/st_debug.pas`, `src/st_os.pas`, `src/st_cpu.pas`, `src/st_wclass.pas`, `src/st_cli_help.pas`, `src/st_artbg.pas`, `src/st_session.pas`, `src/st_profiles.pas` | Per-hunk Windows paths, process/CPU helpers, window-class command shape, help text, background loading. |

Action: copy. The Unix compiler only sees the `{$IFDEF UNIX}`/`{$ELSE}` side,
which is the original. §5 proves it.

### 3.3 Platform-neutral — the only Unix-affecting changes, review each

These are the ones a reviewer must actually read, because they are compiled on
Unix too. All are behaviour-neutral; none is byte-identical.

| Where | Change | Why it is safe |
|---|---|---|
| `Makefile.in`, `configure` | Windows target detection, `.exe` suffix, GNU Make 3.80 compatibility, the `traytool` target (guarded `ifeq ($(OS),Windows_NT)`). | Unix recipes and paths unchanged; `traytool` is inert off Windows. |
| `vendor/fv322/drivers.pas` | `GetTickCount` → `GetTickCount64`; `FVConsts` in `uses` only `{$IFNDEF OS_WINDOWS}`. | Same value modulo the 49.7-day wrap. |
| `vendor/fv322/views.pas`, `app.pas`, `dialogs.pas`, `menus.pas` | Unused `Windows` unit removed; CP850 table under its existing `{$ifdef unix}`; `-Sewnh` cleanups. | No code path changes. |
| `src/st_server.pas` `uses` + `OsGetPid` | Units moved from the `{$IFDEF UNIX}` list to unconditional (`IniFiles`, `Sockets`, `st_wclass`, `st_session`, `st_poll`, `st_cpu`, added `st_os`); `fpGetPid` → `OsGetPid`. | Same symbols already linked on Unix; effect nil, source not byte-identical — hence the rebuild+diff gate. |
| `src/*` `Unused()` helpers, `{$push}{$hints off}` regions | `-Sewnh` hygiene. | No code path changes; the `Unused` helper must stay local per unit (`Windows` exports a colliding one). |
| `.gitignore`, `CHANGELOG.md`, `docs/CLI.md` | Ignore rules, changelog, CLI doc availability wording. | Metadata/docs. |

---

## 4. The procedure (when the decision to merge is made)

Do not run this now; it is the recipe for the reviewer.

1. **Branch off `main`.** `git switch main && git pull && git switch -c
   merge/windows-support`.
2. **Merge the branch.** `git merge windows-support`. Conflicts should be rare
   and confined to files `main` also moved since the merge-base; resolve them
   keeping both the Unix original and the Windows `{$IFDEF}` side.
3. **Build Unix, strictly, on both targets.** GNU/Linux and macOS, the same
   `-Sewnh -vewnh` contract `main` uses. It must compile with no new
   diagnostics.
4. **Prove the Unix binary is behaviourally unchanged.** Run `make test` (the
   POSIX suite: `session_startup_atomic`, `nonblocking_server`,
   `multiclient_intensive`, the rendering/pty tests). It must pass exactly as
   on `main`. Optionally diff a release build of the binary against `main`'s;
   expect only the §3.3 deltas to account for any difference.
5. **Build Windows, strictly.** `make release` + `make traytool`; or
   `packaging\windows\release.ps1` (see `docs/WINDOWS.md`). Must be clean under
   `-Sewnh`.
6. **Smoke-test Windows.** `test\windows\session_smoke.ps1`
   (start/detach/reattach/kill), a resize pass with `hosttest.ps1`, and a tray
   reopen (`superterm-tray --attach NAME`) landing at the saved size, centred.
7. **Only then** fast-forward or merge into `main`.

---

## 5. Acceptance checklist

- [ ] `main`+merge compiles on GNU/Linux under the strict contract, no new
      diagnostics.
- [ ] `main`+merge compiles on macOS under the strict contract.
- [ ] `make test` (POSIX) passes with the same results as `main`.
- [ ] The only files that changed the Unix build are those in §3.3, and each
      was read and understood.
- [ ] Windows `make release` + `make traytool` compile clean under `-Sewnh`.
- [ ] `session_smoke.ps1` passes; resize, tray reopen, detach/reattach work.
- [ ] No secret or certificate material is introduced (`trusted-signing.json`
      holds only placeholders; there is no `.pfx` in the tree).

---

## 6. What is deliberately *not* going to `main` as behaviour

- **Signing / Azure Trusted Signing.** The tooling and docs come along (they
  are Windows packaging), but signing is a release-time step, not a code path.
  See `docs/WINDOWS.md` and `packaging/windows/README.md`.
- **The installer's runtime niceties** (close a running instance before
  replacing files; the sign-in auto-start task) live entirely in
  `packaging/windows/superterm.iss` — packaging, never compiled into any
  binary, Unix or Windows.

For the exact per-hunk mapping and the history of why each change exists, read
`TORESOLVE.md` — §2 for the narratives, §4 for the merge map this document
plans around.
