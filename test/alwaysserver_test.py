#!/usr/bin/env python3
"""superterm test: always-server (every session is born with a daemon).

Covers: socket and sidecar at launch, CLI control from startup,
automatic names and --session, Alt-Q kills without saving, Alt-X kills
and saves, detach with no dialog, a hard-killed client leaves the daemon
alive, self-cleanup once all panes are dead, and the escape hatch
[session] server=detach (classic mode).
"""
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli

HOME = stlib.fresh_home('always')
SESS_INI = HOME + '/.superterm/session.ini'


def socks():
    return stlib.session_sockets(HOME)


def wait_for(pred, timeout=8.0):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.2)
    return pred()


# ---- 1: a server already exists at launch and the CLI can drive it ----
a = stlib.Client(HOME, w=100, h=28)
a.drain(2.0)
check('socket exists at launch', wait_for(lambda: len(socks()) == 1))
name = os.path.basename(socks()[0])[:-5]
check('auto name is session', name == 'session')
r = run_cli(['list'], HOME, env={'LANG': 'C'})
check('list works from launch', r.returncode == 0 and 'session' in r.stdout)
r = run_cli(['send', '.', 'echo LIVE_FROM_CLI'], HOME)
check('send works from launch', r.returncode == 0)
a.wait_until(lambda t: 'LIVE_FROM_CLI' in t)
check('client shows CLI text', 'LIVE_FROM_CLI' in a.text())
r = run_cli(['capture', '.'], HOME)
check('capture works from launch', 'LIVE_FROM_CLI' in r.stdout)

# ---- 2: Alt-Q kills the daemon without saving ----
if os.path.exists(SESS_INI):
    os.remove(SESS_INI)
a.send(b'\x1bq', 1.0)
check('Alt-Q exits client', a.wait_exit(timeout=8.0) is not None)
a.close()
check('Alt-Q kills the daemon', wait_for(lambda: socks() == []))
check('Alt-Q does not save', not os.path.exists(SESS_INI))

# ---- 3: --session FreeFormName and collision -> suffix ----
b = stlib.Client(HOME, args=['--session', 'Trabajo Uno'], w=100, h=28)
b.drain(2.0)
check('named session sanitized', wait_for(
    lambda: any('Trabajo' in s for s in socks())))
c = stlib.Client(HOME, args=['--session', 'Trabajo Uno'], w=100, h=28)
c.drain(2.5)
c.send(b'\x1b', 0.6)   # the selector appears (a live session exists): Esc = new
c.drain(1.5)
check('collision gets suffix', wait_for(
    lambda: len([s for s in socks() if 'Trabajo' in s]) == 2))
c.send(b'\x1bq', 1.0)
c.wait_exit(timeout=8.0)
c.close()

# ---- 4: detach with no dialog; hard-killing the client leaves the daemon ----
b.send(b'\x11', 0.4)
b.send(b'd', 1.0)
check('detach exits with no prompt', b.wait_exit(timeout=8.0) is not None)
b.close()
check('daemon survives detach', any('Trabajo' in s for s in socks()))

d = stlib.Client(HOME, args=['--attach'], w=100, h=28)
d.drain(2.0)
os.kill(d.pid, signal.SIGKILL)   # murdered client: the session must not fall
time.sleep(1.0)
d.close()
check('daemon survives killed client', any('Trabajo' in s for s in socks()))
e = stlib.Client(HOME, args=['--attach'], w=100, h=28)
e.drain(2.0)
e.send(b'echo BACK_AGAIN\r', 1.0)
check('reattach after kill works', 'BACK_AGAIN' in e.text())

# ---- 5: Alt-X kills and saves session.ini daemon-side ----
if os.path.exists(SESS_INI):
    os.remove(SESS_INI)
e.send(b'\x1bx', 1.0)
check('Alt-X exits client', e.wait_exit(timeout=8.0) is not None)
e.close()
check('Alt-X kills the daemon', wait_for(lambda: socks() == []))
check('Alt-X saves session.ini', wait_for(
    lambda: os.path.exists(SESS_INI), timeout=4.0))

# ---- 6: self-cleanup: dead panes and no clients -> shuts itself down ----
f = stlib.Client(HOME, env={'SUPERTERM_REAP_MS': '2500'}, w=100, h=28)
f.drain(2.0)
f.send(b'exit\r', 1.2)           # the only shell dies
f.send(b'\x11', 0.4)             # detach leaving the dead pane behind
f.send(b'd', 1.0)
f.wait_exit(timeout=8.0)
f.close()
check('dead session self-reaps', wait_for(lambda: socks() == [], timeout=15.0))

# ---- 7: escape hatch: server=detach = classic behavior ----
os.makedirs(HOME + '/.superterm', exist_ok=True)
with open(HOME + '/.superterm/superterm.ini', 'w') as fh:
    fh.write('[session]\nserver=detach\n')
g = stlib.Client(HOME, w=100, h=28)
g.drain(2.0)
check('server=detach: no socket at launch', socks() == [])
g.send(b'\x11', 0.4)
g.send(b'd', 0.9)
check('server=detach: detach asks name', 'Session name' in g.text() or
      'Nombre' in g.text())
g.send(b'\r', 1.5)               # accept the suggested name
g.wait_exit(timeout=8.0)
g.close()
check('server=detach: detach creates daemon', wait_for(
    lambda: len(socks()) == 1))
r = run_cli(['kill', '.'], HOME)
check('kill needs explicit name', r.returncode != 0)
name = os.path.basename(socks()[0])[:-5]
r = run_cli(['kill', name], HOME)
check('cleanup kill exit 0', r.returncode == 0)
check('all gone', wait_for(lambda: socks() == []))

stlib.report()
