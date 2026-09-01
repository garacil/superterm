# newsuperterm_v2.md — consolidated Main+ work plan

> **MILESTONE DATABASE — `newsuperterm_plan.db` (SQLite, in this directory).**
> The milestones, their detail, their order and the live implementation status
> reside **in that database, not in this document**. It is the authoritative
> tracker: after every slice, update `estado`, `evidencia` and `actualizado` on
> the affected `hitos` row before starting the next milestone, and record the
> failure chronology honestly — never close a milestone by reclassifying,
> skipping or hiding a failure. Update the affected English documentation in the
> same slice. This document is the narrative rationale and the verified evidence
> behind those milestones; the database is the live state.
> Structure: `fases` (6 phases, `NS-ARCH-01`..`NS-ARCH-06`, pasos 16-21) ·
> `hitos` (22 tasks, each with `descripcion`, `criterios_aceptacion`,
> `ficheros`, `riesgo`, `evidencia`) · `dependencias` (31 edges — the real
> order) · `meta` (architecture, invariants, gates, base commit, golden rule) ·
> view `desbloqueados` (what may start right now).
> Start here: `sqlite3 newsuperterm_plan.db "SELECT * FROM desbloqueados;"`
>
> Single source of truth for `newsuperterm`. It merges the two prior planning
> artifacts — `newsuperterm.md` (detailed weaknesses + improvement catalogue,
> committed on branch `newsupertermc`) and `newsuperterm_codex.md` (invariants,
> SQLite milestones, acceptance thresholds) — losing nothing from either.
> Working copy: `/home/german/sources/claude/newsuperterm`, branch
> `newsupertermc` (off `main` `dbcc21f`). Every claim is cited `file:line`
> against the checked-out tree; unverified items are marked. Golden rule:
> evidence before action — read the SuperTerm source, the vendored FreeVision
> (`vendor/fv322`), the installed FPC RTL and `docs/references/`, then validate
> with a concrete check, before implementing anything.

---

## 1. Decision and measured baseline

Build `newsuperterm` as **"Main+"**: keep `main`'s architecture, port only the
discrete speedupx pieces that do not depend on its pipeline, then close main's
own verified weaknesses — each behind a measurement or oracle gate.

```text
PTYs -> authoritative daemon -> incremental raw bytes / ordered events
                                   |
                                   v
                     persistent per-client Free Vision tree
                                   |
                                   v
                  st_video changed-cell diff -> one buffered write
                                   |
                                   v
                            physical terminal
```

Measured, same host, same probe (key -> painted echo):

| Geometry | newsuperterm/main | speedupx |
| --- | ---: | ---: |
| 100x30 (3k cells) | 15.4 ms | 21.4 ms |
| 200x50 (10k) | 16.1-18.1 ms | 33-38.6 ms |
| 400x100 (40k) | 21.1-23.6 ms | 91-108.5 ms |

speedupx is ~4.6x slower at 400x100 and its cost grows with desktop **area**;
its own suite is red (85 pass / 71 fail, `speedupx:docs/references/index.md`
S10) and a full run is ~71 min (over main's 45-min CI budget). **Root cause,
verified in speedupx source:** its cell became a managed record
(`TTerminalCell.Glyph/Hyperlink: RawByteString`, `st_term_types.pas:164-176`),
so each update pays >=4 full-grid validations + 2 copies + 2 diffs
(`CloneTerminalScreenState` 40k = 11.7 ms vs 0.008 ms for a record assign),
plus force-full catch-up on a one-frame-behind endpoint
(`st_session_desktop_actor.pas ~3143/~2727`), ACK-depth-1 round trips and
25/40 ms coalesce caps. main pays one POD compare. **Lesson: never build a
dense semantic frame per update, and never force a full repaint on a
one-frame-behind client.**

### 1.1 Corrections to the study and prior plans — verified claims (complete)

Every claim in the external "Main+" study and in the two prior planning files was
checked against the checked-out tree. This is the full correction table; nothing
here is memory or assumption.

| Claim (study / prior plans) | Verdict and evidence (`file:line`) |
| --- | --- |
| One buffered write per frame, input-aware coalescing, ignores FV's forced repaint | **TRUE.** `WideUpdateScreen` `st_video.pas:1167`; single `WriteRaw(Frame)` `:1404`; `COALESCE_MS=40` `:473`, gate `:1198`; `Force` used only in a debug line `:1409` (rationale `:1329-1334`, measured 802/1639 frames, 9.9 MB of 10.2 MB over SSH). |
| The renderer diff is against `OldVideoBuf` | **FALSE.** The delta is against `EffOld: array of TEffCell` (`:489`, `EffEqual` `:1335`); `OldVideoBuf` is only blindly `Move`'d at `:1405` — vestigial. Dirty-tracking work (I3) must key off `EffOld`, not `OldVideoBuf`. |
| The persistent FV tree is at `st_fvui.pas:725` | **Claim true, line wrong.** 725 is a comment; the persistent per-client tree is `Panes/Scr/Win` at `src/st_fvui.pas:260-262`. |
| main infers a 256-colour cap from `TERM=xterm-256color` | **FALSE — main never does.** The client emits truecolour unconditionally (`RichSGR` `st_video.pas:583`); `COLORTERM` appears only where the daemon *sets* it for pane children (`st_pty.pas:290`). Nothing to fix on main — only to preserve; and never introduce such a cap when porting `st_hostcaps` (see the integration hazard, a3). |
| main has `FLOW_STOP` flow control | **Does not exist** (grep-verified). Backpressure is read-gating (`st_server.pas:7778-7786`) + lag-drop (`:7734-7741`); a slow client loses only its own connection. |
| main already has `attach --exclusive` | **Does not exist** (`st_cli.pas:1475-1499`). It is a task to add (W10 / I7). Exclusivity today is only a protocol property: a `< 16`-byte `FRAME_ATTACH` payload is treated as legacy/exclusive (`st_server.pas:5022-5027`). |
| `attach --session NAME` is an attach flag | **Does not exist as an attach flag.** `--session NAME` is a *startup* flag only. |
| `resize_policy` is a config key | **Does not exist.** Only a reserved protocol slot documented at `st_server.pas:134`. |
| main "stays flat" with desktop area | **TRUE outcome, nuanced cause.** Cells are fixed-size records so the diff is a cheap compare — but that pass is still O(desktop area) every frame (`st_video.pas:1222-1225`). Flat only because the per-cell constant is tiny; dirty-region tracking (I3) removes even this. |
| FRAME_SCREEN cell is 24 bytes | **CONFIRMED.** `TCell` `st_screen.pas:50-59` (`Txt[0..7]`, `Len`, `Attr:word`, `Cont`, `FgRGB`, `BgRGB`); comment `st_server.pas:107-108`. |
| speedupx does not cap colour from `TERM` | **FALSE — it does.** `st_term_registry.pas:279-313` caps `xterm-256color` at 256 unless `IntermediaryCount = 0`, and this gates the ARCH-14 raw fast path (`st_hostcaps.pas:849-855`, `st_term_adapter.pas:93-96`) — so its slow measurement ran on the non-raw semantic path. Do **not** inherit this cap when porting `st_hostcaps`. |
| The frame-number-table commit is `ea49684` | **Correction: it is `ea500b4`.** `ea49684` is an ARCH commit ("Make session readiness event driven") and is **not** portable. |
| `5d982f7` / `a964afc` are portable chrome/drag fixes | **NOT portable.** They live in new-architecture units (`st_worker_fv_runtime.pas`, `st_fv_chrome.pas`, `st_session_desktop_actor.pas`); `5d982f7` touches no `vendor/fv322` at all. |
| `origin/main` is ahead of `dbcc21f` by real code | **No — media only, VERIFIED.** The 7 intervening commits (`f18401b..b55220d`) are the front-page fireworks video: `docs/video.*`, `README.md`, two `screenshots/` files; zero code or tests. `dbcc21f` is code-identical to `origin/main`. |

---

## 2. Architectural invariants (must hold for every slice)

- The daemon owns PTYs, canonical terminal state, layout, focus, ordering,
  persistence, revisions and bounded nonblocking transport.
- Every attached client owns **one persistent Free Vision tree** and uses the
  existing `st_video` framebuffer diff (`src/st_fvui.pas:260-262`,
  `src/st_video.pas:1167`).
- Normal rendering cost follows changed **bytes and cells**, never total
  desktop area.
- Full snapshots are permitted only for initial attach, explicit refresh,
  physical resize, raw-mode return, or proven desynchronization.
- Preserve: changed-cell runs, cursor/SGR reuse, the ignored FreeVision force
  repaint (`st_video.pas:1409`, rationale `:1329-1334`), one-write presentation
  (`:1404`), input-aware coalescing (`COALESCE_MS=40`, `:473/:1198`).
- Preserve visible truth: direct RGB (`RichSGR` `st_video.pas:583`, emitted
  unconditionally — never downgrade from `TERM`), indexed colours, exact solid
  black, menus, dialogs, scrollbars/trough panning, drag behaviour, and every
  existing visible expectation (Rule 5).
- A slow client may lose only its own connection (lag-drop
  `st_server.pas:7736-7741`; read-gating `:7778-7786`).
- State may be coalesced; bells, clipboard operations, terminal replies and
  other one-shot effects may **not**.
- Encrypted TCP access uses OpenSSH/sshd. Add no OpenSSL dependency and no
  custom encrypted transport.
- `main`, `speedupx`, their stashes and the installed `/usr/local/bin/superterm`
  remain **read-only references** (A/B comparison and visible-behaviour oracle
  only — never a blueprint for ownership/threading/transport shape).

---

## 3. Verified map of main (what newsuperterm inherits)

- **Process:** double fork + `setsid` between forks (`st_server.pas:8018-8271`),
  daemon reopens 0/1/2 on `/dev/null` (`:8218`).
- **Attach:** `FRAME_ATTACH` + `ATTACH_PROTO_VER=16` (`:168`) -> `FRAME_SESSION`
  -> one `FRAME_SCREEN` per pane (`TScreen.SaveToStream` `st_screen.pas:719`) ->
  `FRAME_READY` (`:2489-2721`). Frame table `:21-87`.
- **Ownership:** daemon owns PTYs, canonical `TScreen`s, layout, focus, leases,
  scrollback, revision; client owns FV tree + a mirror `TScreen` per pane
  re-parsed from raw bytes. Incremental = raw PTY bytes broadcast (`:7379-7392`)
  -> daemon and every client each run a full VT parse (N+1).
- **Reactor:** `fpPoll` (`st_poll.pas:82`), all fds nonblocking, budgets
  `IO/FRAME/ACCEPT` (`:212-214`), `POLL_TICK_MS=100` (`:215`), egress 8 MB / 256
  MB during snapshot (`:194,:219`), optional pane worker threads (`:6990-7335`,
  socket reactor single-threaded).
- **Render:** FV -> `VideoBuf`; per-cell rich overlay gated by the VideoBuf
  oracle `RichStands` (`st_video.pas:683`); diff + single write; fullscreen
  passthrough (`UpdatePassthrough` `st_fvui.pas:8554`, `PassthroughRaw`
  `st_video.pas:141`).
- **Emulator:** `st_screen.pas` implements DECCKM/`?7`/`?25`, mouse
  `?9/1000/1002/1003` bitmask, `?1005/1006/1015/1016`, `?47/1047/1049` with own
  save slot, SGR incl. truecolour + colon form, DECSTBM, DECSC/DECRC (restores
  rendition), scrollback ring (trimmed rows). Custom keyboard `st_kbd.pas`,
  gpm-avoiding mouse `st_mouse.pas`.

---

## 4. main's weaknesses to fix (verified, ranked)

**Performance**
- **W1** Latency floor is a fixed ~100 Hz poll: 10 ms `fpnanosleep` in
  `GiveUpTimeSlice` (`vendor/fv322/drivers.pas:794-800`, `app.pas:847`), called
  first in `TSuperApp.Idle` (`st_fvui.pas:10304`); remote socket polled with
  timeout 0, never wakes the loop (`st_server.pas:2775`); local adds 8 ms
  select/`Sleep(8)` (`st_fvui.pas:10613,:10645`); + 20 ms drain (`:10348`) + 40
  ms coalesce. Measured arrow/wheel/mouse "complete" p50 ~130 ms.
- **W2** Full-screen scan every frame (`WideUpdateScreen` `st_video.pas:1222`);
  per-cell heap churn: `PresentedVgaChar`/`Utf8VgaChar` return AnsiString
  (`:363,:274`); `AttrSequence`/`RichSGR` `IntToStr` per changed cell
  (`:258,:583`); `Body := Body + ...` reallocs (`:1350,:1362,:1370`).
- **W3** `TTermView.Draw` redraws the whole pane (`st_fvui.pas:993`):
  `SafeGlyph` heap alloc per cell (`:784`), `Occluded` linear-in-windows per
  cell (`:1027`), `ClipboardCellMarked` x5; `TArtDesktop.Draw` O(area)xO(windows)
  twice (`:10855-10952`).
- **W4** VT parser allocates a RawByteString per printed char
  (`st_screen.pas:1134-1137`), computes `CellWidth` twice (`:971`).
- **W5** Snapshot/broadcast: one `Stream.WriteBuffer` per 24-byte cell
  (`SaveScreenGrid` `:497-509`), ring modulo per cell (`:764`); `Broadcast`
  allocates a RawByteString per client per frame (`:4308`); workers stop/start
  on every attach spinning on `Sleep(1)` (`:5079,:7280`).

**Correctness / fidelity**
- **W6** Lossy snapshot (`SaveToStream` `st_screen.pas:719-771` omits
  `AttrFgRGB/AttrBgRGB`, `FSaveAttr/FSaveFgRGB/FSaveBgRGB`, `FAltSave*`,
  `FPColon`, `FPrivOther`, `FOscOverflow`): second viewer loses active
  truecolour, DECRC rendition, alt-screen saved state, mid-sequence parser
  state. Plan DB F0-10..F0-13.
- **W7** Four frozen parser defects (spec: `speedupx:docs/ARCHITECTURE.md` S12.1;
  lock `test/legacy_terminal_anomaly_test.py`): ALT-RESIZE-HISTORY,
  PENDING-WRAP-CARRY, CELL-GLYPH-TRUNCATION (8-byte `TCell.Txt`),
  ERASE-COLOUR-APPROXIMATION. Each is a separately approved behaviour change with
  its own oracle update.
- **W8** No terminal query answers: `DoCSI` has no `c`/`n`/`$p` case, no `else`
  (`st_screen.pas:1311-1710`); DA/DSR/CPR/DECRQM/XTGETTCAP die silently.

**Robustness / security** (plan DB T-series, AUDIT-3x.md)
- **W9** secret echoed on any line ending `password:` / `passphrase for ... :`
  (`st_pty.pas:918-921`, T-05); nesting chain unvalidated (T-03); sshpass
  detect/exec mismatch (`st_wclass.pas:506-518`, T-04); sidecar `created`
  rewritten (`st_server.pas:7448`, T-07); no protocol/snapshot corruption tests
  (T-08). Plus the remaining still-applicable AUDIT-3x findings (CLI parsing,
  startup identity, nonblocking framing, capture bounds, descriptor reuse,
  daemon cleanup, profile-failure atomicity).

**UX / product**
- **W10** no `attach --exclusive` (`st_cli.pas:1475-1499`); no reconnect/retry
  state on lost daemon (T-11); 4096-column resize > 2 s (CHANGELOG `:795-802`,
  T-24); CLI minors (T-13..T-17); CP437 map (T-23); no automated `top` test
  (T-25).

**Engineering**
- **W11** no perf harness (`grep bench|PERF` empty); 28 standing Notes, no
  `-Se...`; `TESTS` vs files agree by luck (94/94, unenforced); `stlib`
  swallows pyte parse errors (`:1111-1113`).

---

## 5. Milestones (SQLite `hitos_arch`, executable order)

When implementation is authorized: in `/home/german/superterm_plan.db`, mark
`ARCH-15`, `ARCH-15B`, `ARCH-15C` as `superseded` (each naming its NS-ARCH
replacement); leave completed historical rows, including `ARCH-15A`, unchanged;
add these pending rows. For each milestone: read the relevant SuperTerm,
vendored FreeVision, installed FPC, tests, references and SQLite first; preserve
original expectations; write a **new normative `docs/ARCHITECTURE.md`**
describing the actual Main+ topology (do **not** copy speedupx's); update all
affected English documentation and SQLite; run the full gate (S8); then commit
and push `newsuperterm` before starting the next milestone.

| Code | paso | Title | Covers |
| --- | ---: | --- | --- |
| `NS-ARCH-01` | 16 | Freeze main-derived behaviour and performance | I8 hygiene + I0 baseline; W11 |
| `NS-ARCH-02` | 17 | Codify the Main+ architecture and quality gates | new `docs/ARCHITECTURE.md`, invariants (S2), port mechanics (S7), acceptance gates (S8) |
| `NS-ARCH-03` | 18 | Harden daemon, CLI, lifecycle, bounded transport | I6; W9; reconnect (T-11) |
| `NS-ARCH-04` | 19 | Complete terminal semantics and endpoint diagnostics | I4 + a4b drain + passthrough query filter + `--terminal-info`; I5 snapshot; a2/a3/a5; W6/W7/W8 |
| `NS-ARCH-05` | 20 | Optimize the damage path without visible changes | I1/I2/I3, measured only; W1-W5 |
| `NS-ARCH-06` | 21 | Cross-endpoint parity, soak, release closure | final acceptance; mixed truecolor/256; SSH; 10-min soak |

---

## 6. The parts to make (improvement catalogue)

Each item names its milestone and its gate. Nothing lands without the gate.

**I0 (NS-ARCH-01) - Measurement first.** Port `src/st_perf.pas` (self-contained
leaf: `SysUtils`+`st_debug`+`Linux`; enum + 32-bucket histogram +
avg/p50/p95/max/units; gated on `SUPERTERM_PERF=1` + `SUPERTERM_DEBUG`; disabled
path is one cached atomic test). Redefine stages for main's pipeline: input
admission -> PTY read -> `st_screen` parse -> `TTermView.Draw` ->
`WideUpdateScreen` diff -> `WriteRaw` (native preparation / socket delivery /
physical presentation). Add two `SuperTermPerfObserve` calls around
`WideUpdateScreen` (`AUnits := changed_cells`) and `WriteRaw`. Add a
`perf_baseline` harness modelled on `test/large_screen_test.py`, driving 100x30
/ 200x50 / 400x100 with `SUPERTERM_DEBUG_FULL=1` + `SUPERTERM_SYNC=1`, parsing
the per-frame line `video: update ... changed_cells=%d of %d bytes=%d`
(`st_video.pas:1408`) bracketed by `?2026h/l`. **Gate: reproducible ms/update +
bytes/frame table recorded in `docs/`.**

**I8 (NS-ARCH-01) - Hygiene, do first.** Port verbatim (all verified
self-contained): `test/stlib.py` pyte scrub `_PYTE_SCRUB` + `feed_pyte/flush_pyte`
+ hold-back + `report()` failing on uncatalogued parse errors (`3882e58`;
replaces the silent swallow, unblocks `top`); reaping honesty
`REAPED_ELSEWHERE`/`_mark_reaped` + `stlib_reaping_test.py` (`afb6d86`); frozen
wire-constant table + `wire_constants_test.py` (`ea500b4`, values verified equal
to `st_server.pas`); `suite_manifest_test.py` (`80fea10`, do this first so the
list stops drifting); `docs/references/` corpus + `SHA256SUMS` + `README.md`
(sections 5-9 of `index.md` only). Flag: ECMA-48/ECMA-35 PDFs and
`konsole-handbook.pdf` ship without a recorded licence - resolve provenance or
keep link-only. Staged strict build: `-Sew` first, re-count today's Notes on a
real build (the "28" is from the stale `todo.md`), fix or `-vm`-suppress each
with a comment, then `-Sen -Seh`. Replace `todo.md` with a live list, don't
delete it. Archive a clean pre-change baseline of all 94 suites (skips,
environment, binary identity, timing, frame bytes, descriptors).

**I4 (NS-ARCH-04) - Answer terminal queries (fixes W8), clean port.** Commits
`12284af`,`2a8bca6`,`83dd22c`,`994e35b` touch only `src/st_screen.pas` +
`test/screen_replies_test.py` + `Makefile.in` (verified `git show --stat`): a
bounded pending-answer queue on `TScreen` + DA1/DA2, DSR 5/CPR, DECRQM (truthful
`0`/`2`), XTGETTCAP (RGB deliberately refused so ncurses keeps `setaf`). Golden
bytes in `test/vtreplies.py` (`b6d0e78`). These sit in the clean prefix (S7), no
`src/terminal/` dependency. **Companion a4b (required to be observable):** port
the two ~30-line drain sites - `speedupx:src/st_server.pas` `DeliverPaneReply`
(peek -> `FPanes[].WriteStr` -> acknowledge; **PTY owner only**) and
`speedupx:src/st_fvui.pas` (guarded `if RemoteMode then Exit`, so a query is
answered once, not once per attached client). Land the complete persistent
passthrough query filter in the same atomic slice. **Gate: `screen_replies_test`
green; F0-14 baseline (grid answers, passthrough swallow) preserved.**

**I4b (NS-ARCH-04) - `--terminal-info` diagnostics.** Side-effect-free endpoint
capability dump; must not change any rendering decision.

**I5 (NS-ARCH-04) - Complete the snapshot (fixes W6).** Serialize
`AttrFgRGB/AttrBgRGB`, `FSaveAttr/FSaveFgRGB/FSaveBgRGB`, `FAltSave*`,
`FPColon/FPrivOther/FOscOverflow` in `SaveToStream`/`LoadFromStream`, with a
snapshot-version bump that cleanly rejects old snapshots (lesson at
`st_server.pas:128-133`). Plan DB T-22/F0-10..F0-13. **Gate: F0-10..F0-13
pin-and-flip suites invert from KNOWN-GAP to green; second viewer shows exact
active RGB after attach.**

**a2/a3/a5 (NS-ARCH-04) - real bug fixes from the clean prefix.**
- **a2** `st_mouse` owns the whole backend (`46697f9`): fixes a **startup hang**
  (RTL does a blocking `connect(/dev/gpmctl)` during `Drivers` init, before
  `main`); gives a mouse on more terminals; own fake gpm test. Touches
  `st_mouse.pas`+`st_video.pas`+`vendor/fv322/drivers.pas`(-75)+test.
- **a3** panes speak one fixed contract; clients degrade locally (`eca5872`):
  fixes that `Add('TERM', getenv('TERM'))` (`st_pty.pas:287`) lets the **first
  viewer permanently decide every pane's TERM** (attach from a Linux console ->
  every pane 16-colour forever). Force `TERM=xterm-256color`+`COLORTERM=truecolor`
  into panes; degrade per-client at the last mile; **never** use that TERM value
  to downgrade direct RGB. **Integration hazard to resolve first:** a3/a1 pull
  in `st_hostcaps.pas` (`c340bdc`) whose `ResolveHostCapabilities` depends on
  `ResolveTerminalProfileStack` in `st_term_registry.pas` - which carries the
  256-colour cap (`st_term_registry.pas:279-313`, lifts to truecolor only when
  `IntermediaryCount = 0`). Take a trimmed registry slice, or reimplement the
  facts->depth without capping `xterm-256color`. This is the one real
  integration risk in an otherwise clean prefix.
- **a5** `st_pty` env policy (`2b983a5`): a class could set
  `SUPERTERM`/`SUPERTERM_SESSION_CHAIN` and defeat nesting protection; reserved
  names + NUL/LF/CR refused with a reason. 66 lines, tested.

**W7 (NS-ARCH-04) - four parser anomalies as explicit behaviour changes.** Only
if/when German approves each individually: alternate-screen resize history,
pending-wrap restoration, glyph truncation, exact erase/scroll colours - each
with its dedicated regression and a deliberate update of every affected visible
oracle. Never incidental.

**I1 (NS-ARCH-05) - wake the client on socket readability (kills W1).** Replace
the fixed 10 ms nanosleep idle with a bounded `fpPoll`/`fpSelect` on the session
socket fd (and PTY fds locally), capped at the blink/coalesce interval, waking
immediately on input (the idea ARCH-15A proved on speedupx: 331 -> 67 ms).
**Gate: I0 shows key-echo p50 drop; drain budget and coalescing unchanged;
`drive`/`scrollback`/`multiclient_*` oracles unchanged.**

**I2 (NS-ARCH-05) - cut per-cell allocation (W2/W4).** Write
`PresentedVgaChar`/`Utf8VgaChar` into a caller buffer; build SGR into a fixed
buffer; grow `Body` with preallocated length + index; avoid the per-char
RawByteString in `PutRawChar`. **Gate: I0 shows lower alloc/time at 400x100;
byte-for-byte identical `WriteRaw` output (diff the raw stream in a probe).**

**I3 (NS-ARCH-05) - dirty-row/damage tracking (W2/W3), measured only.** After
I1/I2: fast raw-row comparison plus explicit rich-cell/outline dirty spans
(including wide-cell neighbours); evaluate only their union while keeping full
invalidation as the correctness fallback. Keyed off `EffOld` (`st_video.pas:489`,
`EffEqual` `:1335`) - never the vestigial `OldVideoBuf` (`:1405`). **Gate: land
only if I0 proves it faster; must not regress the drag/flood/boot byte budgets
in CHANGELOG `:892-931`.**

**I6 (NS-ARCH-03) - robustness/security (W9).** Resolve one absolute sshpass
binary (T-04); tighten the no-sshpass secret-echo window (T-05); validate the
nesting chain charset/length before the sidecar (T-03); preserve sidecar
`created` (T-07); add protocol/snapshot corruption tests (T-08). Resolve every
still-applicable AUDIT-3x finding **with a failing regression test first**.
**Gate: each with the regression named in its plan DB criterio; battery green
x2.**

**I7 (NS-ARCH-03/06) - product polish (W10).** `attach --exclusive`/`-x` (tmux
`attach -d` style - the vr1 incident fix); reconnect/retry state +
resize-on-reattach (T-11); CLI minors (T-13..T-17); CP437 map (T-23); automated
`top` suite (T-25, unblocked by the I8 pyte scrub). **Gate: new suites green;
documented in README/CLI.**

**Small hardening (NS-ARCH-03, hand-cherry from beyond the clean prefix).**
`b1` `vendor/fv322/dialogs.pas` `E := Default(TEvent)` before a command event
(2 lines, stock FV left arms uninitialised); `b3` `st_ssh_server` i386/overflow
guards (~20 lines); `b6` `st_progress.pas` backward-tick guard (main has bare
`GetTickCount64 - X > Y` at `st_server.pas:7936,:7988`); `b4` `st_debug`
FD_CLOEXEC on the log fd; `b5` `st_layout.ComputeRects` `out` open-array ->
named `TRectArray` (+`TLayout.CreateEmpty`); `b2` `st_pty` fork/exec hardening
(reset child signal dispositions, CLOEXEC via fcntl, exec-status pipe,
`SignalPaneProcessGroup`). Optionally `b10`'s two signal units
(`st_thin_shutdown_posix`/`st_thin_resize_posix`: async-signal-safe self-pipes).
Dead-code/comment cleanups `03cb94f`, `40c520f`.

---

## 7. Branch and port mechanics

`git merge-base main speedupx` **is `dbcc21f`, main's HEAD**; speedupx is a
linear 52-commit continuation. Its first 27 commits (`f18401b..48ba4e0`) are
pre-rearchitecture; the pipeline starts at `51ad600` and never stops. So
`48ba4e0` is main + 27 clean commits with none of ARCH-01..15 - base a `port`
branch there (or cherry-pick the range) to land I4/a4, a2, a3, a5, the I8 test +
build hygiene and `docs/references/` at once, conflict-free. Then revert
`ad14064` (it deletes the macOS CI matrix - a regression; **do not keep it**).
Everything from `51ad600` on is the failed pipeline; the small fixes b1..b10 are
hand-picked. Note: `origin/main` already contains the **first 7** of those media
commits (`f18401b..b55220d`, front-page fireworks video only - verified
docs/media, no code), so it is code-identical to `dbcc21f`.

**Do not import** (tied to the failed pipeline / a coverage regression): the
worker/attach/presentation/codec/authority units and their ~46 suites; the
dense normalized-frame path; per-endpoint semantic projection; delivery threads;
the thin client; the dead `st_term_wire` codec; replicated menu/dialog
implementations; the CI macOS-matrix removal; the i386 cross recipe; `eca5872`'s
client-degradation model reshaping `st_video`/`st_fvui`/`superterm.lpr`;
speedupx's chrome/worker fixes `5d982f7`/`a964afc` (units absent on main). Add no
server-side frame realization.

---

## 8. Test and acceptance plan (the gate)

- **Baseline:** clean pre-change run of all 94 original suites; archive skips,
  environment, binary identity, timing, frame bytes, terminal descriptors.
- **Benchmark:** at 100x30 / 200x50 / 400x100 with >=50 interleaved warmed
  samples each for: key echo, menu opening, content drag, wireframe drag, bulk
  pane output, resize, and fullscreen round trips. Pin with `taskset -c`, median
  of >=2 repeat runs.
- **Endpoints:** both the local Unix-domain route and real OpenSSH, with
  simultaneous truecolor and 256-colour clients attached.
- **Reject a slice** when, on two repeat runs, p50 or p95 exceeds the matching
  baseline by more than `max(1 ms, 5%)`; or native frame bytes increase without
  a required new effect; or scaling with desktop area worsens.
- **Preserve:** keep the 94 original expectations unchanged; add focused tests
  for every imported behaviour or defect. `legacy_terminal_anomaly_test` stays
  33/33 unless a W7 item is deliberately changed with its oracle. The
  drag/flood/boot byte budgets (CHANGELOG `:892-931`) must not regress.
- **Verify visibly:** menus, seven-button profile management, scrollbars and
  trough panning, direct RGB, exact black, drag-content on/off, maximize/restore,
  double-click zoom, detach, reconnect, forced peer loss, terminal restoration.
- **Fidelity gates:** `screen_replies_test` (I4); F0-10..F0-13 pin-and-flip (I5);
  the new T-03/04/05/07/08 regressions (I6).
- **Final closure (NS-ARCH-06):** strict release/debug/test builds; two
  consecutive complete green runs; two mixed-profile clients; real SSH; a
  ten-minute interaction/resize/output soak; and no leaked daemon, child,
  descriptor, socket or terminal mode.

---

## 9. Critical files

- Renderer / latency: `src/st_video.pas` (`WideUpdateScreen` 1167,
  `PresentedVgaChar` 363, `RichSGR` 583, `COALESCE_MS` 473, per-frame log 1408),
  `src/st_fvui.pas` (`Idle` 10273, `TTermView.Draw` 993, `RepaintPane` 734),
  `vendor/fv322/app.pas:847` + `drivers.pas:794`, `src/st_server.pas:2775`.
- Emulator / snapshot: `src/st_screen.pas` (`DoCSI` 1311-1710, `SaveToStream`
  719, `PutRawChar` 1123, `SaveScreenGrid` 497).
- Ports in: `src/st_perf.pas`, `test/vtreplies.py`,
  `test/screen_replies_test.py`, `test/stlib.py`, `test/suite_manifest_test.py`,
  `test/wire_constants_test.py`, `test/stlib_reaping_test.py`,
  `docs/references/`.
- Reference specs: `speedupx:docs/ARCHITECTURE.md` S12.1 (frozen defects, W7);
  `/home/german/superterm_plan.db` `hitos` F0/F1/T rows (acceptance criteria for
  I4-I7).

---

## 10. Assumptions and unverified items

- `newsuperterm` at `dbcc21f` has the same executable and test source as current
  `origin/main`; the 7 intervening upstream commits are **documentation/media
  only - VERIFIED** (`docs/video.*`, `README.md`, two `screenshots/` files; no
  code or tests).
- Performance parity with main plus improved correctness and robustness is
  sufficient; speed improvements are accepted only when measured.
- Client-local persistent rendering is the selected production architecture.
- The installed main binary remains untouched for A/B comparison.
- **To confirm during execution:** (1) whether main **alone** builds clean under
  `-Sewnh` (the "28 Notes" figure is stale); (2) the exact per-stage cost split
  on main (every perf claim here is read from source, not yet measured - I0 is
  the first task); (3) that `st_hostcaps`'s facts->depth resolution can be taken
  **without** the `st_term_registry` 256-colour cap.
- This plan supersedes `newsuperterm.md` (v1) and `newsuperterm_codex.md`. Both
  originals were local planning artifacts; per repo hygiene, planning artifacts
  are normally kept out of git - they are versioned here only at German's
  explicit instruction, on `newsupertermc`.
