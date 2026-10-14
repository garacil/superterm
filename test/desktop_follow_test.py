#!/usr/bin/env python3
"""superterm test: a viewer can have the shared desktop follow its terminal.

Issue #7 asked for the desktop to adjust itself when the terminal changes
size. A terminal's size is one viewer's business in a shared session, so that
is an explicit choice: Desktop > Follow this terminal size, saved as
[ui] desktop_follow_terminal. Off -- the default -- a resize changes only what
that viewer sees. On, the desktop becomes that terminal's work area when it
starts and whenever the terminal settles at a new size; a terminal below the
floor keeps the desktop it has, without a dialog in the way. The daemon's own
session snapshot is the oracle.
"""
import configparser
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stlib
from stlib import canonical_desktop, check, desktop_becomes

HOME = stlib.fresh_home('desktop-follow')
INI = HOME + '/.superterm/superterm.ini'
with open(INI, 'w') as config:
    config.write('[ui]\nlanguage=en\nbackground=none\n'
                 '[session]\nserver=always\nautosave=0\nautorestore=0\n')


def toggle_follow(client):
    client.send(b'\x11md', 0.6)        # prefix, menu bar, Desktop
    client.send(b'f', 1.0)             # Follow this terminal size


def saved_follow():
    parser = configparser.ConfigParser()
    parser.read(INI)
    if not parser.has_option('ui', 'desktop_follow_terminal'):
        return None
    return parser.getboolean('ui', 'desktop_follow_terminal')


def set_follow(value):
    with open(INI) as f:
        text = f.read()
    with open(INI, 'w') as f:
        f.write(re.sub(r'(?m)^desktop_follow_terminal=.*$',
                       'desktop_follow_terminal=' + value, text))


a = b = None
try:
    a = stlib.Client(HOME, w=100, h=30)
    check('the first viewer starts',
          a.wait_until(lambda t: 'Detach' in t, 10.0))
    sockets = stlib.session_sockets(HOME)
    check('one session exists', len(sockets) == 1)
    path = sockets[0] if sockets else ''
    start = canonical_desktop(path)

    # ---- off, the default: a resize is only this viewer's business ----
    a.resize(120, 40, 1.5)
    check('by default a resize leaves the desktop alone',
          canonical_desktop(path) == start)

    # ---- on: the desktop follows this terminal ----
    toggle_follow(a)
    check('turning it on adopts the terminal at once',
          desktop_becomes(path, (120, 38), a))
    check('the choice is saved', saved_follow() is True)
    a.send(b'\x11md', 0.8)
    check('the Desktop menu shows it on',
          a.wait_until(lambda t: 'Follow this terminal size' in t, 3.0))
    a.send(b'\x1b', 0.4)
    a.send(b'\x1b', 0.4)

    a.resize(90, 26, 1.0)
    check('a resize carries the desktop with it',
          desktop_becomes(path, (90, 24), a))

    # steps of a drag settle into one request for the final size
    for w, h in ((92, 27), (94, 28), (96, 29), (98, 30)):
        a.resize(w, h, 0.05)
    check('a drag ends at its final size', desktop_becomes(path, (98, 28), a))

    # A second viewer that does not follow is carried along, never the cause.
    # The option is the user's saved preference, so this viewer starts from a
    # configuration without it, as one on another account or saved file would.
    set_follow('0')
    b = stlib.Client(HOME, args=['--attach'], w=70, h=20)
    check('a second viewer attaches',
          b.wait_until(lambda t: 'Detach' in t and 'sessions' not in t, 10.0))
    b.resize(75, 22, 1.5)
    check('a viewer that does not follow changes nothing',
          canonical_desktop(path) == (98, 28))

    # below the floor the desktop stays, and no dialog interrupts
    a.resize(20, 9, 1.5)
    check('a terminal below the floor keeps the desktop',
          canonical_desktop(path) == (98, 28))
    check('and nobody is told off for it', '20x8' not in a.text())

    a.resize(110, 32, 1.0)
    check('back above the floor it follows again',
          desktop_becomes(path, (110, 30), a))

    # ---- off again ----
    toggle_follow(a)
    check('turning it off is saved', saved_follow() is False)
    a.resize(100, 30, 1.5)
    check('off again, a resize leaves the desktop alone',
          canonical_desktop(path) == (110, 30))

    # ---- the saved choice applies when a viewer starts ----
    a.send(b'\x11', 0.3)
    a.send(b'd', 1.0)
    a.wait_exit(5.0)
    a.close()
    a = None
    set_follow('1')
    a = stlib.Client(HOME, args=['--attach'], w=84, h=26)
    check('a viewer that follows adopts its terminal when it starts',
          desktop_becomes(path, (84, 24), a, timeout=8.0))
finally:
    for client in (b, a):
        if client is not None:
            try:
                client.send(b'\x11', 0.3)
                client.send(b'd', 0.5)
            except OSError:
                pass
    stlib.close_all_daemons(HOME)
    for client in (b, a):
        if client is not None:
            client.wait_exit(3.0)
            client.close()

stlib.report()
