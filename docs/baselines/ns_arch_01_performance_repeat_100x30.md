# Interleaved performance baseline

- samples per scenario: 50
- CPU affinity: pinned to CPU 0
- baseline: `/usr/local/bin/superterm`
- candidate: `/tmp/superterm-nsarch01-current.jp50tD/bin/superterm`

| scenario | geometry | variant | ok/n | min ms | p50 ms | p95 ms | max ms | bytes | changed cells | frames |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| fullscreen_return | 100x30 | baseline | 50/50 | 12.31 | 18.87 | 30.29 | 30.56 | 3042 | 3000 | 1 |
| fullscreen_return | 100x30 | candidate | 50/50 | 12.50 | 21.00 | 29.83 | 30.94 | 3042 | 3000 | 1 |
| menu_open | 100x30 | baseline | 50/50 | 4.28 | 10.76 | 14.25 | 15.24 | 2478 | 549 | 3 |
| menu_open | 100x30 | candidate | 50/50 | 3.63 | 11.15 | 14.56 | 15.64 | 2478 | 549 | 3 |
| wheel_input | 100x30 | baseline | 50/50 | 0.50 | 3.71 | 10.41 | 10.71 | 384 | 64 | 2 |
| wheel_input | 100x30 | candidate | 50/50 | 0.54 | 2.90 | 10.72 | 11.15 | 384 | 65 | 2 |
