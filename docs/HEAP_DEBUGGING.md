# Heap-instrumented debugging

SuperTerm has a second debug build for memory audits. It is deliberately
separate from the ordinary debug binary: HeapTrc changes the memory manager,
allocation sizes and timing, which can hide or expose a race. Use both builds
when investigating a problem rather than treating one as a replacement for
the other.

## Build

```sh
make debug-heap
```

This creates `bin/superterm-debug-heap`. It uses the ordinary debug options
(`-O1 -g -gl -dDEBUG -Crtoi`) and additionally passes:

- `-gh`, which installs Free Pascal's HeapTrc memory manager;
- `-dSUPERTERM_HEAPTRACE`, which lets SuperTerm give every process a distinct
  PID- and role-tagged HeapTrc output file.

The combined `-Crtoi` enables range, stack, overflow and I/O checks. The build
also keeps line information, enables SuperTerm's fatal-signal report and, like
the normal debug build, records full flow detail unless explicitly disabled.
A clean build prints no compiler warnings, notes or hints.

The instrumented target has its own unit directory,
`build/units/debug-heap`, so its units cannot be mixed with either release or
ordinary debug units.

## Recommended run

Create a private directory and supply both log prefixes:

```sh
mkdir -p /tmp/superterm-audit
SUPERTERM_DEBUG=/tmp/superterm-audit/flow.log \
SUPERTERM_DEBUG_FULL=1 \
SUPERTERM_HEAP_LOG=/tmp/superterm-audit/heap \
HEAPTRC='nohalt' \
bin/superterm-debug-heap
```

`SUPERTERM_HEAP_LOG` is a prefix, not one final filename. SuperTerm redirects
HeapTrc again whenever a process receives its role, including after the
session daemon is forked. A run therefore produces files such as:

```text
/tmp/superterm-audit/heap-client-24110.log
/tmp/superterm-audit/heap-daemon-24114.log
/tmp/superterm-audit/flow.log
```

This matters for a multi-client session: using HeapTrc's plain `log=` option
would make every inherited process write to the same file, allowing reports
from concurrent exits to interleave.

`HEAPTRC=nohalt` keeps the audit running after HeapTrc diagnoses a bad heap
operation, so the surrounding SuperTerm log can record more context. Remove
`nohalt` when the desired behavior is to stop at the first invalid heap
operation under a debugger.

## What each file contains

The flow log is a merged, timestamped stream from several processes. Every
line carries:

```text
time [pid role tid=thread-id] event
```

All processes open that file with `O_APPEND` (new files use mode `0600`) and
submit a complete log record in one operating-system write (with retry
handling of interruptions and short writes). This makes the merged trace
suitable for ordering analysis;
one process cannot silently recreate the file or splice its normal record
through another process's line.

With `SUPERTERM_DEBUG_FULL=1` it includes PTY reads, protocol frames, layout
revisions, focus changes, canonical sizes, painting, per-pane lock
acquisition/rejection/release, client attach/detach and daemon activity. PID,
role and thread ID let one correlate a client request with the daemon reactor
or pane-worker that handled it.

Every received client/control frame is logged twice around the daemon's one
global command FIFO:

```text
command-fifo: enqueue seq=412 origin=client slot=2 gen=9 kind=2 pane=0 ...
command-fifo: dequeue seq=412 origin=client slot=2 gen=9 kind=2 pane=0 valid=1 ...
```

Sequence numbers make reordering visible. `gen` prevents a queued command
from acting on a newly connected client that reused the same slot; such a
record is logged with `valid=0` and discarded. A normal action that remains
connected must dequeue with `valid=1`.

Each HeapTrc file is an allocation report for exactly one process. On orderly
termination it states the numbers and sizes of allocated/freed blocks and
lists unfreed blocks with allocation backtraces. HeapTrc also adds a tail to
allocations and diagnoses invalid frees and detected writes beyond a block.

The HeapTrc report is not a raw copy of the process address space. Fatal
signals are covered separately by SuperTerm's crash files:

```text
/tmp/superterm-crash-client-<pid>-<time>-<tag>.log
/tmp/superterm-crash-daemon-<pid>-<time>-<tag>.log
```

Those contain the signal, process identity, file/line backtrace and the last
400 flow-log entries kept in memory. A hard kill or fatal memory corruption may
prevent normal Pascal finalization, so in that case the crash report and flow
log are authoritative; a final HeapTrc summary is not guaranteed.

## Session-daemon lifetime

Detaching the last viewer intentionally leaves the session daemon alive, so
its HeapTrc report is not complete yet. To finalize the daemon and receive its
memory report, either:

- use **Exit** while it is the last attached client; or
- close the session administratively with `superterm-debug-heap kill NAME`.

Afterward, verify that the exact PID recorded in the sidecar has terminated,
then inspect the matching `heap-daemon-<pid>.log`. Socket/sidecar disappearance
alone is not a sufficient deadlock oracle. Merely closing a host terminal can
leave the daemon alive by design.

## Run a regression under HeapTrc

Python tests select the binary through `SUPERTERM_TEST_BIN`:

```sh
SUPERTERM_TEST_BIN="$PWD/bin/superterm-debug-heap" \
python3 test/multiclient_intensive_test.py
```

Private mode creates and later removes its own session under
`/tmp/opencode/st-multiclient-intensive`; it deliberately selects full flow
logging, a per-process heap prefix and `HEAPTRC=nohalt`. The exact `flow` and
`actions` paths are printed at startup.

The test records the daemon PID and every UI PID it creates: stable, churn,
replacement and post-reattach clients. After proven clean detach and orderly
daemon shutdown it requires every matching role/PID report. It also checks
every CLI report it discovers for a final summary, zero unfreed blocks and the
known HeapTrc corruption/accounting markers. The flow log is rejected on
runtime errors, every installed fatal signal, `*** FATAL`, caught daemon-loop
exceptions, `EAccessViolation`, `access violation` or `invalid pointer
operation`. These are concrete checks of the processes and paths exercised by
this run; they are not proof that no unexecuted path contains a leak or race.

The stress oracle makes the fourth, differently sized client prove its old
snapshot tokens and layout before live input starts, then includes that client
in live render and exact-cursor assertions. Geometry commands from the three
stable clients are released concurrently by a barrier while the fourth client
detaches; the test requires complete writes, non-empty and converged layouts,
an observable minimized/zoomed or changed-frame state, and a one-to-one,
monotonic enqueue/dequeue trace from the global command FIFO. Visible resize,
circle and F5 phases additionally require the exact target pane lock, exact
final geometry, canonical PTY markers and identical rendering in every client.
Pane and icon identity is title-keyed and preserves multiplicity, so a stale
duplicate drawing cannot disappear inside a set comparison. The oracle treats
a visible top edge separately from a complete frame because minimized icons
may legitimately cover a pane's bottom border; it nevertheless rejects
missing, duplicate and canonically impossible pane/icon states. Phase
boundaries are fail-fast and write exact screen/state diagnostics on a
convergence failure, preventing one bad action from producing a page of
misleading secondary failures.

The automatic heap check is enabled for the standard
`superterm-debug-heap` filename; set `SUPERTERM_EXPECT_HEAP=1` when testing an
instrumented binary with another name. External/live-session mode verifies
every automated client and CLI process it creates in a fresh log directory.
It deliberately leaves the watched daemon alive, so only that daemon's final
report is excluded. Do not interpret a still-running daemon's partial report
as a leak result.

To add the automated clients to an already running disposable session while
a person watches it, use external mode. It detaches only the clients it adds
and deliberately leaves that daemon alive, but it does rename the first three
panes and exercises their common geometry:

```sh
SUPERTERM_TEST_BIN="$PWD/bin/superterm-debug-heap" \
SUPERTERM_STRESS_SESSION=NAME \
SUPERTERM_STRESS_HOME="$HOME" \
SUPERTERM_STRESS_DAEMON_LOG=/tmp/superterm-audit/daemon-flow.log \
SUPERTERM_STRESS_ROUNDS=2 \
SUPERTERM_STRESS_LIVE_SECONDS=120 \
SUPERTERM_STRESS_VISIBLE_STEP_PAUSE=0.2 \
python3 test/multiclient_intensive_test.py
```

The watched session must contain exactly three panes. The test creates missing
panes before it starts, but rejects a session with extras rather than silently
testing only an arbitrary subset.

`SUPERTERM_STRESS_DAEMON_LOG` is optional. Set it only to the dedicated flow
log with which that existing daemon was started; then the test filters the
newly appended trace by the exact daemon PID and validates this run's FIFO.
Without it, external
mode reports that internal FIFO audit as `SKIP` rather than claiming a result
from client-only logs. Private mode always owns and audits the daemon log.

The seed is printed and written to `actions.log`; reproduce a failure with
`SUPERTERM_STRESS_SEED=0x...`. In external mode the existing daemon keeps the
debug/HeapTrc environment with which it was created, so start that session
with the instrumented binary and desired log paths before running the test.

## More aggressive HeapTrc modes

FPC's installed `heaptrc.pp` also accepts options in the `HEAPTRC` variable:

- `keepreleased` retains freed blocks to detect later writes into them. It can
  consume a very large amount of memory, so use it only for a short,
  reproducible case, not a long stress run.
- `tail_size=N` increases the overwrite-detection tail from its default size.
- `haltonnotreleased` makes remaining allocations a failing exit. Enable it
  only after ensuring every deliberately persistent process has been shut
  down and after establishing a clean baseline for RTL-owned allocations.
- `skipifnoleaks` suppresses empty summaries.

Example for a short write-after-free hunt:

```sh
SUPERTERM_HEAP_LOG=/tmp/superterm-audit/heap \
HEAPTRC='keepreleased tail_size=32' \
bin/superterm-debug-heap
```

The implementation follows the behavior in FPC 3.2.2's installed
`rtl/inc/heaptrc.pp`: `SetHeapTraceOutput` opens the selected report, HeapTrc
maintains thread-local allocation information and merges terminated-thread
information for the final dump.

## Comparing ordinary and heap debug

Use the ordinary build first for deadlocks and timing-sensitive races:

```sh
make debug
SUPERTERM_DEBUG=/tmp/superterm-audit/normal-flow.log \
SUPERTERM_DEBUG_FULL=1 \
bin/superterm-debug
```

Then repeat the same seed/action sequence with `superterm-debug-heap`.
Agreement between both runs is stronger evidence; disagreement is useful too,
because it points to timing or allocation-layout sensitivity.
