# Performance baseline evidence

`test/performance_baseline.py` creates the JSON evidence and adjacent Markdown
summary in this directory. The raw artifact identifies both binaries by path,
SHA-256 and version, identifies the source commit and build flags, and retains
every interleaved sample rather than only aggregate statistics.

The accepted NS-ARCH-01 run must contain 50 successful warmed samples for both
the installed main reference and the isolated `newsuperterm` candidate across
all 17 scenarios and all three required geometries. A failed harness run is
kept under an explicit rejected name and recorded in the SQLite evidence
ledger; it is never renamed into accepted evidence.

Timing results are evidence, not loaded-host unit-test thresholds. A later
implementation slice is accepted only when two repeat runs show no regression
in p50, p95, desktop-area scaling, emitted bytes, or frame count, and all
behavioral tests remain green.
