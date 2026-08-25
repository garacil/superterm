#!/usr/bin/env python3
"""Raw F5 is shared only when every attached host has the same geometry.

The daemon broadcasts each PTY output frame to every viewer, so equal-sized
clients can all preserve the byte-for-byte fullscreen path. A mixed-size set
cannot safely map one canonical terminal byte stream onto every physical
surface; all viewers then use the synchronized renderer at the smallest common
viewport. Leaving F5 restores the normal canonical desktop, which a smaller
host continues to crop deterministically.

An unknown OSC 777 is the transport oracle. Raw passthrough preserves it,
whereas TScreen consumes it and the cell renderer never recreates it. Merely
checking that the menu disappeared would accept both paths and produce a
false PASS.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


def configure(home):
    with open(home + '/.superterm/superterm.ini', 'w') as fh:
        fh.write('[ui]\nlanguage=en\nbackground=none\n'
                 '[session]\nserver=always\nautosave=0\nautorestore=0\n'
                 'zoomanim=0\n')


def drain_all(clients, seconds=0.3):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.025)


def session_name(home):
    sockets = stlib.session_sockets(home)
    check('one session exists', len(sockets) == 1)
    return os.path.basename(sockets[0])[:-5] if sockets else ''


def pane_size(home, session):
    result = run_cli(['list', session], home, env={'LANG': 'C'})
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


def send_raw_oracle(actor, clients, token):
    """Return each client's post-command bytes and the exact raw OSC."""
    osc = b'\x1b]777;' + token + b'\x07'
    visible = token + b'_VISIBLE_DONE'
    offsets = {client: len(client.raw()) for client in clients}
    # The completed visible marker is assembled by printf, so it is absent
    # from the echoed input line and proves that the command actually ran.
    command = (b"printf '\\033]777;" + token + b"\\007'; "
               b"printf '" + token + b"_VISIBLE_%s\\n' 'DONE'\r")
    os.write(actor.fd, command)
    deadline = time.monotonic() + 6.0
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        if all(visible in client.raw()[offsets[client]:]
               for client in clients):
            break
    chunks = {client: client.raw()[offsets[client]:] for client in clients}
    check(token.decode() + ' command completes in every client',
          all(visible in chunks[client] for client in clients))
    return chunks, osc


def frame_right(client):
    found = -1
    for row in client.screen.display:
        for marker in ('╗', '╝', '┐', '┘'):
            found = max(found, row.rfind(marker))
    return found


# ---------------------------------------------------------------- equal hosts

same_home = stlib.fresh_home('passthrough-multiclient-same')
configure(same_home)
same_a = stlib.Client(same_home, w=100, h=30, lang='en')
same_b = None
try:
    same_a.drain(2.5)
    same_session = session_name(same_home)
    same_b = stlib.Client(same_home, args=['--attach', same_session],
                          w=100, h=30, lang='en')
    same_b.drain(2.5)
    same_clients = (same_a, same_b)
    check('equal-size second client attaches', same_b.alive())
    check('equal-size attach leaves windowed PTY',
          pane_size(same_home, same_session) == (96, 25))

    os.write(same_a.fd, b'\x1b[15~')
    drain_all(same_clients, 1.5)
    check('equal-size F5 uses whole canonical terminal',
          pane_size(same_home, same_session) == (100, 30))
    same_chunks, same_osc = send_raw_oracle(
        same_a, same_clients, b'RAW_F5_SAME_GEOMETRY')
    check('equal-size F5 is raw in actor and observer',
          all(same_osc in same_chunks[client] for client in same_clients))
    check('equal-size raw F5 hides the IDE in both',
          all('Detach' not in client.text() for client in same_clients))

    os.write(same_b.fd, b'\x1b[15~')
    drain_all(same_clients, 1.3)
    check('shared F5 exit restores both IDEs',
          all('Detach' in client.text() for client in same_clients))
    check('shared F5 exit restores windowed PTY',
          pane_size(same_home, same_session) == (96, 25))
finally:
    if same_b is not None:
        same_b.close()
    same_a.close()
    stlib.close_all_daemons(same_home)


# -------------------------------------------------------------- unequal hosts

mixed_home = stlib.fresh_home('passthrough-multiclient-mixed')
configure(mixed_home)
large = stlib.Client(mixed_home, w=120, h=36, lang='en')
small = None
try:
    large.drain(2.5)
    mixed_session = session_name(mixed_home)
    small = stlib.Client(mixed_home, args=['--attach', mixed_session],
                         w=70, h=22, lang='en')
    small.drain(2.5)
    mixed_clients = (large, small)
    check('mixed-size second client attaches', small.alive())
    check('mixed-size attach does not negotiate PTY',
          pane_size(mixed_home, mixed_session) == (116, 31))
    check('smaller host initially crops shared frame', frame_right(small) == -1)

    os.write(large.fd, b'\x1b[15~')
    drain_all(mixed_clients, 1.5)
    # Fullscreen uses one renderer grid that fits every host. The normal
    # 120x36 desktop remains saved for F5-out, while the live PTY temporarily
    # adopts the smallest common 70x22 viewport.
    check('mixed-size F5 uses common safe viewport',
          pane_size(mixed_home, mixed_session) == (70, 22))
    mixed_chunks, mixed_osc = send_raw_oracle(
        large, mixed_clients, b'GRID_F5_MIXED_GEOMETRY')
    check('mixed-size F5 uses renderer in both clients',
          all(mixed_osc not in mixed_chunks[client]
              for client in mixed_clients))

    # Put a token in the common area. Both renderers must present identical
    # common desktop cells; the larger host merely has unused outer space.
    large.send(
        b"printf '\\033[2J\\033[H\\033[2;2HSAFE_%s' 'OVERLAP'\r", 0.2)
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        drain_all(mixed_clients, 0.08)
        if all('SAFE_OVERLAP' in client.text() for client in mixed_clients):
            break
    check('mixed-size fallback preserves common content',
          all('SAFE_OVERLAP' in client.text() for client in mixed_clients))
    check('mixed-size common viewport is cell-identical',
          all(large.screen.display[y][:small.w] == small.screen.display[y]
              for y in range(small.h - 2)))
    check('mixed-size fallback remains live',
          all(client.alive() for client in mixed_clients) and
          pane_size(mixed_home, mixed_session) == (70, 22))

    os.write(small.fd, b'\x1b[15~')
    drain_all(mixed_clients, 1.3)
    check('mixed-size F5 exit restores large frame', frame_right(large) == 117)
    check('mixed-size F5 exit keeps safe crop', frame_right(small) == -1)
    check('mixed-size F5 exit restores canonical PTY',
          pane_size(mixed_home, mixed_session) == (116, 31))
finally:
    if small is not None:
        small.close()
    large.close()
    stlib.close_all_daemons(mixed_home)

stlib.report()
