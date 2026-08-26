#!/usr/bin/env python3
"""stlib: shared test fixture for the superterm suite.

Provides:
- Client: a pyte+PTY superterm instance with DSR auto-answer and wait_until.
- fresh_home(name, base=None): a unique, wiped HOME per test file.
- close_all_daemons(home): teardown that terminates every session daemon
  created under a HOME (FRAME_CLOSE, then SIGKILL only after authenticating
  the sidecar PID's birth identity). Registered by fresh_home; a leftover
  daemon is reported as a failure.
- raw_frame/read_frame: the daemon wire protocol (8-byte header + payload).
- run_cli(*args): run the superterm binary without a PTY (CLI commands).
"""
import atexit
import configparser
import ctypes
import fcntl
import glob
import os
import pty
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import termios
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
import pyte  # noqa: E402

BIN = os.environ.get('SUPERTERM_TEST_BIN', os.path.abspath(os.path.join(
    os.path.dirname(__file__), '..', 'bin', 'superterm')))
# User-facing fullscreen is a prefix chord, not a function key.  Keep the
# default in one place so every layout/passthrough regression exercises the
# same public input path.  Tests for a configured non-default prefix use their
# explicit byte instead.
FULLSCREEN_CHORD = b'\x11f'  # default Ctrl-Q, then f

_fails = []
_registered_homes = []
_known_daemons = {}
# Birth identities for the live/escalatable daemon index. Keep these separate
# from _process_identities: after PID reuse, registering a new test child must
# never overwrite the generation which a stale daemon sidecar referred to.
_daemon_identities = {}
# Historical PID/name index used only to attribute crash-report filenames.
# Entries remain after a daemon dies; unlike _known_daemons they are never an
# authority to inspect or signal that numeric PID again.
_auditable_daemons = {}
_daemon_crash_baselines = {}
_initial_daemon_crash_reports = {}
_audited_crash_reports = set()
_process_identities = {}
# One malformed claim is reported once even though session_sockets(), report()
# and teardown deliberately rescan sidecars several times.
_reported_untrusted_sidecars = set()


class _DarwinProcBsdInfo(ctypes.Structure):
    """Exact public proc_bsdinfo prefix from Apple's sys/proc_info.h."""
    _fields_ = [
        ('pbi_flags', ctypes.c_uint32), ('pbi_status', ctypes.c_uint32),
        ('pbi_xstatus', ctypes.c_uint32), ('pbi_pid', ctypes.c_uint32),
        ('pbi_ppid', ctypes.c_uint32), ('pbi_uid', ctypes.c_uint32),
        ('pbi_gid', ctypes.c_uint32), ('pbi_ruid', ctypes.c_uint32),
        ('pbi_rgid', ctypes.c_uint32), ('pbi_svuid', ctypes.c_uint32),
        ('pbi_svgid', ctypes.c_uint32), ('rfu_1', ctypes.c_uint32),
        ('pbi_comm', ctypes.c_char * 16), ('pbi_name', ctypes.c_char * 32),
        ('pbi_nfiles', ctypes.c_uint32), ('pbi_pgid', ctypes.c_uint32),
        ('pbi_pjobc', ctypes.c_uint32), ('e_tdev', ctypes.c_uint32),
        ('e_tpgid', ctypes.c_uint32), ('pbi_nice', ctypes.c_int32),
        ('pbi_start_tvsec', ctypes.c_uint64),
        ('pbi_start_tvusec', ctypes.c_uint64),
    ]


_DARWIN_PROC_PIDTBSDINFO = 3
# Apple xnu bsd/sys/proc.h: a process in SZOMB has exited and is only
# awaiting collection by its parent. It cannot execute or retain an fd.
_DARWIN_SZOMB = 5


def _darwin_proc_bsd_info(pid):
    """Return Apple's exact proc_bsdinfo record, including zombies.

    XNU's ``proc_info`` path only calls ``proc_find_zombref`` for
    ``PROC_PIDTBSDINFO`` when ``arg`` is nonzero.  Passing zero would make a
    zombie indistinguishable from a vanished PID before ``pbi_status`` can be
    inspected.
    """
    if sys.platform != 'darwin':
        return None
    try:
        libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        proc_pidinfo = libproc.proc_pidinfo
        proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int,
                                 ctypes.c_uint64, ctypes.c_void_p,
                                 ctypes.c_int]
        proc_pidinfo.restype = ctypes.c_int
        info = _DarwinProcBsdInfo()
        size = ctypes.sizeof(info)
        if (proc_pidinfo(pid, _DARWIN_PROC_PIDTBSDINFO, 1,
                         ctypes.byref(info), size) == size and
                info.pbi_pid == pid):
            return info
    except (OSError, AttributeError):
        pass
    return None


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


def _linux_identity_from_stat(stat_line):
    """Parse field 22 without trusting ')' or spaces inside field 2."""
    close_paren = stat_line.rfind(')')
    if close_paren < 0:
        return ''
    fields = stat_line[close_paren + 1:].split()
    # The tail begins at original field 3; index 19 is starttime (field 22).
    if len(fields) <= 19 or not fields[19].isdigit():
        return ''
    return 'proc:' + fields[19]


def _valid_process_identity(identity):
    """Accept only the two sidecar formats emitted by ProcBirthIdentity."""
    if identity.startswith('proc:'):
        return bool(identity[5:]) and identity[5:].isdigit()
    if not identity.startswith('darwin:'):
        return False
    parts = identity.split(':')
    if len(parts) != 3 or not parts[1].isdigit() or not parts[2].isdigit():
        return False
    return int(parts[2]) < 1_000_000


def _process_identity(pid):
    """Return a stable, portable-enough birth identity for one exact PID."""
    try:
        with open(f'/proc/{pid}/stat', encoding='ascii',
                  errors='replace') as stream:
            identity = _linux_identity_from_stat(stream.read())
        if identity:
            return identity
    except OSError:
        pass
    info = _darwin_proc_bsd_info(pid)
    if info is not None:
        return (f'darwin:{info.pbi_start_tvsec}:'
                f'{info.pbi_start_tvusec}')
    # A textual `ps lstart` has only one-second resolution and is not an
    # identity: under PID churn it could authorize signalling a reused PID.
    return ''


def process_identity(pid):
    """Public strong PID identity used by exact-cleanup tests."""
    return _process_identity(pid)


def process_uids(pid):
    """Return (real UID, effective UID) without parsing localized ps output."""
    try:
        with open(f'/proc/{pid}/status', encoding='ascii',
                  errors='replace') as stream:
            for line in stream:
                if not line.startswith('Uid:'):
                    continue
                values = line[4:].split()
                if len(values) >= 2:
                    return int(values[0]), int(values[1])
                return None
    except (OSError, ValueError):
        pass
    info = _darwin_proc_bsd_info(pid)
    if info is not None:
        return int(info.pbi_ruid), int(info.pbi_uid)
    return None


def register_process(pid, label='test-process'):
    """Register an exact suite-owned PID which may have called setsid().

    An empty identity is not a weaker registration: it is no registration at
    all, because neither this fixture nor the outer runner may later signal a
    bare numeric PID.  Retry briefly for a just-forked child, then make the
    missing cleanup authority an explicit test failure.
    """
    if pid <= 1:
        check('registered process PID is valid', False)
        return ''
    identity = ''
    for attempt in range(10):
        identity = _process_identity(pid)
        if identity:
            break
        if attempt < 9:
            time.sleep(0.005)
    if not identity:
        check('registered process identity is available', False)
        print(f'  process pid={pid} label={label} has no birth identity')
        return ''
    _process_identities[pid] = identity
    _record_resource('process', pid, label, identity)
    return identity


def unregister_process(pid):
    """Forget a registered PID immediately after its child was reaped.

    The outer timeout runner must never retain a bare historical PID: the OS
    may reuse it for an unrelated process before a long suite finishes.
    """
    if pid > 1:
        identity = _process_identities.pop(pid, None)
        # A failed/empty registration never wrote signalling authority to the
        # registry.  Do not emit a legacy bare completion which could erase a
        # newer, generation-qualified owner of the same numeric PID.
        if identity:
            _record_resource('process_done', pid, identity)


def _unregister_daemon(home, pid):
    if pid > 1:
        identity = _daemon_identities.get(home, {}).pop(pid, '')
        # Never emit a bare historical PID completion: it could erase a newer
        # generation of the same numeric PID in the outer runner.
        if identity:
            _record_resource('daemon_done', pid, identity)
        _known_daemons.get(home, {}).pop(pid, None)


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
        for pid, name, _identity in leftovers:
            print(f"  leftover daemon pid={pid} session={name}")
        for home in _registered_homes:
            close_all_daemons(home)
    # A daemon can terminate from a fatal signal after deleting its sidecar.
    # In that case there is no live PID for the branch above, but its exact
    # PID-tagged crash report must still fail the suite before RESULT is
    # printed (atexit is too late for a direct test invocation's exit code).
    for home in _registered_homes:
        _audit_daemon_crash_reports(home)
    _audit_registered_processes()
    # Successful suites leave no diagnostic state worth retaining. Failure
    # homes deliberately remain available for post-mortem inspection.
    if not _fails:
        for home in _registered_homes:
            shutil.rmtree(home, ignore_errors=True)
    print()
    if _fails:
        print(f"RESULT: FAIL ({len(_fails)}): {', '.join(_fails)}")
        sys.exit(1)
    print('RESULT: PASS')
    sys.exit(0)


def fresh_home(testname, base=None):
    """Unique HOME for this invocation; daemons cleaned up at exit.

    A fixed name let two concurrent suites erase each other's directory and
    close each other's daemons. mkdtemp makes ownership unambiguous to both
    this fixture and run_tests' exact resource registry.
    """
    if base is None:
        # Lets an unprivileged account run the same suite from a root-owned
        # checkout/test parent without relaxing permissions on that shared
        # directory.  The caller still supplies only a parent; mkdtemp owns
        # the exact per-suite child as before.
        base = os.environ.get('SUPERTERM_TEST_HOME_BASE', '/tmp/opencode')
        os.makedirs(base, mode=0o700, exist_ok=True)
    try:
        base_info = os.lstat(base)
    except OSError as exc:
        raise RuntimeError(
            f'cannot inspect test HOME parent {base}: {exc}') from exc
    if not stat.S_ISDIR(base_info.st_mode):
        raise RuntimeError(f'test HOME parent is not a directory: {base}')
    # Keep the HOME compact: the session name is appended again below
    # .superterm/sessions, and Darwin's sockaddr_un.sun_path holds only 104
    # bytes (GNU/Linux holds 108).  mkdtemp's random suffix already provides
    # the unique per-suite identity; the outer runner records the owning test.
    home = tempfile.mkdtemp(prefix='st-', dir=base)
    os.makedirs(home + '/.superterm', exist_ok=True)
    _known_daemons[home] = {}
    _daemon_identities[home] = {}
    _auditable_daemons[home] = {}
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


def _is_real_socket(path):
    """True only for a socket inode at *path*, never for a symlink."""
    try:
        return stat.S_ISSOCK(os.lstat(path).st_mode)
    except OSError:
        return False


def session_sockets(home):
    paths = sorted(path for path in
                   glob.glob(sessions_dir(home) + '/*.sock')
                   if _is_real_socket(path))
    # Remember the exact daemon identities while their sidecars still exist.
    # A clean shutdown removes those files before Pascal unit finalization;
    # retaining the PID prevents a daemon hung in finalization from becoming
    # invisible to report() and teardown.
    _sidecar_pids(home)
    return paths


def _report_untrusted_sidecar(ini, reason, pid=0, name='?'):
    """Report one persistent invalid sidecar once, without PID authority."""
    claim = os.path.abspath(ini)
    if claim in _reported_untrusted_sidecars:
        return
    _reported_untrusted_sidecars.add(claim)
    check('daemon sidecar is complete and verifiable', False)
    details = f'  sidecar={ini}'
    if pid > 1:
        details += f' pid={pid}'
    if name != '?':
        details += f' session={name}'
    print(details + ' reason=' + reason)


def _sidecar_pids(home):
    out = []
    for ini in glob.glob(sessions_dir(home) + '/*.ini'):
        cp = configparser.ConfigParser()
        try:
            info = os.lstat(ini)
            if not stat.S_ISREG(info.st_mode):
                _report_untrusted_sidecar(ini,
                                          'sidecar is not a regular file')
                continue
            with open(ini, encoding='utf-8') as stream:
                cp.read_file(stream, source=ini)
            if not cp.has_section('session') or not cp.has_option(
                    'session', 'pid'):
                _report_untrusted_sidecar(
                    ini, 'missing [session] section or pid')
                continue
            pid = cp.getint('session', 'pid')
            name = cp.get('session', 'name', fallback='?')
            identity = cp.get('session', 'pid_identity', fallback='').strip()
            if pid <= 1:
                _report_untrusted_sidecar(ini, 'invalid daemon pid', pid,
                                          name)
                continue
            out.append((ini, pid, name, identity))
        except FileNotFoundError:
            # Atomic clean shutdown may remove the sidecar after glob().
            continue
        except (OSError, UnicodeError, ValueError,
                configparser.Error) as exc:
            # A file which vanished during the read is the same clean race.
            # Every still-published malformed generation is a real failure.
            if os.path.lexists(ini):
                _report_untrusted_sidecar(
                    ini, type(exc).__name__ + ': ' + str(exc))
    known = _known_daemons.setdefault(home, {})
    identities = _daemon_identities.setdefault(home, {})
    auditable = _auditable_daemons.setdefault(home, {})
    baselines = _daemon_crash_baselines.setdefault(home, {})
    trusted = []
    for ini, pid, name, identity in out:
        # The daemon, while it owned this PID, wrote the claim atomically next
        # to the number.  A missing/old/malformed sidecar may still be closed
        # through its Unix socket, but it can never authorize a numeric signal.
        current_identity = _process_identity(pid)
        if (not _valid_process_identity(identity) or
                current_identity != identity):
            reason = ('missing or malformed identity' if
                      not _valid_process_identity(identity) else
                      'identity does not match the live PID')
            _report_untrusted_sidecar(ini, reason, pid, name)
            continue
        old_identity = identities.get(pid)
        if old_identity and old_identity != identity:
            _unregister_daemon(home, pid)
        known[pid] = name
        auditable[pid] = name
        identities[pid] = identity
        initial = _initial_daemon_crash_reports.get(home, set())
        baselines.setdefault(pid, {
            path for path in initial
            if os.path.basename(path).startswith(
                f'superterm-crash-daemon-{pid}-')
        })
        _record_resource('daemon', home, pid, name, identity)
        trusted.append((pid, name, identity))
    return trusted


def _signal_if_identity(pid, identity, signum):
    """Signal only a generation which still matches its sidecar claim."""
    if (not _valid_process_identity(identity) or
            _process_identity(pid) != identity):
        return False
    try:
        os.kill(pid, signum)
        return True
    except OSError:
        return False


def _finished(pid, expected_identity=None):
    """True for a vanished process or an OS-reported zombie awaiting reap."""
    if expected_identity is None:
        expected_identity = _process_identities.get(pid)
    if expected_identity is not None and not expected_identity:
        # Never escalate a bare historical PID when its birth identity could
        # not be obtained. Socket-level daemon shutdown remains available.
        return True
    if expected_identity:
        current = _process_identity(pid)
        if current != expected_identity:
            return True
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
    info = _darwin_proc_bsd_info(pid)
    if info is not None and info.pbi_status == _DARWIN_SZOMB:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def process_finished(pid, expected_identity):
    """Public strong-identity exit oracle for indirect test descendants."""
    if not _valid_process_identity(expected_identity):
        return False
    return _finished(pid, expected_identity)


def process_is_zombie(pid, expected_identity):
    """Observe zombie state and birth identity in one kernel snapshot."""
    if not _valid_process_identity(expected_identity):
        return False
    try:
        with open(f'/proc/{pid}/stat', encoding='ascii',
                  errors='replace') as stream:
            stat_line = stream.read()
        close_paren = stat_line.rfind(')')
        state = (stat_line[close_paren + 2:close_paren + 3]
                 if close_paren >= 0 else '')
        return (_linux_identity_from_stat(stat_line) == expected_identity and
                state == 'Z')
    except OSError:
        pass
    info = _darwin_proc_bsd_info(pid)
    if info is None:
        return False
    identity = (f'darwin:{info.pbi_start_tvsec}:'
                f'{info.pbi_start_tvusec}')
    return identity == expected_identity and info.pbi_status == _DARWIN_SZOMB


def _alive(pid, expected_identity=None):
    return not _finished(pid, expected_identity)


def _live_daemons(home):
    _sidecar_pids(home)
    live = []
    dead = []
    identities = _daemon_identities.setdefault(home, {})
    for pid, name in list(_known_daemons.get(home, {}).items()):
        identity = identities.get(pid, '')
        if _alive(pid, identity):
            live.append((pid, name, identity))
        else:
            dead.append(pid)
    for pid in dead:
        _unregister_daemon(home, pid)
    return live


def _audit_daemon_crash_reports(home):
    """Fail on new fatal reports from every daemon identified in this run."""
    baselines = _daemon_crash_baselines.get(home, {})
    # Audit the historical index, not the live/escalation index. A daemon may
    # have removed its sidecar and vanished before report(), at which point
    # _live_daemons has correctly retired its numeric PID to prevent reuse
    # hazards but its PID-tagged diagnostic must still fail this suite.
    for pid, name in _auditable_daemons.get(home, {}).items():
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
           any(_alive(pid, identity) for pid, _name, identity in targets)):
        time.sleep(0.05)
    survivors = [(pid, name, identity) for pid, name, identity in targets
                 if _alive(pid, identity)]
    if survivors:
        check('daemon closes without escalation', False)
        for pid, name, identity in survivors:
            print(f'  daemon pid={pid} session={name} required SIGTERM')
            _signal_if_identity(pid, identity, signal.SIGTERM)
        deadline = time.monotonic() + 1.0
        while (time.monotonic() < deadline and
               any(_alive(pid, identity)
                   for pid, _name, identity in survivors)):
            time.sleep(0.05)
        survivors = [(pid, name, identity)
                     for pid, name, identity in survivors
                     if _alive(pid, identity)]
    for pid, name, identity in survivors:
        print(f'  daemon pid={pid} session={name} required SIGKILL')
        _signal_if_identity(pid, identity, signal.SIGKILL)
    if survivors:
        deadline = time.monotonic() + 1.0
        while (time.monotonic() < deadline and
               any(_alive(pid, identity)
                   for pid, _name, identity in survivors)):
            time.sleep(0.05)
        check('daemon terminates after escalation',
              not any(_alive(pid, identity)
                      for pid, _name, identity in survivors))
    for pid, _name, identity in targets:
        if not _alive(pid, identity):
            _unregister_daemon(home, pid)
    # An orphan daemon has no wait status available to this test process.
    # The fatal-signal handler's PID-tagged report is therefore its exact
    # abnormal-exit oracle. Compare against the snapshot taken when the
    # sidecar first identified this daemon so stale reports cannot fail a run.
    _audit_daemon_crash_reports(home)
    # Do not erase malformed claims or a socket belonging to a process which
    # resisted exact cleanup. Successful report() removes the whole unique
    # HOME only after every oracle is green; failed homes remain for diagnosis.


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


def _audit_registered_processes():
    """Fail and safely retire any suite-owned process still registered.

    This makes a directly invoked test as strict as run_tests.py. Every
    signal is gated by the birth identity captured while the suite owned the
    process; a recycled numeric PID is only forgotten, never touched.
    """
    survivors = {
        pid: identity for pid, identity in list(_process_identities.items())
        if _alive(pid, identity)
    }
    if survivors:
        check('no leftover registered processes', False)
        for pid, identity in survivors.items():
            print(f'  leftover registered process pid={pid} identity={identity}')
        for signum in (signal.SIGTERM, signal.SIGKILL):
            for pid, identity in list(survivors.items()):
                _signal_if_identity(pid, identity, signum)
            deadline = time.monotonic() + 1.0
            while time.monotonic() < deadline and any(
                    _alive(pid, identity)
                    for pid, identity in survivors.items()):
                time.sleep(0.05)
            survivors = {
                pid: identity for pid, identity in survivors.items()
                if _alive(pid, identity)
            }
            if not survivors:
                break
    for pid, identity in list(_process_identities.items()):
        if not _alive(pid, identity):
            unregister_process(pid)


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
                 dsr_row=5, dsr_col=1, start_gate_fd=None):
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
        if start_gate_fd is None:
            start_read, start_write = os.pipe()
        else:
            # Several constructors can share one caller-owned pipe.  Every
            # child is then fully forked with its PTY geometry installed
            # before the caller releases one byte per child, giving race tests
            # a real simultaneous start instead of sequential constructors.
            start_read = start_gate_fd
            start_write = None
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            if start_write is not None:
                os.close(start_write)
            try:
                os.read(start_read, 1)
            finally:
                os.close(start_read)
            e = dict(TERM='xterm', SHELL='/bin/bash', HOME=home,
                     SUPERTERM_INI=home + '/no-sys.ini', LANG='C.UTF-8')
            if env:
                e.update(env)
            os.environ.update(e)
            os.execv(BIN, [BIN] + (args or []))
        if start_gate_fd is None:
            os.close(start_read)
        register_process(self.pid, 'superterm-client')
        self._reaped = False
        self._wait_status = None
        try:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                        struct.pack('HHHH', h, w, 0, 0))
            if start_write is not None:
                os.write(start_write, b'1')
        finally:
            if start_write is not None:
                os.close(start_write)
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
        deadline = time.monotonic() + max(0.0, timeout)
        first_probe = True
        while first_probe or time.monotonic() < deadline:
            first_probe = False
            try:
                pid, st = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                self._reaped = True
                unregister_process(self.pid)
                return self._wait_status
            if pid:
                self._reaped = True
                self._wait_status = st
                unregister_process(self.pid)
                return st
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            self.drain(min(0.1, remaining))
        return None

    def alive(self):
        if self._reaped:
            return False
        try:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            self._reaped = True
            unregister_process(self.pid)
            return False
        if pid == 0:
            return True
        self._reaped = True
        self._wait_status = status
        unregister_process(self.pid)
        return False

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass
        if not self._reaped:
            # Closing the PTY normally gives the direct child SIGHUP. Reap it
            # by a hard deadline; direct-child wait authority keeps this PID
            # reserved throughout TERM/KILL escalation, so reuse is impossible.
            status = wait_pid(self.pid, timeout=2.0, terminate=True)
            if status is not None:
                self._reaped = True
                self._wait_status = status
                unregister_process(self.pid)
            else:
                check('client process terminates during close', False)
