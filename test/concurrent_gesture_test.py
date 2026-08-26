#!/usr/bin/env python3
"""Two independent held gestures merge without a visual or canonical rollback.

There are deliberately two complementary oracles here.  The raw protocol
half gives pane 0 and pane 1 to different owners at the same base revision and
checks protocol-v15's viewer-relative ``FRAME_LAYOUT_PEER_EV`` masks.  The
physical half repeats the race with two real mouse actors and a third viewer,
capturing every DEC-2026 presentation.  Releasing either mouse first must not
move the other held pane back for even one rendered frame; its next one-cell
motion must still be accepted before the second commit merges at base+2.

Both release orders run with live-content and wireframe dragging.  This is a
temporal regression test: checking only the final layout would miss the exact
``final -> old -> final`` flash which motivated protocol v15.
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


WIDTH, HEIGHT = 110, 34
TITLES = ('CONCURRENT_PANE_ZERO', 'CONCURRENT_PANE_ONE')

FRAME_ATTACH = 1
FRAME_DETACH = 4
FRAME_LAYOUT = 7
FRAME_LAYOUT_LOCK = 17
FRAME_SESSION = 20
FRAME_SCREEN = 21
FRAME_READY = 22
FRAME_LAYOUT_EV = 26
FRAME_LAYOUT_LOCK_REPLY = 33
FRAME_LAYOUT_PREVIEW = 35
FRAME_LAYOUT_PREVIEW_EV = 36
FRAME_LAYOUT_PEER_EV = 37

PREVIEW_OP_BOUNDS = 1
PREVIEW_OP_WIREFRAME = 2
PREVIEW_OP_CLEAR = 7
PREVIEW_FORMAT = '<QQQB3xiiii'
PREVIEW_SIZE = struct.calcsize(PREVIEW_FORMAT)

FRAME_CTL_LIST = 11
FRAME_CTL_DATA = 42
FRAME_CTL_END = 43
FRAME_LEFT = ('╔', '┌', '░', '▒', '▓')
FRAME_RIGHT = ('╗', '┐', '░', '▒', '▓')
SHADE = frozenset(('░', '▒', '▓'))
CLEAR_RE = re.compile(br'\x1b\[[0-?]*[ -/]*J|\x1bc|\x1b#8')


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
    return struct.unpack_from(fmt, payload, offset), offset + size


def pas_string(payload, offset):
    (length,), offset = unpack_from('<i', payload, offset)
    if length < 0 or offset + length > len(payload):
        raise ValueError('invalid Pascal string')
    value = payload[offset:offset + length].decode('utf-8', 'replace')
    return value, offset + length


def pane_geom(payload, offset):
    return unpack_from('<iiiiiiBBB', payload, offset)


def parse_snapshot(payload):
    """Strictly decode the canonical portion of FRAME_SESSION."""
    nodes, offset = pas_string(payload, 0)
    (focused, count), offset = unpack_from('<ii', payload, offset)
    titles = []
    terms = []
    for _pane in range(count):
        title, offset = pas_string(payload, offset)
        term, offset = pas_string(payload, offset)
        titles.append(title)
        terms.append(term)
    session, offset = pas_string(payload, offset)
    profile, offset = pas_string(payload, offset)
    (geom_count, desk_w, desk_h), offset = unpack_from('<iii', payload,
                                                       offset)
    geometry = []
    for _pane in range(geom_count):
        geom, offset = pane_geom(payload, offset)
        geometry.append(geom)
    (proto, reserved), offset = unpack_from('<ii', payload, offset)
    (revision,), offset = unpack_from('<Q', payload, offset)
    (clients,), offset = unpack_from('<i', payload, offset)
    (locked,), offset = unpack_from('<I', payload, offset)
    (min_w, min_h, hosts_match), offset = unpack_from('<iii', payload,
                                                       offset)
    if geom_count != count or offset != len(payload):
        raise ValueError('invalid FRAME_SESSION tail')
    return {
        'nodes': nodes, 'focused': focused, 'count': count,
        'titles': tuple(titles), 'terms': tuple(terms),
        'session': session, 'profile': profile,
        'desk': (desk_w, desk_h), 'geometry': tuple(geometry),
        'proto': proto, 'reserved': reserved, 'revision': revision,
        'clients': clients, 'changes': 0, 'locked': locked,
        'host': (min_w, min_h, hosts_match),
    }


def parse_layout(payload):
    """Strictly decode both LAYOUT_EV and its v15 PEER_EV twin."""
    nodes, offset = pas_string(payload, 0)
    (focused, count), offset = unpack_from('<ii', payload, offset)
    titles = []
    for _pane in range(count):
        title, offset = pas_string(payload, offset)
        titles.append(title)
    (desk_w, desk_h), offset = unpack_from('<ii', payload, offset)
    geometry = []
    for _pane in range(count):
        geom, offset = pane_geom(payload, offset)
        geometry.append(geom)
    (revision,), offset = unpack_from('<Q', payload, offset)
    (clients,), offset = unpack_from('<i', payload, offset)
    (changes, locked), offset = unpack_from('<II', payload, offset)
    (min_w, min_h, hosts_match), offset = unpack_from('<iii', payload,
                                                       offset)
    if offset != len(payload):
        raise ValueError('invalid layout event tail')
    return {
        'nodes': nodes, 'focused': focused, 'count': count,
        'titles': tuple(titles), 'desk': (desk_w, desk_h),
        'geometry': tuple(geometry), 'revision': revision,
        'clients': clients, 'changes': changes, 'locked': locked,
        'host': (min_w, min_h, hosts_match),
    }


def parse_preview(payload):
    if len(payload) != PREVIEW_SIZE:
        raise ValueError('invalid layout preview size')
    gesture, revision, seq, op, x, y, width, height = struct.unpack(
        PREVIEW_FORMAT, payload)
    return {
        'gesture': gesture, 'revision': revision, 'seq': seq, 'op': op,
        'rect': (x, y, width, height),
    }


def preview_payload(gesture, revision, seq, op, rect):
    return struct.pack(PREVIEW_FORMAT, gesture, revision, seq, op, *rect)


def pas_blob(value):
    encoded = value.encode('utf-8')
    return struct.pack('<i', len(encoded)) + encoded


def layout_payload(snapshot, geometry, revision, changes):
    payload = bytearray(pas_blob(snapshot['nodes']))
    payload += struct.pack('<ii', snapshot['focused'], len(geometry))
    for title in snapshot['titles']:
        payload += pas_blob(title)
    payload += struct.pack('<ii', *snapshot['desk'])
    for geom in geometry:
        payload += struct.pack('<iiiiiiBBB', *geom)
    # Client count is compatibility metadata and locks are never proposed.
    payload += struct.pack('<QiI', revision, 0, changes)
    return bytes(payload)


def collect(peer, seconds=0.30):
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


def drain_wire(peers, seconds=0.20):
    result = [[] for _peer in peers]
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for index, peer in enumerate(peers):
            result[index].extend(collect(peer, 0.025))
    return result


def layout_events(frames):
    return [(kind, parse_layout(payload))
            for kind, _pane, payload in frames
            if kind in (FRAME_LAYOUT_EV, FRAME_LAYOUT_PEER_EV)]


def preview_events(frames):
    return [(pane, parse_preview(payload))
            for kind, pane, payload in frames
            if kind == FRAME_LAYOUT_PREVIEW_EV]


def same_preview_wave(actual, expected):
    """Compare cross-socket arrivals without inventing their global order.

    Unix socket order is strict per sender, while the reactor decides which
    ready client it observes first.  The test must require every event exactly
    once and increasing sequence per pane, but must not claim that Python's
    two successive ``sendall`` calls define arrival order across sockets.
    """
    def key(item):
        pane, event = item
        return (pane, event['gesture'], event['revision'], event['seq'],
                event['op'], event['rect'])

    if sorted(map(key, actual)) != sorted(map(key, expected)):
        return False
    for pane in range(2):
        seqs = [event['seq'] for event_pane, event in actual
                if event_pane == pane]
        if seqs != sorted(seqs) or len(seqs) != len(set(seqs)):
            return False
    return True


def attach_wire(path):
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.settimeout(5.0)
    peer.connect(path)
    peer.sendall(raw_frame(
        FRAME_ATTACH, -1,
        struct.pack('<iiiii', PROTO_VER, WIDTH, HEIGHT, 1, 0)))
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
            raise RuntimeError('unexpected attach frame ' + str(frame[0]))
        screens += 1
    if screens != snapshot['count']:
        peer.close()
        raise RuntimeError('snapshot screen count mismatch')
    return peer, snapshot


def lock_layout(peer, pane, revision, request_id):
    peer.sendall(raw_frame(
        FRAME_LAYOUT_LOCK, pane, struct.pack('<QQ', request_id, revision)))
    preceding = []
    deadline = time.monotonic() + 4.0
    while time.monotonic() < deadline:
        frame = read_frame(peer, timeout=0.5)
        if frame is None:
            break
        if frame[0] != FRAME_LAYOUT_LOCK_REPLY:
            preceding.append(frame)
            continue
        payload = frame[2]
        if len(payload) != 17:
            break
        reply_id = struct.unpack_from('<Q', payload)[0]
        if reply_id != request_id:
            continue
        granted = payload[8] != 0
        reply_revision = struct.unpack_from('<Q', payload, 9)[0]
        return granted, reply_revision, preceding
    return False, 0, preceding


def one_layout(label, frames, kind, revision, geometry, changes, locked):
    events = layout_events(frames)
    expected = [(event_kind, layout) for event_kind, layout in events
                if (event_kind == kind and layout['revision'] == revision and
                    layout['geometry'] == geometry and
                    layout['changes'] == changes and
                    layout['locked'] == locked)]
    if len(events) != 1 or len(expected) != 1:
        print('  ' + label + ' layout events:', [
            (event_kind, item['revision'], item['changes'], item['locked'],
             item['geometry']) for event_kind, item in events])
    check(label, len(events) == 1 and len(expected) == 1)
    return events[0][1] if len(events) == 1 else None


def ordered_clear_before_layout(frames, gesture, kind):
    clear_at = []
    layout_at = []
    wrong_clears = []
    for index, (frame_kind, _pane, payload) in enumerate(frames):
        if frame_kind == FRAME_LAYOUT_PREVIEW_EV:
            preview = parse_preview(payload)
            if preview['op'] == PREVIEW_OP_CLEAR:
                if preview['gesture'] == gesture:
                    clear_at.append(index)
                else:
                    wrong_clears.append(preview['gesture'])
        elif frame_kind == kind:
            layout_at.append(index)
    return (len(clear_at) == 1 and len(layout_at) == 1 and
            clear_at[0] < layout_at[0] and not wrong_clears)


def resized_geometry(geometry, pane, dw):
    result = list(geometry)
    geom = list(result[pane])
    geom[2] += dw
    geom[4] += dw
    result[pane] = tuple(geom)
    return tuple(result)


def with_two_resizes(geometry, dw0, dw1):
    return resized_geometry(resized_geometry(geometry, 0, dw0), 1, dw1)


def zoomed_geometry(snapshot, pane):
    """One exact normal maximum for the equal-host raw fixture."""
    result = [list(geom) for geom in snapshot['geometry']]
    safe_w = min(snapshot['desk'][0], WIDTH)
    safe_h = min(snapshot['desk'][1], HEIGHT - 2)
    result[pane][4] = max(14, safe_w - 2)
    result[pane][5] = max(4, safe_h - 2)
    result[pane][6] = 1
    result[pane][7] = 0
    result[pane][8] = 0
    return tuple(tuple(geom) for geom in result)


def actual_pty_sizes(home, session, tag):
    values = []
    for pane in range(2):
        path = os.path.join(home, f'pty-{tag}-{pane}')
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        result = run_cli(
            ['send', f'{session}:{pane + 1}',
             "stty size > '" + path + "'"], home, env={'LANG': 'C'})
        value = None
        deadline = time.monotonic() + 4.0
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
        values.append(value if result.returncode == 0 else None)
    return tuple(values)


def create_two_panes(home, session, env):
    creator = stlib.Client(home, args=['--session', session], w=WIDTH,
                           h=HEIGHT, lang='en', env=env)
    try:
        creator.drain(2.0)
        creator.send(b'\x1bOQ', 0.9)  # F2: second pane
        creator.send(b'\x11', 0.08)
        creator.send(b't', 0.8)       # deterministic side-by-side layout
        for pane, title in enumerate(TITLES, 1):
            run_cli(['rename', f'{session}:{pane}', title], home, env=env)
        creator.drain(0.8)
        creator.send(b'\x11', 0.08)
        creator.send(b'd', 0.35)
        creator.wait_exit(timeout=6.0)
    finally:
        creator.close()
    sockets = stlib.session_sockets(home)
    return sockets[0] if len(sockets) == 1 else ''


def raw_scenario(peers, baseline, home, session, first, op, serial):
    """Hold both raw leases, then merge their stale-base proposals."""
    actors = peers[:2]
    observer = peers[2]
    other = 1 - first
    base_revision = baseline['revision']
    base_geometry = baseline['geometry']
    bits = (1, 2)
    label = f'raw {"bounds" if op == PREVIEW_OP_BOUNDS else "wire"} '
    label += f'{first}->{other}'
    drain_wire(peers, 0.15)

    # Both locks are granted at one base revision.  Each owner sees the other
    # owner's bit but never its own; the neutral viewer sees both.
    granted0, revision0, prefix0 = lock_layout(
        actors[0], 0, base_revision, 0x43470000 + serial * 16)
    lock0 = [prefix0 + collect(actors[0], 0.20),
             collect(actors[1], 0.25), collect(observer, 0.25)]
    check(label + ' first lock granted',
          granted0 and revision0 == base_revision)
    one_layout(label + ' first owner preserve mask', lock0[0],
               FRAME_LAYOUT_PEER_EV, base_revision, base_geometry, bits[0], 0)
    for viewer in (1, 2):
        one_layout(label + f' first lock viewer {viewer}', lock0[viewer],
                   FRAME_LAYOUT_EV, base_revision, base_geometry, 0, bits[0])

    granted1, revision1, prefix1 = lock_layout(
        actors[1], 1, base_revision, 0x43470001 + serial * 16)
    lock1 = [collect(actors[0], 0.25),
             prefix1 + collect(actors[1], 0.20), collect(observer, 0.25)]
    check(label + ' second lock granted',
          granted1 and revision1 == base_revision)
    one_layout(label + ' actor0 relative locks', lock1[0],
               FRAME_LAYOUT_PEER_EV, base_revision, base_geometry, bits[0],
               bits[1])
    one_layout(label + ' actor1 relative locks', lock1[1],
               FRAME_LAYOUT_PEER_EV, base_revision, base_geometry, bits[1],
               bits[0])
    one_layout(label + ' observer sees both locks', lock1[2],
               FRAME_LAYOUT_EV, base_revision, base_geometry, 0,
               bits[0] | bits[1])

    gesture = (0x434F4E4300000000 + serial * 2,
               0x434F4E4300000001 + serial * 2)
    step = (resized_geometry(base_geometry, 0, -1)[0][:4],
            resized_geometry(base_geometry, 1, -1)[1][:4])
    final_rect = (resized_geometry(base_geometry, 0, -2)[0][:4],
                  resized_geometry(base_geometry, 1, -2)[1][:4])
    expected_first_wave = []
    for pane in range(2):
        actors[pane].sendall(raw_frame(
            FRAME_LAYOUT_PREVIEW, pane,
            preview_payload(gesture[pane], base_revision, 1, op,
                            step[pane])))
        expected_first_wave.append((pane, {
            'gesture': gesture[pane], 'revision': base_revision, 'seq': 1,
            'op': op, 'rect': step[pane],
        }))
    actors[first].sendall(raw_frame(
        FRAME_LAYOUT_PREVIEW, first,
        preview_payload(gesture[first], base_revision, 2, op,
                        final_rect[first])))
    expected_first_wave.append((first, {
        'gesture': gesture[first], 'revision': base_revision, 'seq': 2,
        'op': op, 'rect': final_rect[first],
    }))
    wave = [collect(peer, 0.45) for peer in peers]
    actor0_expected = [event for event in expected_first_wave
                       if event[0] != 0]
    actor1_expected = [event for event in expected_first_wave
                       if event[0] != 1]
    check(label + ' actor0 sees only peer preview',
          preview_events(wave[0]) == actor0_expected)
    check(label + ' actor1 sees only peer preview',
          preview_events(wave[1]) == actor1_expected)
    check(label + ' observer sees every interleaved preview once',
          same_preview_wave(preview_events(wave[2]), expected_first_wave))

    first_geometry = resized_geometry(base_geometry, first, -2)
    actors[first].sendall(raw_frame(
        FRAME_LAYOUT, -1,
        layout_payload(baseline, first_geometry, base_revision, bits[first])))
    released = [collect(peer, 0.65) for peer in peers]
    for viewer in range(3):
        expected_kind = (FRAME_LAYOUT_PEER_EV if viewer == other else
                         FRAME_LAYOUT_EV)
        expected_changes = bits[other] if viewer == other else 0
        expected_locks = 0 if viewer == other else bits[other]
        one_layout(label + f' first release viewer {viewer}', released[viewer],
                   expected_kind, base_revision + 1, first_geometry,
                   expected_changes, expected_locks)
    check(label + ' first owner has no self CLEAR',
          all(event['op'] != PREVIEW_OP_CLEAR
              for _pane, event in preview_events(released[first])))
    for viewer in (other, 2):
        expected_kind = (FRAME_LAYOUT_PEER_EV if viewer == other else
                         FRAME_LAYOUT_EV)
        check(label + f' ordered first CLEAR viewer {viewer}',
              ordered_clear_before_layout(released[viewer], gesture[first],
                                          expected_kind))
    check(label + ' other preview is not cleared',
          all(not (event['gesture'] == gesture[other] and
                   event['op'] == PREVIEW_OP_CLEAR)
              for frames in released for _pane, event in preview_events(frames)))

    # The surviving lease intentionally keeps its old base revision.  One
    # later step is the decisive witness that PEER_EV did not invalidate it.
    actors[other].sendall(raw_frame(
        FRAME_LAYOUT_PREVIEW, other,
        preview_payload(gesture[other], base_revision, 2, op,
                        final_rect[other])))
    continued = [collect(peer, 0.40) for peer in peers]
    expected_continued = [(other, {
        'gesture': gesture[other], 'revision': base_revision, 'seq': 2,
        'op': op, 'rect': final_rect[other],
    })]
    check(label + ' released actor sees remaining next step',
          preview_events(continued[first]) == expected_continued)
    check(label + ' remaining actor still gets no echo',
          preview_events(continued[other]) == [])
    check(label + ' observer sees remaining next step',
          preview_events(continued[2]) == expected_continued)

    final_geometry = with_two_resizes(base_geometry, -2, -2)
    actors[other].sendall(raw_frame(
        FRAME_LAYOUT, -1,
        layout_payload(baseline, final_geometry, base_revision, bits[other])))
    settled = [collect(peer, 0.65) for peer in peers]
    final_layouts = []
    for viewer in range(3):
        final_layouts.append(one_layout(
            label + f' final viewer {viewer}', settled[viewer],
            FRAME_LAYOUT_EV, base_revision + 2, final_geometry, 0, 0))
    check(label + ' all three canonical layouts are byte-equivalent',
          all(item == final_layouts[0] for item in final_layouts[1:]) and
          final_layouts[0] is not None)
    check(label + ' second owner has no self CLEAR',
          all(event['op'] != PREVIEW_OP_CLEAR
              for _pane, event in preview_events(settled[other])))
    for viewer in (first, 2):
        check(label + f' ordered second CLEAR viewer {viewer}',
              ordered_clear_before_layout(settled[viewer], gesture[other],
                                          FRAME_LAYOUT_EV))

    expected_ptys = tuple((geom[4], geom[5]) for geom in final_geometry)
    ptys = actual_pty_sizes(home, session, f'{serial}')
    check(label + ' canonical PTYs match both final geometries',
          ptys == expected_ptys)
    drain_wire(peers, 0.15)
    result = dict(baseline)
    result['revision'] = base_revision + 2
    result['geometry'] = final_geometry
    result['locked'] = 0
    result['changes'] = 0
    return result


def raw_zoom_handoff(peers, baseline, home, session):
    """Two per-pane leases enter zoom from one base; the second wins safely.

    CLI zoom deliberately uses the global lease, so it cannot exercise the
    daemon's stale per-pane merge. These protocol actors each own only their
    pane. The second commit must auto-restore the already-released first
    winner inside the same reactor transaction, never expose two Z flags, and
    restore the loser's PTY from its canonical BW/BH.
    """
    label = 'raw concurrent zoom hand-off'
    bits = (1, 2)
    base_revision = baseline['revision']
    drain_wire(peers, 0.20)
    granted0, revision0, _prefix0 = lock_layout(
        peers[0], 0, base_revision, 0x5A4F4F4D0001)
    granted1, revision1, _prefix1 = lock_layout(
        peers[1], 1, base_revision, 0x5A4F4F4D0002)
    drain_wire(peers, 0.30)
    check(label + ' grants both per-pane leases at one base',
          granted0 and granted1 and
          revision0 == base_revision and revision1 == base_revision)

    first_geometry = zoomed_geometry(baseline, 0)
    peers[0].sendall(raw_frame(
        FRAME_LAYOUT, -1,
        layout_payload(baseline, first_geometry, base_revision, bits[0])))
    first_frames = [collect(peer, 0.65) for peer in peers]
    first_layouts = []
    for viewer in range(3):
        expected_kind = (FRAME_LAYOUT_PEER_EV if viewer == 1 else
                         FRAME_LAYOUT_EV)
        expected_changes = bits[1] if viewer == 1 else 0
        expected_locks = 0 if viewer == 1 else bits[1]
        first_layouts.append(one_layout(
            label + f' first winner viewer {viewer}', first_frames[viewer],
            expected_kind, base_revision + 1, first_geometry,
            expected_changes, expected_locks))
    check(label + ' first commit contains exactly one Z',
          all(layout is not None and
              sum(geom[6] != 0 for geom in layout['geometry']) == 1
              for layout in first_layouts))

    # Actor 1 intentionally submits its old-base view: pane 0 is normal in
    # this payload and is not in the change mask. The daemon must merge pane 1
    # into current state and restore the prior winner itself.
    final_geometry = zoomed_geometry(baseline, 1)
    peers[1].sendall(raw_frame(
        FRAME_LAYOUT, -1,
        layout_payload(baseline, final_geometry, base_revision, bits[1])))
    final_frames = [collect(peer, 0.65) for peer in peers]
    final_layouts = [
        one_layout(label + f' final winner viewer {viewer}',
                   final_frames[viewer], FRAME_LAYOUT_EV,
                   base_revision + 2, final_geometry, 0, 0)
        for viewer in range(3)
    ]
    check(label + ' atomically leaves only the second Z',
          all(layout is not None and
              tuple(index for index, geom in enumerate(layout['geometry'])
                    if geom[6] != 0) == (1,)
              for layout in final_layouts))
    check(label + ' restores loser PTY and installs exact winner PTY',
          actual_pty_sizes(home, session, 'zoom-handoff') ==
          tuple((geom[4], geom[5]) for geom in final_geometry))

    result = dict(baseline)
    result['revision'] = base_revision + 2
    result['geometry'] = final_geometry
    result['locked'] = 0
    result['changes'] = 0
    drain_wire(peers, 0.15)
    return result


def run_raw_protocol():
    home = stlib.fresh_home('concurrent-gesture-protocol')
    ini = home + '/.superterm/superterm.ini'
    with open(ini, 'w', encoding='utf-8') as stream:
        stream.write('[ui]\nlanguage=en\nbackground=none\n'
                     '[session]\nserver=always\nautosave=0\n'
                     'autorestore=0\nzoomanim=0\n')
    session = 'concurrent-gesture-protocol'
    peers = []
    try:
        path = create_two_panes(home, session, {})
        check('raw protocol v15 fixture exists', bool(path) and PROTO_VER >= 15)
        snapshots = []
        if path:
            for _viewer in range(3):
                peer, snapshot = attach_wire(path)
                peers.append(peer)
                snapshots.append(snapshot)
        drain_wire(peers, 0.30)
        check('raw actors and observer attach to two panes',
              len(snapshots) == 3 and
              all(snapshot['count'] == 2 for snapshot in snapshots))
        check('raw peers start from one identical unlocked revision',
              len(snapshots) == 3 and
              all(snapshot['revision'] == snapshots[0]['revision'] and
                  snapshot['geometry'] == snapshots[0]['geometry'] and
                  snapshot['locked'] == 0 for snapshot in snapshots))
        if len(snapshots) == 3:
            baseline = snapshots[0]
            baseline = raw_scenario(peers, baseline, home, session, 1,
                                    PREVIEW_OP_BOUNDS, 1)
            baseline = raw_scenario(peers, baseline, home, session, 0,
                                    PREVIEW_OP_WIREFRAME, 2)
            baseline = raw_zoom_handoff(peers, baseline, home, session)
            late, late_snapshot = attach_wire(path)
            try:
                replay = preview_events(collect(late, 0.35))
                check('late viewer gets final canonical state without previews',
                      late_snapshot['revision'] == baseline['revision'] and
                      late_snapshot['geometry'] == baseline['geometry'] and
                      late_snapshot['locked'] == 0 and replay == [])
            finally:
                late.sendall(raw_frame(FRAME_DETACH, -1))
                late.close()
    finally:
        for peer in peers:
            try:
                peer.sendall(raw_frame(FRAME_DETACH, -1))
            except OSError:
                pass
            peer.close()
        stlib.close_all_daemons(home)


# ---------------------------------------------------------------- physical UI

def display_of(value):
    return value['display'] if isinstance(value, dict) else value.screen.display


def cells_of(value):
    if isinstance(value, dict):
        return value['cells']
    return tuple(tuple(value.screen.buffer[y][x] for x in range(value.w))
                 for y in range(value.h))


def title_top(value, title):
    rows = display_of(value)
    for top, row in enumerate(rows):
        title_x = row.find(title)
        if title_x < 0:
            continue
        lefts = [x for x, char in enumerate(row[:title_x])
                 if char in FRAME_LEFT]
        rights = [x for x, char in enumerate(row[title_x + len(title):],
                  title_x + len(title)) if char in FRAME_RIGHT]
        if lefts and rights:
            return max(lefts), top, min(rights)
    return None


def frame_rect(value, title):
    bounds = title_top(value, title)
    if bounds is None:
        return None
    left, top, right = bounds
    rows = display_of(value)
    for bottom in range(top + 2, len(rows)):
        if (rows[bottom][left] in ('╚', '└') and
                rows[bottom][right] in ('╝', '┘')):
            return left, top, right, bottom
    return None


def pane_locked(value, title):
    bounds = title_top(value, title)
    if bounds is None:
        return False
    left, top, right = bounds
    cells = cells_of(value)
    if (cells[top][left].data in SHADE or
            cells[top][right].data in SHADE or
            ' LOCK ' in display_of(value)[top]):
        return True
    for y in range(top, min(len(cells), top + 20)):
        if ''.join(cells[y + step][left].data
                   for step in range(min(4, len(cells) - y))) == 'LOCK':
            return True
    return False


def perimeter(rect, locked=False):
    left, top, right, bottom = rect
    expected = {}
    for x in range(left + 1, right):
        expected[(x, top)] = '░' if locked else '─'
        expected[(x, bottom)] = '░' if locked else '─'
    for y in range(top + 1, bottom):
        expected[(left, y)] = '▒' if locked else '│'
        expected[(right, y)] = '▒' if locked else '│'
    if locked:
        height = bottom - top + 1
        start = max(1, (height - len('LOCK')) // 2)
        for offset, char in enumerate('LOCK'):
            if top + start + offset < bottom:
                expected[(left, top + start + offset)] = char
        for point in ((left, top), (right, top),
                      (left, bottom), (right, bottom)):
            expected[point] = '▒'
    else:
        expected[(left, top)] = '┌'
        expected[(right, top)] = '┐'
        expected[(left, bottom)] = '└'
        expected[(right, bottom)] = '┘'
    return expected


def complete_ring(value, rect, locked=False):
    cells = cells_of(value)
    height = len(cells)
    width = len(cells[0]) if height else 0
    return all(0 <= x < width and 0 <= y < height and
               cells[y][x].data == glyph
               for (x, y), glyph in perimeter(rect, locked).items())


def snapshot(client):
    return {'kind': 'sample', 'display': tuple(client.screen.display),
            'cells': cells_of(client), 'before_cells': None,
            'changed_cells': 0, 'raw': b''}


def drain_all(clients, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.025)


def control(args, home, env, attempts=30):
    last = None
    for _attempt in range(attempts):
        last = run_cli(args, home, env=env)
        if last.returncode == 0:
            return last
        if 'busy' not in (last.stdout + last.stderr).lower():
            return last
        time.sleep(0.05)
    return last


def daemon_state(path):
    """Strict CTL_LIST geometry and PTY oracle without another UI attach."""
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.settimeout(3.0)
    try:
        peer.connect(path)
        peer.sendall(raw_frame(FRAME_CTL_LIST, -1))
        payload = None
        while True:
            frame = read_frame(peer, timeout=3.0)
            if frame is None or frame[0] == FRAME_CTL_END:
                break
            if frame[0] == FRAME_CTL_DATA:
                payload = frame[2]
    except OSError:
        return None
    finally:
        peer.close()
    if payload is None:
        return None
    try:
        offset = 0
        _name, offset = pas_string(payload, offset)
        _profile, offset = pas_string(payload, offset)
        (count, focused, clients, desk_w, desk_h), offset = unpack_from(
            '<iiiii', payload, offset)
        panes = []
        for _pane in range(count):
            title, offset = pas_string(payload, offset)
            term, offset = pas_string(payload, offset)
            if offset >= len(payload):
                raise ValueError('missing pane kind')
            kind = payload[offset]
            offset += 1
            host, offset = pas_string(payload, offset)
            user, offset = pas_string(payload, offset)
            command, offset = pas_string(payload, offset)
            cwd, offset = pas_string(payload, offset)
            values, offset = unpack_from('<iiiiiii', payload, offset)
            cols, rows, history, bx, by, bw, bh = values
            flags, offset = unpack_from('<BBB', payload, offset)
            panes.append({
                'title': title, 'term': term, 'kind': kind,
                'host': host, 'user': user, 'command': command, 'cwd': cwd,
                'pty': (cols, rows), 'history': history,
                'geom': (bx, by, bw, bh), 'flags': flags,
            })
        if offset != len(payload):
            return None
        return {'count': count, 'focused': focused, 'clients': clients,
                'desk': (desk_w, desk_h), 'panes': panes}
    except (IndexError, struct.error, ValueError):
        return None


def mouse_down(client, x, y):
    os.write(client.fd, f'\x1b[<0;{x + 1};{y + 1}M'.encode())


def mouse_drag(client, x, y):
    os.write(client.fd, f'\x1b[<32;{x + 1};{y + 1}M'.encode())


def mouse_up(client, x, y):
    os.write(client.fd, f'\x1b[<0;{x + 1};{y + 1}m'.encode())


def physical_preview_ok(value, pane, rect, own, wireframe):
    title = TITLES[pane]
    if wireframe:
        return (title_top(value, title) is None and
                complete_ring(value, rect, locked=not own))
    bounds = title_top(value, title)
    return (bounds == rect[:3] and pane_locked(value, title) == (not own))


def no_release_rollback(records, committed_pane, committed_rect,
                        held_pane, held_rect, held_own, wireframe):
    bad = []
    # Live-content viewers already show the final preview at mouse-up.  A
    # wireframe viewer may legitimately have the real window hidden until the
    # canonical event, but once that final frame appears it may never vanish
    # again.  Treating None as unconditionally valid would let a real
    # final->blank->final flash escape this temporal oracle.
    committed_seen = not wireframe
    for index, record in enumerate(records):
        if (record['changed_cells'] <= 0 or
                stlib.cursor_only_transition(record)):
            continue
        committed = title_top(record, TITLES[committed_pane])
        if committed == committed_rect[:3]:
            committed_seen = True
        committed_ok = (committed == committed_rect[:3] or
                        (not committed_seen and committed is None))
        if wireframe:
            held_ok = physical_preview_ok(
                record, held_pane, held_rect, held_own, True)
        else:
            held_ok = (title_top(record, TITLES[held_pane]) == held_rect[:3]
                       and pane_locked(record, TITLES[held_pane]) ==
                       (not held_own))
        if not committed_ok or not held_ok:
            bad.append((index, record['kind'], committed, held_ok,
                        record['changed_cells']))
    if not committed_seen:
        bad.append(('committed-final-never-presented',))
    return bad


def physical_trace_ok(text, op, first):
    previews = re.findall(
        r'layout-preview: relay pane=([01]) owner=\d+ id=(\d+) '
        r'seq=(\d+) op=(\d+) base=(\d+)', text)
    by_pane = {0: [], 1: []}
    for pane, gesture, seq, wire_op, base in previews:
        if int(wire_op) == op:
            by_pane[int(pane)].append(
                (int(gesture), int(seq), int(base)))
    bases = {entry[2] for values in by_pane.values() for entry in values}
    commits = [int(value) for value in re.findall(
        r'layout-commit: owner=\d+ applied=1 revision=(\d+)', text)]
    enough = all(len(values) >= (2 if pane == first else 3) and
                 len({entry[0] for entry in values}) == 1 and
                 [entry[1] for entry in values] == sorted(
                     entry[1] for entry in values)
                 for pane, values in by_pane.items())
    exact_revision = (len(bases) == 1 and len(commits) == 2 and
                      commits == [next(iter(bases)) + 1,
                                  next(iter(bases)) + 2])
    # The first CLEAR in the daemon trace names the pane released first.
    clears = [int(value) for value in re.findall(
        r'layout-preview: clear pane=([01]) owner=\d+', text)]
    return enough and exact_revision and len(clears) == 2 and clears == [
        first, 1 - first]


def physical_scenario(clients, home, session, sock_path, env, log, first,
                      wireframe):
    actors = clients[:2]
    observer = clients[2]
    other = 1 - first
    op = PREVIEW_OP_WIREFRAME if wireframe else PREVIEW_OP_BOUNDS
    mode = 'wire' if wireframe else 'bounds'
    label = f'physical {mode} {first}->{other}'

    tiled = control(['organize', session, 'tile'], home, env)
    focused = control(['focus', session + ':1'], home, env)
    drain_all(clients, 1.0)
    baseline = daemon_state(sock_path)
    rects = tuple(frame_rect(actors[pane], TITLES[pane])
                  for pane in range(2))
    all_rects = [[frame_rect(client, title) for title in TITLES]
                 for client in clients]
    check(label + ' deterministic baseline',
          tiled is not None and tiled.returncode == 0 and
          focused is not None and focused.returncode == 0 and
          baseline is not None and baseline['count'] == 2 and
          all(rect is not None for rect in rects) and
          all(tuple(value) == rects for value in all_rects))
    if baseline is None or any(rect is None for rect in rects):
        return

    starts = []
    for pane, actor in enumerate(actors):
        _left, _top, right, bottom = rects[pane]
        starts.append((right, bottom))
    log_offset = os.path.getsize(log)
    for client in clients:
        client.begin_transition_capture()

    mouse_down(actors[0], *starts[0])
    drain_all(clients, 0.30)
    mouse_down(actors[1], *starts[1])
    drain_all(clients, 0.35)
    for step in (1, 2):
        for pane, actor in enumerate(actors):
            mouse_drag(actor, starts[pane][0] - step, starts[pane][1])
            drain_all(clients, 0.12)
    held_rects = tuple((left, top, right - 2, bottom)
                       for left, top, right, bottom in rects)
    held = [snapshot(client) for client in clients]
    held_ok = True
    for viewer, value in enumerate(held):
        for pane in range(2):
            held_ok = held_ok and physical_preview_ok(
                value, pane, held_rects[pane], viewer == pane, wireframe)
    check(label + ' viewer-relative two-pane lock presentation', held_ok)
    held_daemon = daemon_state(sock_path)
    check(label + ' previews leave canonical geometry and PTYs unchanged',
          held_daemon is not None and
          [pane['geom'] for pane in held_daemon['panes']] ==
          [pane['geom'] for pane in baseline['panes']] and
          [pane['pty'] for pane in held_daemon['panes']] ==
          [pane['pty'] for pane in baseline['panes']])

    # Mark the exact physical presentation boundary immediately before the
    # first release.  Every record after it is cumulative terminal state.
    drain_all(clients, 0.12)
    marks = [len(client.transitions()) for client in clients]
    mouse_up(actors[first], starts[first][0] - 2, starts[first][1])
    drain_all(clients, 0.75)
    released_records = [client.transitions()[mark:]
                        for client, mark in zip(clients, marks)]
    released = [snapshot(client) for client in clients]
    intermediate = daemon_state(sock_path)
    expected_geom = list(pane['geom'] for pane in baseline['panes'])
    first_geom = list(expected_geom[first])
    first_geom[2] -= 2
    expected_geom[first] = tuple(first_geom)
    expected_intermediate_ptys = [pane['pty'] for pane in baseline['panes']]
    expected_intermediate_ptys[first] = (
        expected_intermediate_ptys[first][0] - 2,
        expected_intermediate_ptys[first][1])
    check(label + ' first release commits only its pane',
          intermediate is not None and
          [pane['geom'] for pane in intermediate['panes']] == expected_geom and
          [pane['pty'] for pane in intermediate['panes']] ==
          expected_intermediate_ptys)
    released_ok = True
    for viewer, value in enumerate(released):
        released_ok = released_ok and (
            title_top(value, TITLES[first]) == held_rects[first][:3])
        released_ok = released_ok and physical_preview_ok(
            value, other, held_rects[other], viewer == other, wireframe)
    check(label + ' first final and other held preview coexist', released_ok)

    rollback = []
    for viewer, records in enumerate(released_records):
        bad = no_release_rollback(
            records, first, held_rects[first], other, held_rects[other],
            viewer == other, wireframe)
        if any(CLEAR_RE.search(record['raw'])
               for record in records if record['kind'] == 'direct'):
            bad.append(('terminal-clear',))
        if bad:
            print(f'  {label} viewer {viewer} rollback:', bad[:8])
        rollback.extend((viewer, item) for item in bad)
    check(label + ' no final-old-final physical presentation', not rollback)

    # One more mouse delta after the peer commit proves the surviving modal
    # DragView retained both its local rectangle and its old lease base.
    mouse_drag(actors[other], starts[other][0] - 3, starts[other][1])
    drain_all(clients, 0.35)
    last_rect = (rects[other][0], rects[other][1],
                 rects[other][2] - 3, rects[other][3])
    continued = [snapshot(client) for client in clients]
    check(label + ' remaining gesture relays another exact cell',
          all(physical_preview_ok(value, other, last_rect,
                                  viewer == other, wireframe)
              for viewer, value in enumerate(continued)) and
          all(title_top(value, TITLES[first]) == held_rects[first][:3]
              for value in continued))

    mouse_up(actors[other], starts[other][0] - 3, starts[other][1])
    drain_all(clients, 0.90)
    records = [client.end_transition_capture() for client in clients]
    final = daemon_state(sock_path)
    final_rects = list(held_rects)
    final_rects[other] = last_rect
    expected_geom[other] = (
        expected_geom[other][0], expected_geom[other][1],
        expected_geom[other][2] - 3, expected_geom[other][3])
    expected_final_ptys = list(expected_intermediate_ptys)
    expected_final_ptys[other] = (
        expected_final_ptys[other][0] - 3,
        expected_final_ptys[other][1])
    check(label + ' final geometry and PTYs merge exactly',
          final is not None and
          [pane['geom'] for pane in final['panes']] == expected_geom and
          [pane['pty'] for pane in final['panes']] ==
          expected_final_ptys)
    check(label + ' all three viewers settle identically unlocked',
          all([frame_rect(client, title) for title in TITLES] == final_rects
              for client in clients) and
          all(not pane_locked(client, title)
              for client in clients for title in TITLES))
    # No whole-terminal clear is an independent anti-flicker contract.  The
    # geometry-specific rollback check above remains the primary oracle.
    check(label + ' emits no destructive physical clear',
          not any(CLEAR_RE.search(record['raw'])
                  for viewer_records in records for record in viewer_records))
    with open(log, 'r', errors='replace') as stream:
        stream.seek(log_offset)
        trace = stream.read()
    if not physical_trace_ok(trace, op, first):
        print('  ' + label + ' trace tail:', trace[-3000:])
    check(label + ' trace commits same-base gestures at base+1,+2',
          physical_trace_ok(trace, op, first))


def run_physical_mode(dragcontent):
    mode = 'live' if dragcontent else 'wire'
    home = stlib.fresh_home('concurrent-gesture-' + mode)
    ini = home + '/.superterm/superterm.ini'
    log = '/tmp/superterm-concurrent-gesture-' + mode + '.log'
    try:
        os.unlink(log)
    except FileNotFoundError:
        pass
    with open(ini, 'w', encoding='utf-8') as stream:
        stream.write('[ui]\nlanguage=en\npalette=mono\nbackground=none\n'
                     '[session]\nserver=always\nautosave=0\n'
                     f'autorestore=0\ndragcontent={int(dragcontent)}\n'
                     'zoomanim=0\n')
    env = {'SUPERTERM_DEBUG': log, 'SUPERTERM_DEBUG_FULL': '1',
           'SUPERTERM_SYNC': '1'}
    session = 'concurrent-gesture-' + mode
    clients = []
    try:
        first = stlib.Client(home, args=['--session', session], w=WIDTH,
                             h=HEIGHT, lang='en', env=env)
        clients.append(first)
        first.drain(2.0)
        first.send(b'\x1bOQ', 0.9)
        first.send(b'\x11', 0.08)
        first.send(b't', 0.8)
        for pane, title in enumerate(TITLES, 1):
            control(['rename', f'{session}:{pane}', title], home, env)
        clients.extend(stlib.Client(
            home, args=['--attach', session], w=WIDTH, h=HEIGHT,
            lang='en', env=env) for _viewer in range(2))
        drain_all(clients, 2.2)
        sockets = stlib.session_sockets(home)
        check(mode + ' physical three-client fixture',
              len(sockets) == 1 and all(client.alive() for client in clients))
        if len(sockets) == 1:
            # The first scenario is the original failure: B commits while A
            # still owns pane 0.  Then reverse the release order.
            physical_scenario(clients, home, session, sockets[0], env, log,
                              first=1, wireframe=not dragcontent)
            physical_scenario(clients, home, session, sockets[0], env, log,
                              first=0, wireframe=not dragcontent)
    finally:
        # Esc unwinds a modal DragView if setup/assertion failed mid-gesture.
        for client in reversed(clients):
            try:
                os.write(client.fd, b'\x1b')
                client.drain(0.12)
                client.send(b'\x11', 0.05)
                client.send(b'd', 0.25)
                client.wait_exit(timeout=4.0)
            except (OSError, RuntimeError):
                pass
            client.close()
        stlib.close_all_daemons(home)


run_raw_protocol()
run_physical_mode(True)
run_physical_mode(False)
stlib.report()
