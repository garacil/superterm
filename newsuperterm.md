# newsuperterm.md — plan for the next SuperTerm

> Deliverable of a read-only study of `main` (== `newsuperterm`, HEAD `dbcc21f`,
> VERSION 4.2.1) and `speedupx` (HEAD `5d982f7`). No repo, branch, DB or doc was
> modified during the study. Every claim below is cited `file:line` against the
> checked-out tree; anything unverified is marked. Save this document as
> `newsuperterm.md` in the repo root.

---

## 1. Context — why this plan exists

`newsuperterm` is a literal copy of `main`. Two branches compete for the future:

- **`main`** — the shipped 4.2.1 architecture. Daemon owns PTYs/state; each
  client runs its own Free Vision tree and re-parses raw PTY bytes; the last
  mile is a hand-written cell-diff renderer that emits one buffered write per
  frame. Fast and friendly, but with real, verified weaknesses (§4).
- **`speedupx`** — the ARCH-01…ARCH-15A rearchitecture (52 commits, +246k/−6.5k,
  344 files): the daemon becomes the sole VT parser and publishes dense
  *semantic frames*; per-client compositor/presentation controllers; a Free
  Vision "worker boundary"; a thin client; raw passthrough optimisation.

**The measured verdict is decisive and it is against speedupx.** A same-host,
same-probe study (key→painted-echo latency) recorded:

| Geometry | main | speedupx |
|---|---|---|
| 100×30 (3k cells) | 15.4 ms | 21.4 ms |
| 200×50 (10k) | 16.1–18.1 ms | ~33–38.6 ms |
| 400×100 (40k) | 21.1–23.6 ms | ~91–108.5 ms |

speedupx is ~4.6× slower at 400×100 and, unlike main, its cost grows with
desktop **area**. Its own suite is red: 85 pass / 71 fail on GNU/Linux
(`speedupx:docs/references/index.md` §10; ARCH-15 nota in
`/home/german/superterm_plan.db` records 62 of 72 baseline failures still open),
and a full run takes ~71 min, over main's 45-min CI budget.

**Decision: build `newsuperterm` as "Main+".** Keep main's architecture as the
authority. Port from speedupx only the discrete pieces that do not depend on its
pipeline. Then close main's own verified weaknesses, each behind a measurement
gate. This document is that plan.

---

## 2. Confirming (and correcting) the "Main+" thesis

The external "Main+" study is right in its conclusion. Corrections found while
verifying it against the tree — these change *how* we optimise, so they matter:

| Study claim | Verified status |
|---|---|
| One buffered write/frame, input-aware coalescing, ignores FV's forced repaint | **TRUE.** `WideUpdateScreen` `src/st_video.pas:1167`; single `WriteRaw(Frame)` `:1404`; `COALESCE_MS=40` `:473`, gate `:1198`; `Force` used only in a debug line `:1409` (rationale `:1329-1334`, measured 802/1639 frames, 9.9 MB of 10.2 MB over SSH). |
| Diff is against `OldVideoBuf` | **FALSE.** The delta is against `EffOld: array of TEffCell` (`:489`, `EffEqual` `:1335`). `OldVideoBuf` is only blindly `Move`d at `:1405` — vestigial. Dirty-tracking work must key off `EffOld`, not `OldVideoBuf`. |
| Persistent FV tree at `st_fvui.pas:725` | **Claim true, line wrong.** 725 is a comment; the persistent per-client tree is `Panes/Scr/Win` at `src/st_fvui.pas:260-262`. |
| Never infer a 256-colour cap from `TERM=xterm-256color` | **main already never does.** The client emits truecolour unconditionally (`RichSGR` `st_video.pas:583`); `COLORTERM` appears only where the daemon *sets* it for pane children (`st_pty.pas:290`). Nothing to fix here — only to preserve. |
| main has `FLOW_STOP` / `attach --exclusive` / `resize_policy` | **None exist on main** (grep-verified). Backpressure is read-gating + lag-drop (`st_server.pas:7734-7741`, `:7778-7786`). |
| main "stays flat" with area | **TRUE outcome, nuanced cause.** Cells are fixed-size records so the diff pass is a cheap compare — but that pass is still O(desktop area) every frame (`st_video.pas:1222-1225`). Flat only because the per-cell constant is tiny. Dirty-region tracking (§5, I3) removes even this. |

**Why speedupx is slow (root causes, cited).** From the measured audit
(scratchpad `8ba0e0c8…/msg.txt`, `audit2.py`) and ARCH-15 nota:
- Per-published-frame it does ~6 full-surface validations + ~3 deep clones:
  `CloneTerminalScreenState` 40k cells = 11.7 ms vs 0.008 ms for a record
  assign; `ValidNormalizedFrame` 10k = 1.24 ms; the single hottest per-cell op
  anywhere is `ValidTerminalCell → TerminalGlyphIsDisplayable`, a strict UTF-8
  decode of **every glyph on every validation pass**.
- Cell records carry **managed glyph strings**, so every O(cells) pass allocates.
- **Force-full catch-up**: an endpoint one frame behind gets
  `NeedCurrentFrame → BuildEndpointFrameOffer(AForceFullRepaint=True)`
  (`st_session_desktop_actor.pas ~3143/~2727`) → full clip + diff vs an empty
  baseline + full-surface emission, *every time*. 29 of 42 projections took this
  path in a plain typing burst; a menu open emitted 36,692 B vs main's 2,441 B.
- Synchronous ACK round trips and fixed sleeps in bounded queues (ARCH-15A cut
  331.7 → 67.3 ms by adding a self-pipe wake — still ~4× main).

The lesson for Main+: **never build a dense semantic frame per update, and never
force a full repaint on a one-frame-behind client.** main already obeys both.

---

## 3. What `newsuperterm` inherits from main (verified map)

- **Process model.** Double fork + `setsid` between forks
  (`st_server.pas:8018-8271`); daemon reopens 0/1/2 on `/dev/null` (`:8218`).
- **Attach.** `FRAME_ATTACH` + `ATTACH_PROTO_VER=16` (`:168`) → `FRAME_SESSION`
  → one `FRAME_SCREEN` per pane → `FRAME_READY` (`:2489-2721`). Frame table
  `:21-87`.
- **Ownership.** Daemon: PTYs, canonical `TScreen` per pane, layout/geometry,
  focus, per-pane leases, scrollback, revision. Client: FV tree + a **mirror
  `TScreen` per pane** re-parsed from raw bytes (`st_fvui.pas:260-262`,
  `:10365`). Incremental updates are **raw PTY bytes** broadcast to all
  (`:7379-7392`) → the daemon plus every client each run a full VT parse (N+1).
- **Reactor.** `fpPoll` (`st_poll.pas:82`); all fds nonblocking; per-tick budgets
  `IO_BUDGET/FRAME_BUDGET/ACCEPT_BUDGET` (`:212-214`); per-client egress 8 MB /
  256 MB during snapshot (`:194,:219`); lag-drop (`:7736-7741`); optional pane
  worker threads (`:6990-7335`) with the socket reactor single-threaded.
- **Rendering.** FV → `VideoBuf`; per-cell rich overlay gated by the VideoBuf
  oracle `RichStands` (`st_video.pas:683`); `WideUpdateScreen` diff + single
  write; fullscreen passthrough (`UpdatePassthrough` `st_fvui.pas:8554`,
  `PassthroughRaw` `st_video.pas:141`).
- **Emulator.** `st_screen.pas` implements DECCKM/`?7`/`?25`, mouse
  `?9/1000/1002/1003` as a bitmask, `?1005/1006/1015/1016`, `?47/1047/1049` with
  its own save slot, SGR incl. truecolour + colon form, DECSTBM, DECSC/DECRC
  (restores rendition), scrollback ring (trimmed rows). Custom keyboard
  (`st_kbd.pas`) and mouse (`st_mouse.pas`, own gpm-avoiding driver) drivers.

---

## 4. main's real weaknesses (what "better than main" must fix)

Ranked by user-visible impact. Every item verified `file:line`.

**Performance**
- **W1 — Latency floor is a fixed ~100 Hz poll.** `TProgram.Idle` →
  `GiveUpTimeSlice` = unconditional 10 ms `fpnanosleep`
  (`vendor/fv322/drivers.pas:794-800`, `app.pas:847`), called first in
  `TSuperApp.Idle` (`st_fvui.pas:10304`); the remote socket is polled with
  timeout 0 and never wakes the loop (`st_server.pas:2775`); local mode adds an
  8 ms select / `Sleep(8)` (`st_fvui.pas:10613,:10645`); plus a 20 ms drain
  window (`:10348`) and 40 ms coalesce. Measured arrow/wheel/mouse "complete"
  p50 ≈ 130 ms (`a2-main.log`). **This is the biggest single win available and
  it is in *main's* renderer, not speedupx's.**
- **W2 — Full-screen scan + per-cell heap churn every frame.**
  `WideUpdateScreen` iterates every cell unconditionally (`st_video.pas:1222`);
  `PresentedVgaChar`/`Utf8VgaChar` return `AnsiString` (`:363,:274`);
  `AttrSequence`/`RichSGR` build SGR with `IntToStr` per changed cell
  (`:258,:583`); `Body := Body + …` reallocs per cell (`:1350,:1362,:1370`).
- **W3 — `TTermView.Draw` redraws the whole pane** (`st_fvui.pas:993`) with a
  `SafeGlyph` heap alloc per cell (`:784`), `Occluded` linear-in-windows per
  cell (`:1027`), `ClipboardCellMarked` ×5; `TArtDesktop.Draw` is
  O(area)×O(windows) twice (`:10855-10952`).
- **W4 — VT parser allocates a `RawByteString` per printed char**
  (`st_screen.pas:1134-1137`) and computes `CellWidth` twice (`:971`) — run once
  in the daemon and once per client.
- **W5 — Snapshot/broadcast overhead.** One `Stream.WriteBuffer` per 24-byte
  cell (`SaveScreenGrid` `:497-509`), ring modulo recomputed per cell (`:764`);
  `Broadcast` allocates one `RawByteString` per client per frame (`:4308`);
  workers stop/restart on every attach spinning on `Sleep(1)` (`:5079,:7280`).

**Correctness / fidelity**
- **W6 — Snapshot is lossy** (demonstrated bugs; plan DB F0-10..F0-13).
  `TScreen.SaveToStream` (`st_screen.pas:719-771`) omits `AttrFgRGB/AttrBgRGB`,
  `FSaveAttr/FSaveFgRGB/FSaveBgRGB`, `FAltSave*`, `FPColon`, `FPrivOther`,
  `FOscOverflow` → a second viewer loses active truecolour, DECRC rendition,
  alt-screen saved cursor/rendition, and any sequence split across the snapshot.
- **W7 — Four frozen parser defects** (speedupx `docs/ARCHITECTURE.md` §12.1,
  locked by `test/legacy_terminal_anomaly_test.py`, 33/33):
  ALT-RESIZE-HISTORY, PENDING-WRAP-CARRY, CELL-GLYPH-TRUNCATION (8-byte
  `TCell.Txt`), ERASE-COLOUR-APPROXIMATION (`BlankRow/EraseRange` drop exact
  RGB/256 background). Each needs a *separately approved* core-behaviour change
  with its own oracle update — never an incidental fix.
- **W8 — No terminal query answers.** `DoCSI` has no `c`/`n`/`$p` case and no
  `else` (`st_screen.pas:1311-1710`); DA/DSR/CPR/DECRQM/XTGETTCAP die silently.

**Robustness / security** (plan DB T-series, AUDIT-3x.md)
- **W9** — secret written on any line ending `password:` /`passphrase for … :`
  (`st_pty.pas:918-921`, T-05); nesting chain unvalidated (`st_server.pas`
  chain split, T-03); `sshpass` detect/exec path mismatch
  (`st_wclass.pas:506-518`, T-04); sidecar `created` rewritten on every change
  (`st_server.pas:7448`, T-07); no protocol/snapshot-corruption tests (T-08).

**UX / product** (README roadmap, plan DB)
- **W10** — no `attach --exclusive` (`st_cli.pas:1475-1499`); no reconnect/retry
  state on a lost daemon (README `:966`, T-11); 4096-column resize > 2 s
  (CHANGELOG `:795-802`, T-24); CLI minors (T-13..T-17); CP437 map (T-23);
  automated `top` test (T-25).

**Engineering hygiene**
- **W11** — no perf harness at all (`grep -r bench|PERF src test` empty); 28
  standing compiler Notes with no `-Se…` enforcement (`todo.md:19-26`); `TESTS`
  list vs `test/*_test.py` agree only by luck (94/94, unenforced); `stlib.py`
  silently swallows pyte parse errors (`:1111-1113`).

---

## 5. Improvements — how `newsuperterm` beats main

Ordered by value/risk. **Each item carries a measurement or oracle gate; nothing
lands without it.** Rule 5 applies: no visible behaviour change except where an
item is explicitly a behaviour change with its own approved oracle.

**I0 — Stand up the measurement first (prerequisite for all perf work).**
Port `src/st_perf.pas` (self-contained leaf: `SysUtils`+`st_debug`+`Linux`;
enum + 32-bucket histogram + avg/p50/p95/max/units, gated on `SUPERTERM_PERF=1`
+ `SUPERTERM_DEBUG`), redefining its stages for main's pipeline: PTY-read →
`st_screen` parse → `TTermView.Draw` → `WideUpdateScreen` diff → `WriteRaw`. Add
two `SuperTermPerfObserve` calls around the body of `WideUpdateScreen`
(`AUnits := changed_cells`) and around `WriteRaw`. Add a `perf_baseline`
harness modelled on `test/large_screen_test.py` driving 100×30 / 200×50 /
400×100 with `SUPERTERM_DEBUG_FULL=1` + `SUPERTERM_SYNC=1`, parsing the existing
per-frame line `video: update … changed_cells=%d of %d bytes=%d`
(`st_video.pas:1408`) and bracketing frames with the `?2026h/l` delimiters. This
is the T-24 "baseline before you optimise" guardrail. **Gate: reproducible
ms/update + bytes/frame table recorded in `docs/`.**

**I1 — Wake the client on socket readability (kills W1).** Replace the fixed
10 ms nanosleep idle with an event wait: in remote mode, block the idle in a
bounded `fpPoll`/`fpSelect` on the session socket fd (and PTY fds in local mode)
with a short cap (e.g. the blink/coalesce interval), waking immediately on
input. This is the same idea ARCH-15A proved on speedupx (self-pipe wake, 331 →
67 ms), applied to main's simpler loop. **Gate: I0 shows key-echo p50 drop with
no change to `drive_test`/`scrollback_test`/`multiclient_*` oracles; the drain
budget (`st_fvui.pas:10347`) and coalescing stay.**

**I2 — Cut per-cell allocation in the renderer (W2/W4).** Make
`PresentedVgaChar`/`Utf8VgaChar` write into a caller `ShortString`/buffer instead
of returning `AnsiString`; build SGR into a fixed buffer instead of `IntToStr`
concat; grow `Body` with a preallocated length + index instead of `+`. In
`st_screen.PutRawChar`, avoid the per-char `RawByteString`. **Gate: I0 shows
lower allocation/time at 400×100; byte-for-byte identical `WriteRaw` output
(diff the raw stream in a probe).**

**I3 — Dirty-row tracking (W2/W3), measurement-gated.** Only after I1/I2: track
changed rows so `WideUpdateScreen` and `RepaintPane` skip untouched rows instead
of scanning the whole surface. Keyed off `EffOld` (not `OldVideoBuf`). This is
the one thing main lacks that speedupx also lacks. **Gate: the external study's
own caution — land only if I0 proves it faster; must not regress the drag/flood
byte counts in CHANGELOG `:892-931`.**

**I4 — Answer terminal queries in `st_screen` (fixes W8).** **Port from
speedupx, cleanly.** Commits `12284af`, `2a8bca6`, `83dd22c`, `994e35b` touch
**only** `src/st_screen.pas` + `test/screen_replies_test.py` + `Makefile.in`
(verified via `git show --stat`): a bounded pending-answer queue on `TScreen`
plus DA1/DA2, DSR 5/CPR, DECRQM (truthful `0`/`2`) and XTGETTCAP replies (RGB
deliberately refused so ncurses does not switch `setaf` to packed RGB). Golden
bytes in `test/vtreplies.py` (`b6d0e78`, 7-bit C1, each entry citing the xterm
ctlseqs reference). **These sit in the clean pre-rearchitecture prefix (§6), so
they carry no `src/terminal/` dependency.** **Required companion — the reply
drain (a4b):** the prefix only *exposes* `PendingReplies`; nothing writes them
to the PTY. Port the two ~30-line drain sites — `speedupx:src/st_server.pas`
`DeliverPaneReply` (peek → `FPanes[].WriteStr` → acknowledge; PTY-owner only)
and `speedupx:src/st_fvui.pas` (guarded `if RemoteMode then Exit`, so a query
is answered once by the owner, not once per attached client) — this is plan DB
F1-07. **Gate: `screen_replies_test` green; F0-14 baseline (grid answers,
passthrough swallow) preserved.**

**I5 — Complete the snapshot (fixes W6).** Serialize `AttrFgRGB/AttrBgRGB`,
`FSaveAttr/FSaveFgRGB/FSaveBgRGB`, `FAltSave*`, `FPColon/FPrivOther/FOscOverflow`
in `SaveToStream`/`LoadFromStream`, with a snapshot-version bump that cleanly
rejects old snapshots (the lesson at `st_server.pas:128-133`). This is plan DB
T-22/F0-10..F0-13. **Gate: the pin-and-flip tests F0-10..F0-13 invert from
KNOWN-GAP to green; second viewer shows exact active RGB after attach.**

**I6 — Harden robustness/security (W9).** Fix the sshpass detect/exec path to
resolve one absolute binary (`st_wclass.pas`, T-04); tighten the no-sshpass
secret-echo window (T-05); validate the nesting chain charset/length before the
sidecar (T-03); preserve sidecar `created` (T-07); add protocol/snapshot
corruption tests (T-08). **Gate: each with the regression test named in its plan
DB criterio; full battery green ×2.**

**I7 — Product polish (W10).** `attach --exclusive`/`-x` (tmux `attach -d`
style, evicts other clients — the vr1 incident fix); reconnect/retry state +
resize-on-reattach (T-11); the CLI minors T-13..T-17; CP437 map extension
(T-23); the automated `top` suite (T-25, now unblocked by the pyte scrub, I8).
**Gate: new suites green; documented in README/CLI docs.**

**I8 — Engineering hygiene (W11), do this early.** Port verbatim (all
verified self-contained, main-value):
- `test/stlib.py` pyte scrub catalogue `_PYTE_SCRUB` + `feed_pyte/flush_pyte` +
  hold-back + `report()` failing on uncatalogued parse errors (`3882e58`;
  replaces the silent swallow at `stlib.py:1111-1113`; unblocks `top`).
- Reaping honesty `REAPED_ELSEWHERE`/`_mark_reaped` + `stlib_reaping_test.py`
  (`afb6d86`).
- Frozen wire-constant table + `wire_constants_test.py` (`ea500b4`; every value
  verified equal to `st_server.pas`; only `ATTACH_PROTO_VER` differs and is
  derived at runtime).
- `suite_manifest_test.py` (`80fea10`; cross-checks `TESTS` ↔ files — do this
  first so the list stops drifting).
- `docs/references/` corpus + `SHA256SUMS` + `README.md` (self-contained, 17
  licence files) and `index.md` **sections 5–9 only** (1/1.1/10 describe
  speedupx topology). *Flag: ECMA-48/ECMA-35 PDFs and `konsole-handbook.pdf`
  ship without a recorded licence — resolve provenance or keep as link-only per
  the corpus's own §8 rule before committing.*
- Staged strict build: `-Sew` first, re-count today's Notes on a real build
  (the "28" is from the obsolete `todo.md` and is unverified), fix or `-vm`-
  suppress each with a comment (precedent: `-vm11030,11031`), then `-Sen -Seh`
  (`fbd1824` did it in one token; main can't until the Notes are gone,
  including `vendor/fv322`'s). Replace `todo.md` with a real live list rather
  than deleting it.

**I9 — Real bug fixes and hardening from the clean prefix (`≤ 48ba4e0`), each
verified to touch a bounded file set.** Two of these are *bugs*, not polish:
- **`a2` — `st_mouse` owns the whole mouse backend (`46697f9`).** Fixes a real
  **startup hang**: the FPC RTL does a *blocking* `connect(/dev/gpmctl)` during
  `Drivers` unit init, before `main` runs, so gpm-installed-but-not-listening
  hangs superterm forever. Also gives a working mouse on alacritty/foot/wezterm/
  tmux-256color; non-blocking bounded connect; synthetic release on mid-drag
  transport loss. Touches `st_mouse.pas` + `st_video.pas` +
  `vendor/fv322/drivers.pas` (−75, deletes the darwin/tmux DECSET-to-Output
  guesswork) + `test/gpm_backend_test.py` (its own fake gpm — needs no gpm).
- **`a3` — panes speak one fixed contract; clients degrade locally (`eca5872`).**
  Fixes a real bug: main does `Add('TERM', getenv('TERM'))` (`st_pty.pas:287`),
  so the **first viewer permanently decides every pane's TERM** — attach once
  from a Linux console and every program in every pane is 16-colour forever.
  The fix forces `TERM=xterm-256color`+`COLORTERM=truecolor` into panes and
  degrades per-client at the last mile. ⚠ **Integration risk to resolve first:**
  this and `a1` pull in `st_hostcaps.pas` (`c340bdc`), whose
  `ResolveHostCapabilities` depends on `ResolveTerminalProfileStack` in
  `st_term_registry.pas` — which contains the very 256-colour inference
  (`st_term_registry.pas:279-313`, lifts to truecolor only when
  `IntermediaryCount = 0`) that partly explains speedupx's slow measurement.
  Decide: take a trimmed registry slice, or reimplement `st_hostcaps`'s
  facts→depth against a smaller table that does **not** cap at 256 for
  `xterm-256color`. This is the one real integration hazard in an otherwise
  clean prefix.
- **`a5` — `st_pty` env policy (`2b983a5`).** A window class could set
  `SUPERTERM`/`SUPERTERM_SESSION_CHAIN` and defeat nesting protection; now
  reserved names + NUL/LF/CR are refused with a reason. Pure, tested, 66 lines.
- Small, high-value hardening (hand-cherry, all main-applicable):
  **b1** `vendor/fv322/dialogs.pas` `E := Default(TEvent)` before a command
  event (stock FV left arms uninitialised — 2 lines); **b3** `st_ssh_server`
  i386/overflow guards (~20 lines); **b6** `st_progress.pas` backward-tick guard
  (main has bare `GetTickCount64 - X > Y` at `st_server.pas:7936,:7988`);
  **b4** `st_debug` FD_CLOEXEC on the log fd; **b5** `st_layout.ComputeRects`
  `out` open-array → named `TRectArray` (+`TLayout.CreateEmpty`); **b2**
  `st_pty` fork/exec hardening (reset signal dispositions in the child, CLOEXEC
  via fcntl, exec-status pipe, `SignalPaneProcessGroup`) — largest but classic
  POSIX correctness. Optionally **b10**'s two signal units
  (`st_thin_shutdown_posix`/`st_thin_resize_posix`: async-signal-safe
  self-pipes so a client unwinds through Pascal `finally` and a SIGWINCH burst
  cannot evict shutdown signals).
- Dead-code/comment cleanups `03cb94f`, `40c520f` (main-applicable as-is).

**Explicitly NOT ported** (tied to the failed pipeline or a coverage regression):
the ARCH worker/attach/presentation/codec/authority units and their ~46 suites;
the semantic-frame/normalized-frame path; the thin client; the CI macOS-matrix
removal (main builds and passes on macOS — removing it is pure regression); the
i386 cross recipe (near-zero ROI without the Pascal-probe suites); `eca5872`'s
"clients degrade a fixed contract locally" model (it reshapes `st_video`/
`st_fvui`/`superterm.lpr` around the new client-degradation design — against
Main+); and speedupx's chrome/worker fixes `5d982f7`/`a964afc` (they live in
`st_worker_fv_runtime.pas`/`st_fv_chrome.pas`/`st_session_desktop_actor.pas`,
which do not exist on main).

---

## 6. Sequencing

**Branch mechanics (the clean shortcut).** `git merge-base main speedupx` **is
`dbcc21f`, main's HEAD** — speedupx is a strictly linear 52-commit continuation.
The first **27** commits (`f18401b … 48ba4e0`) are *pre-rearchitecture*; the
pipeline starts at `51ad600` and never stops. So most of the port is not
archaeology: **`48ba4e0` is main + 27 clean commits containing none of
ARCH-01..15.** Base a `port` branch there (or cherry-pick that range), then
revert `ad14064` (it deletes the macOS CI matrix — a regression, do not keep).
That single move lands I4/a4, a2, a3, a5, I8's test+build hygiene and the
`docs/references/` corpus at once, with zero conflict. Everything from `51ad600`
onward is the failed pipeline and is hand-picked, not merged (b1–b10).

1. **I8 first** (hygiene + I0 perf harness): manifest check, pyte scrub, reaping,
   wire table, references, staged strict build, perf baseline recorded.
2. **I4 + I5** (query answers + full snapshot): the highest-fidelity wins, both
   low-coupling ports/edits with existing oracles.
3. **I1** (socket-wake): the biggest latency win; needs I0's numbers.
4. **I2**, then **I3** (renderer allocation, then dirty rows): both gated on I0.
5. **I6 + I7 + I9** (robustness, product polish, optional ports): independent,
   parallelisable, each with its named regression.
6. **W7 frozen defects**: only if/when German approves each as a separate
   core-behaviour change with its own oracle update — never incidentally.

Branch/process rules (from repo memory, unchanged): work on the designated
development branch, green `make test` ×2 before push, commits to German alone
with no AI attribution, English everywhere, "GNU/Linux" never bare "Linux",
`AGENTS.md`/`CLAUDE.md` stay in `.git/info/exclude` only.

---

## 7. Verification (end to end)

- **Build:** `make release test-runtime` (both binaries). Staged strict flag
  proven by a clean `-Sewnh` build once I8 completes.
- **Perf:** `SUPERTERM_PERF=1 SUPERTERM_DEBUG=… SUPERTERM_DEBUG_FULL=1
  SUPERTERM_SYNC=1` run of the `perf_baseline` harness at 100×30 / 200×50 /
  400×100, pinned with `taskset -c`, median of ≥3; compare ms/update and
  bytes/frame before/after each of I1/I2/I3 against the recorded baseline. The
  gross anti-catastrophe threshold (T-24) fails CI if a change regresses > ~2×.
- **Fidelity:** `screen_replies_test` (I4), the F0-10..F0-13 pin-and-flip
  suites (I5), `legacy_terminal_anomaly_test` stays 33/33 unless a W7 item is
  deliberately changed with its oracle.
- **Behaviour (Rule 5):** the existing suites that hold the drag/flood/boot byte
  budgets (CHANGELOG `:892-931`) must not regress; `passthrough_*`,
  `multiclient_*`, `drive`, `scrollback`, `cursor`, `exit_clean` green.
- **Robustness:** the new T-03/04/05/07/08 regressions green; `make test` full
  battery green ×2.

---

## 8. Critical files

- Renderer / latency: `src/st_video.pas` (`WideUpdateScreen` 1167,
  `PresentedVgaChar` 363, `RichSGR` 583, `COALESCE_MS` 473, per-frame log 1408),
  `src/st_fvui.pas` (`Idle` 10273, `TTermView.Draw` 993, `RepaintPane` 734),
  `vendor/fv322/app.pas:847` + `drivers.pas:794` (idle sleep),
  `src/st_server.pas:2775` (zero-timeout poll).
- Emulator / snapshot: `src/st_screen.pas` (`DoCSI` 1311-1710, `SaveToStream`
  719, `PutRawChar` 1123, `SaveScreenGrid` 497).
- Ports in: `src/st_perf.pas`, `test/vtreplies.py`, `test/screen_replies_test.py`,
  `test/stlib.py`, `test/suite_manifest_test.py`, `test/wire_constants_test.py`,
  `test/stlib_reaping_test.py`, `docs/references/`.
- Reference: `speedupx:docs/ARCHITECTURE.md` §12.1 (frozen defects) as the
  read-only spec for W7; `/home/german/superterm_plan.db` `hitos` F0/F1/T rows
  for the acceptance criteria of I4–I7.

---

*Evidence base:* three read-only explorers (main architecture; speedupx
slowness + portable pieces; build/test scaffolding), the plan DB
`/home/german/superterm_plan.db`, the four demonstrated-bug milestones and
`AUDIT-3x.md`, a prior session's measured latency audit (same host/probe), and
direct `git show --stat` / `git merge-base` verification of every proposed port.
Explicitly unverified and to confirm during execution: (1) whether main **alone**
builds clean under `-Sewnh` (the "28 Notes" figure is from the stale `todo.md`);
(2) the exact per-stage cost split on main — every perf claim here is read from
source, not yet measured, which is why I0 (the perf harness) is the first task;
(3) that `st_hostcaps`'s facts→depth resolution can be taken **without** the
`st_term_registry` 256-colour cap. Do not treat any of these as settled.
