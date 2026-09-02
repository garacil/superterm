#!/usr/bin/env python3
"""PTY publication is bounded and carries a verifiable child generation.

The password transport is deliberately exercised with a test-owned executable
named ``sshpass``.  One mode execs successfully but never reads fd 3: a secret
larger than any ordinary pipe must make pane creation fail within the fixed
non-blocking budget, without parking the daemon.  The other mode drains fd 3
and proves byte-for-byte delivery of a multi-write secret.  A guarded fault
hook finally proves that an empty kernel birth identity cannot publish a pane
or a session.
"""

import base64
import configparser
import glob
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


def encode_secret(value):
    return base64.b64encode(value).decode('ascii')


def wait_until(predicate, clients=(), timeout=8.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.03)
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


def pane_rows(output):
    return [line for line in output.splitlines()
            if line and line[0].isdigit()]


def session_identity(home, session):
    path = os.path.join(home, '.superterm', 'sessions', session + '.ini')
    cp = configparser.ConfigParser()
    try:
        cp.read(path)
        return (cp.getint('session', 'pid', fallback=0),
                cp.get('session', 'pid_identity', fallback='').strip())
    except (OSError, ValueError):
        return 0, ''


def write_base_config(home, blocker_secret, reader_secret, closer_secret):
    path = os.path.join(home, '.superterm', 'superterm.ini')
    with open(path, 'w', encoding='utf-8') as stream:
        stream.write(f'''[ui]
language=en
background=none
[autologin]
shell=/bin/bash
login=0
[session]
server=always
default_profile=spawn-base
default_window=main
autosave=0
autorestore=0

[class.blocker]
name=blocker
enabled=1
title=BLOCKER
host=fake.invalid
password={encode_secret(blocker_secret)}

[class.reader]
name=reader
enabled=1
title=READER
host=fake.invalid
password={encode_secret(reader_secret)}

[class.closer]
name=closer
enabled=1
title=CLOSER
host=fake.invalid
password={encode_secret(closer_secret)}

[profile.spawn-base]
name=spawn-base
enabled=1
focused_window=0
windows=main
[profile.spawn-base.window.main]
enabled=1
layout=L
focused_pane=0
panes=stable
[profile.spawn-base.window.main.pane.stable]
enabled=1
title=STABLE
cmd=exec /bin/bash --noprofile --norc -i
''')


def write_local_close_config(home, closer_secret):
    """Boot one sshpass class before any detached server can ignore SIGPIPE."""
    path = os.path.join(home, '.superterm', 'superterm.ini')
    with open(path, 'w', encoding='utf-8') as stream:
        stream.write(f'''[ui]
language=en
background=none
[autologin]
shell=/bin/bash
login=0
[session]
server=detach
default_profile=local-close
default_window=main
autosave=0
autorestore=0

[class.closer]
name=closer
enabled=1
title=CLOSER
host=fake.invalid
password={encode_secret(closer_secret)}

[profile.local-close]
name=local-close
enabled=1
focused_window=0
windows=main
[profile.local-close.window.main]
enabled=1
layout=L
focused_pane=0
panes=closed
[profile.local-close.window.main.pane.closed]
enabled=1
class=closer
''')


def write_local_kill_config(home, pid_file):
    """Keep one signal-resistant direct child for the KillPane fallback."""
    path = os.path.join(home, '.superterm', 'superterm.ini')
    with open(path, 'w', encoding='utf-8') as stream:
        stream.write(f'''[ui]
language=en
background=none
[autologin]
shell=/bin/bash
login=0
[session]
server=detach
default_profile=local-kill
default_window=main
autosave=0
autorestore=0
[profile.local-kill]
name=local-kill
enabled=1
focused_window=0
windows=main
[profile.local-kill.window.main]
enabled=1
layout=L
focused_pane=0
panes=resistant
[profile.local-kill.window.main.pane.resistant]
enabled=1
title=RESISTANT
cmd=trap '' HUP TERM; printf '%s\\n' $$ > {pid_file}; while :; do /bin/sleep 30; done
''')


def write_identity_config(home):
    path = os.path.join(home, '.superterm', 'superterm.ini')
    with open(path, 'w', encoding='utf-8') as stream:
        stream.write('''[ui]
language=en
background=none
[autologin]
shell=/bin/bash
login=0
[session]
server=always
default_session=identity-empty
default_profile=identity
default_window=main
autosave=0
autorestore=0
[profile.identity]
name=identity
enabled=1
focused_window=0
windows=main
[profile.identity.window.main]
enabled=1
layout=L
focused_pane=0
panes=p
[profile.identity.window.main.pane.p]
enabled=1
title=IDENTITY
cmd=exec /bin/bash --noprofile --norc -i
''')


HOME = stlib.fresh_home('pty-spawn-safety')
BIN_DIR = os.path.join(HOME, 'bin')
MODE_FILE = os.path.join(HOME, 'fake-sshpass.mode')
RECEIVED_FILE = os.path.join(HOME, 'fake-sshpass.received')
HELPER = os.path.join(BIN_DIR, 'sshpass')

os.makedirs(BIN_DIR, mode=0o700)
with open(HELPER, 'w', encoding='utf-8') as stream:
    stream.write(f'''#!/bin/sh
mode=$(/bin/cat {MODE_FILE!r} 2>/dev/null)
if test "$mode" = read; then
  /bin/cat <&3 > {RECEIVED_FILE!r}
  exec /bin/bash --noprofile --norc -i
fi
if test "$mode" = close; then
  exec 3<&-
  exit 0
fi
exec /bin/sleep 30
''')
os.chmod(HELPER, 0o700)

# Both values exceed conservative GNU and Darwin pipe capacities.  The reader
# case therefore proves partial-write continuation, not just one lucky write.
BLOCKER_SECRET = b'B' * (256 * 1024) + b':BLOCKER-END'
READER_SECRET = (b'reader-0123456789-ABCDEF:' * 8192) + b'READER-END'
CLOSER_SECRET = b'C' * (256 * 1024) + b':CLOSER-END'
write_base_config(HOME, BLOCKER_SECRET, READER_SECRET, CLOSER_SECRET)
with open(MODE_FILE, 'w', encoding='ascii') as stream:
    stream.write('noread\n')

client = None
try:
    client = stlib.Client(HOME, w=96, h=30, lang='en', env={
        'PATH': BIN_DIR + os.pathsep + os.environ.get('PATH', ''),
        'SUPERTERM_TESTING': '1',
        # Four fixed 100 ms no-progress polls keep the negative case fast.
        'SUPERTERM_TEST_PTY_EXEC_POLLS': '4',
    })
    session = ''

    def find_session():
        nonlocal_sockets = stlib.session_sockets(HOME)
        if len(nonlocal_sockets) != 1:
            return False
        return True

    ready = wait_until(find_session, (client,), timeout=12.0)
    sockets = stlib.session_sockets(HOME)
    if len(sockets) == 1:
        session = os.path.basename(sockets[0])[:-5]
    check('base daemon publishes one session', ready and bool(session))
    before = run_cli(['list', session], HOME, env={'LANG': 'C'}) \
        if session else None
    check('base daemon starts with one stable pane', before is not None and
          before.returncode == 0 and len(pane_rows(before.stdout)) == 1)
    daemon_before = session_identity(HOME, session) if session else (0, '')
    check('base daemon has a birth identity', daemon_before[0] > 1 and
          bool(daemon_before[1]))

    started = time.monotonic()
    blocked = run_cli(['new', session, '--class', 'blocker'], HOME,
                      timeout=6.0) if session else None
    blocked_elapsed = time.monotonic() - started
    check('non-reading sshpass is bounded', blocked is not None and
          blocked_elapsed < 2.0)
    check('incomplete password rejects pane', blocked is not None and
          blocked.returncode != 0)
    after_block = run_cli(['list', session], HOME, env={'LANG': 'C'}) \
        if session else None
    check('failed password pane is never published',
          after_block is not None and after_block.returncode == 0 and
          len(pane_rows(after_block.stdout)) == 1)
    check('failed spawn keeps exact daemon generation',
          session_identity(HOME, session) == daemon_before)

    marker = 'SPAWN_SAFE_481'
    sent = run_cli(['send', f'{session}:1',
                    "printf 'SPAWN_%s_481\\n' SAFE"], HOME) \
        if session else None
    capture = ''

    def stable_replied():
        nonlocal_capture = run_cli(['capture', f'{session}:1'], HOME)
        if nonlocal_capture.returncode == 0:
            capture_holder[0] = nonlocal_capture.stdout
        return marker in capture_holder[0]

    capture_holder = ['']
    responsive = (sent is not None and sent.returncode == 0 and
                  wait_until(stable_replied, (client,), timeout=5.0))
    capture = capture_holder[0]
    check('daemon remains responsive after rejected spawn',
          responsive and marker in capture)

    # The exec handshake may complete just before the helper closes fd 3.
    # A secret larger than the pipe capacity guarantees that the writer meets
    # the closed reader even if its first partial write wins that race.
    with open(MODE_FILE, 'w', encoding='ascii') as stream:
        stream.write('close\n')
    started = time.monotonic()
    closed = run_cli(['new', session, '--class', 'closer'], HOME,
                     timeout=6.0) if session else None
    closed_elapsed = time.monotonic() - started
    check('closed password fd is bounded', closed is not None and
          closed_elapsed < 2.0)
    check('closed password fd rejects pane', closed is not None and
          closed.returncode != 0)
    after_close = run_cli(['list', session], HOME, env={'LANG': 'C'}) \
        if session else None
    check('closed password pane is never published',
          after_close is not None and after_close.returncode == 0 and
          len(pane_rows(after_close.stdout)) == 1)
    check('closed password fd keeps daemon alive',
          session_identity(HOME, session) == daemon_before)

    with open(MODE_FILE, 'w', encoding='ascii') as stream:
        stream.write('read\n')
    started = time.monotonic()
    reader = run_cli(['new', session, '--class', 'reader'], HOME,
                     timeout=8.0) if session else None
    reader_elapsed = time.monotonic() - started
    check('reading sshpass pane is accepted', reader is not None and
          reader.returncode == 0 and reader_elapsed < 5.0)
    received = b''

    def complete_secret():
        try:
            with open(RECEIVED_FILE, 'rb') as stream:
                received_holder[0] = stream.read()
        except OSError:
            return False
        return len(received_holder[0]) >= len(READER_SECRET)

    received_holder = [b'']
    secret_ready = wait_until(complete_secret, (client,), timeout=5.0)
    received = received_holder[0]
    check('password reader receives every byte exactly',
          secret_ready and received == READER_SECRET)
    after_reader = run_cli(['list', session], HOME, env={'LANG': 'C'}) \
        if session else None
    check('successful password pane is published once',
          after_reader is not None and after_reader.returncode == 0 and
          len(pane_rows(after_reader.stdout)) == 2)
finally:
    stlib.close_all_daemons(HOME)
    if client is not None:
        client.wait_exit(3.0)
        client.close()


# SpawnInternal also runs directly in the UI for server=detach, before the
# detached reactor installs its process-wide SIGPIPE policy.  The same helper
# closing fd 3 must reject the class and fall back normally, never terminate
# the SuperTerm process with SIGPIPE.
LOCAL_HOME = stlib.fresh_home('pty-close-sigpipe-local')
write_local_close_config(LOCAL_HOME, CLOSER_SECRET)
with open(MODE_FILE, 'w', encoding='ascii') as stream:
    stream.write('close\n')
local_client = None
try:
    local_client = stlib.Client(LOCAL_HOME, w=88, h=27, lang='en', env={
        'PATH': BIN_DIR + os.pathsep + os.environ.get('PATH', ''),
        'SUPERTERM_TESTING': '1',
        'SUPERTERM_TEST_PTY_EXEC_POLLS': '4',
    })
    local_client.drain(2.0)
    check('closed fd cannot SIGPIPE local UI',
          local_client.wait_exit(0.0) is None)
    check('failed local secret creates no daemon',
          stlib.session_sockets(LOCAL_HOME) == [])
    check('failed local class uses explicit fallback',
          'FAILED' in local_client.text())
finally:
    if local_client is not None:
        if local_client.wait_exit(0.0) is None:
            local_client.send(b'\x1bx', 0.5)
        local_client.wait_exit(3.0)
        local_client.close()


# ProcBirthIdentity can fail transiently even after a pane was published.  A
# zero return from waitpid(child, WNOHANG) is independent kernel proof that
# the numeric PID still denotes this caller's exact direct, unreaped child.
# Force only the identity query in KillPane to fail and require the resistant
# group to be killed and reaped during normal local UI shutdown.
KILL_HOME = stlib.fresh_home('pty-kill-parent-authority')
KILL_PID_FILE = os.path.join(KILL_HOME, 'resistant.pid')
write_local_kill_config(KILL_HOME, KILL_PID_FILE)
kill_client = None
kill_pid = 0
kill_identity = ''
try:
    kill_client = stlib.Client(KILL_HOME, w=88, h=27, lang='en', env={
        'SUPERTERM_TESTING': '1',
        'SUPERTERM_TEST_PTY_KILL_IDENTITY_FAIL': '1',
    })

    def resistant_started():
        nonlocal_pid = 0
        try:
            with open(KILL_PID_FILE, encoding='ascii') as stream:
                nonlocal_pid = int(stream.read().strip())
        except (OSError, ValueError):
            return False
        kill_pid_holder[0] = nonlocal_pid
        return stlib.process_identity(nonlocal_pid) != ''

    kill_pid_holder = [0]
    started = wait_until(resistant_started, (kill_client,), timeout=5.0)
    kill_pid = kill_pid_holder[0]
    kill_identity = stlib.process_identity(kill_pid) if kill_pid > 1 else ''
    if kill_pid > 1:
        stlib.register_process(kill_pid, 'pty-kill-parent-authority-pane')
    check('resistant direct child starts', started and bool(kill_identity))
    began_exit = time.monotonic()
    if kill_client.wait_exit(0.0) is None:
        kill_client.send(b'\x1bx', 0.2)
    kill_status = kill_client.wait_exit(5.0)
    kill_elapsed = time.monotonic() - began_exit
    killed = wait_until(
        lambda: stlib.process_identity(kill_pid) != kill_identity,
        timeout=3.0) if kill_identity else False
    check('waitpid authority bounds local shutdown',
          kill_status == 0 and kill_elapsed < 4.0)
    check('waitpid authority reaps exact child', killed)
finally:
    if (kill_pid > 1 and kill_identity and
            stlib.process_identity(kill_pid) == kill_identity):
        try:
            os.killpg(kill_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        wait_until(lambda: stlib.process_identity(kill_pid) != kill_identity,
                   timeout=2.0)
    if (kill_pid > 1 and kill_identity and
            stlib.process_identity(kill_pid) != kill_identity):
        stlib.unregister_process(kill_pid)
    elif (kill_pid > 1 and kill_identity and
          stlib.process_identity(kill_pid) == kill_identity):
        # Keep its generation-qualified registry entry alive.  The outer
        # runner must see and report a process which survived this test's
        # exact group cleanup; a bare process_done would hide the leak.
        check('resistant child leaves no cleanup survivor', False)
    if kill_client is not None:
        if kill_client.wait_exit(0.0) is None:
            kill_client.send(b'\x1bx', 0.2)
        kill_client.wait_exit(3.0)
        kill_client.close()


# Empty identity is a separate startup so the hook cannot affect the two real
# password transports above.  It must fail before READY and leave no sidecar.
IDENTITY_HOME = stlib.fresh_home('pty-empty-identity')
write_identity_config(IDENTITY_HOME)
identity_client = None
try:
    started = time.monotonic()
    identity_client = stlib.Client(
        IDENTITY_HOME, args=['--ssh-entry'], w=88, h=27, lang='en', env={
        'SSH_CONNECTION': '127.0.0.1 44991 127.0.0.1 8022',
        'SSH_TTY': '/dev/pts/superterm-identity-test',
        'SUPERTERM_TESTING': '1',
        'SUPERTERM_TEST_PTY_EMPTY_IDENTITY': '1',
        'SUPERTERM_TEST_PTY_EXEC_POLLS': '4',
    })
    identity_status = identity_client.wait_exit(4.0)
    identity_elapsed = time.monotonic() - started
    no_socket = wait_until(
        lambda: stlib.session_sockets(IDENTITY_HOME) == [],
        (identity_client,), timeout=3.0)
    sidecars = glob.glob(os.path.join(
        IDENTITY_HOME, '.superterm', 'sessions', '*.ini'))
    check('empty birth identity fails within bound',
          identity_status is not None and identity_elapsed < 4.0)
    check('empty birth identity publishes no session', no_socket)
    check('empty birth identity publishes no sidecar', sidecars == [])
finally:
    stlib.close_all_daemons(IDENTITY_HOME)
    if identity_client is not None:
        identity_client.wait_exit(3.0)
        identity_client.close()


stlib.report()
