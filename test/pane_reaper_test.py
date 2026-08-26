#!/usr/bin/env python3
"""Initial-pane parenthood: daemon reaping and group termination.

Persistent workspaces resolve their launches in the UI but fork every initial
PTY only after the detached daemon owns the objects.  The daemon must therefore
be the real OS parent and sole waitpid owner.  This test exercises both paths:

* a pane exits voluntarily while the creator UI is stopped and the daemon
  still reaps it;
* a pane which ignores HUP and TERM is closed through the daemon's serialized
  control path, which can signal and wait for its own exact child;
* the unaffected shell pane and the shared session remain usable throughout.

All process identities come from private scripts in this test's unique HOME.
No process-name matching is used for either assertions or cleanup.
"""
import errno
import configparser
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('pane-reaper')
CONFIG = HOME + '/.superterm/superterm.ini'
STABLE_SCRIPT = HOME + '/stable-pane.sh'
RESISTANT_SCRIPT = HOME + '/resistant-pane.sh'
SHORT_SCRIPT = HOME + '/short-pane.sh'
ORPHAN_SCRIPT = HOME + '/orphan-leader.sh'
ORPHAN_CHILD_SCRIPT = HOME + '/orphan-child.sh'
STABLE_PIDFILE = HOME + '/stable-pane.pid'
RESISTANT_PIDFILE = HOME + '/resistant-pane.pid'
SHORT_PIDFILE = HOME + '/short-pane.pid'
ORPHAN_PIDFILE = HOME + '/orphan-leader.pid'
ORPHAN_CHILD_PIDFILE = HOME + '/orphan-child.pid'
SHORT_FIFO = HOME + '/short-pane.release'
ORPHAN_FIFO = HOME + '/orphan-leader.release'


def shell_quote(value):
    """The same single-argument quoting convention used by st_config."""
    return "'" + value.replace("'", "'\\''") + "'"


def direct_command(script):
    """Keep ComposePaneCommand from adding its fallback subshell.

    Its idempotence rule recognizes this exact shell tail.  The first exec is
    consequently run by the PTY session leader itself, which makes the PID
    written by each script the actual direct child that the regression needs.
    """
    return (f'exec {shell_quote(script)}; '
            "exec '/bin/bash' -l")


def write_script(path, body):
    with open(path, 'w', encoding='utf-8') as stream:
        stream.write('#!/bin/sh\n' + body)
    os.chmod(path, 0o700)


def read_pid(path):
    try:
        with open(path, encoding='ascii') as stream:
            value = int(stream.read().strip())
        return value if value > 1 else None
    except (FileNotFoundError, OSError, ValueError):
        return None


def process_info(pid):
    """Return exact (ppid, pgid, state), portably through GNU/BSD ps."""
    if not pid:
        return None
    try:
        result = subprocess.run(
            ['/bin/ps', '-o', 'ppid=', '-o', 'pgid=', '-o', 'stat=',
             '-p', str(pid)], capture_output=True, text=True, timeout=2.0,
            check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    fields = result.stdout.split()
    if result.returncode != 0 or len(fields) < 3:
        return None
    try:
        return int(fields[0]), int(fields[1]), fields[2]
    except ValueError:
        return None


def process_birth(pid):
    """Strong /proc ticks or Darwin libproc microsecond birth identity."""
    return stlib.process_identity(pid)


def linux_sigchld_policy(pid):
    """Return (default-disposition, unblocked) from one /proc snapshot."""
    if not sys.platform.startswith('linux') or not pid or pid <= 1:
        return None
    try:
        fields = {}
        with open(f'/proc/{pid}/status', encoding='ascii') as stream:
            for line in stream:
                key, separator, value = line.partition(':')
                if separator and key in ('SigIgn', 'SigCgt', 'SigBlk'):
                    fields[key] = int(value.strip(), 16)
        bit = 1 << (signal.SIGCHLD - 1)
        if set(fields) != {'SigIgn', 'SigCgt', 'SigBlk'}:
            return None
        default = not bool((fields['SigIgn'] | fields['SigCgt']) & bit)
        return default, not bool(fields['SigBlk'] & bit)
    except (OSError, ValueError):
        return None


def poisoned_sigchld_probe():
    """Exec the real test binary with both inherited SIGCHLD hazards."""
    def poison():
        signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGCHLD})

    env = dict(os.environ, HOME=HOME, TERM='xterm', LANG='C',
               SUPERTERM_INI=HOME + '/no-sys.ini', SUPERTERM_TESTING='1',
               SUPERTERM_TEST_SIGCHLD_POLICY='1')
    try:
        result = subprocess.run(
            [stlib.BIN], capture_output=True, text=True, env=env,
            preexec_fn=poison, timeout=5.0, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return (result.returncode == 0 and
            result.stdout ==
            'SIGCHLD_POLICY default=1 blocked=0 nocldwait=0\n' and
            result.stderr == '')


def session_daemon_pid(home, session):
    try:
        cp = configparser.ConfigParser()
        cp.read(os.path.join(home, '.superterm', 'sessions', session + '.ini'))
        pid = cp.getint('session', 'pid', fallback=0)
        return pid if pid > 1 else None
    except (OSError, ValueError):
        return None


def group_alive(pgid):
    if not pgid or pgid <= 1:
        return False
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_process_gone(pid, creator, timeout=8.0):
    """Let the creator run Idle while observing disappearance, not kill(0)."""
    deadline = time.monotonic() + timeout
    saw_zombie = False
    while time.monotonic() < deadline:
        creator.drain(0.04)
        info = process_info(pid)
        if info is None:
            return True, saw_zombie
        saw_zombie = saw_zombie or info[2].startswith('Z')
        time.sleep(0.01)
    return process_info(pid) is None, saw_zombie


def wait_group_gone(pgid, member_pid, creator, timeout=8.0):
    deadline = time.monotonic() + timeout
    saw_zombie = False
    while time.monotonic() < deadline:
        creator.drain(0.04)
        info = process_info(member_pid)
        if info is not None:
            saw_zombie = saw_zombie or info[2].startswith('Z')
        if info is None and not group_alive(pgid):
            return True, saw_zombie
        time.sleep(0.01)
    return (process_info(member_pid) is None and not group_alive(pgid),
            saw_zombie)


def release_fifo(path, creator, timeout=5.0):
    """Wake one FIFO-blocked pane; ENXIO means read-open is not ready."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        creator.drain(0.03)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as exc:
            if exc.errno in (errno.ENXIO, errno.EINTR):
                time.sleep(0.01)
                continue
            return False
        try:
            os.write(fd, b'exit\n')
            return True
        finally:
            os.close(fd)
    return False


def pane_rows(output):
    return [line for line in output.splitlines()
            if line and line[0].isdigit()]


def finish_client(client):
    """Bounded teardown of this test's exact PTY child."""
    if client is None:
        return
    status = client.wait_exit(5.0)
    if status is None:
        try:
            os.kill(client.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        status = client.wait_exit(1.0)
    if status is None:
        try:
            os.kill(client.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        client.wait_exit(1.0)
    client.close()


def kill_owned_group(pid, pgid, birth):
    """Last resort, guarded by the exact PID, group and birth identity."""
    info = process_info(pid)
    if (info is None or pgid <= 1 or info[1] != pgid or
            not birth or process_birth(pid) != birth):
        return
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass


os.mkfifo(SHORT_FIFO, 0o600)
os.mkfifo(ORPHAN_FIFO, 0o600)
write_script(
    STABLE_SCRIPT,
    f"printf '%s\\n' \"$$\" > {shell_quote(STABLE_PIDFILE)}\n"
    "exec /bin/bash --noprofile --norc -i\n")
write_script(
    RESISTANT_SCRIPT,
    "trap '' HUP TERM\n"
    f"printf '%s\\n' \"$$\" > {shell_quote(RESISTANT_PIDFILE)}\n"
    "while :; do sleep 30; done\n")
write_script(
    SHORT_SCRIPT,
    f"printf '%s\\n' \"$$\" > {shell_quote(SHORT_PIDFILE)}\n"
    f"IFS= read -r command < {shell_quote(SHORT_FIFO)}\n"
    "exit 0\n")
write_script(
    ORPHAN_CHILD_SCRIPT,
    "trap '' HUP TERM\n"
    f"printf '%s\\n' \"$$\" > {shell_quote(ORPHAN_CHILD_PIDFILE)}\n"
    "while :; do sleep 30; done\n")
write_script(
    ORPHAN_SCRIPT,
    f"printf '%s\\n' \"$$\" > {shell_quote(ORPHAN_PIDFILE)}\n"
    f"{shell_quote(ORPHAN_CHILD_SCRIPT)} &\n"
    f"IFS= read -r command < {shell_quote(ORPHAN_FIFO)}\n"
    "exit 0\n")

with open(CONFIG, 'w', encoding='utf-8') as stream:
    stream.write(f'''[ui]
language=en
background=none
[autologin]
shell=/bin/bash
login=1
[session]
server=always
default_profile=reaper
default_window=main
autosave=0
autorestore=0

[profile.reaper]
name=reaper
enabled=1
focused_window=0
windows=main
[profile.reaper.window.main]
enabled=1
layout=V:250;L;V:333;L;V:500;L;L
focused_pane=0
panes=stable,resistant,short,orphan
[profile.reaper.window.main.pane.stable]
enabled=1
title=STABLE
cmd={direct_command(STABLE_SCRIPT)}
[profile.reaper.window.main.pane.resistant]
enabled=1
title=RESISTANT
cmd={direct_command(RESISTANT_SCRIPT)}
[profile.reaper.window.main.pane.short]
enabled=1
title=SHORT
cmd={direct_command(SHORT_SCRIPT)}
[profile.reaper.window.main.pane.orphan]
enabled=1
title=ORPHAN
cmd={direct_command(ORPHAN_SCRIPT)}
''')

creator = None
creator_stopped = False
owned = []
try:
    check('entry normalizes inherited SIGCHLD exactly',
          poisoned_sigchld_probe())
    creator = stlib.Client(HOME, w=120, h=36, lang='en',
                           poison_sigchld=True)
    session = ''
    stable_pid = resistant_pid = short_pid = None
    orphan_pid = orphan_child_pid = None
    deadline = time.monotonic() + 15.0
    while time.monotonic() < deadline:
        creator.drain(0.05)
        sockets = stlib.session_sockets(HOME)
        if len(sockets) == 1:
            session = os.path.basename(sockets[0])[:-5]
        stable_pid = read_pid(STABLE_PIDFILE)
        resistant_pid = read_pid(RESISTANT_PIDFILE)
        short_pid = read_pid(SHORT_PIDFILE)
        orphan_pid = read_pid(ORPHAN_PIDFILE)
        orphan_child_pid = read_pid(ORPHAN_CHILD_PIDFILE)
        if (session and stable_pid and resistant_pid and short_pid and
                orphan_pid and orphan_child_pid):
            break
        time.sleep(0.01)

    check('four-pane session promoted', bool(session))
    check('all pane leaders published PIDs',
          all((stable_pid, resistant_pid, short_pid, orphan_pid)))
    check('orphan candidate publishes child PID', bool(orphan_child_pid))

    daemon_pid = session_daemon_pid(HOME, session) if session else None
    if sys.platform.startswith('linux'):
        check('daemon restores and unblocks inherited SIGCHLD',
              linux_sigchld_policy(daemon_pid) == (True, True))
    initial = [(pid, process_info(pid)) for pid in
               (stable_pid, resistant_pid, short_pid, orphan_pid)]
    valid_children = bool(daemon_pid and len(initial) == 4 and all(
        pid and info is not None and info[0] == daemon_pid and
        not info[2].startswith('Z') for pid, info in initial))
    valid_groups = len(initial) == 4 and all(
        pid and info is not None and info[1] == pid
        for pid, info in initial)
    check('initial panes are daemon children', valid_children)
    check('initial panes lead private process groups', valid_groups)
    for label, (pid, info) in zip(
            ('stable', 'resistant', 'short', 'orphan'), initial):
        if pid:
            stlib.register_process(pid, f'pane-reaper-{label}')
        # A PTY session leader owns its whole group.  Record it for guarded
        # cleanup even when the parenthood assertion above finds a regression.
        if pid and info is not None and info[1] == pid:
            owned.append((pid, pid, process_birth(pid)))
    orphan_child_info = process_info(orphan_child_pid)
    check('orphan child starts in leader group',
          orphan_child_info is not None and
          orphan_child_info[1] == orphan_pid)
    if orphan_child_pid:
        stlib.register_process(orphan_child_pid,
                               'pane-reaper-orphan-child')
    if (orphan_child_pid and orphan_child_info is not None and
            orphan_child_info[1] == orphan_pid):
        owned.append((orphan_child_pid, orphan_pid,
                      process_birth(orphan_child_pid)))

    before = run_cli(['list', session], HOME, env={'LANG': 'C'}) \
        if session else None
    check('daemon initially owns four panes', before is not None and
          before.returncode == 0 and len(pane_rows(before.stdout)) == 4)
    check('creator stays attached after promotion', creator.alive())

    if creator is not None and creator.alive():
        os.kill(creator.pid, signal.SIGSTOP)
        creator_stopped = True
    released = bool(short_pid) and release_fifo(SHORT_FIFO, creator)
    check('short pane exits voluntarily', released)
    orphan_released = bool(orphan_pid) and release_fifo(ORPHAN_FIFO, creator)
    check('leader exits while child holds slave', orphan_released)
    short_gone, short_saw_zombie = (False, False)
    if released:
        short_gone, short_saw_zombie = wait_process_gone(
            short_pid, creator, timeout=8.0)
    check('daemon reaps while creator is stopped', short_gone)
    orphan_gone, orphan_saw_zombie = (False, False)
    if orphan_released and orphan_child_pid:
        orphan_gone, orphan_saw_zombie = wait_group_gone(
            orphan_pid, orphan_child_pid, creator, timeout=8.0)
    check('WNOWAIT seals descendants before reap', orphan_gone)
    check('exited leader and orphan child are gone',
          orphan_gone and process_info(orphan_pid) is None and
          process_info(orphan_child_pid) is None)
    if creator_stopped:
        os.kill(creator.pid, signal.SIGCONT)
        creator_stopped = False
        creator.drain(0.3)
    # A transient Z between exit(2) and the next Idle tick is legal.  The
    # regression is a persistent zombie, so disappearance is the hard oracle.
    if short_saw_zombie:
        print('  observed transient short-pane zombie before creator reap')
    if orphan_saw_zombie:
        print('  observed transient orphan-group zombie before daemon reap')
    check('creator survives child reap', creator.alive())

    close_result = run_cli(
        ['close', f'{session}:2'], HOME, env={'LANG': 'C'}, timeout=12) \
        if session else None
    check('daemon accepts resistant pane close', close_result is not None and
          close_result.returncode == 0)
    resistant_gone, resistant_saw_zombie = (False, False)
    if (close_result is not None and close_result.returncode == 0 and
            resistant_pid):
        resistant_gone, resistant_saw_zombie = wait_group_gone(
            resistant_pid, resistant_pid, creator, timeout=8.0)
    check('TERM-resistant pane group disappears', resistant_gone)
    check('daemon reaps killed pane leader',
          resistant_gone and process_info(resistant_pid) is None)
    if resistant_saw_zombie:
        print('  observed transient resistant-pane zombie before creator reap')
    check('creator survives daemon-side pane kill', creator.alive())

    after = run_cli(['list', session], HOME, env={'LANG': 'C'}) \
        if session else None
    check('close compacts only the requested pane', after is not None and
          after.returncode == 0 and len(pane_rows(after.stdout)) == 3)
    stable_info = process_info(stable_pid)
    check('stable pane process remains unchanged', stable_info is not None and
          stable_info[0] == daemon_pid and stable_info[1] == stable_pid and
          not stable_info[2].startswith('Z'))

    # Keep the result shorter than the deliberately narrow 25-column pane,
    # and assemble it in the shell so the terminal's input echo cannot make
    # this liveness oracle pass unless the command was actually executed.
    marker = 'R7391_OK'
    sent = run_cli(
        ['send', f'{session}:1', "printf 'R%s_OK\\n' 7391"], HOME) \
        if session else None
    check('stable pane still accepts input',
          sent is not None and sent.returncode == 0)
    capture = None
    deadline = time.monotonic() + 6.0
    while sent is not None and time.monotonic() < deadline:
        creator.drain(0.05)
        capture = run_cli(['capture', f'{session}:1'], HOME)
        if capture.returncode == 0 and marker in capture.stdout:
            break
        time.sleep(0.02)
    check('stable pane still produces canonical output', capture is not None and
          capture.returncode == 0 and marker in capture.stdout)
    check('attached creator receives stable output',
          creator.wait_until(lambda text: marker in text, timeout=5.0))
finally:
    # First exercise the product's own exact daemon teardown.  The guarded
    # group cleanup below is only a timeout safety net and cannot select an
    # unrelated process by name or pattern.
    if creator_stopped and creator is not None:
        try:
            os.kill(creator.pid, signal.SIGCONT)
        except ProcessLookupError:
            pass
    stlib.close_all_daemons(HOME)
    finish_client(creator)
    for owned_pid, owned_pgid, owned_birth in owned:
        kill_owned_group(owned_pid, owned_pgid, owned_birth)

stlib.report()
