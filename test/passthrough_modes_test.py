#!/usr/bin/env python3
"""superterm test: reclaiming the screen restores the host terminal's modes.

While a pane is maximised its bytes go straight to the host terminal, so
whatever the program inside writes lands on the real terminal -- including
its own mode resets. A superterm running inside a pane resets every mouse
mode when it exits, and that left the OUTER terminal reporting nothing at
all, with no way for superterm to notice: the pointer was simply dead.
Leaving passthrough must put back exactly what the mouse driver asked for.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stlib import Client, fresh_home, check, report, close_all_daemons

home = fresh_home('passmodes')
with open(os.path.join(home, '.superterm', 'superterm.ini'), 'w') as f:
    f.write('[ui]\nlanguage=en\nbackground=none\n')
c = Client(home, w=100, h=30)
c.drain(3.0)


def last_word(raw, mode):
    hits = re.findall((r'\x1b\[\?%d([hl])' % mode).encode(), raw)
    return hits[-1].decode() if hits else None


base = len(c.raw())
c.send(b'\x1b[15~', 1.5)          # F5: maximise -> passthrough
check('passthrough released the mouse',
      last_word(c.raw()[base:], 1000) == 'l')

# the program inside now resets every mouse mode, exactly as a nested
# superterm does when it exits -- straight through to the host terminal
mark = len(c.raw())
c.send(b"printf '\\033[?1006l\\033[?1002l\\033[?1000l'\r", 1.2)
check('the inner reset reached the host', last_word(c.raw()[mark:], 1000) == 'l')

mark = len(c.raw())
c.send(b'\x1b[15~', 2.0)          # F5: back to the window manager
raw = c.raw()[mark:]
check('reclaiming re-enables normal tracking', last_word(raw, 1000) == 'h')
check('reclaiming re-enables button tracking', last_word(raw, 1002) == 'h')
check('reclaiming re-enables SGR reporting', last_word(raw, 1006) == 'h')

# and the mouse really works again: a click focuses the pane
c.send(b'\x1b[<0;20;10M', 0.4)
c.send(b'\x1b[<0;20;10m', 0.8)
check('the client still runs after the click', c.alive())

c.send(b'\x1bx', 1.0)
c.wait_exit(timeout=8.0)
close_all_daemons(home)
report()
