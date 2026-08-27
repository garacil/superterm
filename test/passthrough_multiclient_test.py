#!/usr/bin/env python3
"""Raw fullscreen requires viewers that match the canonical geometry.

The daemon broadcasts each PTY output frame to every viewer, so equal-sized
clients can all preserve the byte-for-byte fullscreen path. A mixed-size set
cannot safely map one canonical terminal byte stream onto every physical
surface; all viewers then use the synchronized renderer at the unchanged
canonical geometry. A smaller host sees its local viewport and scrollbars.
Leaving fullscreen restores the normal canonical desktop without negotiating
either PTY from physical host sizes.

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


def probe_private_terminal_reply(actor, observer):
    """A host DA reply must never become shared pane keyboard input."""
    clients = (actor, observer)
    query = b'\x1b[c'
    response = b'\x1b[?61;4;6;7;14;21;22;23;24;28;32;42;52c'
    leaked_tail = response[3:]
    offsets = {client: len(client.raw()) for client in clients}
    os.write(actor.fd, b"printf '\\033[c'\r")
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        if all(query in client.raw()[offsets[client]:]
               for client in clients):
            break
    check('DA query reaches both equal-size raw viewers',
          all(query in client.raw()[offsets[client]:]
              for client in clients))

    offsets = {client: len(client.raw()) for client in clients}
    os.write(actor.fd, response)
    os.write(observer.fd, response)
    drain_all(clients, 0.7)
    chunks = {client: client.raw()[offsets[client]:] for client in clients}
    check('private DA replies never leak into the shared pane',
          all(leaked_tail not in chunks[client] for client in clients))

    actor.send(b"printf 'AFTER_HOST_DA_%s\\n' 'SAFE'\r", 0.2)
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        if all(b'AFTER_HOST_DA_SAFE' in client.raw()
               for client in clients):
            break
    check('input remains aligned after simultaneous DA replies',
          all(b'AFTER_HOST_DA_SAFE' in client.raw()
              for client in clients))


def probe_blocked_color_query(actor, observer):
    """A broadcast host-read query must not solicit per-client replies."""
    clients = (actor, observer)
    # Xterm permits successive dynamic-color parameters: this single query
    # produces two independently framed replies, OSC 10 and OSC 11.
    query_st = b'\x1b]10;?;?\x1b\\'
    query_bel = b'\x1b]11;?\x07'
    offsets = {client: len(client.raw()) for client in clients}
    os.write(actor.fd,
             b"printf '\\033]10;?;?\\033\\\\\\033]11;?\\007'\r")
    drain_all(clients, 0.8)
    query_seen = {
        client: (query_st in client.raw()[offsets[client]:] or
                 query_bel in client.raw()[offsets[client]:])
        for client in clients
    }
    check('BEL/ST OSC color queries are blocked for every viewer',
          not any(query_seen.values()))

    # Emulate real terminals: only a viewer which received the query answers.
    # The old build broadcasts it to both and both bodies are visibly typed.
    payload10 = b'10;rgb:1e1e/dcdc/0101'
    payload11 = b'11;rgb:0202/2424/0000'
    fragments = (
        b'\x1b',
        b']10;rgb:1e1e/',
        b'dcdc/0101\x07\x1b]11;rgb:0202/',
        b'2424/0000\x1b',
        b'\\',
    )
    offsets = {client: len(client.raw()) for client in clients}
    for client in clients:
        if not query_seen[client]:
            continue
        for fragment in fragments:
            stlib.write_all(client.fd, fragment)
            time.sleep(0.008)
    drain_all(clients, 0.8)
    chunks = {client: client.raw()[offsets[client]:] for client in clients}
    check('fragmented BEL/ST OSC color replies never leak into the pane',
          all(payload10 not in chunks[client] and
              payload11 not in chunks[client] for client in clients))

    # On the buggy build the reply body is pending in readline. Clear it so
    # the alignment oracle executes in either build and reports independently.
    actor.send(b"\x15printf 'AFTER_HOST_OSC_%s\\n' 'SAFE'\r", 0.2)
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        if all(b'AFTER_HOST_OSC_SAFE' in client.raw()
               for client in clients):
            break
    check('input remains aligned after simultaneous OSC replies',
          all(b'AFTER_HOST_OSC_SAFE' in client.raw()
              for client in clients))

    # A color setter is output, not a host read, and must remain raw.
    setter = b'\x1b]10;rgb:1111/2222/3333\x1b\\'
    offsets = {client: len(client.raw()) for client in clients}
    os.write(actor.fd, b"printf '\\033]10;rgb:1111/2222/3333\\033\\\\'\r")
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        if all(setter in client.raw()[offsets[client]:]
               for client in clients):
            break
    check('dynamic-color setter remains raw in every viewer',
          all(setter in client.raw()[offsets[client]:]
              for client in clients))


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

    os.write(same_a.fd, stlib.FULLSCREEN_CHORD)
    drain_all(same_clients, 1.5)
    check('equal-size fullscreen uses whole canonical terminal',
          pane_size(same_home, same_session) == (100, 30))
    same_chunks, same_osc = send_raw_oracle(
        same_a, same_clients, b'RAW_F5_SAME_GEOMETRY')
    check('equal-size fullscreen is raw in actor and observer',
          all(same_osc in same_chunks[client] for client in same_clients))
    check('equal-size raw fullscreen hides the IDE in both',
          all('Detach' not in client.text() for client in same_clients))
    probe_private_terminal_reply(same_a, same_b)
    probe_blocked_color_query(same_a, same_b)

    os.write(same_b.fd, stlib.FULLSCREEN_CHORD)
    drain_all(same_clients, 1.3)
    check('shared fullscreen exit restores both IDEs',
          all('Detach' in client.text() for client in same_clients))
    check('shared fullscreen exit restores windowed PTY',
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

    os.write(large.fd, stlib.FULLSCREEN_CHORD)
    drain_all(mixed_clients, 1.5)
    # Fullscreen uses the canonical 120x36 grid. The 70x22 viewer scrolls or
    # clips that renderer; its physical size never negotiates the live PTY.
    check('mixed-size fullscreen keeps canonical geometry',
          pane_size(mixed_home, mixed_session) == (120, 36))
    mixed_chunks, mixed_osc = send_raw_oracle(
        large, mixed_clients, b'GRID_F5_MIXED_GEOMETRY')
    check('mixed-size fullscreen uses renderer in both clients',
          all(mixed_osc not in mixed_chunks[client]
              for client in mixed_clients))

    # Put a token in the upper-left overlap. Both renderers present identical
    # canonical cells there; the smaller viewer reserves its last column for
    # the vertical desktop scrollbar.
    large.send(
        b"printf '\\033[2J\\033[H\\033[2;2HSAFE_%s' 'OVERLAP'\r", 0.2)
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        drain_all(mixed_clients, 0.08)
        if all('SAFE_OVERLAP' in client.text() for client in mixed_clients):
            break
    check('mixed-size fallback preserves common content',
          all('SAFE_OVERLAP' in client.text() for client in mixed_clients))
    # Row zero is each viewer's physical menu bar.  A narrow client uses the
    # deliberately compact labels there, so it is not part of the shared
    # canonical desktop whose cells this oracle compares.
    overlap_mismatches = [
        (y, large.screen.display[y][:small.w - 1],
         small.screen.display[y][:small.w - 1])
        for y in range(1, small.h - 2)
        if large.screen.display[y][:small.w - 1] !=
        small.screen.display[y][:small.w - 1]
    ]
    if overlap_mismatches:
        y, large_row, small_row = overlap_mismatches[0]
        print('  first overlap mismatch row=%d large=%r small=%r' %
              (y, large_row, small_row))
    check('mixed-size canonical overlap is cell-identical',
          not overlap_mismatches)
    check('mixed-size fallback remains live',
          all(client.alive() for client in mixed_clients) and
          pane_size(mixed_home, mixed_session) == (120, 36))

    os.write(small.fd, stlib.FULLSCREEN_CHORD)
    drain_all(mixed_clients, 1.3)
    check('mixed-size fullscreen exit restores large frame', frame_right(large) == 117)
    check('mixed-size fullscreen exit keeps safe crop', frame_right(small) == -1)
    check('mixed-size fullscreen exit restores canonical PTY',
          pane_size(mixed_home, mixed_session) == (116, 31))
finally:
    if small is not None:
        small.close()
    large.close()
    stlib.close_all_daemons(mixed_home)

stlib.report()
