#!/usr/bin/env python3
"""A native maximize hand-off is one globally exclusive transaction.

Two real UI clients share two panes.  Pane 1 is maximized with its title
button; while it is still maximized, the other client brings pane 2 forward
and maximizes that pane with its own title button.  There is deliberately no
restore between those actions.  The daemon must atomically restore pane 1's
PTY to its saved BW/BH, install pane 2 at the shared safe maximum, publish one
and only one Z flag, and leave both viewers on the same geometry.

The final section repeats simultaneous FIFO control requests for the two
panes. Cross-socket arrival order is intentionally unspecified, but both
commands must complete, every observation may contain at most one canonical
maximized pane and the loser must retain its exact restore grid.
"""
import os
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, raw_frame, read_frame, read_pas_string, run_cli
from stlib import (FRAME_CTL_LIST, FRAME_CTL_DATA, FRAME_CTL_END)


CREATOR_SIZE = (96, 28)
OBSERVER_SIZE = (118, 36)
TITLES = ('EXCLUSIVE_ONE', 'EXCLUSIVE_TWO')
HOME = stlib.fresh_home('zoom-exclusive-switch-' + str(os.getpid()))
INI = os.path.join(HOME, '.superterm', 'superterm.ini')

with open(INI, 'w') as stream:
    stream.write('[ui]\n'
                 'language=en\n'
                 'background=none\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n'
                 'zoomanim=0\n')


def drain_all(clients, seconds=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            if client is not None:
                client.drain(0.025)


def control(args, attempts=30):
    """Retry only a transient lease conflict; never hide another failure."""
    last = None
    for _attempt in range(attempts):
        try:
            last = run_cli(args, HOME, env={'LANG': 'C'}, timeout=5)
        except subprocess.TimeoutExpired:
            print('  control timed out:', ' '.join(args))
            return None
        if last.returncode == 0:
            return last
        if 'busy' not in (last.stdout + last.stderr).lower():
            break
        time.sleep(0.04)
    if last is not None:
        print('  control failed:', ' '.join(args),
              repr((last.stdout + last.stderr).strip()))
    return last


def daemon_state(socket_path):
    """Strict CTL_LIST oracle for PTY, restore geometry and zoom flags."""
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.settimeout(3.0)
    payload = None
    try:
        peer.connect(socket_path)
        peer.sendall(raw_frame(FRAME_CTL_LIST, -1))
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
        _name, offset = read_pas_string(payload, offset)
        _profile, offset = read_pas_string(payload, offset)
        count, focused, clients, desk_w, desk_h = struct.unpack_from(
            '<iiiii', payload, offset)
        offset += struct.calcsize('<iiiii')
        panes = []
        for _pane in range(count):
            title, offset = read_pas_string(payload, offset)
            _term, offset = read_pas_string(payload, offset)
            if offset >= len(payload):
                raise ValueError('missing pane kind')
            offset += 1
            for _field in range(4):
                _value, offset = read_pas_string(payload, offset)
            cols, rows, _history, bx, by, bw, bh = struct.unpack_from(
                '<iiiiiii', payload, offset)
            offset += struct.calcsize('<iiiiiii')
            zoomed, minimized, alive = struct.unpack_from(
                '<BBB', payload, offset)
            offset += struct.calcsize('<BBB')
            panes.append({
                'title': title,
                'pty': (cols, rows),
                'geom': (bx, by, bw, bh),
                'zoomed': bool(zoomed),
                'minimized': bool(minimized),
                'alive': bool(alive),
            })
        if offset != len(payload):
            raise ValueError('trailing CTL_LIST bytes')
        return {
            'count': count,
            'focused': focused,
            'clients': clients,
            'desk': (desk_w, desk_h),
            'panes': panes,
        }
    except (IndexError, struct.error, ValueError):
        return None


def frame_rect(client, title):
    """Inclusive terminal coordinates for a complete normal/locked frame."""
    rows = client.screen.display
    for top, row in enumerate(rows):
        title_x = row.find(title)
        if title_x < 0:
            continue
        lefts = [x for x, char in enumerate(row[:title_x])
                 if char in ('╔', '┌', '▒')]
        rights = [x for x, char in enumerate(
            row[title_x + len(title):], title_x + len(title))
                  if char in ('╗', '┐', '▒')]
        if not lefts or not rights:
            continue
        left, right = max(lefts), min(rights)
        for bottom in range(top + 2, len(rows)):
            if (rows[bottom][left] in ('╚', '└', '▒', '░') and
                    rows[bottom][right] in
                    ('╝', '┘', '▒', '░')):
                return left, top, right, bottom
    return None


def icon_rect(client, title):
    """Inclusive coordinates of the exact two-row minimized icon."""
    rows = client.screen.display
    for top in range(len(rows) - 1):
        row = rows[top]
        title_x = row.find(title)
        if title_x < 0:
            continue
        lefts = [x for x, char in enumerate(row[:title_x]) if char == '┌']
        rights = [x for x, char in enumerate(
            row[title_x + len(title):], title_x + len(title))
                  if char == '┐']
        if not lefts or not rights:
            continue
        left, right = max(lefts), min(rights)
        if (rows[top + 1][left] == '└' and
                rows[top + 1][right] == '┘'):
            return left, top, right, top + 1
    return None


def click_zoom(client, rect):
    if rect is None:
        return False
    _left, top, right, _bottom = rect
    # FreeVision TFrame: local Size.X-4, the centre of its [↑] zoom button.
    x = right - 3
    try:
        os.write(client.fd,
                 f'\x1b[<0;{x + 1};{top + 1}M'.encode())
        os.write(client.fd,
                 f'\x1b[<0;{x + 1};{top + 1}m'.encode())
        return True
    except OSError:
        return False


def click_minimize(client, rect):
    if rect is None:
        return False
    _left, top, right, _bottom = rect
    # Custom FreeVision frame: local Size.X-9, the centre of the real [-].
    x = right - 8
    try:
        os.write(client.fd,
                 f'\x1b[<0;{x + 1};{top + 1}M'.encode())
        os.write(client.fd,
                 f'\x1b[<0;{x + 1};{top + 1}m'.encode())
        return True
    except OSError:
        return False


def click_icon(client, rect):
    if rect is None:
        return False
    left, top, right, _bottom = rect
    try:
        x = (left + right) // 2
        os.write(client.fd,
                 f'\x1b[<0;{x + 1};{top + 1}M'.encode())
        os.write(client.fd,
                 f'\x1b[<0;{x + 1};{top + 1}m'.encode())
        return True
    except OSError:
        return False


def normal_pty(pane):
    _bx, _by, bw, bh = pane['geom']
    return max(4, bw - 2), max(2, bh - 2)


def zoomed_indexes(state):
    if state is None:
        return ()
    return tuple(index for index, pane in enumerate(state['panes'])
                 if pane['zoomed'])


def has_two_panes(state):
    return state is not None and state['count'] == 2 and \
        len(state['panes']) == 2


def settled_state(clients, socket_path, predicate, timeout=6.0):
    """Require three identical valid samples, not one transient coincidence."""
    deadline = time.monotonic() + timeout
    last = None
    stable = 0
    while time.monotonic() < deadline:
        drain_all(clients, 0.06)
        current = daemon_state(socket_path)
        if current == last and current is not None and predicate(current):
            stable += 1
            if stable >= 3:
                return current
        else:
            stable = 1 if current is not None and predicate(current) else 0
        last = current
        time.sleep(0.025)
    print('  last daemon state:', last)
    return None


def no_lock_text(client):
    rows = client.screen.display
    text = '\n'.join(rows)
    if any(('LOCK ' + title) in text or ('LOCK  ' + title) in text
           for title in TITLES):
        return False
    width = len(rows[0]) if rows else 0
    return not any(
        ''.join(rows[y + offset][x] for offset in range(4)) == 'LOCK'
        for x in range(width) for y in range(max(0, len(rows) - 3)))


def prove_unlocked(session):
    """Same-title renames acquire/release both pane leases without mutation."""
    results = [control(['rename', f'{session}:{index + 1}', title])
               for index, title in enumerate(TITLES)]
    return all(result is not None and result.returncode == 0
               for result in results)


def reap_client(client):
    """Bounded detach and exact-PID reap; never leave a UI in another test."""
    if client is None:
        return
    if client.alive():
        try:
            os.write(client.fd, b'\x11d')
        except OSError:
            pass
        client.drain(0.25)
        client.wait_exit(1.5)
    if client.alive():
        try:
            os.kill(client.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        client.wait_exit(1.0)
    if client.alive():
        try:
            os.kill(client.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        client.wait_exit(1.0)
    client.close()


creator = None
observer = None
try:
    creator = stlib.Client(HOME, w=CREATOR_SIZE[0], h=CREATOR_SIZE[1],
                           lang='en')
    creator.drain(2.2)
    creator.send(b'\x1bOQ', 1.2)       # native F2: second pane

    sockets = stlib.session_sockets(HOME)
    check('exclusive fixture session exists', len(sockets) == 1)
    socket_path = sockets[0] if sockets else ''
    session = os.path.basename(socket_path)[:-5] if socket_path else ''

    for index, title in enumerate(TITLES):
        result = control(['rename', f'{session}:{index + 1}', title])
        check(f'rename exclusive pane {index + 1}',
              result is not None and result.returncode == 0)
    tiled = control(['organize', session, 'tile'])
    check('tile exclusive fixture',
          tiled is not None and tiled.returncode == 0)
    creator.drain(0.8)

    observer = stlib.Client(HOME, args=['--attach', session],
                            w=OBSERVER_SIZE[0], h=OBSERVER_SIZE[1], lang='en')
    observer.drain(2.2)
    clients = (creator, observer)
    drain_all(clients, 0.8)

    baseline = settled_state(
        clients, socket_path,
        lambda state: has_two_panes(state) and state['clients'] == 2 and
        zoomed_indexes(state) == () and
        all(not pane['minimized'] and pane['alive']
            for pane in state['panes']))
    check('two-pane two-client baseline', baseline is not None)

    baseline_panes = baseline['panes'] if baseline is not None else []
    baseline_geoms = tuple(pane['geom'] for pane in baseline_panes)
    baseline_ptys = tuple(normal_pty(pane) for pane in baseline_panes)
    desk = baseline['desk'] if baseline is not None else (0, 0)
    safe_outer = (
        min(desk[0], CREATOR_SIZE[0], OBSERVER_SIZE[0]),
        min(desk[1], CREATOR_SIZE[1] - 2, OBSERVER_SIZE[1] - 2),
    )
    safe_pty = (safe_outer[0] - 2, safe_outer[1] - 2)
    safe_frame = (0, 1, safe_outer[0] - 1, safe_outer[1])

    baseline_frames = tuple(
        tuple(frame_rect(client, title) for title in TITLES)
        for client in clients)
    check('both clients share both restore frames',
          baseline is not None and baseline_frames[0] == baseline_frames[1] and
          all(rect is not None for rect in baseline_frames[0]))

    # Native title button: pane 1 enters normal maximize.
    creator.send(b'\x1b1', 0.45)       # inactive controls only focus on click 1
    focused_one = settled_state(
        clients, socket_path,
        lambda state: state['focused'] == 0 and
        zoomed_indexes(state) == ())
    first_rect = frame_rect(creator, TITLES[0])
    check('pane 1 active before native zoom',
          focused_one is not None and first_rect is not None)
    check('native pane 1 zoom click sent', click_zoom(creator, first_rect))
    first_zoom = settled_state(
        clients, socket_path,
        lambda state: has_two_panes(state) and len(baseline_ptys) == 2 and
        zoomed_indexes(state) == (0,) and
        state['panes'][0]['pty'] == safe_pty and
        state['panes'][1]['pty'] == baseline_ptys[1])
    check('pane 1 is the sole canonical maximum', first_zoom is not None)
    check('pane 1 maximum is identical on both clients',
          frame_rect(creator, TITLES[0]) == safe_frame and
          frame_rect(observer, TITLES[0]) == safe_frame)

    # Bring pane 2 forward, but do not restore pane 1.  The following native
    # click must be a compound hand-off, not a second independent Z flag.
    observer.send(b'\x1b2', 0.7)       # Alt-2: shared focus/raise pane 2
    focused_two = settled_state(
        clients, socket_path,
        lambda state: has_two_panes(state) and state['focused'] == 1 and
        zoomed_indexes(state) == (0,))
    pane_two_rect = frame_rect(observer, TITLES[1])
    check('pane 2 raised while pane 1 remains zoomed canonically',
          focused_two is not None and pane_two_rect is not None)
    check('native pane 2 zoom click sent',
          click_zoom(observer, pane_two_rect))

    switched = settled_state(
        clients, socket_path,
        lambda state: has_two_panes(state) and len(baseline_ptys) == 2 and
        len(baseline_geoms) == 2 and zoomed_indexes(state) == (1,) and
        state['panes'][0]['pty'] == baseline_ptys[0] and
        state['panes'][1]['pty'] == safe_pty and
        tuple(pane['geom'] for pane in state['panes']) == baseline_geoms)
    check('direct maximize hand-off leaves exactly one Z', switched is not None)
    check('pane 1 PTY restored from its canonical BW/BH',
          switched is not None and
          switched['panes'][0]['pty'] ==
          (max(4, switched['panes'][0]['geom'][2] - 2),
           max(2, switched['panes'][0]['geom'][3] - 2)))
    check('pane 2 uses exact shared safe maximum',
          switched is not None and switched['panes'][1]['pty'] == safe_pty)
    check('hand-off geometry is identical on both clients',
          frame_rect(creator, TITLES[1]) == safe_frame and
          frame_rect(observer, TITLES[1]) == safe_frame)
    check('hand-off releases all visible and daemon leases',
          no_lock_text(creator) and no_lock_text(observer) and
          prove_unlocked(session))

    # Minimizing a maximized window legitimately preserves both canonical
    # flags: the icon is minimized, while Zoomed records the state to restore.
    # A validator once rejected that combination, so the actor appeared to
    # minimize and then rolled back when the authoritative snapshot arrived.
    check('maximized pane native minimize click sent',
          click_minimize(observer, safe_frame))
    minimized_zoom = settled_state(
        clients, socket_path,
        lambda state: has_two_panes(state) and
        zoomed_indexes(state) == (1,) and state['panes'][1]['minimized'] and
        state['panes'][1]['pty'] == safe_pty)
    drain_all(clients, 0.35)
    creator_icon = icon_rect(creator, TITLES[1])
    observer_icon = icon_rect(observer, TITLES[1])
    check('maximized pane minimizes canonically in both clients',
          minimized_zoom is not None and creator_icon is not None and
          creator_icon == observer_icon and
          frame_rect(creator, TITLES[1]) is None and
          frame_rect(observer, TITLES[1]) is None)

    check('maximized icon native restore click sent',
          click_icon(creator, creator_icon))
    restored_zoom = settled_state(
        clients, socket_path,
        lambda state: has_two_panes(state) and state['focused'] == 1 and
        zoomed_indexes(state) == (1,) and
        not state['panes'][1]['minimized'] and
        state['panes'][1]['pty'] == safe_pty)
    check('icon restore returns to the same shared maximum',
          restored_zoom is not None and
          frame_rect(creator, TITLES[1]) == safe_frame and
          frame_rect(observer, TITLES[1]) == safe_frame and
          no_lock_text(creator) and no_lock_text(observer))

    # Bounded cross-client FIFO zoom races. Which pane wins is intentionally
    # free; all other state is exact, and no sample may expose two canonical Zs.
    for round_index in range(3):
        current = daemon_state(socket_path)
        for winner in zoomed_indexes(current):
            control(['restore', f'{session}:{winner + 1}'])
        normal = settled_state(
            clients, socket_path,
            lambda state: has_two_panes(state) and
            len(baseline_ptys) == 2 and len(baseline_geoms) == 2 and
            zoomed_indexes(state) == () and
            tuple(pane['pty'] for pane in state['panes']) == baseline_ptys and
            tuple(pane['geom'] for pane in state['panes']) == baseline_geoms)
        drain_all(clients, 0.45)
        rect_one = frame_rect(creator, TITLES[0])
        rect_two = frame_rect(observer, TITLES[1])
        round_frames = tuple(
            tuple(frame_rect(client, title) for title in TITLES)
            for client in clients)
        check(f'race {round_index + 1} starts from two visible panes',
              normal is not None and rect_one is not None and
              rect_two is not None and round_frames == baseline_frames)

        barrier = threading.Barrier(3)
        sent = [False, False]
        sampled_zoom_sets = []
        sampler_stop = threading.Event()
        sampler_ready = threading.Event()

        def sample_canonical_zoom_sets():
            sampler_ready.set()
            while not sampler_stop.is_set():
                state = daemon_state(socket_path)
                if state is not None:
                    sampled_zoom_sets.append(zoomed_indexes(state))
                time.sleep(0.005)

        def race_zoom(slot):
            barrier.wait()
            result = control(['zoom', f'{session}:{slot + 1}'])
            sent[slot] = result is not None and result.returncode == 0

        threads = (
            threading.Thread(target=race_zoom, args=(0,)),
            threading.Thread(target=race_zoom, args=(1,)),
        )
        sampler = threading.Thread(target=sample_canonical_zoom_sets)
        sampler.start()
        sampler_ready.wait(1.0)
        for thread in threads:
            thread.start()
        barrier.wait()
        for thread in threads:
            thread.join(7.0)
        time.sleep(0.15)
        sampler_stop.set()
        sampler.join(5.0)
        check(f'race {round_index + 1} completes both FIFO zooms',
              all(sent) and all(not thread.is_alive() for thread in threads)
              and not sampler.is_alive())
        check(f'race {round_index + 1} sampled no dual-Z state',
              bool(sampled_zoom_sets) and
              all(len(indexes) <= 1 for indexes in sampled_zoom_sets))

        deadline = time.monotonic() + 6.0
        raced = None
        stable = 0
        previous = None
        while time.monotonic() < deadline:
            drain_all(clients, 0.05)
            state = daemon_state(socket_path)
            indexes = zoomed_indexes(state)
            valid = False
            if (has_two_panes(state) and len(indexes) == 1 and
                    len(baseline_ptys) == 2 and len(baseline_geoms) == 2):
                winner = indexes[0]
                loser = 1 - winner
                valid = (
                    state['panes'][winner]['pty'] == safe_pty and
                    state['panes'][loser]['pty'] == baseline_ptys[loser] and
                    tuple(pane['geom'] for pane in state['panes']) ==
                    baseline_geoms)
            if valid and state == previous:
                stable += 1
                if stable >= 3:
                    raced = state
                    break
            else:
                stable = 1 if valid else 0
            previous = state
            time.sleep(0.02)

        if raced is None:
            print(f'  race {round_index + 1} last canonical state:', previous,
                  'expected one Z, safe PTY', safe_pty,
                  'restore PTYs', baseline_ptys)
        check(f'race {round_index + 1} settles one exact winner',
              raced is not None)
        if raced is not None:
            winner = zoomed_indexes(raced)[0]
            drain_all(clients, 0.45)
            check(f'race {round_index + 1} winner owns shared focus',
                  raced['focused'] == winner)
            check(f'race {round_index + 1} shared winner geometry',
                  frame_rect(creator, TITLES[winner]) == safe_frame and
                  frame_rect(observer, TITLES[winner]) == safe_frame)
        check(f'race {round_index + 1} releases every lease',
              no_lock_text(creator) and no_lock_text(observer) and
              prove_unlocked(session))
finally:
    reap_client(observer)
    reap_client(creator)
    stlib.close_all_daemons(HOME)

stlib.report()
