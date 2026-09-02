# Interleaved performance baseline

- samples per scenario: 50
- CPU affinity: pinned to CPU 0
- baseline: `/usr/local/bin/superterm`
- candidate: `/tmp/superterm-nsarch01-current.jp50tD/bin/superterm`

| scenario | geometry | variant | ok/n | min ms | p50 ms | p95 ms | max ms | bytes | changed cells | frames |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arrow_input | 200x50 | baseline | 50/50 | 12.21 | 14.89 | 21.85 | 23.04 | 7 | 0 | 1 |
| arrow_input | 200x50 | candidate | 50/50 | 4.13 | 15.08 | 21.26 | 21.38 | 7 | 0 | 1 |
| mouse_drag_input | 200x50 | baseline | 50/50 | 1.38 | 10.23 | 15.92 | 17.98 | 3746 | 241 | 3 |
| mouse_drag_input | 200x50 | candidate | 50/50 | 0.89 | 8.89 | 16.26 | 16.90 | 3746 | 241 | 3 |
| wheel_input | 200x50 | baseline | 50/50 | 0.89 | 8.63 | 11.45 | 12.25 | 552 | 90 | 2 |
| wheel_input | 200x50 | candidate | 50/50 | 2.85 | 8.62 | 12.84 | 13.61 | 552 | 91 | 2 |
