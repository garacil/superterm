#!/usr/bin/env python3
"""Restoring the sole minimized icon must restore real shared focus.

This reproduces the FreeVision edge case where the icon is already first in
Z order while Desktop.Current still names the fallback window.  It checks the
active frame and routes real shell input from both attached clients, so a
daemon-only focus flag cannot make the test pass by itself.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('restore-focus')
with open(HOME + '/.superterm/superterm.ini', 'w') as fh:
    fh.write('[ui]\n'
             'language=en\n'
             'background=none\n'
             '[session]\n'
             'server=always\n'
             'autosave=0\n'
             'autorestore=0\n')

ENV = {
    'SUPERTERM_DEBUG': '/tmp/superterm-restore-focus.log',
    'SUPERTERM_DEBUG_FULL': '1',
}

a = stlib.Client(HOME, w=110, h=34, lang='en', env=ENV)
a.drain(2.0)
a.send(b'\x1bOQ', 0.9)       # F2: exactly two panes

sockets = stlib.session_sockets(HOME)
check('restore-focus session exists', len(sockets) == 1)
SESSION = os.path.basename(sockets[0])[:-5] if sockets else ''


def control(args, attempts=20):
    last = None
    for _attempt in range(attempts):
        last = run_cli(args, HOME, env=ENV)
        if last.returncode == 0:
            return last
        if 'busy' not in (last.stdout + last.stderr).lower():
            break
        time.sleep(0.05)
    if last is not None:
        print('  control failed:', ' '.join(args),
              repr((last.stdout + last.stderr).strip()))
    return last


check('restore-focus pane 1 renamed',
      control(['rename', SESSION + ':1', 'RESTOREDPANE']).returncode == 0)
check('restore-focus pane 2 renamed',
      control(['rename', SESSION + ':2', 'FALLBACKPANE']).returncode == 0)
check('restore-focus panes arranged',
      control(['organize', SESSION, 'grid']).returncode == 0)

b = stlib.Client(HOME, args=['--attach'], w=110, h=34, lang='en', env=ENV)
b.drain(2.2)
a.drain(0.6)
clients = (a, b)


def drain_all(seconds=0.4):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.025)


def frame_rect(client, title):
    rows = client.screen.display
    for top, row in enumerate(rows):
        title_x = row.find(title)
        if title_x < 0:
            continue
        lefts = [x for x, ch in enumerate(row[:title_x])
                 if ch in ('╔', '┌')]
        rights = [x for x, ch in enumerate(row[title_x + len(title):],
                  title_x + len(title)) if ch in ('╗', '┐')]
        if not lefts or not rights:
            continue
        left, right = max(lefts), min(rights)
        for bottom in range(top + 2, len(rows)):
            if (rows[bottom][left] in ('╚', '└') and
                    rows[bottom][right] in ('╝', '┘')):
                return left, top, right, bottom
    return None


def icon_rect(client, title):
    rows = client.screen.display
    for top in range(len(rows) - 1):
        title_x = rows[top].find(title)
        if title_x < 0:
            continue
        lefts = [x for x, ch in enumerate(rows[top][:title_x])
                 if ch == '┌']
        rights = [x for x, ch in enumerate(rows[top][title_x + len(title):],
                  title_x + len(title)) if ch == '┐']
        if not lefts or not rights:
            continue
        left, right = max(lefts), min(rights)
        if (rows[top + 1][left] == '└' and
                rows[top + 1][right] == '┘'):
            return left, top, right, top + 1
    return None


def active_frame(client, title):
    rect = frame_rect(client, title)
    if rect is None:
        return False
    left, top, right, _bottom = rect
    return '[-]' in client.screen.display[top][left:right + 1]


def token_inside(client, title, token):
    rect = frame_rect(client, title)
    if rect is None:
        return False
    left, top, right, bottom = rect
    return any(token in row[left + 1:right]
               for row in client.screen.display[top + 1:bottom])


def click(client, x, y):
    client.send(
        f'\x1b[<0;{x + 1};{y + 1}M\x1b[<0;{x + 1};{y + 1}m'.encode(),
        0.25)


def daemon_state():
    result = run_cli(['list', SESSION], HOME, env=ENV)
    minimized = set()
    focused = None
    for line in result.stdout.splitlines():
        fields = line.split()
        if not fields or not fields[0].isdigit():
            continue
        pane = int(fields[0])
        flags = fields[-1] if set(fields[-1]) <= set('*MZ!') else ''
        if 'M' in flags:
            minimized.add(pane)
        if '*' in flags:
            focused = pane
    return result.returncode, minimized, focused


def wait_state(minimized, focused, timeout=4.0):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        drain_all(0.06)
        last = daemon_state()
        if last == (0, set(minimized), focused):
            return True
        time.sleep(0.025)
    print('  last daemon state:', last)
    return False


check('focus pane before minimizing',
      control(['focus', SESSION + ':1']).returncode == 0)
drain_all(0.5)
target = frame_rect(a, 'RESTOREDPANE')
check('restore-focus target frame found', target is not None)
if target is not None:
    _left, top, right, _bottom = target
    click(a, right - 8, top)    # centre of the active [-] button
check('minimize selects fallback', wait_state({1}, 2))

icon = icon_rect(a, 'RESTOREDPANE')
check('sole restore icon found', icon is not None)
if icon is not None:
    left, top, right, _bottom = icon
    click(a, (left + right) // 2, top)
check('restore publishes pane focus', wait_state(set(), 1))
check('restored frame active in both',
      active_frame(a, 'RESTOREDPANE') and
      active_frame(b, 'RESTOREDPANE') and
      not active_frame(a, 'FALLBACKPANE') and
      not active_frame(b, 'FALLBACKPANE'))

actor_token = 'ACTOR_RESTORE_ROUTE'
os.write(a.fd, b'printf ACTOR_RESTORE_ROUTE\\n\r')
drain_all(0.8)
check('actor input routed to restored pane',
      all(token_inside(client, 'RESTOREDPANE', actor_token) and
          not token_inside(client, 'FALLBACKPANE', actor_token)
          for client in clients))

observer_token = 'OBSERVER_RESTORE_ROUTE'
os.write(b.fd, b'printf OBSERVER_RESTORE_ROUTE\\n\r')
drain_all(0.8)
check('observer input routed to restored pane',
      all(token_inside(client, 'RESTOREDPANE', observer_token) and
          not token_inside(client, 'FALLBACKPANE', observer_token)
          for client in clients))

for client in (b, a):
    client.send(b'\x11', 0.10)
    client.send(b'd', 0.35)
    client.wait_exit(timeout=5.0)
    client.close()
stlib.close_all_daemons(HOME)
stlib.report()
