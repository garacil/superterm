#!/usr/bin/env python3
"""superterm test: the permanent performance harness is complete and usable."""
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import performance_baseline as perf  # noqa: E402
from stlib import check, report  # noqa: E402


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
BINARY = os.environ.get('SUPERTERM_RELEASE_BIN',
                        os.path.join(ROOT, 'bin', 'superterm'))

check('closure sample floor is at least fifty', perf.DEFAULT_SAMPLES >= 50)
check('all three required geometries are frozen',
      perf.DEFAULT_GEOMETRIES == ((100, 30), (200, 50), (400, 100)))
required = {
    'key_echo', 'arrow_input', 'wheel_input', 'mouse_click',
    'mouse_drag_input', 'menu_open', 'dialog_open', 'content_drag',
    'wireframe_drag', 'resize', 'maximize_restore', 'fullscreen_return',
    'viewport_pan', 'bulk_input_output', 'attach_snapshot', 'reconnect',
    'fast_with_slow_client',
}
check('every required interaction scenario is frozen',
      set(perf.SCENARIOS) == required)
check('nearest-rank p95 is deterministic',
      perf.percentile(list(range(1, 101)), 0.95) == 95)
orders = [perf.interleaved_order(iteration) for iteration in range(50)]
check('state parity and variant order are independently balanced',
      orders[:4] == [
          ('baseline', 'candidate'), ('baseline', 'candidate'),
          ('candidate', 'baseline'), ('candidate', 'baseline'),
      ] and all(
          abs(sum(order.index(variant) == position
                  for iteration, order in enumerate(orders)
                  if iteration % 2 == parity) - 12.5) <= 0.5
          for variant in ('baseline', 'candidate')
          for position in (0, 1)
          for parity in (0, 1)))
check('closure samples balance independent process creation order',
      perf.measurement_batches(50) == (25, 25))
batch_balance = {}
for batch, batch_samples in enumerate(perf.measurement_batches(50)):
    for action_iteration in range(batch_samples):
        order = perf.interleaved_order(action_iteration)
        if batch:
            order = tuple(reversed(order))
        for position, variant in enumerate(order):
            key = (variant, action_iteration % 2, position)
            batch_balance[key] = batch_balance.get(key, 0) + 1
check('both action parities balance positions across process batches',
      len(batch_balance) == 8 and
      sorted(batch_balance.values()) == [12] * 4 + [13] * 4)

with tempfile.TemporaryDirectory(prefix='superterm-perf-smoke-') as root:
    output = os.path.join(root, 'smoke.json')
    completed = subprocess.run([
        sys.executable, os.path.join(ROOT, 'test', 'performance_baseline.py'),
        '--baseline', BINARY, '--candidate', BINARY, '--samples', '1',
        '--smoke', '--geometry', '100x30', '--scenario', 'key_echo',
        '--output', output,
    ], cwd=ROOT, capture_output=True, text=True, timeout=45)
    check('one-sample real harness smoke run succeeds', completed.returncode == 0)
    if completed.returncode != 0:
        print(completed.stdout)
        print(completed.stderr)
    try:
        with open(output, encoding='utf-8') as handle:
            payload = json.load(handle)
    except (OSError, ValueError):
        payload = {}
    check('raw result schema is versioned', payload.get('schema') == 1)
    samples = payload.get('samples', [])
    check('smoke run preserves both interleaved raw samples',
          len(samples) == 2 and
          {sample.get('variant') for sample in samples} ==
          {'baseline', 'candidate'})
    check('raw samples carry latency, bytes, cells, and frames',
          bool(samples) and all(
              {'latency_ms', 'bytes', 'changed_cells', 'frames', 'batch',
               'action_iteration'} <= set(sample)
              for sample in samples))
    check('summary carries minimum, p50, p95, and maximum',
          bool(payload.get('summary')) and all(
              {'minimum_ms', 'p50_ms', 'p95_ms', 'maximum_ms'} <= set(row)
              for row in payload['summary']))

report()
