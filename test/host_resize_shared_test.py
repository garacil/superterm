#!/usr/bin/env python3
"""A post-attach host resize is one atomic shared-desktop operation.

The terminal size used during ATTACH is only a viewer capability: joining a
live session at a different size must not negotiate or mutate its desktop.
Once attached, however, a real host SIGWINCH is a user window-management
action.  The actor's new desktop, every pane rectangle and the canonical PTY
size must therefore settle together in every client.

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
RAW_OSC = b'\x1b]777;HOST_RESIZE_RAW_F5\x07'

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


def scaled_single_pane(rectangle, old_host, new_host):
    """Precompute the server's inclusive frame and PTY after ScaleRect."""
    left, top, right, bottom = rectangle
    old_width, old_height = old_host[0], old_host[1] - 2
    new_width, new_height = new_host[0], new_host[1] - 2

    def edge(value, old_size, new_size):
        return (value * new_size + old_size // 2) // old_size

    # Window coordinates are relative to Desktop (physical row 1), and its
    # right/bottom bounds are exclusive.
    new_left = edge(left, old_width, new_width)
    new_top = edge(top - 1, old_height, new_height)
    new_right = edge(right + 1, old_width, new_width)
    new_bottom = edge(bottom, old_height, new_height)
    new_left = max(0, min(new_left, new_width - 16))
    new_top = max(0, min(new_top, new_height - 6))
    new_right = min(new_width, max(new_right, new_left + 16))
    new_bottom = min(new_height, max(new_bottom, new_top + 6))
    frame = (new_left, new_top + 1, new_right - 1, new_bottom)
    pty = (new_right - new_left - 2, new_bottom - new_top - 2)
    return frame, pty


def wait_shared(clients, session, rectangle, pty_size, timeout=6.0):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        last = ([frame_rect(client) for client in clients],
                pane_size(session))
        if (last[0] == [rectangle] * len(clients) and
                last[1] == pty_size):
            return True
        time.sleep(0.025)
    print('  last shared resize state:', last,
          'expected:', ([rectangle] * len(clients), pty_size))
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
          wait_shared((a,), session, (0, 1, 97, 27), (96, 25)))

    # B's 132x40 is attach metadata, not a resize gesture.  It gets margin
    # around the exact 100x30 canonical desktop and cannot change A or the PTY.
    b = stlib.Client(HOME, args=['--attach', session],
                     w=132, h=40, lang='en')
    b.drain(2.5)
    check('different-size attach is live', b.alive())
    check('attach does not negotiate desktop',
          wait_shared((a, b), session, (0, 1, 97, 27), (96, 25)))

    # A later SIGWINCH is deliberate.  It changes the one shared desktop and
    # PTY, including in B, which did not perform the gesture.
    grow_rect, grow_pty = scaled_single_pane(
        (0, 1, 97, 27), (100, 30), (120, 36))
    host_resize(a, 120, 36)
    check('grow changes shared desktop and PTY',
          wait_shared((a, b), session, grow_rect, grow_pty))

    shrink_rect, shrink_pty = scaled_single_pane(
        grow_rect, (120, 36), (84, 24))
    host_resize(a, 84, 24)
    check('shrink changes shared desktop and PTY',
          wait_shared((a, b), session, shrink_rect, shrink_pty))

    # Match B's physical surface without changing the already-canonical size.
    # Fullscreen must now use the latest 84x24 maximum and raw-broadcast the pane to
    # both equal-sized viewers, not resurrect the original 100x30 desktop.
    host_resize(b, 84, 24)
    drain_all((a, b), 0.8)
    os.write(a.fd, stlib.FULLSCREEN_CHORD)
    drain_all((a, b), 1.5)
    check('fullscreen uses resized canonical maximum', pane_size(session) == (84, 24))

    offsets = {client: len(client.raw()) for client in (a, b)}
    # Assemble the visible marker at execution time; the echoed command line
    # cannot satisfy the completion oracle by merely reaching both clients.
    command = (b"printf '\\033]777;HOST_RESIZE_RAW_F5\\007'; "
               b"printf 'HOST_RESIZE_F5_%s\\n' 'OK'\r")
    os.write(a.fd, command)
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        drain_all((a, b), 0.08)
        if all(b'HOST_RESIZE_F5_OK' in client.raw()[offsets[client]:]
               for client in (a, b)):
            break
    check('fullscreen output reaches both clients',
          all(b'HOST_RESIZE_F5_OK' in client.raw()[offsets[client]:]
              for client in (a, b)))
    check('equal-size fullscreen is raw in both clients',
          all(RAW_OSC in client.raw()[offsets[client]:]
              for client in (a, b)))

    os.write(b.fd, stlib.FULLSCREEN_CHORD)
    check('fullscreen restores latest resized frame',
          wait_shared((a, b), session, shrink_rect, shrink_pty))
finally:
    if b is not None:
        b.close()
    a.close()
    stlib.close_all_daemons(HOME)

stlib.report()
