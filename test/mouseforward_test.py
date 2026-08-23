#!/usr/bin/env python3
"""superterm test: the mouse reaches an application that asks for it.

The interior of a window belongs to the application once it has enabled
mouse reporting: presses, releases, drags and the wheel are re-encoded in
the protocol it asked for, at pane coordinates. The frame, the title, the
menu and the status line stay the window manager's. With reporting off,
a click only focuses the pane and the wheel scrolls the history -- as
before. 'cat -v' shows what the pane actually receives.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stlib import Client, fresh_home, check, report, close_all_daemons

W, H = 100, 30
home = fresh_home('mouseforward')
with open(os.path.join(home, '.superterm', 'superterm.ini'), 'w') as f:
    f.write('[ui]\nlanguage=en\nbackground=none\n')
c = Client(home, w=W, h=H)
c.drain(3.0)


def text():
    return '\n'.join(r.rstrip() for r in c.screen.display)


def sgr(btn, x, y, press=True):
    """what a real terminal sends for a click at 1-based screen (x, y)"""
    c.send(('\x1b[<%d;%d;%d%s' % (btn, x, y, 'M' if press else 'm')).encode(), 0.6)


# the first window sits at desktop (0,0), i.e. screen row 1; its interior
# starts one cell in: screen (x, y) -> pane cell (x - 1, y - 2), 1-based
def pane_xy(x, y):
    return x - 1, y - 2


# --- reporting off: a click is the window manager's (focus only)
c.send(b'cat -v\r', 1.0)
sgr(0, 20, 10); sgr(0, 20, 10, False)
check('with reporting off nothing reaches the application', '^[[<' not in text())
c.send(b'\x03', 0.8)

# --- normal tracking, SGR: press and release, at pane coordinates
c.send(b"printf '\\033[?1000h\\033[?1006h'; cat -v\r", 1.2)
sgr(0, 20, 10); sgr(0, 20, 10, False)
px, py = pane_xy(20, 10)
check('press reaches the application in SGR', '^[[<0;%d;%dM' % (px, py) in text())
check('release too', '^[[<0;%d;%dm' % (px, py) in text())
sgr(2, 30, 12); sgr(2, 30, 12, False)
check('right button is button 2', '^[[<2;%d;%dM' % (30 - 1, 12 - 2) in text())

# --- the wheel goes to the application now, not to the history
sgr(64, 25, 11)
check('wheel up reaches the application as button 64', '^[[<64;%d;%dM' % (24, 9) in text())

# --- a click on the title bar (screen row 2: row 1 is the menu bar) is
# still the window manager's: nothing arrives
c.drain(1.0)                               # let the wheel report land first
before = text().count('^[[<')
sgr(0, 40, 2); sgr(0, 40, 2, False)
check('a click on the frame does not reach the application', text().count('^[[<') == before)
# and the menu bar likewise: the menu opens and closes, the app sees nothing
sgr(0, 3, 1); sgr(0, 3, 1, False)
c.send(b'\x1b', 0.6)
check('a click on the menu bar does not reach the application', text().count('^[[<') == before)
c.send(b'\x03', 0.8)

# --- button tracking: a drag reports motion with the button, +32
c.send(b"printf '\\033[?1002h\\033[?1006h'; cat -v\r", 1.2)
sgr(0, 20, 10)
c.send(b'\x1b[<32;22;10M', 0.6)          # motion while held
c.send(b'\x1b[<32;24;10M', 0.6)
sgr(0, 24, 10, False)
check('drag motion reaches the application', '^[[<32;%d;%dM' % (21, 8) in text())
check('the drag ends with a release where it stopped', '^[[<0;%d;%dm' % (23, 8) in text())
c.send(b'\x03', 0.8)

# --- X10 encoding when the application did not ask for SGR
c.send(b"printf '\\033[?1006l\\033[?1000h'; cat -v\r", 1.2)
sgr(0, 20, 10); sgr(0, 20, 10, False)
# ESC [ M then three bytes offset by 32: button 0 -> ' ', col 19 -> '3', row 8 -> '('
check('X10 encoding when SGR is off', '^[[M 3(' in text())
c.send(b'\x03', 0.8)

# --- reporting off again: the wheel scrolls the history as before
c.send(b"printf '\\033[?1000l'; seq 1 200\r", 2.0)
rows_before = [r for r in c.screen.display if r.strip()]
sgr(64, 25, 11)
check('with reporting off the wheel scrolls the history again',
      [r for r in c.screen.display if r.strip()] != rows_before)

c.send(b'\x1b[1;3F', 0.6)
c.send(b'\x1bq', 1.0)
c.wait_exit(timeout=8.0)
close_all_daemons(home)
report()
