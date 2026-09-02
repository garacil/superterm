#!/usr/bin/env python3
"""Mouse menu activation and exclusive pane focus under tmux TERM."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib


HOME = stlib.fresh_home('mouse-focus')
W, H = 110, 35
with open(HOME + '/.superterm/superterm.ini', 'w') as config:
    config.write('[ui]\n'
                 'language=en\n'
                 'background=none\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n')


def mouse(client, x, y):
    os.write(client.fd, f'\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m'.encode())
    client.drain(0.5)


def pane_rows(session):
    result = stlib.run_cli(['list', session], HOME, env={'LANG': 'C'})
    rows = [line for line in result.stdout.splitlines()
            if line and line[0].isdigit()]
    return result, rows


def focused_pane(rows):
    for row in rows:
        if '*' in row:
            try:
                return int(row.split()[0])
            except (IndexError, ValueError):
                return None
    return None


def frame_count(client):
    """Count visible normal-window top-left corners, excluding icons."""
    rows = client.screen.display
    count = 0
    for y, row in enumerate(rows[:-1]):
        for x, char in enumerate(row):
            if char not in ('╔', '┌'):
                continue
            if y + 1 < len(rows) and rows[y + 1][x] in ('╚', '└'):
                continue
            count += 1
    return count


def capture(session, pane):
    return stlib.run_cli(['capture', f'{session}:{pane}'], HOME).stdout


client = stlib.Client(HOME, w=W, h=H,
                      env={'TERM': 'tmux-256color'})
try:
    stlib.check('menu bar becomes visible',
                client.wait_until(lambda text: 'Panes' in text, 8.0))
    sockets = stlib.session_sockets(HOME)
    stlib.check('one isolated session exists', len(sockets) == 1)
    session = os.path.basename(sockets[0])[:-5] if len(sockets) == 1 else ''

    mouse(client, 5, 1)
    stlib.check('mouse opens Panels menu',
                client.wait_until(lambda text: 'Split vertical' in text, 5.0))

    # Panes > Vertical, using global 1-based SGR coordinates.
    mouse(client, 5, 3)
    result, rows = pane_rows(session)
    deadline = time.time() + 6.0
    while time.time() < deadline and len(rows) != 2:
        client.drain(0.2)
        result, rows = pane_rows(session)
    stlib.check('split command succeeds', result.returncode == 0)
    stlib.check('split creates exactly two panes', len(rows) == 2)
    stlib.check('split draws exactly two frames',
                client.wait_until(lambda _text: frame_count(client) == 2,
                                  5.0))

    # Route a unique token to the newly focused pane, then prove it is absent
    # from the other pane's daemon capture.  Merely seeing text in the merged
    # client surface cannot establish its destination.
    right_target = focused_pane(rows)
    stlib.check('new pane is focused in list', right_target in (1, 2))
    other = 3 - right_target if right_target in (1, 2) else 1
    right_token = 'RIGHT_TOKEN_MOUSE_7719'
    client.send(f'echo {right_token}\r'.encode(), 0.8)
    client.wait_until(lambda _text: right_token in capture(session,
                                                           right_target), 5.0)
    stlib.check('new pane receives input exclusively',
                right_token in capture(session, right_target) and
                right_token not in capture(session, other))

    # The centred focused window leaves this part of the underlying window
    # visible.  Clicking it must move the authoritative focus flag and route
    # the next token only to that pane.
    mouse(client, 3, 5)
    _result, clicked_rows = pane_rows(session)
    clicked_target = focused_pane(clicked_rows)
    deadline = time.time() + 5.0
    while (time.time() < deadline and
           (clicked_target not in (1, 2) or clicked_target == right_target)):
        client.drain(0.2)
        _result, clicked_rows = pane_rows(session)
        clicked_target = focused_pane(clicked_rows)
    stlib.check('pane click changes focused flag',
                clicked_target in (1, 2) and clicked_target != right_target)
    clicked_other = 3 - clicked_target if clicked_target in (1, 2) else 1
    left_token = 'LEFT_TOKEN_MOUSE_8823'
    client.send(f'echo {left_token}\r'.encode(), 0.8)
    client.wait_until(lambda _text: left_token in capture(session,
                                                          clicked_target),
                      5.0)
    stlib.check('clicked pane receives input exclusively',
                left_token in capture(session, clicked_target) and
                left_token not in capture(session, clicked_other))
finally:
    try:
        client.send(b'\x1bx', 0.5)
        client.wait_exit(4.0)
    except OSError:
        pass
    stlib.close_all_daemons(HOME)
    client.wait_exit(2.0)
    client.close()

stlib.report()
