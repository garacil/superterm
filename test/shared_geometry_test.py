#!/usr/bin/env python3
"""The shared desktop is fixed; every physical host is a local viewport.

An attach at a different physical size receives the existing canonical
geometry verbatim. A smaller host clips it behind local horizontal/vertical
scrollbars. Neither attach nor a later SIGWINCH changes the desktop, windows
or PTYs seen by another viewer.
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


HOME = stlib.fresh_home('shared-geometry')
TITLE = 'SHAREDGEOM'
with open(HOME + '/.superterm/superterm.ini', 'w') as fh:
    fh.write('[ui]\nlanguage=en\nbackground=none\n'
             '[session]\nserver=always\nautosave=0\nautorestore=0\n')


def pane_size(session):
    result = run_cli(['list', session], HOME, env={'LANG': 'C'})
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


def host_resize(client, width, height):
    # Match a real emulator: its cell surface changes before SIGWINCH.
    client.w, client.h = width, height
    client.screen.resize(lines=height, columns=width)
    fcntl.ioctl(client.fd, termios.TIOCSWINSZ,
                struct.pack('HHHH', height, width, 0, 0))


def desktop_bars(client):
    """Both client-local viewport bars occupy the physical bottom/right."""
    rows = client.screen.display
    if len(rows) < client.h or client.w < 3 or client.h < 5:
        return False
    horizontal = (rows[client.h - 2][0] in ('◄', '<') and
                  rows[client.h - 2][client.w - 2] in ('►', '>'))
    vertical = (rows[1][client.w - 1] in ('▲', '^') and
                rows[client.h - 3][client.w - 1] in ('▼', 'V'))
    return horizontal and vertical


def print_bar_diagnostic(client):
    rows = client.screen.display
    points = ((0, client.h - 2), (client.w - 2, client.h - 2),
              (client.w - 1, 1), (client.w - 1, client.h - 3))
    print('  viewport bar cells:',
          [(point, repr(rows[point[1]][point[0]])) for point in points])


def title_pos(client):
    for y, row in enumerate(client.screen.display):
        x = row.find(TITLE)
        if x >= 0:
            return x, y
    return None


def click(client, x, y):
    stlib.write_all(client.fd, f'\x1b[<0;{x + 1};{y + 1}M'.encode())
    stlib.write_all(client.fd, f'\x1b[<0;{x + 1};{y + 1}m'.encode())


def drain_all(clients, seconds=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.025)


def wait_state(clients, session, rectangles, pty, timeout=6.0):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        last = ([frame_rect(client) for client in clients], pane_size(session))
        if last == (list(rectangles), pty):
            return True
        time.sleep(0.025)
    print('  last geometry state:', last,
          'expected:', (list(rectangles), pty))
    return False


a = stlib.Client(HOME, w=120, h=36, lang='en')
b = None
c = None
try:
    a.drain(2.5)
    sockets = stlib.session_sockets(HOME)
    check('session exists', len(sockets) == 1)
    session = os.path.basename(sockets[0])[:-5] if sockets else ''
    renamed = run_cli(['rename', session + ':1', TITLE], HOME)
    check('pane rename succeeds', renamed.returncode == 0)
    check('creator geometry is canonical',
          wait_state((a,), session, ((0, 1, 117, 33),), (116, 31)))

    # Initial geometry belongs to the existing session. A small joining host
    # cannot implicitly shrink it.
    b = stlib.Client(HOME, args=['--attach', session],
                     w=70, h=22, lang='en')
    b.drain(2.5)
    check('smaller client attaches', b.alive())
    check('attach leaves canonical desktop and PTY',
          wait_state((a, b), session,
                     ((0, 1, 117, 33), None), (116, 31)))

    bars_ready = b.wait_until(lambda _text: desktop_bars(b), 5.0)
    if not bars_ready:
        print_bar_diagnostic(b)
    check('smaller client has both local viewport scrollbars', bars_ready)
    original_a_title = title_pos(a)
    original_b_title = title_pos(b)
    if original_b_title is not None:
        click(b, b.w - 2, b.h - 2)
    scrolled = b.wait_until(
        lambda _text: (original_b_title is not None and
                       title_pos(b) == (original_b_title[0] - 1,
                                        original_b_title[1])), 5.0)
    check('horizontal scrollbar changes only the small local viewport',
          scrolled and title_pos(a) == original_a_title and
          pane_size(session) == (116, 31))

    # A physical resize changes only B's surface and viewport chrome.
    host_resize(b, 90, 28)
    check('attached-client SIGWINCH keeps shared geometry',
          wait_state((a, b), session,
                     ((0, 1, 117, 33), None), (116, 31)))
    resized_bars = b.wait_until(lambda _text: desktop_bars(b), 5.0)
    if not resized_bars:
        print_bar_diagnostic(b)
    check('resized smaller client still owns both local scrollbars',
          resized_bars)

    # Growing A changes its physical margin only; it cannot resize B's world.
    host_resize(a, 140, 40)
    check('creator SIGWINCH keeps shared geometry',
          wait_state((a, b), session,
                     ((0, 1, 117, 33), None), (116, 31)))
    check('large client needs no viewport scrollbars',
          a.wait_until(lambda _text: not desktop_bars(a), 5.0))

    # The control command changes one pane's canonical terminal grid, not the
    # outer desktop/window geometry.
    result = run_cli(['resize', session + ':1', '90x25'], HOME)
    check('explicit pane resize succeeds', result.returncode == 0)
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and pane_size(session) != (90, 25):
        drain_all((a, b), 0.08)
        time.sleep(0.025)
    check('explicit pane resize changes only PTY',
          pane_size(session) == (90, 25) and
          frame_rect(a) == (0, 1, 117, 33) and frame_rect(b) is None)

    run_cli(['send', session + ':1', 'echo ONE_SHARED_DESKTOP'], HOME)
    a.wait_until(lambda text: 'ONE_SHARED_DESKTOP' in text, 5.0)
    check('shared output remains live', 'ONE_SHARED_DESKTOP' in a.text())

    # No viewer remains, but the live daemon keeps the last common desktop.
    b.send(b'\x11', 0.2)
    b.send(b'd', 0.8)
    b.close()
    b = None
    a.send(b'\x11', 0.2)
    a.send(b'd', 0.8)
    try:
        a.wait_exit(timeout=6.0)
    except Exception:
        pass
    a.close()
    time.sleep(0.8)
    check('detached daemon keeps pane size', pane_size(session) == (90, 25))

    c = stlib.Client(HOME, args=['--attach', session],
                     w=150, h=45, lang='en')
    c.drain(3.0)
    check('reattach receives prior contents', 'ONE_SHARED_DESKTOP' in c.text())
    check('reattach geometry is not renegotiated',
          frame_rect(c) == (0, 1, 117, 33) and
          pane_size(session) == (90, 25))
finally:
    if c is not None:
        c.close()
    if b is not None:
        b.close()
    a.close()
    stlib.close_all_daemons(HOME)

stlib.report()
