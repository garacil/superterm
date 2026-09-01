# Performance baseline

- binary: `/home/german/sources/claude/newsuperterm/bin/superterm-perf`
- samples per geometry: 12 (median reported)
- key echo is end-to-end: typed command to painted output.

| geometry | cells | key echo p50 ms | p95 ms | frames | changed cells/frame | bytes/frame |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100x30 | 3000 | 12.1 | 14.1 | 36 | 12 | 74 |
| 200x50 | 10000 | 12.9 | 15.3 | 36 | 12 | 76 |
| 400x100 | 40000 | 17.8 | 21.1 | 39 | 24 | 94 |

## Client frame stages (SUPERTERM_PERF)

| geometry | stage | count | avg us | p50 us | p95 us | max us | units |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100x30 | frame-compare | 5 | 120 | 128 | 256 | 214 | 169 |
| 100x30 | physical-write | 5 | 5 | 4 | 16 | 12 | 591 |
| 200x50 | frame-compare | 5 | 254 | 512 | 512 | 267 | 169 |
| 200x50 | physical-write | 5 | 5 | 4 | 16 | 9 | 591 |
| 400x100 | frame-compare | 8 | 2243 | 2048 | 4096 | 3620 | 171 |
| 400x100 | physical-write | 8 | 6 | 8 | 16 | 12 | 782 |

Percentiles from the histogram are upper bucket bounds (`p50_le_us`), so they read as "at or below".
