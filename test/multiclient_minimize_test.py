#!/usr/bin/env python3
"""Stable shared icon slots and focus with two live FreeVision clients.

This is deliberately visual, not just a daemon-flag test.  It proves that
icons take the first free slot left-to-right and then bottom-to-top, restoring
one leaves a stable hole, and the next minimize reuses only that hole.  It also
checks that neither a focused minimize nor Minimize all rewrites shared focus.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('multiclient-minimize')
with open(HOME + '/.superterm/superterm.ini', 'w') as fh:
    fh.write('[ui]\nlanguage=en\nbackground=none\n'
             '[session]\nserver=always\nautosave=0\nautorestore=0\n')

DEBUG_ENV = {
    'SUPERTERM_DEBUG': '/tmp/superterm-multiclient-minimize.log',
    'SUPERTERM_DEBUG_FULL': '1',
    'SUPERTERM_HEAP_LOG': '/tmp/superterm-multiclient-minimize-heap',
    'HEAPTRC': 'nohalt',
}

a = stlib.Client(HOME, w=110, h=34, lang='en', env=DEBUG_ENV)
a.drain(2.0)
for _ in range(5):
    a.send(b'\x1bOQ', 0.55)       # F2: six panes total
a.send(b'\x11', 0.10)
a.send(b't', 0.9)                 # deterministic non-overlapping baseline

sockets = stlib.session_sockets(HOME)
check('session server exists', len(sockets) == 1)
SESSION = os.path.basename(sockets[0])[:-5] if sockets else ''
for pane in range(1, 7):
    result = run_cli(['rename', f'{SESSION}:{pane}', f'ICONPANE{pane}'],
                     HOME, env=DEBUG_ENV)
    check(f'pane {pane} renamed', result.returncode == 0)
check('six panes arranged as grid',
      run_cli(['organize', SESSION, 'grid'], HOME,
              env=DEBUG_ENV).returncode == 0)

b = stlib.Client(HOME, args=['--attach'], w=110, h=34, lang='en',
                 env=DEBUG_ENV)
b.drain(2.5)
a.drain(0.8)
clients = (a, b)


def drain_all(seconds=0.35):
    end = time.time() + seconds
    while time.time() < end:
        for client in clients:
            client.drain(0.025)


def state():
    result = run_cli(['list', SESSION], HOME,
                     env=dict(DEBUG_ENV, LANG='C'), timeout=6)
    panes = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        if not fields or not fields[0].isdigit():
            continue
        pane = int(fields[0])
        last = fields[-1]
        flags = last if set(last) <= set('*MZ!') else ''
        panes[pane] = flags
    return result.returncode, panes


def normal_rect(client, title):
    rows = client.screen.display
    for top, row in enumerate(rows):
        tx = row.find(title)
        if tx < 0:
            continue
        lefts = [x for x, ch in enumerate(row[:tx]) if ch in ('╔', '┌')]
        rights = [x for x, ch in enumerate(row[tx + len(title):],
                  tx + len(title)) if ch in ('╗', '┐')]
        if not lefts or not rights:
            continue
        left, right = max(lefts), min(rights)
        for bottom in range(top + 3, len(rows)):
            if (rows[bottom][left] in ('╚', '└') and
                    rows[bottom][right] in ('╝', '┘')):
                return left, top, right, bottom
    return None


def active_frame(client, pane):
    rect = normal_rect(client, f'ICONPANE{pane}')
    if rect is None:
        return False
    left, top, right, _bottom = rect
    row = client.screen.display[top]
    return (row[left] == '╔' or row[right] == '╗' or
            '[-]' in row[left:right + 1])


def wait_flags(expected_minimized, focused=None, timeout=4.0):
    deadline = time.time() + timeout
    last = {}
    while time.time() < deadline:
        drain_all(0.08)
        rc, last = state()
        minimized = {pane for pane, flags in last.items() if 'M' in flags}
        active = next((pane for pane, flags in last.items() if '*' in flags),
                      None)
        if rc == 0 and minimized == set(expected_minimized) and (
                focused is None or active == focused):
            return True
        time.sleep(0.025)
    print('  last daemon flags:', last)
    return False


def wait_visual_focus(pane, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        drain_all(0.06)
        if all(active_frame(client, pane) for client in clients):
            return True
    return False


def click(client, x, y):
    """Inject one complete SGR mouse click without a timing assumption."""
    stlib.write_all(
        client.fd,
        f'\x1b[<0;{x + 1};{y + 1}M\x1b[<0;{x + 1};{y + 1}m'.encode())


def icon_rect(client, title):
    """Return the exact two-row custom icon containing title."""
    rows = client.screen.display
    for top in range(len(rows) - 1):
        row = rows[top]
        tx = row.find(title)
        if tx < 0:
            continue
        lefts = [x for x, ch in enumerate(row[:tx]) if ch == '┌']
        rights = [x for x, ch in enumerate(row[tx + len(title):],
                  tx + len(title)) if ch == '┐']
        if not lefts or not rights:
            continue
        left, right = max(lefts), min(rights)
        if (rows[top + 1][left] == '└' and
                rows[top + 1][right] == '┘'):
            return left, top, right, top + 1
    return None


def visual_icons(expected):
    all_rects = []
    ok = True
    for client in clients:
        rects = {pane: icon_rect(client, f'ICONPANE{pane}')
                 for pane in expected}
        values = list(rects.values())
        present = all(rect is not None for rect in values)
        unique = present and len(set(values)) == len(values)
        once = all(client.text().count(f'ICONPANE{pane}') == 1
                   for pane in expected)
        ok = ok and present and unique and once
        all_rects.append(rects)
    shared = len(all_rects) < 2 or all_rects[0] == all_rects[1]
    return ok and shared, all_rects


def wait_visual_icons(expected, timeout=3.0):
    """Wait for both asynchronous UIs, not merely for the daemon flags."""
    deadline = time.time() + timeout
    detail = []
    while time.time() < deadline:
        drain_all(0.06)
        ok, detail = visual_icons(expected)
        if ok:
            return True, detail
    return False, detail


# Pane creation intentionally selects each new pane.  Establish a named focus
# baseline and wait for both actual renderers before testing that minimization
# does not rewrite it.
check('establish pane 1 focus baseline',
      run_cli(['focus', f'{SESSION}:1'], HOME,
              env=DEBUG_ENV).returncode == 0 and
      wait_flags(set(), focused=1) and wait_visual_focus(1))

# Assign five slots in an order unrelated to pane indices.  At 110 columns the
# 26-cell icons make four slots per row: slot four must wrap to the left edge of
# the row immediately above, not below the desktop or beside the status line.
slot_order = (4, 2, 6, 3, 5)
for index, pane in enumerate(slot_order):
    result = run_cli(['minimize', f'{SESSION}:{pane}'], HOME, env=DEBUG_ENV)
    check(f'first-free minimize pane {pane}', result.returncode == 0)
    check(f'minimize pane {pane} preserves focus',
          wait_flags(set(slot_order[:index + 1]), focused=1))

icons_ok, icon_detail = wait_visual_icons(set(slot_order))
if not icons_ok:
    print('  initial icon rectangles:', icon_detail)
check('five icons unique and shared', icons_ok)
initial = icon_detail[0] if icons_ok else {}
ordered = [initial.get(pane) for pane in slot_order]
first_row = ordered[:4]
wrapped = ordered[4] if len(ordered) == 5 else None
check('slots fill left to right on bottom row',
      all(rect is not None for rect in first_row) and
      len({rect[1] for rect in first_row}) == 1 and
      [rect[0] for rect in first_row] ==
      sorted(rect[0] for rect in first_row))
check('next slot wraps upward at left edge',
      wrapped is not None and first_row[0] is not None and
      wrapped[0] == first_row[0][0] and
      wrapped[1] == first_row[0][1] - 2)

# Click a minimized pane which is not the shared focus.  Restore and focus must
# be one daemon-authoritative transaction: both actor and observer settle on
# pane two, rather than the daemon rejecting an early focus while it still
# considers that pane minimized.
pane_two_icon = initial.get(2)
if pane_two_icon is not None:
    click(a, (pane_two_icon[0] + pane_two_icon[2]) // 2, pane_two_icon[1])
check('interactive restore focuses pane 2 for actor and observer',
      pane_two_icon is not None and
      wait_flags(set(slot_order) - {2}, focused=2) and
      wait_visual_focus(2))
icons_ok, hole_detail = wait_visual_icons(set(slot_order) - {2})
if not icons_ok:
    print('  icon rectangles after restore:', hole_detail)
after_hole = hole_detail[0] if icons_ok else {}
check('restore leaves a hole without moving icons',
      icons_ok and all(after_hole.get(pane) == initial.get(pane)
                       for pane in slot_order if pane != 2))

# Exercise the real Alt-F9 UI path from the pane just restored by mouse.  It
# must reuse the released slot and retain pane two as shared logical focus even
# though that pane is now represented by an icon.
a.send(b'\x1b[20;3~', 0.10)       # xterm Alt-F9: minimize focused window
check('focused minimize keeps shared focus',
      wait_flags(set(slot_order), focused=2))
icons_ok, reused_detail = wait_visual_icons(set(slot_order))
if not icons_ok:
    print('  icon rectangles after hole reuse:', reused_detail)
reused = reused_detail[0] if icons_ok else {}
check('next minimize reuses first free slot only',
      icons_ok and reused.get(2) == initial.get(2) and
      all(reused.get(pane) == initial.get(pane)
          for pane in slot_order if pane != 2))

# Keep the older high-rate restore/minimize regression as well as the new
# positional assertions.  Every target releases exactly its own slot and then
# immediately reacquires that first free hole; no other icon may move and the
# deliberately minimized logical focus remains pane two throughout.
for cycle in range(12):
    target = slot_order[cycle % len(slot_order)]
    result = run_cli(['restore', f'{SESSION}:{target}'], HOME, env=DEBUG_ENV)
    check(f'rapid restore {cycle}', result.returncode == 0)
    expected = set(slot_order) - {target}
    check(f'rapid restore state {cycle}',
          wait_flags(expected, focused=2))
    icons_ok, rapid_detail = wait_visual_icons(expected)
    rapid_icons = rapid_detail[0] if icons_ok else {}
    check(f'rapid restore keeps other slots {cycle}',
          icons_ok and all(rapid_icons.get(pane) == initial.get(pane)
                           for pane in expected))
    result = run_cli(['minimize', f'{SESSION}:{target}'], HOME, env=DEBUG_ENV)
    check(f'rapid minimize {cycle}', result.returncode == 0)
    check(f'rapid minimize state {cycle}',
          wait_flags(set(slot_order), focused=2))
    icons_ok, rapid_detail = wait_visual_icons(set(slot_order))
    rapid_icons = rapid_detail[0] if icons_ok else {}
    check(f'rapid minimize reuses exact hole {cycle}',
          icons_ok and all(rapid_icons.get(pane) == initial.get(pane)
                           for pane in slot_order))

# Minimize all is a UI-global transaction.  Pane one takes the next free slot,
# while the already-minimized focused pane remains the shared focus.
a.send(b'\x1bw', 0.05)            # Alt-W: Windows menu
menu_ready = a.wait_until(lambda text: 'Minimize all windows' in text,
                          timeout=2.0)
check('minimize all menu is observable', menu_ready)
if menu_ready:
    a.send(b'a', 0.05)             # Minimize all windows
check('minimize all keeps shared focus',
      wait_flags({1, 2, 3, 4, 5, 6}, focused=2))
icons_ok, all_detail = wait_visual_icons({1, 2, 3, 4, 5, 6})
if not icons_ok:
    print('  all-minimized icon rectangles:', all_detail)
check('all minimized icons remain unique and shared', icons_ok)

for client in (b, a):
    client.send(b'\x11', 0.10)
    client.send(b'd', 0.35)
    client.wait_exit(timeout=5.0)
    client.close()
stlib.close_all_daemons(HOME)
stlib.report()
