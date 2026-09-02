#!/usr/bin/env python3
"""Exit and detach have one unambiguous live-session lifetime.

Covers secondary Exit, last-client Exit, Detach, and the separate
administrative kill path. There is no save/no-save exit variant. This is a
real multi-client UI test: it exercises the final layout sent during
TSuperApp teardown before FRAME_CLOSE, not only a synthetic protocol frame.
"""
import configparser
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('multiclient-close')
SESS_INI = HOME + '/.superterm/session.ini'

with open(HOME + '/.superterm/superterm.ini', 'w') as fh:
    fh.write('[ui]\nlanguage=en\nbackground=none\n'
             '[session]\nserver=always\nautosave=1\nautorestore=0\n')


def wait_for(pred, timeout=8.0):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.1)
    return pred()


def sockets():
    return stlib.session_sockets(HOME)


def wait_daemon_claim(session, timeout=8.0):
    """Return only a complete sidecar claim matching its live generation."""
    path = os.path.join(
        HOME, '.superterm', 'sessions', session + '.ini')
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            meta = configparser.ConfigParser()
            meta.read(path)
            pid = meta.getint('session', 'pid', fallback=0)
            identity = meta.get(
                'session', 'pid_identity', fallback='').strip()
            if (pid > 1 and identity and
                    stlib.process_identity(pid) == identity):
                return pid, identity
        except (OSError, ValueError, configparser.Error):
            pass
        time.sleep(0.02)
    return 0, ''


# Reproduce the reported failure literally: A creates the session and remains
# attached, then B attaches and exits while exactly those two clients exist.
a = stlib.Client(HOME, w=110, h=32, lang='en')
a.drain(2.0)
check('creator session exists', wait_for(lambda: len(sockets()) == 1))
name = os.path.basename(sockets()[0])[:-5] if sockets() else ''

b = stlib.Client(HOME, args=['--attach', name], w=95, h=28, lang='en')
b.drain(2.0)
check('second client attaches', b.alive())

run_cli(['send', name + ':1', 'echo BOTH_CONNECTED'], HOME)
for client in (a, b):
    client.wait_until(lambda text: 'BOTH_CONNECTED' in text, 5.0)
check('both clients receive output', all(
    'BOTH_CONNECTED' in client.text() for client in (a, b)))

# Exit closes only B because creator A remains attached. Even autosave=1 must
# not resurrect the removed Save-and-exit protocol path.
if os.path.exists(SESS_INI):
    os.remove(SESS_INI)
b.send(b'\x1bx', 1.0)
check('attached Alt-X exits sender', b.wait_exit(timeout=8.0) == 0)
b.close()
check('secondary Exit keeps creator alive', a.alive())
check('secondary Exit keeps session alive', len(sockets()) == 1)
check('secondary Exit does not save', not os.path.exists(SESS_INI))

# The same single Exit path remains per-client with a replacement viewer.
c = stlib.Client(HOME, args=['--attach', name], w=80, h=24, lang='en')
c.drain(2.0)
check('replacement client attaches', c.alive())
c.send(b'\x1bx', 1.0)
check('replacement Exit exits sender', c.wait_exit(timeout=8.0) == 0)
c.close()
check('replacement Exit keeps creator alive', a.alive())
check('replacement Exit keeps session alive', len(sockets()) == 1)
run_cli(['send', name + ':1', 'echo CREATOR_STILL_WORKS'], HOME)
a.wait_until(lambda text: 'CREATOR_STILL_WORKS' in text, 5.0)
check('remaining client remains usable', 'CREATOR_STILL_WORKS' in a.text())

# With A now the only attached UI, the same interactive exit closes the daemon.
a.send(b'\x1bx', 1.0)
check('last client exits', a.wait_exit(timeout=8.0) == 0)
a.close()
check('last client closes session', wait_for(lambda: sockets() == []))
check('last Exit leaves no saved session', not os.path.exists(SESS_INI))

# Administrative `kill` is intentionally global even while clients exist.
d = stlib.Client(HOME, args=['--session', 'admin-kill'], w=100, h=28,
                 lang='en')
d.drain(2.0)
check('admin session exists', wait_for(lambda: len(sockets()) == 1))
admin_name = os.path.basename(sockets()[0])[:-5] if sockets() else ''
admin_pid, admin_identity = wait_daemon_claim(admin_name)
check('admin daemon publishes an exact process identity',
      admin_pid > 1 and bool(admin_identity) and
      stlib.process_identity(admin_pid) == admin_identity)
e = stlib.Client(HOME, args=['--attach', admin_name], w=90, h=26,
                 lang='en')
e.drain(2.0)
check('admin second client attaches', e.alive())
result = run_cli(['kill', admin_name], HOME)
check('administrative kill succeeds', result.returncode == 0)
check('administrative kill closes session', wait_for(lambda: sockets() == []))
# Keep both client processes alive below while requiring the daemon generation
# itself to disappear.  A direct child left as Z under the creator retains the
# same birth identity and fails this oracle; socket removal or kill(pid, 0)
# alone cannot distinguish that historical Darwin regression.
check('administrative kill fully reaps daemon', wait_for(
    lambda: (admin_pid > 1 and bool(admin_identity) and
             stlib.process_identity(admin_pid) != admin_identity),
    timeout=8.0))
# Both UIs receive the existing "session was closed" notice. Confirming it is
# what terminates their client processes; this matches multiclient_test.py.
time.sleep(1.5)
d.send(b'\r', 0.5)
e.send(b'\r', 0.5)
check('administrative kill notifies creator',
      d.wait_exit(timeout=8.0) == 0)
check('administrative kill notifies attached',
      e.wait_exit(timeout=8.0) == 0)
d.close()
e.close()

stlib.report()
