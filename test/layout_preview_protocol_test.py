#!/usr/bin/env python3
"""Protocol-v14 layout previews are ordered, transient and owner-scoped.

This test deliberately speaks the raw daemon protocol.  It separates the
preview relay from FreeVision rendering and proves that cosmetic BOUNDS and
WIREFRAME messages cannot mutate the canonical revision, window geometry or
the real PTY size.  Invalid/non-owner frames are followed by another valid
preview, so silently dropping the connection or poisoning its sequence cannot
make a rejection look successful.
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
FRAME_LAYOUT_UNLOCK = 18
FRAME_SESSION = 20
FRAME_SCREEN = 21
FRAME_READY = 22
FRAME_LAYOUT_EV = 26
FRAME_LAYOUT_LOCK_REPLY = 33
FRAME_LAYOUT_PREVIEW = 35
FRAME_LAYOUT_PREVIEW_EV = 36

PREVIEW_OP_BOUNDS = 1
PREVIEW_OP_WIREFRAME = 2
PREVIEW_OP_OUTLINE_SHOW = 3
PREVIEW_OP_OUTLINE_HIDE = 4
PREVIEW_OP_TAIL_BEGIN = 5
PREVIEW_OP_TAIL_END = 6
PREVIEW_OP_CLEAR = 7
PREVIEW_FORMAT = '<QQQB3xiiii'
PREVIEW_SIZE = struct.calcsize(PREVIEW_FORMAT)

HOST_W = 100
HOST_H = 30


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


def unpack_from(fmt, payload, offset):
    size = struct.calcsize(fmt)
    if offset < 0 or offset + size > len(payload):
        raise ValueError('short protocol payload')
    values = struct.unpack_from(fmt, payload, offset)
    return values, offset + size


def pas_string(payload, offset):
    (length,), offset = unpack_from('<i', payload, offset)
    if length < 0 or offset + length > len(payload):
        raise ValueError('invalid Pascal string')
    value = payload[offset:offset + length].decode('utf-8', 'replace')
    return value, offset + length


def pane_geom(payload, offset):
    values, offset = unpack_from('<iiiiiiBBB', payload, offset)
    return values, offset


def parse_snapshot(payload):
    """Decode every canonical field needed from FRAME_SESSION."""
    nodes, offset = pas_string(payload, 0)
    (focused, count), offset = unpack_from('<ii', payload, offset)
    titles = []
    terms = []
    for _ in range(count):
        title, offset = pas_string(payload, offset)
        term, offset = pas_string(payload, offset)
        titles.append(title)
        terms.append(term)
    session, offset = pas_string(payload, offset)
    profile, offset = pas_string(payload, offset)
    (geom_count, desk_w, desk_h), offset = unpack_from(
        '<iii', payload, offset)
    geometry = []
    for _ in range(geom_count):
        geom, offset = pane_geom(payload, offset)
        geometry.append(geom)
    (proto, reserved), offset = unpack_from('<ii', payload, offset)
    (revision,), offset = unpack_from('<Q', payload, offset)
    (clients,), offset = unpack_from('<i', payload, offset)
    (locked,), offset = unpack_from('<I', payload, offset)
    (min_w, min_h, hosts_match), offset = unpack_from(
        '<iii', payload, offset)
    if offset != len(payload):
        raise ValueError('unexpected FRAME_SESSION tail')
    return {
        'nodes': nodes,
        'focused': focused,
        'count': count,
        'titles': tuple(titles),
        'terms': tuple(terms),
        'session': session,
        'profile': profile,
        'desk': (desk_w, desk_h),
        'geometry': tuple(geometry),
        'proto': proto,
        'reserved': reserved,
        'revision': revision,
        'clients': clients,
        'locked': locked,
        'host': (min_w, min_h, hosts_match),
    }


def parse_layout(payload):
    """Decode a canonical FRAME_LAYOUT_EV without accepting trailing junk."""
    nodes, offset = pas_string(payload, 0)
    (focused, count), offset = unpack_from('<ii', payload, offset)
    titles = []
    for _ in range(count):
        title, offset = pas_string(payload, offset)
        titles.append(title)
    (desk_w, desk_h), offset = unpack_from('<ii', payload, offset)
    geometry = []
    for _ in range(count):
        geom, offset = pane_geom(payload, offset)
        geometry.append(geom)
    (revision,), offset = unpack_from('<Q', payload, offset)
    (clients,), offset = unpack_from('<i', payload, offset)
    (changes, locked), offset = unpack_from('<II', payload, offset)
    (min_w, min_h, hosts_match), offset = unpack_from(
        '<iii', payload, offset)
    if offset != len(payload):
        raise ValueError('unexpected FRAME_LAYOUT_EV tail')
    return {
        'nodes': nodes,
        'focused': focused,
        'count': count,
        'titles': tuple(titles),
        'desk': (desk_w, desk_h),
        'geometry': tuple(geometry),
        'revision': revision,
        'clients': clients,
        'changes': changes,
        'locked': locked,
        'host': (min_w, min_h, hosts_match),
    }


def preview_payload(gesture, revision, seq, op, rect=(0, 0, 0, 0)):
    return struct.pack(PREVIEW_FORMAT, gesture, revision, seq, op, *rect)


def pas_blob(value):
    encoded = value.encode('utf-8')
    return struct.pack('<i', len(encoded)) + encoded


def layout_payload(snapshot, geometry, revision, changes):
    """Encode the same strict FRAME_LAYOUT proposal as SendLayout."""
    payload = bytearray(pas_blob(snapshot['nodes']))
    payload += struct.pack('<ii', snapshot['focused'], len(geometry))
    for title in snapshot['titles']:
        payload += pas_blob(title)
    payload += struct.pack('<ii', *snapshot['desk'])
    for geom in geometry:
        payload += struct.pack('<iiiiiiBBB', *geom)
    # ClientCount is compatibility metadata only; zero is valid and avoids
    # baking a racing attach count into the canonical proposal.
    payload += struct.pack('<QiI', revision, 0, changes)
    return bytes(payload)


def parse_preview(payload):
    if len(payload) != PREVIEW_SIZE:
        raise ValueError('bad preview payload size')
    gesture, revision, seq, op, x, y, width, height = struct.unpack(
        PREVIEW_FORMAT, payload)
    return {
        'gesture': gesture,
        'revision': revision,
        'seq': seq,
        'op': op,
        'rect': (x, y, width, height),
    }


def collect(peer, seconds=0.25):
    frames = []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        ready, _, _ = select.select(
            [peer], [], [], min(0.04, deadline - time.monotonic()))
        if not ready:
            continue
        try:
            frame = read_frame(peer, timeout=0.5)
        except (OSError, socket.timeout):
            break
        if frame is None:
            break
        frames.append(frame)
    return frames


def preview_events(frames):
    result = []
    for kind, pane, payload in frames:
        if kind == FRAME_LAYOUT_PREVIEW_EV:
            result.append((pane, parse_preview(payload)))
    return result


def attach_wire(path):
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.settimeout(5.0)
    peer.connect(path)
    payload = struct.pack('<iiiii', PROTO_VER, HOST_W, HOST_H, 1, 0)
    peer.sendall(raw_frame(FRAME_ATTACH, -1, payload))
    first = read_frame(peer, timeout=5.0)
    if first is None or first[0] != FRAME_SESSION:
        peer.close()
        raise RuntimeError('missing FRAME_SESSION')
    snapshot = parse_snapshot(first[2])
    screens = 0
    while True:
        frame = read_frame(peer, timeout=5.0)
        if frame is None:
            peer.close()
            raise RuntimeError('EOF during attach snapshot')
        if frame[0] == FRAME_READY:
            break
        if frame[0] != FRAME_SCREEN:
            peer.close()
            raise RuntimeError('unexpected snapshot frame ' + str(frame[0]))
        screens += 1
    if screens != snapshot['count']:
        peer.close()
        raise RuntimeError('snapshot screen count mismatch')
    return peer, snapshot


def lock_layout(peer, pane, revision, request_id):
    peer.sendall(raw_frame(
        FRAME_LAYOUT_LOCK, pane, struct.pack('<QQ', request_id, revision)))
    deadline = time.monotonic() + 3.0
    preceding = []
    while time.monotonic() < deadline:
        ready, _, _ = select.select([peer], [], [], 0.05)
        if not ready:
            continue
        frame = read_frame(peer, timeout=0.5)
        if frame is None:
            break
        if frame[0] != FRAME_LAYOUT_LOCK_REPLY:
            preceding.append(frame)
            continue
        payload = frame[2]
        if len(payload) != 17:
            return False, 0, preceding
        reply_id = struct.unpack_from('<Q', payload, 0)[0]
        granted = payload[8] != 0
        reply_revision = struct.unpack_from('<Q', payload, 9)[0]
        if reply_id == request_id:
            return granted, reply_revision, preceding
    return False, 0, preceding


def wait_for_unlock(peer, gesture, canonical, timeout=3.0):
    """Return frames through CLEAR followed by the unlocked canonical state."""
    frames = []
    clear_index = None
    layout_index = None
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([peer], [], [], 0.05)
        if not ready:
            continue
        frame = read_frame(peer, timeout=0.5)
        if frame is None:
            break
        frames.append(frame)
        if frame[0] == FRAME_LAYOUT_PREVIEW_EV:
            preview = parse_preview(frame[2])
            if (preview['gesture'] == gesture and
                    preview['op'] == PREVIEW_OP_CLEAR):
                clear_index = len(frames) - 1
        elif frame[0] == FRAME_LAYOUT_EV:
            layout = parse_layout(frame[2])
            if (layout['revision'] == canonical['revision'] and
                    layout['geometry'] == canonical['geometry'] and
                    layout['locked'] & 1 == 0):
                layout_index = len(frames) - 1
        if clear_index is not None and layout_index is not None:
            break
    return frames, clear_index, layout_index


def canonical_equal(snapshot, baseline):
    return (snapshot['revision'] == baseline['revision'] and
            snapshot['desk'] == baseline['desk'] and
            snapshot['nodes'] == baseline['nodes'] and
            snapshot['focused'] == baseline['focused'] and
            snapshot['geometry'] == baseline['geometry'])


def actual_pty_size(home, session, label):
    path = os.path.join(home, 'pty-size-' + label)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    result = run_cli(
        ['send', f'{session}:1', "stty size > '" + path + "'"], home,
        env={'LANG': 'C'})
    if result.returncode != 0:
        print('  pty-size CLI stdout:', result.stdout.strip())
        print('  pty-size CLI stderr:', result.stderr.strip())
    deadline = time.monotonic() + 3.0
    value = None
    while time.monotonic() < deadline:
        try:
            with open(path, encoding='ascii') as stream:
                fields = stream.read().split()
            if len(fields) == 2:
                rows, cols = (int(field) for field in fields)
                value = (cols, rows)
                break
        except (FileNotFoundError, ValueError):
            pass
        time.sleep(0.03)
    return result.returncode, value


def distinct_rects(base, desk, count=3):
    x, y, width, height = base
    desk_w, desk_h = desk
    candidates = []
    for dx, dy, dw, dh in (
            (1, 0, 0, 0), (-1, 0, 0, 0),
            (0, 1, 0, 0), (0, -1, 0, 0),
            (0, 0, -1, 0), (0, 0, -2, 0),
            (0, 0, 0, -1), (0, 0, -1, -1)):
        item = (x + dx, y + dy, width + dw, height + dh)
        ix, iy, iw, ih = item
        if (ix >= 0 and iy >= 0 and iw >= 14 and ih >= 4 and
                ix + iw <= desk_w and iy + ih <= desk_h and
                item != base and item not in candidates):
            candidates.append(item)
        if len(candidates) == count:
            break
    return candidates


HOME = stlib.fresh_home('layout-preview-protocol')
INI = HOME + '/.superterm/superterm.ini'
with open(INI, 'w') as stream:
    stream.write('[ui]\nlanguage=en\nbackground=none\n'
                 '[session]\nserver=always\nautosave=0\nautorestore=0\n')

creator = None
owner = None
observer = None
probe = None
late = None
try:
    creator = stlib.Client(HOME, w=HOST_W, h=HOST_H, lang='en')
    creator.drain(2.0)
    creator.send(b'\x11', 0.08)
    creator.send(b'd', 0.35)
    creator_status = creator.wait_exit(timeout=6.0)
    creator.close()
    creator = None
    sockets = stlib.session_sockets(HOME)
    check('detached protocol session exists',
          creator_status == 0 and len(sockets) == 1)
    path = sockets[0] if len(sockets) == 1 else ''
    session = os.path.basename(path)[:-5] if path else ''

    if not path:
        raise RuntimeError('no detached session socket')
    owner, owner_snapshot = attach_wire(path)
    observer, observer_snapshot = attach_wire(path)
    collect(owner, 0.20)
    collect(observer, 0.20)
    check('raw peers use current protocol',
          owner_snapshot['proto'] == PROTO_VER and
          observer_snapshot['proto'] == PROTO_VER)
    check('raw peers receive one canonical pane',
          owner_snapshot['count'] == 1 and
          owner_snapshot['geometry'] == observer_snapshot['geometry'])
    check('canonical revision is initialized', owner_snapshot['revision'] > 0)

    baseline = owner_snapshot
    geom = baseline['geometry'][0]
    base_rect = geom[:4]
    variants = distinct_rects(base_rect, baseline['desk'])
    check('preview fixture has three valid distinct rectangles',
          len(variants) >= 3)
    while len(variants) < 3:
        variants.append(base_rect)
    bounds_rect, wire_rect, final_rect = variants[:3]
    base_revision = baseline['revision']
    pty_rc, baseline_pty = actual_pty_size(HOME, session, 'baseline')
    collect(owner, 0.15)
    collect(observer, 0.15)
    check('fixture reads real canonical PTY size',
          pty_rc == 0 and baseline_pty == (geom[4], geom[5]))

    granted, reply_revision, owner_prefix = lock_layout(
        owner, 0, base_revision, 0x4C505201)
    check('owner acquires pane preview lease',
          granted and reply_revision == base_revision)
    check('lock reply contains no preview echo',
          preview_events(owner_prefix) == [])
    lock_frames = collect(observer, 0.50)
    locked_layouts = [parse_layout(payload)
                      for kind, _pane, payload in lock_frames
                      if kind == FRAME_LAYOUT_EV]
    check('observer sees canonical pane lock',
          any(layout['locked'] & 1 and
              layout['revision'] == base_revision and
              layout['geometry'] == baseline['geometry']
              for layout in locked_layouts))

    gesture = 0x5052455649455731
    expected = [
        {'gesture': gesture, 'revision': base_revision, 'seq': 1,
         'op': PREVIEW_OP_BOUNDS, 'rect': bounds_rect},
        {'gesture': gesture, 'revision': base_revision, 'seq': 2,
         'op': PREVIEW_OP_WIREFRAME, 'rect': wire_rect},
    ]
    owner.sendall(raw_frame(
        FRAME_LAYOUT_PREVIEW, 0,
        preview_payload(gesture, base_revision, 1,
                        PREVIEW_OP_BOUNDS, bounds_rect)))

    # An attach in the middle of the gesture receives canonical state first,
    # then exactly the latest visual preview after READY. It must not replay a
    # made-up history or omit the currently visible BOUNDS.
    probe, during_snapshot = attach_wire(path)
    check('preview leaves snapshot revision and geometry canonical',
          canonical_equal(during_snapshot, baseline))
    check('snapshot advertises the held lease, not preview geometry',
          during_snapshot['locked'] & 1 != 0)
    replayed = preview_events(collect(probe, 0.30))
    check('mid-gesture attach replays exactly latest BOUNDS',
          replayed == [(0, expected[0])])

    time.sleep(0.025)
    owner.sendall(raw_frame(
        FRAME_LAYOUT_PREVIEW, 0,
        preview_payload(gesture, base_revision, 2,
                        PREVIEW_OP_WIREFRAME, wire_rect)))
    relayed = preview_events(collect(observer, 0.75))
    check('observer receives BOUNDS then WIREFRAME exactly',
          relayed == [(0, expected[0]), (0, expected[1])])
    check('preview owner receives no echo',
          preview_events(collect(owner, 0.30)) == [])

    # A capable but non-owning peer cannot impersonate the lease holder.
    collect(observer, 0.10)
    probe.sendall(raw_frame(
        FRAME_LAYOUT_PREVIEW, 0,
        preview_payload(0xBAD00001, base_revision, 1,
                        PREVIEW_OP_BOUNDS, final_rect)))
    check('non-owner preview is rejected',
          preview_events(collect(observer, 0.30)) == [])
    probe.sendall(raw_frame(FRAME_DETACH, -1))
    probe.close()
    probe = None
    collect(owner, 0.15)
    collect(observer, 0.15)

    pty_rc, during_pty = actual_pty_size(HOME, session, 'during')
    collect(owner, 0.15)
    collect(observer, 0.15)
    check('preview leaves the real PTY unchanged',
          pty_rc == 0 and during_pty == baseline_pty)

    def rejected(label, pane, payload):
        collect(observer, 0.06)
        owner.sendall(raw_frame(FRAME_LAYOUT_PREVIEW, pane, payload))
        check(label, preview_events(collect(observer, 0.25)) == [])

    stale_revision = base_revision - 1 if base_revision > 0 else 1
    rejected('stale preview base revision is rejected', 0,
             preview_payload(gesture, stale_revision, 3,
                             PREVIEW_OP_BOUNDS, final_rect))
    rejected('stale preview sequence is rejected', 0,
             preview_payload(gesture, base_revision, 2,
                             PREVIEW_OP_BOUNDS, final_rect))
    rejected('out-of-range preview pane is rejected', baseline['count'],
             preview_payload(gesture, base_revision, 3,
                             PREVIEW_OP_BOUNDS, final_rect))
    # Partially off-desktop windows are valid FreeVision drag positions.  A
    # rectangle whose right edge is exactly zero, however, has no intersection
    # at all and must be rejected without consuming the next sequence number.
    outside_rect = (-final_rect[2], final_rect[1],
                    final_rect[2], final_rect[3])
    rejected('fully off-desktop preview rectangle is rejected', 0,
             preview_payload(gesture, base_revision, 3,
                             PREVIEW_OP_BOUNDS, outside_rect))

    # Rejections must not consume sequence 3 or close/poison the valid owner.
    # X=-1 still intersects the desktop and is a legitimate drag preview.
    intersecting_rect = (-1, final_rect[1],
                         final_rect[2], final_rect[3])
    time.sleep(0.025)
    owner.sendall(raw_frame(
        FRAME_LAYOUT_PREVIEW, 0,
        preview_payload(gesture, base_revision, 3,
                        PREVIEW_OP_BOUNDS, intersecting_rect)))
    resumed = preview_events(collect(observer, 0.50))
    check('intersecting negative preview relays after rejections',
          resumed == [(0, {
              'gesture': gesture, 'revision': base_revision, 'seq': 3,
              'op': PREVIEW_OP_BOUNDS, 'rect': intersecting_rect})])
    check('owner still receives no resumed echo',
          preview_events(collect(owner, 0.20)) == [])

    probe, negative_snapshot = attach_wire(path)
    check('negative preview leaves canonical state unchanged',
          canonical_equal(negative_snapshot, baseline))
    collect(probe, 0.20)
    probe.sendall(raw_frame(FRAME_DETACH, -1))
    probe.close()
    probe = None
    collect(owner, 0.10)
    collect(observer, 0.10)

    owner.sendall(raw_frame(FRAME_LAYOUT_UNLOCK, 0))
    unlock_frames, clear_at, unlock_at = wait_for_unlock(
        observer, gesture, baseline)
    clears = [event for _pane, event in preview_events(unlock_frames)
              if event['gesture'] == gesture and
              event['op'] == PREVIEW_OP_CLEAR]
    check('unlock emits one ordered CLEAR rollback',
          len(clears) == 1 and clears[0]['seq'] > 3 and
          clears[0]['rect'] == (0, 0, 0, 0) and
          clear_at is not None and unlock_at is not None and
          clear_at < unlock_at)
    unlocked_layouts = [parse_layout(payload)
                        for kind, _pane, payload in unlock_frames
                        if kind == FRAME_LAYOUT_EV]
    check('unlock keeps canonical revision geometry and PTY metadata',
          any(layout['locked'] & 1 == 0 and
              layout['revision'] == base_revision and
              layout['geometry'] == baseline['geometry']
              for layout in unlocked_layouts))

    # Repeat with an abrupt owner loss. DropClient must perform the same
    # transient rollback and release the lease for another client.
    collect(owner, 0.10)
    collect(observer, 0.10)
    granted, reply_revision, _prefix = lock_layout(
        owner, 0, base_revision, 0x4C505202)
    check('owner reacquires lease for disconnect case',
          granted and reply_revision == base_revision)
    collect(observer, 0.30)
    disconnect_gesture = 0x5052455649455732
    owner.sendall(raw_frame(
        FRAME_LAYOUT_PREVIEW, 0,
        preview_payload(disconnect_gesture, base_revision, 1,
                        PREVIEW_OP_BOUNDS, bounds_rect)))
    before_drop = preview_events(collect(observer, 0.40))
    check('observer sees preview before owner disconnect',
          before_drop == [(0, {
              'gesture': disconnect_gesture,
              'revision': base_revision,
              'seq': 1,
              'op': PREVIEW_OP_BOUNDS,
              'rect': bounds_rect})])
    owner.close()
    owner = None
    drop_frames, drop_clear_at, drop_unlock_at = wait_for_unlock(
        observer, disconnect_gesture, baseline)
    drop_clears = [event for _pane, event in preview_events(drop_frames)
                   if event['gesture'] == disconnect_gesture and
                   event['op'] == PREVIEW_OP_CLEAR]
    check('owner disconnect emits one CLEAR rollback',
          len(drop_clears) == 1 and drop_clears[0]['seq'] > 1 and
          drop_clears[0]['rect'] == (0, 0, 0, 0) and
          drop_clear_at is not None and drop_unlock_at is not None and
          drop_clear_at < drop_unlock_at)

    probe, final_snapshot = attach_wire(path)
    stale_after_drop = preview_events(collect(probe, 0.35))
    check('disconnect preserves canonical state and clears preview',
          canonical_equal(final_snapshot, baseline) and
          final_snapshot['locked'] & 1 == 0 and
          stale_after_drop == [])

    pty_rc, final_pty = actual_pty_size(HOME, session, 'final')
    collect(observer, 0.15)
    collect(probe, 0.15)
    check('unlock and disconnect never resize the real PTY',
          pty_rc == 0 and final_pty == baseline_pty)

    # Exercise the one exception to commit-as-END: a zoom contraction may
    # reserve a short cosmetic tail before committing. The commit releases
    # the lease and advances canonical state; only that same gesture may then
    # publish outline steps against the new revision.
    granted, reply_revision, _prefix = lock_layout(
        observer, 0, base_revision, 0x4C505203)
    check('disconnect leaves pane lease acquirable for tail',
          granted and reply_revision == base_revision)
    tail_lock_frames = collect(probe, 0.30)
    check('tail observer sees acquired pane lease',
          any(kind == FRAME_LAYOUT_EV and
              parse_layout(payload)['locked'] & 1 != 0
              for kind, _pane, payload in tail_lock_frames))

    tail_gesture = 0x505245565441494C
    tail_begin = {
        'gesture': tail_gesture, 'revision': base_revision, 'seq': 1,
        'op': PREVIEW_OP_TAIL_BEGIN, 'rect': (0, 0, 0, 0),
    }
    observer.sendall(raw_frame(
        FRAME_LAYOUT_PREVIEW, 0,
        preview_payload(tail_gesture, base_revision, 1,
                        PREVIEW_OP_TAIL_BEGIN)))
    check('TAIL_BEGIN relays exactly under the lease',
          preview_events(collect(probe, 0.30)) == [(0, tail_begin)])
    check('tail owner receives no TAIL_BEGIN echo',
          preview_events(collect(observer, 0.12)) == [])

    old_geom = baseline['geometry'][0]
    new_cols = max(4, final_rect[2] - 2)
    new_rows = max(2, final_rect[3] - 2)
    committed_pane = (*final_rect, new_cols, new_rows, *old_geom[6:])
    committed_geometry = list(baseline['geometry'])
    committed_geometry[0] = committed_pane
    committed_geometry = tuple(committed_geometry)
    observer.sendall(raw_frame(
        FRAME_LAYOUT, -1,
        layout_payload(baseline, committed_geometry, base_revision, 1)))
    committed_revision = base_revision + 1
    observer_commit_frames = collect(observer, 0.25)
    probe_commit_frames = collect(probe, 0.25)
    owner_commits = [parse_layout(payload)
                     for kind, _pane, payload in observer_commit_frames
                     if kind == FRAME_LAYOUT_EV]
    watcher_commits = [parse_layout(payload)
                       for kind, _pane, payload in probe_commit_frames
                       if kind == FRAME_LAYOUT_EV]
    check('tail commit advances one canonical pane revision',
          len(owner_commits) == 1 and len(watcher_commits) == 1 and
          owner_commits[0]['revision'] == committed_revision and
          watcher_commits[0]['revision'] == committed_revision and
          owner_commits[0]['geometry'] == committed_geometry and
          watcher_commits[0]['geometry'] == committed_geometry and
          owner_commits[0]['locked'] & 1 == 0 and
          watcher_commits[0]['locked'] & 1 == 0)

    tail_expected = [
        {'gesture': tail_gesture, 'revision': committed_revision, 'seq': 2,
         'op': PREVIEW_OP_OUTLINE_SHOW, 'rect': final_rect},
        {'gesture': tail_gesture, 'revision': committed_revision, 'seq': 3,
         'op': PREVIEW_OP_OUTLINE_HIDE, 'rect': final_rect},
        {'gesture': tail_gesture, 'revision': committed_revision, 'seq': 4,
         'op': PREVIEW_OP_TAIL_END, 'rect': (0, 0, 0, 0)},
    ]
    tail_wire = b''.join((
        raw_frame(FRAME_LAYOUT_PREVIEW, 0,
                  preview_payload(tail_gesture, committed_revision, 2,
                                  PREVIEW_OP_OUTLINE_SHOW, final_rect)),
        raw_frame(FRAME_LAYOUT_PREVIEW, 0,
                  preview_payload(tail_gesture, committed_revision, 3,
                                  PREVIEW_OP_OUTLINE_HIDE, final_rect)),
        raw_frame(FRAME_LAYOUT_PREVIEW, 0,
                  preview_payload(tail_gesture, committed_revision, 4,
                                  PREVIEW_OP_TAIL_END)),
    ))
    observer.sendall(tail_wire)
    check('authorized outline tail relays SHOW HIDE END in order',
          preview_events(collect(probe, 0.50)) ==
          [(0, event) for event in tail_expected])
    check('tail owner receives no outline echo',
          preview_events(collect(observer, 0.15)) == [])

    probe.sendall(raw_frame(FRAME_DETACH, -1))
    probe.close()
    probe = None
    collect(observer, 0.15)
    committed_baseline = dict(baseline)
    committed_baseline['revision'] = committed_revision
    committed_baseline['geometry'] = committed_geometry
    late, tail_snapshot = attach_wire(path)
    stale_after_tail = preview_events(collect(late, 0.35))
    check('attach after TAIL_END has canonical state and no stale preview',
          canonical_equal(tail_snapshot, committed_baseline) and
          tail_snapshot['locked'] & 1 == 0 and
          stale_after_tail == [])
    late.sendall(raw_frame(FRAME_DETACH, -1))
    late.close()
    late = None

    tail_pty_rc, tail_pty = actual_pty_size(HOME, session, 'tail-commit')
    collect(observer, 0.15)
    check('only tail commit changes the canonical PTY size',
          tail_pty_rc == 0 and tail_pty == (new_cols, new_rows))

    # Leave a second authorized tail unfinished. The daemon's periodic expiry
    # must pair its cosmetic CLEAR with the unchanged canonical layout on the
    # same socket. Clients deliberately defer CLEAR until that following
    # snapshot, so adjacency is what prevents a last-preview -> old -> final
    # flash when an Idle drain stops at its frame/time budget.
    probe, expiry_start = attach_wire(path)
    check('tail-expiry peer starts from committed canonical state',
          canonical_equal(expiry_start, committed_baseline) and
          expiry_start['locked'] & 1 == 0)
    collect(observer, 0.12)
    collect(probe, 0.12)
    granted, reply_revision, _prefix = lock_layout(
        observer, 0, committed_revision, 0x4C505204)
    check('owner acquires lease for expiring tail',
          granted and reply_revision == committed_revision)
    collect(probe, 0.25)

    expiry_gesture = 0x5052455645585052
    expiry_visual = bounds_rect
    observer.sendall(b''.join((
        raw_frame(FRAME_LAYOUT_PREVIEW, 0,
                  preview_payload(expiry_gesture, committed_revision, 1,
                                  PREVIEW_OP_BOUNDS, expiry_visual)),
        raw_frame(FRAME_LAYOUT_PREVIEW, 0,
                  preview_payload(expiry_gesture, committed_revision, 2,
                                  PREVIEW_OP_TAIL_BEGIN)),
    )))
    expiry_prefix = preview_events(collect(probe, 0.40))
    check('unfinished tail relays visual then TAIL_BEGIN exactly',
          expiry_prefix == [
              (0, {'gesture': expiry_gesture,
                   'revision': committed_revision, 'seq': 1,
                   'op': PREVIEW_OP_BOUNDS, 'rect': expiry_visual}),
              (0, {'gesture': expiry_gesture,
                   'revision': committed_revision, 'seq': 2,
                   'op': PREVIEW_OP_TAIL_BEGIN, 'rect': (0, 0, 0, 0)}),
          ])

    expiry_cols = max(4, expiry_visual[2] - 2)
    expiry_rows = max(2, expiry_visual[3] - 2)
    expiry_pane = (*expiry_visual, expiry_cols, expiry_rows,
                   *committed_pane[6:])
    expiry_geometry = list(committed_geometry)
    expiry_geometry[0] = expiry_pane
    expiry_geometry = tuple(expiry_geometry)
    observer.sendall(raw_frame(
        FRAME_LAYOUT, -1,
        layout_payload(committed_baseline, expiry_geometry,
                       committed_revision, 1)))
    expiry_revision = committed_revision + 1
    expiry_owner_commit = collect(observer, 0.25)
    expiry_watcher_commit = collect(probe, 0.25)
    check('unfinished tail commit advances exactly one revision',
          any(kind == FRAME_LAYOUT_EV and
              parse_layout(payload)['revision'] == expiry_revision and
              parse_layout(payload)['geometry'] == expiry_geometry and
              parse_layout(payload)['locked'] & 1 == 0
              for kind, _pane, payload in expiry_owner_commit) and
          any(kind == FRAME_LAYOUT_EV and
              parse_layout(payload)['revision'] == expiry_revision and
              parse_layout(payload)['geometry'] == expiry_geometry and
              parse_layout(payload)['locked'] & 1 == 0
              for kind, _pane, payload in expiry_watcher_commit))

    expiry_baseline = dict(committed_baseline)
    expiry_baseline['revision'] = expiry_revision
    expiry_baseline['geometry'] = expiry_geometry
    expiry_frames, expiry_clear_at, expiry_layout_at = wait_for_unlock(
        probe, expiry_gesture, expiry_baseline, timeout=4.0)
    expiry_clears = [event for _pane, event in preview_events(expiry_frames)
                     if event['gesture'] == expiry_gesture and
                     event['op'] == PREVIEW_OP_CLEAR]
    check('tail timeout emits one CLEAR immediately followed by canonical',
          len(expiry_clears) == 1 and expiry_clears[0]['seq'] > 2 and
          expiry_clear_at is not None and expiry_layout_at is not None and
          expiry_layout_at == expiry_clear_at + 1)
    expiry_layouts = [parse_layout(payload)
                      for kind, _pane, payload in expiry_frames
                      if kind == FRAME_LAYOUT_EV]
    check('tail timeout preserves final revision geometry and unlocked state',
          len(expiry_layouts) == 1 and
          expiry_layouts[0]['revision'] == expiry_revision and
          expiry_layouts[0]['geometry'] == expiry_geometry and
          expiry_layouts[0]['locked'] & 1 == 0)
    check('tail owner receives no reflected timeout preview',
          preview_events(collect(observer, 0.20)) == [])

    late, expired_snapshot = attach_wire(path)
    expired_replay = preview_events(collect(late, 0.35))
    check('attach after tail timeout receives no stale preview',
          canonical_equal(expired_snapshot, expiry_baseline) and
          expired_snapshot['locked'] & 1 == 0 and expired_replay == [])
    late.sendall(raw_frame(FRAME_DETACH, -1))
    late.close()
    late = None
    probe.sendall(raw_frame(FRAME_DETACH, -1))
    probe.close()
    probe = None

    expiry_pty_rc, expiry_pty = actual_pty_size(
        HOME, session, 'tail-expiry')
    collect(observer, 0.15)
    if expiry_pty_rc != 0 or expiry_pty != (expiry_cols, expiry_rows):
        print('  tail-expiry PTY expected/actual:',
              (expiry_cols, expiry_rows), expiry_pty,
              'cli-returncode=', expiry_pty_rc)
    check('tail timeout never changes the committed PTY size',
          expiry_pty_rc == 0 and
          expiry_pty == (expiry_cols, expiry_rows))
finally:
    if late is not None:
        try:
            late.sendall(raw_frame(FRAME_DETACH, -1))
        except OSError:
            pass
        late.close()
    if probe is not None:
        try:
            probe.sendall(raw_frame(FRAME_DETACH, -1))
        except OSError:
            pass
        probe.close()
    if owner is not None:
        try:
            owner.sendall(raw_frame(FRAME_LAYOUT_UNLOCK, -1))
            owner.sendall(raw_frame(FRAME_DETACH, -1))
        except OSError:
            pass
        owner.close()
    if observer is not None:
        try:
            observer.sendall(raw_frame(FRAME_LAYOUT_UNLOCK, -1))
            observer.sendall(raw_frame(FRAME_DETACH, -1))
        except OSError:
            pass
        observer.close()
    if creator is not None:
        creator.close()
    stlib.close_all_daemons(HOME)

stlib.report()
