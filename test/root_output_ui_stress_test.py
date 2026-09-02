#!/usr/bin/env python3
"""Stress UI geometry while several panes recursively list a filesystem.

The standard suite uses a bounded generated tree so the regression is
deterministic.  Set ``SUPERTERM_ROOT_OUTPUT_EXACT=1`` for the live diagnostic
requested by the project owner: every pane runs ``cd /`` followed by
``ls -R`` while mouse drags, maximize/restore operations, and host resizes are
repeated.  Exact mode is intentionally a soak, not part of ``make test``.
"""
import fcntl
import glob
import os
import select
import shlex
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


EXACT = os.environ.get('SUPERTERM_ROOT_OUTPUT_EXACT', '') == '1'
PANES = int(os.environ.get('SUPERTERM_ROOT_OUTPUT_PANES', '2'))
ROUNDS = int(os.environ.get(
    'SUPERTERM_ROOT_OUTPUT_ROUNDS', '80' if EXACT else '12'))
WIDTH = int(os.environ.get('SUPERTERM_ROOT_OUTPUT_WIDTH', '160'))
HEIGHT = int(os.environ.get('SUPERTERM_ROOT_OUTPUT_HEIGHT', '50'))
DRAG_CONTENT = os.environ.get('SUPERTERM_ROOT_OUTPUT_DRAG_CONTENT', '1') == '1'
if PANES < 2 or PANES > 16:
    raise SystemExit('SUPERTERM_ROOT_OUTPUT_PANES must be between 2 and 16')
if ROUNDS < 1:
    raise SystemExit('SUPERTERM_ROOT_OUTPUT_ROUNDS must be positive')
if WIDTH < 80 or HEIGHT < 25:
    raise SystemExit('stress geometry must be at least 80x25')

HOME = stlib.fresh_home('root-output-ui-stress')
LOG_HOME = tempfile.mkdtemp(prefix='superterm-root-output-', dir='/tmp')
FLOW_LOG = os.path.join(LOG_HOME, 'flow.log')
ACTION_LOG = os.path.join(LOG_HOME, 'actions.log')
HEAP_PREFIX = os.path.join(LOG_HOME, 'heap')
DEBUG_ENV = {
    'SUPERTERM_DEBUG': FLOW_LOG,
    'SUPERTERM_DEBUG_FULL': '1',
    'SUPERTERM_HEAP_LOG': HEAP_PREFIX,
    'HEAPTRC': os.environ.get('HEAPTRC', 'nohalt'),
    'TERM': 'xterm-256color',
    'COLORTERM': 'truecolor',
}
BAD_MARKERS = (
    'runtime error', '*** fatal', 'sigsegv', 'sigabrt', 'sigbus',
    'sigfpe', 'sigill', 'unhandled exception', 'access violation',
    'eaccessviolation', 'invalid pointer operation',
    'daemon: exception in main loop',
)

with open(os.path.join(HOME, '.superterm', 'superterm.ini'), 'w',
          encoding='utf-8') as output:
    output.write(
        '[ui]\nlanguage=en\nbackground=none\ndesktop_notifications=0\n'
        '[session]\nserver=always\nautosave=0\nautorestore=0\n'
        f'dragcontent={int(DRAG_CONTENT)}\nzoomanim=0\n'
        'multithread=auto\n')


def action(message):
    line = f'{time.time():.6f} {message}\n'
    with open(ACTION_LOG, 'a', encoding='utf-8') as output:
        output.write(line)
    print(message, flush=True)


def capture_hung_client(pid):
    """Preserve external stacks before cleanup changes a stuck process."""
    path = os.path.join(LOG_HOME, f'client-hang-{pid}.gdb.txt')
    command = [
        'gdb', '--batch', '--nx', '--quiet',
        '-ex', 'set pagination off',
        '-ex', 'thread apply all bt full',
        '-ex', 'thread 1',
        '-ex', 'frame 3',
        '-ex', 'p this',
        '-ex', 'p this^.current',
        '-ex', 'p desktop',
        '-ex', 'p remotemode',
        '-ex', 'p remote',
        '-p', str(pid),
    ]
    try:
        completed = subprocess.run(
            command, capture_output=True, text=True, timeout=20)
        with open(path, 'w', encoding='utf-8') as output:
            output.write('command: ' + ' '.join(command) + '\n')
            output.write(f'returncode: {completed.returncode}\n')
            output.write(completed.stdout)
            output.write(completed.stderr)
        action(f'hung client stack captured path={path} '
               f'rc={completed.returncode}')
    except (OSError, subprocess.SubprocessError) as error:
        action(f'hung client stack capture failed: {error}')


def wait_session(timeout=8.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sockets = stlib.session_sockets(HOME)
        if len(sockets) == 1:
            return os.path.basename(sockets[0])[:-5]
        time.sleep(0.02)
    return ''


def pane_rows(session):
    result = run_cli(['list', session], HOME, env=DEBUG_ENV)
    rows = [line for line in result.stdout.splitlines()
            if line and line[0].isdigit()]
    return result, rows


def pane_history(row):
    """Return the HIST counter from one stable ``superterm list`` row."""
    fields = row.split()
    for index, field in enumerate(fields[:-1]):
        parts = field.split('x', 1)
        if (len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit() and
                fields[index + 1].isdigit()):
            return int(fields[index + 1])
    return -1


def load_marker(pane):
    return os.path.join(HOME, f'.root-output-load-{pane}')


def attached_clients(session):
    """Return the daemon's authoritative viewer count for this session."""
    result = run_cli(['list'], HOME, env={**DEBUG_ENV, 'LANG': 'C'})
    for line in result.stdout.splitlines():
        tokens = line.split()
        if len(tokens) < 4 or tokens[0] in ('NAME', 'NOMBRE'):
            continue
        if tokens[0] != session:
            continue
        try:
            return int(tokens[-3])
        except ValueError:
            return -1
    return -1


def frame_rect(client, title):
    rows = client.screen.display
    for top, row in enumerate(rows):
        title_x = row.find(title)
        if title_x < 0:
            continue
        lefts = [x for x, char in enumerate(row[:title_x])
                 if char in ('╔', '┌')]
        rights = [x for x, char in enumerate(
            row[title_x + len(title):], title_x + len(title))
                  if char in ('╗', '┐')]
        if lefts and rights:
            left, right = max(lefts), min(rights)
            for bottom in range(top + 2, len(rows)):
                if (rows[bottom][left] in ('╚', '└') and
                        rows[bottom][right] in ('╝', '┘')):
                    return left, top, right, bottom
    return None


def sgr_mouse(code, x, y, motion=False, release=False):
    if motion:
        code += 32
    suffix = 'm' if release else 'M'
    return f'\x1b[<{code};{x + 1};{y + 1}{suffix}'.encode()


def write_client(client, data):
    stlib.write_all(client.fd, data)


def mouse_click(client, x, y):
    write_client(client, sgr_mouse(0, x, y))
    time.sleep(0.025)
    write_client(client, sgr_mouse(0, x, y, release=True))
    time.sleep(0.050)


def mouse_drag(client, start, end, steps=8):
    """Send a physical-looking SGR press/path/release gesture."""
    write_client(client, sgr_mouse(0, *start))
    time.sleep(0.030)
    for step in range(1, steps + 1):
        x = start[0] + (end[0] - start[0]) * step // steps
        y = start[1] + (end[1] - start[1]) * step // steps
        write_client(client, sgr_mouse(0, x, y, motion=True))
        time.sleep(0.018)
    write_client(client, sgr_mouse(0, *end, release=True))
    time.sleep(0.060)


def pump_client(client, stop, totals):
    while not stop.is_set() and client.alive():
        try:
            ready, _, _ = select.select([client.fd], [], [], 0.03)
        except (InterruptedError, OSError):
            continue
        if not ready:
            continue
        try:
            data = os.read(client.fd, 262144)
        except OSError:
            break
        if not data:
            break
        totals[0] += len(data)
        prefix = totals[1][-3:]
        totals[1] = (totals[1] + data)[-3:]
        for _query in range((prefix + data).count(b'\x1b[6n')):
            try:
                row, col = client.dsr
                os.write(client.fd, f'\x1b[{row};{col}R'.encode())
            except OSError:
                return


def wait_alive(client, session, seconds=0.25):
    time.sleep(seconds)
    result, rows = pane_rows(session)
    return (client.alive() and result.returncode == 0 and
            len(rows) == PANES and attached_clients(session) == 1)


def restart_finished_listings(session):
    """Keep every pane under the requested recursive-output workload."""
    result, rows = pane_rows(session)
    if result.returncode != 0 or len(rows) != PANES:
        return False
    for pane, row in enumerate(rows, 1):
        if ((EXACT and 'ls -R' in row) or
                ((not EXACT) and os.path.exists(load_marker(pane)))):
            continue
        action(f'restart recursive listing pane={pane}')
        run_cli(['send', f'{session}:{pane}', 'cd /'], HOME, env=DEBUG_ENV)
        command = ('ls -R' if EXACT else
                   bounded_listing_command(bounded_root, pane))
        if run_cli(['send', f'{session}:{pane}', command], HOME,
                   env=DEBUG_ENV).returncode != 0:
            return False
    return True


def bounded_tree():
    root = os.path.join(HOME, 'stress-tree')
    os.makedirs(root, exist_ok=True)
    payload = 'X' * 72
    for directory in range(32):
        path = os.path.join(root, f'd{directory:02d}')
        os.makedirs(path, exist_ok=True)
        for entry in range(64):
            name = os.path.join(path, f'f{entry:03d}-{payload}')
            with open(name, 'w', encoding='ascii'):
                pass
    return root


def bounded_listing_command(root, pane):
    """Return a finite flood large enough to overlap the UI exercise.

    An infinite producer necessarily outruns every bounded queue on a slow
    enough client and tests eviction rather than the requested finite
    recursive-listing interaction. Tile rounds may start another finite batch
    if one has already completed.
    """
    quoted = shlex.quote(root)
    marker = shlex.quote(load_marker(pane))
    return (f'rm -f {marker}; touch {marker}; '
            '_st_i=0; while [ "$_st_i" -lt 32 ]; do '
            f'ls -R {quoted}; _st_i=$((_st_i+1)); sleep 0.02; done; '
            f'rm -f {marker}')


client = None
client_pid = None
stop = threading.Event()
pump = None
session = ''
daemon_pid = None
totals = [0, b'']
try:
    action(f'START exact={int(EXACT)} panes={PANES} rounds={ROUNDS} '
           f'drag_content={int(DRAG_CONTENT)} '
           f'binary={stlib.BIN} log_home={LOG_HOME}')
    client = stlib.Client(HOME, w=WIDTH, h=HEIGHT, lang='en', env=DEBUG_ENV)
    client_pid = client.pid
    client.drain(2.0)
    session = wait_session()
    check('stress session published', bool(session))
    result, rows = pane_rows(session)
    while len(rows) < PANES and client.alive():
        client.send(b'\x1bOQ', 0.6)
        result, rows = pane_rows(session)
    check('requested pane count created', len(rows) == PANES)
    for pane in range(1, PANES + 1):
        renamed = run_cli(
            ['rename', f'{session}:{pane}', f'ROOTSTRESS{pane}'], HOME,
            env=DEBUG_ENV)
        check(f'pane {pane} renamed', renamed.returncode == 0)
    arranged = run_cli(['organize', session, 'tile'], HOME, env=DEBUG_ENV)
    check('panes tiled before load', arranged.returncode == 0)
    client.drain(1.0)

    # Capture one real frame before switching to the high-volume raw pump.
    rect = frame_rect(client, 'ROOTSTRESS1')
    check('mouse target frame found', rect is not None)
    if rect is None:
        raise RuntimeError('cannot locate pane frame for mouse stress')
    left, top, right, bottom = rect
    current_rect = [left, top, right, bottom]

    target = '/' if EXACT else bounded_tree()
    bounded_root = target
    # Establish every working directory before any pane starts flooding the
    # daemon.  Each pane still receives the requested independent ``cd /``
    # followed by ``ls -R`` sequence, but an early producer cannot obscure a
    # later setup command and turn the stress into a false partial workload.
    for pane in range(1, PANES + 1):
        changed = run_cli(['send', f'{session}:{pane}', 'cd /'], HOME,
                          env=DEBUG_ENV)
        check(f'pane {pane} cd / accepted', changed.returncode == 0)
    for pane in range(1, PANES + 1):
        # In bounded mode retain the exact two-command sequence, then list a
        # controlled tree repeatedly so make test remains deterministic.
        command = ('ls -R' if EXACT else bounded_listing_command(target, pane))
        listed = run_cli(['send', f'{session}:{pane}', command], HOME,
                         env=DEBUG_ENV)
        check(f'pane {pane} recursive listing accepted',
              listed.returncode == 0)
    action('all recursive listings submitted')
    deadline = time.monotonic() + 2.0
    rows = []
    while time.monotonic() < deadline:
        result, rows = pane_rows(session)
        histories = [pane_history(row) for row in rows]
        loads_started = (sum('ls -R' in row for row in rows) == PANES
                         if EXACT else
                         all(os.path.exists(load_marker(pane))
                             for pane in range(1, PANES + 1)))
        if (result.returncode == 0 and len(rows) == PANES and loads_started and
                all(history > 0 for history in histories)):
            break
        time.sleep(0.02)
    check('all panes remain listed after output begins',
          result.returncode == 0 and len(rows) == PANES)
    action(f'initial pane rows={rows!r}')
    # A bounded loop alternates between ls and a short sleep, leaving a tiny
    # fork/exec interval where COMMAND is empty. Per-pane lifetime markers and
    # positive HIST counters prove the workload without sampling that race.
    check('recursive listings are live in every pane',
          loads_started and len(rows) == PANES and
          all(pane_history(row) > 0 for row in rows))

    pump = threading.Thread(target=pump_client,
                            args=(client, stop, totals), daemon=True)
    pump.start()
    for number in range(ROUNDS):
        pane = number % PANES + 1
        phase = number % 7
        if phase == 0:
            action(f'round={number} mouse-drag pane=1')
            start = (max(current_rect[0] + 2, current_rect[0] +
                         len('ROOTSTRESS1') // 2), current_rect[1])
            end = (min(WIDTH - 4, start[0] + 5),
                   min(HEIGHT - 4, start[1] + 2))
            mouse_drag(client, start, end)
            dx, dy = end[0] - start[0], end[1] - start[1]
            current_rect = [current_rect[0] + dx, current_rect[1] + dy,
                            current_rect[2] + dx, current_rect[3] + dy]
        elif phase == 1:
            action(f'round={number} mouse-resize pane=1')
            start = (current_rect[2], current_rect[3])
            end = (min(WIDTH - 2, start[0] + 4),
                   min(HEIGHT - 2, start[1] + 2))
            mouse_drag(client, start, end)
            current_rect[2], current_rect[3] = end
        elif phase == 2:
            action(f'round={number} mouse-maximize pane=1')
            mouse_click(client, current_rect[2] - 3, current_rect[1])
        elif phase == 3:
            action(f'round={number} mouse-restore pane=1')
            mouse_click(client, WIDTH - 4, 1)
        elif phase == 4:
            width = WIDTH - 9
            height = HEIGHT - 5
            action(f'round={number} host-resize {width}x{height} '
                   f'then {WIDTH}x{HEIGHT}')
            fcntl.ioctl(client.fd, termios.TIOCSWINSZ,
                        struct.pack('HHHH', height, width, 0, 0))
            time.sleep(0.080)
            fcntl.ioctl(client.fd, termios.TIOCSWINSZ,
                        struct.pack('HHHH', HEIGHT, WIDTH, 0, 0))
        elif phase == 5:
            action(f'round={number} pane-resize pane={pane}')
            run_cli(['resize', f'{session}:{pane}',
                     f'{70 + number % 9}x{20 + number % 5}'], HOME,
                    env=DEBUG_ENV)
        else:
            action(f'round={number} tile')
            run_cli(['organize', session, 'tile'], HOME, env=DEBUG_ENV)
            current_rect = [left, top, right, bottom]
            check(f'round {number} recursive loads remain active',
                  restart_finished_listings(session))
        if not wait_alive(client, session):
            check(f'round {number} client and daemon survive', False)
            break
        check(f'round {number} client and daemon survive', True)

    check('stress produced terminal output', totals[0] > 0)
    result, rows = pane_rows(session)
    check('all panes survive the complete geometry stress',
          client.alive() and result.returncode == 0 and len(rows) == PANES)
finally:
    stop.set()
    if pump is not None:
        pump.join(timeout=2.0)
    if session:
        for pane in range(1, PANES + 1):
            run_cli(['send', '-n', f'{session}:{pane}', '-k', 'C-c'], HOME,
                    env=DEBUG_ENV)
        result = run_cli(['kill', session], HOME, env=DEBUG_ENV)
        action(f'cleanup kill rc={result.returncode}')
    for pane in range(1, PANES + 1):
        try:
            os.unlink(load_marker(pane))
        except FileNotFoundError:
            pass
    if client is not None:
        if client.alive():
            # Drain without pyte and acknowledge when the ordered lifecycle
            # notice reaches the terminal.  Under a real flood an Enter sent
            # only once can legitimately precede that modal by a few
            # milliseconds; repeat the user's acknowledgement under one hard
            # deadline instead of misreporting a healthy modal as a hang.
            deadline = time.monotonic() + 8.0
            status = None
            while client.alive() and time.monotonic() < deadline:
                stlib.drain_clients_raw([client], 0.15)
                if not client.alive():
                    break
                write_client(client, b'\r')
            remaining = max(0.0, deadline - time.monotonic())
            status = client.wait_exit(timeout=remaining)
        else:
            status = client.wait_exit(timeout=0.0)
        action(f'interactive client wait_status={status!r} '
               f'disposition={client.reap_disposition!r}')
        if status is None and client.alive():
            capture_hung_client(client.pid)
        check('interactive stress client exits cleanly', status == 0)
        client.close()

flow = ''
try:
    with open(FLOW_LOG, encoding='utf-8', errors='replace') as input_file:
        flow = input_file.read()
except OSError:
    pass
lower_flow = flow.lower()
for marker in BAD_MARKERS:
    check(f'flow log has no {marker}', marker not in lower_flow)
owned_crashes = (sorted(glob.glob(
    f'/tmp/superterm-crash-client-{client_pid}-*.log'))
    if client_pid is not None else [])
check('stress produced no owned crash report', not owned_crashes)
action(f'END bytes={totals[0]} owned_crashes={owned_crashes!r}')
stlib.report()
