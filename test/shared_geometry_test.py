#!/usr/bin/env python3
"""One live desktop is shared; attach and later host resize are distinct.

An attach at a different physical size receives the existing canonical
geometry verbatim and clips it if necessary.  A SIGWINCH after that attach is
an explicit window-management action: it atomically replaces the common
desktop, pane rectangles and PTY size for every viewer.
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


def scaled_single_pane(rectangle, old_host, new_host):
    """Precompute the canonical inclusive frame and PTY after ScaleRect."""
    left, top, right, bottom = rectangle
    old_width, old_height = old_host[0], old_host[1] - 2
    new_width, new_height = new_host[0], new_host[1] - 2

    def edge(value, old_size, new_size):
        return (value * new_size + old_size // 2) // old_size

    new_left = edge(left, old_width, new_width)
    new_top = edge(top - 1, old_height, new_height)
    new_right = edge(right + 1, old_width, new_width)
    new_bottom = edge(bottom, old_height, new_height)
    new_left = max(0, min(new_left, new_width - 16))
    new_top = max(0, min(new_top, new_height - 6))
    new_right = min(new_width, max(new_right, new_left + 16))
    new_bottom = min(new_height, max(new_bottom, new_top + 6))
    return ((new_left, new_top + 1, new_right - 1, new_bottom),
            (new_right - new_left - 2, new_bottom - new_top - 2))


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

    # A subsequent physical resize is a deliberate shared action even when it
    # comes from the client that originally joined at another size.
    smaller_rect, smaller_pty = scaled_single_pane(
        (0, 1, 117, 33), (120, 36), (90, 28))
    host_resize(b, 90, 28)
    check('attached-client resize becomes shared',
          wait_state((a, b), session,
                     (smaller_rect, smaller_rect), smaller_pty))

    larger_rect, larger_pty = scaled_single_pane(
        smaller_rect, (90, 28), (140, 40))
    host_resize(a, 140, 40)
    check('creator resize becomes shared',
          wait_state((a, b), session,
                     (larger_rect, None), larger_pty))

    # The control command changes one pane's canonical terminal grid, not the
    # outer desktop/window geometry chosen by the last host resize.
    result = run_cli(['resize', session + ':1', '90x25'], HOME)
    check('explicit pane resize succeeds', result.returncode == 0)
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and pane_size(session) != (90, 25):
        drain_all((a, b), 0.08)
        time.sleep(0.025)
    check('explicit pane resize changes only PTY',
          pane_size(session) == (90, 25) and
          frame_rect(a) == larger_rect and frame_rect(b) is None)

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
          frame_rect(c) == larger_rect and
          pane_size(session) == (90, 25))
finally:
    if c is not None:
        c.close()
    if b is not None:
        b.close()
    a.close()
    stlib.close_all_daemons(HOME)

stlib.report()
