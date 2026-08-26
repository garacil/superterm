#!/usr/bin/env python3
"""Run every superterm test suite with an independent hard deadline.

The runner deliberately does not use the non-portable ``timeout`` command.
Each suite gets its own process group, so a deadline terminates the suite and
all of the children which it has not explicitly detached.  Output is inherited
instead of captured: progress and diagnostics remain visible, and setting
PYTHONUNBUFFERED preserves the last lines when a hung suite must be killed.
"""

import argparse
import configparser
import ctypes
import glob
import math
import os
from pathlib import Path
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time


DEFAULT_TIMEOUT = 15 * 60.0
TERM_GRACE = 5.0
FRAME_CLOSE = 5
DARWIN_PROC_PIDTBSDINFO = 3
# Apple xnu bsd/sys/proc.h.  SZOMB has exited and cannot execute or retain
# descriptors; only its parent can collect the remaining process-table row.
DARWIN_SZOMB = 5


class RunnerInterrupted(Exception):
    """Raised by the SIGTERM handler so the active process group is reaped."""

    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


class DarwinProcBsdInfo(ctypes.Structure):
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


def positive_seconds(value, name):
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        raise ValueError(f'{name} must be a number of seconds') from None
    if not math.isfinite(seconds) or seconds <= 0:
        raise ValueError(f'{name} must be greater than zero')
    return seconds


def format_seconds(seconds):
    if seconds.is_integer():
        return str(int(seconds))
    return f'{seconds:g}'


def signal_process_group(proc, signum):
    """Signal the complete process group created for *proc*."""
    try:
        os.killpg(proc.pid, signum)
    except ProcessLookupError:
        pass


def process_group_alive(group_id):
    try:
        os.killpg(group_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def terminate_process_group(proc, grace=TERM_GRACE):
    """Stop and reap a suite: SIGTERM first, then SIGKILL after *grace*."""
    signal_process_group(proc, signal.SIGTERM)
    deadline = time.monotonic() + grace
    while process_group_alive(proc.pid) and time.monotonic() < deadline:
        proc.poll()
        time.sleep(0.05)
    if process_group_alive(proc.pid):
        signal_process_group(proc, signal.SIGKILL)
    # Reaping the direct child is bounded too.  Even an uninterruptible child
    # must not turn the test runner's own cleanup into another infinite wait.
    try:
        return proc.wait(timeout=1.0)
    except subprocess.TimeoutExpired:
        return None


def linux_identity_from_stat(stat_line):
    """Parse field 22 without trusting ')' or spaces inside field 2."""
    close_paren = stat_line.rfind(')')
    if close_paren < 0:
        return ''
    fields = stat_line[close_paren + 1:].split()
    if len(fields) <= 19 or not fields[19].isdigit():
        return ''
    return 'proc:' + fields[19]


def valid_process_identity(identity):
    if identity.startswith('proc:'):
        return bool(identity[5:]) and identity[5:].isdigit()
    if not identity.startswith('darwin:'):
        return False
    parts = identity.split(':')
    if len(parts) != 3 or not parts[1].isdigit() or not parts[2].isdigit():
        return False
    return int(parts[2]) < 1_000_000


def darwin_proc_bsd_info(pid):
    """Return the exact XNU proc_bsdinfo record, including zombies."""
    if sys.platform != 'darwin':
        return None
    try:
        libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        proc_pidinfo = libproc.proc_pidinfo
        proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int,
                                 ctypes.c_uint64, ctypes.c_void_p,
                                 ctypes.c_int]
        proc_pidinfo.restype = ctypes.c_int
        info = DarwinProcBsdInfo()
        size = ctypes.sizeof(info)
        # XNU bsd/kern/proc_info.c enables proc_find_zombref for this flavor
        # only when arg is nonzero.
        if (proc_pidinfo(pid, DARWIN_PROC_PIDTBSDINFO, 1,
                         ctypes.byref(info), size) == size and
                info.pbi_pid == pid):
            return info
    except (OSError, AttributeError):
        pass
    return None


def process_identity(pid):
    try:
        with open(f'/proc/{pid}/stat', encoding='ascii',
                  errors='replace') as stream:
            identity = linux_identity_from_stat(stream.read())
        if identity:
            return identity
    except OSError:
        pass
    info = darwin_proc_bsd_info(pid)
    if info is not None:
        return (f'darwin:{info.pbi_start_tvsec}:'
                f'{info.pbi_start_tvusec}')
    # Never degrade to `ps lstart`: its one-second resolution is insufficient
    # to authorize signals under deliberate PID churn.
    return ''


def process_finished(pid, expected_identity=''):
    """Process vanished, or is a zombie waiting for its parent."""
    if (not valid_process_identity(expected_identity) or
            process_identity(pid) != expected_identity):
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
    info = darwin_proc_bsd_info(pid)
    if info is not None and info.pbi_status == DARWIN_SZOMB:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def registered_resources(path):
    homes = set()
    pids = {}
    failures = []
    invalid_sidecars = set()

    def sidecar_failure(ini, reason):
        absolute = os.path.abspath(ini)
        if absolute in invalid_sidecars:
            return
        invalid_sidecars.add(absolute)
        failures.append('unverifiable daemon sidecar: ' + absolute +
                        ' (' + reason + ')')

    try:
        with open(path, encoding='utf-8', errors='replace') as stream:
            lines = stream.readlines()
    except OSError:
        lines = []
    for line in lines:
        fields = line.rstrip('\n').split('\t')
        if len(fields) >= 2 and fields[0] == 'home':
            homes.add(fields[1])
        elif len(fields) >= 3 and fields[0] == 'daemon':
            homes.add(fields[1])
            try:
                identity = fields[4] if len(fields) >= 5 else ''
                if identity:
                    pids[int(fields[2])] = identity
            except ValueError:
                pass
        elif len(fields) >= 2 and fields[0] == 'process':
            try:
                identity = fields[3] if len(fields) >= 4 else ''
                if identity:
                    pids[int(fields[1])] = identity
            except ValueError:
                pass
        elif len(fields) >= 2 and fields[0] == 'process_done':
            try:
                pid = int(fields[1])
                identity = fields[2] if len(fields) >= 3 else ''
                if identity and pids.get(pid) == identity:
                    pids.pop(pid, None)
            except ValueError:
                pass
        elif len(fields) >= 2 and fields[0] == 'daemon_done':
            try:
                pid = int(fields[1])
                identity = fields[2] if len(fields) >= 3 else ''
                if identity and pids.get(pid) == identity:
                    pids.pop(pid, None)
            except ValueError:
                pass
        elif len(fields) >= 2 and fields[0] == 'failure':
            failures.append(fields[1])
    # Also resolve daemons created just before a suite was interrupted, before
    # it had a chance to ask stlib for the session socket and record the PID.
    for home in homes:
        for ini in glob.glob(home + '/.superterm/sessions/*.ini'):
            parser = configparser.ConfigParser()
            try:
                info = os.lstat(ini)
                if not stat.S_ISREG(info.st_mode):
                    sidecar_failure(ini, 'not a regular file')
                    continue
                with open(ini, encoding='utf-8') as stream:
                    parser.read_file(stream, source=ini)
                if not parser.has_section('session') or not parser.has_option(
                        'session', 'pid'):
                    sidecar_failure(ini,
                                    'missing [session] section or pid')
                    continue
                pid = parser.getint('session', 'pid')
                identity = parser.get(
                    'session', 'pid_identity', fallback='').strip()
                # Old sidecars remain closeable through their Unix socket,
                # but a bare PID or a mismatched birth claim never enters the
                # escalation set.
                if pid <= 1:
                    sidecar_failure(ini, 'invalid daemon pid')
                    continue
                current_identity = process_identity(pid)
                if (valid_process_identity(identity) and
                        current_identity == identity):
                    pids.setdefault(pid, identity)
                else:
                    reason = ('missing or malformed identity' if
                              not valid_process_identity(identity) else
                              'identity does not match the live PID')
                    sidecar_failure(ini, reason)
            except FileNotFoundError:
                # Atomic clean shutdown may remove it after glob().
                continue
            except (OSError, UnicodeError, ValueError,
                    configparser.Error) as exc:
                if os.path.lexists(ini):
                    sidecar_failure(
                        ini, type(exc).__name__ + ': ' + str(exc))
    return homes, pids, failures


def wait_pids(pids, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        survivors = {
            pid: identity for pid, identity in pids.items()
            if not process_finished(pid, identity)
        }
        if not survivors:
            return {}
        time.sleep(0.05)
    return {
        pid: identity for pid, identity in pids.items()
        if not process_finished(pid, identity)
    }


def request_home_daemons_close(home):
    frame = struct.pack('<BBhI', FRAME_CLOSE, 0, -1, 0)
    for sock_path in glob.glob(home + '/.superterm/sessions/*.sock'):
        try:
            if not stat.S_ISSOCK(os.lstat(sock_path).st_mode):
                continue
        except OSError:
            continue
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.settimeout(1.0)
            sock.connect(sock_path)
            sock.sendall(frame)
        except OSError:
            pass
        finally:
            sock.close()


def signal_if_identity(pid, identity, signum):
    """Signal only a process generation authenticated by its sidecar."""
    if (not valid_process_identity(identity) or
            process_identity(pid) != identity):
        return False
    try:
        os.kill(pid, signum)
        return True
    except OSError:
        return False


def cleanup_registered_resources(path, settle=1.0):
    """Audit first, then close/escalate only this suite's exact daemons."""
    homes, pids, recorded_failures = registered_resources(path)
    leftovers = wait_pids(pids, settle)
    # FRAME_CLOSE is path-scoped and safe even when an old or mismatched
    # sidecar supplied no signalling authority. Always attempt it; only the
    # authenticated ``leftovers`` map may reach the numeric escalation below.
    for home in homes:
        request_home_daemons_close(home)
    if leftovers:
        survivors = wait_pids(leftovers, 2.0)
        for signum in (signal.SIGTERM, signal.SIGKILL):
            if not survivors:
                break
            for pid, identity in list(survivors.items()):
                signal_if_identity(pid, identity, signum)
            survivors = wait_pids(survivors, 1.0)
    try:
        os.unlink(path)
    except OSError:
        pass
    return sorted(leftovers), recorded_failures


def suite_path(project_dir, test_name):
    path = Path(test_name)
    if not path.is_absolute():
        path = project_dir / 'test' / path
    return path


def run_suite(project_dir, test_name, timeout):
    path = suite_path(project_dir, test_name)
    label = f'test/{path.name}'
    print(f'\n==> {label} (timeout {format_seconds(timeout)}s)', flush=True)
    if not path.is_file():
        print(f'ERROR: suite not found: {path}', flush=True)
        return False, 'not found', 0.0

    env = os.environ.copy()
    env.setdefault('PYTHONUNBUFFERED', '1')
    # The complete suite is always isolated.  An exported live-session name
    # must never make its intensive member attach to and mutate a real user's
    # desktop.  External/watch mode remains available by invoking
    # multiclient_intensive_test.py directly as documented.
    if path.name == 'multiclient_intensive_test.py':
        for name in ('SUPERTERM_STRESS_SESSION',
                     'SUPERTERM_STRESS_HOME',
                     'SUPERTERM_STRESS_LOGDIR',
                     'SUPERTERM_STRESS_DAEMON_LOG'):
            env.pop(name, None)
    registry_fd, registry_path = tempfile.mkstemp(
        prefix='superterm-suite-', suffix='.resources')
    os.close(registry_fd)
    env['SUPERTERM_TEST_RESOURCE_REGISTRY'] = registry_path
    started = time.monotonic()
    try:
        proc = subprocess.Popen(
            [sys.executable, str(path)],
            cwd=str(project_dir),
            env=env,
            # Available on both Linux and macOS.  It gives the deadline a
            # precise target without also signalling make or this runner.
            start_new_session=True,
        )
    except OSError as exc:
        try:
            os.unlink(registry_path)
        except OSError:
            pass
        elapsed = time.monotonic() - started
        print(f'ERROR: could not start {label}: {exc}', flush=True)
        return False, f'start failed: {exc}', elapsed

    try:
        returncode = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        terminate_process_group(proc)
        leftovers, _recorded = cleanup_registered_resources(
            registry_path, settle=0.1)
        elapsed = time.monotonic() - started
        reason = f'timed out after {format_seconds(timeout)}s'
        if leftovers:
            print(f'  cleaned detached process PIDs: {leftovers}', flush=True)
        print(f'<== TIMEOUT {label} ({elapsed:.1f}s)', flush=True)
        return False, reason, elapsed
    except (KeyboardInterrupt, RunnerInterrupted):
        terminate_process_group(proc)
        cleanup_registered_resources(registry_path, settle=0.1)
        raise

    elapsed = time.monotonic() - started
    leftovers, recorded_failures = cleanup_registered_resources(
        registry_path)
    if returncode == 0 and (leftovers or recorded_failures):
        details = []
        if leftovers:
            details.append('left process PIDs ' + ','.join(map(str, leftovers)))
        if recorded_failures:
            details.append('recorded failed assertion')
        reason = '; '.join(details)
        print(f'<== FAIL {label} ({reason}, {elapsed:.1f}s)', flush=True)
        return False, reason, elapsed
    if returncode == 0:
        print(f'<== PASS {label} ({elapsed:.1f}s)', flush=True)
        return True, '', elapsed
    if returncode < 0:
        reason = f'terminated by signal {-returncode}'
    else:
        reason = f'exit status {returncode}'
    print(f'<== FAIL {label} ({reason}, {elapsed:.1f}s)', flush=True)
    return False, reason, elapsed


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description='run superterm test suites with a per-suite timeout')
    parser.add_argument(
        '--project-dir', type=Path,
        default=Path(__file__).resolve().parent.parent,
        help='superterm source tree (defaults to the parent of test/)')
    parser.add_argument('tests', nargs='+', help='suite filenames under test/')
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    project_dir = args.project_dir.resolve()
    try:
        timeout = positive_seconds(
            os.environ.get('SUPERTERM_TEST_TIMEOUT', str(DEFAULT_TIMEOUT)),
            'SUPERTERM_TEST_TIMEOUT')
    except ValueError as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 2

    def interrupted(signum, _frame):
        raise RunnerInterrupted(signum)

    previous_term = signal.signal(signal.SIGTERM, interrupted)
    failures = []
    total_started = time.monotonic()
    try:
        for test_name in args.tests:
            ok, reason, _elapsed = run_suite(
                project_dir, test_name, timeout)
            if not ok:
                failures.append((Path(test_name).name, reason))
    except KeyboardInterrupt:
        print('\nTest run interrupted by SIGINT.', file=sys.stderr, flush=True)
        return 130
    except RunnerInterrupted as exc:
        print(f'\nTest run interrupted by signal {exc.signum}.',
              file=sys.stderr, flush=True)
        return 128 + exc.signum
    finally:
        signal.signal(signal.SIGTERM, previous_term)

    elapsed = time.monotonic() - total_started
    print('\n---------------------------------------------', flush=True)
    if failures:
        print(f'FAILED suites (of {len(args.tests)}):', flush=True)
        for name, reason in failures:
            print(f'  test/{name}: {reason}', flush=True)
        print(f'completed in {elapsed:.1f}s', flush=True)
        return 1
    print(f'all {len(args.tests)} suites passed in {elapsed:.1f}s', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
