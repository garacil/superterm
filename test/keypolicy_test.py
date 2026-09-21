#!/usr/bin/env python3
"""superterm test: the prefix owns every superterm action, and nothing else.

This is the standing audit of issue #1's rule.  Two halves, and both have to
hold at once or the rule is worthless:

  * no bare key is a superterm key.  Whatever is pressed without the prefix
    reaches the program in the focused pane, byte for byte, including the keys
    superterm used to bind -- the function keys, Alt, the navigation cluster.
  * every superterm action still has a chord, and the UI says which.  A chord
    nobody can discover does not exist, so each one has to appear in a menu
    row, on the status line, or in the help dialog.

The pane runs `cat -vT`, which prints control bytes visibly: what the screen
shows is exactly what the child process received, with no interpretation in
between to argue about.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check

HOME = stlib.fresh_home('keypolicy')
with open(HOME + '/.superterm/superterm.ini', 'w') as config:
    config.write('[ui]\n'
                 'language=en\n'
                 'background=none\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n')

# Every key superterm used to take for itself, and the Meta forms it has to
# produce now.  Alt+character goes out as ESC plus the character; Alt+function
# or navigation key as ESC plus that key's own sequence, which is the Meta
# convention those applications read.
FORWARDED = [
    ('F2',          b'\x1bOQ',      '^[OQ'),
    ('F3',          b'\x1bOR',      '^[OR'),
    ('F5',          b'\x1b[15~',    '^[[15~'),
    ('F6',          b'\x1b[17~',    '^[[17~'),
    ('F7',          b'\x1b[18~',    '^[[18~'),
    ('F8',          b'\x1b[19~',    '^[[19~'),
    ('F9',          b'\x1b[20~',    '^[[20~'),
    ('Alt-b',       b'\x1bb',       '^[b'),
    ('Alt-f',       b'\x1bf',       '^[f'),
    ('Alt-x',       b'\x1bx',       '^[x'),   # the old Exit key
    ('Alt-q',       b'\x1bq',       '^[q'),
    ('Alt-1',       b'\x1b1',       '^[1'),
    ('Alt-0',       b'\x1b0',       '^[0'),
    # punctuation: readline's Alt-. (last argument) and Alt-/ (complete)
    ('Alt-.',       b'\x1b.',       '^[.'),
    ('Alt-/',       b'\x1b/',       '^[/'),
    ('Alt-,',       b'\x1b,',       '^[,'),
    # no ESC+char form exists for these, so they travel as ESC + sequence
    ('Alt-F9',      b'\x1b[20;3~',  '^[^[[20~'),
    ('Alt-Up',      b'\x1b[1;3A',   '^[^[[A'),
    ('Alt-PgUp',    b'\x1b[5;3~',   '^[^[[5~'),
    ('Alt-End',     b'\x1b[1;3F',   '^[^[[F'),
    # modified navigation used to be dropped on the floor
    ('Ctrl-PgUp',   b'\x1b[5;5~',   '^[[5;5~'),
    ('Ctrl-PgDn',   b'\x1b[6;5~',   '^[[6;5~'),
    ('Ctrl-Left',   b'\x1b[1;5D',   '^[[1;5D'),
    # and the ordinary ones must not have regressed
    ('PgUp',        b'\x1b[5~',     '^[[5~'),
    ('Tab',         b'\t',          '^I'),
]

c = stlib.Client(HOME, w=110, h=32)
c.drain(2.5)

# ---- half one: nothing is a superterm key without the prefix ---------------
c.send(b'cat -vT\r', 1.5)
c.send(b'\r', 0.5)
check('the pane is echoing control bytes', '^[' not in c.text())

for name, keys, want in FORWARDED:
    c.send(keys + b'\r', 0.6)
    check(f'{name} reaches the pane unchanged', want in c.text())

# The desktop must still be there: none of the above may have been swallowed
# by superterm and acted on.  Panes, windows and the menu are all unchanged.
check('no key above disturbed the desktop',
      'Panes' in c.text() and 'Windows' in c.text())
check('no key above opened a menu or dialog',
      'Split vertical' not in c.text() and 'Help and shortcuts' not in c.text())

c.send(b'\x03', 0.6)          # Ctrl-C, back to the shell

# ---- half two: every chord works, and the UI advertises it -----------------
check('the status line names the prefix',
      'Ctrl-Q m Menu' in c.text() and 'Ctrl-Q d Detach' in c.text())

c.send(b'\x11?', 1.2)
help_text = c.text()
check('Ctrl-Q ? opens the help', 'Everything starts with Ctrl-Q' in help_text)
check('the help names no bare key', 'Alt-' not in help_text
      and 'F2' not in help_text and 'F9' not in help_text)
c.send(b'\r', 0.8)

# Each chord of the map has to be reachable from the UI as well as the
# keyboard.  The menus carry most of them; the status line carries the menu's
# own chord, and the help dialog carries the rest.
c.send(b'\x11m', 0.8)
c.send(b'p', 1.0)
panes_menu = c.text()
for chord in ('Ctrl-Q v', 'Ctrl-Q b', 'Ctrl-Q k', 'Ctrl-Q o', 'Ctrl-Q i',
              'Ctrl-Q z', 'Ctrl-Q f', 'Ctrl-Q -', 'Ctrl-Q g', 'Ctrl-Q ,',
              'Ctrl-Q PgUp', 'Ctrl-Q PgDn', 'Ctrl-Q Home', 'Ctrl-Q End',
              'Ctrl-Q x'):
    check(f'Panes menu shows {chord}', chord in panes_menu)
c.send(b'\x1b', 0.4)
c.send(b'\x1b', 0.4)

c.send(b'\x11m', 0.8)
c.send(b'w', 1.0)
win_menu = c.text()
for chord in ('Ctrl-Q +', 'Ctrl-Q r', 'Ctrl-Q w', 'Ctrl-Q t'):
    check(f'Windows menu shows {chord}', chord in win_menu)
# n/p are per-window rows, so they only appear once a profile is active;
# the help dialog lists them unconditionally.
check('help lists the window chords',
      'n next' in help_text and 'p previous' in help_text)
c.send(b'\x1b', 0.4)
c.send(b'\x1b', 0.4)

# The chords themselves, on the live desktop.
def panes():
    # the focused window is drawn in double rule, the others single
    return c.text().count('╔') + c.text().count('┌')

check('one pane to start with', panes() == 1)
c.send(b'\x11v', 1.8)
check('Ctrl-Q v splits the pane', panes() == 2)
c.send(b'\x11k', 1.8)
check('Ctrl-Q k closes it again', panes() == 1)

c.send(b'for i in $(seq 1 120); do echo LINE$i; done\r', 2.2)
check('the pane is at the live end', 'LINE120' in c.text())
c.send(b'\x11\x1b[5~', 1.0)
check('Ctrl-Q PgUp scrolls the history back', 'LINE120' not in c.text())
c.send(b'\x11\x1b[4~', 1.0)
check('Ctrl-Q End returns to the live end', 'LINE120' in c.text())

# A doubled prefix is the escape hatch: one literal prefix byte to the pane.
c.send(b'stty -ixon\r', 0.8)   # Ctrl-Q is XOFF; let it through to cat
c.send(b'cat -vT\r', 1.2)
c.send(b'\x11\x11\r', 0.8)
check('Ctrl-Q Ctrl-Q sends one literal prefix', '^Q' in c.text())
c.send(b'\x03', 0.6)

c.send(b'\x11x', 1.5)
check('Ctrl-Q x exits', c.wait_exit(8.0) == 0)

stlib.report()
