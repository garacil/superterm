#!/usr/bin/env python3
"""Shared minimize/icon invariants with two live FreeVision clients.

This is deliberately visual, not just a daemon-flag test: it parses both
rendered terminal grids and proves that every minimized window has one unique
two-row icon, restoring an icon publishes the state, and no minimized pane is
ever the shared focus.
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
for _ in range(3):
    a.send(b'\x1bOQ', 0.55)       # F2: four panes total
a.send(b'\x11', 0.10)
a.send(b't', 0.9)                 # deterministic non-overlapping baseline

sockets = stlib.session_sockets(HOME)
check('session server exists', len(sockets) == 1)
SESSION = os.path.basename(sockets[0])[:-5] if sockets else ''
for pane in range(1, 5):
    result = run_cli(['rename', f'{SESSION}:{pane}', f'ICONPANE{pane}'],
                     HOME, env=DEBUG_ENV)
    check(f'pane {pane} renamed', result.returncode == 0)
check('four panes arranged as grid',
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


# Preserve a pre-minimize position, then minimize three panes in an order that
# used to leave PANE2 hidden underneath PANE3.
before3 = normal_rect(a, 'ICONPANE3')
check('pane 3 baseline frame found', before3 is not None)
for pane in (3, 2, 4):
    result = run_cli(['minimize', f'{SESSION}:{pane}'], HOME, env=DEBUG_ENV)
    check(f'minimize pane {pane}', result.returncode == 0)
check('three minimized flags converge', wait_flags({2, 3, 4}, focused=1))
icons_ok, icon_detail = wait_visual_icons({2, 3, 4})
if not icons_ok:
    print('  icon rectangles:', icon_detail)
check('three icons unique and shared', icons_ok)

# Click PANE3's icon in the second UI. This path previously restored only the
# local TWindow and then let the next daemon event minimize it again.
pane3_icon = icon_rect(b, 'ICONPANE3')
check('pane 3 clickable icon found', pane3_icon is not None)
if pane3_icon is not None:
    left, top, right, _ = pane3_icon
    x = min(right - 1, left + 5)
    b.send(f'\x1b[<0;{x + 1};{top + 1}M\x1b[<0;{x + 1};{top + 1}m'.encode(),
           0.35)
check('icon click restores canonically', wait_flags({2, 4}, focused=3))
drain_all(0.4)
after3 = normal_rect(a, 'ICONPANE3')
check('restored pane keeps saved rectangle',
      before3 is not None and after3 == before3 and
      normal_rect(b, 'ICONPANE3') == before3)
icons_ok, icon_detail = wait_visual_icons({2, 4})
if not icons_ok:
    print('  compact icon rectangles:', icon_detail)
check('remaining icons compact without overlap', icons_ok)

# Repeated high-rate state changes: alternate ordering so every pane occupies
# every icon slot. Assert after every settled batch, not merely at test end.
check('prepare rapid three-icon baseline',
      run_cli(['minimize', f'{SESSION}:3'], HOME,
              env=DEBUG_ENV).returncode == 0 and
      wait_flags({2, 3, 4}, focused=1))
for cycle in range(12):
    target = 2 + (cycle % 3)
    result = run_cli(['restore', f'{SESSION}:{target}'], HOME, env=DEBUG_ENV)
    check(f'rapid restore {cycle}', result.returncode == 0)
    expected = {2, 3, 4} - {target}
    check(f'rapid restore state {cycle}', wait_flags(expected))
    result = run_cli(['minimize', f'{SESSION}:{target}'], HOME, env=DEBUG_ENV)
    check(f'rapid minimize {cycle}', result.returncode == 0)
    check(f'rapid minimize state {cycle}', wait_flags({2, 3, 4}))
    icons_ok, _ = wait_visual_icons({2, 3, 4})
    check(f'rapid icons unique {cycle}', icons_ok)

# All panes may be icons, but then there is deliberately no focused pane.
check('minimize last visible pane',
      run_cli(['minimize', f'{SESSION}:1'], HOME,
              env=DEBUG_ENV).returncode == 0)
check('all minimized means no focus', wait_flags({1, 2, 3, 4}))
rc, final_state = state()
check('no focused minimized flag',
      rc == 0 and all('*M' not in flags and 'M*' not in flags
                      for flags in final_state.values()))
icons_ok, _ = wait_visual_icons({1, 2, 3, 4})
check('four icons unique and shared', icons_ok)

# CLI focus intentionally restores an icon, then focuses it atomically.
check('focus restores pane 2',
      run_cli(['focus', f'{SESSION}:2'], HOME,
              env=DEBUG_ENV).returncode == 0)
check('restored focus is visible', wait_flags({1, 3, 4}, focused=2))

for client in (b, a):
    client.send(b'\x11', 0.10)
    client.send(b'd', 0.35)
    client.wait_exit(timeout=5.0)
    client.close()
stlib.close_all_daemons(HOME)
stlib.report()
