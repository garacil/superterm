#!/usr/bin/env python3
"""A shrink must not scroll content away while there are blank rows to give.

A pane is created at one size and laid out to its final, slightly smaller one a
moment later. If the program in it has already written its first line by then,
the old behaviour scrolled the top line into the scrollback and off the visible
screen -- for a shrink that had empty rows going spare.

That is how a window class whose command starts `echo SOMETHING` lost its first
line on macOS, where openpty lets the child write before the layout settles.
GNU/Linux usually resized before the child wrote and so never showed it, which
is why this drives the shrink explicitly instead of relying on that timing.
"""
import stlib

TOKEN = 'TOKEN_FIRSTLINE'

home = stlib.fresh_home('resize_keep')
ini = home + '/.superterm/superterm.ini'
import os
os.makedirs(os.path.dirname(ini), exist_ok=True)
with open(ini, 'w') as f:
    f.write('[ui]\nlanguage=en\n'
            '[session]\nautosave=0\nautorestore=0\nserver=always\n')

# a tall client, so the pane has plenty of blank rows below the cursor
tall = stlib.Client(home, args=['--session', 'keep'], w=100, h=40)
tall.drain(4.0)
tall.send(('echo %s\n' % TOKEN).encode(), 1.5)
tall.drain(2.0)

vis = stlib.run_cli(['capture', 'keep:1'], home).stdout
hist = stlib.run_cli(['capture', 'keep:1', '--history'], home).stdout
stlib.check('the token is on the visible screen', TOKEN in vis)
stlib.check('the token is in the scrollback', TOKEN in hist)

# detach and come back with a much shorter client: the pane is renegotiated
# down to its size, which is the shrink under test
tall.send(b'\x11', 0.4)
tall.send(b'd', 1.5)
tall.wait_exit(8.0)

short = stlib.Client(home, args=['--attach', 'keep'], w=100, h=14)
short.drain(4.0)

vis2 = stlib.run_cli(['capture', 'keep:1'], home).stdout
hist2 = stlib.run_cli(['capture', 'keep:1', '--history'], home).stdout

# the point of the test: 26 rows went away, but only a few carried content, so
# the blank ones below the cursor should have absorbed the whole shrink
stlib.check('the token survives a shrink to 14 rows', TOKEN in vis2)
stlib.check('and is still in the scrollback', TOKEN in hist2)
stlib.check('the pane is still alive', short.alive())

stlib.close_all_daemons(home)
short.close()
stlib.report()
