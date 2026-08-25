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
import glob
import math
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time


DEFAULT_TIMEOUT = 15 * 60.0
TERM_GRACE = 5.0
FRAME_CLOSE = 5


class RunnerInterrupted(Exception):
    """Raised by the SIGTERM handler so the active process group is reaped."""

    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


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


def process_finished(pid):
    """Process vanished, or is a Linux zombie waiting for its parent."""
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


def registered_resources(path):
    homes = set()
    pids = set()
    failures = []
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
                pids.add(int(fields[2]))
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
                parser.read(ini)
                pid = parser.getint('session', 'pid', fallback=0)
                if pid > 0:
                    pids.add(pid)
            except (OSError, ValueError, configparser.Error):
                pass
    return homes, pids, failures


def wait_pids(pids, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        survivors = {pid for pid in pids if not process_finished(pid)}
        if not survivors:
            return set()
        time.sleep(0.05)
    return {pid for pid in pids if not process_finished(pid)}


def request_home_daemons_close(home):
    frame = struct.pack('<BBhI', FRAME_CLOSE, 0, -1, 0)
    for sock_path in glob.glob(home + '/.superterm/sessions/*.sock'):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.settimeout(1.0)
            sock.connect(sock_path)
            sock.sendall(frame)
        except OSError:
            pass
        finally:
            sock.close()


def cleanup_registered_resources(path, settle=1.0):
    """Audit first, then close/escalate only this suite's exact daemons."""
    homes, pids, recorded_failures = registered_resources(path)
    leftovers = wait_pids(pids, settle)
    if leftovers:
        for home in homes:
            request_home_daemons_close(home)
        survivors = wait_pids(leftovers, 2.0)
        for signum in (signal.SIGTERM, signal.SIGKILL):
            if not survivors:
                break
            for pid in survivors:
                try:
                    os.kill(pid, signum)
                except ProcessLookupError:
                    pass
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
            print(f'  cleaned detached daemon PIDs: {leftovers}', flush=True)
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
            details.append('left daemon PIDs ' + ','.join(map(str, leftovers)))
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
