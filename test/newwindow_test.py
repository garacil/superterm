#!/usr/bin/env python3
"""superterm test: opening a window leaves the ones already open alone.

Creating a pane used to end in RelayoutAll, which re-tiled every window from
the split tree -- so opening a third window resized the two you had, and
SIGWINCH'd their PTYs with them. A new window now takes the size its class
(or [ui] newwincols/newwinrows) asks for, centred, and touches nothing else.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stlib import Client, fresh_home, check, report, close_all_daemons

W, H = 110, 35
NEW_COLS, NEW_ROWS = 40, 10


def corners(client):
    """Top-left corner of every window frame on screen, as (row, col).

    The focused window draws a double corner, the rest a single one.
    """
    out = []
    for row, line in enumerate(client.screen.display):
        for col, ch in enumerate(line):
            if ch in ('┌', '╔'):     # -+- and =+=
                out.append((row, col))
    return sorted(out)


def frame_at(client, row, col):
    """Outer width and height of the frame whose top-left corner is here.

    Measured to the matching corner glyphs, not by walking the border: the
    top border carries the title and the [-] [^] buttons, and the bottom
    right carries the resize grip.
    """
    disp = client.screen.display
    w = 0
    for x in range(col + 1, len(disp[row])):
        if disp[row][x] in ('┐', '╗'):
            w = x - col + 1
            break
    h = 0
    for y in range(row + 1, len(disp)):
        if col < len(disp[y]) and disp[y][col] in ('└', '╚'):
            h = y - row + 1
            break
    return w, h


home = fresh_home('newwindow')
ini = os.path.join(home, '.superterm', 'superterm.ini')
os.makedirs(os.path.dirname(ini), exist_ok=True)
with open(ini, 'w') as f:
    f.write('[ui]\nlanguage=en\nbackground=none\n'
            'newwincols=%d\nnewwinrows=%d\n' % (NEW_COLS, NEW_ROWS))

c = Client(home, w=W, h=H)
c.drain(3.0)

# one window, filling the desktop: the way every session has always started
first = corners(c)
check('starts with one window', len(first) == 1)
# it spans the desktop bar the two-column gap the tiler has always left
first_rect = (first[0], frame_at(c, *first[0])) if first else None
check('first window spans the desktop',
      first_rect is not None and first_rect[0] == (1, 0)
      and first_rect[1][0] >= W - 2)

# open a second one
c.send(b'\x1b[13~', 2.0)          # F3: split -> new pane
second = corners(c)
check('now two windows', len(second) == 2)

# the one that was already there has not moved and has not been resized
check('first window did not move', first[0] in second)
if first_rect is not None and first[0] in second:
    check('first window was not resized',
          frame_at(c, *first[0]) == first_rect[1])

# the new one is the size that was asked for, and centred
others = [p for p in second if p != first[0]]
if others:
    row, col = others[0]
    w, h = frame_at(c, row, col)
    check('new window is its configured width', w == NEW_COLS + 2)
    check('new window is its configured height', h == NEW_ROWS + 2)
    # desktop is everything but the menu row and the status row
    check('new window is centred across', col == (W - (NEW_COLS + 2)) // 2)
    check('new window is centred down',
          row == 1 + ((H - 2) - (NEW_ROWS + 2)) // 2)

# a third one must not disturb the ones already open. Centred windows of the
# same size land on top of each other, so the third is not separately visible
# -- its number in the title bar is the proof it is there.
before = corners(c)
sizes_before = {p: frame_at(c, *p) for p in before}
c.send(b'\x1b[13~', 2.0)
check('third window opened', '3' in c.screen.display[11])
kept = all(frame_at(c, *p) == sizes_before[p] for p in before if p in corners(c))
check('the open windows are untouched', kept and first[0] in corners(c))
check('the wide window still has its size',
      frame_at(c, *first[0]) == first_rect[1])

# and tiling on demand still works: prefix + t. It is the one thing that IS
# allowed to move everything, and it makes the three stacked windows separate.
stacked = corners(c)
c.send(b'\x11', 0.4)              # prefix (Ctrl-Q)
c.send(b't', 1.5)                 # tile
tiled = corners(c)
check('prefix + t tiles them', len(tiled) == 3 and tiled != stacked)

c.send(b'\x1bq', 1.0)             # Alt-Q: quit without saving
c.wait_exit(timeout=8.0)
close_all_daemons(home)
report()
