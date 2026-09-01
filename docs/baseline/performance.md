# Performance baseline

- binary: `/home/german/sources/claude/newsuperterm/bin/superterm-test`
- samples per geometry: 12 (median reported)
- key echo is end-to-end: typed command to painted output.

| geometry | cells | key echo p50 ms | p95 ms | frames | changed cells/frame | bytes/frame |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100x30 | 3000 | 13.3 | 15.7 | 47 | 24 | 94 |
| 200x50 | 10000 | 15.4 | 16.8 | 46 | 24 | 94 |
| 400x100 | 40000 | 17.1 | 20.7 | 43 | 24 | 94 |

## Client frame stages (SUPERTERM_PERF)

| geometry | stage | count | avg us | p50 us | p95 us | max us | units |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100x30 | frame-compare | 10 | 191 | 256 | 512 | 459 | 226 |
| 100x30 | physical-write | 10 | 6 | 4 | 16 | 12 | 970 |
| 200x50 | frame-compare | 10 | 330 | 512 | 1024 | 529 | 201 |
| 200x50 | physical-write | 10 | 4 | 4 | 8 | 7 | 919 |
| 400x100 | frame-compare | 7 | 1797 | 2048 | 2048 | 1828 | 170 |
| 400x100 | physical-write | 7 | 8 | 8 | 16 | 15 | 710 |

Percentiles from the histogram are upper bucket bounds (`p50_le_us`), so they read as "at or below".
