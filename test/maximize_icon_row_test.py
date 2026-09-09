#!/usr/bin/env python3
"""A maximize stops immediately above the minimized icons, at every instant.

Minimized windows park as icons along the bottom of the canonical desktop. A
maximized window used to take the whole desktop and bury them, and it only
corrected itself on the next unrelated event, so the user saw it settle in two
steps. The size of a maximize is daemon-owned shared state, which is why this
suite asserts the daemon's grid and not merely what one viewer painted:

* with icons parked, a maximize is exactly the desktop minus the icon row, on
  the first paint and with no click anywhere;
* the zoom animation never reaches the icon rows on any frame;
* restoring or minimizing an unrelated window re-fits an already maximized
  pane, in both directions;
* a minimized maximized pane keeps the grid it will be restored to;
* with nothing minimized, a maximize is still the whole desktop.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('maximize-icon-row-' + str(os.getpid()))
SESSION = 'maxicons'
W, H = 100, 32
DESK_H = H - 2          # menu row and status row are outside the desktop
ICON_H = 2              # st_layout.ICON_H
FULL = (W - 2, DESK_H - 2)
ABOVE_ICONS = (W - 2, DESK_H - 2 - ICON_H)

with open(HOME + '/.superterm/superterm.ini', 'w', encoding='utf-8') as stream:
    stream.write('[ui]\nlanguage=en\nbackground=none\ndesktop_limit_marks=0\n'
                 '[session]\nserver=always\nautosave=0\nautorestore=0\n'
                 'zoomanim=1\n')


def click(client, x, y):
    stlib.write_all(client.fd, f'\x1b[<0;{x + 1};{y + 1}M'.encode())
    stlib.write_all(client.fd, f'\x1b[<0;{x + 1};{y + 1}m'.encode())


def panes():
    """Daemon-owned PTY grid and flags per pane, from the public CLI."""
    result = run_cli(['list', SESSION], HOME, env={'LANG': 'C'})
    if result.returncode != 0:
        return {}
    out = {}
    for line in result.stdout.splitlines():
        if not line or not line[0].isdigit():
            continue
        fields = line.split()
        size = next((f for f in fields if 'x' in f and f[0].isdigit()), None)
        if size is None:
            continue
        cols, rows = size.split('x', 1)
        flags = line.strip().split()[-1]
        if not set(flags) <= set('*MZ!'):
            flags = ''
        out[int(fields[0])] = ((int(cols), int(rows)), flags)
    return out


def wait_for(predicate, client, timeout=8.0):
    import time
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        client.drain(0.1)
        if predicate():
            return True
    return predicate()


def button(client, mark):
    """FreeVision draws the frame buttons only on the active window."""
    for y, row in enumerate(client.screen.display):
        x = row.find(mark)
        if x >= 0:
            return x, y
    return -1, -1


def icon_rows(client):
    return [y for y, row in enumerate(client.screen.display)
            if row.lstrip().startswith('┌') or row.lstrip().startswith('└')]


c = stlib.Client(HOME, args=['--session', SESSION], w=W, h=H, lang='en')
c.drain(2.5)
c.send(b'\x1bc', 0.4)
c.wait_until(lambda text: 'Local shell' in text, 3.0)
stlib.write_all(c.fd, b'1')
c.drain(2.0)
check('the session starts with two panes', len(panes()) == 2)

# ---- baseline: with no icons a maximize is still the whole desktop ---------
zx, zy = button(c, '[↑]')
check('the active window shows its zoom button', zx > 0)
click(c, zx + 1, zy)
check('maximize with no icons takes the whole desktop',
      wait_for(lambda: panes().get(2, ((0, 0), ''))[0] == FULL, c))
zx, zy = button(c, '[↑]')
click(c, zx + 1, zy)                          # back to a window
c.drain(1.0)

# ---- with one icon parked, the maximize stops above it --------------------
check('minimize pane 2', run_cli(['minimize', f'{SESSION}:2'], HOME)
      .returncode == 0)
c.drain(1.5)
rows = icon_rows(c)
check('the icon is parked at the bottom of the desktop',
      len(rows) >= 2 and max(rows) == DESK_H)

stlib.write_all(c.fd, b'\x1b1')               # focus pane 1
c.drain(1.2)
zx, zy = button(c, '[↑]')
check('the focused pane shows its zoom button', zx > 0)
click(c, zx + 1, zy)

# Sample straight through the zoom animation: no frame of it may reach the
# icon rows, which is what made the window appear to settle in two steps.
# Only a border reaching the right edge can belong to the maximized window;
# a parked icon is narrow and would otherwise be counted as its own bottom.
lowest = -1
for _ in range(60):
    c.drain(0.05)
    for y, row in enumerate(c.screen.display):
        if len(row) >= W and row[W - 1] in ('┘', '╝'):
            lowest = max(lowest, y)
check('no animation frame reaches the icon rows',
      0 < lowest <= DESK_H - ICON_H)
check('a maximize with one icon is the desktop minus the icon row',
      wait_for(lambda: panes().get(1, ((0, 0), ''))[0] == ABOVE_ICONS, c))
check('the maximized pane is flagged maximized',
      'Z' in panes().get(1, ((0, 0), ''))[1])

# ---- the icon row moving re-fits an already maximized pane ----------------
check('restore pane 2', run_cli(['restore', f'{SESSION}:2'], HOME)
      .returncode == 0)
check('restoring the icon gives the maximized pane its rows back',
      wait_for(lambda: panes().get(1, ((0, 0), ''))[0] == FULL, c))
check('minimize pane 2 again', run_cli(['minimize', f'{SESSION}:2'], HOME)
      .returncode == 0)
check('parking an icon again re-fits the maximized pane',
      wait_for(lambda: panes().get(1, ((0, 0), ''))[0] == ABOVE_ICONS, c))

# ---- a minimized maximized pane keeps its restore grid --------------------
check('minimize the maximized pane 1', run_cli(['minimize', f'{SESSION}:1'],
      HOME).returncode == 0)
c.drain(1.5)
state = panes().get(1, ((0, 0), ''))
check('a minimized maximized pane keeps the grid it will restore to',
      state[0] == ABOVE_ICONS and 'M' in state[1] and 'Z' in state[1])

c.close()
stlib.close_all_daemons(HOME)
stlib.report()
