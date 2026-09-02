#!/usr/bin/env python3
"""superterm test: turning any-motion tracking off must not leave the host
terminal reporting nothing.

A full-screen program that wants hover -- Claude Code, Codex -- asks for
`?1003h`. superterm passes that on to the host terminal while such a pane has
the focus, and takes it back when the focus moves. xterm keeps the three
tracking modes as independent flags, so `?1003l` leaves `?1000`/`?1002`
standing; Konsole, and it is not alone, holds ONE mouse mode, and the same
sequence leaves it reporting nothing at all -- the pointer turns back into an
I-beam and no click reaches the window manager again.

top and htop never showed it: they ask for button tracking, not for motion.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check

HOME = stlib.fresh_home('mousemode')
os.makedirs(HOME + '/.superterm', exist_ok=True)
with open(HOME + '/.superterm/superterm.ini', 'w') as f:
    f.write('[ui]\nlanguage=en\nbackground=none\n'
            '[session]\nautorestore=0\nautosave=0\n')

c = stlib.Client(HOME, w=100, h=30, lang='en')
c.drain(2.5)
c.send(b'\x1bOQ', 1.6)            # F2: a second window to move the focus to
c.send(b'\x1b1', 0.9)             # Alt-1: back to the first

base = len(c.raw())
c.send(b"printf '\\033[?1003h\\033[?1006h'\r", 1.6)
check('the host is asked for any-motion',
      b'\x1b[?1003h' in c.raw()[base:])

base = len(c.raw())
c.send(b'\x1b2', 1.4)             # Alt-2: the focus leaves that pane
out = c.raw()[base:]
check('any-motion is taken back', b'\x1b[?1003l' in out)
check('base tracking is re-asserted',
      b'\x1b[?1000h' in out and b'\x1b[?1002h' in out and b'\x1b[?1006h' in out)

# and the window manager still gets its clicks
c.send(b'\x1b[<0;4;1M', 0.2)
c.send(b'\x1b[<0;4;1m', 1.0)
check('a click still opens the menu',
      ('Close pane' in c.text()) or ('Split vertical' in c.text()))
c.send(b'\x1b', 0.5)

c.send(b'\x1bx', 0.8)
try:
    c.wait_exit(timeout=6)
except Exception:
    pass
stlib.close_all_daemons(HOME)
stlib.report()
