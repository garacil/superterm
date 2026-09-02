#!/usr/bin/env python3
"""Post-attach SIGWINCH changes a viewer, never the canonical desktop.

The terminal size used during ATTACH is only a viewer capability: joining a
live session at a different size must not negotiate or mutate its desktop.
Once attached, later physical resizes only add/remove that viewer's margins or
scrollbars. The shared desktop, every pane rectangle and canonical PTY remain
byte-for-byte stable.

The resize helper deliberately resizes pyte before TIOCSWINSZ, matching a real
terminal emulator.  Reversing those operations can lose SuperTerm's fast
repaint and manufacture a false failure in the test itself.
"""
import fcntl
import os
import struct
import sys
import termios
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('host-resize-shared')
TITLE = 'HOSTRESIZE'

with open(HOME + '/.superterm/superterm.ini', 'w') as fh:
    fh.write('[ui]\nlanguage=en\nbackground=none\n'
             '[session]\nserver=always\nautosave=0\nautorestore=0\n'
             'zoomanim=0\n')


def pane_size(session):
    result = run_cli(['list', session], HOME, env={'LANG': 'C'})
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        if not line.startswith('1 '):
            continue
        for token in line.split():
            if 'x' not in token or not token[0].isdigit():
                continue
            try:
                return tuple(int(value) for value in token.split('x', 1))
            except ValueError:
                pass
    return None


def frame_rect(client):
    """Return the inclusive rectangle of our complete titled frame."""
    rows = client.screen.display
    for top, row in enumerate(rows):
        title_x = row.find(TITLE)
        if title_x < 0:
            continue
        lefts = [x for x, char in enumerate(row[:title_x])
                 if char in ('╔', '┌')]
        rights = [x for x, char in enumerate(row[title_x + len(TITLE):],
                  title_x + len(TITLE)) if char in ('╗', '┐')]
        if not lefts or not rights:
            continue
        left, right = max(lefts), min(rights)
        for bottom in range(top + 2, len(rows)):
            if (rows[bottom][left] in ('╚', '└') and
                    rows[bottom][right] in ('╝', '┘')):
                return left, top, right, bottom
    return None


def drain_all(clients, seconds=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.025)


def host_resize(client, width, height):
    client.w, client.h = width, height
    client.screen.resize(lines=height, columns=width)
    fcntl.ioctl(client.fd, termios.TIOCSWINSZ,
                struct.pack('HHHH', height, width, 0, 0))


def desktop_bars(client):
    rows = client.screen.display
    if len(rows) < client.h or client.w < 3 or client.h < 5:
        return False
    return (rows[client.h - 2][0] in ('◄', '<') and
            rows[client.h - 2][client.w - 2] in ('►', '>') and
            rows[1][client.w - 1] in ('▲', '^') and
            rows[client.h - 3][client.w - 1] in ('▼', 'V'))


def wait_shared(clients, session, rectangles, pty_size, timeout=6.0):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        last = ([frame_rect(client) for client in clients],
                pane_size(session))
        if (last[0] == list(rectangles) and
                last[1] == pty_size):
            return True
        time.sleep(0.025)
    print('  last shared resize state:', last,
          'expected:', (list(rectangles), pty_size))
    return False


a = stlib.Client(HOME, w=100, h=30, lang='en')
b = None
try:
    a.drain(2.5)
    sockets = stlib.session_sockets(HOME)
    check('session exists', len(sockets) == 1)
    session = os.path.basename(sockets[0])[:-5] if sockets else ''
    renamed = run_cli(['rename', session + ':1', TITLE], HOME)
    check('pane rename succeeds', renamed.returncode == 0)
    check('100x30 creator has exact desktop',
          wait_shared((a,), session, ((0, 1, 97, 27),), (96, 25)))

    # B's 132x40 is attach metadata, not a resize gesture.  It gets margin
    # around the exact 100x30 canonical desktop and cannot change A or the PTY.
    b = stlib.Client(HOME, args=['--attach', session],
                     w=132, h=40, lang='en')
    b.drain(2.5)
    check('different-size attach is live', b.alive())
    check('attach does not negotiate desktop',
          wait_shared((a, b), session,
                      ((0, 1, 97, 27), (0, 1, 97, 27)), (96, 25)))

    # A later SIGWINCH only changes A's physical margin.
    host_resize(a, 120, 36)
    check('grow leaves shared desktop and PTY unchanged',
          wait_shared((a, b), session,
                      ((0, 1, 97, 27), (0, 1, 97, 27)), (96, 25)))

    # Shrinking A clips the canonical frame and adds bars only on A.
    host_resize(a, 84, 24)
    check('shrink leaves shared desktop and PTY unchanged',
          wait_shared((a, b), session,
                      (None, (0, 1, 97, 27)), (96, 25)))
    check('only the smaller viewer gains viewport scrollbars',
          a.wait_until(lambda _text: desktop_bars(a), 5.0) and
          not desktop_bars(b))

    # Matching B's small surface gives it its own bars without changing
    # canonical state or A's local viewport.
    host_resize(b, 84, 24)
    check('second shrink still leaves canonical state unchanged',
          wait_shared((a, b), session, (None, None), (96, 25)))
    check('each small viewer owns its own scrollbars',
          b.wait_until(lambda _text: desktop_bars(a) and desktop_bars(b),
                       5.0))

    # Growing B back to the exact canonical physical size removes only B's
    # bars. Visible chrome is the acknowledgement for this final SIGWINCH.
    host_resize(b, 100, 30)
    check('viewer grow restores its local full frame only',
          wait_shared((a, b), session,
                      (None, (0, 1, 97, 27)), (96, 25)))
    check('scrollbar ownership remains client-local',
          b.wait_until(lambda _text: desktop_bars(a) and
                       not desktop_bars(b), 5.0))
finally:
    if b is not None:
        b.close()
    a.close()
    stlib.close_all_daemons(HOME)

stlib.report()
