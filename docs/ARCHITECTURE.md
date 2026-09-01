# SuperTerm architecture

Normative. If code or another document contradicts this one, this one wins —
or this one is wrong and gets corrected. Every structural claim below cites the
source that implements it, because a document that cannot be checked stops
being normative the first time someone doubts it.

This is **not** the architecture document of the `speedupx` branch. That branch
describes a different design, which this project measured and rejected; §7 says
why, with numbers.

---

## 1. The shape of the system

```text
pane processes (PTYs)
      |
      v
session daemon                one per session, authoritative
  ├─ owns the PTYs, the canonical TScreen per pane, layout,
  │  focus, pane leases, scrollback and the revision counter
  └─ multiplexes: broadcasts each pane's RAW BYTES to every viewer
      |
      v
client process                one per attached terminal
  ├─ one persistent Free Vision view tree, built once and kept
  ├─ its own TScreen mirror per pane, fed the same raw bytes
  └─ draws into the video buffer
      |
      v
st_video flush                compares against the last presented cells,
                              emits only changed cells as runs,
                              in ONE buffered write
      |
      v
physical terminal
```

The daemon is a **byte multiplexer**, not a renderer. It never composes a
picture and never produces a per-client frame. `HandlePaneOutput`
(`src/st_server.pas:7379`) forwards what the PTY produced with
`Broadcast(Kind, APane, Data[0], Length(Data), ...)` — the pane's own bytes,
unchanged.

The consequence is deliberate and worth stating plainly: the daemon and **every
attached client each run their own VT parse** of the same stream. That is N+1
parses for N viewers. It is accepted because a parse is cheap and per-byte,
whereas composing a picture per client is expensive and per-area (§7).

**Ownership.** Daemon: PTYs, canonical `TScreen`s, layout tree and geometry,
focus, per-pane leases, scrollback, revision. Client: its Free Vision tree
(`Panes`/`Scr`/`Win`, `src/st_fvui.pas:261`), the physical terminal, its local
viewport, copy mode and clipboard.

---

## 2. Invariants

These are the rules a change is measured against. Breaking one is not a
trade-off to be argued in a commit message; it is a separate, explicitly
approved decision.

1. The daemon owns PTYs, canonical terminal state, layout, focus, ordering,
   persistence, revisions and bounded nonblocking transport.
2. Every attached client owns **one persistent Free Vision tree** and uses the
   existing `st_video` changed-cell diff. No client rebuilds its tree per frame.
3. Normal rendering cost follows **changed bytes and cells**, never total
   desktop area.
4. Full snapshots happen only on initial attach, explicit refresh, physical
   resize, raw-mode return, or proven desynchronization.
5. Preserve the emission machinery: changed-cell runs, cursor and SGR reuse,
   the deliberately ignored Free Vision forced repaint, one buffered write per
   frame, and input-aware coalescing.
6. Preserve visible truth: direct RGB, indexed colour, exact solid black,
   menus, dialogs, scrollbars and trough panning, drag behaviour. Any intended
   visible change is a separate approved change, never a side effect.
7. A slow client may lose **only its own connection**. It never stalls a pane
   or another viewer.
8. Replaceable state may be coalesced. One-shot effects — bells, clipboard
   operations, terminal replies — may not.
9. Encrypted TCP access is provided by OpenSSH. No OpenSSL dependency, no
   bespoke encrypted transport.
10. `main`, `speedupx`, their stashes and any installed binary are **read-only
    references**: consult them for what the user must see, never for how to
    shape ownership, threading or transport here.

---

## 3. Output path

Free Vision draws into the video buffer as usual. The flush is
`WideUpdateScreen` (`src/st_video.pas:1178`), and it is where this project's
performance lives:

- **One write per frame.** Everything accumulates into a body string and leaves
  in a single `WriteRaw(Frame)` (`src/st_video.pas:1437`).
- **A cell diff, not a repaint.** The comparison is against `EffOld`, an array
  of resolved effective cells (`src/st_video.pas:500`) — the rich pane overlay
  and the chrome after resolution, not the raw VGA buffer.
- **Free Vision's forced repaint is ignored on purpose.** `TGroup.ReDraw` asks
  for an unconditional update; honouring it resent every cell on every mouse
  move. The flag survives only in a debug line (`src/st_video.pas:1447`).
- **Input-aware coalescing.** If more input is already queued the frame is
  skipped, bounded by `COALESCE_MS = 40` (`src/st_video.pas:484`) so continuous
  input still presents at ~25 fps.
- **The rich overlay carries colour.** A pane cell is emitted with its true
  colour when its oracle still stands in the video buffer (`RichStands`,
  `src/st_video.pas:694`); otherwise the cell falls back to chrome. This is how
  truecolour survives overlapping windows without patching Free Vision.
- **Fullscreen passthrough.** When one pane owns the whole terminal and the
  geometry matches exactly, its bytes go straight out and the renderer stands
  down (`UpdatePassthrough`, `src/st_fvui.pas:8554`).

**Colour is never downgraded from `TERM`.** The client emits truecolour
unconditionally; the only host probe is for encoding, not colour. Any future
capability work must preserve this.

### Known cost, measured

`WideUpdateScreen` scans the whole surface every frame. Measured with
`make perf` (see `docs/baseline/`): 120 µs at 100x30, 254 µs at 200x50,
2 243 µs at 400x100 — roughly 19x for 13x the area — while bytes per frame stay
flat. Removing that scan is milestone NS05-I3 (damage tracking); the larger
latency term today is the fixed idle sleep (§5), which is NS05-I1.

---

## 4. Input path

A custom keyboard driver decodes stdin itself (`src/st_kbd.pas`), because the
RTL driver treats a lone ESC as an Alt prefix and blocks; `ESC_TIMEOUT_MS = 50`
(`src/st_kbd.pas:47`) and the CSI/SS3 decoders live there, with bracketed paste
captured whole. The mouse has its own driver (`src/st_mouse.pas`) registered
before `Drivers`, and it enables exactly `?1000 ?1002 ?1006`
(`src/st_mouse.pas:137`) — any-motion tracking is deliberately not among them,
because the RTL event queue is small and Free Vision drains one event per loop,
so a pointer sweep would overflow it for nothing.

Keys, paste and synthesized mouse reports funnel to one place and are sent to
the daemon as input frames; the daemon writes them to the pane's PTY.

---

## 5. Scheduling and latency

The client loop is Free Vision's: `TProgram.Idle` ends in `GiveUpTimeSlice`
(`vendor/fv322/app.pas:847`, `vendor/fv322/drivers.pas:785`), which is an
unconditional 10 ms sleep, and `TSuperApp.Idle` (`src/st_fvui.pas:10273`) runs
on top of it. Socket readability does not wake the loop today. Together with
the bounded socket drain (32 frames, `src/st_fvui.pas:10351`) and the 40 ms
coalescing window, that is the dominant term in key-to-paint latency —
measured 12-18 ms end to end. Replacing it with an event-driven wake is
NS05-I1 and is the single largest improvement available.

---

## 6. Transport, backpressure and failure isolation

The daemon is a single bounded `fpPoll` reactor (`src/st_poll.pas:93`). Every
descriptor is nonblocking. Per tick it spends at most `IO_BUDGET` bytes and
`FRAME_BUDGET` frames (`src/st_server.pas:212-213`), with
`POLL_TICK_MS = 100` (`src/st_server.pas:215`) as the idle quantum.

Backpressure is **read-gating plus lag-drop**, not flow control: a client is
only polled for reading while it is under budget (`src/st_server.pas:7780`),
its egress queue is bounded (`MAX_EGRESS`, raised to `MAX_SNAPSHOT_EGRESS`
while a snapshot drains, `src/st_server.pas:194,219`), and a client that has
made no progress past the grace period is dropped
(`src/st_server.pas:197-198,7736`). PTYs are always drained; a stalled viewer
loses its own connection and nothing else (invariant 7).

Optional per-pane reactor threads exist (`TPanePollWorker`,
`src/st_server.pas:689`, configured by `multithread`), but the socket reactor
stays single-threaded: worker results are handed back and broadcast from the
one loop, so ordering is preserved.

The attach handshake is versioned (`ATTACH_PROTO_VER = 16`,
`src/st_server.pas:168`) and a mismatch is refused with a message. A snapshot
is the session frame, one screen frame per pane (`TScreen.SaveToStream`,
`src/st_screen.pas:719`), then ready.

**Known gap.** That snapshot is lossy: the active RGB, the saved-cursor
rendition, the alternate-screen saved slots and several parser flags are not
serialized, so a second viewer can lose exact colour. Milestone NS04-I5.

---

## 7. What this architecture is not, and why

The `speedupx` branch moved parsing, composition and rendering into the daemon
and produced a dense semantic frame per client per update. It is a coherent
design and it is **rejected here on measurement**, not taste:

| geometry | this architecture | speedupx |
| --- | ---: | ---: |
| 100x30 | 15.4 ms | 21.4 ms |
| 200x50 | 18.1 ms | 38.6 ms |
| 400x100 | 23.6 ms | 108.5 ms |

Its cost grew with desktop **area** because its cell became a managed record
with heap-allocated glyph and hyperlink strings, so each update paid several
full-grid validations, clones and comparisons, plus a forced full repaint
whenever an endpoint fell one frame behind.

Therefore, permanently:

- No server-side frame realization, normalized frames or dense semantic frames.
- No per-endpoint projection, compositor or delivery thread.
- No thin client: the client keeps its own Free Vision tree.
- No cell type carrying managed strings on the hot path.
- Never force a full repaint because a viewer is one frame behind.

`test/architecture_boundary_test.py` enforces this mechanically: it fails if any
of 28 rejected units appears in `src/`, if `src/` stops being flat, if any
`uses` clause imports one, or if the macOS CI jobs disappear. The boundary is
checked, not merely written down here.

---

## 8. Quality gates

A change is accepted only if all of these hold.

**Behaviour (Rule 5).** The archived battery in `docs/baseline/` is the
reference. Its expectations are never edited to accommodate a change. A new
failure, or a different failing check inside a known-failing suite, is a
regression. The six currently failing suites are open work, not accepted
failures, and are listed with proof that they predate this work.

**Performance.** Never make it worse. Reject a slice when, on two repeat runs,
p50 or p95 exceeds the recorded baseline by more than `max(1 ms, 5%)`; or when
bytes per frame grow without a required new effect; or when scaling with
desktop area worsens. Where a measurement cannot resolve the question — noise
larger than the effect — do not argue from it: remove the doubt structurally.
The telemetry itself is the worked example: it lives in a separate `make perf`
binary and the release `.text` section is provably identical without it.

**Build.** `-Sewnh` makes any compiler diagnostic fatal, in every mode.

**Evidence.** Read the sources, the vendored Free Vision, the installed FPC RTL
and `docs/references/` before acting; validate with a concrete check or a
minimal reproducer; state what was observed and what remains unverified. A
guess is a blocker to investigate, never a fact to encode.

**Frozen parser defects.** Four known `TScreen` defects — alternate-screen
resize history, pending-wrap carry, cell glyph truncation and the erase/scroll
colour approximation — are preserved on purpose so that ownership and transport
work cannot silently change what users see. Correcting one is a separate,
explicitly approved change with its own regression and a deliberate update of
every affected visible oracle.

---

## 9. Where the milestones live

The executable plan is `newsuperterm_plan.db` (SQLite) in the repository root:
phases, tasks, dependencies, acceptance criteria and current state. This
document says what the architecture *is*; that database says what is being done
about it and how far it has got. `newsuperterm_v2.md` carries the reasoning and
the evidence behind both.
