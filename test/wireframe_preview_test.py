#!/usr/bin/env python3
"""Rendered protocol-v14 wireframes stay identical in two real viewers.

The raw protocol test proves ownership and framing; this test proves what a
person actually sees.  With ``dragcontent=0`` it pauses after every one-cell
move/grow step and compares the complete transient ring (glyph, position and
monochrome attribute) in the actor and observer.  CTL_LIST is sampled while
the mouse/key gesture is still modal, so an optimistic PTY/layout mutation
cannot be hidden by a correct final repaint.
"""
import os
import re
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


WIDTH, HEIGHT = 110, 34
STEP_PAUSE = 0.20
TITLE = 'WIRE_PREVIEW_TARGET'
OTHER = 'WIRE_PREVIEW_OTHER'
FRAME_CTL_LIST = 11
FRAME_CTL_DATA = 42
FRAME_CTL_END = 43
RING_GLYPHS = frozenset('┌─┐│└┘')
FRAME_LEFT = ('╔', '┌', '░', '▒', '▓')
FRAME_RIGHT = ('╗', '┐', '░', '▒', '▓')
CLEAR_RE = re.compile(br'\x1b\[[0-?]*[ -/]*J|\x1bc|\x1b#8')

HOME = stlib.fresh_home('wireframe-preview')
INI = HOME + '/.superterm/superterm.ini'
LOG = '/tmp/superterm-wireframe-preview.log'
try:
    os.unlink(LOG)
except FileNotFoundError:
    pass
with open(INI, 'w', encoding='utf-8') as output:
    output.write('[ui]\n'
                 'language=en\n'
                 'palette=mono\n'
                 'background=none\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n'
                 'dragcontent=0\n'
                 'zoomanim=0\n')

ENV = {
    'SUPERTERM_DEBUG': LOG,
    'SUPERTERM_DEBUG_FULL': '1',
    'SUPERTERM_SYNC': '1',
}


def display_of(value):
    if isinstance(value, dict):
        return value['display']
    return value.screen.display


def cells_of(value):
    if isinstance(value, dict):
        return value['cells']
    return tuple(tuple(value.screen.buffer[y][x] for x in range(value.w))
                 for y in range(value.h))


def snapshot(client):
    return {
        'kind': 'sample',
        'display': tuple(client.screen.display),
        'cells': cells_of(client),
        'before_cells': None,
        'changed_cells': 0,
        'raw': b'',
    }


def char_attr(char):
    return (char.fg, char.bg, char.bold, char.italics, char.underscore,
            char.strikethrough, char.reverse, char.blink)


def title_bounds(value, title=TITLE):
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


def frame_rect(value, title=TITLE):
    bounds = title_bounds(value, title)
    if bounds is None:
        return None
    left, top, right = bounds
    rows = display_of(value)
    for bottom in range(top + 2, len(rows)):
        if (rows[bottom][left] in ('╚', '└') and
                rows[bottom][right] in ('╝', '┘')):
            return left, top, right, bottom
    return None


def has_lock(value):
    rows = display_of(value)
    if any(re.search(r'\bLOCK\s+' + re.escape(TITLE) + r'\b', row)
           for row in rows):
        return True
    width = len(rows[0]) if rows else 0
    for x in range(width):
        for y in range(max(0, len(rows) - 3)):
            if ''.join(rows[y + offset][x] for offset in range(4)) == 'LOCK':
                return True
    return False


def perimeter(rect):
    left, top, right, bottom = rect
    expected = {}
    for x in range(left + 1, right):
        expected[(x, top)] = '─'
        expected[(x, bottom)] = '─'
    for y in range(top + 1, bottom):
        expected[(left, y)] = '│'
        expected[(right, y)] = '│'
    expected[(left, top)] = '┌'
    expected[(right, top)] = '┐'
    expected[(left, bottom)] = '└'
    expected[(right, bottom)] = '┘'
    return expected


def locked_perimeter(rect):
    """Exact CP437 176/177 remote-owner ring rendered as Unicode."""
    left, top, right, bottom = rect
    height = bottom - top + 1
    lock_start = max(1, (height - len('LOCK')) // 2)
    expected = {}
    for x, y in perimeter(rect):
        if (x == left and height >= 6 and
                lock_start <= y - top < lock_start + len('LOCK')):
            expected[(x, y)] = 'LOCK'[y - top - lock_start]
        elif x in (left, right):
            expected[(x, y)] = '▒'
        else:
            expected[(x, y)] = '░'
    return expected


def active_ring(value, expected_attr):
    cells = cells_of(value)
    coords = {
        (x, y): char.data
        for y, row in enumerate(cells)
        for x, char in enumerate(row)
        if char.data in RING_GLYPHS and char_attr(char) == expected_attr
    }
    if not coords:
        return None, coords
    xs = [point[0] for point in coords]
    ys = [point[1] for point in coords]
    rect = min(xs), min(ys), max(xs), max(ys)
    if coords != perimeter(rect):
        return None, coords
    return rect, coords


def exact_ring(value, rect, expected_attr):
    found, coords = active_ring(value, expected_attr)
    if found != rect or coords != perimeter(rect):
        return False
    # The hidden real window must not leave stale title/frame text underneath
    # its composited ring.
    return not any(TITLE in row for row in display_of(value))


def complete_ring(value, rect, expected_attr, locked=False):
    """True when one expected outline is complete, even over other frames."""
    cells = cells_of(value)
    height = len(cells)
    width = len(cells[0]) if height else 0
    expected = locked_perimeter(rect) if locked else perimeter(rect)
    for (x, y), glyph in expected.items():
        if (x < 0 or y < 0 or x >= width or y >= height or
                cells[y][x].data != glyph or
                char_attr(cells[y][x]) != expected_attr):
            return False
    return True


def exact_locked_ring(value, rect, expected_attr):
    return (complete_ring(value, rect, expected_attr, locked=True) and
            not any(TITLE in row for row in display_of(value)))


def drain_all(clients, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.025)


def control(args, attempts=30):
    last = None
    for _attempt in range(attempts):
        last = run_cli(args, HOME, env=ENV)
        if last.returncode == 0:
            return last
        if 'busy' not in (last.stdout + last.stderr).lower():
            break
        time.sleep(0.05)
    return last


def preview_ids(value):
    return {int(match) for match in re.findall(
        r'layout-preview: relay pane=0 owner=0 id=(\d+) ', value)}


def current_preview_ids():
    with open(LOG, 'r', errors='replace') as log_file:
        return preview_ids(log_file.read())


def read_new_preview_trace(prior_ids, needs_commit, timeout=2.0):
    """Find one new gesture without relying on a multiprocess file offset."""
    deadline = time.monotonic() + timeout
    value = ''
    selected = None
    while True:
        with open(LOG, 'r', errors='replace') as log_file:
            value = log_file.read()
        for gesture_id in sorted(preview_ids(value) - prior_ids):
            marker = (f'layout-preview: relay pane=0 owner=0 '
                      f'id={gesture_id} ')
            start = value.find(marker)
            trace = value[start:]
            relays = trace.count(marker)
            cleared = (f'layout-preview: clear pane=0 owner=0 '
                       f'id={gesture_id} ') in trace
            committed = ('layout-commit: owner=0 applied=1 revision=' in
                         trace)
            if relays >= 6 and cleared and (committed or not needs_commit):
                return trace, gesture_id
            selected = gesture_id
        if time.monotonic() >= deadline:
            if selected is None:
                return value, None
            marker = (f'layout-preview: relay pane=0 owner=0 '
                      f'id={selected} ')
            return value[value.find(marker):], selected
        time.sleep(0.04)


def read_control_list(sock_path):
    """Return daemon focus, canonical geometry and real screen dimensions."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(3.0)
    try:
        try:
            sock.connect(sock_path)
        except OSError:
            return None
        sock.sendall(stlib.raw_frame(FRAME_CTL_LIST, -1))
        payload = None
        while True:
            frame = stlib.read_frame(sock, timeout=3.0)
            if frame is None or frame[0] == FRAME_CTL_END:
                break
            if frame[0] == FRAME_CTL_DATA:
                payload = frame[2]
    finally:
        sock.close()
    if payload is None:
        return None
    try:
        offset = 0
        _name, offset = stlib.read_pas_string(payload, offset)
        _profile, offset = stlib.read_pas_string(payload, offset)
        pane_count, focused, _clients, desk_w, desk_h = struct.unpack_from(
            '<iiiii', payload, offset)
        offset += struct.calcsize('<iiiii')
        panes = []
        for _pane in range(pane_count):
            title, offset = stlib.read_pas_string(payload, offset)
            term, offset = stlib.read_pas_string(payload, offset)
            kind = payload[offset]
            offset += 1
            host, offset = stlib.read_pas_string(payload, offset)
            user, offset = stlib.read_pas_string(payload, offset)
            command, offset = stlib.read_pas_string(payload, offset)
            cwd, offset = stlib.read_pas_string(payload, offset)
            cols, rows, history, bx, by, bw, bh = struct.unpack_from(
                '<iiiiiii', payload, offset)
            offset += struct.calcsize('<iiiiiii')
            zoomed, minimized, alive = struct.unpack_from('<BBB', payload,
                                                          offset)
            offset += 3
            panes.append({
                'title': title, 'term': term, 'kind': kind,
                'host': host, 'user': user, 'command': command, 'cwd': cwd,
                'pty': (cols, rows), 'history': history,
                'geom': (bx, by, bw, bh), 'zoomed': bool(zoomed),
                'minimized': bool(minimized), 'alive': bool(alive),
            })
        if offset != len(payload):
            return None
        return {'focused': focused, 'desk': (desk_w, desk_h), 'panes': panes}
    except (IndexError, struct.error, ValueError):
        return None


def target_daemon_state(sock_path):
    state = read_control_list(sock_path)
    if state is None:
        return None
    for pane in state['panes']:
        if TITLE in pane['title']:
            return state['focused'], pane['geom'], pane['pty']
    return None


def mouse_down(client, x, y):
    os.write(client.fd, f'\x1b[<0;{x + 1};{y + 1}M'.encode())


def mouse_drag(client, x, y):
    os.write(client.fd, f'\x1b[<32;{x + 1};{y + 1}M'.encode())


def mouse_up(client, x, y):
    os.write(client.fd, f'\x1b[<0;{x + 1};{y + 1}m'.encode())


def compact(values):
    result = []
    for value in values:
        if not result or result[-1] != value:
            result.append(value)
    return result


def temporal_integrity(records, baseline, final, valid_rings, expected_attr,
                       locked=False):
    """Reject a blank/old/partial presentation, not normal cursor blinking."""
    bad = []
    for index, record in enumerate(records):
        if record['changed_cells'] <= 0 or stlib.cursor_only_transition(record):
            continue
        rect = frame_rect(record)
        rings = [ring for ring in valid_rings
                 if complete_ring(record, ring, expected_attr, locked)]
        surface = (bool(record['display']) and
                   'Panes' in record['display'][0] and
                   any('F2 Split' in row for row in record['display']))
        # The lock shades the observer's old frame, whose corners deliberately
        # stop matching frame_rect().  A wireframe may otherwise coexist with
        # the baseline pane or replace it, but an intermediate real pane and a
        # bare state with neither pane nor ring are both visible flicker.
        locked_baseline = (has_lock(record) and
                           any(TITLE in row for row in record['display']))
        allowed = (rect in (baseline, final) or locked_baseline or
                   (rect is None and len(rings) == 1))
        if not surface or not allowed:
            bad.append((index, record['kind'], record['changed_cells'],
                        rect, tuple(rings), surface))
    return bad


def raw_has_clear(records):
    return any(CLEAR_RE.search(record['raw']) is not None
               for record in records)


def direct_printed_text(records):
    """Return direct (outside DEC 2026) bytes that could flash as text."""
    printed = []
    for record in records:
        if record['kind'] != 'direct':
            continue
        raw = record['raw']
        raw = re.sub(br'\x1b\][^\x07]*(?:\x07|\x1b\\)', b'', raw,
                     flags=re.DOTALL)
        raw = re.sub(br'\x1bP.*?\x1b\\', b'', raw, flags=re.DOTALL)
        raw = re.sub(br'\x1b\[[0-?]*[ -/]*[@-~]', b'', raw)
        raw = re.sub(br'\x1b[ -/]*[@-Z\\-_]', b'', raw)
        raw = bytes(value for value in raw if value >= 32 and value != 127)
        if raw:
            printed.append(raw)
    return printed


def perform_mouse_gesture(label, actor, observer, sock_path, resize):
    clients = (actor, observer)
    baseline = frame_rect(actor)
    observer_baseline = frame_rect(observer)
    daemon_baseline = target_daemon_state(sock_path)
    actor_attr = (char_attr(actor.screen.buffer[baseline[1]][baseline[0]])
                  if baseline is not None else None)
    observer_attr = (
        char_attr(observer.screen.buffer[observer_baseline[1]][
            observer_baseline[0]]) if observer_baseline is not None else None)
    check(label + ' has identical baseline',
          baseline is not None and baseline == observer_baseline and
          daemon_baseline is not None)
    check(label + ' uses same monochrome frame attribute',
          actor_attr is not None and actor_attr == observer_attr)
    if baseline is None or daemon_baseline is None:
        return

    left, top, right, bottom = baseline
    if resize:
        start_x, start_y = right, bottom
    else:
        title_x = actor.screen.display[top].find(TITLE)
        start_x = title_x + len(TITLE) // 2
        start_y = top
    prior_preview_ids = current_preview_ids()
    for client in clients:
        client.begin_transition_capture()
    mouse_down(actor, start_x, start_y)
    drain_all(clients, 0.32)
    held_state = target_daemon_state(sock_path)
    held_lock_ok = has_lock(observer) and not has_lock(actor)

    step_rects = []
    ring_ok = True
    lock_samples = [(not has_lock(actor), has_lock(observer))]
    canonical_samples = [held_state]
    focus_samples = [] if held_state is None else [held_state[0]]
    for step in range(1, 7):
        end_x = start_x + step
        end_y = start_y
        mouse_drag(actor, end_x, end_y)
        drain_all(clients, STEP_PAUSE)
        expected = ((left, top, right + step, bottom) if resize else
                    (left + step, top, right + step, bottom))
        step_rects.append(expected)
        actor_sample = snapshot(actor)
        observer_sample = snapshot(observer)
        lock_samples.append((not has_lock(actor_sample),
                             has_lock(observer_sample)))
        actor_ok = exact_ring(actor_sample, expected, actor_attr)
        observer_ok = exact_locked_ring(observer_sample, expected,
                                        observer_attr)
        if not (actor_ok and observer_ok):
            ar, ac = active_ring(actor_sample, actor_attr)
            br = expected if complete_ring(observer_sample, expected,
                                           observer_attr, locked=True) else None
            bc = locked_perimeter(expected) if br is not None else {}
            print(f'  {label} step {step}: expected={expected} '
                  f'actor={ar}/{len(ac)} observer={br}/{len(bc)}')
        ring_ok = ring_ok and actor_ok and observer_ok
        state = target_daemon_state(sock_path)
        canonical_samples.append(state)
        if state is not None:
            focus_samples.append(state[0])

    mouse_up(actor, start_x + 6, start_y)
    drain_all(clients, 1.1)
    actor_records = actor.end_transition_capture()
    observer_records = observer.end_transition_capture()
    final_actor = frame_rect(actor)
    final_observer = frame_rect(observer)
    daemon_final = target_daemon_state(sock_path)
    expected_final = step_rects[-1]
    check(label + ' observer alone shows LOCK while held',
          held_lock_ok and all(actor_ok and observer_ok
                               for actor_ok, observer_ok in lock_samples))
    check(label + ' relays six exact one-cell rings', ring_ok)
    check(label + ' keeps canonical geometry/PTY under every ring',
          bool(canonical_samples) and
          all(state == daemon_baseline for state in canonical_samples))
    check(label + ' keeps shared focus throughout',
          bool(focus_samples) and all(focus == daemon_baseline[0]
                                      for focus in focus_samples) and
          daemon_final is not None and
          daemon_final[0] == daemon_baseline[0])
    check(label + ' commits one identical final rectangle',
          final_actor == expected_final and final_observer == expected_final)
    if resize:
        expected_geom = (daemon_baseline[1][0], daemon_baseline[1][1],
                         daemon_baseline[1][2] + 6,
                         daemon_baseline[1][3])
        expected_pty = (daemon_baseline[2][0] + 6,
                        daemon_baseline[2][1])
    else:
        expected_geom = (daemon_baseline[1][0] + 6,
                         daemon_baseline[1][1],
                         daemon_baseline[1][2], daemon_baseline[1][3])
        expected_pty = daemon_baseline[2]
    check(label + ' commits canonical geometry/PTY once',
          daemon_final is not None and daemon_final[1] == expected_geom and
          daemon_final[2] == expected_pty)

    valid = set(step_rects)
    actor_bad = temporal_integrity(actor_records, baseline, expected_final,
                                   valid, actor_attr)
    observer_bad = temporal_integrity(observer_records, baseline,
                                      expected_final, valid, observer_attr,
                                      locked=True)
    if actor_bad:
        print('  ' + label + ' actor artifacts:', actor_bad[:8])
    if observer_bad:
        print('  ' + label + ' observer artifacts:', observer_bad[:8])
    check(label + ' has no blank/rollback/artifact presentation',
          not actor_bad and not observer_bad and
          not raw_has_clear(actor_records + observer_records) and
          not direct_printed_text(actor_records + observer_records))
    actor_path = compact([baseline] + [frame_rect(record)
                         for record in actor_records
                         if frame_rect(record) is not None])
    observer_path = compact([baseline] + [frame_rect(record)
                            for record in observer_records
                            if frame_rect(record) is not None])
    if actor_path != [baseline, expected_final]:
        print('  ' + label + ' actor real-frame path:', actor_path)
    if observer_path != [baseline, expected_final]:
        print('  ' + label + ' observer real-frame path:', observer_path)
    check(label + ' real frame jumps only baseline to final',
          actor_path == [baseline, expected_final] and
          observer_path == [baseline, expected_final])
    gesture_log, gesture_id = read_new_preview_trace(prior_preview_ids, True)
    marker = (f'layout-preview: relay pane=0 owner=0 id={gesture_id} '
              if gesture_id is not None else '')
    preview_count = gesture_log.count(marker) if marker else 0
    commit_count = len(re.findall(
        r'layout-commit: owner=0 applied=1 revision=', gesture_log))
    if preview_count < 6 or commit_count != 1:
        print(f'  {label} trace counts: previews={preview_count} '
              f'owner-commits={commit_count}')
    check(label + ' trace has previews then one commit',
          preview_count >= 6 and commit_count == 1)


def perform_keyboard_cancel(actor, observer, sock_path):
    label = 'keyboard resize Esc'
    clients = (actor, observer)
    baseline = frame_rect(actor)
    daemon_baseline = target_daemon_state(sock_path)
    actor_attr = (char_attr(actor.screen.buffer[baseline[1]][baseline[0]])
                  if baseline is not None else None)
    observer_attr = (char_attr(observer.screen.buffer[baseline[1]][baseline[0]])
                     if baseline is not None else None)
    if baseline is None or daemon_baseline is None:
        check(label + ' baseline exists', False)
        return
    left, top, right, bottom = baseline
    prior_preview_ids = current_preview_ids()
    for client in clients:
        client.begin_transition_capture()
    # xterm's standard Ctrl-F5 encoding selects FreeVision cmResize. Shift-
    # Right then chooses the grow branch of DragView.Change, one cell at time.
    os.write(actor.fd, b'\x1b[15;5~')
    drain_all(clients, 0.35)
    held_lock_ok = has_lock(observer) and not has_lock(actor)
    step_rects = []
    ring_ok = True
    lock_samples = [(not has_lock(actor), has_lock(observer))]
    canonical_samples = [target_daemon_state(sock_path)]
    for step in range(1, 7):
        os.write(actor.fd, b'\x1b[1;2C')
        drain_all(clients, STEP_PAUSE)
        expected = left, top, right + step, bottom
        step_rects.append(expected)
        a_sample = snapshot(actor)
        b_sample = snapshot(observer)
        lock_samples.append((not has_lock(a_sample), has_lock(b_sample)))
        step_ok = (exact_ring(a_sample, expected, actor_attr) and
                   exact_locked_ring(b_sample, expected, observer_attr))
        if not step_ok:
            ar, ac = active_ring(a_sample, actor_attr)
            br = expected if complete_ring(b_sample, expected, observer_attr,
                                           locked=True) else None
            bc = locked_perimeter(expected) if br is not None else {}
            print(f'  {label} step {step}: expected={expected} '
                  f'actor={ar}/{len(ac)} observer={br}/{len(bc)}')
        ring_ok = ring_ok and step_ok
        canonical_samples.append(target_daemon_state(sock_path))
    os.write(actor.fd, b'\x1b')
    drain_all(clients, 1.1)
    actor_records = actor.end_transition_capture()
    observer_records = observer.end_transition_capture()
    daemon_final = target_daemon_state(sock_path)
    check(label + ' observer alone shows LOCK while held',
          held_lock_ok and all(actor_ok and observer_ok
                               for actor_ok, observer_ok in lock_samples))
    check(label + ' relays six exact one-cell rings', ring_ok)
    check(label + ' never changes canonical geometry/PTY',
          bool(canonical_samples) and
          all(state == daemon_baseline for state in canonical_samples) and
          daemon_final == daemon_baseline)
    check(label + ' restores both viewers atomically',
          frame_rect(actor) == baseline and frame_rect(observer) == baseline)
    valid = set(step_rects + [baseline])
    actor_bad = temporal_integrity(actor_records, baseline, baseline, valid,
                                   actor_attr)
    observer_bad = temporal_integrity(observer_records, baseline, baseline,
                                      valid, observer_attr, locked=True)
    if actor_bad:
        print('  keyboard cancel actor artifacts:', actor_bad[:8])
    if observer_bad:
        print('  keyboard cancel observer artifacts:', observer_bad[:8])
    check(label + ' has no blank/text/flicker artifact',
          not actor_bad and not observer_bad and
          not raw_has_clear(actor_records + observer_records) and
          not direct_printed_text(actor_records + observer_records))
    gesture_log, gesture_id = read_new_preview_trace(prior_preview_ids, False)
    marker = (f'layout-preview: relay pane=0 owner=0 id={gesture_id} '
              if gesture_id is not None else '')
    clear_marker = (f'layout-preview: clear pane=0 owner=0 id={gesture_id} '
                    if gesture_id is not None else '')
    check(label + ' uses CLEAR/UNLOCK without layout commit',
          bool(marker) and gesture_log.count(marker) >= 6 and
          bool(clear_marker) and clear_marker in gesture_log and
          'layout-commit: owner=' not in gesture_log)


actor = observer = None
try:
    actor = stlib.Client(HOME, w=WIDTH, h=HEIGHT, lang='en', env=ENV)
    actor.drain(2.0)
    actor.send(b'\x1bOQ', 1.0)  # F2: create the second pane
    actor.send(b'\x11', 0.08)
    actor.send(b't', 0.8)       # deterministic two-column layout
    sockets = stlib.session_sockets(HOME)
    check('wireframe session exists', len(sockets) == 1)
    sock_path = sockets[0] if sockets else ''
    session = os.path.basename(sock_path)[:-5] if sock_path else ''
    renamed = (control(['rename', session + ':1', TITLE]).returncode == 0 and
               control(['rename', session + ':2', OTHER]).returncode == 0)
    focused = control(['focus', session + ':1']).returncode == 0
    check('wireframe fixture configured', renamed and focused)
    observer = stlib.Client(HOME, args=['--attach'], w=WIDTH, h=HEIGHT,
                            lang='en', env=ENV)
    drain_all((actor, observer), 2.0)
    check('wireframe observer attached', observer.alive())
    check('wireframe baseline shared focus',
          frame_rect(actor) == frame_rect(observer) and
          target_daemon_state(sock_path) is not None and
          target_daemon_state(sock_path)[0] == 0)

    perform_mouse_gesture('mouse move', actor, observer, sock_path,
                          resize=False)
    perform_mouse_gesture('mouse resize', actor, observer, sock_path,
                          resize=True)
    perform_keyboard_cancel(actor, observer, sock_path)
finally:
    # Esc also unwinds cmResize if an assertion/setup failure left it modal.
    for client in (observer, actor):
        if client is None:
            continue
        try:
            os.write(client.fd, b'\x1b')
            client.drain(0.15)
            client.send(b'\x11', 0.05)
            client.send(b'd', 0.25)
            client.wait_exit(timeout=4.0)
        except OSError:
            pass
        client.close()
    stlib.close_all_daemons(HOME)

stlib.report()
