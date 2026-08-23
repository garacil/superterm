#!/usr/bin/env python3
"""Pane focus changes window chrome, never terminal-cell colours."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


HOME = stlib.fresh_home('focus-color')
os.makedirs(HOME + '/.superterm', exist_ok=True)
with open(HOME + '/.superterm/superterm.ini', 'w') as f:
    # Use a real artwork background: its clipped repaint is the path that used
    # to overwrite a pane's truecolor overlay after the pane lost focus.
    f.write('[ui]\nlanguage=en\nbackground=london\nbackground_mode=center\n'
            '[session]\nautorestore=0\nautosave=0\n')

c = stlib.Client(HOME, w=100, h=30, lang='en')
c.drain(2.0)
c.send(b'\x1bOQ', 1.4)             # F2: add the second pane
c.send(b'\x11', 0.2)
c.send(b't', 1.2)                   # tile so both interiors stay visible


def mouse(x, y):
    start = len(c.raw())
    c.send(f'\x1b[<0;{x};{y}M'.encode(), 0.1)
    c.send(f'\x1b[<0;{x};{y}m'.encode(), 0.9)
    return c.raw()[start:]


def marker_style(marker, fg, bg):
    """Return every display attribute for the coloured marker occurrence."""
    for y, line in enumerate(c.screen.display):
        start = 0
        while True:
            x = line.find(marker, start)
            if x < 0:
                break
            cells = c.screen.buffer[y]
            if cells[x].fg == fg and cells[x].bg == bg:
                return tuple((cells[i].fg, cells[i].bg, cells[i].bold,
                              cells[i].italics, cells[i].underscore,
                              cells[i].reverse)
                             for i in range(x, x + len(marker)))
            start = x + 1
    return None


def frame_order():
    row = c.screen.display[1]
    active = row.find('╔')
    inactive = row.find('┌')
    return active, inactive


# Pane 2 starts focused. Reproduce the bold ANSI-green shell prompt from the
# reported capture, then add an unmistakable truecolor foreground/background.
# Move focus in both directions more than once; every pane that becomes
# inactive must preserve both representations exactly.
c.send(b"printf '\\033[1;32mPANE2_ANSI_GREEN\\033[0m\\n'\r", 1.2)
p2_ansi_focused = marker_style('PANE2_ANSI_GREEN', 'brightgreen', '000000')
check('pane 2 ANSI green is visible', p2_ansi_focused is not None)
c.send(b"printf '\\033[38;2;250;40;20;48;2;10;70;160mPANE2_RGB"
       b"\\033[0m\\n'\r", 1.2)
p2_focused = marker_style('PANE2_RGB', 'fa2814', '0a46a0')
check('pane 2 truecolor is visible', p2_focused is not None)
focus_delta = mouse(5, 5)
p2_inactive = marker_style('PANE2_RGB', 'fa2814', '0a46a0')
check('inactive pane 2 keeps all colours',
      p2_focused is not None and p2_inactive == p2_focused)
check('inactive pane 2 keeps ANSI green',
      marker_style('PANE2_ANSI_GREEN', 'brightgreen', '000000') ==
      p2_ansi_focused)
check('left focus sends border delta only',
      len(focus_delta) < 2500 and b'PANE2_RGB' not in focus_delta and
      b'PANE2_ANSI_GREEN' not in focus_delta and
      b'38;2;250;40;20' not in focus_delta)
active, inactive = frame_order()
check('focus changes only the left border',
      active >= 0 and inactive >= 0 and active < inactive)

# Exercise the opposite direction too: colour pane 1 while focused, click
# pane 2, and verify both pane interiors remain byte-for-byte styled alike.
c.send(b"printf '\\033[38;2;20;220;80;48;2;90;10;130mPANE1_RGB"
       b"\\033[0m\\n'\r", 1.2)
p1_focused = marker_style('PANE1_RGB', '14dc50', '5a0a82')
check('pane 1 truecolor is visible', p1_focused is not None)
focus_delta = mouse(60, 5)
p1_inactive = marker_style('PANE1_RGB', '14dc50', '5a0a82')
check('inactive pane 1 keeps all colours',
      p1_focused is not None and p1_inactive == p1_focused)
check('refocused pane 2 keeps all colours',
      marker_style('PANE2_RGB', 'fa2814', '0a46a0') == p2_focused)
check('refocused pane 2 keeps ANSI green',
      marker_style('PANE2_ANSI_GREEN', 'brightgreen', '000000') ==
      p2_ansi_focused)
check('right focus sends border delta only',
      len(focus_delta) < 2500 and b'PANE1_RGB' not in focus_delta and
      b'PANE2_RGB' not in focus_delta and
      b'PANE2_ANSI_GREEN' not in focus_delta and
      b'38;2;20;220;80' not in focus_delta and
      b'38;2;250;40;20' not in focus_delta)
active, inactive = frame_order()
check('focus changes only the right border',
      active >= 0 and inactive >= 0 and inactive < active)

# Repeat the same transitions. The original regression appeared only after a
# pane had first been selected and then lost focus, so one transition is not a
# sufficient test.
focus_delta = mouse(5, 5)
check('second left focus keeps pane 2 RGB',
      marker_style('PANE2_RGB', 'fa2814', '0a46a0') == p2_focused)
check('second left focus keeps pane 2 green',
      marker_style('PANE2_ANSI_GREEN', 'brightgreen', '000000') ==
      p2_ansi_focused)
check('second left focus sends chrome only',
      len(focus_delta) < 2500 and b'PANE2_RGB' not in focus_delta and
      b'PANE2_ANSI_GREEN' not in focus_delta and
      b'38;2;250;40;20' not in focus_delta)

focus_delta = mouse(60, 5)
check('second right focus keeps pane 1 RGB',
      marker_style('PANE1_RGB', '14dc50', '5a0a82') == p1_focused)
check('second right focus keeps pane 2 RGB',
      marker_style('PANE2_RGB', 'fa2814', '0a46a0') == p2_focused)
check('second right focus sends chrome only',
      len(focus_delta) < 2500 and b'PANE1_RGB' not in focus_delta and
      b'PANE2_RGB' not in focus_delta and
      b'38;2;20;220;80' not in focus_delta and
      b'38;2;250;40;20' not in focus_delta)

c.send(b'\x1bq', 0.8)
try:
    c.wait_exit(timeout=6)
except Exception:
    pass
c.close()
stlib.close_all_daemons(HOME)
stlib.report()
