#!/usr/bin/env python3
"""A global lease cannot replay pre-grant layout snapshots after its action.

The real UI is stopped after it has consumed either the prefix or the Window
menu opener.  A protocol peer then completes 17 global lock/unlock pairs.
That puts 34 authoritative, but deliberately old, LAYOUT snapshots in the
stopped UI's Unix socket.  The action key is already in its PTY when it is
continued, so ``TSessionClient.LockLayout(-1)`` must drain those snapshots,
the grant's viewer-relative PEER snapshot, and finally its correlated reply.

FreeVision performs one Idle call before dispatching the already-readable
action key after SIGCONT.  Exactly 32 inert HOST_SUMMARY frames are therefore
placed first: that one Idle consumes its complete budget without changing a
cell.  The following CLEAR plus 34 old layouts and the grant's PEER snapshot
must then be drained by LockLayout itself.  Tile, Cascade and Minimize all
first paint their new local result.  A
client which later applies the pre-grant snapshots visibly presents
``new -> old -> new`` across two Idle batches.  SUPERTERM_SYNC records every
physical DEC-2026 transaction so this test rejects that rollback rather than
merely checking the eventual canonical geometry.  The three exercised global
consumers are Tile, Cascade and Minimize all; profile replacement deliberately
does not use this lease path because it leaves the old remote session first.
"""
import os
import re
import select
import signal
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, raw_frame, read_frame, run_cli


WIDTH, HEIGHT = 112, 36
SESSION = 'global-lock-queue'
TITLES = ('QUEUE_PANE_ZERO', 'QUEUE_PANE_ONE', 'QUEUE_PANE_TWO')
STALE_LOCK_PAIRS = 17
IDLE_FRAME_BUDGET = 32

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
FRAME_LAYOUT_PREVIEW = 35
FRAME_LAYOUT_PEER_EV = 37

PREVIEW_OP_BOUNDS = 1
PREVIEW_FORMAT = '<QQQB3xiiii'

FRAME_CORNERS = frozenset(('╔', '┌', '░', '▒', '▓'))
FRAME_RIGHT = frozenset(('╗', '┐', '░', '▒', '▓'))
CLEAR_RE = re.compile(br'\x1b\[[0-?]*[ -/]*[JK]|\x1bc|\x1b#8')


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
    nodes, offset = pas_string(payload, 0)
    (focused, count), offset = unpack_from('<ii', payload, offset)
    titles = []
    for _pane in range(count):
        title, offset = pas_string(payload, offset)
        _term, offset = pas_string(payload, offset)
        titles.append(title)
    _session, offset = pas_string(payload, offset)
    _profile, offset = pas_string(payload, offset)
    (geom_count, desk_w, desk_h), offset = unpack_from('<iii', payload,
                                                       offset)
    geometry = []
    for _pane in range(geom_count):
        geom, offset = pane_geom(payload, offset)
        geometry.append(geom)
    (proto, _reserved), offset = unpack_from('<ii', payload, offset)
    (revision,), offset = unpack_from('<Q', payload, offset)
    (_clients,), offset = unpack_from('<i', payload, offset)
    (locked,), offset = unpack_from('<I', payload, offset)
    (_min_w, _min_h, _hosts_match), offset = unpack_from('<iii', payload,
                                                          offset)
    if (geom_count != count or offset != len(payload) or proto != PROTO_VER):
        raise ValueError('invalid FRAME_SESSION tail')
    return {
        'nodes': nodes, 'focused': focused, 'titles': tuple(titles),
        'desk': (desk_w, desk_h), 'geometry': tuple(geometry),
        'revision': revision, 'locked': locked,
    }


def parse_layout(payload):
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
    (_clients,), offset = unpack_from('<i', payload, offset)
    (changes, locked), offset = unpack_from('<II', payload, offset)
    (_min_w, _min_h, _hosts_match), offset = unpack_from('<iii', payload,
                                                          offset)
    if offset != len(payload):
        raise ValueError('invalid layout payload')
    return {
        'nodes': nodes, 'focused': focused, 'titles': tuple(titles),
        'desk': (desk_w, desk_h), 'geometry': tuple(geometry),
        'revision': revision, 'changes': changes, 'locked': locked,
    }


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
            raise RuntimeError('EOF during attach')
        if frame[0] == FRAME_READY:
            break
        if frame[0] != FRAME_SCREEN:
            peer.close()
            raise RuntimeError('unexpected attach frame ' + str(frame[0]))
        screens += 1
    if screens != len(snapshot['geometry']):
        peer.close()
        raise RuntimeError('snapshot screen count mismatch')
    # READY can be followed by membership metadata.  Remove it now so every
    # frame counted below was caused by one of this test's lock pairs.
    drain_wire(peer, 0.15)
    return peer, snapshot


def drain_wire(peer, seconds):
    frames = []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        ready, _, _ = select.select(
            [peer], [], [], min(0.025, deadline - time.monotonic()))
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


def read_lock_reply(peer, request_id):
    preceding = []
    deadline = time.monotonic() + 4.0
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
        revision = struct.unpack_from('<Q', frame[2], 9)[0]
        return frame[2][8] != 0, revision, preceding
    return False, 0, preceding


def read_one_layout(peer):
    deadline = time.monotonic() + 4.0
    unrelated = []
    while time.monotonic() < deadline:
        frame = read_frame(peer, timeout=0.7)
        if frame is None:
            break
        if frame[0] in (FRAME_LAYOUT_EV, FRAME_LAYOUT_PEER_EV):
            return frame, unrelated
        unrelated.append(frame)
    return None, unrelated


def enqueue_stale_layouts(peer, snapshot, serial):
    """Complete 17 pairs and validate every snapshot before continuing."""
    base_revision = snapshot['revision']
    base_geometry = snapshot['geometry']
    layout_frames = []
    valid = True
    for turn in range(STALE_LOCK_PAIRS):
        request_id = 0x474C510000000000 + serial * 0x100 + turn + 1
        peer.sendall(raw_frame(
            FRAME_LAYOUT_LOCK, -1,
            struct.pack('<QQ', request_id, base_revision)))
        granted, revision, preceding = read_lock_reply(peer, request_id)
        layouts = [frame for frame in preceding
                   if frame[0] in (FRAME_LAYOUT_EV, FRAME_LAYOUT_PEER_EV)]
        valid = valid and granted and revision == base_revision and len(
            layouts) == 1
        for frame in layouts:
            parsed = parse_layout(frame[2])
            valid = valid and parsed['revision'] == base_revision and \
                parsed['geometry'] == base_geometry
            layout_frames.append(frame)

        peer.sendall(raw_frame(FRAME_LAYOUT_UNLOCK, -1))
        unlocked, unrelated = read_one_layout(peer)
        valid = valid and unlocked is not None and not unrelated
        if unlocked is not None:
            parsed = parse_layout(unlocked[2])
            valid = valid and unlocked[0] == FRAME_LAYOUT_EV and \
                parsed['revision'] == base_revision and \
                parsed['geometry'] == base_geometry and parsed['locked'] == 0
            layout_frames.append(unlocked)
    return valid, layout_frames


def enqueue_idle_budget_prefix(peer):
    """Put exactly one no-paint Idle budget ahead of the stale layouts."""
    for _turn in range(IDLE_FRAME_BUDGET):
        peer.sendall(raw_frame(
            FRAME_CLIENT_SIZE, -1, struct.pack('<ii', WIDTH, HEIGHT)))
    frames = []
    deadline = time.monotonic() + 4.0
    while (len(frames) < IDLE_FRAME_BUDGET and
           time.monotonic() < deadline):
        frame = read_frame(peer, timeout=0.7)
        if frame is None:
            break
        frames.append(frame)
    return (len(frames) == IDLE_FRAME_BUDGET and
            all(frame[0] == FRAME_HOST_SUMMARY_EV for frame in frames)), frames


def begin_rendered_preview(peer, snapshot, serial):
    """Give pane zero to the peer and send one valid live-content preview."""
    request_id = 0x5052560000000000 + serial
    peer.sendall(raw_frame(
        FRAME_LAYOUT_LOCK, 0,
        struct.pack('<QQ', request_id, snapshot['revision'])))
    granted, revision, preceding = read_lock_reply(peer, request_id)
    layouts = [frame for frame in preceding
               if frame[0] in (FRAME_LAYOUT_EV, FRAME_LAYOUT_PEER_EV)]
    lock_valid = granted and revision == snapshot['revision'] and len(
        layouts) == 1

    bx, by, bw, bh = snapshot['geometry'][0][:4]
    desk_w, desk_h = snapshot['desk']
    x = min(bx + 3, max(0, desk_w - 24))
    y = min(by + 2, max(0, desk_h - 7))
    width = min(max(24, bw - 4), desk_w - x)
    height = min(max(7, bh - 2), desk_h - y)
    rect = (x, y, width, height)
    gesture = 0x5052455649455700 + serial
    payload = struct.pack(
        PREVIEW_FORMAT, gesture, snapshot['revision'], 1,
        PREVIEW_OP_BOUNDS, *rect)
    peer.sendall(raw_frame(FRAME_LAYOUT_PREVIEW, 0, payload))
    return lock_valid, rect, gesture


def collect_new_layout(peer, base_revision, timeout=5.0):
    frames = []
    final = None
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select(
            [peer], [], [], min(0.05, deadline - time.monotonic()))
        if not ready:
            continue
        frame = read_frame(peer, timeout=0.7)
        if frame is None:
            break
        frames.append(frame)
        if frame[0] not in (FRAME_LAYOUT_EV, FRAME_LAYOUT_PEER_EV):
            continue
        parsed = parse_layout(frame[2])
        if parsed['revision'] == base_revision + 1:
            final = parsed
            break
    return final, frames


def rows_of(value):
    return value['display'] if isinstance(value, dict) else value.screen.display


def title_bounds(value, title):
    """Top edge coordinates, including the distinct locked-border glyphs."""
    rows = rows_of(value)
    for top, row in enumerate(rows):
        title_x = row.find(title)
        if title_x < 0:
            continue
        lefts = [x for x, char in enumerate(row[:title_x])
                 if char in FRAME_CORNERS]
        rights = [x for x, char in enumerate(
            row[title_x + len(title):], title_x + len(title))
                  if char in FRAME_RIGHT]
        if lefts and rights:
            return max(lefts), top, min(rights)
    return None


def visual_signature(value):
    return tuple(title_bounds(value, title) for title in TITLES)


def compact(values):
    result = []
    for value in values:
        if not result or result[-1] != value:
            result.append(value)
    return result


def control(home, args, attempts=30):
    last = None
    for _attempt in range(attempts):
        last = run_cli(args, home, env={'LANG': 'C'})
        if last.returncode == 0:
            return last
        if 'busy' not in (last.stdout + last.stderr).lower():
            return last
        time.sleep(0.04)
    return last


def open_window_menu(client):
    client.send(b'\x1bw', 0.35)
    return ('Cascade' in client.text() and 'Organize' in client.text() and
            'Tile' in client.text())


def prime_prefix(client):
    client.send(b'\x11', 0.12)
    return True


def run_action(ui, home, path, env, log, baseline_mode, action_name,
               prime, action_key, serial, rendered_preview=False):
    label = action_name.lower()
    baseline_result = control(home, ['organize', SESSION, baseline_mode])
    ui.drain(0.9)
    if rendered_preview:
        # Put the previewed pane at the front of an overlapping cascade so
        # its exact BOUNDS rectangle remains physically measurable.
        focused = control(home, ['focus', SESSION + ':1'])
        ui.drain(0.45)
    else:
        focused = None
    baseline_signature = visual_signature(ui)

    peer, snapshot = attach_wire(path)
    ui.drain(0.55)  # consume attach/membership events before it is stopped
    baseline_signature = visual_signature(ui)
    check(label + ' baseline control and three panes',
          baseline_result is not None and baseline_result.returncode == 0 and
          (not rendered_preview or
           (focused is not None and focused.returncode == 0)) and
          len(snapshot['geometry']) == 3 and
          any(value is not None for value in baseline_signature))

    preview_rect = None
    preview_signature = None
    preview_lock_valid = True
    if rendered_preview:
        preview_lock_valid, preview_rect, _gesture = begin_rendered_preview(
            peer, snapshot, serial)
        ui.drain(0.65)
        preview_signature = visual_signature(ui)
        expected_top = (preview_rect[0], preview_rect[1] + 1,
                        preview_rect[0] + preview_rect[2] - 1)
        if (not preview_lock_valid or
                preview_signature == baseline_signature or
                preview_signature[0] != expected_top):
            print('  ' + label + ' preview:', {
                'lock_valid': preview_lock_valid,
                'rect': preview_rect,
                'expected_top': expected_top,
                'baseline': baseline_signature,
                'visible': preview_signature,
            })
        check(label + ' peer BOUNDS preview is physically rendered',
              preview_lock_valid and preview_signature != baseline_signature
              and preview_signature[0] == expected_top)

    primed = prime(ui)
    check(label + ' input path primed before stop', primed)
    log_offset = os.path.getsize(log)
    stopped = False
    records = []
    final = None
    queued = []
    queue_valid = False
    budget_valid = False
    budget_frames = []
    try:
        os.kill(ui.pid, signal.SIGSTOP)
        stopped = True
        time.sleep(0.08)
        # GetEvent calls Idle once before it dispatches the queued key after
        # SIGCONT.  Fill precisely that budget with metadata-only frames so
        # CLEAR/layout remain unread for LockLayout's correlated wait.
        budget_valid, budget_frames = enqueue_idle_budget_prefix(peer)
        if rendered_preview:
            # Cancellation is deliberately after SIGSTOP.  Its CLEAR and
            # canonical old layout are therefore pre-grant queued events;
            # the displayed preview itself remains on the physical terminal.
            peer.sendall(raw_frame(FRAME_LAYOUT_UNLOCK, 0))
            released, unrelated = read_one_layout(peer)
            preview_lock_valid = preview_lock_valid and released is not None \
                and not unrelated
            if released is not None:
                released_layout = parse_layout(released[2])
                preview_lock_valid = preview_lock_valid and \
                    released_layout['revision'] == snapshot['revision'] and \
                    released_layout['geometry'] == snapshot['geometry'] and \
                    released_layout['locked'] == 0
        queue_valid, queued = enqueue_stale_layouts(peer, snapshot, serial)
        # Capture begins with either the unchanged desktop or its Window menu.
        # The action is already readable before SIGCONT, while all 34 stale
        # snapshots are already complete in the Unix socket.
        ui.begin_transition_capture()
        os.write(ui.fd, action_key)
        os.kill(ui.pid, signal.SIGCONT)
        stopped = False
        ui.drain(2.2)
        final, _frames = collect_new_layout(peer, snapshot['revision'])
        ui.drain(0.65)
        records = ui.end_transition_capture()
    finally:
        if stopped:
            try:
                os.kill(ui.pid, signal.SIGCONT)
            except ProcessLookupError:
                pass

    expected_stale = STALE_LOCK_PAIRS * 2
    check(label + ' queues 34 validated old layouts',
          budget_valid and len(budget_frames) == IDLE_FRAME_BUDGET and
          queue_valid and preview_lock_valid and
          len(queued) == expected_stale and
          expected_stale > IDLE_FRAME_BUDGET)
    check(label + ' commits exactly the next canonical revision',
          final is not None and final['revision'] == snapshot['revision'] + 1
          and final['geometry'] != snapshot['geometry'])

    final_signature = visual_signature(ui)
    check(label + ' reaches a distinct material geometry',
          final_signature != baseline_signature and
          any(value is not None for value in final_signature))

    states = []
    indexed_states = []
    for index, record in enumerate(records):
        if record['changed_cells'] <= 0 or stlib.cursor_only_transition(record):
            continue
        signature = visual_signature(record)
        if signature == baseline_signature:
            state = 'old'
        elif signature == final_signature:
            state = 'new'
        else:
            state = 'other'
        states.append(state)
        indexed_states.append((index, state, signature,
                               record['changed_cells'], record['kind']))
    path_states = compact(states)
    first_new = next((index for index, state in enumerate(states)
                      if state == 'new'), -1)
    rollback = first_new >= 0 and 'old' in states[first_new + 1:]
    if first_new < 0 or rollback:
        print('  ' + label + ' transition path:', path_states)
        print('  ' + label + ' material signatures:', indexed_states[:30])
    check(label + ' physically presents the new action', first_new >= 0)
    check(label + ' never presents new-old-new',
          first_new >= 0 and not rollback)
    if rendered_preview:
        preview_replayed = any(
            visual_signature(record) == preview_signature
            for record in records
            if record['changed_cells'] > 0 and
            not stlib.cursor_only_transition(record))
        baseline_flash = first_new >= 0 and 'old' in states[:first_new]
        final_preview_rect = final['geometry'][0][:4] if final else None
        if (first_new < 0 or baseline_flash or preview_replayed or
                final_preview_rect == preview_rect):
            print('  ' + label + ' preview settle:', {
                'first_new': first_new,
                'states': path_states,
                'baseline_flash': baseline_flash,
                'preview_replayed': preview_replayed,
                'preview_rect': preview_rect,
                'final_rect': final_preview_rect,
            })
        check(label + ' settles old preview inside the owned action',
              first_new >= 0 and not baseline_flash and
              not preview_replayed and final_preview_rect != preview_rect)
    check(label + ' uses complete synchronized renderer updates',
          all(record['kind'] == 'sync' for record in records
              if record['changed_cells'] > 0 and
              not stlib.cursor_only_transition(record)) and
          not any(CLEAR_RE.search(record['raw']) for record in records))

    with open(log, 'r', errors='replace') as stream:
        stream.seek(log_offset)
        trace = stream.read()
    check(label + ' real UI acquired one global lease',
          len(re.findall(
              r'client-layout-lock: request=\d+ pane=-1 granted=1 ',
              trace)) == 1)

    try:
        peer.sendall(raw_frame(FRAME_DETACH, -1))
    except OSError:
        pass
    peer.close()
    ui.drain(0.45)


home = stlib.fresh_home('global-lock-queue')
ini = home + '/.superterm/superterm.ini'
log = '/tmp/superterm-global-lock-queue.log'
try:
    os.unlink(log)
except FileNotFoundError:
    pass
with open(ini, 'w', encoding='utf-8') as stream:
    stream.write('[ui]\nlanguage=en\npalette=mono\nbackground=none\n'
                 '[session]\nserver=always\nautosave=0\nautorestore=0\n'
                 'dragcontent=1\nzoomanim=0\n')
env = {'SUPERTERM_DEBUG': log, 'SUPERTERM_DEBUG_FULL': '1',
       'SUPERTERM_SYNC': '1'}

ui = stlib.Client(home, args=['--session', SESSION], w=WIDTH, h=HEIGHT,
                  lang='en', env=env)
try:
    ui.drain(2.0)
    ui.send(b'\x1bOQ', 0.75)
    ui.send(b'\x1bOQ', 0.75)
    for pane, title in enumerate(TITLES, 1):
        renamed = control(home, ['rename', f'{SESSION}:{pane}', title])
        check('rename pane ' + str(pane),
              renamed is not None and renamed.returncode == 0)
    ui.drain(0.8)
    sockets = stlib.session_sockets(home)
    check('one debug session with three panes',
          len(sockets) == 1 and ui.alive())
    path = sockets[0] if len(sockets) == 1 else ''
    if path:
        # PrefixPending is the shortest path to Tile and guarantees the queued
        # 't' is handled as one command as soon as the stopped UI continues.
        run_action(
            ui, home, path, env, log, 'cascade', 'Tile',
            prime_prefix, b't', 1, rendered_preview=True)
        # A menu owns Current while it is open, so Idle cannot consume remote
        # events before the mnemonic invokes the global structural command.
        run_action(
            ui, home, path, env, log, 'grid', 'Cascade',
            open_window_menu, b'e', 2)
        run_action(
            ui, home, path, env, log, 'tile', 'Minimize all',
            open_window_menu, b'a', 3)
finally:
    try:
        os.kill(ui.pid, signal.SIGCONT)
    except ProcessLookupError:
        pass
    try:
        ui.send(b'\x11', 0.05)
        ui.send(b'd', 0.25)
        ui.wait_exit(timeout=4.0)
    except (OSError, RuntimeError):
        pass
    ui.close()
    stlib.close_all_daemons(home)

stlib.report()
