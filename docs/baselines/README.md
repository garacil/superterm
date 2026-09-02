# Performance baseline evidence

`test/performance_baseline.py` creates the JSON evidence and adjacent Markdown
summary in this directory. The raw artifact identifies both binaries by path,
SHA-256 and version, identifies the source commit and build flags, and retains
every interleaved sample rather than only aggregate statistics.

An accepted closure run must contain 50 successful warmed samples for both the
installed main reference and the isolated candidate across every selected
scenario and required geometry. Failed and experimental runs stay in `/tmp`
or another ignored workspace under explicit rejected names; they are never
renamed into accepted evidence or committed as project documentation.

Timing results are evidence, not loaded-host unit-test thresholds. A later
implementation slice is accepted only when two repeat runs show no regression
in p50, p95, desktop-area scaling, emitted bytes, or frame count, and all
behavioral tests remain green.
