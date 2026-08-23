#!/usr/bin/env python3
"""superterm test: maximising is not the same as taking the terminal.

Maximise -- the window's own icon, or Panes > Maximize/restore -- fills the
desktop and leaves the frame, the menu bar and the status line where they
are. F5, and only F5, hands the whole terminal to the pane and takes the
window manager off the screen.

They used to be one thing: any zoom put the pane into passthrough, so
maximising a window with its icon threw the IDE away.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check

HOME = stlib.fresh_home('fullscreen')
os.makedirs(HOME + '/.superterm', exist_ok=True)
with open(HOME + '/.superterm/superterm.ini', 'w') as f:
    f.write('[ui]\nlanguage=en\nbackground=none\n'
            '[session]\nautorestore=0\nautosave=0\n')

c = stlib.Client(HOME, w=100, h=30, lang='en')
c.drain(2.5)
check('the IDE is up', 'Panes' in c.text() and 'Detach' in c.text())


def framed():
    """is a window frame being drawn?"""
    return sum(1 for r in c.screen.display
               if ('║' in r) or ('╔' in r) or ('│' in r)) > 3


# ---- maximise: bigger window, same IDE ----
c.send(b'\x1b[<0;4;1M', 0.2)      # the Panes menu
c.send(b'\x1b[<0;4;1m', 0.8)
c.send(b'x', 1.8)                 # Ma~x~imize/restore
txt = c.text()
check('maximise keeps the menu bar', 'Panes' in txt)
check('maximise keeps the status line', 'Detach' in txt)
check('maximise keeps the window frame', framed())

# ---- F5: the pane owns the terminal ----
c.send(b'\x1b[15~', 1.8)
txt = c.text()
check('F5 hides the menu bar', 'Panes' not in txt)
check('F5 hides the status line', 'Detach' not in txt)

# ---- F5 again: the IDE comes back, window and all ----
c.send(b'\x1b[15~', 1.8)
txt = c.text()
check('F5 brings the menu bar back', 'Panes' in txt)
check('F5 brings the status line back', 'Detach' in txt)
check('F5 brings the window back', framed())

# the pane still works after the round trip
c.send(b'echo BACK_IN_THE_IDE\r', 1.2)
c.wait_until(lambda t: 'BACK_IN_THE_IDE' in t, 6.0)
check('the pane still runs', 'BACK_IN_THE_IDE' in c.text())

c.send(b'\x1bq', 0.8)
try:
    c.wait_exit(timeout=6)
except Exception:
    pass
stlib.close_all_daemons(HOME)
stlib.report()
