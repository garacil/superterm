#!/usr/bin/env python3
"""Stress one shared focus/layout/fullscreen state across detach and attach."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('shared-state-stress')
with open(HOME + '/.superterm/superterm.ini', 'w') as fh:
    fh.write('[ui]\nlanguage=en\nbackground=none\n'
             '[session]\nserver=always\nautosave=0\nautorestore=0\n'
             'zoomanim=0\n')

TITLE1 = 'STATEPANE1'
TITLE2 = 'STATEPANE2'
TITLES = (TITLE1, TITLE2)


def detach(client, label):
    client.send(b'\x11', 0.2)
    client.send(b'd', 0.8)
    status = client.wait_exit(timeout=6.0)
    check(f'{label} detach exits cleanly', status == 0)
    client.close()


def drain_all(clients, seconds=0.4):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.025)


def wait_presentation(clients, predicate, timeout=4.0, stable_for=0.12):
    """Wait for every PTY renderer to present one stable canonical state."""
    deadline = time.monotonic() + timeout
    stable_since = None
    while time.monotonic() < deadline:
        drain_all(clients, 0.06)
        now = time.monotonic()
        if predicate():
            if stable_since is None:
                stable_since = now
            elif now - stable_since >= stable_for:
                return True
        else:
            stable_since = None
        time.sleep(0.025)
    return False


def control(args, label):
    result = run_cli(args, HOME)
    if result.returncode != 0:
        print('  control failure:', ' '.join(args),
              repr((result.stdout + result.stderr).strip()))
    check(label, result.returncode == 0)
    return result


def daemon_state(session):
    result = run_cli(['list', session], HOME, env={'LANG': 'C'})
    focused = None
    minimized = set()
    zoomed = set()
    panes = set()
    for line in result.stdout.splitlines():
        fields = line.split()
        if not fields or not fields[0].isdigit():
            continue
        pane = int(fields[0])
        panes.add(pane)
        flags = fields[-1] if set(fields[-1]) <= set('*MZ!') else ''
        if '*' in flags:
            focused = pane
        if 'M' in flags:
            minimized.add(pane)
        if 'Z' in flags:
            zoomed.add(pane)
    return result.returncode, focused, minimized, zoomed, panes


def wait_state(clients, session, focused, minimized=(), zoomed=(),
               timeout=4.0):
    expected = (0, focused, set(minimized), set(zoomed), {1, 2})
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        drain_all(clients, 0.06)
        last = daemon_state(session)
        if last == expected:
            return True
        time.sleep(0.025)
    print('  last daemon state:', last, 'expected:', expected)
    return False


FRAME = set('╔╗╚╝═║┌┐└┘─│')


def geometry(client):
    """Frame coordinates, normalizing active/inactive drawing style."""
    return {(y, x) for y, row in enumerate(client.screen.display)
            for x, ch in enumerate(row) if ch in FRAME}


def frame_rect(client, title):
    """Return a normal (at least three-row) frame containing title."""
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


def frame_origin(client, title):
    """Return a titled frame's top-left even when cascade obscures its tail."""
    for top, row in enumerate(client.screen.display):
        title_x = row.find(title)
        if title_x < 0:
            continue
        lefts = [x for x, ch in enumerate(row[:title_x])
                 if ch in ('╔', '┌')]
        if lefts:
            return max(lefts), top
    return None


def icon_rect(client, title):
    """Return the exact two-row minimized icon containing title."""
    rows = client.screen.display
    for top in range(len(rows) - 1):
        title_x = rows[top].find(title)
        if title_x < 0:
            continue
        lefts = [x for x, ch in enumerate(rows[top][:title_x]) if ch == '┌']
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
    return rect is not None and client.screen.display[rect[1]][rect[0]] == '╔'


def pane_contains(client, title, token):
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


a = stlib.Client(HOME, w=100, h=30, lang='en')
a.drain(2.5)
a.send(b'\x1bOQ', 1.5)          # F2: second pane
sockets = stlib.session_sockets(HOME)
check('session server exists', len(sockets) == 1)
session = os.path.basename(sockets[0])[:-5] if sockets else ''
initial = control(['list', session], 'initial pane list succeeds')
initial_panes = [line for line in initial.stdout.splitlines()
                 if line and line[0].isdigit()]
check('F2 materially creates second pane', len(initial_panes) == 2)
for pane, title in enumerate(TITLES, 1):
    control(['rename', f'{session}:{pane}', title],
            f'pane {pane} rename succeeds')
control(['organize', session, 'grid'], 'initial grid succeeds')
a.drain(1.0)

b = stlib.Client(HOME, args=['--attach', session],
                 w=100, h=30, lang='en')
b.drain(3.0)
check('second viewer attaches', b.alive())
clients = (a, b)
drain_all(clients, 0.6)
baseline = tuple(frame_rect(a, title) for title in TITLES)
check('both normal panes are visible', all(rect is not None
                                           for rect in baseline))
check('attach receives exact initial layout',
      baseline == tuple(frame_rect(b, title) for title in TITLES) and
      geometry(a) == geometry(b))
check('initial daemon state is explicit',
      wait_state(clients, session, focused=2))

# Focus changes originate in two different clients.  Check each intermediate
# daemon flag and both actual active frames; merely checking the last click
# would let a dropped first focus event pass.
pane1_rect = frame_rect(a, TITLE1)
if pane1_rect is not None:
    click(a, pane1_rect[0] + 2, pane1_rect[1] + 2)
check('first client focus reaches daemon',
      wait_state(clients, session, focused=1))
first_focus_presented = wait_presentation(clients, lambda: (
    active_frame(a, TITLE1) and active_frame(b, TITLE1) and
    not active_frame(a, TITLE2) and not active_frame(b, TITLE2)))
check('first focus is rendered by both clients',
      first_focus_presented and
      active_frame(a, TITLE1) and active_frame(b, TITLE1) and
      not active_frame(a, TITLE2) and not active_frame(b, TITLE2))

pane2_rect = frame_rect(b, TITLE2)
if pane2_rect is not None:
    click(b, pane2_rect[0] + 2, pane2_rect[1] + 2)
check('second client focus reaches daemon',
      wait_state(clients, session, focused=2))
second_focus_presented = wait_presentation(clients, lambda: (
    active_frame(a, TITLE2) and active_frame(b, TITLE2) and
    not active_frame(a, TITLE1) and not active_frame(b, TITLE1)))
check('second focus is rendered by both clients',
      second_focus_presented and
      active_frame(a, TITLE2) and active_frame(b, TITLE2) and
      not active_frame(a, TITLE1) and not active_frame(b, TITLE1))

# Fullscreen is shared too. Equal-size viewers all receive the same raw PTY
# stream; client count alone must not downgrade them to the cell renderer.
# After both detach, the next sole viewer receives that live flag unchanged.
before_fullscreen = frame_rect(a, TITLE2)
b.send(stlib.FULLSCREEN_CHORD, 2.0)
drain_all(clients, 0.8)
after_fullscreen_a = frame_rect(a, TITLE2)
after_fullscreen_b = frame_rect(b, TITLE2)
check('shared fullscreen hands both equal hosts to the pane',
      before_fullscreen is not None and
      after_fullscreen_a is None and after_fullscreen_b is None and
      'Detach' not in a.text() and 'Detach' not in b.text())
check('shared raw fullscreen keeps both clients live', a.alive() and b.alive())
check('fullscreen preserves focused pane and ordinary flags',
      wait_state(clients, session, focused=2, zoomed={2}))
detach(a, 'creator')
detach(b, 'second viewer')

c = stlib.Client(HOME, args=['--attach', session],
                 w=100, h=30, lang='en')
c.drain(3.0)
check('sole reattach receives live fullscreen passthrough',
      c.alive() and 'Detach' not in c.text())
check('fullscreen reattach retains daemon focus',
      wait_state((c,), session, focused=2, zoomed={2}))
c.send(stlib.FULLSCREEN_CHORD, 1.5)  # leave fullscreen, keep session alive
check('fullscreen exit restores exact saved rectangle',
      'Detach' in c.text() and frame_rect(c, TITLE2) == before_fullscreen)
check('fullscreen exit retains explicit state',
      wait_state((c,), session, focused=2))

# Exercise many serialized mutations while two clients watch the same state.
d = stlib.Client(HOME, args=['--attach', session],
                 w=100, h=30, lang='en')
d.drain(2.5)
clients = (c, d)
drain_all(clients, 0.5)
check('stress observer receives exact current layout',
      all(frame_rect(c, title) == frame_rect(d, title)
          for title in TITLES))
modes = ('tile', 'cascade', 'grid')
mode_layouts = {}
for turn in range(9):
    pane = turn % 2 + 1
    other = 3 - pane
    mode = modes[turn % len(modes)]
    control(['focus', f'{session}:{pane}'],
            f'round {turn} focus command succeeds')
    check(f'round {turn} focus transition settles',
          wait_state(clients, session, focused=pane))
    before_organize = tuple(frame_origin(c, title) for title in TITLES)
    control(['organize', session, mode],
            f'round {turn} {mode} command succeeds')
    check(f'round {turn} {mode} clears transient flags',
          wait_state(clients, session, focused=pane))
    mode_key = (mode, pane)
    known_layout = mode_layouts.get(mode_key)

    def organized_presentation():
        current = tuple(frame_origin(c, title) for title in TITLES)
        visible = (any(origin is not None for origin in current)
                   if mode == 'cascade'
                   else all(origin is not None for origin in current))
        return (visible and
                current == tuple(frame_origin(d, title) for title in TITLES) and
                geometry(c) == geometry(d) and
                (mode != 'cascade' or current != before_organize) and
                (known_layout is None or current == known_layout))

    organize_presented = wait_presentation(clients, organized_presentation)
    layout = tuple(frame_origin(c, title) for title in TITLES)
    # Cascade is allowed to obscure a background title completely; tile/grid
    # are not.  The daemon-state oracle above still proves that both panes
    # exist, while the shared geometry signature proves both viewers received
    # the same overlapping presentation.
    visible_origins_ok = (any(origin is not None for origin in layout)
                          if mode == 'cascade'
                          else all(origin is not None for origin in layout))
    check(f'round {turn} {mode} has valid material frame origins',
          visible_origins_ok)
    check(f'round {turn} {mode} reaches both clients',
          organize_presented and
          layout == tuple(frame_origin(d, title) for title in TITLES) and
          geometry(c) == geometry(d))
    if mode_key in mode_layouts:
        check(f'round {turn} {mode} is deterministic',
              layout == mode_layouts[mode_key])
    else:
        mode_layouts[mode_key] = layout
    if mode == 'cascade':
        check(f'round {turn} {mode} material transition occurs',
              layout != before_organize)

    if turn % 3 == 1:
        # Minimized icons must be measured from a non-overlapping workspace;
        # a perfectly valid cascade can cover the lower icon with its front
        # window and make a visual assertion impossible.
        control(['organize', session, 'grid'],
                f'round {turn} pre-minimize grid succeeds')
        check(f'round {turn} pre-minimize grid settles',
              wait_state(clients, session, focused=pane))
        grid_presented = wait_presentation(clients, lambda: (
            all(frame_rect(c, title) is not None for title in TITLES) and
            tuple(frame_rect(c, title) for title in TITLES) ==
            tuple(frame_rect(d, title) for title in TITLES) and
            geometry(c) == geometry(d)))
        check(f'round {turn} pre-minimize grid is presented',
              grid_presented)
        before_minimize = frame_rect(c, TITLES[other - 1])
        control(['minimize', f'{session}:{other}'],
                f'round {turn} minimize command succeeds')
        check(f'round {turn} minimize flag settles',
              wait_state(clients, session, focused=pane,
                         minimized={other}))
        minimize_presented = wait_presentation(clients, lambda: (
            frame_rect(c, TITLES[other - 1]) is None and
            frame_rect(d, TITLES[other - 1]) is None and
            icon_rect(c, TITLES[other - 1]) is not None and
            icon_rect(c, TITLES[other - 1]) ==
            icon_rect(d, TITLES[other - 1])))
        check(f'round {turn} minimized icon is material and shared',
              minimize_presented and before_minimize is not None and
              frame_rect(c, TITLES[other - 1]) is None and
              frame_rect(d, TITLES[other - 1]) is None and
              icon_rect(c, TITLES[other - 1]) is not None and
              icon_rect(c, TITLES[other - 1]) ==
              icon_rect(d, TITLES[other - 1]))
        control(['restore', f'{session}:{other}'],
                f'round {turn} restore minimized command succeeds')
        check(f'round {turn} restore minimized flag settles',
              wait_state(clients, session, focused=pane))
        restore_presented = wait_presentation(clients, lambda: (
            frame_rect(c, TITLES[other - 1]) == before_minimize and
            frame_rect(d, TITLES[other - 1]) == before_minimize and
            icon_rect(c, TITLES[other - 1]) is None and
            icon_rect(d, TITLES[other - 1]) is None))
        check(f'round {turn} restore returns exact material frame',
              restore_presented and
              frame_rect(c, TITLES[other - 1]) == before_minimize and
              frame_rect(d, TITLES[other - 1]) == before_minimize and
              icon_rect(c, TITLES[other - 1]) is None and
              icon_rect(d, TITLES[other - 1]) is None)
    if turn % 3 == 2:
        before_zoom = tuple(frame_rect(c, title) for title in TITLES)
        control(['zoom', f'{session}:{pane}'],
                f'round {turn} zoom command succeeds')
        check(f'round {turn} zoom flag settles',
              wait_state(clients, session, focused=pane, zoomed={pane}))
        zoom_presented = wait_presentation(clients, lambda: (
            frame_rect(c, TITLES[pane - 1]) is not None and
            frame_rect(c, TITLES[pane - 1]) != before_zoom[pane - 1] and
            frame_rect(c, TITLES[pane - 1]) ==
            frame_rect(d, TITLES[pane - 1])))
        zoom_rect = frame_rect(c, TITLES[pane - 1])
        check(f'round {turn} zoom is a shared material transition',
              zoom_presented and zoom_rect is not None and
              zoom_rect != before_zoom[pane - 1] and
              frame_rect(d, TITLES[pane - 1]) == zoom_rect)
        control(['restore', f'{session}:{pane}'],
                f'round {turn} restore zoom command succeeds')
        check(f'round {turn} restore zoom flag settles',
              wait_state(clients, session, focused=pane))
        zoom_restore_presented = wait_presentation(clients, lambda: (
            tuple(frame_rect(c, title) for title in TITLES) == before_zoom and
            tuple(frame_rect(d, title) for title in TITLES) == before_zoom))
        check(f'round {turn} zoom restore returns exact layout',
              zoom_restore_presented and
              tuple(frame_rect(c, title) for title in TITLES) == before_zoom and
              tuple(frame_rect(d, title) for title in TITLES) == before_zoom)
    marker = f'SHARED_CURSOR_{turn}_{pane}'
    command = ("printf '\\033[2J\\033[H" + marker +
               "\\033[10;20HCURSOR_END'; sleep 5")
    control(['send', f'{session}:{pane}', command],
            f'round {turn} send command succeeds')
    drain_all(clients, 0.9)
    captured = control(['capture', f'{session}:{pane}'],
                       f'round {turn} capture succeeds')
    check(f'round {turn} canonical pane content survives',
          marker in captured.stdout)
    check(f'round {turn} pane content is rendered in both clients',
          pane_contains(c, TITLES[pane - 1], marker) and
          pane_contains(d, TITLES[pane - 1], marker))
    check(f'round {turn} active frame remains shared',
          active_frame(c, TITLES[pane - 1]) and
          active_frame(d, TITLES[pane - 1]))
    check(f'round {turn} geometry is identical', geometry(c) == geometry(d))
    # CSI 10;20 H is one-based. Printing ten bytes leaves the terminal cursor
    # at zero-based column 29, so its exact host position is frame left+30,
    # top+10. Bounds alone are guaranteed by pyte and prove nothing.
    rect_c = frame_rect(c, TITLES[pane - 1])
    rect_d = frame_rect(d, TITLES[pane - 1])
    expected_c = None if rect_c is None else (rect_c[0] + 30,
                                               rect_c[1] + 10)
    expected_d = None if rect_d is None else (rect_d[0] + 30,
                                               rect_d[1] + 10)
    check(f'round {turn} exact cursor reaches both clients',
          expected_c is not None and expected_d is not None and
          (c.screen.cursor.x, c.screen.cursor.y) == expected_c and
          (d.screen.cursor.x, d.screen.cursor.y) == expected_d)
    check(f'round {turn} output does not mutate window state',
          wait_state(clients, session, focused=pane))
    control(['send', '-n', f'{session}:{pane}', '-k', 'C-c'],
            f'round {turn} stop cursor fixture succeeds')
    drain_all(clients, 0.2)

# Leave a final state with no viewers. Reattach must reproduce it directly,
# without loading, saving, or fitting it to the new process.
control(['focus', session + ':1'], 'final focus command succeeds')
check('final focus settles', wait_state(clients, session, focused=1))
before_final_cascade = geometry(c)
control(['organize', session, 'cascade'],
        'final cascade command succeeds')
check('final cascade state settles',
      wait_state(clients, session, focused=1))
final_cascade_presented = wait_presentation(clients, lambda: (
    geometry(c) != before_final_cascade and geometry(c) == geometry(d)))
check('final cascade is a material shared transition',
      final_cascade_presented and
      geometry(c) != before_final_cascade and geometry(c) == geometry(d))
last_geometry = geometry(c)
last_rects = tuple(frame_rect(c, title) for title in TITLES)
detach(c, 'stress creator')
detach(d, 'stress observer')

e = stlib.Client(HOME, args=['--attach', session],
                 w=100, h=30, lang='en')
reattach_presented = wait_presentation((e,), lambda: (
    geometry(e) == last_geometry and
    tuple(frame_rect(e, title) for title in TITLES) == last_rects))
check('final geometry survives all detach',
      reattach_presented and geometry(e) == last_geometry and
      tuple(frame_rect(e, title) for title in TITLES) == last_rects)
check('reattach restores explicit final daemon state',
      wait_state((e,), session, focused=1))
e.send(b'echo FINAL_SHARED_FOCUS\r', 1.0)
check('reattached client remains alive after input', e.alive())
cap1 = control(['capture', session + ':1'],
               'final pane 1 capture succeeds')
cap2 = control(['capture', session + ':2'],
               'final pane 2 capture succeeds')
check('final focus survives all detach',
      'FINAL_SHARED_FOCUS' in cap1.stdout and
      'FINAL_SHARED_FOCUS' not in cap2.stdout and
      pane_contains(e, TITLE1, 'FINAL_SHARED_FOCUS'))

detach(e, 'final viewer')
stlib.close_all_daemons(HOME)
stlib.report()
