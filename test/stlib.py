#!/usr/bin/env python3
"""stlib: shared test fixture for the superterm suite.

Provides:
- Client: a pyte+PTY superterm instance with DSR auto-answer and wait_until.
- fresh_home(name): a unique, wiped HOME per test file.
- close_all_daemons(home): teardown that terminates every session daemon
  created under a HOME (FRAME_CLOSE, then SIGKILL by sidecar pid). Registered
  atexit by fresh_home; a leftover daemon is reported as a failure.
- raw_frame/read_frame: the daemon wire protocol (8-byte header + payload).
- run_cli(*args): run the superterm binary without a PTY (CLI commands).
"""
import atexit
import configparser
import fcntl
import glob
import os
import pty
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import termios
import time

sys.path.insert(0, os.path.dirname(__file__))
import pyte  # noqa: E402

BIN = os.environ.get('SUPERTERM_TEST_BIN', os.path.abspath(os.path.join(
    os.path.dirname(__file__), '..', 'bin', 'superterm')))

_fails = []
_registered_homes = []
_known_daemons = {}
_daemon_crash_baselines = {}
_initial_daemon_crash_reports = {}
_audited_crash_reports = set()


def _record_resource(kind, *values):
    """Persist suite-owned resources so the outer runner can clean setsid."""
    path = os.environ.get('SUPERTERM_TEST_RESOURCE_REGISTRY', '')
    if not path:
        return
    safe = [str(value).replace('\t', ' ').replace('\n', ' ')
            for value in values]
    line = '\t'.join((kind, *safe)) + '\n'
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, line.encode('utf-8', 'replace'))
        finally:
            os.close(fd)
    except OSError:
        pass


def check(name, cond, width=36):
    print(f"{name:{width}}: {'OK' if cond else 'FAIL'}")
    if not cond:
        _fails.append(name)
        _record_resource('failure', name)


def fails():
    return _fails


def report():
    """Final verdict; also fails if any daemon outlived the test."""
    leftovers = []
    for home in _registered_homes:
        leftovers += _live_daemons(home)
    if leftovers:
        check('no leftover daemons', False)
        for pid, name in leftovers:
            print(f"  leftover daemon pid={pid} session={name}")
        for home in _registered_homes:
            close_all_daemons(home)
    # A daemon can terminate from a fatal signal after deleting its sidecar.
    # In that case there is no live PID for the branch above, but its exact
    # PID-tagged crash report must still fail the suite before RESULT is
    # printed (atexit is too late for a direct test invocation's exit code).
    for home in _registered_homes:
        _audit_daemon_crash_reports(home)
    print()
    if _fails:
        print(f"RESULT: FAIL ({len(_fails)}): {', '.join(_fails)}")
        sys.exit(1)
    print('RESULT: PASS')
    sys.exit(0)


def fresh_home(testname):
    """Unique wiped HOME for this test; daemons cleaned up at exit."""
    home = '/tmp/opencode/st-' + testname
    # A previous interrupted run may have left a daemon behind.  Resolve and
    # close it while its sidecar still identifies the exact PID; deleting the
    # directory first would make that process invisible to this run.
    if os.path.isdir(home + '/.superterm/sessions'):
        close_all_daemons(home)
    shutil.rmtree(home, ignore_errors=True)
    os.makedirs(home + '/.superterm', exist_ok=True)
    _known_daemons[home] = {}
    _daemon_crash_baselines[home] = {}
    # Snapshot before this run can launch a daemon. Taking the baseline only
    # when its sidecar is first observed can hide a very fast crash that wrote
    # its fatal report between fork and sidecar discovery.
    _initial_daemon_crash_reports[home] = set(glob.glob(
        '/tmp/superterm-crash-daemon-*.log'))
    _record_resource('home', home)
    if home not in _registered_homes:
        _registered_homes.append(home)
        atexit.register(close_all_daemons, home)
    return home


# ---------------------------------------------------------------- protocol

FRAME_ATTACH = 1
FRAME_INPUT = 2
FRAME_RESIZE = 3
FRAME_DETACH = 4
FRAME_CLOSE = 5


def raw_frame(kind, pane, payload=b''):
    """8-byte packed header (Kind, Reserved, Pane:int16, Size:uint32)."""
    return struct.pack('<BBhI', kind, 0, pane, len(payload)) + payload


def read_frame(sock, timeout=5.0):
    """Read one frame; returns (kind, pane, payload) or None on EOF."""
    sock.settimeout(timeout)
    hdr = b''
    while len(hdr) < 8:
        chunk = sock.recv(8 - len(hdr))
        if not chunk:
            return None
        hdr += chunk
    kind, _res, pane, size = struct.unpack('<BBhI', hdr)
    data = b''
    while len(data) < size:
        chunk = sock.recv(min(65536, size - len(data)))
        if not chunk:
            return None
        data += chunk
    return kind, pane, data


def pas_string(s):
    """Serialize a Pascal WriteString: int32 length + bytes."""
    b = s.encode('utf-8') if isinstance(s, str) else s
    return struct.pack('<i', len(b)) + b


def read_pas_string(buf, ofs):
    """Read a WriteString from a bytes buffer; returns (value, new_ofs)."""
    (ln,) = struct.unpack_from('<i', buf, ofs)
    ofs += 4
    val = buf[ofs:ofs + ln].decode('utf-8', 'replace')
    return val, ofs + ln


def sessions_dir(home):
    return home + '/.superterm/sessions'


def session_sockets(home):
    paths = sorted(glob.glob(sessions_dir(home) + '/*.sock'))
    # Remember the exact daemon identities while their sidecars still exist.
    # A clean shutdown removes those files before Pascal unit finalization;
    # retaining the PID prevents a daemon hung in finalization from becoming
    # invisible to report() and teardown.
    _sidecar_pids(home)
    return paths


def _sidecar_pids(home):
    out = []
    for ini in glob.glob(sessions_dir(home) + '/*.ini'):
        cp = configparser.ConfigParser()
        try:
            cp.read(ini)
            pid = cp.getint('session', 'pid', fallback=0)
            name = cp.get('session', 'name', fallback='?')
            if pid > 0:
                out.append((pid, name))
        except Exception:
            pass
    known = _known_daemons.setdefault(home, {})
    baselines = _daemon_crash_baselines.setdefault(home, {})
    for pid, name in out:
        known[pid] = name
        initial = _initial_daemon_crash_reports.get(home, set())
        baselines.setdefault(pid, {
            path for path in initial
            if os.path.basename(path).startswith(
                f'superterm-crash-daemon-{pid}-')
        })
        _record_resource('daemon', home, pid, name)
    return out


def _finished(pid):
    """True for a vanished process and for a Linux zombie awaiting reaping."""
    if pid <= 0:
        return True
    try:
        with open(f'/proc/{pid}/stat', encoding='ascii',
                  errors='replace') as stream:
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


def _alive(pid):
    return not _finished(pid)


def _live_daemons(home):
    _sidecar_pids(home)
    return [(pid, name)
            for pid, name in _known_daemons.get(home, {}).items()
            if _alive(pid)]


def _audit_daemon_crash_reports(home):
    """Fail on new fatal reports from every daemon identified in this run."""
    baselines = _daemon_crash_baselines.get(home, {})
    for pid, name in _known_daemons.get(home, {}).items():
        reports = set(glob.glob(f'/tmp/superterm-crash-daemon-{pid}-*.log'))
        new_reports = sorted(
            reports - baselines.get(pid, set()) - _audited_crash_reports)
        if new_reports:
            check('daemon exits without fatal report', False)
            for report_path in new_reports:
                print(f'  daemon pid={pid} session={name} crash={report_path}')
            _audited_crash_reports.update(new_reports)


def close_all_daemons(home):
    """Close exact known daemons; record failure before bounded escalation."""
    targets = _live_daemons(home)
    for sock_path in session_sockets(home):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(1.0)
            s.connect(sock_path)
            s.sendall(raw_frame(FRAME_CLOSE, -1))
            s.close()
        except OSError:
            pass
    deadline = time.monotonic() + 5.0
    while (time.monotonic() < deadline and
           any(_alive(pid) for pid, _name in targets)):
        time.sleep(0.05)
    survivors = [(pid, name) for pid, name in targets if _alive(pid)]
    if survivors:
        check('daemon closes without escalation', False)
        for pid, name in survivors:
            print(f'  daemon pid={pid} session={name} required SIGTERM')
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        deadline = time.monotonic() + 1.0
        while (time.monotonic() < deadline and
               any(_alive(pid) for pid, _name in survivors)):
            time.sleep(0.05)
        survivors = [(pid, name) for pid, name in survivors if _alive(pid)]
    for pid, name in survivors:
        print(f'  daemon pid={pid} session={name} required SIGKILL')
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    if survivors:
        deadline = time.monotonic() + 1.0
        while (time.monotonic() < deadline and
               any(_alive(pid) for pid, _name in survivors)):
            time.sleep(0.05)
        check('daemon terminates after escalation',
              not any(_alive(pid) for pid, _name in survivors))
    # An orphan daemon has no wait status available to this test process.
    # The fatal-signal handler's PID-tagged report is therefore its exact
    # abnormal-exit oracle. Compare against the snapshot taken when the
    # sidecar first identified this daemon so stale reports cannot fail a run.
    _audit_daemon_crash_reports(home)
    shutil.rmtree(sessions_dir(home), ignore_errors=True)


# ---------------------------------------------------------------- processes

def _wait_pid_until(pid, deadline):
    """Return a wait status before *deadline*, or None without blocking."""
    while True:
        try:
            waited, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            # The process was already reaped by its owner.
            return 0
        if waited:
            return status
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        time.sleep(min(0.05, remaining))


def wait_pid(pid, timeout=5.0, terminate=True):
    """Reap a child by a hard deadline, optionally escalating TERM to KILL.

    Unlike ``os.waitpid(pid, 0)``, this helper can never hang a suite forever.
    It returns the wait status, or None only when the process survived every
    bounded escalation (or when ``terminate`` is false and the deadline won).
    """
    status = _wait_pid_until(pid, time.monotonic() + max(0.0, timeout))
    if status is not None or not terminate:
        return status
    for signum in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, signum)
        except ProcessLookupError:
            pass
        status = _wait_pid_until(pid, time.monotonic() + 1.0)
        if status is not None:
            return status
    return None


def cursor_only_transition(record):
    """True only for FreeVision toggling reverse on one software-cursor cell.

    A blanket ``changed_cells <= 1`` filter hides genuine one-cell artifacts.
    Conversely, treating this exact attribute toggle as a workspace repaint
    makes every normal cursor blink look like a duplicate transition.
    """
    if record.get('changed_cells') != 1:
        return False
    changed = []
    for before_row, after_row in zip(record['before_cells'], record['cells']):
        for before, after in zip(before_row, after_row):
            if before != after:
                changed.append((before, after))
    if len(changed) != 1:
        return False
    before, after = changed[0]
    return (before.reverse != after.reverse and
            before._replace(reverse=False) == after._replace(reverse=False))


def run_cli(args, home, env=None, stdin=None, timeout=30):
    """Run superterm without a PTY (CLI commands); returns CompletedProcess."""
    e = dict(os.environ, HOME=home, TERM='xterm',
             SUPERTERM_INI=home + '/no-sys.ini')
    if env:
        e.update(env)
    return subprocess.run([BIN] + list(args), capture_output=True, text=True,
                          env=e, input=stdin, timeout=timeout)


def drain_clients_raw(clients, seconds):
    """Fairly drain several client PTYs without running the pyte emulator.

    This is for high-volume backpressure tests. Feeding megabytes through
    pyte in one client's ``drain()`` call can consume many seconds of Python
    CPU and, during that time, manufacture a false laggard by starving every
    other PTY. Here one ``select`` set services all clients in readiness order.

    The clients' raw byte streams advance, but their ``screen``/``text()``
    models deliberately do not. Callers must use raw offsets for assertions
    until a later low-volume phase; transition capture is therefore rejected.
    """
    if any(client._transition_capture for client in clients):
        raise RuntimeError('raw multi-client drain during transition capture')
    active = {client.fd: client for client in clients if client.alive()}
    totals = {client: 0 for client in clients}
    deadline = time.monotonic() + max(0.0, seconds)
    while active and time.monotonic() < deadline:
        timeout = min(0.05, max(0.0, deadline - time.monotonic()))
        try:
            ready, _, _ = select.select(list(active), [], [], timeout)
        except InterruptedError:
            continue
        for fd in ready:
            client = active.get(fd)
            if client is None:
                continue
            try:
                data = os.read(fd, 65536)
            except OSError:
                active.pop(fd, None)
                continue
            if not data:
                active.pop(fd, None)
                continue
            # Include a possible split DSR token, but not a complete previous
            # token, so each terminal query receives exactly one answer.
            prefix = client._raw[-3:]
            client._raw += data
            totals[client] += len(data)
            for _ in range((prefix + data).count(b'\x1b[6n')):
                row, col = client.dsr
                try:
                    os.write(fd, f'\x1b[{row};{col}R'.encode())
                except OSError:
                    active.pop(fd, None)
                    break
    return totals


class Client:
    """A pyte-rendered interactive superterm on a PTY."""

    def __init__(self, home, args=None, w=110, h=32, env=None, lang=None,
                 dsr_row=5, dsr_col=1):
        self.w, self.h = w, h
        self.home = home
        self.screen = pyte.Screen(w, h)
        self.stream = pyte.ByteStream(self.screen)
        self.dsr = (dsr_row, dsr_col)
        if lang is not None:
            ini = home + '/.superterm/superterm.ini'
            os.makedirs(os.path.dirname(ini), exist_ok=True)
            if not os.path.exists(ini):
                with open(ini, 'w') as f:
                    f.write(f'[ui]\nlanguage={lang}\n')
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            e = dict(TERM='xterm', SHELL='/bin/bash', HOME=home,
                     SUPERTERM_INI=home + '/no-sys.ini', LANG='C.UTF-8')
            if env:
                e.update(env)
            os.environ.update(e)
            os.execv(BIN, [BIN] + (args or []))
        self._reaped = False
        self._wait_status = None
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', h, w, 0, 0))
        self._raw = b''
        # Optional, test-only capture of the *presented* renderer updates.
        # WideUpdateScreen wraps each physical update in DECSET 2026 when
        # SUPERTERM_SYNC=1.  A single os.read may contain several such
        # updates, so recording one snapshot per read would hide precisely
        # the transient rollback/flicker these tests are meant to catch.
        self._transition_capture = False
        self._transition_screen = None
        self._transition_stream = None
        self._transition_pending = b''
        self._transition_in_frame = False
        self._transition_raw = b''
        self._transition_direct_raw = b''
        self._transition_last_cells = None
        self._transitions = []

    def begin_transition_capture(self):
        """Record one rendered snapshot per DEC synchronized update.

        The caller must start the client with SUPERTERM_SYNC=1.  Existing
        output is replayed into a private pyte model to establish the exact
        baseline; subsequent snapshots therefore show real intermediate
        terminal states, rather than only the final state after drain().
        """
        self._transition_screen = pyte.Screen(self.w, self.h)
        self._transition_stream = pyte.ByteStream(self._transition_screen)
        try:
            self._transition_stream.feed(self._raw)
        except Exception:
            pass
        self._transition_pending = b''
        self._transition_in_frame = False
        self._transition_raw = b''
        self._transition_direct_raw = b''
        self._transition_last_cells = tuple(
            tuple(self._transition_screen.buffer[y][x]
                  for x in range(self.w))
            for y in range(self.h))
        self._transitions = []
        self._transition_capture = True

    def end_transition_capture(self):
        """Stop capturing and return the synchronized transition records."""
        # Direct writes (notably the intentionally visible zoom outline and
        # passthrough hand-off) have no DEC 2026 delimiter.  At the end of an
        # action, commit their last buffered bytes as one observable state.
        if self._transition_capture and self._transition_pending:
            part = self._transition_pending
            self._transition_pending = b''
            try:
                self._transition_stream.feed(part)
            except Exception:
                pass
            if self._transition_in_frame:
                self._transition_raw += part
            else:
                self._transition_direct_raw += part
        if (self._transition_capture and not self._transition_in_frame and
                self._transition_direct_raw):
            self._save_transition('direct', self._transition_direct_raw)
            self._transition_direct_raw = b''
        incomplete = self._transition_in_frame
        incomplete_bytes = len(self._transition_raw)
        self._transition_capture = False
        if incomplete:
            # DECSET 2026 without its matching reset leaves a real terminal
            # holding the update indefinitely.  Returning only earlier
            # records made temporal tests report PASS from pyte's internal
            # cells even though nothing final had actually been presented.
            raise AssertionError(
                'incomplete DEC synchronized update '
                f'({incomplete_bytes} captured bytes without CSI ? 2026 l)')
        return list(self._transitions)

    def transitions(self):
        """Return transition records collected since begin_transition_capture."""
        return list(self._transitions)

    def _save_transition(self, kind, raw):
        screen = self._transition_screen
        cells = tuple(tuple(screen.buffer[y][x] for x in range(self.w))
                      for y in range(self.h))
        before = self._transition_last_cells
        changed = 0
        if before is not None:
            changed = sum(before[y][x] != cells[y][x]
                          for y in range(self.h)
                          for x in range(self.w))
        self._transitions.append({
            'kind': kind,
            'display': tuple(screen.display),
            'cells': cells,
            # Preserve the exact presented predecessor.  Tests can now tell
            # a cursor-only update from an erased frame or a content repaint
            # which happened between two otherwise-correct final states.
            'before_cells': before,
            'changed_cells': changed,
            'cursor': (screen.cursor.x, screen.cursor.y),
            'raw': raw,
        })
        self._transition_last_cells = cells

    def _feed_transition_capture(self, data):
        """Split arbitrary PTY reads at complete DECSET 2026 transactions."""
        start = b'\x1b[?2026h'
        finish = b'\x1b[?2026l'
        self._transition_pending += data
        while self._transition_pending:
            token = finish if self._transition_in_frame else start
            idx = self._transition_pending.find(token)
            if idx < 0:
                # Retain only a possible token prefix across os.read calls;
                # everything before it is safe to feed immediately.
                safe = max(0, len(self._transition_pending) - len(token) + 1)
                if safe:
                    part = self._transition_pending[:safe]
                    self._transition_pending = self._transition_pending[safe:]
                    try:
                        self._transition_stream.feed(part)
                    except Exception:
                        pass
                    if self._transition_in_frame:
                        self._transition_raw += part
                    else:
                        self._transition_direct_raw += part
                break

            end = idx + len(token)
            part = self._transition_pending[:end]
            self._transition_pending = self._transition_pending[end:]
            if self._transition_in_frame:
                try:
                    self._transition_stream.feed(part)
                except Exception:
                    pass
                self._transition_raw += part
                self._save_transition('sync', self._transition_raw)
                self._transition_raw = b''
                self._transition_in_frame = False
            else:
                # Bytes before the marker belong to direct terminal output;
                # the synchronized transaction itself starts at the marker.
                before = part[:-len(token)]
                if before:
                    try:
                        self._transition_stream.feed(before)
                    except Exception:
                        pass
                    self._transition_direct_raw += before
                if self._transition_direct_raw:
                    self._save_transition('direct',
                                          self._transition_direct_raw)
                    self._transition_direct_raw = b''
                try:
                    self._transition_stream.feed(token)
                except Exception:
                    pass
                self._transition_raw = token
                self._transition_in_frame = True

    def drain(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    d = os.read(self.fd, 65536)
                    if not d:
                        return
                except OSError:
                    return
                self._raw += d
                if b'\x1b[6n' in d:
                    row, col = self.dsr
                    try:
                        os.write(self.fd, f'\x1b[{row};{col}R'.encode())
                    except OSError:
                        pass
                try:
                    self.stream.feed(d)
                except Exception:
                    pass
                if self._transition_capture:
                    self._feed_transition_capture(d)

    def send(self, data, seconds=0.8):
        try:
            os.write(self.fd, data)
        except OSError:
            pass   # the client already exited (e.g. after an immediate detach)
        self.drain(seconds)

    def resize(self, w, h, seconds=1.0):
        """Resize the host PTY and the pyte model used by assertions."""
        self.w, self.h = w, h
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', h, w, 0, 0))
        self.screen.resize(lines=h, columns=w)
        self.drain(seconds)

    def text(self):
        return '\n'.join(row.rstrip() for row in self.screen.display)

    def raw(self):
        return self._raw

    def wait_until(self, pred, timeout=12.0):
        end = time.time() + timeout
        while time.time() < end:
            self.drain(0.2)
            if pred(self.text()):
                return True
        return pred(self.text())

    def wait_exit(self, timeout=5.0):
        """Wait for the child to exit; returns exit status or None."""
        if self._reaped:
            return self._wait_status
        end = time.time() + timeout
        while time.time() < end:
            try:
                pid, st = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                self._reaped = True
                return self._wait_status
            if pid:
                self._reaped = True
                self._wait_status = st
                return st
            self.drain(0.1)
        return None

    def alive(self):
        if self._reaped:
            return False
        try:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            self._reaped = True
            return False
        if pid == 0:
            return True
        self._reaped = True
        self._wait_status = status
        return False

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass
        if not self._reaped:
            try:
                pid, status = os.waitpid(self.pid, os.WNOHANG)
                if pid:
                    self._reaped = True
                    self._wait_status = status
            except ChildProcessError:
                self._reaped = True
