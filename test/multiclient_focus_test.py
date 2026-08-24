#!/usr/bin/env python3
"""Each attached UI keeps its own pane focus; CLI focus remains global."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('multiclient-focus')
INI = os.path.join(HOME, '.superterm', 'superterm.ini')
with open(INI, 'w') as f:
    f.write('[ui]\nlanguage=en\nbackground=none\n'
            '[session]\nserver=always\nautosave=0\nautorestore=0\n')

a = stlib.Client(HOME, w=100, h=30, lang='en')
a.drain(2.5)
a.send(b'\x1bOQ', 1.5)          # F2: second pane
a.send(b'\x11', 0.2)
a.send(b't', 1.2)                # tile the two windows

sockets = stlib.session_sockets(HOME)
check('session server exists', len(sockets) == 1)
SES = os.path.basename(sockets[0])[:-5] if sockets else ''

b = stlib.Client(HOME, args=['--attach'], w=100, h=30, lang='en')
b.drain(3.0)
check('second client attached', b.alive())


def click(c, x, y):
    c.send(f'\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m'.encode(), 0.7)


def frame_order(c):
    """Return active/inactive frame columns on the tiled title row."""
    for row in c.screen.display[1:5]:
        active = row.find('╔')
        inactive = row.find('┌')
        if active >= 0 and inactive >= 0:
            return active, inactive
    return -1, -1


# A chooses the left pane and B the right pane. Before the fix the 400 ms
# whole-layout synchronization copied B's focus back into A, so both clients
# ended on whichever pane was clicked last.
click(a, 5, 5)
time.sleep(0.8)
click(b, 60, 5)
a.drain(2.0)
b.drain(2.0)
aa, ai = frame_order(a)
ba, bi = frame_order(b)
check('client A keeps left focus', aa >= 0 and ai >= 0 and aa < ai)
check('client B keeps right focus', ba >= 0 and bi >= 0 and bi < ba)

# Input proves this is functional focus, not only different border paint.
a.send(b'echo LOCAL_FOCUS_A\r', 1.0)
b.send(b'echo LOCAL_FOCUS_B\r', 1.0)
cap1 = run_cli(['capture', SES + ':1'], HOME).stdout if SES else ''
cap2 = run_cli(['capture', SES + ':2'], HOME).stdout if SES else ''
check('A input reached pane 1', 'LOCAL_FOCUS_A' in cap1 and
      'LOCAL_FOCUS_A' not in cap2)
check('B input reached pane 2', 'LOCAL_FOCUS_B' in cap2 and
      'LOCAL_FOCUS_B' not in cap1)

# `superterm focus` is deliberately different: it is an explicit remote
# command and should still focus the requested pane in every attached UI.
r = run_cli(['focus', SES + ':1'], HOME) if SES else None
check('CLI focus succeeds', r is not None and r.returncode == 0)
a.drain(1.5)
b.drain(1.5)
aa, ai = frame_order(a)
ba, bi = frame_order(b)
check('CLI focus applies to client A', aa >= 0 and ai >= 0 and aa < ai)
check('CLI focus applies to client B', ba >= 0 and bi >= 0 and ba < bi)

for c in (b, a):
    c.send(b'\x11', 0.2)
    c.send(b'd', 0.8)
    if 'Detach' in c.text() or 'detach' in c.text():
        c.send(b'\r', 0.8)
    c.close()
stlib.close_all_daemons(HOME)
stlib.report()
