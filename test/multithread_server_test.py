#!/usr/bin/env python3
"""Dynamic pane reactors: configuration, scaling, ordering and teardown."""
import configparser
import glob
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


def write_config(home, value):
    os.makedirs(home + '/.superterm', exist_ok=True)
    with open(home + '/.superterm/superterm.ini', 'w') as fh:
        fh.write('[session]\nserver=always\nautosave=0\n'
                 'autorestore=0\nmultithread=' + str(value) + '\n')


def session_state(home):
    paths = glob.glob(home + '/.superterm/sessions/*.ini')
    if len(paths) != 1:
        return None
    cp = configparser.ConfigParser()
    try:
        cp.read(paths[0])
        sec = cp['session']
        return {key: sec.getint(key, fallback=-1)
                for key in ('pid', 'panes', 'cpus', 'thread_limit', 'threads')}
    except (OSError, KeyError, ValueError):
        return None


def wait_state(home, predicate, timeout=8.0):
    end = time.time() + timeout
    state = None
    while time.time() < end:
        state = session_state(home)
        if state and predicate(state):
            return state
        time.sleep(0.05)
    return state


def actual_os_threads(pid):
    path = f'/proc/{pid}/task'
    if os.path.isdir(path):
        try:
            return len(os.listdir(path))
        except OSError:
            return None
    if sys.platform == 'darwin':
        try:
            result = subprocess.run(
                ['/bin/ps', '-M', '-p', str(pid), '-o', 'pid='],
                capture_output=True, text=True, timeout=3.0,
                check=False)
        except (OSError, subprocess.TimeoutExpired):
            return None
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        if result.returncode == 0 and lines:
            return len(lines)
    return None


def available_cpu_oracle():
    """Independent OS/Python view of CPUs schedulable by this process."""
    if hasattr(os, 'sched_getaffinity'):
        try:
            return max(1, len(os.sched_getaffinity(0)))
        except OSError:
            pass
    return max(1, os.cpu_count() or 1)


HOME = stlib.fresh_home('multithread-server')
write_config(HOME, 4)
client = stlib.Client(HOME, w=100, h=28)
client.drain(2.0)
sockets = stlib.session_sockets(HOME)
check('multithread session exists', len(sockets) == 1)
session = os.path.basename(sockets[0])[:-5] if sockets else ''

state = wait_state(HOME, lambda s: s['panes'] == 1 and s['threads'] > 0)
check('daemon detects available CPU count', bool(state) and
      state['cpus'] == available_cpu_oracle())
expected_limit = min(4, state['cpus']) if state else -1
expected_one = 1 + min(1, max(0, expected_limit - 1))
check('numeric value caps total threads', bool(state) and
      state['thread_limit'] == expected_limit)
check('one pane creates one pane worker', bool(state) and
      state['threads'] == expected_one)
os_thread_overhead = None
if state:
    actual = actual_os_threads(state['pid'])
    # Linux /proc enumerates the process thread-for-thread. Darwin's ps -M
    # can additionally report a stable runtime/process row; retain it as a
    # baseline and require every later worker to increase the OS count by one.
    if sys.platform == 'darwin':
        if actual is not None and actual >= state['threads']:
            os_thread_overhead = actual - state['threads']
        check('sidecar establishes Darwin OS thread baseline',
              actual is not None and os_thread_overhead is not None)
    else:
        check('sidecar matches OS thread count', actual is not None and
              actual == state['threads'])

# Create enough independent panes to reach the configured/CPU ceiling. New
# pane insertion compacts indexes, so it also exercises the stop/drain/rebuild
# transaction around the daemon's fork.
for _ in range(3):
    result = run_cli(['new', session], HOME)
    check('concurrent pane creation', result.returncode == 0)
state = wait_state(HOME, lambda s: s['panes'] == 4)
expected_four = 1 + min(4, max(0, expected_limit - 1))
check('workers grow up to configured cap', bool(state) and
      state['threads'] == expected_four)
if state:
    actual = actual_os_threads(state['pid'])
    if sys.platform == 'darwin':
        check('grown pool matches Darwin OS thread delta', actual is not None and
              (os_thread_overhead is not None and
               actual == state['threads'] + os_thread_overhead))
    else:
        check('grown pool matches OS threads', actual is not None and
              actual == state['threads'])

# All panes produce output at once. Each byte stream must stay ordered while
# control sockets remain responsive and the server-side TScreen instances are
# updated by different workers.
for pane in range(1, 5):
    command = (f"printf 'MT{pane}_FIRST\\n'; seq 1 2500; "
               f"printf 'MT{pane}_LAST\\n'")
    result = run_cli(['send', f'{session}:{pane}', command], HOME,
                     timeout=8)
    check('parallel pane command accepted', result.returncode == 0)

all_ordered = True
for pane in range(1, 5):
    found = False
    end = time.time() + 10.0
    while time.time() < end:
        result = run_cli(['capture', f'{session}:{pane}', '--history'], HOME,
                         timeout=8)
        first = result.stdout.find(f'MT{pane}_FIRST')
        last = result.stdout.rfind(f'MT{pane}_LAST')
        if result.returncode == 0 and first >= 0 and last > first:
            found = True
            break
        time.sleep(0.15)
    all_ordered = all_ordered and found
check('parallel pane streams stay ordered', all_ordered)
result = run_cli(['list', session], HOME, timeout=5)
check('client reactor responsive under load', result.returncode == 0)

# Closing panes releases excess workers. Closing the last pane leaves only
# reactor 0, and creating a pane again grows the pool without restarting the
# daemon.
for pane in (4, 3, 2):
    result = run_cli(['close', f'{session}:{pane}'], HOME)
    check('pane close while multithreaded', result.returncode == 0)
state = wait_state(HOME, lambda s: s['panes'] == 1)
check('workers shrink with pane count', bool(state) and
      state['threads'] == expected_one)
# The control CLI deliberately refuses to close a session's last pane; the
# attached window manager can create the supported empty-desktop state. Open
# the menu by keyboard and synchronize with its caption before selecting the
# command, rather than racing a raw click against a pending repaint.
client.send(b'\x1bp', 0.1)
menu_open = client.wait_until(lambda text: 'Close pane' in text, 4.0)
check('pane menu opens before last close', menu_open)
if menu_open:
    client.send(b'c', 1.5)
state = wait_state(HOME, lambda s: s['panes'] == 0)
check('zero panes leaves network reactor', bool(state) and
      state['threads'] == 1)
result = run_cli(['new', session], HOME)
check('pane recreated from empty session', result.returncode == 0)
state = wait_state(HOME, lambda s: s['panes'] == 1)
check('worker recreated after empty session', bool(state) and
      state['threads'] == expected_one)

client.send(b'\x1bx', 1.0)
client.close()
stlib.close_all_daemons(HOME)

# Explicit 1 is the old topology even on a multicore host, and the environment
# override wins over an auto value for deterministic debugging.
SINGLE_HOME = stlib.fresh_home('multithread-single')
write_config(SINGLE_HOME, 'auto')
single = stlib.Client(SINGLE_HOME, w=90, h=25,
                      env={'SUPERTERM_MULTITHREAD': '1'})
single.drain(2.0)
single_state = wait_state(
    SINGLE_HOME, lambda s: s['panes'] == 1 and s['threads'] == 1)
check('environment override selects single thread', bool(single_state) and
      single_state['thread_limit'] == 1)
if single_state:
    actual = actual_os_threads(single_state['pid'])
    if sys.platform == 'darwin':
        check('single mode creates no hidden Darwin worker', actual is not None and
              (os_thread_overhead is not None and
               actual == 1 + os_thread_overhead))
    else:
        check('single mode creates no hidden worker',
              actual is not None and actual == 1)
single.send(b'echo SINGLE_REACTOR_OK\r', 1.0)
check('single reactor remains functional',
      single.wait_until(lambda text: 'SINGLE_REACTOR_OK' in text, 5.0))
single.send(b'\x1bx', 1.0)
single.close()
stlib.close_all_daemons(SINGLE_HOME)

AUTO_HOME = stlib.fresh_home('multithread-auto')
write_config(AUTO_HOME, 'auto')
auto_client = stlib.Client(AUTO_HOME, w=90, h=25)
auto_client.drain(2.0)
auto_state = wait_state(AUTO_HOME, lambda s: s['panes'] == 1)
check('auto independently detects CPUs', bool(auto_state) and
      auto_state['cpus'] == available_cpu_oracle())
auto_limit = min(auto_state['cpus'], 17) if auto_state else -1
check('auto uses available CPU limit', bool(auto_state) and
      auto_state['thread_limit'] == auto_limit)
check('auto creates only needed workers', bool(auto_state) and
      auto_state['threads'] == 1 + min(1, max(0, auto_limit - 1)))
auto_client.send(b'\x1bx', 1.0)
auto_client.close()
stlib.close_all_daemons(AUTO_HOME)

stlib.report()
