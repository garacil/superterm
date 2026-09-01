#!/usr/bin/env python3
"""superterm test: the mouse backend must keep the two properties it already has.

This suite pins behaviour that is ALREADY correct, rather than driving new
work. It exists because both properties are easy to lose to a well-meaning
simplification, and because one of them fails in a way no test would otherwise
catch: a hang before the program's first line runs.

  1. No blocking connect to gpm at startup.

     The RTL decides whether a mouse exists from a fixed list of TERM
     prefixes, and for anything else it tries gpm -- with a BLOCKING connect
     to /dev/gpmctl, made while the Drivers unit initialises. With gpm
     installed but not accepting (its listen backlog full) that hangs
     superterm forever, before main runs, where nothing in the program can
     intervene. src/st_mouse.pas avoids it by registering its own driver
     before Drivers and probing gpm with a NON-BLOCKING connect.

     The failure needs a wedged gpm to reproduce, which cannot be arranged on
     a developer's machine without interfering with a real system service.
     So the guard here is on the source: the probe must set O_NONBLOCK before
     it connects, and the unit must precede Drivers in the program's uses
     clause. Both are the mechanism; losing either restores the hang.

  2. A mouse on terminals the RTL has never heard of.

     tmux-256color, alacritty, foot and wezterm are not on the RTL's list, so
     without this unit nobody enables xterm tracking and there is no mouse at
     all. This half IS observable, so it is tested by running the product.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stlib  # noqa: E402
from stlib import check, report  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOUSE_UNIT = os.path.join(ROOT, 'src', 'st_mouse.pas')
PROGRAM = os.path.join(ROOT, 'src', 'superterm.lpr')

# What st_mouse enables for a terminal the RTL does not know.
TRACK_ON = (b'\x1b[?1000h', b'\x1b[?1002h', b'\x1b[?1006h')


def source(path):
    with open(path, encoding='utf-8', errors='replace') as handle:
        return handle.read()


def test_probe_is_nonblocking():
    text = source(MOUSE_UNIT)
    body = ''
    match = re.search(r'function GpmAccepting[^;]*;(.*?)\nend;', text, re.S)
    if match:
        body = match.group(1)
    check('the gpm probe exists', bool(body))
    if not body:
        return
    nonblock = body.find('O_NONBLOCK')
    connect = body.find('fpconnect')
    check('the gpm probe sets O_NONBLOCK', nonblock >= 0)
    check('it connects only after that', 0 <= nonblock < connect)
    # EAGAIN on an AF_UNIX connect means the listen backlog is full: a gpm
    # that is present but wedged. Treating it as "accepting" would hand the
    # console back to the RTL driver and reintroduce the blocking path.
    check('a full backlog is not mistaken for an accepting gpm',
          'EAGAIN' in body or 'Err = 0' in body)


def test_unit_precedes_drivers():
    text = source(PROGRAM)
    match = re.search(r'\buses\b(.*?);', text, re.S | re.I)
    check('the program has a uses clause', match is not None)
    if match is None:
        return
    names = [n.strip().lower() for n in match.group(1).split(',')]
    names = [n.split()[0] for n in names if n.strip()]
    check('the program imports st_mouse', 'st_mouse' in names)
    check('the program imports drivers', 'drivers' in names)
    if 'st_mouse' in names and 'drivers' in names:
        # Registration happens in st_mouse's initialization, so it only wins
        # if the unit is initialised first, which is the uses order.
        check('st_mouse is initialised before Drivers',
              names.index('st_mouse') < names.index('drivers'))


def test_mouse_on_unknown_terminal():
    """Run the product under a TERM the RTL does not recognise."""
    for term in ('alacritty', 'foot', 'wezterm', 'tmux-256color'):
        home = stlib.fresh_home('mouse-%s' % term)
        with open(os.path.join(home, '.superterm', 'superterm.ini'), 'w') as f:
            f.write('[ui]\nlanguage=en\nbackground=none\n'
                    '[session]\nserver=always\nautosave=0\nautorestore=0\n')
        client = None
        try:
            client = stlib.Client(home, w=90, h=28, lang='en',
                                  env={'TERM': term})
            client.drain(3.0)
            raw = client.raw()
            check(f'TERM={term}: xterm mouse tracking is enabled',
                  all(seq in raw for seq in TRACK_ON))
            # Any-motion tracking is deliberately NOT enabled: the RTL event
            # queue is small and Free Vision drains one event per loop, so a
            # pointer sweep would overflow it for nothing.
            check(f'TERM={term}: any-motion tracking stays off',
                  b'\x1b[?1003h' not in raw)
        finally:
            if client is not None:
                try:
                    client.send(b'\x1bx', 1.0)
                    client.close()
                except Exception:                          # noqa: BLE001
                    pass
            stlib.close_all_daemons(home)


def test_console_term_still_starts():
    """TERM=linux takes the gpm path; it must start and exit regardless."""
    home = stlib.fresh_home('mouse-console')
    with open(os.path.join(home, '.superterm', 'superterm.ini'), 'w') as f:
        f.write('[ui]\nlanguage=en\nbackground=none\n'
                '[session]\nserver=always\nautosave=0\nautorestore=0\n')
    client = None
    try:
        client = stlib.Client(home, w=90, h=28, lang='en',
                              env={'TERM': 'linux'})
        client.drain(3.0)
        client.send(b"printf 'CONSOLE_ALIVE\\n'\r", 2.0)
        screen = '\n'.join(''.join(client.screen.display[y])
                           for y in range(28))
        check('a console TERM still reaches a usable prompt',
              'CONSOLE_ALIVE' in screen)
    finally:
        if client is not None:
            try:
                client.send(b'\x1bx', 1.0)
                client.close()
            except Exception:                              # noqa: BLE001
                pass
        stlib.close_all_daemons(home)


test_probe_is_nonblocking()
test_unit_precedes_drivers()
test_mouse_on_unknown_terminal()
test_console_term_still_starts()
report()
