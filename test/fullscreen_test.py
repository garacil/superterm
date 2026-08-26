#!/usr/bin/env python3
"""superterm test: maximising is not the same as taking the terminal.

Maximise -- the window's own icon, or Panes > Maximize/restore -- fills the
desktop and leaves the frame, the menu bar and the status line where they
are. Prefix+f, and only that command, hands the whole terminal to the pane
and takes the window manager off the screen. Physical F5 remains application
input in both windowed and fullscreen modes.

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
check('fullscreen chord is advertised', 'Ctrl-Q f Full screen' in c.text())
check('F5 is not advertised as fullscreen', 'F5 Full screen' not in c.text())


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

# Bind physical F5 in bash and prove that SuperTerm forwards the escape
# sequence instead of changing layout.  The marker is checked only after the
# bind command itself has completed, so its echoed command cannot satisfy it.
c.send(b"bind '\"\\e[15~\":\"PHYSICAL_F5_REACHED\"'\r", 0.8)
physical_offset = len(c.raw())
c.send(b'\x1b[15~', 0.8)
check('physical F5 reaches the pane',
      b'PHYSICAL_F5_REACHED' in c.raw()[physical_offset:])
check('physical F5 keeps the IDE visible', 'Panes' in c.text())
c.send(b'\x15', 0.2)  # Ctrl-U: clear the injected readline text

# ---- prefix+f: the pane owns the terminal ----
c.send(stlib.FULLSCREEN_CHORD, 1.8)
txt = c.text()
check('fullscreen hides the menu bar', 'Panes' not in txt)
check('fullscreen hides the status line', 'Detach' not in txt)

# Physical F5 must also stay with the pane while passthrough owns the screen.
physical_offset = len(c.raw())
c.send(b'\x1b[15~', 0.8)
check('fullscreen physical F5 reaches the pane',
      b'PHYSICAL_F5_REACHED' in c.raw()[physical_offset:])
c.send(b'\x15', 0.2)

# ---- prefix+f again: the IDE comes back, window and all ----
c.send(stlib.FULLSCREEN_CHORD, 1.8)
txt = c.text()
check('fullscreen exit brings the menu bar back', 'Panes' in txt)
check('fullscreen exit brings the status line back', 'Detach' in txt)
check('fullscreen exit brings the window back', framed())

# the pane still works after the round trip
c.send(b'echo BACK_IN_THE_IDE\r', 1.2)
c.wait_until(lambda t: 'BACK_IN_THE_IDE' in t, 6.0)
check('the pane still runs', 'BACK_IN_THE_IDE' in c.text())

c.send(b'\x1bx', 0.8)
try:
    c.wait_exit(timeout=6)
except Exception:
    pass
stlib.close_all_daemons(HOME)
stlib.report()
