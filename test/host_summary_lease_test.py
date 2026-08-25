#!/usr/bin/env python3
"""Host compatibility bypasses layout leases without touching geometry.

One real UI enters equal-host raw F5.  A protocol peer then owns pane 0's
layout lease while a third, smaller host attaches, resizes, and detaches.  The
lease owner must receive each dedicated host summary before it unlocks, while
the real UI must reclaim the renderer immediately and the canonical PTY size
must never roll back.  This specifically catches reusing LAYOUT_EV for host
metadata: that broadcast deliberately skips its current lease owner.
"""
import os
import re
import select
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, raw_frame, read_frame, run_cli


FRAME_ATTACH = 1
FRAME_DETACH = 4
FRAME_LAYOUT_LOCK = 17
FRAME_LAYOUT_UNLOCK = 18
FRAME_CLIENT_SIZE = 19
FRAME_SESSION = 20
FRAME_SCREEN = 21
FRAME_READY = 22
FRAME_LAYOUT_EV = 26
FRAME_LAYOUT_LOCK_REPLY = 33
FRAME_HOST_SUMMARY_EV = 34


def attach_proto_ver():
    source = os.path.join(os.path.dirname(__file__), '..', 'src',
                          'st_server.pas')
    with open(source, encoding='utf-8') as stream:
        for line in stream:
            match = re.match(r'\s*ATTACH_PROTO_VER\s*=\s*(\d+)', line)
            if match:
                return int(match.group(1))
    raise RuntimeError('ATTACH_PROTO_VER not found')


PROTO_VER = attach_proto_ver()


def configure(home):
    with open(home + '/.superterm/superterm.ini', 'w') as stream:
        stream.write('[ui]\nlanguage=en\nbackground=none\n'
                     '[session]\nserver=always\nautosave=0\nautorestore=0\n'
                     'zoomanim=0\n')


def skip_pascal_string(payload, offset):
    _value, offset = stlib.read_pas_string(payload, offset)
    return offset


def snapshot_revision(payload):
    """Parse the versioned SESSION tail up to its canonical revision."""
    offset = skip_pascal_string(payload, 0)
    _focused, count = struct.unpack_from('<ii', payload, offset)
    offset += 8
    for _ in range(count):
        offset = skip_pascal_string(payload, offset)  # title
        offset = skip_pascal_string(payload, offset)  # terminal
    offset = skip_pascal_string(payload, offset)      # session name
    offset = skip_pascal_string(payload, offset)      # profile
    geom_count, _desk_w, _desk_h = struct.unpack_from('<iii', payload,
                                                       offset)
    offset += 12 + geom_count * (6 * 4 + 3)
    proto, _reserved = struct.unpack_from('<ii', payload, offset)
    offset += 8
    if proto != PROTO_VER:
        raise ValueError('snapshot protocol mismatch')
    return struct.unpack_from('<Q', payload, offset)[0]


def layout_revision(payload):
    """Parse a LAYOUT_EV through geometry to its canonical revision."""
    offset = skip_pascal_string(payload, 0)
    _focused, count = struct.unpack_from('<ii', payload, offset)
    offset += 8
    for _ in range(count):
        offset = skip_pascal_string(payload, offset)
    offset += 8 + count * (6 * 4 + 3)  # desktop WxH and pane geometry
    return struct.unpack_from('<Q', payload, offset)[0]


def attach_wire(path, width, height):
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.settimeout(5.0)
    peer.connect(path)
    peer.sendall(raw_frame(FRAME_ATTACH, -1,
                           struct.pack('<iiiii', PROTO_VER, width, height,
                                       1, 0)))
    first = read_frame(peer, timeout=5.0)
    if first is None or first[0] != FRAME_SESSION:
        peer.close()
        raise RuntimeError('missing SESSION snapshot')
    revision = snapshot_revision(first[2])
    while True:
        frame = read_frame(peer, timeout=5.0)
        if frame is None:
            peer.close()
            raise RuntimeError('EOF during snapshot')
        if frame[0] == FRAME_READY:
            return peer, revision
        if frame[0] != FRAME_SCREEN:
            peer.close()
            raise RuntimeError('unexpected snapshot frame ' + str(frame[0]))


def collect_until(peer, predicate, ui=None, timeout=5.0):
    frames = []
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if ui is not None:
            ui.drain(0.025)
        ready, _, _ = select.select([peer], [], [], 0.04)
        if not ready:
            continue
        frame = read_frame(peer, timeout=0.5)
        if frame is None:
            break
        frames.append(frame)
        if predicate(frame):
            break
    return frames


def host_summary(frame):
    if frame[0] != FRAME_HOST_SUMMARY_EV or len(frame[2]) != 16:
        return None
    return struct.unpack('<iiii', frame[2])


def pane_size(home, session):
    result = run_cli(['list', session], home, env={'LANG': 'C'})
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        if not line.startswith('1 '):
            continue
        for token in line.split():
            if re.fullmatch(r'\d+x\d+', token):
                return tuple(int(value) for value in token.split('x', 1))
    return None


home = stlib.fresh_home('host-summary-lease')
configure(home)
ui = stlib.Client(home, w=100, h=30, lang='en')
lease_peer = None
small_peer = None
try:
    ui.drain(2.2)
    sockets = stlib.session_sockets(home)
    check('one session exists', len(sockets) == 1)
    path = sockets[0] if sockets else ''
    session = os.path.basename(path)[:-5] if path else ''

    if path:
        lease_peer, revision = attach_wire(path, 100, 30)
        initial = collect_until(
            lease_peer,
            lambda frame: host_summary(frame) == (2, 100, 30, 1), ui)
        check('equal-host summary reaches protocol peer',
              any(host_summary(frame) == (2, 100, 30, 1)
                  for frame in initial))
    else:
        revision = 0
        check('equal-host summary reaches protocol peer', False)

    # This is an explicit F5 after both equal hosts are present, so raw is
    # permitted.  The protocol peer observes the resulting layout revision.
    if lease_peer is not None:
        os.write(ui.fd, b'\x1b[15~')
        f5_frames = collect_until(
            lease_peer, lambda _frame: False, ui, timeout=2.0)
        layouts = [frame for frame in f5_frames
                   if frame[0] == FRAME_LAYOUT_EV]
        if layouts:
            # F5 first broadcasts its visible lock at the old revision, then
            # the atomic fullscreen commit at the next one. Waiting for only
            # the first LAYOUT_EV would intentionally submit a stale lease.
            revision = max(layout_revision(frame[2]) for frame in layouts)
        ui.drain(0.8)
        check('equal hosts enter raw F5',
              layouts and 'Detach' not in ui.text() and
              pane_size(home, session) == (100, 30))
    else:
        check('equal hosts enter raw F5', False)

    # The wire peer now owns pane 0. BroadcastLayoutEv intentionally excludes
    # it until unlock; host summaries must not share that exclusion.
    granted = False
    if lease_peer is not None:
        request_id = 0x48535431
        lease_peer.sendall(raw_frame(
            FRAME_LAYOUT_LOCK, 0, struct.pack('<QQ', request_id, revision)))
        replies = collect_until(
            lease_peer,
            lambda frame: frame[0] == FRAME_LAYOUT_LOCK_REPLY, ui)
        for frame in replies:
            if frame[0] != FRAME_LAYOUT_LOCK_REPLY or len(frame[2]) != 17:
                continue
            reply_id, = struct.unpack_from('<Q', frame[2], 0)
            granted = reply_id == request_id and frame[2][8] == 1
        check('protocol peer owns pane lease', granted)
    else:
        check('protocol peer owns pane lease', False)

    before = pane_size(home, session)
    if path and granted:
        small_peer, _small_revision = attach_wire(path, 70, 22)
        attach_events = collect_until(
            lease_peer,
            lambda frame: host_summary(frame) == (3, 70, 22, 0), ui)
    else:
        attach_events = []
    attach_summary = any(host_summary(frame) == (3, 70, 22, 0)
                         for frame in attach_events)
    check('lease owner gets incompatible attach summary before unlock',
          attach_summary)
    check('host event is separate from lease-filtered layout',
          attach_summary and
          all(frame[0] != FRAME_LAYOUT_EV for frame in attach_events))

    ui.drain(1.0)
    check('raw owner reclaims renderer on incompatible attach',
          'Detach' in ui.text())
    check('attach summary does not roll back canonical geometry',
          before == (100, 30) and pane_size(home, session) == before)

    # A later physical-size report follows the same independent path while
    # the original lease is deliberately still held.
    if small_peer is not None:
        small_peer.sendall(raw_frame(
            FRAME_CLIENT_SIZE, -1, struct.pack('<ii', 60, 20)))
        resize_events = collect_until(
            lease_peer,
            lambda frame: host_summary(frame) == (3, 60, 20, 0), ui)
    else:
        resize_events = []
    resize_summary = any(host_summary(frame) == (3, 60, 20, 0)
                         for frame in resize_events)
    check('lease owner gets resize summary before unlock', resize_summary)
    check('resize metadata leaves canonical geometry unchanged',
          pane_size(home, session) == before)

    if small_peer is not None:
        small_peer.sendall(raw_frame(FRAME_DETACH, -1))
        small_peer.close()
        small_peer = None
        detach_events = collect_until(
            lease_peer,
            lambda frame: host_summary(frame) == (2, 100, 30, 1), ui)
    else:
        detach_events = []
    check('lease owner gets detach summary before unlock',
          any(host_summary(frame) == (2, 100, 30, 1)
              for frame in detach_events))
    ui.drain(0.8)
    check('membership change does not bounce renderer back to raw',
          'Detach' in ui.text())
    check('detach metadata leaves canonical geometry unchanged',
          pane_size(home, session) == before)

    if lease_peer is not None:
        lease_peer.sendall(raw_frame(FRAME_LAYOUT_UNLOCK, 0))
finally:
    if small_peer is not None:
        try:
            small_peer.sendall(raw_frame(FRAME_DETACH, -1))
        except OSError:
            pass
        small_peer.close()
    if lease_peer is not None:
        try:
            lease_peer.sendall(raw_frame(FRAME_LAYOUT_UNLOCK, 0))
            lease_peer.sendall(raw_frame(FRAME_DETACH, -1))
        except OSError:
            pass
        lease_peer.close()
    ui.close()
    stlib.close_all_daemons(home)

stlib.report()
