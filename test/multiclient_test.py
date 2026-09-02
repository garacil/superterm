#!/usr/bin/env python3
"""superterm test: several interactive clients on the same session.

Covers: versioned attach and legacy client exclusivity, output broadcast to
all clients, live window management (rename/new/close via CLI), one canonical
geometry, laggard disconnection and the shutdown notice.
"""
import os
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import (FRAME_ATTACH, FRAME_READY, FRAME_SCREEN, FRAME_SESSION,
                   check, raw_frame, read_frame, run_cli)

PROTO_VER = stlib.attach_proto_ver()

HOME = stlib.fresh_home('multiclient')
with open(HOME + '/.superterm/superterm.ini', 'w') as config:
    config.write('[ui]\n'
                 'language=en\n'
                 'palette=color\n'
                 'background=none\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n')


def clients_column(home):
    """CLIENTS from the session row: the token before the CREATED date."""
    r = run_cli(['list'], home, env={'LANG': 'C'})
    for line in r.stdout.splitlines():
        toks = line.split()
        if len(toks) >= 4 and toks[0] != 'NAME':
            try:
                return int(toks[-3])
            except ValueError:
                continue
    return -1


def attach_raw(sock_path, payload):
    """Raw ATTACH; returns (socket, ok_snapshot)."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(8.0)
    s.connect(sock_path)
    s.sendall(raw_frame(FRAME_ATTACH, -1, payload))
    ok = False
    try:
        fr = read_frame(s, timeout=5.0)
        if fr is not None and fr[0] == FRAME_SESSION:
            while True:
                fr = read_frame(s, timeout=5.0)
                if fr is None:
                    break
                if fr[0] == FRAME_READY:
                    ok = True
                    break
                if fr[0] != FRAME_SCREEN:
                    break
    except (socket.timeout, OSError):
        pass
    return s, ok


# ---- detached session with 1 pane ----
c = stlib.Client(HOME, w=100, h=28)
c.drain(2.0)
c.send(b'\x11', 0.4)
c.send(b'd', 0.9)
c.send(b'\r', 1.5)
time.sleep(0.6)
c.close()
socks = stlib.session_sockets(HOME)
check('detached session exists', len(socks) == 1)
SOCK = socks[0]
SES = os.path.basename(SOCK)[:-5]

# ---- legacy client (ATTACH with no payload) alone, still works ----
s, ok = attach_raw(SOCK, b'')
check('legacy attach alone still served', ok)
s.close()
time.sleep(0.8)

# ---- two real interactive clients ----
a = stlib.Client(HOME, args=['--attach'], w=100, h=28)
a.drain(2.5)
b = stlib.Client(HOME, args=['--attach'], w=80, h=24)
b.drain(2.5)
check('client A attached', a.alive())
check('client B attached', b.alive())
check('two clients listed', clients_column(HOME) == 2)

# ---- input from A is seen by both A and B (merge + broadcast) ----
a.send(b'echo MC_TOKEN_77\r', 0.5)
a.wait_until(lambda t: 'MC_TOKEN_77' in t)
b.wait_until(lambda t: 'MC_TOKEN_77' in t)
check('client A sees its own input', 'MC_TOKEN_77' in a.text())
check('client B sees broadcast output', 'MC_TOKEN_77' in b.text())

# ---- ephemeral control keeps working with 2 attached ----
r = run_cli(['capture', '.'], HOME)
check('capture with 2 clients', r.returncode == 0 and 'MC_TOKEN_77' in r.stdout)

# ---- a legacy client is rejected while v2 clients exist ----
s, ok = attach_raw(SOCK, b'')
check('legacy attach rejected while shared', not ok)
s.close()

# ---- LIVE window management (the F3 guard no longer exists) ----
r = run_cli(['rename', SES + ':1', 'Panel Compartido'], HOME)
check('rename while attached exit 0', r.returncode == 0)
a.wait_until(lambda t: 'Panel Compartido' in t)
b.wait_until(lambda t: 'Panel Compartido' in t)
check('client A sees new title', 'Panel Compartido' in a.text())
check('client B sees new title', 'Panel Compartido' in b.text())

r = run_cli(['new', SES, '--cmd', 'sleep 600', '-t', 'Trabajo Largo'], HOME)
check('new pane while attached exit 0', r.returncode == 0)
r = run_cli(['list', SES], HOME, env={'LANG': 'C'})
check('daemon has 2 panes', len([l for l in r.stdout.splitlines()
                                 if l and l[0].isdigit()]) == 2)
a.wait_until(lambda t: 'Trabajo Largo' in t)
b.wait_until(lambda t: 'Trabajo Largo' in t)
check('client A gained the window', 'Trabajo Largo' in a.text())
check('client B gained the window', 'Trabajo Largo' in b.text())

# ---- canonical geometry: B's 80-column host does not shrink the PTY ----
r = run_cli(['list', SES], HOME, env={'LANG': 'C'})
row1 = [l for l in r.stdout.splitlines() if l.startswith('1 ')]
size_ok = False
if row1:
    for tok in row1[0].split():
        if 'x' in tok and tok[0].isdigit():
            cols = int(tok.split('x')[0])
            size_ok = cols > 80
            break
check('smaller client leaves PTY canonical', size_ok)

# ---- 3.0.1: an attach with a different geometry does not bounce sizes ----
# Previously, attach transient sizes shrank and re-grew everyone's screens,
# moving visible content into history. Attach now makes no size request.
run_cli(['send', SES + ':1', 'echo GEOM_TOKEN_31'], HOME)
a.wait_until(lambda t: 'GEOM_TOKEN_31' in t)
b.wait_until(lambda t: 'GEOM_TOKEN_31' in t)
run_cli(['organize', SES, 'grid'], HOME)
a.drain(1.0)
b.drain(1.0)
c3 = stlib.Client(HOME, args=['--attach'], w=90, h=26)
c3.drain(3.0)
a.drain(1.0)
check('new client sees snapshot content', 'GEOM_TOKEN_31' in c3.text())
check('old client keeps visible content', 'GEOM_TOKEN_31' in a.text())
c3.send(b'\x11', 0.4)
c3.send(b'd', 1.0)
c3.wait_exit(timeout=8.0)
c3.close()

# ---- close the new pane via CLI: both clients compact ----
r = run_cli(['close', SES + ':2'], HOME)
check('close while attached exit 0', r.returncode == 0)
a.wait_until(lambda t: 'Trabajo Largo' not in t)
b.wait_until(lambda t: 'Trabajo Largo' not in t)
check('client A dropped the window', 'Trabajo Largo' not in a.text())
check('client B dropped the window', 'Trabajo Largo' not in b.text())
run_cli(['send', SES + ':1', 'echo AFTER_CLOSE_OK'], HOME)
a.wait_until(lambda t: 'AFTER_CLOSE_OK' in t)
b.wait_until(lambda t: 'AFTER_CLOSE_OK' in t)
check('panes still aligned in A', 'AFTER_CLOSE_OK' in a.text())
check('panes still aligned in B', 'AFTER_CLOSE_OK' in b.text())

# ---- laggard client: an attached v2 that never reads does not block the daemon ----
lag, ok = attach_raw(
    SOCK, struct.pack('<iiiii', PROTO_VER, 100, 28, 1, 0))
check('laggard attached', ok)
check('three clients listed', clients_column(HOME) == 3)
run_cli(['send', SES + ':1',
         "yes LAGGARD_FLOOD | head -c 2000000; printf 'PUMP_%s\\n' DONE"],
        HOME)
# Drain both host PTYs from one select set. Running pyte over this deliberately
# huge stream one client at a time can itself take longer than the daemon's
# lag grace and create a fake slow client. The raw pump tests real transport
# backpressure without letting the Python oracle starve either live reader.
deadline = time.monotonic() + 45
next_probe = 0.0
listed_clients = -1
canonical_done = False
while time.monotonic() < deadline:
    stlib.drain_clients_raw([a, b], 0.25)
    now = time.monotonic()
    if now >= next_probe:
        next_probe = now + 0.75
        listed_clients = clients_column(HOME)
        capture = run_cli(['capture', SES + ':1'], HOME)
        canonical_done = (capture.returncode == 0 and
                          'PUMP_DONE' in capture.stdout)
    if listed_clients == 2 and canonical_done:
        break
listed_clients = clients_column(HOME)
check('flood reached canonical pane', canonical_done)
check('laggard dropped, live clients kept',
      listed_clients == 2 and a.alive() and b.alive())
lag.close()
# The canonical capture above proves that all pane output reached the daemon.
# Now prove that both surviving UI processes still consume a later event and
# draw it to their host terminals. Use the title: B's deliberately smaller
# host clips the canonical pane's last row, so requiring the final shell line
# on that host would test clipping rather than transport survival.
post_marker = b'LIVE_AFTER_FLOOD_91'
a_offset = len(a.raw())
b_offset = len(b.raw())
r = run_cli(['rename', SES + ':1', post_marker.decode('ascii')], HOME)
check('post-flood title accepted', r.returncode == 0)
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    stlib.drain_clients_raw([a, b], 0.2)
    if (post_marker in a.raw()[a_offset:] and
            post_marker in b.raw()[b_offset:]):
        break
a_post = a.raw()[a_offset:]
b_post = b.raw()[b_offset:]
a_rendered = post_marker in a_post
b_rendered = post_marker in b_post
if not a_rendered:
    print(f'  client A post-flood bytes={len(a_post)} tail={a_post[-240:]!r}')
if not b_rendered:
    print(f'  client B post-flood bytes={len(b_post)} tail={b_post[-240:]!r}')
check('client A survived the flood', a_rendered)
check('client B survived the flood', b_rendered)
check('two live clients remain after flood',
      clients_column(HOME) == 2 and a.alive() and b.alive())
r = run_cli(['list'], HOME, env={'LANG': 'C'})
check('daemon alive after flood', r.returncode == 0 and SES in r.stdout)

# ---- kill the session: both clients get the notice and exit ----
r = run_cli(['kill', SES], HOME)
check('kill with clients attached exit 0', r.returncode == 0)
time.sleep(1.5)
a.send(b'\r', 0.5)   # accept the "session was closed" notice
b.send(b'\r', 0.5)
check('client A exited cleanly after shutdown', a.wait_exit(timeout=8.0) == 0)
check('client B exited cleanly after shutdown', b.wait_exit(timeout=8.0) == 0)
check('session gone', stlib.session_sockets(HOME) == [])

stlib.report()
