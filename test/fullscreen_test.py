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
import time

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


def wait_raw(offset, marker, timeout=6.0):
    """Wait for pane bytes which must traverse raw passthrough unchanged."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        c.drain(0.10)
        if marker in c.raw()[offset:]:
            return True
    return marker in c.raw()[offset:]


# ---- maximise: bigger window, same IDE ----
c.send(b'\x1b[<0;4;1M', 0.2)      # the Panes menu
c.send(b'\x1b[<0;4;1m', 0.8)
c.send(b'x', 0.1)                 # Ma~x~imize/restore
c.wait_until(lambda _text: framed() and
             'Panes' in c.text() and 'Detach' in c.text(), 6.0)
txt = c.text()
check('maximise keeps the menu bar', 'Panes' in txt)
check('maximise keeps the status line', 'Detach' in txt)
check('maximise keeps the window frame', framed())

# Bind physical F5 in bash and prove that SuperTerm forwards the escape
# sequence instead of changing layout.  Clear the pane after installing the
# binding: the command's own echo contains the marker, so a raw-byte search is
# not a valid windowed-mode oracle.  The renderer's logical pane model must
# show a new marker after F5 instead.
c.send(b"bind '\"\\e[15~\":\"PHYSICAL_F5_REACHED\"'; "
       b"printf '\\033[2J\\033[HWINDOWED_F5_READY\\n'\r", 0.1)
binding_ready = c.wait_until(
    lambda text: ('WINDOWED_F5_READY' in text and
                  'PHYSICAL_F5_REACHED' not in text), 6.0)
check('windowed F5 binding is ready', binding_ready)
c.send(b'\x1b[15~', 0.1)
physical_reached = c.wait_until(
    lambda text: 'PHYSICAL_F5_REACHED' in text, 6.0)
check('physical F5 reaches the pane',
      physical_reached)
check('physical F5 keeps the IDE visible', 'Panes' in c.text())
c.send(b'\x15', 0.2)  # Ctrl-U: clear the injected readline text

# ---- prefix+f: the pane owns the terminal ----
c.send(stlib.FULLSCREEN_CHORD, 0.1)
c.wait_until(lambda text: 'Panes' not in text and 'Detach' not in text, 6.0)
txt = c.text()
check('fullscreen hides the menu bar', 'Panes' not in txt)
check('fullscreen hides the status line', 'Detach' not in txt)

# Physical F5 must also stay with the pane while passthrough owns the screen.
physical_offset = len(c.raw())
c.send(b'\x1b[15~', 0.1)
check('fullscreen physical F5 reaches the pane',
      wait_raw(physical_offset, b'PHYSICAL_F5_REACHED'))
c.send(b'\x15', 0.2)

# ---- prefix+f again: the IDE comes back, window and all ----
c.send(stlib.FULLSCREEN_CHORD, 0.1)
c.wait_until(lambda text: ('Panes' in text and 'Detach' in text and framed()),
             6.0)
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
