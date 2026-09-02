#!/usr/bin/env python3
"""The daemon alone owns explicit canonical-desktop resize transactions.

This drives protocol v16 directly so the UI cannot accidentally make the
assertions pass by repairing a malformed proposal locally. It verifies the
global lease/base revision, exact bounds, minimum title translation and stable
normal-window sizes/PTYs. Protocol replies are ordering barriers, so the test
does not guess when a resize has settled with a fixed sleep.
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
from stlib import (FRAME_ATTACH, FRAME_LAYOUT, FRAME_DESKTOP_RESIZE,
    FRAME_LAYOUT_LOCK, FRAME_CLIENT_SIZE, FRAME_SESSION, FRAME_SCREEN,
    FRAME_READY, FRAME_ERROR, FRAME_LAYOUT_EV, FRAME_RESIZE_EV,
    FRAME_LAYOUT_LOCK_REPLY, FRAME_HOST_SUMMARY_EV, FRAME_LAYOUT_PEER_EV)


DESKTOP_MIN = (20, 25)
DESKTOP_MAX = (8192, 4094)
SCREEN_MAX = (8192, 4096)
GEOM_FORMAT = '<iiiiiiBBB'


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


def unpack(fmt, payload, offset):
    size = struct.calcsize(fmt)
    if offset < 0 or offset + size > len(payload):
        raise ValueError('short protocol payload')
    return struct.unpack_from(fmt, payload, offset), offset + size


def pas_string(payload, offset):
    (length,), offset = unpack('<i', payload, offset)
    if length < 0 or offset + length > len(payload):
        raise ValueError('invalid Pascal string')
    return (payload[offset:offset + length].decode('utf-8', 'replace'),
            offset + length)


def parse_snapshot(payload):
    nodes, offset = pas_string(payload, 0)
    (focused, count), offset = unpack('<ii', payload, offset)
    titles = []
    for _pane in range(count):
        title, offset = pas_string(payload, offset)
        _term, offset = pas_string(payload, offset)
        titles.append(title)
    _name, offset = pas_string(payload, offset)
    _profile, offset = pas_string(payload, offset)
    (geom_count, desk_w, desk_h), offset = unpack('<iii', payload, offset)
    geometry = []
    for _pane in range(geom_count):
        geom, offset = unpack(GEOM_FORMAT, payload, offset)
        geometry.append(geom)
    (proto, _reserved), offset = unpack('<ii', payload, offset)
    (revision,), offset = unpack('<Q', payload, offset)
    (_clients,), offset = unpack('<i', payload, offset)
    (_locked,), offset = unpack('<I', payload, offset)
    (_min_w, _min_h, _match), offset = unpack('<iii', payload, offset)
    if (offset != len(payload) or geom_count != count or
            proto != PROTO_VER):
        raise ValueError('malformed session snapshot')
    return {
        'nodes': nodes, 'focused': focused, 'titles': tuple(titles),
        'desk': (desk_w, desk_h), 'geometry': tuple(geometry),
        'revision': revision,
    }


def parse_layout(payload):
    nodes, offset = pas_string(payload, 0)
    (focused, count), offset = unpack('<ii', payload, offset)
    titles = []
    for _pane in range(count):
        title, offset = pas_string(payload, offset)
        titles.append(title)
    desk, offset = unpack('<ii', payload, offset)
    geometry = []
    for _pane in range(count):
        geom, offset = unpack(GEOM_FORMAT, payload, offset)
        geometry.append(geom)
    (revision, _clients, changes, locked), offset = unpack(
        '<QiII', payload, offset)
    (_min_w, _min_h, _match), offset = unpack('<iii', payload, offset)
    if offset != len(payload):
        raise ValueError('malformed layout event')
    return {
        'nodes': nodes, 'focused': focused, 'titles': tuple(titles),
        'desk': desk, 'geometry': tuple(geometry), 'revision': revision,
        'changes': changes, 'locked': locked,
    }


def layout_payload(layout, geometry, revision, changes):
    payload = bytearray(stlib.pas_string(layout['nodes']))
    payload += struct.pack('<ii', layout['focused'], len(geometry))
    for title in layout['titles']:
        payload += stlib.pas_string(title)
    payload += struct.pack('<ii', *layout['desk'])
    for geom in geometry:
        payload += struct.pack(GEOM_FORMAT, *geom)
    # The daemon owns viewer count, lock mask and host metadata; SendLayout's
    # real client payload ends after the change mask too.
    payload += struct.pack('<QiI', revision, 0, changes)
    return bytes(payload)


def drain_ready(peer):
    """Read frames already queued without waiting for future traffic."""
    frames = []
    while True:
        ready, _, _ = select.select([peer], [], [], 0)
        if not ready:
            break
        frame = read_frame(peer, timeout=0.5)
        if frame is None:
            break
        frames.append(frame)
    return frames


def attach_wire(path, width=63, height=19):
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.settimeout(5.0)
    peer.connect(path)
    peer.sendall(raw_frame(
        FRAME_ATTACH, -1,
        struct.pack('<iiiii', PROTO_VER, width, height, 1, 0)))
    first = read_frame(peer, timeout=5.0)
    if first is None or first[0] != FRAME_SESSION:
        raise RuntimeError('missing FRAME_SESSION')
    snapshot = parse_snapshot(first[2])
    screens = 0
    while True:
        frame = read_frame(peer, timeout=5.0)
        if frame is None:
            raise RuntimeError('EOF before FRAME_READY')
        if frame[0] == FRAME_READY:
            break
        if frame[0] != FRAME_SCREEN:
            raise RuntimeError('unexpected attach frame %d' % frame[0])
        screens += 1
    if screens != len(snapshot['geometry']):
        raise RuntimeError('screen count mismatch')
    drain_ready(peer)
    return peer, snapshot


def acquire(peer, pane, revision, request_id):
    peer.sendall(raw_frame(
        FRAME_LAYOUT_LOCK, pane, struct.pack('<QQ', request_id, revision)))
    deadline = time.monotonic() + 4.0
    preceding = []
    while time.monotonic() < deadline:
        frame = read_frame(peer, timeout=0.7)
        if frame is None:
            break
        if frame[0] != FRAME_LAYOUT_LOCK_REPLY:
            preceding.append(frame)
            continue
        if len(frame[2]) != 17:
            continue
        reply_id = struct.unpack_from('<Q', frame[2], 0)[0]
        if reply_id != request_id:
            continue
        reply_revision = struct.unpack_from('<Q', frame[2], 9)[0]
        return frame[2][8] != 0 and reply_revision == revision, preceding
    return False, preceding


def wait_layout(peer, revision, timeout=5.0):
    frames = []
    layouts = []
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([peer], [], [], 0.05)
        if not ready:
            continue
        frame = read_frame(peer, timeout=0.7)
        if frame is None:
            break
        frames.append(frame)
        if frame[0] in (FRAME_LAYOUT_EV, FRAME_LAYOUT_PEER_EV):
            layout = parse_layout(frame[2])
            if layout['revision'] == revision and layout['locked'] == 0:
                layouts.append(layout)
                break
    return (layouts[-1] if layouts else None), frames


def commit_geometry(peer, layout, geometry, request_id, accepted=True,
                    lock_pane=0, changes=1):
    revision = layout['revision']
    granted, _preceding = acquire(peer, lock_pane, revision, request_id)
    if not granted:
        return None, []
    peer.sendall(raw_frame(
        FRAME_LAYOUT, -1,
        layout_payload(layout, geometry, revision, changes)))
    return wait_layout(peer, revision + int(accepted))


def resize_desktop(peer, layout, size, request_id, base=None):
    revision = layout['revision']
    granted, preceding = acquire(peer, -1, revision, request_id)
    if not granted:
        return None, preceding
    payload_revision = revision if base is None else base
    peer.sendall(raw_frame(
        FRAME_DESKTOP_RESIZE, -1,
        struct.pack('<Qii', payload_revision, size[0], size[1])))
    expected = revision + 1 if size != layout['desk'] and \
        size[0] >= DESKTOP_MIN[0] and size[1] >= DESKTOP_MIN[1] and \
        size[0] <= DESKTOP_MAX[0] and size[1] <= DESKTOP_MAX[1] and \
        payload_revision == revision else revision
    settled, frames = wait_layout(peer, expected)
    return settled, preceding + frames


def publish_host_size(peer, width, height):
    """Publish physical metadata and stop at its FIFO acknowledgement."""
    peer.sendall(raw_frame(
        FRAME_CLIENT_SIZE, -1, struct.pack('<ii', width, height)))
    frames = []
    deadline = time.monotonic() + 4.0
    while time.monotonic() < deadline:
        frame = read_frame(peer, timeout=0.7)
        if frame is None:
            break
        frames.append(frame)
        if frame[0] == FRAME_HOST_SUMMARY_EV:
            return True, frames
    return False, frames


HOME = stlib.fresh_home('desktop-resize-protocol')
with open(HOME + '/.superterm/superterm.ini', 'w', encoding='utf-8') as stream:
    stream.write('[ui]\nlanguage=en\nbackground=none\n'
                 '[session]\nserver=always\nautosave=0\nautorestore=0\n'
                 'zoomanim=0\n')

ui = None
peer = None
try:
    ui = stlib.Client(HOME, w=100, h=30, lang='en')
    ready = ui.wait_until(lambda _text: len(stlib.session_sockets(HOME)) == 1,
                          8.0)
    check('suite-owned session starts', ready)
    sockets = stlib.session_sockets(HOME)
    path = sockets[0] if len(sockets) == 1 else ''
    if path:
        session = os.path.basename(path)[:-5]
        created_a = run_cli(
            ['new', session, '--cmd', 'sleep 600'], HOME,
            env={'LANG': 'C'})
        created_b = run_cli(
            ['new', session, '--cmd', 'sleep 600'], HOME,
            env={'LANG': 'C'})
        peer, layout = attach_wire(path)
    else:
        session = ''
        created_a = None
        created_b = None
        layout = None
    check('protocol v16 snapshot has three canonical panes',
          layout is not None and PROTO_VER == 16 and
          created_a is not None and created_a.returncode == 0 and
          created_b is not None and created_b.returncode == 0 and
          len(layout['geometry']) == 3 and
          layout['desk'][0] >= DESKTOP_MIN[0] and
          layout['desk'][1] >= DESKTOP_MIN[1])

    if layout is not None:
        # Physical size reports remain transport metadata, including a size
        # much smaller than the canonical desktop.
        host_ack, metadata_frames = publish_host_size(peer, 37, 9)
        unchanged, barrier_frames = resize_desktop(
            peer, layout, layout['desk'], 0x44534B0000000000)
        check('FRAME_CLIENT_SIZE is acknowledged as local metadata', host_ack)
        check('host SIGWINCH leaves canonical geometry and revision intact',
              unchanged is not None and unchanged['desk'] == layout['desk'] and
              unchanged['geometry'] == layout['geometry'] and
              unchanged['revision'] == layout['revision'] and
              not any(frame[0] == FRAME_RESIZE_EV
                      for frame in metadata_frames + barrier_frames))
        if unchanged is not None:
            layout = unchanged

        geom = list(layout['geometry'])
        bx, by, bw, bh, _cols, _rows, _zoomed, _minimized, _full = geom[0]
        normal_cols = max(4, bw - 2)
        normal_rows = max(2, bh - 2)
        geom[0] = (layout['desk'][0] + 10, layout['desk'][1] + 10,
                   bw, bh, normal_cols, normal_rows, 0, 0, 0)
        moved, frames = commit_geometry(peer, layout, geom,
                                        0x44534B0000000001)
        check('protocol peer can establish offscreen normal geometry',
              moved is not None and moved['geometry'][0][:2] ==
              geom[0][:2] and moved['revision'] == layout['revision'] + 1)
        if moved is not None:
            layout = moved
            # Direct hostile peers bypass every UI-side range check. Exercise
            # each outer-rectangle field independently, including additions
            # which would wrap a signed TRect if evaluated as Longint.
            partial = list(layout['geometry'])
            valid_head = list(partial[0])
            invalid_tail = list(partial[1])
            valid_head[0] += 1
            invalid_tail[2] = SCREEN_MAX[0] + 1
            partial[0] = tuple(valid_head)
            partial[1] = tuple(invalid_tail)
            atomic, atomic_frames = commit_geometry(
                peer, layout, partial, 0x44534B000000003F,
                accepted=False, lock_pane=-1, changes=3)
            check('invalid geometry tail cannot apply a valid pane head',
                  atomic is not None and
                  atomic['revision'] == layout['revision'] and
                  atomic['geometry'] == layout['geometry'] and
                  atomic['changes'] == 0 and atomic['locked'] == 0 and
                  not any(frame[0] == FRAME_RESIZE_EV
                          for frame in atomic_frames))

            hostile_fields = (
                ('BX', 0, (1 << 31) - 1),
                ('BY', 1, -(1 << 31)),
                ('BW', 2, SCREEN_MAX[0] + 1),
                ('BH', 3, SCREEN_MAX[1] + 1),
            )
            hostile_rejected = True
            for number, (_name, field, value) in enumerate(hostile_fields):
                proposal = list(layout['geometry'])
                pane = list(proposal[0])
                pane[field] = value
                proposal[0] = tuple(pane)
                rejected, reject_frames = commit_geometry(
                    peer, layout, proposal,
                    0x44534B0000000040 + number, accepted=False)
                hostile_rejected = hostile_rejected and (
                    rejected is not None and
                    rejected['revision'] == layout['revision'] and
                    rejected['geometry'] == layout['geometry'] and
                    rejected['locked'] == 0 and
                    not any(frame[0] == FRAME_RESIZE_EV
                            for frame in reject_frames))
            check('hostile BX/BY/BW/BH reject atomically without revision',
                  hostile_rejected)

            before = layout['geometry']
            resized, frames = resize_desktop(
                peer, layout, DESKTOP_MIN, 0x44534B0000000002)
            expected_x = DESKTOP_MIN[0] - 1 - 5
            check('minimum desktop is accepted atomically',
                  resized is not None and resized['desk'] == DESKTOP_MIN and
                  resized['revision'] == layout['revision'] + 1 and
                  sum(1 for frame in frames
                      if frame[0] in (FRAME_LAYOUT_EV,
                                      FRAME_LAYOUT_PEER_EV) and
                      parse_layout(frame[2])['revision'] ==
                      resized['revision']) == 1)
            check('shrink preserves BW/BH and normal PTY',
                  resized is not None and
                  all(after[2:6] == prior[2:6]
                      for after, prior in zip(resized['geometry'], before)))
            check('shrink translates only to one safe title cell',
                  resized is not None and
                  resized['geometry'][0][:2] ==
                  (expected_x, DESKTOP_MIN[1] - 1))
            check('desktop transaction emits no standalone PTY resize',
                  not any(frame[0] == FRAME_RESIZE_EV for frame in frames))
            if resized is not None:
                layout = resized
                same, after_frames = resize_desktop(
                    peer, layout, DESKTOP_MIN, 0x44534B000000000B)
                layout_events = [
                    (frame[0], parse_layout(frame[2]))
                    for frame in frames + after_frames
                    if frame[0] in (FRAME_LAYOUT_EV, FRAME_LAYOUT_PEER_EV)]
                settled_events = [
                    state for kind, state in layout_events
                    if kind == FRAME_LAYOUT_EV and
                    state['revision'] == resized['revision'] and
                    state['locked'] == 0]
                acquire_events = [
                    state for kind, state in layout_events
                    if kind == FRAME_LAYOUT_PEER_EV]
                # The lock mask is viewer-relative: the owner sees locked=0
                # even in its own PEER_EV acquisition barrier.  Those two
                # barriers are not commits; only the two ordinary LAYOUT_EV
                # frames below are the settled changed/same-size commands.
                exactly_once = (
                    same is not None and
                    same['revision'] == resized['revision'] and
                    same['geometry'] == resized['geometry'] and
                    len(settled_events) == 2 and
                    len(acquire_events) == 2 and
                    [state['revision'] for state in acquire_events] ==
                    [resized['revision'] - 1, resized['revision']] and
                    all(state['locked'] == 0 and state['changes'] != 0
                        for state in acquire_events))
                if not exactly_once:
                    print('  resize barrier diagnostic:', {
                        'changed_revision': resized['revision'],
                        'same_revision': (same or {}).get('revision'),
                        'geometry_equal': (same is not None and
                                           same['geometry'] ==
                                           resized['geometry']),
                        'settled_at_revision': len(settled_events),
                        'acquire_revisions': [state['revision']
                                              for state in acquire_events],
                        'frame_kinds': [frame[0]
                                        for frame in frames + after_frames],
                    })
                check('explicit resize changes canonical state exactly once',
                      exactly_once)
                if same is not None:
                    layout = same

        if layout is not None:
            # A hostile peer can bypass the client's local range check. The
            # daemon must reject it, release the lease and keep the revision.
            invalid_sizes = (
                (DESKTOP_MIN[0] - 1, DESKTOP_MIN[1]),
                (DESKTOP_MIN[0], DESKTOP_MIN[1] - 1),
                (DESKTOP_MAX[0] + 1, DESKTOP_MAX[1]),
                (DESKTOP_MAX[0], DESKTOP_MAX[1] + 1),
            )
            all_rejected = True
            for number, invalid_size in enumerate(invalid_sizes, 3):
                invalid, frames = resize_desktop(
                    peer, layout, invalid_size,
                    0x44534B0000000020 + number)
                all_rejected = all_rejected and (
                    invalid is not None and invalid['desk'] == layout['desk']
                    and invalid['revision'] == layout['revision']
                    and invalid['locked'] == 0
                    and any(frame[0] == FRAME_ERROR for frame in frames))
            check('four adjacent out-of-range dimensions are rejected',
                  all_rejected)

            stale, frames = resize_desktop(
                peer, layout, (40, 25), 0x44534B0000000004,
                base=max(0, layout['revision'] - 1))
            check('stale resize base is rejected and lease released',
                  stale is not None and stale['desk'] == layout['desk'] and
                  stale['revision'] == layout['revision'] and
                  stale['locked'] == 0 and
                  any(frame[0] == FRAME_ERROR for frame in frames))

            # No physical renderer needs to consume the intentionally huge
            # bound. Keep only the raw peer attached while validating it.
            ui.close()
            ui = None
            maximum, _frames = resize_desktop(
                peer, layout, DESKTOP_MAX, 0x44534B0000000005)
            check('maximum desktop is accepted without resizing normal PTY',
                  maximum is not None and maximum['desk'] == DESKTOP_MAX and
                  all(after[2:6] == prior[2:6]
                      for after, prior in
                      zip(maximum['geometry'], layout['geometry'])))
            if maximum is not None:
                layout = maximum

            moderate, _frames = resize_desktop(
                peer, layout, (40, 25), 0x44534B0000000006)
            if moderate is not None:
                layout = moderate
            check('desktop returns from maximum without scaling a window',
                  maximum is not None and moderate is not None and
                  moderate['desk'] == (40, 25) and
                  all(after[2:6] == prior[2:6]
                      for after, prior in
                      zip(moderate['geometry'], maximum['geometry'])))

finally:
    if peer is not None:
        try:
            peer.close()
        except OSError:
            pass
    if ui is not None:
        ui.close()
    stlib.close_all_daemons(HOME)

stlib.report()
