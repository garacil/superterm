#!/usr/bin/env python3
"""Normal maximize uses the smallest attached physical viewport.

The order is deliberate: a small client creates the session, a larger client
attaches, then that later client performs a real host resize which grows the
one canonical desktop.  The desktop resize remains shared, but maximizing a
pane inside it must use the smallest host's IDE area.  Otherwise the small
creator loses the right and bottom frame even though the daemon already knows
its host dimensions.

This exercises the native title-button ``cmZoom`` path. The prefix+f command
has a different fullscreen/raw-passthrough path and cannot prove normal
window maximize.
"""
import fcntl
import os
import re
import signal
import socket
import struct
import sys
import termios
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


FRAME_ATTACH = 1
FRAME_DETACH = 4
FRAME_SESSION = 20
FRAME_SCREEN = 21
FRAME_READY = 22


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


HOME = stlib.fresh_home('maximize-min-viewport-' + str(os.getpid()))
DEBUG_LOG = os.path.join(HOME, 'maximize-flow.log')
TRACE_ENV = {
    'SUPERTERM_DEBUG': DEBUG_LOG,
    'SUPERTERM_DEBUG_FULL': '1',
}
TITLE = 'MINVIEWPORT'
SMALL_HOST = (88, 26)
LARGE_ATTACH = (128, 38)
LARGE_RESIZE = (132, 40)
SAFE_FRAME = (0, 1, SMALL_HOST[0] - 1, SMALL_HOST[1] - 2)
SAFE_PTY = (SMALL_HOST[0] - 2, SMALL_HOST[1] - 4)
LARGE_MAX_FRAME = (0, 1, LARGE_RESIZE[0] - 1, LARGE_RESIZE[1] - 2)
LARGE_MAX_PTY = (LARGE_RESIZE[0] - 2, LARGE_RESIZE[1] - 4)


class FixtureError(Exception):
    pass

with open(HOME + '/.superterm/superterm.ini', 'w') as fh:
    fh.write('[ui]\nlanguage=en\nbackground=none\n'
             '[session]\nserver=always\nautosave=0\nautorestore=0\n'
             'zoomanim=1\n')


def pane_state(session):
    result = run_cli(['list', session], HOME, env={'LANG': 'C'})
    if result.returncode != 0:
        return None, ''
    for line in result.stdout.splitlines():
        if not line.startswith('1 '):
            continue
        size = None
        for token in line.split():
            if 'x' not in token or not token[0].isdigit():
                continue
            try:
                size = tuple(int(value) for value in token.split('x', 1))
                break
            except ValueError:
                pass
        last = line.split()[-1]
        flags = last if set(last) <= set('*MZ!') else ''
        return size, flags
    return None, ''


def pane_size(session):
    return pane_state(session)[0]


def frame_rect(client):
    rows = client.screen.display
    for top, row in enumerate(rows):
        title_x = row.find(TITLE)
        if title_x < 0:
            continue
        lefts = [x for x, char in enumerate(row[:title_x])
                 if char in ('╔', '┌', '▒')]
        rights = [x for x, char in enumerate(
            row[title_x + len(TITLE):], title_x + len(TITLE))
                  if char in ('╗', '┐', '▒')]
        if not lefts or not rights:
            continue
        left, right = max(lefts), min(rights)
        for bottom in range(top + 2, len(rows)):
            if (rows[bottom][left] in ('╚', '└', '▒', '░') and
                    rows[bottom][right] in ('╝', '┘', '▒', '░')):
                return left, top, right, bottom
    return None


def drain_all(clients, seconds=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            client.drain(0.025)


def host_resize(client, width, height):
    # Match a real terminal emulator: resize its cell surface before SIGWINCH.
    client.w, client.h = width, height
    client.screen.resize(lines=height, columns=width)
    fcntl.ioctl(client.fd, termios.TIOCSWINSZ,
                struct.pack('HHHH', height, width, 0, 0))


def scaled_single_pane(rectangle, old_host, new_host):
    """Precompute the exact canonical frame/grid produced by ScaleRect."""
    left, top, right, bottom = rectangle
    old_width, old_height = old_host[0], old_host[1] - 2
    new_width, new_height = new_host[0], new_host[1] - 2

    def edge(value, old_size, new_size):
        return (value * new_size + old_size // 2) // old_size

    new_left = edge(left, old_width, new_width)
    new_top = edge(top - 1, old_height, new_height)
    new_right = edge(right + 1, old_width, new_width)
    new_bottom = edge(bottom, old_height, new_height)
    new_left = max(0, min(new_left, new_width - 16))
    new_top = max(0, min(new_top, new_height - 6))
    new_right = min(new_width, max(new_right, new_left + 16))
    new_bottom = min(new_height, max(new_bottom, new_top + 6))
    return ((new_left, new_top + 1, new_right - 1, new_bottom),
            (new_right - new_left - 2, new_bottom - new_top - 2))


def click(client, x, y):
    os.write(client.fd, f'\x1b[<0;{x + 1};{y + 1}M'.encode())
    os.write(client.fd, f'\x1b[<0;{x + 1};{y + 1}m'.encode())


def wait_zoom_preview(log_offset, timeout=0.7):
    """Wait until the daemon relays the first already-derived zoom ring."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(DEBUG_LOG):
            with open(DEBUG_LOG, 'r', encoding='utf-8',
                      errors='replace') as stream:
                stream.seek(log_offset)
                if any('layout-preview: relay pane=0 ' in line and
                       ' op=3 ' in line for line in stream):
                    return True
        time.sleep(0.005)
    return False


def attach_wire(path, width, height):
    """Attach immediately; snapshot parsing proves the host became ready."""
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.settimeout(5.0)
    try:
        peer.connect(path)
        peer.sendall(stlib.raw_frame(
            FRAME_ATTACH, -1,
            struct.pack('<iiiii', PROTO_VER, width, height, 1, 0)))
        first = stlib.read_frame(peer, timeout=5.0)
        if first is None or first[0] != FRAME_SESSION:
            raise RuntimeError('missing FRAME_SESSION')
        while True:
            frame = stlib.read_frame(peer, timeout=5.0)
            if frame is None:
                raise RuntimeError('EOF before FRAME_READY')
            if frame[0] == FRAME_READY:
                return peer
            if frame[0] != FRAME_SCREEN:
                raise RuntimeError('unexpected snapshot frame ' + str(frame[0]))
    except Exception:
        peer.close()
        raise


def wait_state(clients, session, frames, pty, zoomed=None, timeout=7.0,
               stable_for=0.2):
    deadline = time.monotonic() + timeout
    last = None
    stable_since = None
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        size, flags = pane_state(session)
        last = ([frame_rect(client) for client in clients], size, flags)
        match = (last[:2] == (list(frames), pty) and
                 (zoomed is None or (('Z' in flags) == zoomed)))
        if match:
            if stable_since is None:
                stable_since = time.monotonic()
            elif time.monotonic() - stable_since >= stable_for:
                return True
        else:
            stable_since = None
        time.sleep(0.025)
    print('  last maximize state:', last,
          'expected:', (list(frames), pty, zoomed))
    return False


def detach_client(client):
    client.send(b'\x11', 0.15)
    client.send(b'd', 0.5)
    status = client.wait_exit(6.0)
    client.close()
    return status == 0


def finish_client(client):
    if client is None:
        return
    status = client.wait_exit(1.0)
    if status is None:
        try:
            os.kill(client.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        status = client.wait_exit(1.0)
    if status is None:
        try:
            os.kill(client.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        client.wait_exit(1.0)
    client.close()


small = None
large = None
peer = None
race_wire = None
try:
    small = stlib.Client(HOME, w=SMALL_HOST[0], h=SMALL_HOST[1], lang='en',
                         env=TRACE_ENV)
    small.drain(2.5)
    sockets = stlib.session_sockets(HOME)
    check('small creator session exists', len(sockets) == 1)
    socket_path = sockets[0] if sockets else ''
    session = os.path.basename(socket_path)[:-5] if socket_path else ''
    renamed = run_cli(['rename', session + ':1', TITLE], HOME)
    check('maximize fixture pane renamed', renamed.returncode == 0)
    drain_all((small,), 0.5)
    original_small_frame = frame_rect(small)
    original_pty = pane_size(session)
    check('small creator has complete initial frame',
          original_small_frame is not None)

    if original_small_frame is None:
        raise FixtureError('fixture has no observable initial frame')

    large = stlib.Client(HOME, args=['--attach', session],
                         w=LARGE_ATTACH[0], h=LARGE_ATTACH[1], lang='en',
                         env=TRACE_ENV)
    large.drain(2.5)
    clients = (small, large)
    check('larger second client attaches', large.alive())
    check('attach alone keeps small canonical desktop',
          frame_rect(small) == original_small_frame and
          frame_rect(large) == original_small_frame and
          pane_size(session) == original_pty)

    # The larger second client now performs an explicit resize.  That is a
    # legitimate shared-desktop change and creates the important state:
    # canonical desktop larger than the minimum still-connected host.
    expected_grown_frame, expected_grown_pty = scaled_single_pane(
        original_small_frame, SMALL_HOST, LARGE_RESIZE)
    host_resize(large, LARGE_RESIZE[0], LARGE_RESIZE[1])
    check('later large resize grows canonical desktop',
          wait_state(clients, session,
                     (None, expected_grown_frame), expected_grown_pty))
    grown_frame = frame_rect(large)

    # Click the native zoom control in the later/larger client.  The final
    # shared pane must fit the small creator exactly, with the same complete
    # frame and PTY grid in both clients.
    if grown_frame is not None:
        _left, top, right, _bottom = grown_frame
        click(large, right - 3, top)
    check('normal maximize uses smallest host IDE area',
          wait_state(clients, session,
                     (SAFE_FRAME, SAFE_FRAME), SAFE_PTY, zoomed=True))

    # Zoom is reversible: using a safe maximum must not overwrite the larger
    # canonical desktop nor the exact pre-zoom restore rectangle/grid.
    maximized = frame_rect(large)
    if maximized is not None:
        _left, top, right, _bottom = maximized
        click(large, right - 3, top)
    check('safe maximize restores exact grown shared window',
          wait_state(clients, session,
                     (None, expected_grown_frame), expected_grown_pty,
                     zoomed=False))

    # The one-shot control path is daemon-owned and must enforce the same
    # invariant instead of merely changing a Zoomed flag around the old PTY.
    cli_zoom = run_cli(['zoom', session + ':1'], HOME, env={'LANG': 'C'})
    check('CLI maximize accepts shared pane', cli_zoom.returncode == 0)
    check('CLI maximize uses the same smallest host area',
          wait_state(clients, session,
                     (SAFE_FRAME, SAFE_FRAME), SAFE_PTY, zoomed=True))
    cli_restore = run_cli(['restore', session + ':1'], HOME,
                          env={'LANG': 'C'})
    check('CLI restore accepts shared pane', cli_restore.returncode == 0)
    check('CLI restore returns exact grown window and PTY',
          wait_state(clients, session,
                     (None, expected_grown_frame), expected_grown_pty,
                     zoomed=False))

    # The minimum remains authoritative when the large viewer leaves.  The
    # old count/mismatch gate failed here because one small client reports
    # HostSizesMatch=True even though the canonical desktop is still large.
    large_detached = detach_client(large)
    check('larger viewer detaches cleanly', large_detached)
    if large_detached:
        large = None
    clients = (small,)
    single_zoom = run_cli(['zoom', session + ':1'], HOME, env={'LANG': 'C'})
    check('sole small viewer can maximize', single_zoom.returncode == 0)
    check('sole small viewer still caps canonical maximum',
          wait_state(clients, session, (SAFE_FRAME,), SAFE_PTY, zoomed=True))
    single_restore = run_cli(['restore', session + ':1'], HOME,
                             env={'LANG': 'C'})
    check('sole small viewer restores', single_restore.returncode == 0)
    check('sole small restore preserves large canonical desktop',
          wait_state(clients, session, (None,), expected_grown_pty,
                     zoomed=False))

    # Two equal small viewers are another HostSizesMatch=True case.  Equal
    # physical sizes must not disable the cap when the saved desktop is larger.
    peer = stlib.Client(HOME, args=['--attach', session],
                        w=SMALL_HOST[0], h=SMALL_HOST[1], lang='en',
                        env=TRACE_ENV)
    peer.drain(2.0)
    clients = (small, peer)
    check('second equal small viewer attaches', peer.alive())
    equal_zoom = run_cli(['zoom', session + ':1'], HOME, env={'LANG': 'C'})
    check('equal small viewers can maximize', equal_zoom.returncode == 0)
    check('equal small viewers retain the minimum cap',
          wait_state(clients, session, (SAFE_FRAME, SAFE_FRAME), SAFE_PTY,
                     zoomed=True))
    equal_restore = run_cli(['restore', session + ':1'], HOME,
                            env={'LANG': 'C'})
    check('equal small viewers restore', equal_restore.returncode == 0)
    check('equal small restore is exact',
          wait_state(clients, session, (None, None), expected_grown_pty,
                     zoomed=False))
    peer_detached = detach_client(peer)
    check('equal peer detaches cleanly', peer_detached)
    if peer_detached:
        peer = None

    # Membership does not rewrite an already committed shared maximum.  Grow
    # the remaining physical viewer, maximize at that canonical size, then
    # attach a smaller viewer.  Both must retain the same large canonical PTY;
    # the small host merely clips it instead of inventing a local safe frame.
    host_resize(small, LARGE_RESIZE[0], LARGE_RESIZE[1])
    drain_all((small,), 0.8)
    large_zoom = run_cli(['zoom', session + ':1'], HOME, env={'LANG': 'C'})
    check('large sole viewer can maximize', large_zoom.returncode == 0)
    check('large sole maximum uses canonical desktop',
          wait_state((small,), session, (LARGE_MAX_FRAME,), LARGE_MAX_PTY,
                     zoomed=True))
    peer = stlib.Client(HOME, args=['--attach', session],
                        w=SMALL_HOST[0], h=SMALL_HOST[1], lang='en',
                        env=TRACE_ENV)
    peer.drain(2.0)
    clients = (small, peer)
    check('small viewer attaches after large maximum', peer.alive())
    check('attach does not split an existing shared maximum',
          wait_state(clients, session, (LARGE_MAX_FRAME, None),
                     LARGE_MAX_PTY, zoomed=True))

    # Once both are present, a fresh maximize action must use the current
    # smallest host.  Restore first, then exercise the native title control.
    post_attach_restore = run_cli(['restore', session + ':1'], HOME,
                                  env={'LANG': 'C'})
    check('post-attach restore succeeds', post_attach_restore.returncode == 0)
    check('post-attach restore remains canonical',
          wait_state(clients, session, (expected_grown_frame, None),
                     expected_grown_pty, zoomed=False))
    restored = frame_rect(small)
    if restored is not None:
        _left, top, right, _bottom = restored
        click(small, right - 3, top)
    check('fresh native maximize after attach uses new minimum',
          wait_state(clients, session, (SAFE_FRAME, SAFE_FRAME), SAFE_PTY,
                     zoomed=True))
    resize_zoomed = run_cli(['resize', session + ':1', '40x10'], HOME,
                             env={'LANG': 'C'})
    check('explicit PTY resize rejects a maximized pane',
          resize_zoomed.returncode != 0 and
          'restore' in (resize_zoomed.stdout + resize_zoomed.stderr).lower())
    check('rejected resize preserves canonical maximum',
          wait_state(clients, session, (SAFE_FRAME, SAFE_FRAME), SAFE_PTY,
                     zoomed=True))

    # Exercise the client's acknowledgement path under the same TOCTOU race
    # as the raw protocol test.  With zoom animation enabled, the large sole
    # viewer derives its proposal before the animation; a small attach during
    # those eight frames makes the daemon normalize that already-derived
    # intent when it arrives.
    race_restore = run_cli(['restore', session + ':1'], HOME,
                           env={'LANG': 'C'})
    check('TOCTOU setup restores the shared pane',
          race_restore.returncode == 0 and
          wait_state(clients, session, (expected_grown_frame, None),
                     expected_grown_pty, zoomed=False))
    race_peer_detached = detach_client(peer)
    check('TOCTOU setup detaches the small peer', race_peer_detached)
    if race_peer_detached:
        peer = None
    clients = (small,)
    check('TOCTOU setup leaves one large restored viewer',
          wait_state(clients, session, (expected_grown_frame,),
                     expected_grown_pty, zoomed=False))

    log_offset = os.path.getsize(DEBUG_LOG) if os.path.exists(DEBUG_LOG) else 0
    race_rect = frame_rect(small)
    if race_rect is not None:
        _left, top, right, _bottom = race_rect
        click(small, right - 3, top)
    preview_started = wait_zoom_preview(log_offset)
    check('TOCTOU maximize derived its large animated target',
          preview_started)
    # Use an already-running raw protocol peer here rather than launching a
    # second executable inside the remaining animation window. Sending ATTACH
    # immediately after the first relayed ring deterministically changes the
    # daemon's commit-time minimum while the actor retains its large proposal.
    race_wire = attach_wire(socket_path, SMALL_HOST[0], SMALL_HOST[1])
    clients = (small,)
    check('small attach during maximize normalizes the stale proposal',
          wait_state(clients, session, (SAFE_FRAME,), SAFE_PTY,
                     zoomed=True))
    peer = stlib.Client(HOME, args=['--attach', session],
                        w=SMALL_HOST[0], h=SMALL_HOST[1], lang='en',
                        env=TRACE_ENV)
    peer.drain(2.0)
    clients = (small, peer)
    check('normalized maximum is identical in a real late viewer',
          wait_state(clients, session, (SAFE_FRAME, SAFE_FRAME), SAFE_PTY,
                     zoomed=True))
    with open(DEBUG_LOG, 'r', encoding='utf-8', errors='replace') as stream:
        stream.seek(log_offset)
        race_log = stream.read()
    check('normalized maximize is acknowledged, never rejected',
          (f'remote-zoom: proposed pane=0 zoom=1 full=0 '
           f'pty={LARGE_MAX_PTY[0]}x{LARGE_MAX_PTY[1]}') in race_log and
          'remote-zoom: acknowledged pane=0' in race_log and
          'remote-zoom: rejected' not in race_log)
except FixtureError as error:
    print('  fixture error:', error)
finally:
    if race_wire is not None:
        try:
            race_wire.sendall(stlib.raw_frame(FRAME_DETACH, -1))
        except OSError:
            pass
        race_wire.close()
    stlib.close_all_daemons(HOME)
    finish_client(peer)
    finish_client(large)
    finish_client(small)

stlib.report()
