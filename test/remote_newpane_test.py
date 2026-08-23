#!/usr/bin/env python3
"""superterm test: a pane created in the daemon gets its own window here.

The client mirrors the daemon's panes in four parallel arrays. Inserting one
shifts them up, and the slot the shift vacates has to be cleared -- all of it.
Win was the one left holding the pointer the shift had just copied up, so the
neighbour's window sat in the array twice: the new pane got no window of its
own (CreateWindowForPane refuses to build one where Win is not nil), the focus
landed on the neighbour, and closing either index freed the shared window
through one slot and left the other dangling. The next repaint walked into it
and the client died with SIGSEGV in SyncScrollBar.

Only the remote path was wrong, so it takes a daemon to see it at all.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli

HOME = stlib.fresh_home('remotenew')
os.makedirs(HOME + '/.superterm', exist_ok=True)
with open(HOME + '/.superterm/superterm.ini', 'w') as f:
    f.write('[ui]\nlanguage=en\nbackground=none\n'
            '[session]\nautorestore=0\nautosave=0\n'
            '[class.extra]\nname=extra\nenabled=0\ntitle=extra\n'
            'cols=40\nrows=10\n')

# a detached session to attach to: that is what puts the client in remote mode
c = stlib.Client(HOME, w=110, h=34, lang='en')
c.drain(2.5)
c.send(b'\x11', 0.4)
c.send(b'd', 1.0)
c.send(b'\r', 1.6)
c.wait_exit(timeout=8)
c.close()
SES = os.path.basename(stlib.session_sockets(HOME)[0])[:-5]

c = stlib.Client(HOME, w=110, h=34, args=['--attach', SES], lang='en')
c.drain(2.5)
check('attached to the session', 'Panes' in c.text())

# Three panes, and then a fourth created by splitting one that is NOT the
# last: the new leaf lands in the middle of the preorder, which is what makes
# the arrays shift at all. Appending to the end shifts nothing and the bug
# stays hidden -- which is why it took a real workspace to meet it.
for _ in range(2):
    run_cli(['new', SES], HOME)
    c.drain(1.2)
check('three panes to start with',
      len(run_cli(['list', SES], HOME).stdout.strip().splitlines()) - 1 == 3)

run_cli(['focus', '%s:1' % SES], HOME)
c.drain(0.8)
r = run_cli(['new', SES, '-c', 'extra'], HOME)
check('new pane accepted', r.returncode == 0)
c.drain(2.0)
panes = run_cli(['list', SES], HOME).stdout.strip().splitlines()[1:]
check('the daemon has four panes', len(panes) == 4)

# Every pane gets a name of its own; every one of them has to be drawn. With
# the vacated slot left uncleared, two panes shared one window, so one of the
# four names had nowhere to appear.
NAMES = ('alfa', 'bravo', 'charlie', 'delta')
for i, nm in enumerate(NAMES):
    run_cli(['rename', '%s:%d' % (SES, i + 1), nm], HOME)
run_cli(['organize', SES, 'grid'], HOME)   # tiled: no title hides another
c.drain(2.5)
seen = [nm for nm in NAMES if nm in c.text()]
check('every pane has its own window', len(seen) == 4)

# ---- and closing one must not take the client with it ----
r = run_cli(['close', '%s:1' % SES], HOME)
check('close accepted', r.returncode == 0)
c.drain(2.5)
check('client survived the close', 'Panes' in c.text())
left = run_cli(['list', SES], HOME).stdout.strip().splitlines()[1:]
check('three panes left', len(left) == 3)

run_cli(['send', '%s:1' % SES, 'echo STILL_ALIVE'], HOME)
c.wait_until(lambda t: 'STILL_ALIVE' in t, 6.0)
check('the surviving panes still run', 'STILL_ALIVE' in c.text())

c.send(b'\x1bx', 1.5)
try:
    c.wait_exit(timeout=8)
except Exception:
    pass
c.close()
stlib.close_all_daemons(HOME)
stlib.report()
