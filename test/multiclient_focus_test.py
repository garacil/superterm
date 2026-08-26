#!/usr/bin/env python3
"""Focus is shared, while every attached client may write without a lock."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('multiclient-focus')
INI = os.path.join(HOME, '.superterm', 'superterm.ini')
with open(INI, 'w') as f:
    f.write('[ui]\nlanguage=en\nbackground=none\n'
            '[session]\nserver=always\nautosave=0\nautorestore=0\n')

a = stlib.Client(HOME, w=100, h=30, lang='en')
a.drain(2.5)
a.send(b'\x1bOQ', 1.5)          # F2: second pane
a.send(b'\x11', 0.2)
a.send(b't', 1.2)                # tile the two windows

sockets = stlib.session_sockets(HOME)
check('session server exists', len(sockets) == 1)
SES = os.path.basename(sockets[0])[:-5] if sockets else ''
check('lock pane has stable title',
      run_cli(['rename', SES + ':1', 'LOCKPANE'], HOME).returncode == 0)

b = stlib.Client(HOME, args=['--attach'], w=100, h=30, lang='en')
b.drain(3.0)
check('second client attached', b.alive())


def click(c, x, y):
    c.send(f'\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m'.encode(), 0.25)


def drain_both(seconds=1.2):
    end = time.time() + seconds
    while time.time() < end:
        a.drain(0.04)
        b.drain(0.04)


def active_side(c):
    """Return left/right according to the active double-line frame."""
    for row in c.screen.display[1:7]:
        active = row.find('╔')
        inactive = row.find('┌')
        if active >= 0 and inactive >= 0:
            return 'left' if active < inactive else 'right'
    return 'unknown'


# A focus frame is lock-free but authoritative: every viewer follows it.
click(a, 5, 5)
drain_both()
check('A focus propagates left to A', active_side(a) == 'left')
check('A focus propagates left to B', active_side(b) == 'left')

click(b, 60, 5)
drain_both()
check('B focus propagates right to A', active_side(a) == 'right')
check('B focus propagates right to B', active_side(b) == 'right')

# No input lock exists. Both clients write to the current shared pane; both
# commands must arrive, in send order, without one client disabling the other.
a.send(b"printf 'WRITE_FROM_A\\n'\r", 0.05)
b.send(b"printf 'WRITE_FROM_B\\n'\r", 0.8)
drain_both()
cap1 = run_cli(['capture', SES + ':1'], HOME).stdout if SES else ''
cap2 = run_cli(['capture', SES + ':2'], HOME).stdout if SES else ''
check('both clients can write shared focus',
      'WRITE_FROM_A' in cap2 and 'WRITE_FROM_B' in cap2)
check('shared focus routes neither write left',
      'WRITE_FROM_A' not in cap1 and 'WRITE_FROM_B' not in cap1)
check('both viewers receive A output', 'WRITE_FROM_A' in a.text() and
      'WRITE_FROM_A' in b.text())
check('both viewers receive B output', 'WRITE_FROM_B' in a.text() and
      'WRITE_FROM_B' in b.text())

# The control client changes the same focus and every UI follows it.
r = run_cli(['focus', SES + ':1'], HOME) if SES else None
check('CLI focus succeeds', r is not None and r.returncode == 0)
drain_both()
cli_side_a = active_side(a)
cli_side_b = active_side(b)
if cli_side_a != 'left' or cli_side_b != 'left':
    print('CLI focus diagnostic A:', repr(a.screen.display[1:7]))
    print('CLI focus diagnostic B:', repr(b.screen.display[1:7]))
check('CLI focus propagates to A', cli_side_a == 'left')
check('CLI focus propagates to B', cli_side_b == 'left')


def has_vertical_lock(c):
    rows = c.screen.display
    for x in range(c.w):
        for y in range(max(0, c.h - 3)):
            if ''.join(rows[y + n][x] for n in range(4)) == 'LOCK':
                return True
    return False


# Hold the left title border down: FreeVision remains in its modal DragView,
# but the daemon and the other UI must remain completely live.
stlib.write_all(a.fd, b'\x1b[<0;10;2M')
time.sleep(0.25)
b.drain(0.9)
check('other client sees shaded lock border',
      any(ch in ('░', '▒') for row in b.screen.display for ch in row))
check('other client sees vertical LOCK', has_vertical_lock(b))

start = time.monotonic()
busy = run_cli(['minimize', SES + ':1'], HOME, timeout=5)
check('competing pane action never waits', time.monotonic() - start < 2.0)
check('first pane action owns the lock',
      busy.returncode != 0 and 'busy' in (busy.stderr + busy.stdout).lower())

# Keep hammering the exact same pane while the mouse remains down. A single
# successful mutation would prove that ownership was released between modal
# mouse events (the live bug a stationary human gesture exposed).
blocked_ops = (
    ['minimize', SES + ':1'],
    ['restore', SES + ':1'],
    ['resize', SES + ':1', '41x12'],
    ['rename', SES + ':1', 'MUST_NOT_WIN'],
)
blocked_ok = True
blocked_started = time.monotonic()
for attempt in range(12):
    result = run_cli(blocked_ops[attempt % len(blocked_ops)], HOME, timeout=5)
    blocked_ok = blocked_ok and result.returncode != 0 and (
        'busy' in (result.stderr + result.stdout).lower())
check('held gesture rejects 12 same-pane mutations', blocked_ok)
check('held rejection remains nonblocking',
      time.monotonic() - blocked_started < 4.0)

b.send(b"printf 'WRITE_WHILE_LOCKED\\n'\r", 0.8)
check('input stays enabled while locked',
      'WRITE_WHILE_LOCKED' in run_cli(['capture', SES + ':1'], HOME).stdout)
check('output stays live while locked', 'WRITE_WHILE_LOCKED' in b.text())

# Release at the same coordinate (no geometry change), then verify that both
# the transient word and shaded CP437 border disappear from the other viewer.
stlib.write_all(a.fd, b'\x1b[<0;10;2m')
drain_both(1.5)
check('unlock removes vertical LOCK', not has_vertical_lock(b))
check('unlock restores normal border',
      not any(ch in ('░', '▒') for row in b.screen.display for ch in row))


def frame_rect(c, title):
    for top, row in enumerate(c.screen.display):
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
        for bottom in range(top + 2, c.h):
            if (c.screen.display[bottom][left] in ('╚', '└') and
                    c.screen.display[bottom][right] in ('╝', '┘')):
                return left, top, right, bottom
    return None


# Drag the actual title text one character per event.  The original minimize
# button remains in its traditional local X Size.X-10..-8 slot; the title
# itself must only move the window and hold the pane lock.
before = frame_rect(a, 'LOCKPANE')
check('title drag frame found', before is not None)
if before is not None:
    left, top, right, _bottom = before
    title_x = a.screen.display[top].find('LOCKPANE')
    title_drag_x = title_x + len('LOCKPANE') // 2
    press = f'\x1b[<0;{title_drag_x + 1};{top + 1}M'.encode()
    stlib.write_all(a.fd, press)
    time.sleep(0.2)
    b.drain(0.4)
    busy = run_cli(['minimize', SES + ':1'], HOME, timeout=5)
    check('title drag owns pane continuously',
          busy.returncode != 0 and
          'busy' in (busy.stderr + busy.stdout).lower())
    for delta in range(1, 7):
        stlib.write_all(a.fd,
                        (f'\x1b[<32;{title_drag_x + delta + 1};'
                         f'{top + 1}M').encode())
        drain_both(0.06)
    stlib.write_all(
        a.fd, (f'\x1b[<0;{title_drag_x + 7};{top + 1}m').encode())
    drain_both(1.2)
after = frame_rect(a, 'LOCKPANE')
check('title text drag moves window',
      before is not None and after is not None and after[0] > before[0])
pane_one = next((line for line in
                 run_cli(['list', SES], HOME).stdout.splitlines()
                 if line.startswith('1')), '')
check('title drag never minimizes window', 'M' not in pane_one.split()[-1:])

# The original [-] is visible in its historical right-hand slot. Clicking it
# publishes the shared minimized state, and restoring returns the same window.
button_frame = frame_rect(a, 'LOCKPANE')
check('original minimize button frame found', button_frame is not None)
if button_frame is not None:
    _left, top, right, _bottom = button_frame
    check('original minimize button visible in A',
          a.screen.display[top][right - 9:right - 6] == '[-]')
    check('original minimize button visible in B',
          b.screen.display[top][right - 9:right - 6] == '[-]')
    click(a, right - 7, top + 1)
    drain_both(1.2)
pane_one = next((line for line in
                 run_cli(['list', SES], HOME).stdout.splitlines()
                 if line.startswith('1')), '')
check('original minimize button minimizes shared pane',
      pane_one.split()[-1:] == ['M'])
check('restore after minimize button',
      run_cli(['restore', SES + ':1'], HOME).returncode == 0)
drain_both(1.2)
check('restored button window visible in both clients',
      frame_rect(a, 'LOCKPANE') is not None and
      frame_rect(b, 'LOCKPANE') is not None)

for c in (b, a):
    c.send(b'\x11', 0.2)
    c.send(b'd', 0.8)
    if 'Detach' in c.text() or 'detach' in c.text():
        c.send(b'\r', 0.8)
    c.close()
stlib.close_all_daemons(HOME)
stlib.report()
