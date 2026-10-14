#!/usr/bin/env python3
"""superterm test: a fullscreen pane comes back whole when its size returns.

Issue #5. A fullscreen pane owns the terminal (passthrough) only while the
terminal is exactly the desktop size. Shrink the terminal window and the
window manager takes the screen back; grow it again and the pane owns the
terminal once more. On that second hand-off the screen was cleared and then
left black: the pane's PTY never changed size, so nothing inside it had any
reason to draw again. The pane has to be shown as it is, with the cursor and
the pen where its program left them, before its raw output resumes.

The steps are the issue's: a windowed terminal grows to full screen, the
desktop is adjusted to it, the pane goes fullscreen, and the terminal is put
back in a window and in full screen again (here, two PTY resizes).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check

HOME = stlib.fresh_home('fullscreen-reenter')
# Panes run login shells, which read .bash_profile and not .bashrc.
with open(HOME + '/.bash_profile', 'w') as f:
    f.write("PS1='$ '\n")
with open(HOME + '/.superterm/superterm.ini', 'w') as config:
    config.write('[ui]\n'
                 'language=en\n'
                 'background=none\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n')

SMALL = (100, 30)
LARGE = (160, 45)

# The shell assembles both markers, so neither appears in the echo of the
# command line that prints it: seeing one means its output reached the screen.
# HOT is printed in truecolor and left without a reset, so the pen the program
# is holding is part of what has to come back.
MARK = b"printf 'MARK%s\\n' 1\r"
HOT = b"printf '\\033[38;2;255;100;0mHOT%s ' 2\r"


def row_of(client, needle):
    for y, line in enumerate(client.screen.display):
        if needle in line:
            return y
    return -1


def fg_of(client, needle):
    y = row_of(client, needle)
    if y < 0:
        return None
    x = client.screen.display[y].index(needle)
    return client.screen.buffer[y][x].fg


c = stlib.Client(HOME, w=SMALL[0], h=SMALL[1])
try:
    check('windowed terminal starts',
          c.wait_until(lambda t: 'Pan' in t and '$' in t, 10.0))

    c.resize(*LARGE, 1.0)                 # Alt+Enter: terminal full screen
    c.send(b'\x11md', 0.6)                # Desktop menu
    c.send(b'a', 1.2)                     # Adjust to this terminal size
    c.send(stlib.FULLSCREEN_CHORD, 1.4)   # the pane owns the terminal
    check('fullscreen hides the menu', 'Detach' not in c.text())

    c.send(MARK, 0.3)
    check('fullscreen pane prints its marker',
          c.wait_until(lambda t: 'MARK1' in t, 8.0))
    c.send(HOT, 0.3)
    check('fullscreen pane prints in truecolor',
          c.wait_until(lambda t: 'HOT2' in t, 8.0))
    check('truecolor reaches the terminal', fg_of(c, 'HOT2') == 'ff6400')

    c.resize(*SMALL, 1.5)                 # Alt+Enter: terminal in a window
    check('a smaller terminal brings the window manager back',
          c.wait_until(lambda t: 'Detach' in t, 6.0))

    c.resize(*LARGE, 1.5)                 # Alt+Enter: full screen again
    check('the full size hands the terminal back to the pane',
          c.wait_until(lambda t: 'Detach' not in t, 6.0))
    shown = c.wait_until(lambda t: 'MARK1' in t and 'HOT2' in t, 6.0)
    check('the pane is not left black', shown)
    if not shown:
        print('  ' + '\n  '.join(r.rstrip() for r in c.screen.display[:4]))
    check('cells keep their colour', fg_of(c, 'HOT2') == 'ff6400')

    # Raw output continues from where the program's cursor and pen are.
    c.send(b'printf "AFTER%s\\n" 3\r', 0.3)
    check('output resumes in the pane',
          c.wait_until(lambda t: 'AFTER3' in t, 8.0))
    mark, hot, after = row_of(c, 'MARK1'), row_of(c, 'HOT2'), row_of(c, 'AFTER3')
    check('output resumes below what was there', 0 <= mark < hot < after)
    check('output keeps the pen the program set', fg_of(c, 'AFTER3') == 'ff6400')
    check('the prompt line was not overwritten',
          'HOT2 $ printf' in c.screen.display[hot])
finally:
    try:
        c.send(b'\x11', 0.3)
        c.send(b'd', 0.5)
    except OSError:
        pass
    stlib.close_all_daemons(HOME)
    c.wait_exit(3.0)
    c.close()

stlib.report()
