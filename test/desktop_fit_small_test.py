#!/usr/bin/env python3
"""superterm test: a small terminal can adjust the desktop to its own size.

Desktop > Adjust to this terminal size asks for the terminal minus the menu
and status rows. A 20x25 terminal (issue #7) and the common 80x24 one used to
be refused because the floor was a 25-row work area; the floor is now the
least the window manager works in. The daemon's own session snapshot is the
oracle, so nothing depends on what a dialog can show on a narrow screen.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import canonical_desktop, check, desktop_becomes


HOME = stlib.fresh_home('desktop-fit-small')
with open(HOME + '/.superterm/superterm.ini', 'w') as config:
    config.write('[ui]\n'
                 'language=en\n'
                 'background=none\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n')


def adjust(client):
    client.send(b'\x11md', 0.6)        # prefix, menu bar, Desktop
    client.send(b'a', 1.0)             # Adjust to this terminal size


small = None
try:
    small = stlib.Client(HOME, w=20, h=25)
    check('20x25 client starts',
          small.wait_until(lambda text: 'Pan' in text, 8.0))
    sockets = stlib.session_sockets(HOME)
    check('one session exists', len(sockets) == 1)
    path = sockets[0] if sockets else ''

    adjust(small)
    check('20x25 terminal adjusts the desktop to 20x23',
          desktop_becomes(path, (20, 23), small))

    small.resize(80, 24, 1.0)
    adjust(small)
    check('80x24 terminal adjusts the desktop to 80x22',
          desktop_becomes(path, (80, 22), small))

    small.resize(20, 10, 1.0)
    adjust(small)
    check('20x10 terminal reaches the 20x8 floor',
          desktop_becomes(path, (20, 8), small))

    small.resize(20, 9, 1.0)
    adjust(small)
    refused = small.wait_until(lambda text: '20x8' in text, 4.0)
    small.send(b'\r', 0.6)
    check('a terminal below the floor is told the limit', refused)
    check('a refusal leaves the desktop as it was',
          canonical_desktop(path) == (20, 8))
finally:
    if small is not None:
        try:
            small.send(b'\x11', 0.3)
            small.send(b'd', 0.5)
        except OSError:
            pass
    stlib.close_all_daemons(HOME)
    if small is not None:
        small.wait_exit(3.0)
        small.close()

stlib.report()
