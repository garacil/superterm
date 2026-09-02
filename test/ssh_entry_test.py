#!/usr/bin/env python3
"""The restricted SSH entry reuses one canonical Unix-socket session.

This drives `superterm --ssh-entry` on real PTYs with the environment that
OpenSSH's forced interactive command supplies.  It covers exact naming,
profile creation, simultaneous first logins, geometry, abrupt loss/detach,
reattach and the legitimate zero-pane default.
"""

import configparser
import os
import signal
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


def ssh_env(serial=1, original=None):
    env = {
        'SSH_CONNECTION': f'127.0.0.1 {40000 + serial} 127.0.0.1 8022',
        'SSH_TTY': f'/dev/pts/superterm-test-{serial}',
        'LANG': 'C.UTF-8',
    }
    if original is not None:
        env['SSH_ORIGINAL_COMMAND'] = original
    return env


def names(home):
    return sorted(os.path.basename(path)[:-5]
                  for path in stlib.session_sockets(home))


def sidecar(home, name):
    cp = configparser.ConfigParser()
    cp.read(os.path.join(home, '.superterm', 'sessions', name + '.ini'))
    return {
        'panes': cp.getint('session', 'panes', fallback=-1),
        'profile': cp.get('session', 'profile', fallback=''),
        'attached': cp.getint('session', 'attached', fallback=-1),
    }


def pane_size(home, session):
    result = run_cli(['list', session], home, env={'LANG': 'C'})
    for line in result.stdout.splitlines():
        if not line.startswith('1 '):
            continue
        for token in line.split():
            if 'x' not in token or not token[0].isdigit():
                continue
            try:
                return tuple(int(value) for value in token.split('x', 1))
            except ValueError:
                pass
    return None


def config_value(home, section, option, fallback=''):
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    try:
        with open(os.path.join(home, '.superterm', 'superterm.ini'),
                  encoding='utf-8') as stream:
            parser.read_file(stream)
    except (OSError, configparser.Error):
        return fallback
    return parser.get(section, option, fallback=fallback)


def drain_all(clients, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            if client is not None and client.alive():
                client.drain(0.025)


def wait_for(predicate, clients=(), timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        if predicate():
            return True
        time.sleep(0.025)
    return predicate()


# Invalid/noninteractive requests fail before FreeVision starts.
INVALID_HOME = stlib.fresh_home('ssh-entry-invalid')
invalid = run_cli(['--ssh-entry'], INVALID_HOME,
                  env={'SSH_CONNECTION': '', 'SSH_TTY': ''})
check('direct entry without SSH rejected', invalid.returncode != 0 and
      'pty' in invalid.stderr.lower())
no_tty = run_cli(['--ssh-entry'], INVALID_HOME,
                 env={'SSH_CONNECTION': '127.0.0.1 1 127.0.0.1 2',
                      'SSH_TTY': ''})
check('SSH request without PTY rejected', no_tty.returncode != 0 and
      'pty' in no_tty.stderr.lower())
remote_cmd = run_cli(['--ssh-entry'], INVALID_HOME,
                     env=ssh_env(2, 'uname -a'))
check('SSH original command rejected', remote_cmd.returncode != 0 and
      'commands' in remote_cmd.stderr.lower())
empty_remote_cmd = run_cli(['--ssh-entry'], INVALID_HOME,
                           env=ssh_env(3, ''))
check('present empty original command is still an exec request',
      empty_remote_cmd.returncode != 0 and
      'commands' in empty_remote_cmd.stderr.lower())
malformed_entry = run_cli(['--ssh-entry', 'extra'], INVALID_HOME,
                          env=ssh_env(4))
check('malformed reserved SSH entry cannot reach TUI',
      malformed_entry.returncode == 2 and
      'additional arguments' in malformed_entry.stderr.lower() and
      not stlib.session_sockets(INVALID_HOME))

# The per-name creation lock is shared with ordinary startup and must remain a
# trusted regular file. A bad inode fails immediately instead of being
# chmodded/replaced or retried as if another creator merely held a valid lock.
for unsafe_kind in ('symlink', 'fifo', 'group-writable'):
    unsafe_home = stlib.fresh_home('ssh-entry-lock-' + unsafe_kind)
    unsafe_sessions = os.path.join(
        unsafe_home, '.superterm', 'sessions')
    os.makedirs(unsafe_sessions, mode=0o700, exist_ok=True)
    unsafe_lock = os.path.join(unsafe_sessions, '.create-session.lock')
    if unsafe_kind == 'symlink':
        target = os.path.join(unsafe_home, 'unrelated-lock-target')
        with open(target, 'w', encoding='ascii'):
            pass
        os.symlink(target, unsafe_lock)
    elif unsafe_kind == 'fifo':
        os.mkfifo(unsafe_lock, mode=0o600)
    else:
        with open(unsafe_lock, 'w', encoding='ascii'):
            pass
        os.chmod(unsafe_lock, 0o620)
    started = time.monotonic()
    unsafe = run_cli(['--ssh-entry'], unsafe_home, env=ssh_env(20))
    check(unsafe_kind + ' creation lock rejected',
          unsafe.returncode != 0 and
          'lock session creation' in unsafe.stderr.lower() and
          time.monotonic() - started < 2.0 and
          not stlib.session_sockets(unsafe_home))


# A stale or hostile Unix listener may accept() and then never produce the
# attach snapshot.  This is especially important for ForceCommand: one bad
# per-user socket must not consume an sshd child forever.
HANG_HOME = stlib.fresh_home('ssh-entry-hung-listener')
with open(os.path.join(HANG_HOME, '.superterm', 'superterm.ini'), 'w',
          encoding='utf-8') as stream:
    stream.write('''[ui]
language=en
background=none
[session]
default_session=hung
default_profile=
''')
hang_dir = os.path.join(HANG_HOME, '.superterm', 'sessions')
os.makedirs(hang_dir, mode=0o700, exist_ok=True)
hang_path = os.path.join(hang_dir, 'hung.sock')
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(hang_path)
listener.listen(1)
hang_stop = threading.Event()
hang_connections = []


def hold_attach_open():
    try:
        conn, _ = listener.accept()
        hang_connections.append(conn)
        hang_stop.wait(5.0)
    except OSError:
        pass


hang_thread = threading.Thread(target=hold_attach_open, daemon=True)
hang_thread.start()
started = time.monotonic()
hung = stlib.Client(HANG_HOME, args=['--ssh-entry'], w=80, h=24,
                    env=dict(ssh_env(4), SUPERTERM_TESTING='1',
                             SUPERTERM_TEST_ATTACH_POLLS='3'), lang='en')
try:
    status = hung.wait_exit(4.0)
    elapsed = time.monotonic() - started
    check('accepted silent session has bounded attach',
          status is not None and elapsed < 3.0)
    check('silent listener cannot publish a daemon',
          not os.path.exists(os.path.join(hang_dir, 'hung.ini')))
finally:
    hung.close()
    hang_stop.set()
    for conn in hang_connections:
        conn.close()
    listener.close()
    hang_thread.join(timeout=1.0)
    try:
        os.unlink(hang_path)
    except FileNotFoundError:
        pass
    stlib.close_all_daemons(HANG_HOME)


# Publication failure after listen() used to tempt the second login into the
# half-created socket while the first creator still held its lock.  The waiter
# must stay behind that lock, observe rollback, and then become the sole real
# creator instead of hanging or inventing a suffixed session.
ROLLBACK_HOME = stlib.fresh_home('ssh-entry-publish-rollback')
with open(os.path.join(ROLLBACK_HOME, '.superterm', 'superterm.ini'), 'w',
          encoding='utf-8') as stream:
    stream.write('''[ui]
language=en
background=none
[session]
server=detach
default_session=rollback
default_profile=rollback-profile
autosave=0
autorestore=0
[profile.rollback-profile]
name=rollback-profile
enabled=1
focused_window=0
windows=main
[profile.rollback-profile.window.main]
enabled=1
layout=L
focused_pane=0
panes=p
[profile.rollback-profile.window.main.pane.p]
enabled=1
cmd=echo ROLLBACK_READY; exec /bin/bash -i
''')
fault = stlib.Client(ROLLBACK_HOME, args=['--ssh-entry'], w=88, h=27,
                     env=dict(ssh_env(5), SUPERTERM_TESTING='1',
                              SUPERTERM_TEST_DAEMON_STAGE='daemon-hang-post',
                              SUPERTERM_TEST_STARTUP_POLLS='15'), lang='en')
recovery = None
rollback_socket = os.path.join(ROLLBACK_HOME, '.superterm', 'sessions',
                               'rollback.sock')
try:
    check('fault creator reaches unpublished listener', wait_for(
        lambda: os.path.exists(rollback_socket), (fault,), timeout=1.2))
    recovery_started = time.monotonic()
    recovery = stlib.Client(
        ROLLBACK_HOME, args=['--ssh-entry'], w=92, h=29,
        env=dict(ssh_env(6), SUPERTERM_TESTING='1',
                 SUPERTERM_TEST_CREATE_POLLS='100',
                 SUPERTERM_TEST_ATTACH_POLLS='10'), lang='en')
    recovered = wait_for(
        lambda: ('ROLLBACK_READY' in recovery.text() and
                 names(ROLLBACK_HOME) == ['rollback']),
        (fault, recovery), timeout=8.0)
    check('waiter recovers failed publication', recovered)
    check('failed publication recovery is bounded',
          time.monotonic() - recovery_started < 7.0)
    check('failed creator exits without stealing session',
          fault.wait_exit(2.0) is not None)
finally:
    if recovery is not None:
        recovery.close()
    fault.close()
    stlib.close_all_daemons(ROLLBACK_HOME)


# Sequential entry: the configured exact session/profile is created once;
# a larger later PTY attaches without renegotiating canonical geometry.
HOME = stlib.fresh_home('ssh-entry')
STARTS = os.path.join(HOME, 'profile-starts.log')
with open(os.path.join(HOME, '.superterm', 'superterm.ini'), 'w',
          encoding='utf-8') as stream:
    stream.write(f'''[ui]
language=en
background=none
[session]
server=detach
default_session=SSH Main
default_profile=ssh-default
autosave=0
autorestore=0

[profile.ssh-default]
name=ssh-default
enabled=1
focused_window=0
windows=main
[profile.ssh-default.window.main]
enabled=1
layout=L
focused_pane=0
panes=p
[profile.ssh-default.window.main.pane.p]
enabled=1
title=SSHENTRY
cmd=echo START >> {STARTS}; echo SSH_ENTRY_READY; exec /bin/bash -i
''')

a = stlib.Client(HOME, args=['--ssh-entry'], w=96, h=30,
                 env=ssh_env(10), lang='en')
b = None
c = None
try:
    a.drain(3.0)
    check('SSH forces persistent server mode', names(HOME) == ['SSH-Main'])
    check('configured profile starts', 'SSH_ENTRY_READY' in a.text())
    check('exact session/profile sidecar',
          sidecar(HOME, 'SSH-Main')['profile'] == 'ssh-default')
    initial_size = pane_size(HOME, 'SSH-Main')
    check('creator establishes pane geometry', initial_size is not None)

    b = stlib.Client(HOME, args=['--ssh-entry'], w=145, h=46,
                     env=ssh_env(11), lang='en')
    drain_all((a, b), 3.0)
    check('later SSH login attaches same daemon',
          names(HOME) == ['SSH-Main'] and b.alive())
    check('later login receives existing screen', 'SSH_ENTRY_READY' in b.text())
    check('attach never changes canonical geometry',
          pane_size(HOME, 'SSH-Main') == initial_size)
    starts = []
    if os.path.exists(STARTS):
        with open(STARTS, encoding='utf-8') as stream:
            starts = stream.read().splitlines()
    check('profile command executed exactly once', starts == ['START'])

    a.send(b'echo SSH_SHARED_TEXT\r', 0.3)
    check('pane output reaches every SSH viewer', wait_for(
        lambda: ('SSH_SHARED_TEXT' in a.text() and
                 'SSH_SHARED_TEXT' in b.text()), (a, b)))

    # A lost network connection terminates only its forced-command client.
    os.kill(b.pid, signal.SIGHUP)
    check('lost SSH client exits', b.wait_exit(5.0) is not None)
    b.close()
    b = None
    check('lost SSH client only detaches', wait_for(
        lambda: names(HOME) == ['SSH-Main'] and
        sidecar(HOME, 'SSH-Main')['attached'] == 1, (a,)))
    a.send(b'echo AFTER_SSH_LOSS\r', 0.6)
    check('remaining client stays writable', 'AFTER_SSH_LOSS' in a.text())

    a.send(b'\x11', 0.2)
    a.send(b'd', 0.8)
    check('explicit detach exits entry client', a.wait_exit(5.0) is not None)
    a.close()
    check('default session survives no viewers', wait_for(
        lambda: names(HOME) == ['SSH-Main']))

    c = stlib.Client(HOME, args=['--ssh-entry'], w=70, h=22,
                     env=ssh_env(12), lang='en')
    c.drain(2.5)
    check('SSH reattach restores live contents',
          'AFTER_SSH_LOSS' in c.text())
    check('reattach still preserves geometry',
          pane_size(HOME, 'SSH-Main') == initial_size)
finally:
    if c is not None:
        c.close()
    if b is not None:
        b.close()
    a.close()
    stlib.close_all_daemons(HOME)


# A forced-command client may create/switch to another live session through
# the ordinary Sessions menu.  Detach must resume that exact session on the
# next SSH login: the daemon already retained its workspace, so only a small
# per-user routing pointer is persisted.  "default" deliberately ignores the
# pointer for administrators who want every login to enter one fixed session.
ROUTE_HOME = stlib.fresh_home('ssh-entry-last-route')
ROUTE_INI = os.path.join(ROUTE_HOME, '.superterm', 'superterm.ini')
with open(ROUTE_INI, 'w', encoding='utf-8') as stream:
    stream.write('''[ui]
language=en
background=none
[session]
server=detach
default_session=home
default_profile=route-profile
ssh_session=last
autosave=0
autorestore=0
[profile.route-profile]
name=route-profile
enabled=1
focused_window=0
windows=main
[profile.route-profile.window.main]
enabled=1
layout=L
focused_pane=0
panes=p
[profile.route-profile.window.main.pane.p]
enabled=1
cmd=echo ROUTE_PROFILE_READY; exec /bin/bash -i
''')

route = stlib.Client(ROUTE_HOME, args=['--ssh-entry'], w=98, h=31,
                     env=ssh_env(70), lang='en')
resumed = None
fixed = None
try:
    check('last-route default session starts',
          route.wait_until(lambda text: 'ROUTE_PROFILE_READY' in text))
    route.send(b"printf 'HOME_ROUTE_MARKER\\n'\r", 0.0)
    check('home route accepts input',
          route.wait_until(lambda text: 'HOME_ROUTE_MARKER' in text))
    check('successful SSH creation records initial route', wait_for(
        lambda: config_value(ROUTE_HOME, 'session',
                             'ssh_last_session') == 'home', (route,)))

    route.send(b'\x1bs', 0.35)       # Alt-S: Sessions
    check('SSH client exposes new-session action',
          route.wait_until(lambda text: 'New session' in text))
    route.send(b'n', 0.45)
    check('SSH new-session dialog selects configured profile',
          route.wait_until(lambda text:
              'Session name:' in text and 'route-profile' in text))
    route.send(b'\r', 0.0)
    check('SSH client switches without closing old session', wait_for(
        lambda: names(ROUTE_HOME) == ['home', 'route-profile'],
        (route,), timeout=12.0))
    route.send(b"printf 'LAST_ROUTE_MARKER\\n'\r", 0.0)
    check('new SSH session accepts input',
          route.wait_until(lambda text: 'LAST_ROUTE_MARKER' in text))
    check('session switch atomically updates last route', wait_for(
        lambda: config_value(ROUTE_HOME, 'session',
                             'ssh_last_session') == 'route-profile',
        (route,)))
    check('routing write preserves configured profile',
          config_value(ROUTE_HOME, 'profile.route-profile', 'name') ==
          'route-profile')

    route.send(b'\x11', 0.2)
    route.send(b'd', 0.8)
    check('last-route client detaches', route.wait_exit(5.0) is not None)
    route.close()
    check('both routed sessions survive detach', wait_for(
        lambda: names(ROUTE_HOME) == ['home', 'route-profile']))

    resumed = stlib.Client(ROUTE_HOME, args=['--ssh-entry'], w=76, h=23,
                           env=ssh_env(71), lang='en')
    check('next SSH login resumes session created in menu',
          resumed.wait_until(lambda text: 'LAST_ROUTE_MARKER' in text))
    check('resumed SSH login did not fall back to default',
          'HOME_ROUTE_MARKER' not in resumed.text())
    resumed.send(b'\x11', 0.2)
    resumed.send(b'd', 0.8)
    check('resumed last-route client detaches',
          resumed.wait_exit(5.0) is not None)
    resumed.close()
    resumed = None

    # Change only the routing policy, retaining a deliberately different live
    # last pointer.  The next entry must choose the configured fixed default.
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    with open(ROUTE_INI, encoding='utf-8') as stream:
        parser.read_file(stream)
    parser.set('session', 'ssh_session', 'default')
    parser.set('session', 'ssh_last_session', 'route-profile')
    with open(ROUTE_INI, 'w', encoding='utf-8') as stream:
        parser.write(stream)

    fixed = stlib.Client(ROUTE_HOME, args=['--ssh-entry'], w=85, h=26,
                         env=ssh_env(72), lang='en')
    check('fixed routing ignores last-session pointer',
          fixed.wait_until(lambda text: 'HOME_ROUTE_MARKER' in text))
    check('fixed routing did not attach alternate session',
          'LAST_ROUTE_MARKER' not in fixed.text())
finally:
    if fixed is not None:
        fixed.close()
    if resumed is not None:
        resumed.close()
    route.close()
    stlib.close_all_daemons(ROUTE_HOME)


# Simultaneous first logins contend on the creation lock but publish one
# exact daemon and execute the profile command once, never race-N suffixes.
RACE_HOME = stlib.fresh_home('ssh-entry-race')
RACE_STARTS = os.path.join(RACE_HOME, 'starts.log')
with open(os.path.join(RACE_HOME, '.superterm', 'superterm.ini'), 'w',
          encoding='utf-8') as stream:
    stream.write(f'''[ui]
language=en
background=none
[session]
server=detach
default_session=race
default_profile=race-profile
autosave=0
autorestore=0
[profile.race-profile]
name=race-profile
enabled=1
focused_window=0
windows=main
[profile.race-profile.window.main]
enabled=1
layout=L
focused_pane=0
panes=p
[profile.race-profile.window.main.pane.p]
enabled=1
cmd=echo ONE >> {RACE_STARTS}; echo RACE_READY; exec /bin/bash -i
''')

gate_read, gate_write = os.pipe()
racers = []
try:
    racers = [stlib.Client(RACE_HOME, args=['--ssh-entry'],
                           w=90 + i * 5, h=28 + i,
                           env=ssh_env(30 + i), lang='en',
                           start_gate_fd=gate_read)
              for i in range(4)]
    os.close(gate_read)
    gate_read = -1
    os.write(gate_write, b'R' * len(racers))
    os.close(gate_write)
    gate_write = -1
except Exception:
    if gate_read >= 0:
        os.close(gate_read)
    if gate_write >= 0:
        # Release every already-created child before propagating the setup
        # failure, so fixture cleanup can still reap them.
        try:
            os.write(gate_write, b'R' * len(racers))
        except OSError:
            pass
        os.close(gate_write)
    raise
try:
    ready = wait_for(
        lambda: (names(RACE_HOME) == ['race'] and
                 all('RACE_READY' in client.text() for client in racers)),
        racers, timeout=15.0)
    check('simultaneous logins all attach', ready)
    check('race creates one exact session', names(RACE_HOME) == ['race'])
    race_lines = []
    if os.path.exists(RACE_STARTS):
        with open(RACE_STARTS, encoding='utf-8') as stream:
            race_lines = stream.read().splitlines()
    check('race executes profile once', race_lines == ['ONE'])
    check('race records every viewer', sidecar(RACE_HOME, 'race')['attached'] == 4)
finally:
    for client in racers:
        client.close()
    stlib.close_all_daemons(RACE_HOME)


# Missing/default-invalid profile intentionally creates a persistent empty
# desktop. It reattaches as-is and can later receive its first normal pane.
EMPTY_HOME = stlib.fresh_home('ssh-entry-empty')
with open(os.path.join(EMPTY_HOME, '.superterm', 'superterm.ini'), 'w',
          encoding='utf-8') as stream:
    stream.write('''[ui]
language=en
background=none
[session]
server=detach
default_session=void
default_profile=does-not-exist
autosave=0
autorestore=0
''')

empty = stlib.Client(EMPTY_HOME, args=['--ssh-entry'], w=88, h=27,
                     env=ssh_env(60), lang='en')
try:
    empty.drain(2.5)
    check('missing profile creates empty session',
          names(EMPTY_HOME) == ['void'] and
          sidecar(EMPTY_HOME, 'void')['panes'] == 0)
    check('empty session draws no pane frame',
          not any(('╔' in row or '┌' in row)
                  for row in empty.screen.display))
    empty.send(b'\x1bc', 0.3)
    empty.send(b'1', 1.5)
    check('empty SSH session accepts first pane', wait_for(
        lambda: sidecar(EMPTY_HOME, 'void')['panes'] == 1, (empty,)))
finally:
    empty.close()
    stlib.close_all_daemons(EMPTY_HOME)

stlib.report()
