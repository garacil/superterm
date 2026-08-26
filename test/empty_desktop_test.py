#!/usr/bin/env python3
"""Zero panes is a complete shared-session state, not a terminal condition.

This is deliberately an end-to-end UI test. Control-only creation used to
hide the bug because it could recreate a daemon pane while attached clients
still rejected the empty layout revision. The regression therefore drives
the real Classes and Panes menus and checks all three views of the state:

* the daemon's pane list;
* the window frames rendered by every attached client; and
* real shell input/output after the first pane is recreated.

It also detaches every viewer while the session has zero panes, reattaches two
fresh clients to that same empty session, and makes both clients request panes
concurrently. Both FIFO commands must execute, one after the other, without
mutating the empty split tree simultaneously. Finally it drives two complete
0 -> 16 -> 0 cycles, alternating the actor on every action, and verifies the
visible maximum-pane guard.
"""
import configparser
import os
import re
import socket
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('emptydesk')
SESSION = 'zero-panes'
ENV = {'SUPERTERM_REAP_MS': '300000'}
INI = HOME + '/.superterm/superterm.ini'


def write_config(class_enabled):
    with open(INI, 'w', encoding='utf-8') as stream:
        stream.write('[ui]\nlanguage=en\nbackground=none\n'
                     '[session]\nserver=always\nautorestore=0\nautosave=0\n'
                     '[class.cycle]\nname=cycle\ntitle=cycle\n'
                     f'enabled={int(class_enabled)}\ncmd=\n')


# Keep the reusable class disabled during fresh startup, otherwise classes are
# autostart panes. It is enabled before the two fresh reattached UIs start.
write_config(False)


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
FRAME_ATTACH = 1
FRAME_DETACH = 4
FRAME_SESSION = 20
FRAME_SCREEN = 21
FRAME_READY = 22


def drain_all(clients, seconds=0.8):
    """Drain every viewer fairly, so one client cannot hide a stale peer."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for client in clients:
            if client is not None:
                client.drain(0.025)


def wait_for(predicate, clients=(), timeout=8.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        drain_all(clients, 0.08)
        if predicate():
            return True
        time.sleep(0.02)
    drain_all(clients, 0.1)
    return predicate()


def pane_rows():
    result = run_cli(['list', SESSION], HOME, env={'LANG': 'C'})
    if result.returncode != 0:
        return []
    return [line for line in result.stdout.splitlines()
            if re.match(r'^\d+\s', line)]


def pane_count():
    return len(pane_rows())


def capture_has(*tokens):
    result = run_cli(['capture', SESSION + ':1'], HOME)
    return result.returncode == 0 and all(token in result.stdout
                                          for token in tokens)


def sidecar_state():
    path = HOME + '/.superterm/sessions/' + SESSION + '.ini'
    parser = configparser.ConfigParser()
    try:
        parser.read(path)
        return {
            'panes': parser.getint('session', 'panes', fallback=-99),
            'attached': parser.getint('session', 'attached', fallback=-99),
        }
    except (OSError, configparser.Error, ValueError):
        return {}


def frame_count(client):
    """Count top-left window corners, independent of active/inactive style."""
    return sum(row.count('╔') + row.count('┌')
               for row in client.screen.display)


def top_frames(client):
    """Return every visible top frame and its exact two number cells.

    Grid order is pane order. Reading at right-6/right-5 is the screen-space
    form of frame-local Size.X-7/Size.X-6; digits in titles or pane contents
    therefore cannot satisfy the assertion.
    """
    frames = []
    for y, row in enumerate(client.screen.display):
        lefts = [x for x, char in enumerate(row) if char in ('╔', '┌')]
        rights = [x for x, char in enumerate(row) if char in ('╗', '┐')]
        for left, right in zip(lefts, rights):
            if right <= left or right - left + 1 < 14:
                continue
            number_x = right - 6
            frames.append({
                'x': left,
                'y': y,
                'right': right,
                'number_x': number_x,
                'number': row[number_x:number_x + 2],
                'border': row[left:right + 1],
            })
    return sorted(frames, key=lambda frame: (frame['y'], frame['x']))


def all_empty(clients):
    state = sidecar_state()
    return (pane_count() == 0 and state.get('panes') == 0 and
            all(frame_count(client) == 0 for client in clients))


def snapshot_layout_head():
    """Read authoritative nodes/focus/count from a real attach snapshot."""
    paths = stlib.session_sockets(HOME)
    if len(paths) != 1:
        return {}
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.settimeout(5.0)
    try:
        peer.connect(paths[0])
        peer.sendall(stlib.raw_frame(
            FRAME_ATTACH, -1,
            struct.pack('<iiiii', PROTO_VER, 100, 30, 1, 0)))
        frame = stlib.read_frame(peer, timeout=5.0)
        if frame is None or frame[0] != FRAME_SESSION:
            return {}
        payload = frame[2]
        nodes, offset = stlib.read_pas_string(payload, 0)
        if offset + 8 > len(payload):
            return {}
        focused, count = struct.unpack_from('<ii', payload, offset)
        while True:
            frame = stlib.read_frame(peer, timeout=5.0)
            if frame is None:
                return {}
            if frame[0] == FRAME_READY:
                break
            if frame[0] != FRAME_SCREEN:
                return {}
        peer.sendall(stlib.raw_frame(FRAME_DETACH, -1))
        return {'nodes': nodes, 'focused': focused, 'panes': count}
    except (OSError, socket.timeout, struct.error, ValueError):
        return {}
    finally:
        peer.close()


def wait_empty(label, clients):
    ui_ok = wait_for(lambda: all_empty(clients), clients)
    snapshot = snapshot_layout_head() if ui_ok else {}
    snapshot_ok = (snapshot.get('nodes') == '' and
                   snapshot.get('panes') == 0 and
                   snapshot.get('focused') == -1)
    ok = ui_ok and snapshot_ok
    if not ok:
        print('  empty-state diagnostic:', sidecar_state(),
              'snapshot=', snapshot,
              'rows=', repr(pane_rows()),
              'frames=', [frame_count(client) for client in clients])
    check(label, ok)
    return ok


def open_local_shell(client):
    """Choose Classes -> Local shell through the actual UI."""
    client.send(b'\x1bc', 0.35)       # Alt-C: Classes menu
    menu_visible = 'Local shell' in client.text()
    client.send(b'1', 0.05)
    return menu_visible


def close_last_pane(client):
    """Choose Panes -> Close pane through the actual UI."""
    client.send(b'\x1bp', 0.35)       # Alt-P: Panes menu
    menu_visible = 'Close pane' in client.text()
    client.send(b'c', 0.05)
    return menu_visible


def choose_cycle_class(client, settle=0.10):
    """Choose the enabled test class, entry 2 after Local shell."""
    client.send(b'\x1bc', settle)
    menu_visible = 'cycle' in client.text()
    client.send(b'2', 0.015)
    return menu_visible


def close_pane_fast(client):
    client.send(b'\x1bp', 0.10)
    menu_visible = 'Close pane' in client.text()
    client.send(b'c', 0.015)
    return menu_visible


def detach(client):
    client.send(b'\x11', 0.10)        # configured prefix: Ctrl-Q
    client.send(b'd', 0.25)
    status = client.wait_exit(timeout=6.0)
    client.close()
    return status == 0


# Start one always-server session and attach a second real UI.
a = stlib.Client(HOME, args=['--session', SESSION], w=100, h=30,
                 lang='en', env=ENV)
a.drain(2.5)
b = stlib.Client(HOME, args=['--attach', SESSION], w=100, h=30,
                 lang='en', env=ENV)
drain_all((a, b), 2.5)
check('session starts with one pane', pane_count() == 1)
check('both clients start attached', a.alive() and b.alive() and
      sidecar_state().get('attached') == 2)
check('both clients render the pane', frame_count(a) == 1 and
      frame_count(b) == 1)

# Give the original frame an unmistakable title. Its disappearance proves
# that both clients applied the kill, rather than merely that the daemon did.
renamed = run_cli(['rename', SESSION + ':1', 'BEFORE_ZERO'], HOME)
check('baseline rename succeeds', renamed.returncode == 0)
check('baseline title reaches both clients', wait_for(
    lambda: 'BEFORE_ZERO' in a.text() and 'BEFORE_ZERO' in b.text(),
    (a, b)))

# A closes the last pane. Zero panes and focus=-1 must become one canonical
# state in the daemon and in both UIs.
check('Panes menu can close the last pane', close_last_pane(a))
wait_empty('both clients apply the empty desktop', (a, b))
check('empty desktop keeps both clients alive', a.alive() and b.alive())
check('closed title disappears everywhere',
      'BEFORE_ZERO' not in a.text() and 'BEFORE_ZERO' not in b.text())

# Recreate the first pane from the same Classes -> Local shell action reported
# by the user. A daemon count is not enough: both clients must draw it and
# both must route input to its real PTY.
check('Classes menu works with zero panes', open_local_shell(a))
check('one UI request creates one pane', wait_for(
    lambda: pane_count() == 1 and frame_count(a) == 1 and
    frame_count(b) == 1, (a, b)))
a.send(b"printf 'CREATED_FROM_A\\n'\r", 0.08)
b.send(b"printf 'WRITTEN_FROM_B\\n'\r", 0.08)
check('recreated pane accepts both clients', wait_for(
    lambda: capture_has('CREATED_FROM_A', 'WRITTEN_FROM_B'), (a, b)))
check('recreated output reaches both clients', wait_for(
    lambda: all('CREATED_FROM_A' in client.text() and
                'WRITTEN_FROM_B' in client.text()
                for client in (a, b)), (a, b)))

# Queue the reported worst ordering in one host write: close the last pane and
# immediately select Classes -> Local shell, without draining the zero-pane
# KILL/LAYOUT events in between. The old client-side pre-lock used its stale
# revision and silently lost this NEWPANE request.
temporal_rename = run_cli(
    ['rename', SESSION + ':1', 'TEMPORAL_OLD_PANE'], HOME)
check('temporal case baseline renamed', temporal_rename.returncode == 0 and
      wait_for(lambda: 'TEMPORAL_OLD_PANE' in a.text() and
               'TEMPORAL_OLD_PANE' in b.text(), (a, b)))
try:
    os.write(b.fd, b'\x1bpc\x1bc1')  # Alt-P,c then Alt-C,1; no drain here
    temporal_sent = True
except OSError:
    temporal_sent = False
check('close+new UI burst was queued', temporal_sent)
temporal_recreated = wait_for(
    lambda: (pane_count() == 1 and frame_count(a) == 1 and
             frame_count(b) == 1 and
             'TEMPORAL_OLD_PANE' not in a.text() and
             'TEMPORAL_OLD_PANE' not in b.text()),
    (a, b), timeout=8.0)
check('close+new burst recreates first pane', temporal_recreated)
if temporal_recreated:
    a.send(b"printf 'TEMPORAL_RECREATE_OK\\n'\r", 0.06)
check('close+new burst pane is usable', temporal_recreated and wait_for(
    lambda: capture_has('TEMPORAL_RECREATE_OK'), (a, b)))

# B can close the same shared last pane too. Then every viewer detaches,
# leaving the live daemon in its legitimate zero-pane/zero-viewer state.
check('second client can close the last pane', close_last_pane(b))
wait_empty('second close reaches zero everywhere', (a, b))
check('first zero-pane client detaches', detach(a))
check('second zero-pane client detaches', detach(b))
check('empty session survives zero viewers', wait_for(
    lambda: (len(stlib.session_sockets(HOME)) == 1 and
             sidecar_state().get('attached') == 0 and pane_count() == 0)))

# The daemon has already loaded this class definition while creating the
# earlier local shell. Fresh clients now expose it in their Classes menus;
# the daemon-side definition is otherwise identical.
write_config(True)

# Two completely new processes must be able to attach to the zero-pane
# snapshot. This is where the old client rejected PaneCount=0 outright.
c = stlib.Client(HOME, args=['--attach', SESSION], w=100, h=30,
                 lang='en', env=ENV)
d = stlib.Client(HOME, args=['--attach', SESSION], w=100, h=30,
                 lang='en', env=ENV)
drain_all((c, d), 2.5)
c_alive = c.alive()
d_alive = d.alive()
fresh_attach_ok = (c_alive and d_alive and
                   len(stlib.session_sockets(HOME)) == 1 and
                   sidecar_state().get('attached') == 2)
if not fresh_attach_ok:
    print('  fresh-attach diagnostic:',
          {'c_pid': c.pid, 'c_alive': c_alive,
           'd_pid': d.pid, 'd_alive': d_alive,
           'sidecar': sidecar_state(),
           'sockets': stlib.session_sockets(HOME)})
    print('  client c tail:', repr(c.text()[-600:]))
    print('  client d tail:', repr(d.text()[-600:]))
check('two fresh clients attach to zero panes', fresh_attach_ok)
check('reattached clients receive empty desktop',
      pane_count() == 0 and frame_count(c) == 0 and frame_count(d) == 0)

# A failed process attach makes every later menu assertion a meaningless
# cascade. Report the one precise failure above and clean up; the concurrent
# command stress begins only with two proven live peers.
if not fresh_attach_ok:
    if c_alive:
        detach(c)
    else:
        c.close()
    if d_alive:
        detach(d)
    else:
        d.close()
    stlib.close_all_daemons(HOME)
    stlib.report()

# Open the Classes menu in both clients first, then release both selections at
# one barrier. Both commands are valid. The daemon's single FIFO consumer must
# serialize their structural leases and create two panes, never lose one and
# never let both mutate pane zero simultaneously.
def concurrent_first_pair(clients, cycle):
    left, right = clients
    left.send(b'\x1bc', 0.12)
    right.send(b'\x1bc', 0.12)
    menus = 'cycle' in left.text() and 'cycle' in right.text()
    barrier = threading.Barrier(3)
    send_errors = []

    def choose(client):
        try:
            barrier.wait(timeout=3.0)
            os.write(client.fd, b'2')
        except Exception as exc:
            send_errors.append(repr(exc))

    threads = [threading.Thread(target=choose, args=(client,))
               for client in clients]
    for thread in threads:
        thread.start()
    barrier.wait(timeout=3.0)
    for thread in threads:
        thread.join(timeout=3.0)
    delivered = not send_errors and all(not thread.is_alive()
                                        for thread in threads)
    check(f'cycle {cycle} concurrent menus opened', menus)
    check(f'cycle {cycle} concurrent requests delivered', delivered)
    both_created = wait_for(lambda: pane_count() == 2, clients, timeout=6.0)
    check(f'cycle {cycle} FIFO creates both panes', both_created)
    return menus and delivered and both_created


def fill_to_max(clients, cycle):
    ok = concurrent_first_pair(clients, cycle)
    # Panes 3..16 alternate actors. Wait for each exact count so the next UI
    # command never rests on an assumed event ordering or arbitrary sleep.
    for expected in range(3, 17):
        actor = clients[(expected + cycle) & 1]
        menu_ok = choose_cycle_class(actor)
        created = wait_for(lambda expected=expected:
                           pane_count() == expected, clients, timeout=5.0)
        ok = ok and menu_ok and created
        if not created:
            print(f'  creation stopped at expected={expected} '
                  f'actual={pane_count()} state={sidecar_state()}')
            break
    check(f'cycle {cycle} alternating UI fill reaches 16',
          ok and pane_count() == 16)
    return ok and pane_count() == 16


def expose_all_panes(clients, cycle):
    names = [f'C{cycle}P{index:02d}' for index in range(1, 17)]
    renamed_all = True
    for index, name in enumerate(names, 1):
        result = run_cli(['rename', f'{SESSION}:{index}', name], HOME)
        renamed_all = renamed_all and result.returncode == 0
    organized = run_cli(['organize', SESSION, 'grid'], HOME)
    prefix = f'C{cycle}P'
    visible = wait_for(lambda: all(
        len(top_frames(client)) == 16 and
        all(prefix in frame['border'] for frame in top_frames(client))
        for client in clients), clients, timeout=8.0)
    if organized.returncode != 0 or not visible:
        print(f'  cycle {cycle} organize: rc={organized.returncode} '
              f'out={organized.stdout!r} err={organized.stderr!r}')
        for client_no, client in enumerate(clients, 1):
            print(f'  cycle {cycle} client {client_no} '
                  f'top_frames={top_frames(client)!r}')
            print('\n'.join('    ' + row for row in client.screen.display))
    number_diagnostics = []
    numbers_ok = True
    for client_no, client in enumerate(clients, 1):
        frames = top_frames(client)
        for pane_no in range(10, 17):
            if len(frames) >= pane_no:
                frame = frames[pane_no - 1]
                actual = frame['number']
                coords = (frame['x'], frame['y'], frame['right'],
                          frame['number_x'])
            else:
                actual = ''
                coords = None
            if actual != str(pane_no):
                numbers_ok = False
                number_diagnostics.append(
                    (client_no, pane_no, actual, coords))
    check(f'cycle {cycle} all 16 panes renamed', renamed_all)
    check(f'cycle {cycle} all 16 visible in both UIs',
          organized.returncode == 0 and visible)
    if number_diagnostics:
        print(f'  cycle {cycle} frame-number diagnostics:',
              number_diagnostics)
    check(f'cycle {cycle} frame numbers 10..16 exact',
          organized.returncode == 0 and visible and numbers_ok)
    return (renamed_all and organized.returncode == 0 and visible and
            numbers_ok)


def reject_seventeenth(clients, cycle):
    actor = clients[cycle & 1]
    menu_ok = choose_cycle_class(actor, settle=0.12)
    dialog = wait_for(lambda: 'Maximum 16 panes' in actor.text(),
                      clients, timeout=4.0)
    stayed_full = pane_count() == 16
    check(f'cycle {cycle} 17th opens maximum dialog', menu_ok and dialog)
    check(f'cycle {cycle} 17th leaves exactly 16 panes', stayed_full)
    if dialog:
        actor.send(b'\r', 0.15)
    return menu_ok and dialog and stayed_full


def close_all_panes(clients, cycle):
    ok = True
    for before in range(16, 0, -1):
        actor = clients[(before + cycle) & 1]
        menu_ok = close_pane_fast(actor)
        expected = before - 1
        closed = wait_for(lambda expected=expected:
                          pane_count() == expected, clients, timeout=5.0)
        ok = ok and menu_ok and closed
        if not closed:
            print(f'  close stopped at before={before} '
                  f'actual={pane_count()} state={sidecar_state()}')
            break
    empty_ok = wait_for(lambda: all_empty(clients), clients, timeout=6.0)
    snapshot = snapshot_layout_head() if empty_ok else {}
    canonical_zero = (snapshot.get('nodes') == '' and
                      snapshot.get('panes') == 0 and
                      snapshot.get('focused') == -1)
    if not (empty_ok and canonical_zero):
        print(f'  cycle {cycle} zero diagnostic: state={sidecar_state()} '
              f'snapshot={snapshot} frames='
              f'{[frame_count(client) for client in clients]}')
    check(f'cycle {cycle} alternating closes reach zero',
          ok and empty_ok and canonical_zero)
    return ok and empty_ok and canonical_zero


for cycle in (1, 2):
    filled = fill_to_max((c, d), cycle)
    if filled:
        expose_all_panes((c, d), cycle)
        reject_seventeenth((c, d), cycle)
        close_all_panes((c, d), cycle)
    else:
        check(f'cycle {cycle} all 16 visible in both UIs', False)
        check(f'cycle {cycle} frame numbers 10..16 exact', False)
        check(f'cycle {cycle} 17th opens maximum dialog', False)
        check(f'cycle {cycle} 17th leaves exactly 16 panes', False)
        check(f'cycle {cycle} alternating closes reach zero', False)

check('post-cycle clients remain alive', c.alive() and d.alive())

check('post-cycle first client detaches with status 0', detach(c))
check('post-cycle second client detaches with status 0', detach(d))
stlib.close_all_daemons(HOME)
stlib.report()
