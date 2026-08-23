#!/usr/bin/env python3
"""superterm test: opening a pane leaves the other windows alone.

Creating a pane used to end in RelayoutAll, which re-tiled every window from
the split tree -- so opening a third window resized the two you had, and
SIGWINCH'd their PTYs with them. Now:

- F2/F3 are real splits: the FOCUSED window gives up half of itself and the
  new one takes the other half. No other window moves.
- A pane opened from a class lands centred, at the size the class asks for
  (cols/rows), on top of whatever is there. Again nothing else moves.
- Tiling is still there on demand: prefix + t.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stlib import (Client, fresh_home, check, report, close_all_daemons,
                   session_sockets, run_cli)

W, H = 110, 35
CLASS_COLS, CLASS_ROWS = 40, 10


def corners(client):
    """Top-left corner of every window frame on screen, as (row, col)."""
    out = []
    for row, line in enumerate(client.screen.display):
        for col, ch in enumerate(line):
            if ch in ('┌', '╔'):
                out.append((row, col))
    return sorted(out)


def frame_at(client, row, col):
    """Outer width and height of the frame whose top-left corner is here,
    measured to the matching corner glyphs."""
    disp = client.screen.display
    w = h = 0
    for x in range(col + 1, len(disp[row])):
        if disp[row][x] in ('┐', '╗'):
            w = x - col + 1
            break
    for y in range(row + 1, len(disp)):
        if col < len(disp[y]) and disp[y][col] in ('└', '╚'):
            h = y - row + 1
            break
    return w, h


def frames(client):
    return {p: frame_at(client, *p) for p in corners(client)}


home = fresh_home('newwindow')
ini = os.path.join(home, '.superterm', 'superterm.ini')
with open(ini, 'w') as f:
    f.write('[ui]\nlanguage=en\nbackground=none\n\n'
            '[class.small]\nname=small\ncols=%d\nrows=%d\n'
            % (CLASS_COLS, CLASS_ROWS))

c = Client(home, w=W, h=H)
c.drain(3.0)

# --- one window, spanning the desktop (bar the tiler's traditional gap)
f0 = frames(c)
check('starts with one window', len(f0) == 1)
first = min(f0) if f0 else None
check('first window spans the desktop',
      first == (1, 0) and f0[first][0] >= W - 2)
full_w = f0[first][0] if first else 0

# --- F2: the new window is centred and NOTHING already open moves
c.send(b'\x1bOQ', 2.0)
f1 = frames(c)
check('split: now two windows', len(f1) == 2)
check('split: the old window kept its place', first in f1)
check('split: the old window was not resized', f1.get(first) == f0[first])
new = [p for p in f1 if p != first]
if new:
    row, col = new[0]
    w, h = f1[(row, col)]
    check('split: the new one is centred across', col == (W - w) // 2)
    check('split: the new one is centred down', row == 1 + ((H - 2) - h) // 2)

# --- a second one: still nothing already open moves
before = dict(f1)
c.send(b'\x1bOQ', 2.0)
f2 = frames(c)
check('second window: the first is untouched',
      first in f2 and f2[first] == before[first])

# --- a class pane: centred at the class size, on top; nothing else moves
socks = session_sockets(home)
check('session socket present', len(socks) == 1)
name = os.path.basename(socks[0])[:-5] if socks else ''
before = dict(f2)
r = run_cli(['new', name, '-c', 'small'], home)
check('class pane opened through the CLI', r.returncode == 0)
c.drain(2.5)
f3 = frames(c)
others = [p for p in f3 if p not in before]
check('class: one new window', len(others) == 1)
if others:
    row, col = others[0]
    w, h = f3[(row, col)]
    check('class: its configured width', w == CLASS_COLS + 2)
    check('class: its configured height', h == CLASS_ROWS + 2)
    check('class: centred across', col == (W - (CLASS_COLS + 2)) // 2)
    check('class: centred down', row == 1 + ((H - 2) - (CLASS_ROWS + 2)) // 2)
untouched = all(p in f3 and f3[p] == before[p] for p in before
                if p[1] < (W - (CLASS_COLS + 2)) // 2)   # those it cannot cover
check('class: the windows already open are untouched', untouched)

# --- and tiling on demand still works: prefix + t
stacked = corners(c)
c.send(b'\x11', 0.4)
c.send(b't', 1.5)
tiled = corners(c)
check('prefix + t tiles them', len(tiled) == 4 and tiled != stacked)

c.send(b'\x1bq', 1.0)
c.wait_exit(timeout=8.0)
close_all_daemons(home)
report()
