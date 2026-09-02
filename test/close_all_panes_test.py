#!/usr/bin/env python3
"""Close all is one atomic visual transition, not sixteen close animations.

The shared-session half deliberately starts at the hard limit of sixteen
panes and attaches a second real UI.  The first client chooses
Windows -> Close all windows while both PTYs record every DEC synchronized
screen update.  Neither renderer may ever present an intermediate 15..1 pane
desktop, nor repaint the final empty desktop twice.

The daemon state is checked independently through a fresh attach snapshot:
zero panes means an empty layout string and focus -1.  The observer then
creates the first pane again through the real Classes menu, proving that both
clients stayed attached and received the same new canonical workspace.

``server=detach`` exercises the separate in-process implementation with the
same one-paint contract.
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


SESSION = 'close-all'
SYNC_ENV = {
    'SUPERTERM_REAP_MS': '300000',
    'SUPERTERM_SYNC': '1',
}


def write_config(home, server_mode):
    path = home + '/.superterm/superterm.ini'
    with open(path, 'w', encoding='utf-8') as stream:
        stream.write(
            '[ui]\n'
            'language=en\n'
            'background=none\n'
            '[session]\n'
            f'server={server_mode}\n'
            'autorestore=0\n'
            'autosave=0\n')


def drain_all(clients, seconds=0.8):
    """Drain peers fairly so a fast actor cannot hide a stale observer."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            if client is not None:
                client.drain(0.025)


def wait_for(predicate, clients=(), timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        if predicate():
            return True
        time.sleep(0.02)
    drain_all(clients, 0.12)
    return predicate()


def display_of(value):
    return value['display'] if isinstance(value, dict) else value.screen.display


def cells_of(value):
    if isinstance(value, dict):
        return value['cells']
    return tuple(tuple(value.screen.buffer[y][x] for x in range(value.w))
                 for y in range(value.h))


def frame_rects(value):
    """Return every complete FreeVision frame, including the open menu."""
    rows = display_of(value)
    result = set()
    for top, row in enumerate(rows):
        for left, char in enumerate(row):
            if char not in ('╔', '┌'):
                continue
            for right in range(left + 2, len(row)):
                if row[right] not in ('╗', '┐'):
                    continue
                found = False
                for bottom in range(top + 2, len(rows)):
                    if (rows[bottom][left] in ('╚', '└') and
                            rows[bottom][right] in ('╝', '┘')):
                        result.add((left, top, right, bottom))
                        found = True
                        break
                if found:
                    break
    return frozenset(result)


def presentation_signature(value):
    """Exact rendered cells and exact set of complete frame rectangles."""
    return cells_of(value), frame_rects(value)


def reverse_only_cell(before, after):
    return (before.reverse != after.reverse and
            before._replace(reverse=False) == after._replace(reverse=False))


def allowed_menu_prefix(record, references):
    """Allow only cellwise states from the captured menu/base envelope.

    FreeVision restores a modal menu in several synchronized writes.  A
    physical transaction can therefore contain the restored value for some
    cells and the still-open-menu value for others.  Requiring either whole
    snapshot verbatim rejects that legitimate incremental teardown.  Every
    visible glyph must nevertheless equal one of the two independently
    captured states, and every complete frame must retain one of their exact
    geometry sets.  Attribute-only focus/cursor restoration is deliberately
    allowed; a blank, displaced or partially closed workspace cannot pass.
    """
    if len(references) != 2:
        return False
    baseline_cells, baseline_frames = references[0]
    menu_cells, menu_frames = references[1]
    observed_frames = frame_rects(record)
    if observed_frames not in (baseline_frames, menu_frames):
        return False
    menu_only = menu_frames - baseline_frames
    last_row = len(baseline_cells) - 1

    def menu_owned(x, y):
        # Selection changes are allowed within the exact captured menu and
        # its FreeVision shadow. TMenuBox.Draw owns a one-column left gutter
        # before the first corner frame_rects can observe. The application
        # menu/status rows also show the active mnemonic while a modal menu is
        # being dispatched.
        return (y in (0, last_row) or any(
            left - 1 <= x <= right + 2 and top <= y <= bottom + 1
            for left, top, right, bottom in menu_only))

    for y, (baseline_row, menu_row, observed_row) in enumerate(zip(
            baseline_cells, menu_cells, record['cells'])):
        for x, (baseline, menu, observed) in enumerate(zip(
                baseline_row, menu_row, observed_row)):
            if (not menu_owned(x, y) and
                    observed.data != baseline.data and
                    observed.data != menu.data):
                return False
    return True


def menu_prefix_mismatches(record, references, limit=12):
    """Describe cells outside the two captured states after a rejection."""
    baseline_cells, _baseline_frames = references[0]
    menu_cells, _menu_frames = references[1]
    result = []
    for y, (baseline_row, menu_row, observed_row) in enumerate(zip(
            baseline_cells, menu_cells, record['cells'])):
        for x, (baseline, menu, observed) in enumerate(zip(
                baseline_row, menu_row, observed_row)):
            if (observed.data != baseline.data and
                    observed.data != menu.data):
                result.append((x, y, baseline, menu, observed))
                if len(result) >= limit:
                    return result
    return result


def frame_count(value):
    """Count visible window top-left corners in a rendered screen."""
    return sum(row.count('╔') + row.count('┌') for row in display_of(value))


def compact(values):
    result = []
    for value in values:
        if not result or result[-1] != value:
            result.append(value)
    return result


def structural(records):
    """Keep every presentation which changes even one visible cell."""
    return [record for record in records
            if record['changed_cells'] > 0 and
            not stlib.cursor_only_transition(record)]


def destructive_direct(record):
    """A clear outside DEC 2026 can flash even if the final cells match."""
    if record['kind'] != 'direct':
        return False
    raw = record['raw']
    return (re.search(br'\x1b\[[0-?]*[ -/]*[JKXPLM@]', raw) is not None or
            b'\x1bc' in raw or b'\x1b#8' in raw)


def check_single_empty_paint(label, records, initial_count,
                             allowed_prefix=()):
    """Reject partial closes, rollback, blank flashes and duplicate paints.

    The actor and the local UI necessarily dismiss their modal Windows menu
    before the application command is dispatched.  Those records contain
    only the exact captured menu or exact captured N-pane baseline; discard
    that prefix.  Frame counts alone are insufficient because a partial or
    displaced workspace can retain N corners.  From the first other state
    onward there must still be precisely one synchronized N-to-zero
    presentation.  The observer has no allowed prefix.
    """
    updates = structural(records)
    prefix_updates = []
    while (updates and allowed_prefix and
           allowed_menu_prefix(updates[0], allowed_prefix)):
        prefix_updates.append(updates.pop(0))
    path = compact([initial_count] +
                   [frame_count(record) for record in updates])
    if len(updates) != 1 or path != [initial_count, 0]:
        print(f'  {label} path:', ' -> '.join(map(str, path)))
        if prefix_updates:
            print(f'  {label} exact menu-dismiss prefix:',
                  [(record['kind'], record['changed_cells'],
                    frame_count(record), sorted(frame_rects(record)))
                   for record in prefix_updates])
        print(f'  {label} updates:',
              [(record['kind'], record['changed_cells'], frame_count(record),
                sorted(frame_rects(record)))
               for record in updates])
        if allowed_prefix and updates:
            mismatches = menu_prefix_mismatches(updates[0], allowed_prefix)
            if mismatches:
                print(f'  {label} menu-envelope mismatches:', mismatches)
    bad_direct = [record for record in records if destructive_direct(record)]
    if bad_direct:
        print(f'  {label} destructive direct writes:',
              [(record['changed_cells'], len(record['raw']))
               for record in bad_direct])
    check(label,
          len(updates) == 1 and updates[0]['kind'] == 'sync' and
          path == [initial_count, 0] and not bad_direct)


def open_close_all_menu(client):
    client.send(b'\x1bw', 0.40)       # Alt-W: Windows
    return 'Close all windows' in client.text()


def open_local_shell(client):
    client.send(b'\x1bc', 0.35)       # Alt-C: Classes
    visible = 'Local shell' in client.text()
    client.send(b'1', 0.06)
    return visible


def shell_token_command(*parts):
    """Build a token in the shell so the echoed input cannot satisfy it."""
    marker = ''.join(parts)
    command = ("printf '%s' " + ' '.join("'" + part + "'"
                                          for part in parts) +
               "; printf '\\n'\r").encode('ascii')
    if marker.encode('ascii') in command:
        raise AssertionError('marker must not occur in echoed command')
    return marker, command


def detach(client):
    if client is None:
        return
    client.send(b'\x11', 0.08)        # configured prefix: Ctrl-Q
    client.send(b'd', 0.25)
    client.wait_exit(timeout=6.0)
    client.close()


def protocol_version():
    path = os.path.join(os.path.dirname(__file__), '..', 'src',
                        'st_server.pas')
    with open(path, encoding='utf-8') as stream:
        for line in stream:
            match = re.match(r'\s*ATTACH_PROTO_VER\s*=\s*(\d+)', line)
            if match:
                return int(match.group(1))
    raise RuntimeError('ATTACH_PROTO_VER not found')


def canonical_snapshot(home):
    """Read nodes/focus/count from the authoritative attach snapshot."""
    sockets = stlib.session_sockets(home)
    if len(sockets) != 1:
        return {}
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.settimeout(5.0)
    try:
        peer.connect(sockets[0])
        payload = struct.pack('<iiiii', protocol_version(), 160, 50, 1, 0)
        peer.sendall(stlib.raw_frame(1, -1, payload))  # FRAME_ATTACH
        frame = stlib.read_frame(peer, timeout=5.0)
        if frame is None or frame[0] != 20:            # FRAME_SESSION
            return {}
        nodes, offset = stlib.read_pas_string(frame[2], 0)
        if offset + 8 > len(frame[2]):
            return {}
        focused, panes = struct.unpack_from('<ii', frame[2], offset)
        while True:
            frame = stlib.read_frame(peer, timeout=5.0)
            if frame is None:
                return {}
            if frame[0] == 22:                         # FRAME_READY
                break
            if frame[0] != 21:                         # FRAME_SCREEN
                return {}
        peer.sendall(stlib.raw_frame(4, -1))           # FRAME_DETACH
        return {'nodes': nodes, 'focused': focused, 'panes': panes}
    except (OSError, socket.timeout, struct.error, ValueError):
        return {}
    finally:
        peer.close()


def daemon_pane_count(home):
    result = run_cli(['list', SESSION], home, env={'LANG': 'C'})
    if result.returncode != 0:
        return -1
    return sum(bool(re.match(r'^\d+\s', line))
               for line in result.stdout.splitlines())


# --------------------------------------------------------- shared daemon

remote_home = stlib.fresh_home('close-all-panes')
write_config(remote_home, 'always')
a = None
b = None
try:
    a = stlib.Client(remote_home, args=['--session', SESSION],
                     w=160, h=50, lang='en', env=SYNC_ENV)
    a.drain(2.5)

    # Build a balanced 4x4 split tree.  Repeatedly splitting only the focused
    # leaf creates a 16-deep tree whose minimum-size rectangles overlap, so
    # closing a hidden leaf would not be observable by a corner-count test.
    # Descending targets preserve the indexes of every not-yet-split leaf.
    creates = []
    for direction in ('--right', '--down', '--right', '--down'):
        old_count = len(creates) + 1
        for pane in range(old_count, 0, -1):
            creates.append(run_cli(
                ['new', f'{SESSION}:{pane}', direction], remote_home,
                env={'LANG': 'C'}))
    check('sixteen-pane setup succeeds',
          all(result.returncode == 0 for result in creates) and
          wait_for(lambda: daemon_pane_count(remote_home) == 16, (a,)))

    # Expose every frame.  Overlapped windows could let an intermediate close
    # escape a corner count even though the user would still see the repaint.
    # Tiling itself acquires a revision-checked global lease.  The daemon can
    # finish the fifteen synchronous CLI controls before this rendered client
    # has consumed every NEWPANE_EV, in which case the first lease is
    # correctly denied. Retry the idempotent setup action after draining; the
    # close operation measured below is executed only after all 16 are visible.
    tiled = False
    for _attempt in range(6):
        a.send(b'\x11', 0.06)
        a.send(b't', 0.75)
        tiled = frame_count(a) == 16
        if tiled:
            break
    check('actor visibly tiles sixteen panes', tiled)

    b = stlib.Client(remote_home, args=['--attach', SESSION],
                     w=160, h=50, lang='en', env=SYNC_ENV)
    drain_all((a, b), 2.7)
    check('observer attaches to all sixteen',
          b.alive() and frame_count(a) == 16 and frame_count(b) == 16)

    remote_baseline = presentation_signature(a)
    check('Windows menu exposes Close all', open_close_all_menu(a))
    remote_menu = presentation_signature(a)
    a.begin_transition_capture()
    b.begin_transition_capture()
    stlib.write_all(a.fd, b'c')       # mnemonic: Close all windows
    drain_all((a, b), 2.0)
    actor_records = a.end_transition_capture()
    observer_records = b.end_transition_capture()

    check_single_empty_paint('actor presents one 16-to-0 paint',
                             actor_records, 16,
                             allowed_prefix=(remote_baseline, remote_menu))
    check_single_empty_paint('observer presents one 16-to-0 paint',
                             observer_records, 16)
    check('both clients stay attached at zero',
          a.alive() and b.alive() and len(stlib.session_sockets(remote_home)) == 1)
    check('both rendered desktops are empty',
          frame_count(a) == 0 and frame_count(b) == 0 and
          daemon_pane_count(remote_home) == 0)

    empty = canonical_snapshot(remote_home)
    if empty != {'nodes': '', 'focused': -1, 'panes': 0}:
        print('  empty canonical snapshot:', empty)
    check('daemon publishes canonical empty layout',
          empty == {'nodes': '', 'focused': -1, 'panes': 0})

    check('observer can recreate Local shell', open_local_shell(b))
    recreated = wait_for(
        lambda: (daemon_pane_count(remote_home) == 1 and
                 frame_count(a) == 1 and frame_count(b) == 1),
        (a, b))
    check('first pane reappears in both clients', recreated)
    one = canonical_snapshot(remote_home) if recreated else {}
    check('recreated pane is canonical and focused',
          one.get('nodes') == 'L' and one.get('focused') == 0 and
          one.get('panes') == 1)

    marker, marker_command = shell_token_command('CLOSE_ALL_',
                                                 'RECREATED_OK')
    b.send(marker_command, 0.10)
    shared_output = wait_for(
        lambda: marker in a.text() and marker in b.text(), (a, b))
    check('recreated pane output reaches both', shared_output)
finally:
    detach(b)
    detach(a)
    stlib.close_all_daemons(remote_home)


# ------------------------------------------------------------ local mode

local_home = stlib.fresh_home('close-all-panes-local')
write_config(local_home, 'detach')
local = None
try:
    local = stlib.Client(local_home, w=120, h=38, lang='en', env=SYNC_ENV)
    local.drain(2.0)
    for _ in range(3):
        local.send(b'\x1bOQ', 0.45)   # F2: create another local pane
    local.send(b'\x11', 0.08)
    local.send(b't', 0.9)
    check('local branch starts with four panes',
          not stlib.session_sockets(local_home) and frame_count(local) == 4)

    local_baseline = presentation_signature(local)
    check('local Windows menu exposes Close all', open_close_all_menu(local))
    local_menu = presentation_signature(local)
    local.begin_transition_capture()
    stlib.write_all(local.fd, b'c')
    local.drain(1.2)
    local_records = local.end_transition_capture()
    check_single_empty_paint('local presents one 4-to-0 paint',
                             local_records, 4,
                             allowed_prefix=(local_baseline, local_menu))
    check('local UI stays alive and empty',
          local.alive() and frame_count(local) == 0)

    check('local zero desktop can create pane', open_local_shell(local))
    check('local recreated pane is usable', wait_for(
        lambda: frame_count(local) == 1, (local,)))
    local_marker, local_command = shell_token_command(
        'LOCAL_CLOSE_ALL_', 'RECREATED_OK')
    local.send(local_command, 0.8)
    check('local recreated shell receives input',
          local_marker in local.text())
finally:
    if local is not None and local.alive():
        local.send(b'\x1bx', 0.4)     # Alt-X: Exit
        local.wait_exit(timeout=6.0)
    if local is not None:
        local.close()
    stlib.close_all_daemons(local_home)


stlib.report()
