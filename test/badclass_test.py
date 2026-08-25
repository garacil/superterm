#!/usr/bin/env python3
"""superterm test: a class whose terminal never comes up must not kill the UI.

Opening an SSH class that cannot connect leaves the pane with no class index
-- -1 when there is none, -2 when its terminal failed -- and the fallback
that replaces it read WClasses at that index with no check at all. Reading an
array at -2 is a segfault, and it was the one reported from the field:
"I opened the vr1 class, never saw it appear, closed a pane and it crashed".
Deleting a class while its pane lives leaves the same index past the end.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stlib import (Client, fresh_home, check, report, close_all_daemons,
                   run_cli, session_sockets)

home = fresh_home('badclass')
with open(os.path.join(home, '.superterm', 'superterm.ini'), 'w') as f:
    # 192.0.2.0/24 is reserved for documentation: it never answers
    f.write('[ui]\nlanguage=en\nbackground=none\n\n'
            '[class.nowhere]\nname=nowhere\nhost=192.0.2.1\nuser=nobody\n'
            'port=59999\n')

c = Client(home, w=110, h=34)
c.drain(3.0)
ses = os.path.basename(session_sockets(home)[0])[:-5]
c.send(b'echo ALIVE_MARK\r', 1.5)
check('session up', any('ALIVE_MARK' in r for r in c.screen.display))

r = run_cli(['new', ses, '-c', 'nowhere'], home)
check('the unreachable class was requested', r.returncode == 0)
c.drain(4.0)
check('the client survived opening it', c.alive())

# whatever came up, closing a pane must not take the client with it
c.send(b'\x1b[13;3~', 2.5)
check('the client survived closing a pane', c.alive())

# and so must saving the session, which reads the class name by index
c.send(b'\x13', 1.5)                      # Ctrl-S: save
check('the client survived saving', c.alive())

if c.alive():
    c.send(b'\x1bx', 1.0)
    c.wait_exit(timeout=8.0)
close_all_daemons(home)
report()
