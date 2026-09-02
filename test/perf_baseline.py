#!/usr/bin/env python3
"""superterm performance baseline harness (not a pass/fail suite).

Deliberately NOT named *_test.py: it measures, it does not assert. The battery
must stay a behaviour contract, and a timing threshold in it would be a flake
generator on a loaded machine. The gross anti-regression threshold belongs to
whoever compares two runs of this table.

What it measures, per geometry:

  key echo ms   end-to-end: write one printf into the focused pane and wait
                for its OUTPUT to be painted. This is the number the whole
                Main+ decision rests on, so it is measured the same way for
                every geometry rather than derived from internal counters.
  update ms     the client's own frame stages, read back from the
                SUPERTERM_PERF lines (frame-compare and physical-write).
  cells/frame   changed cells per painted frame, from the FULL debug line.
  bytes/frame   bytes actually written to the terminal per painted frame.

The point of the last two is the Main+ claim itself: cost must follow CHANGED
CELLS, not desktop area. Run three geometries and watch whether bytes and time
stay flat while the area grows 13x.

Usage:  python3 test/perf_baseline.py [--out docs/baseline/performance.md]
Requires the telemetry binary: make perf. The release and test-runtime
binaries deliberately contain no instrumentation at all, so the stage table
is empty when this is pointed at them.
"""
import argparse
import os
import re
import select
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stlib  # noqa: E402

GEOMETRIES = ((100, 30), (200, 50), (400, 100))
SAMPLES = 12
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

UPDATE_RE = re.compile(
    r'video: update force=\d+ runs=(\d+) changed_cells=(\d+) of (\d+) '
    r'bytes=(\d+)')
PERF_RE = re.compile(
    r'perf: stage=(\S+) count=(\d+) avg_us=(\d+) p50_le_us=(\d+) '
    r'p95_le_us=(\d+) max_us=(\d+) units=(\d+)')


def key_echo_samples(client, n=SAMPLES):
    """ms from writing a command to seeing its OUTPUT painted."""
    out = []
    for i in range(n):
        marker = b'__P%02d__' % i
        # The echo of the typed line also contains the marker, so the output
        # is the SECOND occurrence. Counting one would time the local echo.
        cmd = b"printf '__P%02d" % i + b"__\\n'\r"
        buf = b''
        started = time.monotonic()
        os.write(client.fd, cmd)
        seen = None
        deadline = started + 5.0
        while time.monotonic() < deadline:
            r, _, _ = select.select([client.fd], [], [], 0.002)
            if not r:
                continue
            try:
                data = os.read(client.fd, 262144)
            except OSError:
                break
            if not data:
                break
            buf += data
            if buf.count(marker) >= 2:
                seen = time.monotonic()
                break
        if seen is not None:
            out.append((seen - started) * 1000.0)
        client.drain(0.25)
    return out


def parse_log(path):
    updates, stages = [], {}
    try:
        with open(path, encoding='utf-8', errors='replace') as handle:
            for line in handle:
                m = UPDATE_RE.search(line)
                if m:
                    updates.append({
                        'runs': int(m.group(1)),
                        'cells': int(m.group(2)),
                        'area': int(m.group(3)),
                        'bytes': int(m.group(4)),
                    })
                    continue
                m = PERF_RE.search(line)
                if m:
                    stages[m.group(1)] = {
                        'count': int(m.group(2)), 'avg_us': int(m.group(3)),
                        'p50_us': int(m.group(4)), 'p95_us': int(m.group(5)),
                        'max_us': int(m.group(6)), 'units': int(m.group(7)),
                    }
    except OSError:
        pass
    return updates, stages


def measure(w, h):
    home = stlib.fresh_home('perf-%dx%d' % (w, h))
    with open(os.path.join(home, '.superterm', 'superterm.ini'), 'w') as ini:
        ini.write('[ui]\nlanguage=en\nbackground=none\n'
                  'desktop_notifications=0\n'
                  '[session]\nserver=always\nautosave=0\nautorestore=0\n')
    log = os.path.join(home, 'perf.log')
    env = {'SUPERTERM_PERF': '1', 'SUPERTERM_DEBUG': log,
           'SUPERTERM_DEBUG_FULL': '1', 'SUPERTERM_SYNC': '1'}
    client = stlib.Client(home, w=w, h=h, lang='en', env=env)
    try:
        client.drain(3.0)
        samples = key_echo_samples(client)
        client.drain(0.5)
    finally:
        try:
            client.send(b'\x1bx', 1.0)
            client.close()
        except Exception:                          # noqa: BLE001
            pass
        stlib.close_all_daemons(home)
    updates, stages = parse_log(log)
    painted = [u for u in updates if u['bytes'] > 0]
    return {
        'w': w, 'h': h, 'area': w * h,
        'samples': samples,
        'echo_p50': statistics.median(samples) if samples else None,
        'echo_p95': (sorted(samples)[max(0, int(len(samples) * 0.95) - 1)]
                     if samples else None),
        'frames': len(painted),
        'cells': statistics.median([u['cells'] for u in painted])
        if painted else None,
        'bytes': statistics.median([u['bytes'] for u in painted])
        if painted else None,
        'stages': stages,
    }


def fmt(value, digits=1):
    return '-' if value is None else f'{value:.{digits}f}'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(
        ROOT, 'docs', 'baseline', 'performance.md'))
    args = ap.parse_args()

    perf_bin = os.environ.get(
        'SUPERTERM_PERF_BIN', os.path.join(ROOT, 'bin', 'superterm-perf'))
    if not os.path.exists(perf_bin):
        print(f'missing telemetry binary {perf_bin}; run make perf',
              file=sys.stderr)
        return 2
    stlib.BIN = perf_bin

    results = [measure(w, h) for w, h in GEOMETRIES]

    lines = []
    lines.append('# Performance baseline')
    lines.append('')
    lines.append(f'- binary: `{stlib.BIN}`')
    lines.append(f'- samples per geometry: {SAMPLES} (median reported)')
    lines.append('- key echo is end-to-end: typed command to painted output.')
    lines.append('')
    lines.append('| geometry | cells | key echo p50 ms | p95 ms | frames | '
                 'changed cells/frame | bytes/frame |')
    lines.append('| --- | ---: | ---: | ---: | ---: | ---: | ---: |')
    for r in results:
        lines.append(
            f"| {r['w']}x{r['h']} | {r['area']} | {fmt(r['echo_p50'])} | "
            f"{fmt(r['echo_p95'])} | {r['frames']} | {fmt(r['cells'], 0)} | "
            f"{fmt(r['bytes'], 0)} |")
    lines.append('')
    lines.append('## Client frame stages (SUPERTERM_PERF)')
    lines.append('')
    lines.append('| geometry | stage | count | avg us | p50 us | p95 us | '
                 'max us | units |')
    lines.append('| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |')
    for r in results:
        for name in sorted(r['stages']):
            s = r['stages'][name]
            lines.append(
                f"| {r['w']}x{r['h']} | {name} | {s['count']} | {s['avg_us']} "
                f"| {s['p50_us']} | {s['p95_us']} | {s['max_us']} | "
                f"{s['units']} |")
    lines.append('')
    lines.append('Percentiles from the histogram are upper bucket bounds '
                 '(`p50_le_us`), so they read as "at or below".')
    text = '\n'.join(lines) + '\n'

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as handle:
        handle.write(text)
    print(text)
    print(f'written: {args.out}')
    return 0


sys.exit(main())
