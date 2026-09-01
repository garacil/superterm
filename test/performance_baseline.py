#!/usr/bin/env python3
"""Interleaved SuperTerm behavior/performance baseline harness.

This is deliberately not an ``*_test.py`` suite: timings are evidence, not a
loaded-host pass/fail threshold. ``performance_harness_test.py`` validates its
schema and one real smoke run. A closure baseline uses at least 50 warmed
samples and preserves every raw sample in JSON.
"""
import argparse
import fcntl
import hashlib
import json
import math
import os
import select
import signal
import statistics
import struct
import subprocess
import sys
import termios
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stlib  # noqa: E402


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
DEFAULT_GEOMETRIES = ((100, 30), (200, 50), (400, 100))
DEFAULT_SAMPLES = 50
SYNC_END = b'\x1b[?2026l'
SCENARIOS = (
    'key_echo', 'arrow_input', 'wheel_input', 'mouse_click',
    'mouse_drag_input', 'menu_open', 'dialog_open', 'content_drag',
    'wireframe_drag', 'resize', 'maximize_restore', 'fullscreen_return',
    'viewport_pan', 'bulk_input_output', 'attach_snapshot', 'reconnect',
    'fast_with_slow_client',
)


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def interleaved_order(iteration):
    """Balance order independently of an action's even/odd state."""
    if (iteration // 2) % 2 == 0:
        return 'baseline', 'candidate'
    return 'candidate', 'baseline'


def measurement_batches(samples):
    """Split closure samples so each binary is created first equally often."""
    if samples < 2:
        return (samples,)
    first = samples // 2
    return first, samples - first


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def binary_identity(path):
    absolute = os.path.abspath(path)
    version = ''
    try:
        completed = subprocess.run(
            [absolute, '--version'], capture_output=True, text=True,
            timeout=5)
        version = (completed.stdout + completed.stderr).strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return {'path': absolute, 'sha256': sha256(absolute), 'version': version}


def screen_cells(client):
    return tuple(tuple(client.screen.buffer[y][x] for x in range(client.w))
                 for y in range(client.h))


def changed_cells(before, after):
    height = max(len(before), len(after))
    changed = 0
    for y in range(height):
        before_row = before[y] if y < len(before) else ()
        after_row = after[y] if y < len(after) else ()
        width = max(len(before_row), len(after_row))
        for x in range(width):
            left = before_row[x] if x < len(before_row) else None
            right = after_row[x] if x < len(after_row) else None
            changed += left != right
    return changed


def read_once(client, timeout):
    timeout = max(0.0, timeout)
    try:
        readable, _, _ = select.select([client.fd], [], [], timeout)
    except (InterruptedError, OSError):
        return b''
    if not readable:
        return b''
    try:
        data = os.read(client.fd, 262144)
    except OSError:
        return b''
    if not data:
        return b''
    dsr_prefix = client._raw[-3:]
    client._raw += data
    for _query in range((dsr_prefix + data).count(b'\x1b[6n')):
        row, col = client.dsr
        try:
            os.write(client.fd, f'\x1b[{row};{col}R'.encode())
        except OSError:
            break
    stlib.feed_pyte(client.stream, data, 'performance harness')
    return data


def quiesce(client, quiet=0.04, ceiling=1.5):
    deadline = time.monotonic() + ceiling
    last = time.monotonic()
    while time.monotonic() < deadline:
        data = read_once(client, 0.004)
        if data:
            last = time.monotonic()
        elif time.monotonic() - last >= quiet:
            break
    stlib.flush_pyte(client.stream, 'performance quiescence')


def measure_action(client, trigger, completion=None, timeout=5.0,
                   quiet=0.025):
    quiesce(client)
    before = screen_cells(client)
    raw_start = len(client._raw)
    started = time.monotonic_ns()
    trigger()
    first_ns = None
    last_data_ns = started
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = read_once(client, 0.002)
        now_ns = time.monotonic_ns()
        raw = client._raw[raw_start:]
        if data:
            last_data_ns = now_ns
        complete = (completion(client, raw) if completion is not None
                    else (SYNC_END in raw or bool(raw)))
        if complete and first_ns is None:
            first_ns = now_ns
        if (first_ns is not None and not data and
                (now_ns - last_data_ns) / 1_000_000_000 >= quiet):
            break
    stlib.flush_pyte(client.stream, 'performance action')
    raw = client._raw[raw_start:]
    after = screen_cells(client)
    frames = raw.count(SYNC_END)
    if raw and frames == 0:
        frames = 1                 # an intentional direct presentation
    return {
        'success': first_ns is not None,
        'latency_ms': ((first_ns - started) / 1_000_000
                       if first_ns is not None else None),
        'settled_ms': ((last_data_ns - started) / 1_000_000
                       if first_ns is not None else None),
        'bytes': len(raw),
        'frames': frames,
        'changed_cells': changed_cells(before, after),
    }


def write_input(client, data):
    stlib.write_all(client.fd, data)


def unmeasured_input(client, data, settle=0.12):
    write_input(client, data)
    # The released daemon may legitimately service this input on its next
    # 100 ms tick. A quiet interval before that tick is not settled output.
    deadline = time.monotonic() + settle
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        read_once(client, min(0.01, remaining))
    quiesce(client, quiet=0.04, ceiling=max(0.5, settle + 0.5))


def wait_raw(client, marker, timeout=5.0):
    start = len(client._raw)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        read_once(client, 0.004)
        if marker in client._raw[start:]:
            quiesce(client)
            return True
    return False


def mouse(code, x, y, motion=False, release=False):
    if motion:
        code += 32
    suffix = 'm' if release else 'M'
    return f'\x1b[<{code};{x + 1};{y + 1}{suffix}'.encode()


def frame_rects(client):
    rows = client.screen.display
    rectangles = []
    for top, row in enumerate(rows):
        for left, char in enumerate(row):
            if char not in ('╔', '┌'):
                continue
            right_chars = ('╗', '┐')
            right = next((x for x in range(left + 3, len(row))
                          if row[x] in right_chars), None)
            if right is None:
                continue
            bottom = next((y for y in range(top + 2, len(rows))
                           if left < len(rows[y]) and right < len(rows[y]) and
                           rows[y][left] in ('╚', '└') and
                           rows[y][right] in ('╝', '┘')), None)
            if bottom is not None:
                rectangles.append((left, top, right, bottom))
    # Nested glyphs can be rediscovered; coordinates are the identity.
    return sorted(set(rectangles))


def visible_output_line(client, marker, prefix=''):
    expected = prefix + marker.decode('ascii')
    return any(expected in row and 'printf' not in row
               for row in client.screen.display)


def write_config(home, drag_content=True):
    with open(os.path.join(home, '.superterm', 'superterm.ini'), 'w',
              encoding='utf-8') as handle:
        handle.write(
            '[ui]\nlanguage=en\nbackground=none\n'
            'desktop_notifications=0\n'
            '[session]\nserver=always\nautosave=0\nautorestore=0\n'
            f'dragcontent={int(drag_content)}\nzoomanim=0\n')


def wait_session(home, timeout=4.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sockets = stlib.session_sockets(home)
        if len(sockets) == 1:
            return os.path.basename(sockets[0])[:-5]
        time.sleep(0.02)
    raise RuntimeError('session socket was not published')


class ScenarioContext:
    def __init__(self, binary, scenario, width, height, label):
        self.binary = binary
        self.scenario = scenario
        self.base_width = width
        self.base_height = height
        self.home = stlib.fresh_home('perf-' + label)
        self.clients = []
        self.owner = None
        self.client = None
        self.session = ''
        self.stopped = None
        write_config(self.home, scenario != 'wireframe_drag')
        stlib.BIN = binary
        env = {'SUPERTERM_SYNC': '1', 'TERM': 'xterm-256color',
               'COLORTERM': 'truecolor'}

        if scenario in ('attach_snapshot', 'reconnect', 'viewport_pan'):
            owner_w = width + 30 if scenario == 'viewport_pan' else width
            owner_h = height + 12 if scenario == 'viewport_pan' else height
            self.owner = stlib.Client(
                self.home, w=owner_w, h=owner_h, lang='en', env=env)
            self.clients.append(self.owner)
            self.owner.drain(1.2)
            self.session = wait_session(self.home)
            if scenario == 'viewport_pan':
                self.client = stlib.Client(
                    self.home, args=['--attach', self.session], w=width,
                    h=height, lang='en', env=env)
                self.clients.append(self.client)
                self.client.drain(1.0)
            elif scenario == 'reconnect':
                unmeasured_input(self.owner, b'\x11d')
                self.owner.wait_exit(3.0)
                self.owner.close()
                self.clients.remove(self.owner)
                self.owner = None
            return

        self.client = stlib.Client(
            self.home, w=width, h=height, lang='en', env=env)
        self.clients.append(self.client)
        self.client.drain(1.2)
        self.session = wait_session(self.home)
        self.prepare()

    def prepare(self):
        client = self.client
        scenario = self.scenario
        if scenario == 'arrow_input':
            unmeasured_input(client, b'echo PERF_ARROW_HISTORY\r')
        elif scenario == 'wheel_input':
            unmeasured_input(client,
                             b'for i in $(seq 1 120); do echo WHEEL_$i; done\r',
                             0.8)
        elif scenario == 'mouse_click':
            # Exercise an ordinary button click through a stable control.
            # Focusing one of the default overlapping windows raises it and
            # can legitimately hide the other window, so alternating between
            # two detected frames is not a repeatable workload.  The pane
            # scrollbar has an independently frozen click contract.
            unmeasured_input(client, b'seq 1 300\r', 0.8)
        elif scenario in ('bulk_input_output',):
            unmeasured_input(
                client,
                b"python3 -u -c 'import sys; [print(\"OUT:\"+x.rstrip()[:13]) "
                b"for x in sys.stdin]'\r", 0.3)
        elif scenario in ('mouse_drag_input', 'content_drag',
                          'wireframe_drag'):
            stlib.run_cli(['rename', self.session + ':1', 'PERF_DRAG'],
                          self.home, env={'LANG': 'C'})
            quiesce(client, quiet=0.05, ceiling=1.0)
        elif scenario == 'fast_with_slow_client':
            stlib.BIN = self.binary
            slow = stlib.Client(
                self.home, args=['--attach', self.session],
                w=self.base_width, h=self.base_height, lang='en',
                env={'SUPERTERM_SYNC': '1', 'TERM': 'xterm-256color',
                     'COLORTERM': 'truecolor'})
            self.clients.append(slow)
            slow.drain(0.8)
            os.kill(slow.pid, signal.SIGSTOP)
            self.stopped = slow
            write_input(
                client,
                b"python3 -c 'print(\"S\"*250000)' && "
                b"echo SLOW_BACKLOG_READY\r")
            if not wait_raw(client, b'SLOW_BACKLOG_READY', timeout=8.0):
                raise RuntimeError('fast client did not finish slow backlog')

    def measured_attach(self):
        stlib.BIN = self.binary
        env = {'SUPERTERM_SYNC': '1', 'TERM': 'xterm-256color',
               'COLORTERM': 'truecolor'}
        started = time.monotonic_ns()
        client = stlib.Client(
            self.home, args=['--attach', self.session], w=self.base_width,
            h=self.base_height, lang='en', env=env)
        before = tuple(tuple() for _ in range(self.base_height))
        first_ns = None
        last_ns = started
        deadline = time.monotonic() + 6.0
        while time.monotonic() < deadline:
            data = read_once(client, 0.002)
            now_ns = time.monotonic_ns()
            if data:
                last_ns = now_ns
            if (first_ns is None and
                    ('F2 Split' in client.text() or SYNC_END in client._raw)):
                first_ns = now_ns
            if (first_ns is not None and not data and
                    (now_ns - last_ns) / 1_000_000_000 >= 0.025):
                break
        stlib.flush_pyte(client.stream, 'performance attach')
        after = screen_cells(client)
        raw = client.raw()
        result = {
            'success': first_ns is not None,
            'latency_ms': ((first_ns - started) / 1_000_000
                           if first_ns is not None else None),
            'settled_ms': ((last_ns - started) / 1_000_000
                           if first_ns is not None else None),
            'bytes': len(raw),
            'frames': raw.count(SYNC_END) or (1 if raw else 0),
            'changed_cells': changed_cells(before, after),
        }
        client.close()
        return result

    def perform(self, iteration):
        if self.scenario in ('attach_snapshot', 'reconnect'):
            return self.measured_attach()

        client = self.client
        scenario = self.scenario
        cleanup = None
        completion = None

        if scenario in ('key_echo', 'fast_with_slow_client'):
            marker = f'__KEY_{iteration:04d}__'.encode()
            data = b"printf '" + marker + b"\\n'\r"
            completion = lambda current, _raw: visible_output_line(
                current, marker)
        elif scenario == 'arrow_input':
            data = b'\x1b[A'
            cleanup = lambda: unmeasured_input(client, b'\x15')
        elif scenario == 'wheel_input':
            code = 64 if iteration % 2 == 0 else 65
            data = mouse(code, max(2, client.w // 2),
                         max(2, client.h // 2))
        elif scenario == 'mouse_click':
            rectangles = frame_rects(client)
            if not rectangles:
                return {'success': False, 'latency_ms': None,
                        'settled_ms': None, 'bytes': 0, 'frames': 0,
                        'changed_cells': 0}
            _left, top, right, bottom = rectangles[-1]
            arrows = [y for y in range(top + 1, bottom)
                      if client.screen.display[y][right] == '▲']
            if not arrows:
                return {'success': False, 'latency_ms': None,
                        'settled_ms': None, 'bytes': 0, 'frames': 0,
                        'changed_cells': 0}
            y = arrows[0]
            data = mouse(0, right, y) + mouse(0, right, y, release=True)
            cleanup = lambda: unmeasured_input(client, b'\x1b[1;3F', 0.04)
        elif scenario in ('mouse_drag_input', 'content_drag',
                          'wireframe_drag'):
            rectangles = frame_rects(client)
            if not rectangles:
                return {'success': False, 'latency_ms': None,
                        'settled_ms': None, 'bytes': 0, 'frames': 0,
                        'changed_cells': 0}
            target = next((rect for rect in rectangles
                           if 'PERF_DRAG' in client.screen.display[rect[1]]),
                          rectangles[0])
            left, top, right, _bottom = target
            title_start = client.screen.display[top].find('PERF_DRAG')
            if title_start < 0:
                return {'success': False, 'latency_ms': None,
                        'settled_ms': None, 'bytes': 0, 'frames': 0,
                        'changed_cells': 0}
            start_x = title_start + len('PERF_DRAG') // 2
            if left <= 0:
                delta = 1
            elif right >= client.w - 1:
                delta = -1
            else:
                delta = 1 if iteration % 2 == 0 else -1
            end_x = max(1, min(client.w - 2, start_x + delta))
            press = mouse(0, start_x, top)
            motion = mouse(0, end_x, top, motion=True)
            release = mouse(0, end_x, top, release=True)
            unmeasured_input(client, press, 0.15)
            if scenario == 'mouse_drag_input':
                data = motion
                cleanup = lambda: unmeasured_input(client, release, 0.04)
            else:
                data = motion + release
        elif scenario == 'menu_open':
            data = b'\x1bp'
            cleanup = lambda: unmeasured_input(client, b'\x1b')
        elif scenario == 'dialog_open':
            data = b'\x1bh\r'
            cleanup = lambda: unmeasured_input(client, b'\x1b')
        elif scenario == 'resize':
            target_w = self.base_width - (iteration % 2)

            def resize_trigger():
                client.w = target_w
                client.screen.resize(lines=self.base_height,
                                     columns=target_w)
                fcntl.ioctl(client.fd, termios.TIOCSWINSZ,
                            struct.pack('HHHH', self.base_height,
                                        target_w, 0, 0))

            return measure_action(client, resize_trigger)
        elif scenario == 'maximize_restore':
            data = b'\x1bpx'
        elif scenario == 'fullscreen_return':
            data = stlib.FULLSCREEN_CHORD
        elif scenario == 'viewport_pan':
            x = client.w - 2 if iteration % 2 == 0 else 0
            y = client.h - 2
            data = mouse(0, x, y) + mouse(0, x, y, release=True)
        elif scenario == 'bulk_input_output':
            marker = f'BULK_{iteration:04d}_END'.encode()
            payload = marker + b'X' * 4096
            data = payload + b'\r'
            completion = lambda current, _raw: visible_output_line(
                current, marker, 'OUT:')
        else:                           # pragma: no cover - guarded by parser
            raise RuntimeError('unknown scenario ' + scenario)

        result = measure_action(
            client, lambda: write_input(client, data), completion=completion)
        if cleanup is not None:
            cleanup()
        return result

    def close(self):
        if self.stopped is not None:
            try:
                os.kill(self.stopped.pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
            self.stopped = None
        for client in reversed(self.clients):
            try:
                client.close()
            except Exception as exc:              # noqa: BLE001
                print(f'cleanup warning: {exc}', file=sys.stderr)
        stlib.close_all_daemons(self.home)


def summarize(samples):
    groups = {}
    for sample in samples:
        key = (sample['scenario'], sample['geometry'], sample['variant'])
        groups.setdefault(key, []).append(sample)
    rows = []
    for (scenario, geometry, variant), records in sorted(groups.items()):
        good = [record for record in records if record['success']]
        latencies = [record['latency_ms'] for record in good]
        rows.append({
            'scenario': scenario, 'geometry': geometry, 'variant': variant,
            'samples': len(records), 'successful': len(good),
            'minimum_ms': min(latencies) if latencies else None,
            'p50_ms': statistics.median(latencies) if latencies else None,
            'p95_ms': percentile(latencies, 0.95),
            'maximum_ms': max(latencies) if latencies else None,
            'median_bytes': statistics.median(
                [record['bytes'] for record in good]) if good else None,
            'median_changed_cells': statistics.median(
                [record['changed_cells'] for record in good]) if good else None,
            'median_frames': statistics.median(
                [record['frames'] for record in good]) if good else None,
        })
    return rows


def markdown_report(payload):
    lines = [
        '# Interleaved performance baseline', '',
        f"- samples per scenario: {payload['metadata']['samples']}",
        f"- CPU affinity: {payload['metadata']['cpu_affinity']}",
        f"- baseline: `{payload['binaries']['baseline']['path']}`",
        f"- candidate: `{payload['binaries']['candidate']['path']}`", '',
        '| scenario | geometry | variant | ok/n | min ms | p50 ms | p95 ms | max ms | bytes | changed cells | frames |',
        '| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |',
    ]

    def number(value, digits=2):
        if value is None:
            return '-'
        return f'{value:.{digits}f}'

    for row in payload['summary']:
        lines.append(
            f"| {row['scenario']} | {row['geometry']} | {row['variant']} | "
            f"{row['successful']}/{row['samples']} | "
            f"{number(row['minimum_ms'])} | {number(row['p50_ms'])} | "
            f"{number(row['p95_ms'])} | {number(row['maximum_ms'])} | "
            f"{number(row['median_bytes'], 0)} | "
            f"{number(row['median_changed_cells'], 0)} | "
            f"{number(row['median_frames'], 0)} |")
    return '\n'.join(lines) + '\n'


def parse_geometry(value):
    try:
        width, height = (int(part) for part in value.lower().split('x', 1))
    except (ValueError, TypeError):
        raise argparse.ArgumentTypeError('geometry must be WIDTHxHEIGHT')
    if width < 40 or height < 15:
        raise argparse.ArgumentTypeError('geometry is too small for the IDE')
    return width, height


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default='/usr/local/bin/superterm')
    parser.add_argument('--candidate', default=os.path.join(
        ROOT, 'bin', 'superterm'))
    parser.add_argument('--samples', type=int, default=DEFAULT_SAMPLES)
    parser.add_argument('--geometry', action='append', type=parse_geometry,
                        dest='geometries')
    parser.add_argument('--scenario', action='append', choices=SCENARIOS,
                        dest='scenarios')
    parser.add_argument('--output', required=True,
                        help='raw JSON result path; .md summary is adjacent')
    parser.add_argument('--smoke', action='store_true',
                        help='allow fewer than 50 samples for harness testing')
    args = parser.parse_args(argv)
    if args.samples < 1 or (args.samples < DEFAULT_SAMPLES and not args.smoke):
        parser.error('closure runs require at least 50 samples')
    args.geometries = args.geometries or list(DEFAULT_GEOMETRIES)
    args.scenarios = args.scenarios or list(SCENARIOS)
    return args


def main(argv=None):
    args = parse_args(argv)
    for path in (args.baseline, args.candidate):
        if not os.path.isfile(path) or not os.access(path, os.X_OK):
            print(f'not an executable binary: {path}', file=sys.stderr)
            return 2

    original_affinity = None
    affinity_text = 'unavailable'
    if hasattr(os, 'sched_getaffinity') and hasattr(os, 'sched_setaffinity'):
        try:
            original_affinity = os.sched_getaffinity(0)
            cpu = min(original_affinity)
            os.sched_setaffinity(0, {cpu})
            affinity_text = f'pinned to CPU {cpu}'
        except OSError as exc:
            affinity_text = f'not pinned: {exc}'

    variants = {'baseline': os.path.abspath(args.baseline),
                'candidate': os.path.abspath(args.candidate)}
    raw_samples = []
    try:
        for width, height in args.geometries:
            geometry = f'{width}x{height}'
            for scenario in args.scenarios:
                iteration = 0
                for batch, batch_samples in enumerate(
                        measurement_batches(args.samples)):
                    contexts = {}
                    creation_order = (('baseline', 'candidate') if batch == 0
                                      else ('candidate', 'baseline'))
                    try:
                        for variant in creation_order:
                            contexts[variant] = ScenarioContext(
                                variants[variant], scenario, width, height,
                                f'{batch}-{variant[:1]}-{scenario[:8]}-{width}')
                        # Creation and warm-up order are both reversed in the
                        # second batch. This prevents a stable daemon poll
                        # phase from being attributed to one binary label.
                        for variant in creation_order:
                            contexts[variant].perform(-1)
                        for action_iteration in range(batch_samples):
                            # Stateful scenarios alternate direction or target
                            # on action parity. AB/AB/BA/BA balances both
                            # parities; reversing it in batch two also balances
                            # position across independently started contexts.
                            order = interleaved_order(action_iteration)
                            if batch != 0:
                                order = tuple(reversed(order))
                            for position, variant in enumerate(order):
                                result = contexts[variant].perform(
                                    action_iteration)
                                result.update({
                                    'scenario': scenario,
                                    'geometry': geometry,
                                    'variant': variant,
                                    'iteration': iteration,
                                    'action_iteration': action_iteration,
                                    'batch': batch,
                                    'order': position,
                                })
                                raw_samples.append(result)
                            iteration += 1
                    finally:
                        for context in contexts.values():
                            context.close()
                print(f'completed {scenario} {geometry}', flush=True)
    finally:
        if original_affinity is not None:
            try:
                os.sched_setaffinity(0, original_affinity)
            except OSError:
                pass

    payload = {
        'schema': 1,
        'metadata': {
            'generated_at': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
            'samples': args.samples,
            'geometries': [f'{w}x{h}' for w, h in args.geometries],
            'scenarios': args.scenarios,
            'cpu_affinity': affinity_text,
            'platform': sys.platform,
            'python': sys.version,
            'source_commit': subprocess.run(
                ['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True,
                text=True, timeout=5).stdout.strip(),
            'build_flags': '-Mobjfpc -Sh -Sewnh -vewnh; release -O4 -gl',
        },
        'binaries': {name: binary_identity(path)
                     for name, path in variants.items()},
        'samples': raw_samples,
    }
    payload['summary'] = summarize(raw_samples)
    output = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    with open(output, 'w', encoding='utf-8') as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write('\n')
    markdown = os.path.splitext(output)[0] + '.md'
    with open(markdown, 'w', encoding='utf-8') as handle:
        handle.write(markdown_report(payload))
    print(f'raw results: {output}')
    print(f'summary: {markdown}')
    return 0 if all(sample['success'] for sample in raw_samples) else 1


if __name__ == '__main__':
    sys.exit(main())
