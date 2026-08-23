#!/usr/bin/env python3
"""superterm test: closing the last window empties the desktop, it does not
end the program -- and a pane can be opened again afterwards.

Leaving is something you ask for: Alt-X, Sessions > Save and exit, or the
Exit entry that Panes carries for the hand that has just closed everything.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli

HOME = stlib.fresh_home('emptydesk')
os.makedirs(HOME + '/.superterm', exist_ok=True)
with open(HOME + '/.superterm/superterm.ini', 'w') as f:
    f.write('[ui]\nlanguage=en\nbackground=none\n'
            '[session]\nautorestore=0\nautosave=0\n')


def panes():
    out = run_cli(['list', '.'], HOME).stdout.strip().splitlines()
    return max(0, len(out) - 1)


c = stlib.Client(HOME, w=100, h=30, lang='en')
c.drain(2.5)
check('one pane to start with', panes() == 1)

# ---- close the only pane, from Panes > Close pane ----
c.send(b'\x1b[<0;4;1M', 0.2)
c.send(b'\x1b[<0;4;1m', 0.8)
c.send(b'c', 2.0)
txt = c.text()
check('the program is still running', 'Panes' in txt and 'Detach' in txt)
check('the desktop is empty', panes() == 0)

# ---- and a pane can be opened again ----
c.send(b'\x11', 0.4)
c.send(b'c', 1.2)          # prefix + c: open class in new pane
c.send(b'\r', 2.2)         # 'Local shell'
check('a pane can be opened again', panes() == 1)
c.send(b'echo BACK_FROM_EMPTY\r', 1.5)
c.wait_until(lambda t: 'BACK_FROM_EMPTY' in t, 6.0)
check('the new pane runs', 'BACK_FROM_EMPTY' in c.text())

# ---- Panes carries a way out ----
c.send(b'\x1b[<0;4;1M', 0.2)
c.send(b'\x1b[<0;4;1m', 0.8)
check('Panes offers Exit', 'Exit superterm' in c.text())
c.send(b'\x1b', 0.5)

c.send(b'\x1bx', 1.5)      # Alt-X: leaving, said on purpose
try:
    c.wait_exit(timeout=8)
except Exception:
    pass
c.close()
stlib.close_all_daemons(HOME)
stlib.report()
