# Interleaved performance baseline

- samples per scenario: 50
- CPU affinity: pinned to CPU 0
- baseline: `/usr/local/bin/superterm`
- candidate: `/tmp/superterm-nsarch01-current.jp50tD/bin/superterm`

| scenario | geometry | variant | ok/n | min ms | p50 ms | p95 ms | max ms | bytes | changed cells | frames |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| key_echo | 400x100 | baseline | 50/50 | 24.27 | 31.01 | 46.51 | 94.28 | 258 | 62 | 2 |
| key_echo | 400x100 | candidate | 50/50 | 24.29 | 32.90 | 97.13 | 110.17 | 258 | 62 | 2 |
| mouse_click | 400x100 | baseline | 50/50 | 2.09 | 10.88 | 15.04 | 16.18 | 870 | 134 | 1 |
| mouse_click | 400x100 | candidate | 50/50 | 2.57 | 9.41 | 14.88 | 15.43 | 872 | 134 | 1 |
