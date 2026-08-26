#!/usr/bin/env python3
"""Host compatibility metadata never changes canonical zoom geometry.

One real UI enters equal-host raw fullscreen. A protocol peer then owns pane 0's
layout lease while a third, smaller host attaches and resizes.  The lease owner
must receive each dedicated host summary before it commits, while the real UI
must reclaim the renderer immediately and the canonical PTY size must never
change.  This specifically catches reusing LAYOUT_EV for host metadata:
that broadcast deliberately skips its current lease owner.

The lease was granted while only the two large hosts existed. After the small
peer reports its still smaller physical size, the owner submits the canonical
large normal-maximize proposal at the still-valid layout revision. The daemon
must keep that canonical grid and publish it only in the atomic LAYOUT_EV,
never normalize it to physical host metadata or emit an intermediate
RESIZE_EV.
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
FRAME_LAYOUT = 7
FRAME_LAYOUT_LOCK = 17
FRAME_CLIENT_SIZE = 19
FRAME_SESSION = 20
FRAME_SCREEN = 21
FRAME_READY = 22
FRAME_LAYOUT_EV = 26
FRAME_RESIZE_EV = 29
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


def parse_layout(payload):
    """Strictly decode the canonical layout needed for a new proposal."""
    nodes, offset = stlib.read_pas_string(payload, 0)
    focused, count = struct.unpack_from('<ii', payload, offset)
    offset += 8
    titles = []
    for _ in range(count):
        title, offset = stlib.read_pas_string(payload, offset)
        titles.append(title)
    desk = struct.unpack_from('<ii', payload, offset)
    offset += 8
    geometry = []
    geom_size = struct.calcsize('<iiiiiiBBB')
    for _ in range(count):
        geometry.append(struct.unpack_from('<iiiiiiBBB', payload, offset))
        offset += geom_size
    revision, clients, changes, locked = struct.unpack_from(
        '<QiII', payload, offset)
    offset += struct.calcsize('<QiII')
    host = struct.unpack_from('<iii', payload, offset)
    offset += 12
    if offset != len(payload):
        raise ValueError('unexpected LAYOUT_EV tail')
    return {
        'nodes': nodes,
        'focused': focused,
        'titles': tuple(titles),
        'desk': desk,
        'geometry': tuple(geometry),
        'revision': revision,
        'clients': clients,
        'changes': changes,
        'locked': locked,
        'host': host,
    }


def layout_payload(layout, geometry, revision, changes):
    """Encode the strict FRAME_LAYOUT proposal used by protocol clients."""
    payload = bytearray(stlib.pas_string(layout['nodes']))
    payload += struct.pack('<ii', layout['focused'], len(geometry))
    for title in layout['titles']:
        payload += stlib.pas_string(title)
    payload += struct.pack('<ii', *layout['desk'])
    for geom in geometry:
        payload += struct.pack('<iiiiiiBBB', *geom)
    # Client count is compatibility metadata.  Locks and host summaries are
    # daemon-owned and therefore deliberately absent from a proposal.
    payload += struct.pack('<QiI', revision, 0, changes)
    return bytes(payload)


def layout_with_revision(frame, revision):
    if frame[0] != FRAME_LAYOUT_EV:
        return None
    layout = parse_layout(frame[2])
    return layout if layout['revision'] == revision else None


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


home = stlib.fresh_home('host-summary-lease-' + str(os.getpid()))
configure(home)
ui = None
lease_peer = None
small_peer = None
try:
    ui = stlib.Client(home, w=100, h=30, lang='en')
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

    # This is explicit fullscreen after both equal hosts are present, so raw is
    # permitted.  The protocol peer observes the resulting layout revision.
    canonical = None
    if lease_peer is not None:
        os.write(ui.fd, stlib.FULLSCREEN_CHORD)
        f5_frames = collect_until(
            lease_peer, lambda _frame: False, ui, timeout=2.0)
        layouts = [frame for frame in f5_frames
                   if frame[0] == FRAME_LAYOUT_EV]
        if layouts:
            # Fullscreen first broadcasts its visible lock at the old revision, then
            # the atomic fullscreen commit at the next one. Waiting for only
            # the first LAYOUT_EV would intentionally submit a stale lease.
            canonical = max((parse_layout(frame[2]) for frame in layouts),
                            key=lambda layout: layout['revision'])
            revision = canonical['revision']
        ui.drain(0.8)
        check('equal hosts enter raw fullscreen',
              canonical is not None and 'Detach' not in ui.text() and
              pane_size(home, session) == (100, 30))
    else:
        check('equal hosts enter raw fullscreen', False)

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

    # The lease still carries the valid revision from equal-host fullscreen.
    # Its normal-maximize proposal uses the canonical desktop minus the 2x2
    # frame. The just-processed 60x20 report is metadata only and must not
    # replace that canonical grid with a host-derived 58x16 PTY.
    committed_layout = None
    commit_events = []
    canonical_zoom_size = None
    host_derived_size = None
    if (lease_peer is not None and small_peer is not None and granted and
            canonical is not None and resize_summary):
        proposed_geometry = list(canonical['geometry'])
        bx, by, bw, bh, _cols, _rows, _zoomed, minimized, _full = \
            proposed_geometry[0]
        canonical_zoom_size = (canonical['desk'][0] - 2,
                               canonical['desk'][1] - 2)
        proposed_geometry[0] = (
            bx, by, bw, bh, *canonical_zoom_size, 1, minimized, 0)
        host_derived_size = (
            min(canonical['desk'][0], 60) - 2,
            min(canonical['desk'][1], 20 - 2) - 2)
        lease_peer.sendall(raw_frame(
            FRAME_LAYOUT, -1,
            layout_payload(canonical, proposed_geometry, revision, 1)))
        commit_events = collect_until(
            lease_peer,
            lambda frame: layout_with_revision(frame, revision + 1)
            is not None,
            ui)
        # Keep observing past the first final layout: a delayed RESIZE_EV or
        # duplicate same-revision layout would be a real non-atomic update.
        commit_events += collect_until(
            lease_peer, lambda _frame: False, ui, timeout=0.35)
        committed = [layout_with_revision(frame, revision + 1)
                     for frame in commit_events]
        committed = [layout for layout in committed if layout is not None]
        if committed:
            committed_layout = committed[-1]

    check('fixture distinguishes canonical zoom from host metadata',
          canonical_zoom_size == (98, 26) and
          host_derived_size == (58, 16))
    check('zoom commit emits no intermediate RESIZE_EV',
          committed_layout is not None and
          all(frame[0] != FRAME_RESIZE_EV for frame in commit_events) and
          sum(layout_with_revision(frame, revision + 1) is not None
              for frame in commit_events) == 1)
    check('daemon keeps zoom on canonical desktop after host resize',
          committed_layout is not None and
          committed_layout['host'] == (60, 20, 0) and
          committed_layout['geometry'][0][4:6] == canonical_zoom_size and
          committed_layout['geometry'][0][6:9] == (1, 0, 0))
    check('canonical PTY matches committed LAYOUT_EV',
          canonical_zoom_size is not None and
          pane_size(home, session) == canonical_zoom_size)

    # A zoomed pane must retain a valid restore rectangle.  A local protocol
    # peer may be malformed even though normal UI paths never emit zero BW/BH;
    # reject the whole proposal without changing revision, PTY or geometry.
    malformed_granted = False
    malformed_layout = None
    malformed_events = []
    if lease_peer is not None and committed_layout is not None:
        malformed_revision = committed_layout['revision']
        malformed_request = 0x48535432
        lease_peer.sendall(raw_frame(
            FRAME_LAYOUT_LOCK, 0,
            struct.pack('<QQ', malformed_request, malformed_revision)))
        malformed_replies = collect_until(
            lease_peer,
            lambda frame: frame[0] == FRAME_LAYOUT_LOCK_REPLY, ui)
        for frame in malformed_replies:
            if frame[0] != FRAME_LAYOUT_LOCK_REPLY or len(frame[2]) != 17:
                continue
            reply_id, = struct.unpack_from('<Q', frame[2], 0)
            malformed_granted = (reply_id == malformed_request and
                                 frame[2][8] == 1)
        if malformed_granted:
            malformed_geometry = list(committed_layout['geometry'])
            bx, by, _bw, _bh, cols, rows, zoomed, minimized, full = \
                malformed_geometry[0]
            malformed_geometry[0] = (
                bx, by, 0, 0, cols, rows, zoomed, minimized, full)
            lease_peer.sendall(raw_frame(
                FRAME_LAYOUT, -1,
                layout_payload(committed_layout, malformed_geometry,
                               malformed_revision, 1)))
            malformed_events = collect_until(
                lease_peer,
                lambda frame: (frame[0] == FRAME_LAYOUT_EV and
                               parse_layout(frame[2])['revision'] ==
                               malformed_revision and
                               parse_layout(frame[2])['locked'] == 0),
                ui)
            candidates = [parse_layout(frame[2])
                          for frame in malformed_events
                          if frame[0] == FRAME_LAYOUT_EV]
            if candidates:
                malformed_layout = candidates[-1]

    check('malformed zoom fixture reacquires its pane lease',
          malformed_granted)
    check('zero restore rectangle is rejected atomically',
          malformed_layout is not None and
          malformed_layout['revision'] == committed_layout['revision'] and
          malformed_layout['geometry'][0] ==
          committed_layout['geometry'][0] and
          all(frame[0] != FRAME_RESIZE_EV for frame in malformed_events))
    check('malformed zoom leaves canonical PTY unchanged',
          canonical_zoom_size is not None and
          pane_size(home, session) == canonical_zoom_size)

    if small_peer is not None:
        small_peer.sendall(raw_frame(FRAME_DETACH, -1))
        small_peer.close()
        small_peer = None
        detach_events = collect_until(
            lease_peer,
            lambda frame: host_summary(frame) == (2, 100, 30, 1), ui)
    else:
        detach_events = []
    check('protocol peer gets detach host summary',
          any(host_summary(frame) == (2, 100, 30, 1)
              for frame in detach_events))
    ui.drain(0.8)
    check('membership change does not bounce renderer back to raw',
          'Detach' in ui.text())
    check('detach metadata leaves canonical geometry unchanged',
          canonical_zoom_size is not None and
          pane_size(home, session) == canonical_zoom_size)

finally:
    if small_peer is not None:
        try:
            small_peer.sendall(raw_frame(FRAME_DETACH, -1))
        except OSError:
            pass
        small_peer.close()
    if lease_peer is not None:
        try:
            lease_peer.sendall(raw_frame(FRAME_DETACH, -1))
        except OSError:
            pass
        lease_peer.close()
    stlib.close_all_daemons(home)
    if ui is not None:
        stlib.wait_pid(ui.pid, timeout=3.0, terminate=True)
        ui.close()

stlib.report()
