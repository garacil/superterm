#!/usr/bin/env python3
"""Session load/save preserves the fixed logical desktop dimensions."""
import configparser
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


HOME = stlib.fresh_home('desktop-persistence')
SESSION_INI = HOME + '/.superterm/session.ini'
INITIAL_DESK = (96, 27)
FIT_DESK = (110, 33)  # first client's 110x35 terminal minus menu/status
BOUNDS = (7, 3, 50, 14)

with open(HOME + '/.superterm/superterm.ini', 'w', encoding='utf-8') as stream:
    stream.write('[ui]\nlanguage=en\nbackground=none\n'
                 '[session]\nserver=detach\nautosave=1\nautorestore=1\n')

with open(SESSION_INI, 'w', encoding='utf-8') as stream:
    stream.write(f'''[layout]
nodes=L
count=1
focused=0
deskw={INITIAL_DESK[0]}
deskh={INITIAL_DESK[1]}

[pane0]
cmd=
cwd={HOME}
term=
argc=0
bx={BOUNDS[0]}
by={BOUNDS[1]}
bw={BOUNDS[2]}
bh={BOUNDS[3]}
''')


def saved_state():
    parser = configparser.ConfigParser(interpolation=None)
    try:
        parser.read(SESSION_INI)
        desk = (parser.getint('layout', 'deskw'),
                parser.getint('layout', 'deskh'))
        bounds = tuple(parser.getint('pane0', key)
                       for key in ('bx', 'by', 'bw', 'bh'))
        return desk, bounds
    except (configparser.Error, OSError, ValueError):
        return None


def wait_saved(expected, timeout=6.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if saved_state() == expected:
            return True
        time.sleep(0.02)
    return saved_state() == expected


def show_desktop(client, expected):
    client.send(b'\x1bd', 0.0)
    opened = client.wait_until(
        lambda text: 'Show current dimensions' in text, 5.0)
    if opened:
        client.send(b's', 0.0)
    shown = client.wait_until(
        lambda text: f'Logical desktop: {expected[0]}x{expected[1]}' in text,
        5.0)
    if shown:
        client.send(b'\r', 0.0)
        client.wait_until(lambda text: 'Logical desktop:' not in text, 5.0)
    return opened and shown


def exact_saved_frame(client):
    """The saved exclusive BW/BH rectangle, below the physical menu row."""
    left, local_top, width, height = BOUNDS
    top = local_top + 1
    right = left + width - 1
    bottom = top + height - 1
    rows = client.screen.display
    if bottom >= len(rows) or right >= len(rows[top]):
        return False
    return (rows[top][left] in ('╔', '┌') and
            rows[top][right] in ('╗', '┐') and
            rows[bottom][left] in ('╚', '└') and
            rows[bottom][right] in ('╝', '┘'))


def fit_to_terminal(client):
    client.send(b'\x1bd', 0.0)
    opened = client.wait_until(
        lambda text: 'Adjust to this terminal size' in text, 5.0)
    if opened:
        client.send(b'a', 0.0)
    return opened and client.wait_until(
        lambda _text: exact_saved_frame(client), 6.0)


def desktop_bars(client):
    rows = client.screen.display
    return (len(rows) >= client.h and client.w >= 3 and client.h >= 5 and
            rows[client.h - 2][0] in ('◄', '<') and
            rows[client.h - 2][client.w - 2] in ('►', '>') and
            rows[1][client.w - 1] in ('▲', '^') and
            rows[client.h - 3][client.w - 1] in ('▼', 'V'))


def click(client, x, y):
    stlib.write_all(
        client.fd,
        f'\x1b[<0;{x + 1};{y + 1}M\x1b[<0;{x + 1};{y + 1}m'.encode())


def oversized_dialog_anchored(client):
    """Scroll both axes, then open a dialog larger than the viewport."""
    client.resize(40, 12, seconds=0.0)
    bars_ready = client.wait_until(lambda _text: desktop_bars(client), 5.0)
    if not bars_ready:
        return False, False
    before_h = client.screen.display[client.h - 2]
    before_v = ''.join(row[client.w - 1]
                       for row in client.screen.display)
    # Page-right/down cells, immediately before each arrow. This establishes
    # non-zero viewport offsets without relying on a fixed processing delay.
    click(client, client.w - 3, client.h - 2)
    click(client, client.w - 1, client.h - 4)
    scrolled = client.wait_until(
        lambda _text: (
            client.screen.display[client.h - 2] != before_h and
            ''.join(row[client.w - 1]
                    for row in client.screen.display) != before_v),
        5.0)
    if not scrolled:
        return True, False
    client.send(b'\x1bh', 0.0)
    menu = client.wait_until(lambda text: 'About...' in text, 4.0)
    if menu:
        client.send(b'b', 0.0)
    opened = client.wait_until(
        lambda _text: any('About' in row
                          for row in client.screen.display[1:]), 4.0)
    anchored = False
    if opened:
        title_row = next(
            (y for y, row in enumerate(client.screen.display)
             if 'About' in row), -1)
        anchored = (title_row == 1 and
                    client.screen.display[title_row][0] in ('╔', '┌'))
        client.send(b'\x1b', 0.0)
    return True, anchored


first = stlib.Client(HOME, w=110, h=35, lang='en')
second = None
try:
    # Saved desktop-local Y=3 appears at physical row 4 below the menu.
    restored = first.wait_until(
        lambda _text: first.screen.display[BOUNDS[1] + 1][BOUNDS[0]] == '╔',
        8.0)
    check('session loads saved window bounds', restored)
    check('session loads saved DeskW/H', show_desktop(first, INITIAL_DESK))

    # This is deliberately the classic local `server=detach` path. Before the
    # GrowMode guard, changing the logical desktop made FreeVision scale the
    # normal window (and its PTY) proportionally. The explicit fit command may
    # change only the desktop; the saved normal rectangle stays byte-for-byte.
    check('local explicit fit preserves exact normal window',
          fit_to_terminal(first) and exact_saved_frame(first))
    check('local explicit fit publishes exact DeskW/H',
          show_desktop(first, FIT_DESK))

    # Remove only this fixture-owned source after it is loaded. A later exact
    # INI proves the local-mode Exit autosave serialized live state instead of
    # re-reading our seed.
    os.unlink(SESSION_INI)
    first.send(b'\x1bx', 0.0)
    exit_status = first.wait_exit(timeout=8.0)
    check('autosaving session exit completes', exit_status == 0)
    check('session save preserves DeskW/H and bounds',
          wait_saved((FIT_DESK, BOUNDS)))
    first.close()

    # A new process with a different physical viewport must reload the same
    # logical values; host geometry is never substituted during restore.
    second = stlib.Client(HOME, w=104, h=32, lang='en')
    check('restart reloads exact DeskW/H', show_desktop(second, FIT_DESK))
    check('smaller restart owns local viewport bars',
          second.wait_until(lambda _text: desktop_bars(second), 5.0))
    check('restart retains saved INI values',
          saved_state() == (FIT_DESK, BOUNDS))
    scrolled, anchored = oversized_dialog_anchored(second)
    check('small viewport can scroll both local axes', scrolled)
    check('oversized dialog anchors its visible upper-left corner', anchored)
finally:
    if second is not None:
        second.close()
    first.close()
    stlib.close_all_daemons(HOME)


# A pre-fixed-desktop session has no deskw/deskh. Its accessible window must
# stay byte-exact, while an entirely unreachable title is translated just far
# enough onto the startup terminal. Width and height are never scaled.
LEGACY_HOME = stlib.fresh_home('desktop-persistence-legacy')
LEGACY_INI = LEGACY_HOME + '/.superterm/session.ini'
LEGACY_VISIBLE = (7, 3, 30, 10)
LEGACY_HIDDEN = (200, 100, 30, 10)
LEGACY_REPAIRED = (74, 27, 30, 10)  # 80x28 desktop; safe title cell at 79
with open(LEGACY_HOME + '/.superterm/superterm.ini', 'w',
          encoding='utf-8') as stream:
    stream.write('[ui]\nlanguage=en\nbackground=none\n'
                 '[session]\nserver=detach\nautosave=1\nautorestore=1\n')
with open(LEGACY_INI, 'w', encoding='utf-8') as stream:
    stream.write(f'''[layout]
nodes=V:500;L;L
count=2
focused=0

[pane0]
cmd=
cwd={LEGACY_HOME}
term=
title=LEGACYVISIBLE
argc=0
bx={LEGACY_VISIBLE[0]}
by={LEGACY_VISIBLE[1]}
bw={LEGACY_VISIBLE[2]}
bh={LEGACY_VISIBLE[3]}

[pane1]
cmd=
cwd={LEGACY_HOME}
term=
title=LEGACYHIDDEN
argc=0
bx={LEGACY_HIDDEN[0]}
by={LEGACY_HIDDEN[1]}
bw={LEGACY_HIDDEN[2]}
bh={LEGACY_HIDDEN[3]}
''')

legacy = stlib.Client(LEGACY_HOME, w=80, h=30, lang='en')
try:
    legacy_ready = legacy.wait_until(
        lambda _text: (
            legacy.screen.display[LEGACY_VISIBLE[1] + 1]
                                 [LEGACY_VISIBLE[0]] in ('╔', '┌') and
            legacy.screen.display[LEGACY_REPAIRED[1] + 1]
                                 [LEGACY_REPAIRED[0]] in ('╔', '┌')),
        8.0)
    check('legacy session preserves accessible saved position', legacy_ready)
    legacy.send(b'\x1bx', 0.0)  # autosave serializes the restored live bounds
    saved_ok = legacy.wait_exit(timeout=8.0) == 0
    parser = configparser.ConfigParser(interpolation=None)
    parser.read(LEGACY_INI)
    visible_saved = tuple(parser.getint('pane0', key)
                          for key in ('bx', 'by', 'bw', 'bh'))
    hidden_saved = tuple(parser.getint('pane1', key)
                         for key in ('bx', 'by', 'bw', 'bh'))
    check('legacy accessible bounds remain exact',
          saved_ok and visible_saved == LEGACY_VISIBLE)
    check('legacy unreachable title is minimally exposed without scaling',
          saved_ok and hidden_saved == LEGACY_REPAIRED)
finally:
    if legacy.alive():
        legacy.send(b'\x1bx', 0.0)
        legacy.wait_exit(timeout=5.0)
    legacy.close()
    stlib.close_all_daemons(LEGACY_HOME)

stlib.report()
