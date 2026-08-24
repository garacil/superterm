#!/usr/bin/env python3
"""F5 raw mode must not outlive a smaller client's size constraint."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


HOME = stlib.fresh_home('passthrough-multiclient')
with open(HOME + '/.superterm/superterm.ini', 'w') as fh:
    fh.write('[ui]\nlanguage=en\nbackground=none\n'
             '[session]\nserver=always\nautosave=0\nautorestore=0\n')

# A owns a large host and enters direct/raw F5 passthrough.
a = stlib.Client(HOME, w=120, h=36, lang='en')
a.drain(2.5)
a.send(b'\x1b[15~', 1.8)
check('large client enters F5 passthrough', 'Detach' not in a.text())

# B asks the daemon for a smaller common PTY. Raw bytes cannot remain mapped
# directly onto A's 120x36 terminal: wrapping and cursor coordinates would be
# interpreted using two different grids. A must reclaim its synchronized UI.
b = stlib.Client(HOME, args=['--attach'], w=70, h=22, lang='en')
b.drain(3.0)
a.wait_until(lambda text: 'Detach' in text, 6.0)
check('smaller client forces grid fallback', 'Detach' in a.text())

a.send(b'echo CONSTRAINED_GRID_OK\r', 1.0)
a.wait_until(lambda text: 'CONSTRAINED_GRID_OK' in text, 6.0)
check('fallback remains interactive', 'CONSTRAINED_GRID_OK' in a.text())

# Detaching B removes the minimum-size constraint. A kept its 120x36 request,
# so the daemon grows the PTY and A can safely resume raw mode automatically.
b.send(b'\x11', 0.3)
b.send(b'd', 1.0)
try:
    b.wait_exit(timeout=6.0)
except Exception:
    pass
b.close()
a.wait_until(lambda text: 'Detach' not in text, 8.0)
check('raw mode resumes after disconnect', 'Detach' not in a.text())

a.send(b"stty size; echo AFTER_SMALL_CLIENT_LEFT\r", 1.2)
a.wait_until(lambda text: 'AFTER_SMALL_CLIENT_LEFT' in text, 6.0)
rows = [i for i, row in enumerate(a.screen.display)
        if 'AFTER_SMALL_CLIENT_LEFT' in row]
token_row = rows[-1] if rows else -1
check('PTY returns to large client size', '36 120' in a.text())
check('cursor stays next to final output', token_row >= 0 and
      0 <= a.screen.cursor.y - token_row <= 3)

a.send(b'\x1b[15~', 1.2)
a.send(b'\x1bx', 1.0)
a.close()
stlib.close_all_daemons(HOME)
stlib.report()
