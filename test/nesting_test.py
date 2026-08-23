#!/usr/bin/env python3
"""superterm test: superterm inside a superterm pane.

Every nested start used to be refused, because a pane attaching to its own
session mirrors forever. The guard is now by identity: each pane carries
SUPERTERM_SESSION_CHAIN, each daemon writes its id in the sidecar, and only
the sessions on the chain are refused -- the one this pane belongs to and
the ones above it. Another session, or a new one, is as safe from a pane as
from any terminal, and the picker never offers a forbidden one.
"""
import configparser
import glob
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stlib import (Client, fresh_home, check, report, close_all_daemons,
                   session_sockets, sessions_dir, run_cli, BIN)

W, H = 110, 35
home = fresh_home('nesting')
with open(os.path.join(home, '.superterm', 'superterm.ini'), 'w') as f:
    f.write('[ui]\nlanguage=en\nbackground=none\n')


def sidecar(name):
    cp = configparser.ConfigParser()
    cp.read(os.path.join(sessions_dir(home), name + '.ini'))
    return cp


def screen(c):
    return '\n'.join(r.rstrip() for r in c.screen.display)


# --- session A, the outer one
a = Client(home, w=W, h=H, args=['--session', 'outer'])
a.drain(3.0)
check('outer session up', any('outer' in os.path.basename(s) for s in session_sockets(home)))
check('the sidecar carries an id', sidecar('outer').get('session', 'id', fallback='') != '')

# the pane's environment carries the chain
a.send(b'echo CHAIN=$SUPERTERM_SESSION_CHAIN\r', 1.5)
# read it from the pane rather than from the screen: a window is only as wide
# as its class asks for, so the line can be wrapped or clipped on screen while
# the pane itself has it whole
chain = ''
for line in run_cli(['capture', 'outer:1'], home).stdout.splitlines():
    if line.startswith('CHAIN='):
        chain = line[len('CHAIN='):].strip()
check('the pane knows its session chain', chain != '' and
      chain.endswith(sidecar('outer').get('session', 'id')))

# --- from inside: the own session is refused, by name
a.send((BIN + ' --attach outer; echo EXIT=$?\r').encode(), 2.5)
check('attaching to the own session is refused', 'EXIT=2' in screen(a))
check('...and says why', 'belongs to' in screen(a))

# --- from inside: the control CLI still works
a.send((BIN + ' list >/dev/null; echo LIST=$?\r').encode(), 2.0)
check('the control CLI works from a pane', 'LIST=0' in screen(a))

# --- from inside, with no name and only the own session: refused too
a.send((BIN + ' --attach; echo AUTO=$?\r').encode(), 2.5)
check('auto-pick finds nothing safe', 'AUTO=1' in screen(a))

# --- another session, B, started from outside
b = Client(home, w=90, h=26, args=['--session', 'other'])
b.drain(3.0)
b.send(b'\x1b', 1.5)        # the picker offers 'outer'; Esc = start the new one
b.drain(2.0)
check('second session up', any('other' in os.path.basename(s) for s in session_sockets(home)))

# --- from inside A: attaching to B is allowed, and a client really starts
a.send(b'clear\r', 0.6)
a.send((BIN + ' --attach other\r').encode(), 4.0)
att = int(sidecar('other').get('session', 'attached', fallback='0'))
check('a nested client attached to the other session', att >= 2)
check('the nested client is on screen', 'Panes' in screen(a) and
      screen(a).count('Panes') >= 2)

# --- two hops: from inside the nested client (whose pane belongs to B,
# below A), attaching back to A must be refused as well
a.send((BIN + ' --attach outer; echo DEEP=$?\r').encode(), 3.0)
check('the ancestor two hops up is refused', 'DEEP=2' in screen(a))

# --- leaving: close B from outside; the nested client goes with it
r = run_cli(['kill', 'other'], home)
check('other session killed', r.returncode == 0)
a.drain(2.5)
b.wait_exit(timeout=8.0)

a.send(b'\x1bq', 1.0)
a.wait_exit(timeout=8.0)
close_all_daemons(home)
report()
