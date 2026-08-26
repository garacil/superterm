#!/usr/bin/env python3
"""A held title gesture must never hand focus to the window underneath.

This is deliberately temporal.  Looking only after mouse-up misses the bug:
FreeVision may select another window while its modal DragView is still active
and then select the requested pane again at commit.  Two real UI clients are
kept attached while every physical DEC-2026 update, several daemon focus
samples, and the DEBUG_FULL focus/layout trace are inspected.

Both panes are the actor in turn.  Each is tested with a stationary held
mouse-down and with character-by-character movement, once with live content
and once with wireframe dragging.
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


FRAME_CTL_LIST = 11
FRAME_CTL_DATA = 42
FRAME_CTL_END = 43
TITLES = ('HOLD_FOCUS_P0', 'HOLD_FOCUS_P1')
FRAME_LEFT = ('╔', '┌', '░', '▒', '▓')
FRAME_RIGHT = ('╗', '┐', '░', '▒', '▓')
RING_GLYPHS = frozenset('┌─┐│└┘')


def drain_all(clients, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.025)


def control(args, home, env, attempts=20):
    """Retry a setup operation only while the prior layout is settling."""
    last = None
    for _attempt in range(attempts):
        last = run_cli(args, home, env=env)
        if last.returncode == 0:
            return last
        if 'busy' not in (last.stdout + last.stderr).lower():
            break
        time.sleep(0.05)
    return last


def daemon_state(sock_path):
    """Read authoritative focus and pane geometry from FRAME_CTL_LIST."""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(3.0)
        sock.connect(sock_path)
        sock.sendall(stlib.raw_frame(FRAME_CTL_LIST, -1))
        payload = None
        while True:
            frame = stlib.read_frame(sock, timeout=3.0)
            if frame is None or frame[0] == FRAME_CTL_END:
                break
            if frame[0] == FRAME_CTL_DATA:
                payload = frame[2]
        sock.close()
        if payload is None:
            return None
        offset = 0
        _name, offset = stlib.read_pas_string(payload, offset)
        _profile, offset = stlib.read_pas_string(payload, offset)
        pane_count, focused, _clients, desk_w, desk_h = struct.unpack_from(
            '<iiiii', payload, offset)
        offset += struct.calcsize('<iiiii')
        panes = []
        for _pane in range(pane_count):
            title, offset = stlib.read_pas_string(payload, offset)
            _term, offset = stlib.read_pas_string(payload, offset)
            offset += 1                         # pane kind
            _host, offset = stlib.read_pas_string(payload, offset)
            _user, offset = stlib.read_pas_string(payload, offset)
            _command, offset = stlib.read_pas_string(payload, offset)
            _cwd, offset = stlib.read_pas_string(payload, offset)
            _cols, _rows, _history, bx, by, bw, bh = struct.unpack_from(
                '<iiiiiii', payload, offset)
            offset += struct.calcsize('<iiiiiii')
            _zoomed, _minimized, _alive = struct.unpack_from(
                '<BBB', payload, offset)
            offset += 3
            panes.append({'title': title, 'geom': (bx, by, bw, bh)})
        if offset != len(payload):
            return None
        return {'focused': focused, 'desk': (desk_w, desk_h),
                'panes': panes}
    except (IndexError, OSError, struct.error, ValueError):
        return None


def daemon_focus(sock_path):
    """Read FFocused without parsing localized CLI text."""
    state = daemon_state(sock_path)
    return None if state is None else state['focused']


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
        'raw': b'',
        'changed_cells': 0,
    }


def title_bounds(value, title):
    """Return the top frame bounds, including a shaded locked frame."""
    for top, row in enumerate(display_of(value)):
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


def pane_is_visually_active(value, pane):
    """Use FreeVision chrome, not cursor location, as the sfActive witness."""
    bounds = title_bounds(value, TITLES[pane])
    if bounds is None:
        return False
    left, top, right = bounds
    row = display_of(value)[top]
    # TFrame changes to a single-line dragging style while sfActive remains
    # set.  SuperTerm's native [-] is drawn only under sfActive, so it is the
    # reliable held-gesture marker; double corners cover settled frames too.
    return (row[left] == '╔' or row[right] == '╗' or
            (right - left >= 13 and row[right - 9:right - 6] == '[-]'))


def visible_active_panes(value):
    return {pane for pane in range(2) if pane_is_visually_active(value, pane)}


def has_lock(value):
    rows = display_of(value)
    if any('LOCK' in row for row in rows):
        return True
    width = len(rows[0]) if rows else 0
    for x in range(width):
        for y in range(max(0, len(rows) - 3)):
            if ''.join(rows[y + offset][x] for offset in range(4)) == 'LOCK':
                return True
    return False


def char_attr(char):
    return (char.fg, char.bg, char.bold, char.italics, char.underscore,
            char.strikethrough, char.reverse, char.blink)


def has_active_ring(value, expected):
    """A hidden wireframe owner is represented by its active-colour ring."""
    count = 0
    for row in cells_of(value):
        for char in row:
            if char.data in RING_GLYPHS and char_attr(char) == expected:
                count += 1
    return count >= 4


def has_locked_ring(value, expected):
    """An observer represents the same hidden pane with shaded LOCK chrome."""
    count = 0
    for row in cells_of(value):
        for char in row:
            if char.data in ('░', '▒') and char_attr(char) == expected:
                count += 1
    return has_lock(value) and count >= 4


def visual_focus_contract(values, target, allow_hidden, expected_attr,
                          locked_hidden=False):
    """No presentation may activate the other pane or de-activate a visible target."""
    other = 1 - target
    for index, value in enumerate(values):
        active = visible_active_panes(value)
        if other in active or len(active) > 1:
            return False, f'frame {index} activates {sorted(active)}'
        target_visible = title_bounds(value, TITLES[target]) is not None
        if target_visible and target not in active:
            return False, f'frame {index} shows target inactive'
        if not target_visible:
            if not allow_hidden:
                return False, f'frame {index} loses visible target'
            ring_present = (has_locked_ring(value, expected_attr)
                            if locked_hidden else
                            has_active_ring(value, expected_attr))
            if not ring_present:
                return False, f'frame {index} loses target and active ring'
    return True, ''


def focus_trace_values(log_text):
    """All focus-bearing client trace records from this isolated gesture."""
    explicit = [int(value) for value in
                re.findall(r'focus: pane=(-?\d+)', log_text)]
    layouts = [int(value) for value in
               re.findall(r'layout-event:[^\n]* focus=(-?\d+)', log_text)]
    return explicit, layouts


def run_mode(dragcontent):
    wireframe = not dragcontent
    mode = 'wireframe-on' if wireframe else 'wireframe-off'
    home = stlib.fresh_home('title-hold-' + mode)
    ini = os.path.join(home, '.superterm', 'superterm.ini')
    log = '/tmp/superterm-title-hold-' + mode + '.log'
    try:
        os.unlink(log)
    except FileNotFoundError:
        pass
    with open(ini, 'w') as output:
        output.write('[ui]\n'
                     'language=en\n'
                     'palette=mono\n'
                     'background=none\n'
                     '[session]\n'
                     'server=always\n'
                     'autosave=0\n'
                     'autorestore=0\n'
                     f'dragcontent={int(dragcontent)}\n'
                     'zoomanim=0\n')
    env = {
        'SUPERTERM_DEBUG': log,
        'SUPERTERM_DEBUG_FULL': '1',
        'SUPERTERM_SYNC': '1',
    }

    first = stlib.Client(home, w=110, h=34, lang='en', env=env)
    first.drain(2.0)
    first.send(b'\x1bOQ', 1.0)       # F2: second pane
    first.send(b'\x11', 0.08)
    first.send(b't', 0.8)             # deterministic two-column baseline
    sockets = stlib.session_sockets(home)
    check(mode + ' session exists', len(sockets) == 1)
    sock_path = sockets[0] if sockets else ''
    session = os.path.basename(sock_path)[:-5] if sock_path else ''

    renamed = True
    for pane, title in enumerate(TITLES):
        result = control(['rename', f'{session}:{pane + 1}', title],
                         home, env)
        renamed = renamed and result is not None and result.returncode == 0
    check(mode + ' titles installed', renamed)

    second = stlib.Client(home, args=['--attach'], w=110, h=34,
                          lang='en', env=env)
    clients = (first, second)
    drain_all(clients, 2.0)
    check(mode + ' second client attached', second.alive())

    for target in range(2):
        for moving in (False, True):
            gesture = 'move' if moving else 'stationary'
            label = f'{mode} pane{target} {gesture}'

            tiled = control(['organize', session, 'tile'], home, env)
            focused = control(['focus', f'{session}:{target + 1}'], home, env)
            drain_all(clients, 0.8)
            check(label + ' setup',
                  tiled is not None and tiled.returncode == 0 and
                  focused is not None and focused.returncode == 0)

            actor_index = (target + int(moving) + int(wireframe)) % 2
            actor = clients[actor_index]
            observer = clients[1 - actor_index]
            before_actor = frame_rect(actor, TITLES[target])
            before_observer = frame_rect(observer, TITLES[target])
            check(label + ' target frame found',
                  before_actor is not None and
                  before_actor == before_observer)

            if before_actor is None:
                # Keep the protocol stream balanced even after a setup error;
                # stlib.report will retain the precise failed assertion.
                continue
            left, top, _right, _bottom = before_actor
            title_x = actor.screen.display[top].find(TITLES[target])
            press_x = title_x + len(TITLES[target]) // 2
            expected_attr = char_attr(actor.screen.buffer[top][left])
            log_offset = os.path.getsize(log)
            daemon_before = daemon_state(sock_path)
            daemon_samples = [daemon_focus(sock_path)]
            actor_samples = []
            observer_samples = []
            held_locks = []

            for client in clients:
                client.begin_transition_capture()
            os.write(actor.fd,
                     f'\x1b[<0;{press_x + 1};{top + 1}M'.encode())

            # A stationary hold is sampled repeatedly.  A moving hold is
            # sampled after every one-character mouse event.  CTL_LIST is
            # served by the daemon while the actor remains inside DragView.
            drain_all(clients, 0.16)
            for _sample in range(3):
                actor_samples.append(snapshot(actor))
                observer_samples.append(snapshot(observer))
                held_locks.append((has_lock(actor), has_lock(observer)))
                daemon_samples.append(daemon_focus(sock_path))
                drain_all(clients, 0.06)

            end_x, end_y = press_x, top
            if moving:
                direction = 1 if target == 0 else -1
                for step in range(1, 5):
                    end_x = press_x + direction * step
                    end_y = top + min(step, 2)
                    os.write(actor.fd,
                             (f'\x1b[<32;{end_x + 1};'
                              f'{end_y + 1}M').encode())
                    drain_all(clients, 0.08)
                    actor_samples.append(snapshot(actor))
                    observer_samples.append(snapshot(observer))
                    held_locks.append((has_lock(actor), has_lock(observer)))
                    daemon_samples.append(daemon_focus(sock_path))

            # One last observation while the button is still down, then the
            # release and its canonical layout commit.
            drain_all(clients, 0.10)
            actor_samples.append(snapshot(actor))
            observer_samples.append(snapshot(observer))
            daemon_samples.append(daemon_focus(sock_path))
            os.write(actor.fd,
                     f'\x1b[<0;{end_x + 1};{end_y + 1}m'.encode())
            drain_all(clients, 1.0)
            actor_records = actor.end_transition_capture()
            observer_records = observer.end_transition_capture()
            daemon_samples.append(daemon_focus(sock_path))
            actor_after = snapshot(actor)
            observer_after = snapshot(observer)
            daemon_after = daemon_state(sock_path)

            with open(log, 'r', errors='replace') as log_file:
                log_file.seek(log_offset)
                gesture_log = log_file.read()
            explicit_focus, layout_focus = focus_trace_values(gesture_log)

            check(label + ' daemon focus never changes',
                  bool(daemon_samples) and
                  all(value == target for value in daemon_samples))
            if (any(value != target for value in explicit_focus) or
                    any(value != target for value in layout_focus)):
                print('  ' + label + ' focus trace:',
                      explicit_focus, layout_focus)
            check(label + ' trace never names other pane',
                  bool(layout_focus) and
                  all(value == target for value in explicit_focus) and
                  all(value == target for value in layout_focus))
            check(label + ' lock stays observer-only',
                  bool(held_locks) and
                  all(not actor_lock and observer_lock
                      for actor_lock, observer_lock in held_locks))

            actor_values = actor_records + actor_samples
            observer_values = observer_records + observer_samples
            actor_ok, actor_reason = visual_focus_contract(
                actor_values, target, allow_hidden=(wireframe and moving),
                expected_attr=expected_attr)
            observer_ok, observer_reason = visual_focus_contract(
                observer_values, target, allow_hidden=(wireframe and moving),
                expected_attr=expected_attr,
                locked_hidden=(wireframe and moving))
            if not actor_ok:
                print('  ' + label + ' actor:', actor_reason)
            if not observer_ok:
                print('  ' + label + ' observer:', observer_reason)
            check(label + ' actor never activates other', actor_ok)
            check(label + ' observer keeps target active', observer_ok)

            visual_direct = [record for record in actor_records
                             if record['kind'] == 'direct' and
                             record['changed_cells'] > 0]
            if wireframe and moving:
                hidden_actor = [value for value in actor_values
                                if title_bounds(value, TITLES[target]) is None]
                hidden_observer = [value for value in observer_values
                                   if title_bounds(value,
                                                   TITLES[target]) is None]
                check(label + ' uses composited wireframe',
                      bool(hidden_actor) and bool(hidden_observer) and
                      all(has_active_ring(value, expected_attr)
                          for value in hidden_actor) and
                      all(has_locked_ring(value, expected_attr)
                          for value in hidden_observer) and
                      not visual_direct)
            else:
                check(label + ' has no wireframe paint',
                      not visual_direct)

            after_actor = title_bounds(actor_after, TITLES[target])
            after_observer = title_bounds(observer_after, TITLES[target])
            before_geom = (daemon_before['panes'][target]['geom']
                           if daemon_before is not None and
                           target < len(daemon_before['panes']) else None)
            after_geom = (daemon_after['panes'][target]['geom']
                          if daemon_after is not None and
                          target < len(daemon_after['panes']) else None)
            if before_geom is not None:
                expected_geom = ((before_geom[0] + direction * 4,
                                  before_geom[1] + 2, before_geom[2],
                                  before_geom[3]) if moving else before_geom)
            else:
                expected_geom = None
            expected_left = left + (direction * 4 if moving else 0)
            expected_top = top + (2 if moving else 0)
            expected_geometry = (
                expected_geom is not None and after_geom == expected_geom and
                after_actor is not None and after_observer is not None and
                after_actor[:2] == (expected_left, expected_top) and
                after_observer[:2] == (expected_left, expected_top))
            check(label + ' release keeps shared geometry', expected_geometry)
            check(label + ' release keeps target active',
                  visible_active_panes(actor_after) == {target} and
                  visible_active_panes(observer_after) == {target} and
                  daemon_samples[-1] == target)

    # Focus is intentionally outside the pane-layout lease.  Exercise the
    # ordering which a normal "focus never changes while held" test cannot:
    # client A enters FreeVision's modal DragView for pane 0, then client B
    # focuses pane 1 while A is still holding the mouse and before A supplies
    # its first movement.  The first wireframe ChangeBounds must preserve that
    # newer Current across Hide, and mouse-up must preserve it across Show.
    # The same scenario in live-content mode catches an unconditional focus
    # replay at release even though no Hide/Show is involved.
    target = 0
    newer_focus = 1
    label = mode + ' remote focus wins held move'
    tiled = control(['organize', session, 'tile'], home, env)
    focused = control(['focus', f'{session}:{target + 1}'], home, env)
    drain_all(clients, 0.8)
    check(label + ' setup',
          tiled is not None and tiled.returncode == 0 and
          focused is not None and focused.returncode == 0 and
          daemon_focus(sock_path) == target and
          visible_active_panes(first) == {target} and
          visible_active_panes(second) == {target})

    actor = first
    observer = second
    before_actor = frame_rect(actor, TITLES[target])
    before_observer = frame_rect(observer, TITLES[target])
    daemon_before = daemon_state(sock_path)
    check(label + ' target frame found',
          before_actor is not None and before_actor == before_observer)

    if before_actor is not None:
        left, top, right, bottom = before_actor
        title_x = actor.screen.display[top].find(TITLES[target])
        press_x = title_x + len(TITLES[target]) // 2
        os.write(actor.fd,
                 f'\x1b[<0;{press_x + 1};{top + 1}M'.encode())
        drain_all(clients, 0.18)
        held_before_focus = (not has_lock(actor) and has_lock(observer))

        # This must originate in the other attached UI, rather than in the
        # daemon-control helper: Alt-2 follows the ordinary client focus path
        # and its event reaches A while A's DragView is pumping Idle.
        observer.send(b'\x1b2', 0.05)
        focus_deadline = time.monotonic() + 3.0
        remote_focus_arrived = False
        while time.monotonic() < focus_deadline:
            drain_all(clients, 0.05)
            if (daemon_focus(sock_path) == newer_focus and
                    visible_active_panes(actor) == {newer_focus} and
                    visible_active_panes(observer) == {newer_focus}):
                remote_focus_arrived = True
                break
        check(label + ' receives newer focus before first delta',
              remote_focus_arrived)

        # Capture only presentations after the newer focus has converged.  A
        # stale active frame for pane 0 anywhere in this interval is therefore
        # a real focus rollback, not the legitimate mouse-down focus preceding
        # client B's command.
        log_offset = os.path.getsize(log)
        for client in clients:
            client.begin_transition_capture()
        focus_samples = [daemon_focus(sock_path)]
        visual_samples = [
            (visible_active_panes(actor), visible_active_panes(observer))
        ]
        held_locks = [(not has_lock(actor), has_lock(observer))]
        for step in range(1, 5):
            os.write(actor.fd,
                     (f'\x1b[<32;{press_x + step + 1};'
                      f'{top + 1}M').encode())
            drain_all(clients, 0.09)
            focus_samples.append(daemon_focus(sock_path))
            visual_samples.append(
                (visible_active_panes(actor),
                 visible_active_panes(observer)))
            held_locks.append((not has_lock(actor), has_lock(observer)))

        os.write(actor.fd,
                 f'\x1b[<0;{press_x + 5};{top + 1}m'.encode())
        drain_all(clients, 1.0)
        actor_records = actor.end_transition_capture()
        observer_records = observer.end_transition_capture()
        focus_samples.append(daemon_focus(sock_path))
        visual_samples.append(
            (visible_active_panes(actor), visible_active_panes(observer)))
        after_actor = frame_rect(actor, TITLES[target])
        after_observer = frame_rect(observer, TITLES[target])
        daemon_after = daemon_state(sock_path)

        with open(log, 'r', errors='replace') as log_file:
            log_file.seek(log_offset)
            post_focus_log = log_file.read()
        explicit_focus, layout_focus = focus_trace_values(post_focus_log)
        stale_focus = (target in explicit_focus or target in layout_focus)
        if stale_focus:
            print('  ' + label + ' stale focus trace:',
                  explicit_focus, layout_focus)

        record_visuals = [
            pane_is_visually_active(record, newer_focus)
            for record in actor_records + observer_records
            if record['changed_cells'] > 0
        ]
        sampled_focus_ok = all(
            newer_focus in actor_active and newer_focus in observer_active
            for actor_active, observer_active in visual_samples)
        if not sampled_focus_ok:
            print('  ' + label + ' sampled active panes:', visual_samples)
        if not record_visuals or not all(record_visuals):
            print('  ' + label + ' transition active panes:',
                  record_visuals)
        before_geom = (daemon_before['panes'][target]['geom']
                       if daemon_before is not None and
                       target < len(daemon_before['panes']) else None)
        after_geom = (daemon_after['panes'][target]['geom']
                      if daemon_after is not None and
                      target < len(daemon_after['panes']) else None)
        expected_geom = ((before_geom[0] + 4, before_geom[1],
                          before_geom[2], before_geom[3])
                         if before_geom is not None else None)
        actor_title_after = title_bounds(actor, TITLES[target])
        observer_title_after = title_bounds(observer, TITLES[target])
        geometry_ok = (
            expected_geom is not None and after_geom == expected_geom and
            actor_title_after is not None and
            observer_title_after is not None and
            actor_title_after[:2] == (left + 4, top) and
            observer_title_after[:2] == (left + 4, top))
        if not geometry_ok:
            print('  ' + label + ' final geometry:',
                  'expected daemon', expected_geom, 'daemon', after_geom,
                  'actor', after_actor, 'observer', after_observer,
                  'actor title', actor_title_after,
                  'observer title', observer_title_after)
        check(label + ' keeps pane lease while focus changes',
              held_before_focus and bool(held_locks) and
              all(actor_unlocked and observer_locked
                  for actor_unlocked, observer_locked in held_locks))
        check(label + ' daemon keeps newer focus through commit',
              bool(focus_samples) and
              all(value == newer_focus for value in focus_samples))
        check(label + ' every sampled border keeps newer focus',
              bool(visual_samples) and sampled_focus_ok)
        check(label + ' every physical transition keeps newer focus',
              bool(record_visuals) and
              all(record_visuals))
        check(label + ' log never restores actor focus',
              not stale_focus and bool(layout_focus) and
              layout_focus[-1] == newer_focus)
        check(label + ' commits movement without changing focus',
              geometry_ok and
              pane_is_visually_active(actor, newer_focus) and
              pane_is_visually_active(observer, newer_focus) and
              not has_lock(actor) and not has_lock(observer))

    for client in (second, first):
        client.send(b'\x11', 0.08)
        client.send(b'd', 0.30)
        client.wait_exit(timeout=4.0)
        client.close()
    stlib.close_all_daemons(home)


run_mode(dragcontent=True)
run_mode(dragcontent=False)
stlib.report()
