#!/usr/bin/env python3
"""Intensive shared desktop/focus test with attach/detach churn.

Run with SUPERTERM_TEST_BIN=bin/superterm-debug and full logging to exercise
range/overflow/I/O checks in the build while every wire frame is recorded.
"""
import atexit
import glob
import configparser
import os
import math
import random
import re
import shlex
import socket
import stat
import struct
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


EXTERNAL_SESSION = os.environ.get('SUPERTERM_STRESS_SESSION', '').strip()
EXTERNAL_MODE = bool(EXTERNAL_SESSION)
EXTERNAL_DAEMON_LOG = os.environ.get(
    'SUPERTERM_STRESS_DAEMON_LOG', '').strip()
EXTERNAL_DAEMON_LOG_OFFSET = 0
if EXTERNAL_DAEMON_LOG:
    try:
        EXTERNAL_DAEMON_LOG_OFFSET = os.path.getsize(EXTERNAL_DAEMON_LOG)
    except OSError:
        pass
if EXTERNAL_MODE:
    HOME = os.environ.get('SUPERTERM_STRESS_HOME', os.environ.get('HOME', ''))
    if not HOME:
        raise SystemExit('SUPERTERM_STRESS_HOME is required in external mode')
    safe_session = ''.join(ch if ch.isalnum() or ch in '-_' else '_'
                           for ch in EXTERNAL_SESSION)
    requested_log_home = os.environ.get('SUPERTERM_STRESS_LOGDIR', '')
    if requested_log_home:
        LOG_HOME = requested_log_home
        os.makedirs(LOG_HOME, exist_ok=True)
    else:
        os.makedirs('/tmp/opencode', exist_ok=True)
        LOG_HOME = tempfile.mkdtemp(
            prefix=f'st-live-{safe_session}-', dir='/tmp/opencode')
else:
    HOME = stlib.fresh_home('multiclient-intensive')
    LOG_HOME = HOME
DEBUG_LOG = LOG_HOME + '/superterm-full.log'
ACTION_LOG = LOG_HOME + '/actions.log'
DEBUG_ENV = {
    'SUPERTERM_DEBUG': DEBUG_LOG,
    'SUPERTERM_DEBUG_FULL': '1',
    'SUPERTERM_HEAP_LOG': LOG_HOME + '/heap',
    'HEAPTRC': 'nohalt',
    # Do not let an exported debugging override silently turn this dedicated
    # multicore stress into the single-reactor topology.
    'SUPERTERM_MULTITHREAD': 'auto',
}
BAD_FLOW_MARKERS = (
    'runtime error',
    '*** fatal',
    'sigsegv',
    'sigabrt',
    'sigbus',
    'sigfpe',
    'sigill',
    'unhandled exception',
    'crash report',
    'access violation',
    'eaccessviolation',
    'invalid pointer operation',
    'daemon: exception in main loop',
)
SEED_TEXT = os.environ.get('SUPERTERM_STRESS_SEED', '0x3515a11')
SEED = int(SEED_TEXT, 0)
RNG = random.Random(SEED)
ROUNDS = int(os.environ.get('SUPERTERM_STRESS_ROUNDS', '12'))
LIVE_SECONDS = int(os.environ.get('SUPERTERM_STRESS_LIVE_SECONDS', '0'))
CLIENT_W = int(os.environ.get(
    'SUPERTERM_STRESS_WIDTH', '163' if EXTERNAL_MODE else '132'))
CLIENT_H = int(os.environ.get(
    'SUPERTERM_STRESS_HEIGHT', '64' if EXTERNAL_MODE else '42'))
VISIBLE_STEP_PAUSE = float(os.environ.get(
    'SUPERTERM_STRESS_VISIBLE_STEP_PAUSE', '0.2'))
EXPECT_HEAP = ('debug-heap' in os.path.basename(stlib.BIN) or
               os.environ.get('SUPERTERM_EXPECT_HEAP', '') == '1')
if ROUNDS < 1:
    raise SystemExit('SUPERTERM_STRESS_ROUNDS must be at least 1')
if ROUNDS > 1296:
    raise SystemExit('SUPERTERM_STRESS_ROUNDS cannot exceed 1296')
if LIVE_SECONDS < 0:
    raise SystemExit('SUPERTERM_STRESS_LIVE_SECONDS cannot be negative')
if CLIENT_W < 60 or CLIENT_H < 18:
    raise SystemExit('stress client geometry must be at least 60x18')
if not math.isfinite(VISIBLE_STEP_PAUSE) or VISIBLE_STEP_PAUSE <= 0:
    raise SystemExit('SUPERTERM_STRESS_VISIBLE_STEP_PAUSE must be positive')
if not EXTERNAL_MODE:
    with open(HOME + '/.superterm/superterm.ini', 'w') as fh:
        # Membership toasts are deliberately client-local and their two-second
        # FIFO timers need not start on the same tick.  They can cover a pane
        # border while this suite compares the shared desktop.  The dedicated
        # client_notifications_test.py keeps that behaviour enabled and
        # verifies every toast/status/bell; disable only the optional desktop
        # overlay here so the pane-convergence oracle observes shared state.
        fh.write('[ui]\nlanguage=en\nbackground=none\n'
                 'desktop_notifications=0\n'
                 '[session]\nserver=always\nautosave=0\nautorestore=0\n'
                 'multithread=auto\nzoomanim=0\n')


def trace_action(message):
    line = (f'{time.time():.6f} seed={SEED:#x} {message}\n')
    with open(ACTION_LOG, 'a', encoding='utf-8') as fh:
        fh.write(line)


def require_clean(context):
    """Stop at a failed phase boundary before later actions can cascade."""
    if stlib.fails():
        trace_action(f'FAIL_FAST context={context!r} first={stlib.fails()[0]!r}')
        raise SystemExit(
            f'stress fail-fast at {context}: {stlib.fails()[0]}')


trace_action(f'START binary={stlib.BIN} rounds={ROUNDS} '
             f'live_seconds={LIVE_SECONDS} external={int(EXTERNAL_MODE)} '
             f'home={HOME} session={EXTERNAL_SESSION or "<new>"}')
print(f'stress seed={SEED:#x}')
print(f'action log={ACTION_LOG}')
print(f'flow log={DEBUG_LOG}')


def round_code(number):
    """Fixed two-cell base36 tag; keeps narrow-pane markers unwrapped."""
    alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    value = number % (len(alphabet) * len(alphabet))
    return alphabet[value // len(alphabet)] + alphabet[value % len(alphabet)]


def fifo_sequences(log_text, daemon_pid=None):
    """Return the daemon's enqueue/dequeue sequence streams from full log."""
    if daemon_pid is not None:
        daemon_tag = f'[{daemon_pid} daemon '
        log_text = '\n'.join(
            line for line in log_text.splitlines() if daemon_tag in line)
    enqueue = [int(value) for value in re.findall(
        r'command-fifo: enqueue seq=(\d+)', log_text)]
    dequeue = [int(value) for value in re.findall(
        r'command-fifo: dequeue seq=(\d+)', log_text)]
    return enqueue, dequeue


def client_fifo_dequeue_count(path, daemon_pid):
    """Count accepted interactive-client commands in one daemon flow log."""
    try:
        with open(path, encoding='utf-8', errors='replace') as input_file:
            value = input_file.read()
    except OSError:
        return -1
    daemon_tag = f'[{daemon_pid} daemon '
    return sum(1 for line in value.splitlines()
               if daemon_tag in line and
               'command-fifo: dequeue ' in line and
               'origin=client ' in line and ' valid=1 ' in line)


def check_fifo_log(log_text, prefix='global command FIFO', daemon_pid=None):
    enqueue, dequeue = fifo_sequences(log_text, daemon_pid=daemon_pid)
    monotonic_enqueue = (len(enqueue) > 20 and
                         all(left < right
                             for left, right in zip(enqueue, enqueue[1:])))
    check(prefix + ' records substantial traffic', len(enqueue) > 20)
    check(prefix + ' enqueue sequence is monotonic', monotonic_enqueue)
    check(prefix + ' dequeues every command once', dequeue == enqueue)


def drain_all(clients, seconds):
    end = time.time() + seconds
    while time.time() < end:
        for client in clients:
            if client is not None:
                client.drain(0.03)


KNOWN_CLIENT_PIDS = set()
TRACKED_CLIENTS = {}
ACTIVE_TEST_FOREGROUNDS = {}
FOREGROUND_QUERY_FAILED = object()
os.makedirs('/tmp/opencode', exist_ok=True)
FOREGROUND_CONTROL_DIR = tempfile.mkdtemp(
    prefix='superterm-stress-foreground-', dir='/tmp/opencode')
FOREGROUND_HELPER_FD, FOREGROUND_HELPER = tempfile.mkstemp(
    prefix='wait-', suffix='.py', dir=FOREGROUND_CONTROL_DIR)
try:
    os.write(FOREGROUND_HELPER_FD,
             b'import os, sys, time\n'
             b'deadline = time.monotonic() + 60\n'
             b'while time.monotonic() < deadline:\n'
             b'    try:\n'
             b'        os.lstat(sys.argv[1])\n'
             b'        break\n'
             b'    except FileNotFoundError:\n'
             b'        time.sleep(0.02)\n')
finally:
    os.close(FOREGROUND_HELPER_FD)


def daemon_claim(session):
    """Return one sidecar-authenticated daemon generation."""
    path = os.path.join(stlib.sessions_dir(HOME), session + '.ini')
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode):
            return None
        parser = configparser.ConfigParser()
        with open(path, encoding='utf-8') as stream:
            parser.read_file(stream, source=path)
        pid = parser.getint('session', 'pid')
        identity = parser.get('session', 'pid_identity').strip()
    except (OSError, UnicodeError, ValueError, configparser.Error):
        return None
    if pid <= 1 or not identity or stlib.process_identity(pid) != identity:
        return None
    return pid, identity


def pane_foreground_command(session, pane):
    """Read one live command from the daemon's untruncated CTL_LIST frame."""
    socket_path = os.path.join(stlib.sessions_dir(HOME), session + '.sock')
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.settimeout(2.0)
    try:
        peer.connect(socket_path)
        peer.sendall(stlib.raw_frame(11, -1))
        payload = None
        while True:
            frame = stlib.read_frame(peer, timeout=2.0)
            if frame is None or frame[0] == 43:
                break
            if frame[0] == 42:
                payload = frame[2]
        if payload is None:
            return FOREGROUND_QUERY_FAILED
        offset = 0
        _name, offset = stlib.read_pas_string(payload, offset)
        _profile, offset = stlib.read_pas_string(payload, offset)
        count, _focused, _clients, _desk_w, _desk_h = struct.unpack_from(
            '<iiiii', payload, offset)
        offset += struct.calcsize('<iiiii')
        if pane < 1 or pane > count:
            return FOREGROUND_QUERY_FAILED
        for pane_no in range(1, count + 1):
            _title, offset = stlib.read_pas_string(payload, offset)
            _term, offset = stlib.read_pas_string(payload, offset)
            offset += 1
            _host, offset = stlib.read_pas_string(payload, offset)
            _user, offset = stlib.read_pas_string(payload, offset)
            command, offset = stlib.read_pas_string(payload, offset)
            _cwd, offset = stlib.read_pas_string(payload, offset)
            offset += struct.calcsize('<iiiiiii') + 3
            if pane_no == pane:
                return command
    except (OSError, ValueError, IndexError, struct.error):
        return FOREGROUND_QUERY_FAILED
    finally:
        peer.close()
    return FOREGROUND_QUERY_FAILED


def acquire_test_foreground(session, pane, token, timeout=3.0):
    """Claim authority only after the unique helper is the live foreground."""
    claim = daemon_claim(session)
    stop_path = os.path.join(FOREGROUND_CONTROL_DIR, token + '.stop')

    def owned_helper(command):
        """Accept Python's real post-exec path, but no weaker identity."""
        if command is FOREGROUND_QUERY_FAILED:
            return False
        try:
            argv = shlex.split(command)
        except ValueError:
            return False
        if len(argv) != 4:
            return False
        executable = os.path.basename(argv[0]).lower()
        return (re.fullmatch(r'python(?:3(?:\.\d+)?)?', executable) is not None
                and argv[1:] == [FOREGROUND_HELPER, stop_path, token])

    deadline = time.monotonic() + timeout
    while claim is not None and time.monotonic() < deadline:
        observed = pane_foreground_command(session, pane)
        if (daemon_claim(session) == claim and
                owned_helper(observed)):
            ACTIVE_TEST_FOREGROUNDS[(session, pane)] = (
                claim[0], claim[1], observed, stop_path)
            return True
        time.sleep(0.04)
    return False


def stop_test_foreground(session, pane, timeout=3.0):
    """Stop only the exact helper through its private one-use file."""
    key = (session, pane)
    authority = ACTIVE_TEST_FOREGROUNDS.get(key)
    if authority is None:
        return False
    pid, identity, expected, stop_path = authority
    if daemon_claim(session) != (pid, identity):
        return False
    observed = pane_foreground_command(session, pane)
    if observed is FOREGROUND_QUERY_FAILED or observed != expected:
        return False
    # This cannot race into a later foreground: no byte is sent to the PTY.
    # Only the helper whose exact argv was authenticated polls this private,
    # per-run path, and every invocation has its own one-use token.
    try:
        marker = os.open(stop_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                         0o600)
        os.close(marker)
    except FileExistsError:
        pass
    except OSError:
        return False
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if daemon_claim(session) != (pid, identity):
            return False
        observed = pane_foreground_command(session, pane)
        if observed is FOREGROUND_QUERY_FAILED:
            time.sleep(0.04)
            continue
        if observed != expected:
            del ACTIVE_TEST_FOREGROUNDS[key]
            try:
                os.unlink(stop_path)
            except FileNotFoundError:
                pass
            return True
        time.sleep(0.04)
    return False


def track_client(client):
    KNOWN_CLIENT_PIDS.add(client.pid)
    TRACKED_CLIENTS[client.pid] = client
    return client


def untrack_client(client):
    TRACKED_CLIENTS.pop(client.pid, None)


def cleanup_tracked_clients():
    """Bounded exception-path cleanup; never touch an external daemon."""
    # exact_round deliberately holds one test-owned helper in each pane. If
    # fail-fast aborts after acquisition, release only those helpers through
    # their private files before detaching our UIs. No cleanup byte is ever
    # written to an external session's PTY.
    for session, pane in sorted(ACTIVE_TEST_FOREGROUNDS):
        try:
            stop_test_foreground(session, pane, timeout=2.0)
        except Exception:
            pass
    for client in list(TRACKED_CLIENTS.values()):
        try:
            if client.alive():
                client.send(b'\x11', 0.03)
                client.send(b'd', 0.05)
                client.wait_exit(timeout=1.0)
        except Exception:
            pass
        client.close()
        untrack_client(client)
    # Do not remove a stop marker which a still-running helper has not yet
    # observed. The helper self-expires after 60 seconds; a failed test keeps
    # its tiny private directory as evidence instead of risking interference.
    if not ACTIVE_TEST_FOREGROUNDS:
        try:
            os.unlink(FOREGROUND_HELPER)
        except FileNotFoundError:
            pass
        try:
            os.rmdir(FOREGROUND_CONTROL_DIR)
        except OSError:
            pass


atexit.register(cleanup_tracked_clients)


def detach(client):
    """Detach one UI and prove that its process exited successfully."""
    client.send(b'\x11', 0.12)
    client.send(b'd', 0.35)
    try:
        status = client.wait_exit(timeout=6.0)
    except Exception:
        status = None
    client.close()
    untrack_client(client)
    return status == 0


def cli_retry(args, attempts=30):
    result = None
    for _ in range(attempts):
        result = run_cli(args, HOME, env=DEBUG_ENV, timeout=8)
        if result.returncode == 0:
            return result
        time.sleep(0.05)
    return result


def pane_sizes(session):
    result = run_cli(['list', session], HOME, env=dict(DEBUG_ENV, LANG='C'))
    sizes = []
    for line in result.stdout.splitlines():
        if not line or not line[0].isdigit():
            continue
        for token in line.split():
            if 'x' in token and token[0].isdigit():
                try:
                    sizes.append(tuple(int(v) for v in token.split('x', 1)))
                    break
                except ValueError:
                    pass
    return result.returncode, tuple(sizes)


def pane_flags(session):
    """Return the list command's stable per-pane M/Z/dead flags."""
    result = run_cli(['list', session], HOME, env=dict(DEBUG_ENV, LANG='C'))
    flags = []
    if result.returncode != 0:
        return ()
    for line in result.stdout.splitlines():
        if not line or not line[0].isdigit():
            continue
        last = line.split()[-1]
        flags.append(last if set(last) <= set('*MZ!') else '')
    return tuple(flags)


def split_marker_command(marker):
    """Build output whose complete marker is absent from the echoed input."""
    split = max(1, len(marker) // 2)
    left, right = marker[:split], marker[split:]
    command = ("printf '%s' '" + left + "' '" + right +
               "'; printf '\\n'")
    if marker in command:
        raise AssertionError('marker must not occur in its shell command')
    return command


def session_daemon_pid(session):
    """Return the daemon PID recorded in this session's sidecar."""
    for sock_path in stlib.session_sockets(HOME):
        if os.path.basename(sock_path)[:-5] != session:
            continue
        parser = configparser.ConfigParser()
        try:
            parser.read(sock_path[:-5] + '.ini')
            return parser.getint('session', 'pid', fallback=0)
        except (OSError, configparser.Error, ValueError):
            return 0
    return 0


def process_finished(pid):
    """True when PID is gone, or already a zombie awaiting its parent."""
    if pid <= 0:
        return False
    stat_path = f'/proc/{pid}/stat'
    try:
        with open(stat_path, encoding='ascii', errors='replace') as stream:
            stat = stream.read()
        close_paren = stat.rfind(')')
        if close_paren >= 0 and stat[close_paren + 2:close_paren + 3] == 'Z':
            return True
    except OSError:
        pass
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def wait_process_finished(pid, timeout=15.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process_finished(pid):
            return True
        time.sleep(0.05)
    return process_finished(pid)


def close_daemon_orderly(session, pid):
    """Request CLOSE and wait for this exact daemon, never just a sidecar."""
    session_base = os.path.join(stlib.sessions_dir(HOME), session)
    artifacts = (session_base + '.sock', session_base + '.ini')
    result = run_cli(['kill', session], HOME, env=DEBUG_ENV, timeout=8)
    accepted = result.returncode == 0
    finished = wait_process_finished(pid, timeout=15.0)
    artifact_deadline = time.monotonic() + 2.0
    while (time.monotonic() < artifact_deadline and
           any(os.path.exists(path) for path in artifacts)):
        time.sleep(0.05)
    artifacts_gone = not any(os.path.exists(path) for path in artifacts)
    check('daemon close command accepted', accepted)
    check('daemon PID terminates without escalation', finished)
    check('daemon socket and sidecar are removed', artifacts_gone)
    if not finished:
        # Cleanup is deliberately after recording the failure.  SIGKILL must
        # never be capable of turning a deadlocked daemon into a green test.
        trace_action(f'DAEMON_CLOSE_FORCED pid={pid}')
        stlib.close_all_daemons(HOME)
    return accepted and finished and artifacts_gone


def audit_heap_reports(expected_paths, label):
    """Wait for and validate every report in this run's unique log dir."""
    leak_re = re.compile(
        r'(?m)^\s*(\d+) unfreed memory blocks\s*:\s*(\d+)\s*$')
    corruption_markers = (
        'marked memory at $',
        'error in heap memory list',
        'error in linked list of heap_mem_info',
        'points into invalid memory block',
        'does not point to valid memory block',
        'tail modified after release',
        'changed after call to freemem',
        'should be :',
    )
    report_deadline = time.monotonic() + 8.0
    while time.monotonic() < report_deadline:
        ready = True
        for path in expected_paths:
            try:
                with open(path, encoding='utf-8', errors='replace') as stream:
                    if not leak_re.findall(stream.read()):
                        ready = False
                        break
            except OSError:
                ready = False
                break
        if ready:
            break
        time.sleep(0.05)

    heap_paths = sorted(glob.glob(LOG_HOME + '/heap-*.log'))
    missing = [path for path in expected_paths if path not in heap_paths]
    unfinished = []
    leaked = []
    corrupt = []
    for path in heap_paths:
        try:
            with open(path, encoding='utf-8', errors='replace') as stream:
                heap_text = stream.read()
        except OSError:
            unfinished.append(path)
            continue
        summaries = leak_re.findall(heap_text)
        if not summaries:
            unfinished.append(path)
        elif (int(summaries[-1][0]) != 0 or
              int(summaries[-1][1]) != 0):
            leaked.append((path, summaries[-1]))
        lowered = heap_text.lower()
        if any(marker in lowered for marker in corruption_markers):
            corrupt.append(path)
    if missing:
        print(f'  {label} missing expected reports:', *missing, sep='\n    ')
    if unfinished:
        print(f'  {label} unfinished reports:', *unfinished, sep='\n    ')
    if leaked:
        print(f'  {label} leaking reports:', *leaked, sep='\n    ')
    if corrupt:
        print(f'  {label} corrupt reports:', *corrupt, sep='\n    ')
    check(label + ' reports were produced', bool(heap_paths))
    check(label + ' expected role/PID reports exist', not missing)
    check(label + ' every process finalized', not unfinished)
    check(label + ' reports have zero leaks', not leaked)
    check(label + ' reports have no corruption', not corrupt)
    return heap_paths, unfinished


# Keep the human-facing names short: GEOMETRY_BURST deliberately drives a
# split down to FreeVision's minimum width, where a long title is truncated by
# the close/minimize/number/zoom controls. Normal frames key identity to
# FreeVision's stable one-digit window number at ``right - 6``; minimized
# icons use these unique short titles because they carry no window number.
PANE_TITLES = ('A1', 'B2', 'C3')


def pane_title(pane):
    if pane < 1 or pane > len(PANE_TITLES):
        raise ValueError(f'invalid stress pane number: {pane}')
    return PANE_TITLES[pane - 1]


def geometry(client):
    """Return all observable structural pane perimeters.

    Pane identity and multiplicity live in ``pane_visual_map``; this cell set
    remains useful for exact common-outline comparisons between clients.
    """
    rects = [rect for pane in range(1, 4)
             for rect in pane_frame_rects(client, pane)]
    for pane in range(1, 4):
        rects.extend(pane_icon_rects(client, pane))
    cells = set()
    for rect in rects:
        if rect is None:
            continue
        left, top, right, bottom = rect
        cells.update((top, x) for x in range(left, right + 1))
        cells.update((bottom, x) for x in range(left, right + 1))
        cells.update((y, left) for y in range(top + 1, bottom))
        cells.update((y, right) for y in range(top + 1, bottom))
    return cells


def has_visible_frame(client):
    """At least one real normal/minimized window starts on this screen."""
    return bool(geometry(client))


def pane_icon_rects(client, pane):
    """Return every exact two-row icon carrying this pane's unique title."""
    rows = client.screen.display
    title = pane_title(pane)
    result = []
    for top, row in enumerate(rows):
        if top + 1 >= len(rows):
            continue
        title_at = row.find(title)
        while title_at >= 0:
            lefts = [x for x, char in enumerate(row[:title_at])
                     if char == '┌']
            rights = [x for x, char in enumerate(
                row[title_at + len(title):], title_at + len(title))
                      if char == '┐']
            if lefts and rights:
                left, right = max(lefts), min(rights)
                width = right - left + 1
                title_start = title_at - left
                top_cells = row[left:right + 1]
                # TTermFrame centers the title itself. Its separator clearing
                # may leave two spaces on the left at this even width, so an
                # invented exact dash/space template rejects a genuine icon.
                # Keep the actual invariants strict: one centered title,
                # blank separators, and only line/blank cells around it.
                title_end = title_start + len(title)
                if (width == 26 and title_start == (width - len(title)) // 2 and
                        top_cells[0] == '┌' and top_cells[-1] == '┐' and
                        top_cells.count(title) == 1 and
                        title_start > 1 and title_end < width - 1 and
                        top_cells[title_start - 1] == ' ' and
                        top_cells[title_end] == ' ' and
                        all(char in '─ ' for char in
                            top_cells[1:title_start]) and
                        all(char in '─ ' for char in
                            top_cells[title_end:-1]) and
                        rows[top + 1][left] == '└' and
                        rows[top + 1][right] == '┘' and
                        all(char == '─'
                            for char in rows[top + 1][left + 1:right])):
                    result.append((left, top, right, top + 1))
            title_at = row.find(title, title_at + len(title))
    return tuple(result)


def minimized_icon_rects(client):
    """Return title-identified icons; retained for focused diagnostics."""
    return tuple(rect for pane in range(1, 4)
                 for rect in pane_icon_rects(client, pane))


def locked_pane_frame_rects(client, pane):
    """Return every numbered LOCK frame with structurally bounded edges."""
    rows = client.screen.display
    result = []
    for top, row in enumerate(rows):
        for number_x, char in enumerate(row):
            right = number_x + 6
            if (char != str(pane) or right >= len(row) or
                    row[right] != '▒'):
                continue
            for left in range(number_x - 1, -1, -1):
                if row[left] != '▒':
                    continue
                for bottom in range(top + 2, len(rows)):
                    if not all(cell == '░'
                               for cell in rows[bottom][left:right + 1]):
                        continue
                    left_edge = ''.join(rows[y][left]
                                        for y in range(top + 1, bottom))
                    # TTermScrollBar owns the pane's right-edge interior and
                    # paints after TTermFrame.  A real locked pane therefore
                    # has a shaded right corner and base but may legitimately
                    # carry its active ▲/▓/▼ scrollbar down that edge.  Keep
                    # the other structural anchors exact and accept only that
                    # finite renderer alphabet here.
                    right_edge = ''.join(rows[y][right]
                                         for y in range(top + 1, bottom))
                    if ('LOCK' in left_edge and
                            all(char in '▒▲▼■▓^V'
                                for char in right_edge)):
                        rect = (left, top, right, bottom)
                        if rect not in result:
                            result.append(rect)
                        break
    return tuple(result)


def locked_pane_frame_rect(client, pane):
    """Return the sole LOCK frame, or None when absent or duplicated."""
    rects = locked_pane_frame_rects(client, pane)
    return rects[0] if len(rects) == 1 else None


def pane_frame_tops(client, pane):
    """Return every numbered normal top, including stable ghost copies."""
    rows = client.screen.display
    digit = str(pane)
    result = []
    for top, row in enumerate(rows):
        for right, corner in enumerate(row):
            if corner not in ('╗', '┐') or right < 6:
                continue
            if row[right - 6] != digit:
                continue
            left_corner = '╔' if corner == '╗' else '┌'
            lefts = [x for x, char in enumerate(row[:right])
                     if char == left_corner]
            if not lefts:
                continue
            left = max(lefts)
            edge = (left, top, right)
            if edge not in result:
                result.append(edge)
    return tuple(result)


def pane_frame_top(client, pane):
    """Return one unambiguous normal top, never hide a duplicate frame."""
    tops = pane_frame_tops(client, pane)
    return tops[0] if len(tops) == 1 else None


def normal_pane_frame_rects(client, pane):
    """Return every complete normal frame associated with a numbered top."""
    rows = client.screen.display
    result = []
    for top_edge in pane_frame_tops(client, pane):
        left, top, right = top_edge
        for bottom in range(top + 2, len(rows)):
            # The active frame's scrollbar/grow control may legitimately
            # replace either bottom corner with the passive glyph.
            if (rows[bottom][left] in ('╚', '└') and
                    rows[bottom][right] in ('╝', '┘')):
                rect = (left, top, right, bottom)
                if rect not in result:
                    result.append(rect)
                break
    return tuple(result)


def pane_frame_rects(client, pane):
    """Return every complete normal or locked frame for one pane."""
    return (normal_pane_frame_rects(client, pane) +
            locked_pane_frame_rects(client, pane))


def pane_frame_rect(client, pane):
    """Return one unambiguous complete frame, or None for any duplicate."""
    tops = pane_frame_tops(client, pane)
    normal = normal_pane_frame_rects(client, pane)
    locked = locked_pane_frame_rects(client, pane)
    if len(tops) > 1 or len(normal) > 1 or len(locked) > 1:
        return None
    if tops and locked:
        return None
    rects = normal + locked
    return rects[0] if len(rects) == 1 else None


def frame_origin(client, pane):
    top_edge = pane_frame_top(client, pane)
    return None if top_edge is None else top_edge[:2]


def pane_text(client, pane):
    rect = pane_frame_rect(client, pane)
    if rect is None:
        return ''
    left, top, right, bottom = rect
    return '\n'.join(row[left + 1:right]
                     for row in client.screen.display[top + 1:bottom])


def pane_token_at(client, pane, token, col, row):
    """Check a token at one exact 1-based PTY coordinate in a visible pane."""
    top_edge = pane_frame_top(client, pane)
    if top_edge is None or col < 1 or row < 1:
        return False
    left, top, right = top_edge
    start_x = left + col
    y = top + row
    return (y < len(client.screen.display) and
            start_x + len(token) <= right and
            client.screen.display[y][start_x:start_x + len(token)] == token)


def layout_rects(client):
    """Window geometry only; focus buttons/border style are decoration."""
    return tuple(pane_frame_rect(client, pane) for pane in range(1, 4))


def pane_visual_map(client):
    """Per-pane tops/frames/locks/icons, preserving every visible copy."""
    return tuple((pane_frame_tops(client, pane),
                  normal_pane_frame_rects(client, pane),
                  locked_pane_frame_rects(client, pane),
                  pane_icon_rects(client, pane))
                 for pane in range(1, 4))


def visual_map_matches_flags(visual, flags, active,
                             allow_passthrough=False):
    """Validate rendered pane/icon state against one canonical list result."""
    if len(visual) != 3 or len(flags) != 3:
        return False
    if any('!' in flag for flag in flags):
        # CLI `!` is a dead pane, never a fullscreen marker. A crash must not
        # become a visually valid empty desktop in the stress oracle.
        return False

    visually_empty = all(not tops and not frames and not locks and not icons
                         for tops, frames, locks, icons in visual)
    if (allow_passthrough and visually_empty and active == 0 and
            any('Z' in flag for flag in flags)):
        # Only the explicitly mixed fullscreen burst may legitimately finish with raw
        # passthrough owning the host terminal. CLI list represents both IDE
        # zoom and fullscreen with Z, so callers opt into this visual alternative.
        zoomed_panes = [pane for pane, flag in enumerate(flags, 1)
                        if 'Z' in flag]
        focused_panes = [pane for pane, flag in enumerate(flags, 1)
                         if '*' in flag]
        return (len(zoomed_panes) == 1 and len(focused_panes) == 1 and
                zoomed_panes == focused_panes and
                'M' not in flags[zoomed_panes[0] - 1])

    for pane, ((tops, frames, locks, icons), flag) in enumerate(
            zip(visual, flags), 1):
        if locks or len(tops) > 1 or len(frames) > 1:
            # Stable convergence cannot contain a lease decoration or two
            # independently observable copies of the same numbered window.
            return False
        if 'M' in flag:
            if tops or frames or len(icons) != 1:
                return False
        else:
            if icons:
                return False

    # Z-order can hide a complete ordinary or zoomed pane; canonical `list`
    # proves it exists even when no cell is observable.  At least one normal
    # top must remain visible unless every pane is a valid minimized icon.
    if (not all('M' in flag for flag in flags) and
            not any(tops for tops, _frames, _locks, _icons in visual)):
        return False

    focused_panes = [pane for pane, flag in enumerate(flags, 1)
                     if '*' in flag]
    # Minimize and Minimize all are visibility operations.  A minimized icon
    # intentionally retains the one shared logical focus until an explicit
    # focus/restore action chooses another pane.
    if len(focused_panes) != 1:
        return False
    focused = focused_panes[0]
    if active not in (0, focused):
        return False
    focused_top_visible = (focused > 0 and
                           bool(visual[focused - 1][0]))
    if focused_top_visible and active != focused:
        return False
    return True


def prime_snapshot_tokens(clients, session, number):
    """Put unambiguous content in every pane before a churn attach starts."""
    tokens = []
    sent = True
    for pane in range(1, 4):
        # Must remain contiguous from column 3 in a minimum-width PTY.
        token = f'S{round_code(number)}P{pane}'
        split = len(token) // 2
        # The complete token does not occur in the echoed command.  Only the
        # shell's printf output can satisfy capture/render assertions.
        command = (
            f"S='{token[:split]}''{token[split:]}'; "
            "printf '\\033[2J\\033[2;3H%s\\033[6;7H' \"$S\"")
        result = cli_retry(['send', f'{session}:{pane}', command], attempts=8)
        sent = sent and result is not None and result.returncode == 0
        tokens.append(token)
    check(f'round {number} snapshot tokens submitted', sent)

    deadline = time.monotonic() + 4.0
    captured = [False] * 3
    rendered = False
    while time.monotonic() < deadline:
        drain_all(clients, 0.10)
        for pane, token in enumerate(tokens, 1):
            result = run_cli(['capture', f'{session}:{pane}'], HOME,
                             env=DEBUG_ENV, timeout=8)
            captured[pane - 1] = (result.returncode == 0 and
                                  token in result.stdout)
        rendered = all(
            token in pane_text(viewer, pane)
            for viewer in clients
            for pane, token in enumerate(tokens, 1))
        if all(captured) and rendered:
            break
    check(f'round {number} snapshot tokens canonical', all(captured))
    check(f'round {number} snapshot tokens rendered before attach', rendered)
    require_clean(f'round {number} snapshot priming')
    return tuple(tokens)


def wait_churn_snapshot(churn, tokens, expected_layout, timeout=5.0):
    """Prove the joining client rendered the old snapshot before live I/O."""
    deadline = time.monotonic() + timeout
    raw_tokens = False
    rendered = False
    layout_ok = False
    while time.monotonic() < deadline:
        churn.drain(0.10)
        raw = churn.raw()
        raw_tokens = all(token.encode() in raw for token in tokens)
        rendered = all(
            token in pane_text(churn, pane)
            for pane, token in enumerate(tokens, 1))
        layout_ok = layout_rects(churn) == expected_layout
        if raw_tokens and rendered and layout_ok:
            break
    return raw_tokens, rendered, layout_ok


def locked_panes(client):
    """Return panes carrying SuperTerm's actual LOCK frame decoration.

    Scrollbars legitimately use the same shade glyphs as locked borders, so
    treating any ``░``/``▒`` cell as a lock makes every ordinary pane look
    permanently locked.  Require the stable window number, bounded side
    columns, vertical ``LOCK`` and the exact shaded bottom edge together.
    """
    return {pane for pane in range(1, 4)
            if locked_pane_frame_rects(client, pane)}


def has_lock_marker(client):
    """Recognize both numbered locked frames and unnumbered wireframe rings."""
    rows = client.screen.display
    width = len(rows[0]) if rows else 0
    for x in range(width):
        for y in range(max(0, len(rows) - 3)):
            if ''.join(rows[y + offset][x]
                       for offset in range(4)) == 'LOCK':
                return True
    return False


def wait_unlocked(clients, timeout=3.0):
    """Consume the acquire/release events of short one-shot CLI locks."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        drain_all(clients, 0.12)
        if not any(has_lock_marker(client) for client in clients):
            return True
    return False


def active_panes(client):
    """Return active pane numbers once per visible active frame copy."""
    result = []
    for pane in range(1, 4):
        for left, top, right in pane_frame_tops(client, pane):
            row = client.screen.display[top]
            if row[left] == '╔' and row[right] == '╗':
                result.append(pane)
    return tuple(result)


def active_pane(client):
    panes = active_panes(client)
    if len(panes) == 1:
        return panes[0]
    if panes:
        return -1                 # two active borders are an explicit defect
    return 0


def wait_shared_focus(clients, pane, timeout=3.0):
    started = time.monotonic()
    deadline = started + timeout
    while time.monotonic() < deadline:
        drain_all(clients, 0.10)
        locked = any(locked_panes(client) for client in clients)
        if not locked and all(active_pane(client) == pane
                              for client in clients):
            trace_action(f'FOCUS_SYNC pane={pane} '
                         f'latency={time.monotonic() - started:.4f}')
            return True
    active = [active_pane(client) for client in clients]
    trace_action(f'FOCUS_TIMEOUT pane={pane} active={active}')
    stamp = int(time.time() * 1000)
    for client_no, client in enumerate(clients, 1):
        path = (f'{LOG_HOME}/focus-timeout-{stamp}-pane{pane}-'
                f'client{client_no}.txt')
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write(f'expected={pane} active={active[client_no - 1]} '
                     f'cursor={client.screen.cursor.x},'
                     f'{client.screen.cursor.y}\n')
            fh.write('\n'.join(client.screen.display))
            fh.write('\n')
    if 'SESSION' in globals() and SESSION:
        listed = run_cli(['list', SESSION], HOME,
                         env=dict(DEBUG_ENV, LANG='C'), timeout=8)
        compact = ' | '.join(line.strip() for line in
                             listed.stdout.splitlines() if line.strip())
        trace_action(f'FOCUS_TIMEOUT_DAEMON rc={listed.returncode} '
                     f'list={compact!r}')
    return False


def wait_shared_pane_state(clients, pane, predicate, timeout=3.0):
    """Wait for one exact pane state and complete geometry on every PTY."""
    deadline = time.monotonic() + timeout
    rects = [pane_frame_rect(client, pane) for client in clients]
    while time.monotonic() < deadline:
        if (predicate(rects) and
                all(geometry(client) == geometry(clients[0])
                    for client in clients[1:])):
            return rects
        drain_all(clients, 0.05)
        rects = [pane_frame_rect(client, pane) for client in clients]
    return rects


def unit_path(start, finish):
    """Every adjacent mouse point differs by at most one terminal cell."""
    x, y = start
    ex, ey = finish
    result = [(x, y)]
    while (x, y) != (ex, ey):
        if x < ex:
            x += 1
        elif x > ex:
            x -= 1
        if y < ey:
            y += 1
        elif y > ey:
            y -= 1
        result.append((x, y))
    return result


def expand_unit_path(points):
    result = []
    for start, finish in zip(points, points[1:]):
        segment = unit_path(start, finish)
        if result:
            segment = segment[1:]
        result.extend(segment)
    return result or list(points)


def mouse_drag(client, start, finish, steps=None, pause=0.025):
    """Perform a real FreeVision drag through every intermediate cell."""
    points = unit_path(start, finish)
    sx, sy = points[0]
    ex, ey = points[-1]
    trace_action(f'MOUSE_DRAG pid={client.pid} from={start} to={finish} '
                 f'steps={len(points) - 1}')
    stlib.write_all(client.fd, f'\x1b[<0;{sx + 1};{sy + 1}M'.encode())
    time.sleep(pause)
    for x, y in points[1:]:
        stlib.write_all(client.fd, f'\x1b[<32;{x + 1};{y + 1}M'.encode())
        time.sleep(pause)
    stlib.write_all(client.fd, f'\x1b[<0;{ex + 1};{ey + 1}m'.encode())


def slow_mouse_path(clients, actor, points, label, pane=1,
                    step_pause=VISIBLE_STEP_PAUSE):
    """Hold one real mouse gesture long enough to observe its pane lock."""
    points = expand_unit_path(points)
    if len(points) < 2:
        return False
    sx, sy = points[0]
    trace_action(f'VISUAL_BEGIN label={label} actor={actor.pid} pane={pane} '
                 f'points={len(points)} step_pause={step_pause:.3f} '
                 f'from={points[0]} to={points[-1]}')
    stlib.write_all(actor.fd, f'\x1b[<0;{sx + 1};{sy + 1}M'.encode())
    lock_seen = False
    # The lease is acquired before FreeVision enters DragView. Sample that
    # real locked frame before the first motion: in wireframe mode motion then
    # hides it and replaces it with an intentionally unnumbered outline.
    drain_all(clients, step_pause)
    for viewer in clients:
        if viewer is not actor:
            lock_seen = lock_seen or pane in locked_panes(viewer)
    marker = f'K{label[0]}{pane}'
    marker_result = None
    for step, (x, y) in enumerate(points[1:], 1):
        stlib.write_all(actor.fd, f'\x1b[<32;{x + 1};{y + 1}M'.encode())
        drain_all(clients, step_pause)
        for viewer in clients:
            if viewer is actor:
                continue
            lock_seen = lock_seen or pane in locked_panes(viewer)
        if step == len(points) // 2:
            # PTY input remains live while only layout mutation is owned.
            marker_result = cli_retry(
                ['send', f'{SESSION}:{pane}', split_marker_command(marker)],
                attempts=8)
    ex, ey = points[-1]
    stlib.write_all(actor.fd, f'\x1b[<0;{ex + 1};{ey + 1}m'.encode())
    drain_all(clients, 0.45)
    unlocked = wait_unlocked(clients, timeout=3.0)
    trace_action(f'VISUAL_END label={label} lock_seen={int(lock_seen)} '
                 f'unlocked={int(unlocked)}')
    check(f'{label} visible shaded LOCK', lock_seen)
    check(f'{label} unlock after mouse release', unlocked)
    marker_submitted = (marker_result is not None and
                        marker_result.returncode == 0)
    marker_canonical = False
    marker_rendered = False
    marker_deadline = time.monotonic() + 4.0
    while time.monotonic() < marker_deadline:
        drain_all(clients, 0.10)
        capture = run_cli(['capture', f'{SESSION}:{pane}'], HOME,
                          env=DEBUG_ENV, timeout=8)
        marker_canonical = (capture.returncode == 0 and
                            marker in capture.stdout)
        marker_rendered = all(marker in pane_text(client, pane)
                              for client in clients)
        if marker_canonical and marker_rendered:
            break
    check(f'{label} lock-time PTY marker submitted', marker_submitted)
    check(f'{label} lock-time PTY marker canonical', marker_canonical)
    check(f'{label} lock-time PTY marker rendered', marker_rendered)
    return (lock_seen and unlocked and marker_submitted and
            marker_canonical and marker_rendered)


def slow_visual_resize(clients, session, cycle):
    """Resize pane 1 cell by cell for about two seconds."""
    restore_and_tile(clients, session)
    focused = cli_retry(['focus', f'{session}:1'], attempts=8)
    check(f'visual resize {cycle} focus accepted',
          focused is not None and focused.returncode == 0)
    drain_all(clients, 0.5)
    rect = pane_frame_rect(clients[0], 1)
    check(f'visual resize {cycle} frame found', rect is not None)
    if rect is None:
        require_clean(f'visual resize {cycle} frame lookup')
        return
    left, top, right, bottom = rect
    if cycle % 2 == 0:
        target = (max(left + 24, right - 30),
                  max(top + 9, bottom - 10))
    else:
        target = (min(clients[0].w - 3, right + 30),
                  min(clients[0].h - 3, bottom + 10))
    gesture_ok = slow_mouse_path(
        clients, clients[cycle % len(clients)],
        unit_path((right, bottom), target), f'RESIZE_{cycle}', pane=1)
    final_rects = wait_shared_pane_state(
        clients, 1,
        lambda values: all(rect is not None and
                           rect[0] == left and rect[1] == top and
                           rect[2:] == target for rect in values))
    check(f'visual resize {cycle} reaches exact shared rectangle',
          all(rect is not None and
              rect[0] == left and rect[1] == top and
              rect[2:] == target for rect in final_rects))
    if not gesture_ok:
        trace_action(f'VISUAL_ORACLE label=RESIZE_{cycle} '
                     'gesture-invariants-failed independently-of-geometry')
    require_clean(f'visual resize {cycle}')


def slow_visual_circle(clients, session, cycle):
    """Keep one window-move lock throughout a complete visible orbit."""
    restored = cli_retry(['restore', f'{session}:1'], attempts=8)
    focused = cli_retry(['focus', f'{session}:1'], attempts=8)
    check(f'visual circle {cycle} restore accepted',
          restored is not None and restored.returncode == 0)
    check(f'visual circle {cycle} focus accepted',
          focused is not None and focused.returncode == 0)
    drain_all(clients, 0.5)
    rect = pane_frame_rect(clients[0], 1)
    check(f'visual circle {cycle} frame found', rect is not None)
    if rect is None:
        require_clean(f'visual circle {cycle} frame lookup')
        return
    left, top, right, bottom = rect
    width = right - left + 1
    height = bottom - top + 1
    max_left = max(0, clients[0].w - width)
    max_top = max(1, clients[0].h - 1 - height)
    center_x = max_left // 2
    center_y = 1 + max(0, max_top - 1) // 2
    radius_x = max(1, max_left // 2 - 2)
    radius_y = max(1, max(0, max_top - 1) // 2 - 1)
    grab = min(8, max(2, width - 3))
    points = [(left + grab, top)]
    phase = RNG.random() * 2.0 * math.pi
    direction = -1 if RNG.randrange(2) else 1
    for step in range(1, 37):
        angle = phase + direction * 2.0 * math.pi * step / 36.0
        new_left = center_x + round(radius_x * math.cos(angle))
        new_top = center_y + round(radius_y * math.sin(angle))
        points.append((new_left + grab, new_top))
    gesture_ok = slow_mouse_path(
        clients, clients[(cycle + 1) % len(clients)], points,
        f'CIRCLE_SLOW_{cycle}', pane=1)
    expected = (points[-1][0] - grab, points[-1][1],
                points[-1][0] - grab + width - 1,
                points[-1][1] + height - 1)
    final_rects = wait_shared_pane_state(
        clients, 1,
        lambda values: all(rect == expected for rect in values))
    check(f'visual circle {cycle} reaches exact shared rectangle',
          all(rect == expected for rect in final_rects))
    if not gesture_ok:
        trace_action(f'VISUAL_ORACLE label=CIRCLE_SLOW_{cycle} '
                     'gesture-invariants-failed independently-of-geometry')
    require_clean(f'visual circle {cycle}')


def held_fullscreen(clients, session, cycle):
    """Leave fullscreen on screen long enough for a human to inspect."""
    pane = cycle % 3 + 1
    restored = cli_retry(['restore', f'{session}:{pane}'], attempts=8)
    focused = cli_retry(['focus', f'{session}:{pane}'], attempts=8)
    check(f'fullscreen {cycle} restore accepted',
          restored is not None and restored.returncode == 0)
    check(f'fullscreen {cycle} focus accepted',
          focused is not None and focused.returncode == 0)
    check(f'fullscreen {cycle} focus reaches every client',
          focused is not None and focused.returncode == 0 and
          wait_shared_focus(clients, pane))
    require_clean(f'fullscreen {cycle} focus')
    drain_all(clients, 0.45)
    actor = clients[(cycle + 2) % len(clients)]
    before = layout_rects(clients[0])
    trace_action(f'VISUAL_BEGIN label=F5_{cycle} actor={actor.pid} '
                 f'pane={pane} hold=0.8')
    stlib.write_all(actor.fd, stlib.FULLSCREEN_CHORD)
    drain_all(clients, 0.8)
    during = [layout_rects(client) for client in clients]
    # All stress viewers use CLIENT_W x CLIENT_H. Client count must not force
    # an equal-size set through the cell renderer: raw fullscreen has no IDE frame in
    # any client. The focal passthrough test checks the exact OSC byte path;
    # here the stress oracle checks simultaneous shared state and liveness.
    check(f'fullscreen {cycle} enters raw mode in every client',
          before[pane - 1] is not None and
          all(all(rect is None for rect in rects) for rects in during) and
          all('Detach' not in client.text() for client in clients))
    check(f'fullscreen {cycle} clients remain alive', all(c.alive() for c in clients))
    stlib.write_all(actor.fd, stlib.FULLSCREEN_CHORD)
    drain_all(clients, 0.6)
    check(f'fullscreen {cycle} restores exact shared geometry',
          all(layout_rects(client) == before for client in clients))
    trace_action(f'VISUAL_END label=F5_{cycle}')
    require_clean(f'fullscreen {cycle}')


def circle_window(clients, session, cycles=1, step_pause=0.20):
    """Move pane 1 around a precomputed ellipse and prove convergence."""
    local_focus(clients[0], 1)
    drain_all(clients, 0.5)
    rect = pane_frame_rect(clients[0], 1)
    check('circle source frame found', rect is not None)
    if rect is None:
        return

    # First make the pane small enough to have useful travel in both axes.
    left, top, right, bottom = rect
    desired_right = min(clients[0].w - 4, left + 43)
    desired_bottom = min(clients[0].h - 3, top + 15)
    mouse_drag(clients[0], (right, bottom),
               (desired_right, desired_bottom), steps=7)
    resized_rects = wait_shared_pane_state(
        clients, 1,
        lambda values: all(value is not None and
                           value[2] - value[0] + 1 <= 45 and
                           value[3] - value[1] + 1 <= 17
                           for value in values))
    rect = resized_rects[0]
    resized_ok = all(value is not None and
                     value[2] - value[0] + 1 <= 45 and
                     value[3] - value[1] + 1 <= 17
                     for value in resized_rects)
    check('circle pane resized for travel', resized_ok)
    if not resized_ok:
        return

    width = rect[2] - rect[0] + 1
    height = rect[3] - rect[1] + 1
    max_left = clients[0].w - width
    max_top = clients[0].h - 1 - height
    center_x = max_left // 2
    center_y = 1 + max(0, max_top - 1) // 2
    radius_x = max(2, min(center_x - 1, max_left - center_x - 1))
    radius_y = max(1, min(center_y - 2, max_top - center_y - 1))
    points = []
    for step in range(12):
        angle = 2.0 * math.pi * step / 12.0
        point = (center_x + round(radius_x * math.cos(angle)),
                 center_y + round(radius_y * math.sin(angle)))
        if not points or point != points[-1]:
            points.append(point)
    phase = RNG.randrange(len(points))
    points = points[phase:] + points[:phase]
    if RNG.randrange(2):
        points.reverse()
    trace_action(f'CIRCLE points={points} cycles={cycles}')

    for cycle in range(cycles):
        for point_no, target in enumerate(points):
            rect = pane_frame_rect(clients[0], 1)
            if rect is None:
                check(f'circle {cycle}.{point_no} source remains visible', False)
                return
            grab_offset = min(8, rect[2] - rect[0] - 2)
            start = (rect[0] + grab_offset, rect[1])
            finish = (target[0] + grab_offset, target[1])
            mouse_drag(clients[cycle % len(clients)], start, finish,
                       steps=6, pause=max(0.015, step_pause / 4.0))
            actual_rects = wait_shared_pane_state(
                clients, 1,
                lambda values, target=target: all(
                    item is not None and item[:2] == target
                    for item in values))
            at_target = all(item is not None and item[:2] == target
                            for item in actual_rects)
            check(f'circle {cycle}.{point_no} exact shared position',
                  at_target)
            check(f'circle {cycle}.{point_no} shared complete geometry',
                  all(geometry(client) == geometry(clients[0])
                      for client in clients[1:]))
            check(f'circle {cycle}.{point_no} valid cursors', all(
                  0 <= client.screen.cursor.x < client.w and
                  0 <= client.screen.cursor.y < client.h
                  for client in clients))

            # Exercise ordered PTY input/output while the layout travels.
            marker = f'CIRCLE_{cycle}_{point_no}'
            command = ("printf '\\033[2J\\033[4;6H'; " +
                       split_marker_command(marker))
            submitted = run_cli(['send', session + ':1', command], HOME,
                                env=DEBUG_ENV, timeout=8)
            captured = ''
            rendered = False
            marker_deadline = time.monotonic() + 3.0
            while time.monotonic() < marker_deadline:
                drain_all(clients, 0.08)
                capture = run_cli(['capture', session + ':1'], HOME,
                                  env=DEBUG_ENV, timeout=8)
                captured = capture.stdout if capture.returncode == 0 else ''
                rendered = all(marker in pane_text(client, 1)
                               for client in clients)
                if marker in captured and rendered:
                    break
            check(f'circle {cycle}.{point_no} marker submitted',
                  submitted.returncode == 0)
            check(f'circle {cycle}.{point_no} marker canonical',
                  marker in captured)
            check(f'circle {cycle}.{point_no} marker rendered', rendered)
            require_clean(f'circle {cycle}.{point_no}')


def local_focus(client, pane):
    client.send(b'\x1b' + str(pane).encode(), 0.35)


def exact_round(clients, session, number, extra=None):
    """Write from different clients, then verify precomputed cells/cursors."""
    viewers = clients + ([extra] if extra is not None else [])
    target_row = 3 + number % 2
    target_col = 4 + number % 5
    cursor_row = 8 + number % 2
    cursor_col = 12 + number % 4
    tokens = []
    foreground_tokens = []
    for pane, client in enumerate(clients, 1):
        # Seven cells: fits at the worst target column 8 in 14 PTY columns.
        token = f'R{round_code(number)}C{pane}P{pane}'
        tokens.append(token)
        foreground_token = f'STFG_{SEED:X}_{number}_{pane}'
        foreground_tokens.append(foreground_token)
        split = len(token) // 2
        # Give every platform an unambiguous terminal foreground process
        # group.  The stress oracle is about exact ownership and safe cleanup,
        # not about Linux's optional procfs wait-state fallback.
        command = (f"set -m; S='{token[:split]}''{token[split:]}'; "
                   f"printf '\\033[2J\\033[{target_row};{target_col}H%s"
                   f"\\033[{cursor_row};{cursor_col}H' \"$S\"; "
                   f"'{sys.executable}' '{FOREGROUND_HELPER}' "
                   f"'{os.path.join(FOREGROUND_CONTROL_DIR, foreground_token + '.stop')}' "
                   f"'{foreground_token}'\r")
        # Focus is one shared channel. Let every viewer consume it before this
        # actor types; otherwise a focus event from a different client may
        # legitimately win between Alt-N and a later key. Different clients
        # still drive the three panes and the three foreground sleeps overlap.
        actor = clients[(pane + number - 1) % len(clients)]
        focus_result = cli_retry(['focus', f'{session}:{pane}'])
        check(f'round {number} select exact pane {pane}',
              focus_result is not None and focus_result.returncode == 0)
        check(f'round {number} exact focus sync {pane}',
              wait_shared_focus(viewers, pane))
        require_clean(f'round {number} exact pane {pane} focus')
        # A preceding mixed fullscreen/menu burst may enter passthrough before
        # another client's ``Esc w r`` reaches the FIFO. In that ordering the
        # final ``r`` is pane input and remains on bash's unfinished command
        # line. Clear such deliberately generated typeahead before using an
        # assignment as an exact-output oracle; otherwise ``rS=...`` executes
        # and prints the value of an older S variable, falsely reporting lost
        # input after a zero-viewer reattach.
        stlib.write_all(actor.fd, b'\x03')
        drain_all(viewers, 0.15)
        trace_action(f'EXACT round={number} pane={pane} actor={actor.pid} '
                     f'token={token} cell={target_row},{target_col} '
                     f'cursor={cursor_row},{cursor_col}')
        stlib.write_all(actor.fd, command.encode())
        drain_all(viewers, 0.35)
    drain_all(viewers, 0.9)
    check(f'round {number} exact locks released', wait_unlocked(viewers))

    def token_at(viewer, pane, token):
        origin = frame_origin(viewer, pane)
        if origin is None:
            return False
        x, y = origin
        row = y + target_row
        col = x + target_col
        return (0 <= row < viewer.h and
                viewer.screen.display[row][col:col + len(token)] == token)

    visible_started = time.monotonic()
    visible_deadline = visible_started + 4.0
    while time.monotonic() < visible_deadline:
        if all(token_at(viewer, pane, token)
               for pane, token in enumerate(tokens, 1)
               for viewer in viewers):
            break
        drain_all(viewers, 0.10)
    trace_action(f'EXACT_VISIBLE round={number} '
                 f'latency={time.monotonic() - visible_started:.4f}')

    for pane, token in enumerate(tokens, 1):
        captured = run_cli(['capture', f'{session}:{pane}'], HOME,
                           env=DEBUG_ENV, timeout=8).stdout
        check(f'round {number} canonical pane {pane}', token in captured)
        for viewer_no, viewer in enumerate(viewers, 1):
            check(f'round {number} P{pane} visible C{viewer_no}',
                  token_at(viewer, pane, token))
        check(f'round {number} owns exact foreground {pane}',
              acquire_test_foreground(
                  session, pane, foreground_tokens[pane - 1]))
    if extra is not None:
        check(f'round {number} churn renders every live exact token',
              all(token_at(extra, pane, token)
                  for pane, token in enumerate(tokens, 1)))
    require_clean(f'round {number} exact text placement')

    # Cycle the one shared focus and precompute the exact host cursor for every
    # pane. Every viewer must follow each focus and expose the same cursor.
    for pane in range(1, 4):
        focus_result = cli_retry(['focus', f'{session}:{pane}'])
        check(f'round {number} select cursor pane {pane}',
              focus_result is not None and focus_result.returncode == 0)
        check(f'round {number} cursor focus sync {pane}',
              wait_shared_focus(viewers, pane))
        require_clean(f'round {number} cursor pane {pane} focus')
        drain_all(viewers, 0.15)
        for viewer_no, viewer in enumerate(viewers, 1):
            origin = frame_origin(viewer, pane)
            expected = None if origin is None else (
                origin[0] + cursor_col, origin[1] + cursor_row)
            actual = (viewer.screen.cursor.x, viewer.screen.cursor.y)
            check(f'round {number} focus P{pane} cursor C{viewer_no}',
                  actual == expected)
            if viewer is extra:
                check(f'round {number} churn cursor exact P{pane}',
                      actual == expected)
        require_clean(f'round {number} cursor pane {pane} placement')
        # Stop the exact helper through its private channel. No input is ever
        # sent to the shared PTY, so a later foreground cannot be interrupted.
        check(f'round {number} stops exact foreground {pane}',
              stop_test_foreground(session, pane))
        drain_all(viewers, 0.15)
    drain_all(viewers, 0.45)


def ordered_shared_input_burst(clients, session, number, extra=None):
    """All clients type concurrently into the one shared focused pane."""
    viewers = clients + ([extra] if extra is not None else [])
    pane = RNG.randrange(1, 4)
    actor = RNG.choice(clients)
    focus_result = cli_retry(['focus', f'{session}:{pane}'])
    check(f'round {number} select ordered pane',
          focus_result is not None and focus_result.returncode == 0)
    check(f'round {number} ordered focus sync',
          wait_shared_focus(viewers, pane))
    require_clean(f'round {number} ordered focus')
    drain_all(viewers, 0.20)

    # Non-canonical cat makes every byte visible immediately while retaining
    # ISIG so Ctrl-C can stop it afterward. A canonical reader plus a newline
    # from another client is not a valid ordering test: that newline may
    # overtake bytes still queued on a different client socket.
    ready = f'Q{number & 0xff:02X}R'
    done = f'E{number & 0xff:02X}S'
    ready_split = len(ready) // 2
    done_split = len(done) // 2
    reader_command = (
        "R='" + ready[:ready_split] + "''" + ready[ready_split:] + "'; "
        "stty -icanon -echo; "
        "printf '\\033[2J\\033[2;3H%s' \"$R\"; "
        "cat\r")
    done_command = (
        "stty sane; D='" + done[:done_split] + "''" +
        done[done_split:] + "'; printf '\\033[4;3H%s' \"$D\"\r")
    # Neither sentinel occurs in either echoed shell command. Only execution
    # around `stty`/`cat` can satisfy the two synchronization points.
    if (ready in reader_command or done in reader_command or
            done in done_command):
        raise AssertionError('reader sentinels must be split in the command')
    stlib.write_all(actor.fd, reader_command.encode('ascii'))
    ready_capture = ''
    ready_rendered = False
    ready_deadline = time.monotonic() + 4.0
    while time.monotonic() < ready_deadline:
        drain_all(viewers, 0.10)
        ready_capture = run_cli(
            ['capture', f'{session}:{pane}'], HOME,
            env=DEBUG_ENV, timeout=8).stdout
        ready_rendered = all(pane_token_at(
            viewer, pane, ready, 3, 2) for viewer in viewers)
        if ready in ready_capture and ready_rendered:
            break
    check(f'round {number} raw reader ready',
          ready in ready_capture and ready_rendered)
    require_clean(f'round {number} raw reader startup')
    count = 6 + number % 4
    # Each writer owns a disjoint alphabet.  Its projection must remain
    # ordered, but no cross-client ordering is asserted because simultaneous
    # writes have no externally observable "correct" winner.
    alphabets = ('@%', '#&', '$*')
    payloads = [(alphabet * count).encode('ascii')
                for alphabet in alphabets]
    barrier = threading.Barrier(len(clients) + 1)
    write_results = [None] * len(clients)

    def concurrent_write(index):
        try:
            barrier.wait(timeout=3.0)
            write_results[index] = stlib.write_all(
                clients[index].fd, payloads[index])
        except Exception as exc:  # asserted by the coordinating thread
            write_results[index] = exc

    writers = [threading.Thread(target=concurrent_write, args=(index,))
               for index in range(len(clients))]
    trace_action(f'INPUT_BURST round={number} pane={pane} actor={actor.pid} '
                 f'concurrent=1 count={count}')
    for writer in writers:
        writer.start()
    barrier.wait(timeout=3.0)
    for writer in writers:
        writer.join(timeout=3.0)
    check(f'round {number} concurrent writers finish',
          all(not writer.is_alive() for writer in writers))
    for idx, (result, payload) in enumerate(zip(write_results, payloads), 1):
        check(f'round {number} client {idx} writes complete burst',
              result == len(payload))
    captured = ''
    burst_started = time.monotonic()
    burst_deadline = burst_started + 4.0
    while time.monotonic() < burst_deadline:
        drain_all(viewers, 0.12)
        captured = run_cli(['capture', f'{session}:{pane}'], HOME,
                           env=DEBUG_ENV, timeout=8).stdout
        if all(captured.count(symbol) == count for alphabet in alphabets
               for symbol in alphabet):
            break
    wire_alphabet = ''.join(alphabets)
    wire = ''.join(ch for ch in captured if ch in wire_alphabet)
    trace_action(f'INPUT_VISIBLE round={number} '
                 f'latency={time.monotonic() - burst_started:.4f} '
                 f'counts={[captured.count(symbol) for alphabet in alphabets for symbol in alphabet]}')
    check(f'round {number} complete concurrent FIFO stream',
          len(wire) == sum(len(payload) for payload in payloads))
    for idx, alphabet in enumerate(alphabets, 1):
        projection = ''.join(ch for ch in wire if ch in alphabet)
        check(f'round {number} client {idx} FIFO projection',
              projection == alphabet * count)
    render_deadline = time.monotonic() + 4.0
    rendered = False
    while time.monotonic() < render_deadline:
        drain_all(viewers, 0.10)
        rendered = all(
            all(pane_text(viewer, pane).count(symbol) == count
                for alphabet in alphabets for symbol in alphabet)
            for viewer in viewers)
        if rendered:
            break
    for viewer_no, viewer in enumerate(viewers, 1):
        text = pane_text(viewer, pane)
        check(f'round {number} ordered output C{viewer_no}',
              all(text.count(symbol) == count
                  for alphabet in alphabets for symbol in alphabet))
    if extra is not None:
        text = pane_text(extra, pane)
        check(f'round {number} churn renders complete live FIFO output',
              all(text.count(symbol) == count
                  for alphabet in alphabets for symbol in alphabet))
    stlib.write_all(actor.fd, b'\x03')
    drain_all(viewers, 0.15)
    # Send restoration as a fresh shell command. If cat were still alive it
    # would only render the split literals; the complete sentinel can appear
    # at the exact cell only after the shell executes `stty sane`.
    stlib.write_all(actor.fd, done_command.encode('ascii'))
    done_capture = ''
    done_rendered = False
    done_deadline = time.monotonic() + 4.0
    while time.monotonic() < done_deadline:
        drain_all(viewers, 0.10)
        done_capture = run_cli(['capture', f'{session}:{pane}'], HOME,
                               env=DEBUG_ENV, timeout=8).stdout
        done_rendered = all(pane_token_at(
            viewer, pane, done, 3, 4) for viewer in viewers)
        if done in done_capture and done_rendered:
            break
    check(f'round {number} raw reader exits and restores tty',
          done in done_capture and done_rendered)
    require_clean(f'round {number} raw reader shutdown')


def restore_and_tile(clients, session):
    # Clear any shared fullscreen/minimize/zoom state, then tile from a real
    # attached client. CLI operations retry rather than wait on a pane lock.
    for pane in range(1, 4):
        result = cli_retry(['restore', f'{session}:{pane}'])
        check(f'restore pane {pane} after burst',
              result is not None and result.returncode == 0)
    tiled = cli_retry(['organize', session, 'tile'], attempts=12)
    check('canonical tile after burst',
          tiled is not None and tiled.returncode == 0)
    drain_all(clients, 0.9)
    rects = [layout_rects(client) for client in clients]
    if not all(all(rect is not None for rect in client_rects)
               for client_rects in rects):
        print('  restore/tile client layouts:', rects)
        for viewer_index, client in enumerate(clients, 1):
            with open(os.path.join(
                    LOG_HOME, f'restore-tile-viewer-{viewer_index}.txt'),
                    'w', encoding='utf-8') as fh:
                fh.write('\n'.join(client.screen.display))
                fh.write('\n')
    check('canonical tile is visible in every client', all(
        all(rect is not None for rect in client_rects)
        for client_rects in rects))
    require_clean('restore and tile')


def live_stress(clients, session, seconds):
    """Visible deterministic coverage followed by reproducible random load."""
    deadline = time.monotonic() + seconds
    action = 0

    def assert_converged(label, allow_passthrough=False):
        """Require one unlocked geometry/focus state, not mere survival."""
        unlocked = wait_unlocked(clients, timeout=3.0)
        converged = False
        layouts = []
        signatures = []
        visuals = []
        active = []
        flags = ()
        state_deadline = time.monotonic() + 3.0
        while time.monotonic() < state_deadline:
            drain_all(clients, 0.10)
            # Layout/flags may still be queued after a concurrent burst. A
            # single pre-loop snapshot can remain obsolete for the full wait
            # and manufacture either a pass or a timeout.
            flags = pane_flags(session)
            layouts = [layout_rects(client) for client in clients]
            signatures = [geometry(client) for client in clients]
            visuals = [pane_visual_map(client) for client in clients]
            active = [active_pane(client) for client in clients]
            converged = (all(layout == layouts[0] for layout in layouts[1:])
                         and all(sig == signatures[0]
                                 for sig in signatures[1:])
                         and all(visual == visuals[0]
                                 for visual in visuals[1:])
                         and all(pane_no == active[0]
                                 for pane_no in active[1:])
                         and all(visual_map_matches_flags(
                             visual, flags, pane_no, allow_passthrough)
                             for visual, pane_no in zip(visuals, active)))
            if converged:
                break
        if not converged:
            stamp = int(time.time() * 1000)
            trace_action(
                f'CONVERGENCE_TIMEOUT label={label!r} flags={flags!r} '
                f'layouts={layouts!r} visuals={visuals!r} '
                f'active={active!r} '
                f'geometry_sizes={[len(value) for value in signatures]!r}')
            for client_no, client in enumerate(clients, 1):
                path = (f'{LOG_HOME}/convergence-timeout-{stamp}-'
                        f'client{client_no}.txt')
                with open(path, 'w', encoding='utf-8') as output:
                    output.write(f'label={label!r}\nflags={flags!r}\n')
                    output.write(f'layout={layouts[client_no - 1]!r}\n')
                    output.write(f'visual={visuals[client_no - 1]!r}\n')
                    output.write(f'active={active[client_no - 1]!r}\n')
                    output.write('display:\n')
                    output.write('\n'.join(client.screen.display))
                    output.write('\n')
        cursors_valid = all(
            0 <= client.screen.cursor.x < client.w and
            0 <= client.screen.cursor.y < client.h
            for client in clients)
        check(label + ' locks released', unlocked)
        check(label + ' shared geometry/layout/focus converges', converged)
        check(label + ' cursors remain valid', cursors_valid)
        require_clean(label + ' convergence')
        return unlocked and converged and cursors_valid

    def perform(op, pane):
        nonlocal action
        action += 1
        label = f'live {action} {op}'
        trace_action(f'LIVE action={action} op={op} pane={pane}')
        if op in ('focus', 'zoom', 'restore', 'minimize'):
            result = cli_retry([op, f'{session}:{pane}'], attempts=8)
            accepted = result is not None and result.returncode == 0
            check(label + ' accepted', accepted)
            if op == 'focus':
                check(label + ' reaches every client',
                      accepted and wait_shared_focus(clients, pane))
            flags = pane_flags(session)
            flags_ok = len(flags) == 3
            if flags_ok and op == 'zoom':
                flags_ok = 'Z' in flags[pane - 1]
            elif flags_ok and op == 'minimize':
                flags_ok = 'M' in flags[pane - 1]
            elif flags_ok and op == 'restore':
                flags_ok = not any(ch in flags[pane - 1] for ch in 'MZ')
            if op != 'focus':
                check(label + ' canonical flag', flags_ok)
        elif op in ('tile', 'cascade'):
            result = cli_retry(['organize', session, op], attempts=8)
            accepted = result is not None and result.returncode == 0
            check(label + ' accepted', accepted)
            flags = pane_flags(session)
            check(label + ' restores three normal panes',
                  len(flags) == 3 and
                  not any(any(ch in flag for ch in 'MZ') for flag in flags))
        elif op == 'input':
            # Establish a visible common target, then prove focus before using
            # a direct CLI pane address. Otherwise the marker could pass while
            # client-side focus propagation was broken.
            restore_and_tile(clients, session)
            focused = cli_retry(['focus', f'{session}:{pane}'], attempts=8)
            focus_ok = focused is not None and focused.returncode == 0
            check(label + ' target focused', focus_ok)
            check(label + ' focus reaches every client',
                  focus_ok and wait_shared_focus(clients, pane))
            check(label + ' target visible', all(
                pane_frame_rect(client, pane) is not None
                for client in clients))
            marker = f'L{action:02x}P{pane}'
            command = ("printf '\\033[2J\\033[4;6H'; " +
                       split_marker_command(marker))
            result = cli_retry(['send', f'{session}:{pane}', command],
                               attempts=8)
            check(label + ' accepted',
                  result is not None and result.returncode == 0)
            visible_deadline = time.monotonic() + 3.0
            captured = ''
            rendered = False
            while time.monotonic() < visible_deadline:
                drain_all(clients, 0.08)
                capture = run_cli(['capture', f'{session}:{pane}'], HOME,
                                  env=DEBUG_ENV, timeout=8)
                captured = capture.stdout if capture.returncode == 0 else ''
                rendered = all(
                    marker in pane_text(client, pane)
                    for client in clients)
                if marker in captured and rendered:
                    break
            check(label + ' canonical', marker in captured)
            check(label + ' rendered', rendered)
        elif op == 'burst':
            fifo_log = EXTERNAL_DAEMON_LOG if EXTERNAL_MODE else DEBUG_LOG
            daemon_pid = session_daemon_pid(session)
            fifo_before = (-1 if not fifo_log else
                           client_fifo_dequeue_count(fifo_log, daemon_pid))
            sequences = [stlib.FULLSCREEN_CHORD, b'\x1bwr', b'\x11t']
            RNG.shuffle(sequences)
            writes = []
            for client, sequence in zip(clients, sequences):
                try:
                    writes.append(stlib.write_all(client.fd, sequence))
                except OSError as exc:
                    writes.append(exc)
            check(label + ' writes complete',
                  all(result == len(sequence) for result, sequence in
                      zip(writes, sequences)))
            if fifo_before >= 0:
                fifo_after = fifo_before
                fifo_deadline = time.monotonic() + 3.0
                while time.monotonic() < fifo_deadline:
                    drain_all(clients, 0.08)
                    fifo_after = client_fifo_dequeue_count(
                        fifo_log, daemon_pid)
                    if fifo_after >= fifo_before + len(clients):
                        break
                # This is an aggregate traffic acknowledgement. The stronger
                # geometry burst below proves distinct material pane state.
                check(label + ' produces daemon FIFO traffic',
                      fifo_after >= fifo_before + len(clients))
            else:
                trace_action(f'LIVE_BURST_FIFO_SKIP action={action} '
                             'reason=no-dedicated-daemon-log')
        else:
            # Use a larger but different host so the entire canonical snapshot
            # is observable: clipping is tested elsewhere and is not attach
            # failure. Restore first so every pane/title has a visible oracle.
            restore_and_tile(clients, session)
            expected_layout = layout_rects(clients[0])
            expected_geometry = geometry(clients[0])
            churn = track_client(stlib.Client(
                HOME, args=['--attach', session],
                w=CLIENT_W + RNG.randrange(1, 20),
                h=CLIENT_H + RNG.randrange(1, 10),
                lang='en', env=DEBUG_ENV))
            snapshot_ok = False
            snapshot_deadline = time.monotonic() + 5.0
            while time.monotonic() < snapshot_deadline:
                drain_all(clients + [churn], 0.10)
                snapshot_ok = (
                    churn.alive() and
                    layout_rects(churn) == expected_layout and
                    geometry(churn) == expected_geometry and
                    all(pane_frame_rect(churn, item) is not None
                        for item in range(1, 4)))
                if snapshot_ok:
                    break
            check(label + ' client attached alive', churn.alive())
            check(label + ' receives complete snapshot/layout', snapshot_ok)
            check(label + ' detaches cleanly', detach(churn))

        drain_all(clients, 0.08)
        check(label + ' automated clients alive',
              all(client.alive() for client in clients))
        assert_converged(label, allow_passthrough=(op == 'burst'))
        if op == 'burst':
            # A legal FIFO winner may be raw fullscreen. Normalize only after proving
            # that shared result, so the next randomized operation starts in
            # the IDE and cannot inherit a hidden passthrough state.
            restore_and_tile(clients, session)
            assert_converged(label + ' normalized')
        if action % 10 == 0:
            started = time.monotonic()
            listed = run_cli(['list', session], HOME, env=DEBUG_ENV,
                             timeout=8)
            responsive = (listed.returncode == 0 and
                          time.monotonic() - started < 3.0)
            check(label + ' daemon responsive', responsive)
            trace_action(f'LIVE_HEARTBEAT action={action} '
                         f'responsive={int(responsive)} '
                         f'clients_alive='
                         f'{int(all(c.alive() for c in clients))}')

    # No random seed is allowed to skip an operation class. These nine first
    # actions provide deterministic coverage; the subsequent random phase is
    # still mandatory and runs until both its quota and requested time pass.
    required_ops = ('focus', 'zoom', 'restore', 'minimize', 'tile',
                    'cascade', 'input', 'burst', 'churn')
    for index, op in enumerate(required_ops):
        perform(op, index % 3 + 1)

    # Deliberate visible gestures prove shaded lock ownership, one-cell motion
    # and fullscreen transition/restoration before the high-rate randomized phase.
    slow_visual_resize(clients, session, 0)
    slow_visual_circle(clients, session, 0)
    held_fullscreen(clients, session, 0)
    assert_converged('live visual phase')

    random_actions = 0
    while time.monotonic() < deadline or random_actions < 60:
        perform(RNG.choice(required_ops), RNG.randrange(1, 4))
        random_actions += 1
    check('live deterministic operation coverage',
          action >= len(required_ops))
    check('live randomized action quota', random_actions >= 60)
    assert_converged('live final state before restore')


if EXTERNAL_MODE:
    SESSION = EXTERNAL_SESSION
    existing = run_cli(['list', SESSION], HOME,
                       env=dict(DEBUG_ENV, LANG='C'), timeout=8)
    check('external stress session exists', existing.returncode == 0)
    creator = track_client(stlib.Client(
        HOME, args=['--attach', SESSION], w=CLIENT_W, h=CLIENT_H,
        lang='en', env=DEBUG_ENV))
    creator.drain(2.5)
    sizes_rc, sizes = pane_sizes(SESSION)
    check('external pane list succeeds', sizes_rc == 0)
    while sizes_rc == 0 and len(sizes) < 3:
        pane_no = len(sizes) + 1
        created = cli_retry(['new', SESSION, '-t', f'STRESS{pane_no}'])
        check(f'create external pane {pane_no}',
              created is not None and created.returncode == 0)
        if created is None or created.returncode != 0:
            break
        drain_all([creator], 0.5)
        sizes_rc, sizes = pane_sizes(SESSION)
    check('external fixture has exactly three panes',
          sizes_rc == 0 and len(sizes) == 3)
    require_clean('external fixture pane count')
    organized = cli_retry(['organize', SESSION, 'tile'])
    check('external panes tile successfully',
          organized is not None and organized.returncode == 0)
else:
    creator = track_client(stlib.Client(
        HOME, w=CLIENT_W, h=CLIENT_H, lang='en', env=DEBUG_ENV))
    creator.drain(2.5)
    creator.send(b'\x1bOQ', 1.0)
    creator.send(b'\x1bOQ', 1.0)
    creator.send(b'\x11', 0.1)
    creator.send(b't', 1.0)
    sockets = stlib.session_sockets(HOME)
    check('intensive session exists', len(sockets) == 1)
    SESSION = os.path.basename(sockets[0])[:-5] if sockets else ''
for pane in range(1, 4):
    check(f'rename pane {pane}', cli_retry(
        ['rename', f'{SESSION}:{pane}', pane_title(pane)]).returncode == 0)

clients = [creator,
           track_client(stlib.Client(
               HOME, args=['--attach', SESSION], w=CLIENT_W, h=CLIENT_H,
               lang='en', env=DEBUG_ENV)),
           track_client(stlib.Client(
               HOME, args=['--attach', SESSION], w=CLIENT_W, h=CLIENT_H,
               lang='en', env=DEBUG_ENV))]
drain_all(clients, 3.0)
check('three stable clients alive', all(c.alive() for c in clients))
require_clean('three-client fixture startup')
expected_heap_client_pids = tuple(client.pid for client in clients)
expected_heap_daemon_pid = session_daemon_pid(SESSION)
trace_action('HEAP_EXPECT daemon_pid=' + str(expected_heap_daemon_pid) +
             ' stable_client_pids=' +
             ','.join(str(pid) for pid in expected_heap_client_pids))
local_focus(clients[0], 1)
drain_all(clients, 0.8)

if EXTERNAL_MODE and LIVE_SECONDS > 0:
    ready = (f'AUTOMATED_CLIENTS_READY session={SESSION} home={HOME} '
             f'clients=3 seed={SEED:#x} seconds={LIVE_SECONDS}; '
             'watch now, wait for LIVE_STRESS_BEGIN before interacting')
    trace_action(ready)
    print(ready, flush=True)

# A full real-mouse orbit precedes the conflicting action burst. This catches
# lost modal unlocks, stale frame origins and clients that paint an old layout.
circle_window(clients, SESSION)
restore_and_tile(clients, SESSION)
# Keep raw multi-view fullscreen in the ordinary automated suite too. Previously this
# gesture ran only in the optional human-watch phase, so `make test` could
# silently lose the equal-geometry passthrough path.
held_fullscreen(clients, SESSION, 0)
restore_and_tile(clients, SESSION)

for number in range(ROUNDS):
    restore_and_tile(clients, SESSION)
    local_focus(clients[0], 1)

    # Put content in the old snapshot, then attach a differently sized fourth
    # viewer and require both that snapshot and all subsequent live output.
    # A larger host remains different without clipping the canonical desktop,
    # so exact layout, render and cursor assertions are meaningful.
    snapshot_tokens = prime_snapshot_tokens(clients, SESSION, number)
    snapshot_layout = layout_rects(clients[0])
    check(f'round {number} snapshot layout is non-empty',
          all(rect is not None for rect in snapshot_layout))
    before_sizes_rc, before_attach = pane_sizes(SESSION)
    check(f'round {number} reads PTY sizes before attach',
          before_sizes_rc == 0 and len(before_attach) == 3)
    churn = track_client(stlib.Client(
        HOME, args=['--attach', SESSION],
        w=CLIENT_W + RNG.randrange(1, 20),
        h=CLIENT_H + RNG.randrange(1, 10),
        lang='en', env=DEBUG_ENV))
    snapshot_raw, snapshot_render, snapshot_layout_ok = wait_churn_snapshot(
        churn, snapshot_tokens, snapshot_layout)
    check(f'round {number} churn receives snapshot tokens', snapshot_raw)
    check(f'round {number} churn renders snapshot tokens', snapshot_render)
    check(f'round {number} churn receives snapshot layout',
          snapshot_layout_ok)
    require_clean(f'round {number} churn snapshot')
    exact_round(clients, SESSION, number, churn)
    ordered_shared_input_burst(clients, SESSION, number, churn)
    check(f'round {number} churn client alive', churn.alive())
    after_sizes_rc, after_attach = pane_sizes(SESSION)
    check(f'round {number} attach keeps PTYs',
          before_sizes_rc == 0 and after_sizes_rc == 0 and
          len(before_attach) == 3 and after_attach == before_attach)
    check(f'round {number} churn applies live shared layout',
          layout_rects(churn) == layout_rects(clients[0]) and
          geometry(churn) == geometry(clients[0]) and
          pane_visual_map(churn) == pane_visual_map(clients[0]))

    # A real concurrent geometry burst: the three writes are released by one
    # barrier, while the fourth client detaches.  Each contender first asks
    # for a different pane and then performs a non-reversing minimize. Shared
    # focus may legitimately reorder those requests before Alt-F9 is decoded,
    # so the oracle requires material canonical mutation and exact visual
    # convergence rather than falsely claiming all three panes must minimize.
    patterns = (
        (b'\x1b1\x1b[20;3~', b'\x1b2\x1b[20;3~',
         b'\x1b3\x1b[20;3~'),
        (b'\x1b2\x1b[20;3~', b'\x1b3\x1b[20;3~',
         b'\x1b1\x1b[20;3~'),
        (b'\x1b3\x1b[20;3~', b'\x1b1\x1b[20;3~',
         b'\x1b2\x1b[20;3~'),
    )
    seqs = list(RNG.choice(patterns))
    RNG.shuffle(seqs)
    before_geometry = geometry(clients[0])
    before_layout = layout_rects(clients[0])
    before_flags = pane_flags(SESSION)
    trace_action(f'GEOMETRY_BURST round={number} seqs='
                 f'{[seq.hex() for seq in seqs]}')
    geometry_barrier = threading.Barrier(len(clients) + 1)
    geometry_results = [None] * len(clients)

    def concurrent_geometry_write(index):
        try:
            geometry_barrier.wait(timeout=3.0)
            geometry_results[index] = stlib.write_all(
                clients[index].fd, seqs[index])
        except Exception as exc:  # asserted by the coordinating thread
            geometry_results[index] = exc

    geometry_writers = [
        threading.Thread(target=concurrent_geometry_write, args=(index,))
        for index in range(len(clients))]
    for writer in geometry_writers:
        writer.start()
    geometry_barrier.wait(timeout=3.0)
    # Detach the churn client while locks/proposals and PTY output are active.
    churn_detach_write = stlib.write_all(churn.fd, b'\x11d')
    for writer in geometry_writers:
        writer.join(timeout=3.0)
    check(f'round {number} concurrent geometry writers finish',
          all(not writer.is_alive() for writer in geometry_writers))
    check(f'round {number} concurrent geometry writes complete',
          all(result == len(seq) for result, seq in
              zip(geometry_results, seqs)))
    drain_all(clients + [churn], 1.4)
    try:
        churn_detach_status = churn.wait_exit(timeout=6.0)
    except Exception:
        churn_detach_status = None
    churn.close()
    untrack_client(churn)
    check(f'round {number} churn detach command written',
          churn_detach_write == 2)
    check(f'round {number} churn detaches cleanly',
          churn_detach_status == 0)

    sig = geometry(clients[0])
    final_layout = layout_rects(clients[0])
    final_flags = pane_flags(SESSION)
    final_visuals = [pane_visual_map(client) for client in clients]
    final_active = [active_pane(client) for client in clients]
    check(f'round {number} shared layout is non-empty',
          bool(sig) and all(has_visible_frame(c) for c in clients))
    check(f'round {number} shared geometry converges',
          all(geometry(c) == sig for c in clients[1:]))
    check(f'round {number} shared layout converges',
          all(layout_rects(c) == final_layout for c in clients[1:]))
    final_visual = final_visuals[0]
    if (not all(visual == final_visual for visual in final_visuals[1:]) or
            not (len(final_flags) == 3 and
                 all(visual_map_matches_flags(visual, final_flags, active)
                     for visual, active in zip(final_visuals, final_active)))):
        print(f'  round {number} canonical flags: {final_flags}')
        print(f'  round {number} active panes: {final_active}')
        for viewer_index, visual in enumerate(final_visuals, 1):
            print(f'  round {number} viewer {viewer_index} visual: {visual}')
            with open(os.path.join(
                    LOG_HOME, f'round-{number}-viewer-{viewer_index}.txt'),
                    'w', encoding='utf-8') as fh:
                fh.write('\n'.join(clients[viewer_index - 1].screen.display))
                fh.write('\n')
    check(f'round {number} shared pane/icon identity converges',
          all(visual == final_visual for visual in final_visuals[1:]))
    check(f'round {number} canonical flags match every rendered pane/icon',
          len(final_flags) == 3 and
          all(visual_map_matches_flags(visual, final_flags, active)
              for visual, active in zip(final_visuals, final_active)))
    check(f'round {number} geometry burst changes material state',
          (sig != before_geometry or final_layout != before_layout or
           final_flags != before_flags))
    start = time.monotonic()
    listed = run_cli(['list', SESSION], HOME, env=DEBUG_ENV, timeout=8)
    check(f'round {number} reactor stays responsive',
          listed.returncode == 0 and time.monotonic() - start < 3.0)
    require_clean(f'round {number} final invariants')

    # Replace a stable viewer in the middle of ongoing session life.
    if number in (3, 7):
        check(f'round {number} replaced client detaches cleanly',
              detach(clients[2]))
        clients[2] = track_client(stlib.Client(
            HOME, args=['--attach', SESSION], w=CLIENT_W, h=CLIENT_H,
            lang='en', env=DEBUG_ENV))
        clients[2].drain(1.5)
        check(f'round {number} stable client replaced', clients[2].alive())

if LIVE_SECONDS > 0:
    live_started = time.monotonic()
    live_interrupted = False
    try:
        trace_action(f'LIVE_STRESS_BEGIN seconds={LIVE_SECONDS}')
        print(f'LIVE_STRESS_BEGIN seconds={LIVE_SECONDS} '
              'human interaction is allowed now', flush=True)
        live_stress(clients, SESSION, LIVE_SECONDS)
    except KeyboardInterrupt:
        live_interrupted = True
        trace_action('INTERRUPTED cleanup=graceful')
        print('stress interrupted; detaching automated clients', flush=True)
    finally:
        trace_action('LIVE_STRESS_END')
        print('LIVE_STRESS_END; automated clients are detaching', flush=True)
    live_elapsed = time.monotonic() - live_started
    check('live stress completed requested duration',
          not live_interrupted and live_elapsed >= LIVE_SECONDS)
else:
    trace_action('LIVE_STRESS skipped=seconds-zero')
    print('LIVE_STRESS: SKIP (set SUPERTERM_STRESS_LIVE_SECONDS; '
          'the documented leak/deadlock audit uses 120)', flush=True)

if EXTERNAL_MODE:
    for client_no, client in enumerate(clients, 1):
        check(f'external client {client_no} detaches cleanly',
              detach(client))
    check('external daemon remains after stress',
          run_cli(['list', SESSION], HOME, env=DEBUG_ENV,
                  timeout=8).returncode == 0)
    trace_action('END external daemon_preserved=1')
    log_text = ''
    try:
        with open(DEBUG_LOG, encoding='utf-8', errors='replace') as fh:
            log_text = fh.read().lower()
    except OSError:
        pass
    check('full debug log was produced', len(log_text) > 1000)
    check('full debug log has no crash marker',
          not any(marker in log_text for marker in BAD_FLOW_MARKERS))
    # An already-running daemon keeps the environment it inherited when it
    # was created.  The fresh client log above therefore cannot contain its
    # FIFO trace.  Audit that trace only when the caller supplies the daemon's
    # real, dedicated flow log; private mode below always owns both ends and
    # always performs this check.
    if EXTERNAL_DAEMON_LOG:
        daemon_log_text = ''
        try:
            with open(EXTERNAL_DAEMON_LOG, 'rb') as fh:
                fh.seek(EXTERNAL_DAEMON_LOG_OFFSET)
                daemon_log_text = fh.read().decode(
                    'utf-8', 'replace').lower()
        except OSError as exc:
            print('  external daemon log read error:', exc)
        check_fifo_log(daemon_log_text, 'external global command FIFO',
                       daemon_pid=expected_heap_daemon_pid)
    else:
        trace_action('EXTERNAL_FIFO_AUDIT skipped=no-daemon-log')
        print('external daemon FIFO audit: SKIP '
              '(set SUPERTERM_STRESS_DAEMON_LOG to its dedicated flow log)')
    if EXPECT_HEAP:
        external_client_paths = [
            LOG_HOME + '/heap-client-' + str(pid) + '.log'
            for pid in sorted(KNOWN_CLIENT_PIDS)]
        audit_heap_reports(external_client_paths,
                           'external automated-client HeapTrc')
    stlib.report()

# Detach every viewer, then attach three completely new ones. The daemon must
# retain one live geometry and all pane screens without any save/load step.
restore_and_tile(clients, SESSION)
last_geometry = geometry(clients[0])
last_layout = layout_rects(clients[0])
last_displays = [list(client.screen.display) for client in clients]
for client_no, client in enumerate(clients, 1):
    check(f'pre-reattach client {client_no} detaches cleanly',
          detach(client))
check('daemon survives zero viewers', len(stlib.session_sockets(HOME)) == 1)

clients = [track_client(stlib.Client(
    HOME, args=['--attach', SESSION], w=CLIENT_W, h=CLIENT_H,
    lang='en', env=DEBUG_ENV)) for _ in range(3)]
drain_all(clients, 3.0)
local_focus(clients[0], 1)
drain_all(clients, 0.7)
check('three fresh clients see retained geometry',
      all(layout_rects(c) == last_layout for c in clients))
if any(layout_rects(c) != last_layout for c in clients):
    with open(HOME + '/before-reattach.txt', 'w', encoding='utf-8') as fh:
        for idx, display in enumerate(last_displays, 1):
            fh.write(f'=== CLIENT {idx} ===\n')
            fh.write('\n'.join(display) + '\n')
    with open(HOME + '/after-reattach.txt', 'w', encoding='utf-8') as fh:
        for idx, client in enumerate(clients, 1):
            fh.write(f'=== CLIENT {idx} ===\n')
            fh.write('\n'.join(client.screen.display) + '\n')
    for idx, client in enumerate(clients, 1):
        trace_action(f'REATTACH_GEOMETRY client={idx} '
                     f'missing={sorted(last_geometry - geometry(client))} '
                     f'extra={sorted(geometry(client) - last_geometry)}')
exact_round(clients, SESSION, 99)

for client_no, client in enumerate(clients, 1):
    check(f'final client {client_no} detaches cleanly', detach(client))

# Close the exact daemon without the test helper's SIGKILL fallback.  Record
# failure before any forced cleanup so a deadlock cannot be turned green by
# deleting its sidecar.
close_daemon_orderly(SESSION, expected_heap_daemon_pid)

log_text = ''
try:
    with open(DEBUG_LOG, encoding='utf-8', errors='replace') as fh:
        log_text = fh.read().lower()
except OSError:
    pass
check('full debug log was produced', len(log_text) > 1000)
check('full debug log has no crash marker',
      not any(marker in log_text for marker in BAD_FLOW_MARKERS))
check_fifo_log(log_text)

# HeapTrc builds produce one PID-tagged report per client, CLI and daemon.
# Ordinary debug/release builds produce none, so only require reports when the
# selected binary is the documented heap target (or the caller explicitly
# opts in for a renamed instrumented binary).
if EXPECT_HEAP:
    expected_daemon_path = (LOG_HOME + '/heap-daemon-' +
                            str(expected_heap_daemon_pid) + '.log')
    expected_client_paths = [
        LOG_HOME + '/heap-client-' + str(pid) + '.log'
        for pid in sorted(KNOWN_CLIENT_PIDS)]
    expected_paths = [expected_daemon_path] + expected_client_paths
    heap_paths, unfinished = audit_heap_reports(
        expected_paths, 'private HeapTrc')
    check('HeapTrc final daemon report exists',
          expected_heap_daemon_pid > 0 and
          expected_daemon_path in heap_paths and
          expected_daemon_path not in unfinished)
    check('HeapTrc final reports exist for every known UI client',
          len(expected_client_paths) == len(KNOWN_CLIENT_PIDS) and
          len(expected_client_paths) >= 7 and
          all(path in heap_paths and path not in unfinished
              for path in expected_client_paths))

stlib.report()
