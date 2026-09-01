# Performance baseline

- binary: `/home/german/sources/claude/newsuperterm/bin/superterm-perf`
- samples per geometry: 12 (median reported)
- key echo is end-to-end: typed command to painted output.

| geometry | cells | key echo p50 ms | p95 ms | frames | changed cells/frame | bytes/frame |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100x30 | 3000 | 6.0 | 6.6 | 153 | 1 | 57 |
| 200x50 | 10000 | 7.3 | 8.2 | 141 | 1 | 57 |
| 400x100 | 40000 | 10.6 | 10.7 | 140 | 1 | 59 |

## Client frame stages (SUPERTERM_PERF)

| geometry | stage | count | avg us | p50 us | p95 us | max us | units |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100x30 | frame-compare | 5 | 85 | 128 | 128 | 91 | 25 |
| 100x30 | fv-draw | 6 | 308 | 512 | 512 | 341 | 0 |
| 100x30 | physical-write | 6 | 4 | 4 | 8 | 7 | 272 |
| 100x30 | screen-parse | 5 | 2 | 2 | 4 | 4 | 602 |
| 200x50 | frame-compare | 14 | 231 | 256 | 256 | 247 | 112 |
| 200x50 | fv-draw | 14 | 858 | 1024 | 1024 | 888 | 0 |
| 200x50 | physical-write | 14 | 4 | 4 | 16 | 9 | 726 |
| 200x50 | screen-parse | 16 | 2 | 2 | 4 | 3 | 1410 |
| 400x100 | frame-compare | 2 | 1844 | 2048 | 2048 | 1885 | 2 |
| 400x100 | fv-draw | 2 | 3347 | 4096 | 4096 | 3349 | 0 |
| 400x100 | physical-write | 2 | 8 | 8 | 16 | 9 | 116 |
| 400x100 | screen-parse | 6 | 2 | 2 | 8 | 6 | 676 |

Percentiles from the histogram are upper bucket bounds (`p50_le_us`), so they read as "at or below".
