#!/usr/bin/env python3
"""Normal maximize follows the logical desktop, never a physical viewer.

A small client creates the session and a large one attaches. SIGWINCH on the
large client is presentation-only. Only Desktop > Adjust to this terminal
changes canonical bounds; that explicit transaction leaves the normal window
and PTY untouched. Native/CLI maximize then use those logical bounds even
while the smaller viewer is clipped behind its own scrollbars.
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


HOME = stlib.fresh_home('maximize-logical-desktop-' + str(os.getpid()))
TITLE = 'LOGICALMAX'
SMALL_HOST = (88, 27)  # 25-row usable desktop: exact supported minimum
LARGE_ATTACH = (128, 38)
LARGE_HOST = (132, 40)
LOGICAL_DESK = (LARGE_HOST[0], LARGE_HOST[1] - 2)
MANUAL_DESK = (126, 35)
MAX_FRAME = (0, 1, LOGICAL_DESK[0] - 1, LOGICAL_DESK[1])
MAX_PTY = (LOGICAL_DESK[0] - 2, LOGICAL_DESK[1] - 2)

with open(HOME + '/.superterm/superterm.ini', 'w') as stream:
    stream.write('[ui]\nlanguage=en\nbackground=none\n'
                 '[session]\nserver=always\nautosave=0\nautorestore=0\n'
                 'zoomanim=0\n')


def pane_state(session):
    result = run_cli(['list', session], HOME, env={'LANG': 'C'})
    if result.returncode != 0:
        return None, ''
    for line in result.stdout.splitlines():
        if not line.startswith('1 '):
            continue
        size = None
        for token in line.split():
            if 'x' not in token or not token[0].isdigit():
                continue
            try:
                size = tuple(int(value) for value in token.split('x', 1))
                break
            except ValueError:
                pass
        flags = line.split()[-1]
        if not set(flags) <= set('*MZ!'):
            flags = ''
        return size, flags
    return None, ''


def frame_rect(client):
    rows = client.screen.display
    for top, row in enumerate(rows):
        title_x = row.find(TITLE)
        if title_x < 0:
            continue
        lefts = [x for x, char in enumerate(row[:title_x])
                 if char in ('╔', '┌', '▒')]
        rights = [x for x, char in enumerate(
            row[title_x + len(TITLE):], title_x + len(TITLE))
                  if char in ('╗', '┐', '▒')]
        if not lefts or not rights:
            continue
        left, right = max(lefts), min(rights)
        for bottom in range(top + 2, len(rows)):
            if (rows[bottom][left] in ('╚', '└', '▒', '░') and
                    rows[bottom][right] in ('╝', '┘', '▒', '░')):
                return left, top, right, bottom
    return None


def desktop_bars(client):
    rows = client.screen.display
    if len(rows) < client.h or client.w < 3 or client.h < 5:
        return False
    return (rows[client.h - 2][0] in ('◄', '<') and
            rows[client.h - 2][client.w - 2] in ('►', '>') and
            rows[1][client.w - 1] in ('▲', '^') and
            rows[client.h - 3][client.w - 1] in ('▼', 'V'))


def host_resize(client, width, height):
    client.w, client.h = width, height
    client.screen.resize(lines=height, columns=width)
    fcntl.ioctl(client.fd, termios.TIOCSWINSZ,
                struct.pack('HHHH', height, width, 0, 0))


def click(client, x, y):
    stlib.write_all(client.fd, f'\x1b[<0;{x + 1};{y + 1}M'.encode())
    stlib.write_all(client.fd, f'\x1b[<0;{x + 1};{y + 1}m'.encode())


def set_manual_desktop(client, width, height):
    """Drive the real Desktop dialog and replace both selected input lines."""
    client.send(b'\x1bd', 0.0)
    if not client.wait_until(lambda text: 'Modify dimensions' in text, 4.0):
        return False
    client.send(b'm', 0.0)
    if not client.wait_until(lambda text: 'Desktop dimensions' in text, 4.0):
        return False
    for label, value in (('Width', width), ('Height', height)):
        point = None
        for y, row in enumerate(client.screen.display):
            label_x = row.find(label)
            if label_x >= 0:
                # RunDesktopSizeDialog places its input at local X=22 and the
                # label at X=3: click one cell inside that 12-cell input.
                point = label_x + 20, y
                break
        if point is None:
            return False
        click(client, *point)
        client.send(b'\x19' + str(value).encode(), 0.0)  # Ctrl-Y clears line
    client.send(b'\r', 0.0)  # default OK
    return client.wait_until(
        lambda text: 'Desktop dimensions' not in text, 6.0)


def wait_state(clients, session, frames, pty, zoomed, timeout=8.0):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.04)
        size, flags = pane_state(session)
        last = ([frame_rect(client) for client in clients], size, flags)
        if (last[0] == list(frames) and size == pty and
                (('Z' in flags) == zoomed)):
            return True
    print('  last logical maximize state:', last,
          'expected:', (list(frames), pty, zoomed))
    return False


small = stlib.Client(HOME, w=SMALL_HOST[0], h=SMALL_HOST[1], lang='en')
large = None
try:
    ready = small.wait_until(
        lambda _text: len(stlib.session_sockets(HOME)) == 1, 8.0)
    check('small creator session exists', ready)
    sockets = stlib.session_sockets(HOME)
    session = os.path.basename(sockets[0])[:-5] if len(sockets) == 1 else ''
    renamed = run_cli(['rename', session + ':1', TITLE], HOME,
                      env={'LANG': 'C'})
    check('maximize fixture pane renamed', renamed.returncode == 0)
    original_ready = small.wait_until(
        lambda _text: frame_rect(small) is not None, 6.0)
    original_frame = frame_rect(small)
    original_pty, _flags = pane_state(session)
    check('small creator has complete canonical frame',
          original_ready and original_frame is not None and
          original_pty is not None)

    large = stlib.Client(HOME, args=['--attach', session],
                         w=LARGE_ATTACH[0], h=LARGE_ATTACH[1], lang='en')
    check('larger viewer attaches',
          large.wait_until(lambda _text: frame_rect(large) == original_frame,
                           8.0))
    host_resize(large, *LARGE_HOST)
    check('large SIGWINCH leaves canonical window and PTY unchanged',
          wait_state((small, large), session,
                     (original_frame, original_frame), original_pty, False))

    # Exercise the actual new top-level Desktop menu. Its accelerator is D;
    # Adjust is A. The authoritative layout event is observed through the
    # large full frame plus the small client's local scrollbar chrome.
    large.send(b'\x1bd', 0.0)
    menu_open = large.wait_until(
        lambda text: 'Adjust to this terminal size' in text, 5.0)
    check('Desktop menu exposes explicit fit command', menu_open)
    large.send(b'a', 0.0)
    adjusted = False
    fit_deadline = time.monotonic() + 8.0
    while time.monotonic() < fit_deadline:
        small.drain(0.04)
        large.drain(0.04)
        if (desktop_bars(small) and
                frame_rect(large) == original_frame):
            adjusted = True
            break
    fit_ok = (adjusted and frame_rect(small) == original_frame and
              pane_state(session)[0] == original_pty)
    if not fit_ok:
        print('  explicit fit diagnostic:', {
            'bars': desktop_bars(small),
            'small_frame': frame_rect(small),
            'large_frame': frame_rect(large),
            'original_frame': original_frame,
            'pty': pane_state(session)[0],
            'original_pty': original_pty,
        })
    check('explicit fit grows desktop without scaling normal window',
          fit_ok)

    # Show current dimensions is another independent UI oracle for the exact
    # logical size chosen above, rather than an inference from a pane grid.
    large.send(b'\x1bd', 0.0)
    large.wait_until(lambda text: 'Show current dimensions' in text, 4.0)
    large.send(b's', 0.0)
    shown = large.wait_until(
        lambda text: f'Logical desktop: {LOGICAL_DESK[0]}x{LOGICAL_DESK[1]}'
        in text, 5.0)
    check('Desktop menu reports exact logical dimensions', shown)
    large.send(b'\r', 0.0)
    large.wait_until(lambda text: 'Logical desktop:' not in text, 5.0)

    # Exercise the other mutating menu path, including both real input lines.
    # A manual desktop change has the same invariant as Fit: it must not scale
    # this normal frame or PTY. Then restore the larger logical size for the
    # maximize checks below.
    manual_ok = set_manual_desktop(large, *MANUAL_DESK)
    check('manual Desktop dialog accepts explicit dimensions', manual_ok)
    large.send(b'\x1bd', 0.0)
    large.wait_until(lambda text: 'Show current dimensions' in text, 4.0)
    large.send(b's', 0.0)
    manual_shown = large.wait_until(
        lambda text: f'Logical desktop: {MANUAL_DESK[0]}x{MANUAL_DESK[1]}'
        in text, 5.0)
    check('manual Desktop dialog commits exact logical dimensions',
          manual_shown and frame_rect(large) == original_frame and
          pane_state(session)[0] == original_pty)
    large.send(b'\r', 0.0)
    large.wait_until(lambda text: 'Logical desktop:' not in text, 5.0)
    large.send(b'\x1bd', 0.0)
    large.wait_until(lambda text: 'Adjust to this terminal size' in text, 4.0)
    large.send(b'a', 0.0)
    check('fit restores terminal logical dimensions after manual edit',
          large.wait_until(
              lambda _text: (frame_rect(large) == original_frame and
                             desktop_bars(small)), 8.0) and
          pane_state(session)[0] == original_pty)

    # Native title zoom uses the logical desktop. The smaller client clips it
    # but never forces a smaller canonical maximum.
    restored_large = frame_rect(large)
    if restored_large is not None:
        _left, top, right, _bottom = restored_large
        click(large, right - 3, top)
    check('native maximize uses logical desktop, not smallest host',
          wait_state((small, large), session, (None, MAX_FRAME),
                     MAX_PTY, True))

    resize_zoomed = run_cli(['resize', session + ':1', '40x10'], HOME,
                             env={'LANG': 'C'})
    check('explicit pane resize rejects maximized pane',
          resize_zoomed.returncode != 0 and
          'restore' in
          (resize_zoomed.stdout + resize_zoomed.stderr).lower())
    check('rejected pane resize preserves logical maximum',
          wait_state((small, large), session, (None, MAX_FRAME),
                     MAX_PTY, True))

    restored = run_cli(['restore', session + ':1'], HOME, env={'LANG': 'C'})
    check('CLI restore succeeds', restored.returncode == 0)
    check('restore recovers exact unscaled frame and PTY',
          wait_state((small, large), session,
                     (original_frame, original_frame),
                     original_pty, False))

    cli_zoom = run_cli(['zoom', session + ':1'], HOME, env={'LANG': 'C'})
    check('CLI maximize succeeds', cli_zoom.returncode == 0)
    check('CLI maximize uses same logical bounds',
          wait_state((small, large), session, (None, MAX_FRAME),
                     MAX_PTY, True))

    # A subsequent host grow is presentation-only even while zoomed.
    host_resize(large, 150, 45)
    check('SIGWINCH while zoomed keeps logical maximum and PTY',
          wait_state((small, large), session, (None, MAX_FRAME),
                     MAX_PTY, True))
finally:
    if large is not None:
        large.close()
    small.close()
    stlib.close_all_daemons(HOME)

stlib.report()
