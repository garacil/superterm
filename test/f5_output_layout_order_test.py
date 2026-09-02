#!/usr/bin/env python3
"""Fullscreen output/layout ordering with two equal 100x30 viewers.

The optional fullscreen animation gives this test a deterministic ordering barrier.
The actor does not poll its session socket during the eight animation steps,
while the daemon and the observer continue to run.  A helper in the pane emits
numbered cursor-positioned/wrapping bursts during that interval. On entry the
animation precedes the proposal; on a correct exit it follows the ACK. The
same timing therefore proves which side of the authoritative layout parsed
each output frame without relying on a scheduler-sized sleep.

This is specifically an oracle against optimistic client-side fullscreen
resizes.  On entry, output produced for the old 96x25 PTY must be interpreted
as rendered output by both mirrors before raw passthrough begins.  On exit,
the corrected client proposes immediately and waits for the authoritative
96x25 layout before changing locally; the delayed helper output is therefore
rendered at 96x25 by both viewers.  The old client resized itself first and
spent the helper's delay animating before sending its proposal, so the actor
parsed those bytes at 96x25 while the daemon/observer still used 100x30.
OSC 777 is consumed by the renderer but survives byte-for-byte in passthrough,
so it proves which path each client actually used; looking only for a hidden
menu would not.

The daemon text capture and serialized TScreen cursor are checked against
precomputed wrap positions, then both restored FreeVision pane interiors and
both physical cursors are compared with that canonical state.
"""
import os
import re
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import (CAPTURE_VISIBLE, FRAME_ATTACH, FRAME_CTL_CAPTURE,
                   FRAME_CTL_DATA, FRAME_CTL_END, FRAME_DETACH, FRAME_READY,
                   FRAME_SCREEN, check, raw_frame, read_frame, run_cli)

WIDTH = 100
HEIGHT = 30
TITLE = 'F5ORDER'
ENTRY_OSC = b'\x1b]777;F5_ORDER_ENTRY_07\x07'
RAW_OSC = b'\x1b]777;F5_ORDER_STABLE_RAW\x07'
EXIT_OSC = b'\x1b]777;F5_ORDER_EXIT_07\x07'


PROTO_VER = stlib.attach_proto_ver()
HOME = stlib.fresh_home('f5-output-layout-order')
os.makedirs(HOME + '/.superterm', exist_ok=True)
with open(HOME + '/.superterm/superterm.ini', 'w') as stream:
    stream.write('[ui]\nlanguage=en\nbackground=none\n'
                 '[session]\nserver=always\nautosave=0\nautorestore=0\n'
                 'multithread=2\nzoomanim=1\n')

# The foreground helper reads one raw trigger per phase. Eight bursts at
# 25 ms intervals fit inside the 8*45 ms animation whether that animation is
# correctly after the exit ACK or incorrectly before the old proposal. Every
# burst clears the pane, making number 07 the deterministic final state.
HELPER = HOME + '/f5_order_helper.py'
with open(HELPER, 'w', encoding='ascii') as stream:
    stream.write(r'''import os
import time

def burst(kind, row, col):
    for number in range(8):
        time.sleep(0.025)
        token = ((kind + f'{number:02d}A|' +
                  kind + f'{number:02d}B|' +
                  kind + f'{number:02d}C|' +
                  kind + f'{number:02d}D|').encode('ascii'))
        osc = (b'\x1b]777;F5_ORDER_' +
               (b'ENTRY_' if kind == 'E' else b'EXIT_') +
               f'{number:02d}'.encode('ascii') + b'\x07')
        position = f'\x1b[{row};{col}H'.encode('ascii')
        os.write(1, osc + b'\x1b[2J\x1b[H' + position + token)

os.write(1, b'\x1b[2J\x1b[HF5_ORDER_READY')
os.read(0, 1)
burst('E', 24, 93)
os.read(0, 1)
os.write(1, b'\x1b]777;F5_ORDER_STABLE_RAW\x07'
            b'\x1b[1;1HRAW_STABLE_VISIBLE')
os.read(0, 1)
burst('X', 25, 95)
os.read(0, 1)
''')


def drain_all(clients, seconds=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.025)


def one_session_socket():
    sockets = stlib.session_sockets(HOME)
    check('one session exists', len(sockets) == 1)
    return sockets[0] if len(sockets) == 1 else ''


def pane_size(session):
    result = run_cli(['list', session], HOME, env={'LANG': 'C'})
    if result.returncode != 0:
        return None
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


def wait_state(clients, session, size, raw, timeout=6.0):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        last = (pane_size(session),
                tuple('Detach' in client.text() for client in clients))
        if last[0] == size and all(value != raw for value in last[1]):
            return True
        time.sleep(0.02)
    print('  last fullscreen state:', last, 'expected size/raw:', size, raw)
    return False


def frame_rect(client):
    """Inclusive rectangle of the complete frame carrying TITLE."""
    rows = client.screen.display
    for top, row in enumerate(rows):
        title_x = row.find(TITLE)
        if title_x < 0:
            continue
        lefts = [x for x, char in enumerate(row[:title_x])
                 if char in ('\u2554', '\u250c')]
        rights = [x for x, char in enumerate(
            row[title_x + len(TITLE):], title_x + len(TITLE))
            if char in ('\u2557', '\u2510')]
        if not lefts or not rights:
            continue
        left, right = max(lefts), min(rights)
        for bottom in range(top + 2, len(rows)):
            if (rows[bottom][left] in ('\u255a', '\u2514') and
                    rows[bottom][right] in ('\u255d', '\u2518')):
                return left, top, right, bottom
    return None


def rendered_pane_rows(client):
    rectangle = frame_rect(client)
    if rectangle is None:
        return None
    left, top, right, bottom = rectangle
    return [client.screen.display[row][left + 1:right].rstrip()
            for row in range(top + 1, bottom)]


def capture_rows(path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(8.0)
    frames = []
    try:
        sock.connect(path)
        sock.sendall(raw_frame(
            FRAME_CTL_CAPTURE, 0,
            struct.pack('<ii', CAPTURE_VISIBLE, 0)))
        while True:
            frame = read_frame(sock, timeout=8.0)
            if frame is None:
                break
            frames.append(frame)
            if frame[0] == FRAME_CTL_END:
                break
    finally:
        sock.close()
    complete = bool(frames) and frames[-1][0] == FRAME_CTL_END
    data = b''.join(payload for kind, _pane, payload in frames
                    if kind == FRAME_CTL_DATA)
    rows = data.decode('utf-8', 'replace').split('\n')
    if rows and rows[-1] == '':
        rows.pop()
    return complete, rows


def daemon_screen_head(path):
    """Attach read-only long enough to obtain TScreen's first four fields."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(8.0)
    screen_head = None
    try:
        sock.connect(path)
        payload = struct.pack('<iiiii', PROTO_VER, WIDTH, HEIGHT, 0, 0)
        sock.sendall(raw_frame(FRAME_ATTACH, -1, payload))
        while True:
            frame = read_frame(sock, timeout=8.0)
            if frame is None:
                break
            kind, pane, data = frame
            if kind == FRAME_SCREEN and pane == 0 and len(data) >= 16:
                screen_head = struct.unpack_from('<iiii', data)
            if kind == FRAME_READY:
                break
        sock.sendall(raw_frame(FRAME_DETACH, -1))
    finally:
        sock.close()
    return screen_head


actor = stlib.Client(HOME, w=WIDTH, h=HEIGHT, lang='en')
observer = None
try:
    actor.drain(2.5)
    path = one_session_socket()
    session = os.path.basename(path)[:-5] if path else ''
    renamed = run_cli(['rename', session + ':1', TITLE], HOME)
    check('pane rename succeeds', renamed.returncode == 0)

    observer = stlib.Client(HOME, args=['--attach', session],
                            w=WIDTH, h=HEIGHT, lang='en')
    clients = (actor, observer)
    drain_all(clients, 2.0)
    check('equal-size observer attaches', observer.alive())
    check('initial pane is windowed 96x25', pane_size(session) == (96, 25))

    command = f'stty raw -echo; exec python3 -u {HELPER}\r'.encode('ascii')
    stlib.write_all(actor.fd, command)
    deadline = time.monotonic() + 6.0
    ready = False
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        complete, rows = capture_rows(path)
        if complete and any('F5_ORDER_READY' in row for row in rows):
            ready = True
            break
    check('raw ordering helper is ready', ready)

    # ENTRY: the pane is still 96 columns while the expansion animation runs.
    # The actor must not resize its mirror or enter raw before these already-
    # ordered output frames have been consumed.
    entry_offsets = {client: len(client.raw()) for client in clients}
    stlib.write_all(actor.fd, b'E')
    stlib.write_all(actor.fd, stlib.FULLSCREEN_CHORD)
    check('entry reaches shared raw 100x30',
          wait_state(clients, session, (100, 30), raw=True))
    entry_chunks = {client: client.raw()[entry_offsets[client]:]
                    for client in clients}
    complete, entry_rows = capture_rows(path)
    check('entry daemon capture completes', complete and len(entry_rows) == 30)
    check('entry burst really precedes layout',
          len(entry_rows) == 30 and
          entry_rows[23] == ' ' * 92 + 'E07A' and
          entry_rows[24] == '|E07B|E07C|E07D|')
    entry_raw_paths = tuple(ENTRY_OSC in entry_chunks[client]
                            for client in clients)
    if entry_raw_paths != (False, False):
        print('  entry OSC raw paths (actor, observer):', entry_raw_paths)
    check('pre-layout entry output is rendered by both',
          entry_raw_paths == (False, False))

    # Once the canonical layout is fullscreen, the same OSC must be preserved
    # byte-for-byte in both equal-sized passthrough viewers.
    raw_offsets = {client: len(client.raw()) for client in clients}
    stlib.write_all(actor.fd, b'R')
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        if all(RAW_OSC in client.raw()[raw_offsets[client]:]
               for client in clients):
            break
    raw_chunks = {client: client.raw()[raw_offsets[client]:]
                  for client in clients}
    check('settled fullscreen OSC is raw in both',
          all(RAW_OSC in raw_chunks[client] for client in clients))
    check('settled fullscreen bytes reach both',
          all(b'RAW_STABLE_VISIBLE' in raw_chunks[client]
              for client in clients))

    # EXIT: the proposal/ACK precedes the helper's first delayed burst. Both
    # clients must leave raw together and parse every burst at the daemon's
    # restored 96x25 size. The former optimistic client instead resized only
    # the actor, animated for 360 ms, and sent the proposal afterwards; this
    # same delayed burst then split actor and observer across different paths.
    exit_offsets = {client: len(client.raw()) for client in clients}
    stlib.write_all(actor.fd, b'X')
    stlib.write_all(actor.fd, stlib.FULLSCREEN_CHORD)
    check('exit restores shared IDE 96x25',
          wait_state(clients, session, (96, 25), raw=False))

    # wait_state intentionally returns as soon as geometry settles. Do not
    # sample a lucky intermediate burst: require the deterministic final 07.
    expected_last = '7A|X07B|X07C|X07D|'
    deadline = time.monotonic() + 5.0
    complete, final_rows = False, []
    while time.monotonic() < deadline:
        drain_all(clients, 0.05)
        complete, final_rows = capture_rows(path)
        if (complete and len(final_rows) == 25 and
                final_rows[24] == expected_last):
            break
        time.sleep(0.02)
    check('final daemon capture completes',
          complete and len(final_rows) == 25)
    # At 96 columns, row 25 column 95 has room for two bytes. Wrapping at the
    # bottom scrolls those two bytes to row 24 and leaves the remaining 18 on
    # row 25. This differs deliberately from output parsed at 100 then shrunk.
    check('exit burst is parsed after restore layout',
          len(final_rows) == 25 and
          final_rows[23] == ' ' * 94 + 'X0' and
          final_rows[24] == expected_last)

    # The serialized header is Width, Height, CursorX, CursorY.  It supplies a
    # cursor oracle that text capture alone cannot provide.
    screen_head = daemon_screen_head(path)
    check('daemon screen/cursor is exact',
          screen_head == (96, 25, 18, 24))

    # The daemon capture can settle before a Darwin PTY has delivered the
    # corresponding renderer transaction to both viewer models.  Wait for the
    # actual windowed state, not for a scheduler-sized delay.  This retains the
    # strict physical cursor oracle: a viewer which never applies the final
    # cursor movement still times out and fails below.
    deadline = time.monotonic() + 6.0
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        actor_frame = frame_rect(actor)
        observer_frame = frame_rect(observer)
        actor_cursor = None if actor_frame is None else (
            actor_frame[0] + 1 + 18, actor_frame[1] + 1 + 24)
        observer_cursor = None if observer_frame is None else (
            observer_frame[0] + 1 + 18, observer_frame[1] + 1 + 24)
        if (rendered_pane_rows(actor) == final_rows and
                rendered_pane_rows(observer) == final_rows and
                (actor.screen.cursor.x, actor.screen.cursor.y) == actor_cursor and
                (observer.screen.cursor.x,
                 observer.screen.cursor.y) == observer_cursor):
            break

    actor_rows = rendered_pane_rows(actor)
    observer_rows = rendered_pane_rows(observer)
    if actor_rows != final_rows:
        print('  actor final rows 24/25:',
              None if actor_rows is None else actor_rows[23:25])
        print('  daemon final rows 24/25:', final_rows[23:25])
    check('actor mirror/render equals daemon capture',
          actor_rows is not None and actor_rows == final_rows)
    check('observer mirror/render equals daemon capture',
          observer_rows is not None and observer_rows == final_rows)

    # Only now has the helper's deterministic 07 burst demonstrably reached
    # the daemon and both windowed mirrors.  Testing raw absence immediately
    # after the layout ACK was vacuous: the first burst might not exist yet.
    exit_chunks = {client: client.raw()[exit_offsets[client]:]
                   for client in clients}
    exit_raw_paths = tuple(EXIT_OSC in exit_chunks[client]
                           for client in clients)
    if exit_raw_paths != (False, False):
        print('  exit OSC raw paths (actor, observer):', exit_raw_paths)
    check('post-ACK exit output is rendered by both',
          exit_raw_paths == (False, False))

    actor_frame = frame_rect(actor)
    observer_frame = frame_rect(observer)
    actor_cursor = None if actor_frame is None else (
        actor_frame[0] + 1 + 18, actor_frame[1] + 1 + 24)
    observer_cursor = None if observer_frame is None else (
        observer_frame[0] + 1 + 18, observer_frame[1] + 1 + 24)
    actual_cursors = ((actor.screen.cursor.x, actor.screen.cursor.y),
                      (observer.screen.cursor.x, observer.screen.cursor.y))
    expected_cursors = (actor_cursor, observer_cursor)
    if actual_cursors != expected_cursors:
        print('  physical cursors actual/expected:',
              actual_cursors, expected_cursors)
    check('both restored physical cursors equal daemon',
          actor_cursor is not None and observer_cursor is not None and
          actual_cursors == expected_cursors)
    check('both clients survive ordering stress',
          actor.alive() and observer.alive())
finally:
    if observer is not None:
        observer.close()
    actor.close()
    stlib.close_all_daemons(HOME)

stlib.report()
