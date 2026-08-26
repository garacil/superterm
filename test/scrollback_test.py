#!/usr/bin/env python3
"""superterm test: the history is reachable -- wheel, keys and scrollbar.

The engine (ring, viewport) existed; what was missing was every way of
using it: a scrollbar on the window, the mouse wheel, page keys beyond the
undocumented Alt-PgUp, and a view that stays put while output keeps coming.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stlib import (Client, fresh_home, check, report, close_all_daemons,
                   session_sockets, run_cli)

W, H = 100, 30
home = fresh_home('scrollback')
with open(os.path.join(home, '.superterm', 'superterm.ini'), 'w') as f:
    f.write('[ui]\nlanguage=en\nbackground=none\n')
c = Client(home, w=W, h=H)
c.drain(3.0)
socks = session_sockets(home)
name = os.path.basename(socks[0])[:-5] if socks else ''


def right_col():
    """column of the window's right frame (the tiler leaves a gap, so it is
    not the last column of the terminal)"""
    top = c.screen.display[1]
    for x in range(len(top) - 1, -1, -1):
        if top[x] in ('╗', '┐'):
            return x
    return W - 1


def interior():
    """the pane's text rows, without the frame columns"""
    rc = right_col()
    return [r[1:rc].rstrip() for r in c.screen.display[2:H - 3]]


def right_edge():
    rc = right_col()
    return ''.join(r[rc] if len(r) > rc else ' ' for r in c.screen.display[2:H - 3])


def has_bar():
    e = right_edge()
    return ('▒' in e) or ('▓' in e) or ('■' in e)


def wheel(up, x=40, y=15):
    c.send(('\x1b[<%d;%d;%dM' % (64 if up else 65, x, y)).encode(), 0.8)


def numbers():
    out = []
    for r in interior():
        if re.fullmatch(r'\d+', r.strip()):
            out.append(int(r.strip()))
    return out


def last():
    n = numbers()
    return n[-1] if n else -1


def first():
    """topmost numbered row: it moves by exactly the scroll amount, while the
    bottom one does not when the pane ends in a prompt"""
    n = numbers()
    return n[0] if n else -1


def expect_after(notches):
    """what the bottom row will show after scrolling back 3 lines per notch,
    computed from the screen as it is now (prompt rows included)"""
    rows = interior()
    bottom = max(i for i, r in enumerate(rows) if r.strip())
    target = rows[bottom - 3 * notches].strip()
    return int(target) if target.isdigit() else -1


# --- the bar is there from the start, even with nothing to scroll yet:
# hiding it until the first line scrolls off made a fresh window look like a
# build without the feature
check('scrollbar is there before there is any history', has_bar())

# --- make history
c.send(b'seq 1 300\r', 2.5)
check('output scrolled (300 at the bottom)', last() == 300)
check('scrollbar appears once there is history', has_bar())

# --- wheel up: earlier lines, three per notch
want1, want2 = expect_after(1), expect_after(2)
wheel(True)
check('wheel up shows earlier lines', last() == want1 and want1 < 300)
wheel(True)
check('another notch: three more', last() == want2 and want2 == want1 - 3)

# --- Alt-PgUp: a page further back
c.send(b'\x1b[5;3~', 0.8)
page = last()
check('Alt-PgUp pages back', 0 < page < 294)

# --- the view holds its place while new output arrives (injected through
# the daemon, so no key is pressed on this client)
before = numbers()
r = run_cli(['send', name + ':1', 'seq 301 330'], home)
c.drain(1.5)
check('output injected', r.returncode == 0)
check('new output does not move a scrolled-back view', numbers() == before)

# --- a key for the application returns to live
c.send(b'\r', 1.0)
check('typing returns to live', last() == 330)

# --- forward/back/home/end and the Ctrl alias
want2 = expect_after(2)
wheel(True); wheel(True)
check('scrolled back again', last() == want2 and want2 < 330)
c.send(b'\x1b[6;3~', 0.8)
check('Alt-PgDn pages forward (to live here)', last() == 330)
c.send(b'\x1b[5;5~', 0.8)
check('Ctrl-PgUp pages back too', last() < 330)
c.send(b'\x1b[1;3H', 0.8)
check('Alt-Home goes to the oldest line', numbers() and numbers()[0] <= 2)
c.send(b'\x1b[1;3F', 0.8)
check('Alt-End returns to live', last() == 330)

# --- alternate screen: no scrollbar, and the wheel becomes arrow keys
c.send(b"printf '\\033[?1049h'; cat -v\r", 1.5)
check('no scrollbar on the alternate screen', not has_bar())
wheel(True)
check('wheel on the alternate screen sends Up arrows',
      any('^[[A^[[A^[[A' in r for r in interior()))
c.send(b'\x03', 0.8)
c.send(b"printf '\\033[?1049l'\r", 1.2)
check('scrollbar is back after the alternate screen', has_bar())

# --- clicking the bar: the arrow steps a line, the trough pages
col = right_col()
glyphs = [(y, c.screen.display[y][col]) for y in range(2, H - 3)
          if c.screen.display[y][col] in '▲▼■']
up = [y for y, ch in glyphs if ch == '▲']
thumb = [y for y, ch in glyphs if ch == '■']
if up:
    was = first()
    c.send(('\x1b[<0;%d;%dM' % (col + 1, up[0] + 1)).encode(), 0.3)
    c.send(('\x1b[<0;%d;%dm' % (col + 1, up[0] + 1)).encode(), 0.6)
    # the vendor repeats the step while the button is held, so one click is
    # one line or a few -- what matters is that it moved back
    check('clicking the up arrow scrolls back', first() < was)
if thumb and thumb[0] > 6:
    was = first()
    y = thumb[0] - 4
    c.send(('\x1b[<0;%d;%dM' % (col + 1, y + 1)).encode(), 0.3)
    c.send(('\x1b[<0;%d;%dm' % (col + 1, y + 1)).encode(), 0.8)
    check('clicking the trough pages back', first() < was - 1)
c.send(b'\x1b[1;3F', 0.6)

# --- after panes are renumbered, the bar must still drive THIS pane.
# A window points at its pane from three places -- itself, the terminal view
# and the scrollbar -- and the scrollbar kept the old index when panes were
# inserted or closed. It then moved ANOTHER pane's viewport: the thumb
# jumped and snapped back on the next sync and this window never scrolled.
c.send(b'\x1b[1;3F', 0.5)
c.send(b'\x1bOQ', 2.0)            # F2: a second window (panes renumber)
c.send(b'\x1b[13;3~', 2.0)        # Alt-F3: close it (they renumber again)
c.drain(1.0)
col = right_col()
glyphs = [(y, c.screen.display[y][col]) for y in range(2, H - 3)
          if c.screen.display[y][col] in '\u25b2\u25bc\u25a0']
up = [y for y, ch in glyphs if ch == '\u25b2']
if up and first() > 0:
    was = first()
    c.send(('\x1b[<0;%d;%dM' % (col + 1, up[0] + 1)).encode(), 0.3)
    c.send(('\x1b[<0;%d;%dm' % (col + 1, up[0] + 1)).encode(), 0.6)
    check('the bar still drives this pane after renumbering', first() < was)
else:
    check('the bar still drives this pane after renumbering', False)

c.send(b'\x1bx', 1.0)
c.wait_exit(timeout=8.0)
close_all_daemons(home)
report()
