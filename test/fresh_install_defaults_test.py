#!/usr/bin/env python3
"""A configuration-free installation starts from the advertised workspace.

This is an end-to-end test of compiled defaults, not an INI fixture.  It
starts SuperTerm with neither a user nor a system configuration and observes
the daemon state and the cells actually presented to the terminal.
"""
import os
import socket
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import FRAME_CTL_DATA, FRAME_CTL_END, FRAME_CTL_LIST, check
HOST_W, HOST_H = 132, 55       # deliberately not the canonical 120x52 IDE
DESKTOP = (120, 50)
PTY_SIZE = (80, 25)
SAVED_GEOM = (19, 11, 82, 27)  # centred 80x25 interior plus its 1-cell frame
ROOT = Path(__file__).resolve().parent.parent
ART_DIR = ROOT / 'backgrounds'


def daemon_state(sock_path):
    """Decode the authoritative CTL_LIST state used by the public CLI."""
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.settimeout(4.0)
    try:
        peer.connect(sock_path)
        peer.sendall(stlib.raw_frame(FRAME_CTL_LIST, -1))
        payload = None
        while True:
            frame = stlib.read_frame(peer, timeout=4.0)
            if frame is None or frame[0] == FRAME_CTL_END:
                break
            if frame[0] == FRAME_CTL_DATA:
                payload = frame[2]
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
            offset += 1
            _host, offset = stlib.read_pas_string(payload, offset)
            _user, offset = stlib.read_pas_string(payload, offset)
            _command, offset = stlib.read_pas_string(payload, offset)
            _cwd, offset = stlib.read_pas_string(payload, offset)
            cols, rows, _history, bx, by, bw, bh = struct.unpack_from(
                '<iiiiiii', payload, offset)
            offset += struct.calcsize('<iiiiiii')
            zoomed, minimized, alive = struct.unpack_from(
                '<BBB', payload, offset)
            offset += 3
            panes.append({
                'title': title,
                'size': (cols, rows),
                'geom': (bx, by, bw, bh),
                'zoomed': bool(zoomed),
                'minimized': bool(minimized),
                'alive': bool(alive),
            })
        if offset != len(payload):
            return None
        return {'desk': (desk_w, desk_h), 'focused': focused,
                'panes': panes}
    except (OSError, struct.error, ValueError, IndexError):
        return None
    finally:
        peer.close()


SYNC_BEGIN = b'\x1b[?2026h'
SYNC_END = b'\x1b[?2026l'


def wait_presented(client, after=0, timeout=5.0):
    """Wait until the client has finished presenting a synchronized frame.

    WideUpdateScreen wraps every physical update in DECSET 2026, so the raw
    stream carries a balanced begin/end pair per presented surface. The daemon
    reaches its final state before the client has written the last cell of the
    first frame, and snapshotting there reads a half-drawn surface: the frames
    and the minimized icon simply are not on it yet. Wait for a balanced pair
    beyond `after` instead of sleeping a fixed amount.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        begins = client._raw.count(SYNC_BEGIN)
        ends = client._raw.count(SYNC_END)
        if ends > after and begins == ends:
            return True
        client.drain(0.05)
    return (client._raw.count(SYNC_END) > after and
            client._raw.count(SYNC_BEGIN) == client._raw.count(SYNC_END))


def alien_palette():
    art = ART_DIR / 'goody.art'
    for line in art.read_text(encoding='utf-8').splitlines():
        if line.startswith('palette: '):
            return {value.lower() for value in line[9:].split()}
    return set()


home = stlib.fresh_home('fresh-install-defaults')
config = os.path.join(home, '.superterm', 'superterm.ini')
check('fixture begins without user configuration', not os.path.exists(config))

client = None
socket_path = ''
try:
    client = stlib.Client(home, w=HOST_W, h=HOST_H,
                          env={
                              'SUPERTERM_SYNC': '1',
                              'SUPERTERM_BACKGROUNDS': os.fspath(ART_DIR),
                          })
    deadline = time.monotonic() + 8.0
    state = None
    while time.monotonic() < deadline:
        client.drain(0.10)
        sockets = stlib.session_sockets(home)
        if len(sockets) == 1:
            socket_path = sockets[0]
            state = daemon_state(socket_path)
            if state and len(state['panes']) == 1:
                break

    pane = state['panes'][0] if state and len(state['panes']) == 1 else {}
    check('fresh daemon owns a 120x50 canonical desktop',
          state is not None and state['desk'] == DESKTOP)
    check('fresh daemon owns exactly one pane',
          state is not None and len(state['panes']) == 1)
    check('initial PTY is exactly 80x25', pane.get('size') == PTY_SIZE)
    check('initial normal rectangle preserves its exact PTY size',
          pane.get('geom') == SAVED_GEOM)
    check('initial pane is alive, focused and minimized',
          state is not None and state['focused'] == 0 and
          pane.get('alive') and pane.get('minimized') and
          not pane.get('zoomed'))

    # Slot zero is the first stable 26x2 icon at the bottom-left of the
    # canonical desktop.  Desktop row 48 is physical row 49 below the menu.
    check('first presentation completes before it is observed',
          wait_presented(client))
    rows = client.screen.display
    icon_ok = (rows[49][0] in ('┌', '╔') and
               rows[49][25] in ('┐', '╗') and
               rows[50][0] in ('└', '╚') and
               rows[50][25] in ('┘', '╝'))
    check('initial pane is presented in stable minimized slot zero', icon_ok)
    check('first presentation contains only one final synchronized surface',
          client._raw.count(b'\x1b[?2026h') == 1 and
          client._raw.count(b'\x1b[?2026l') == 1)

    # Observe the actual renderer, not the selected menu mark.  Monochrome's
    # menu bar is white on the solid black RGB ground; the colour palette is
    # black on white.  The picture deliberately retains its own RGB colours.
    menu_cell = client.screen.buffer[0][0]
    check('compiled UI default is monochrome',
          menu_cell.fg == 'white' and menu_cell.bg == '000000')
    icon_attrs = {
        (client.screen.buffer[y][x].fg, client.screen.buffer[y][x].bg)
        for y in (49, 50)
        for x in range(26)
    }
    if icon_attrs != {('brightwhite', '000000')}:
        print('  minimized icon attributes: %r' % sorted(icon_attrs))
    check('minimized pane chrome follows the monochrome palette',
          icon_attrs == {('brightwhite', '000000')})
    visible_backgrounds = {
        cell.bg.lower()
        for row in client.screen.buffer.values()
        for cell in row.values()
        if isinstance(cell.bg, str)
    }
    check('compiled background default renders the alien artwork',
          len(visible_backgrounds & alien_palette()) >= 40)
    check('observing defaults does not manufacture a user INI',
          not os.path.exists(config))

    # The icon is only the presentation state. Restoring it must recover the
    # exact centred rectangle and must not reinterpret 80x25 as outer bounds.
    session = os.path.basename(socket_path)[:-5] if socket_path else ''
    frames_before_restore = client._raw.count(SYNC_END)
    restored = (stlib.run_cli(['restore', session + ':1'], home)
                if session else None)
    deadline = time.monotonic() + 5.0
    restored_state = None
    while time.monotonic() < deadline:
        client.drain(0.08)
        restored_state = daemon_state(socket_path) if socket_path else None
        if (restored_state and restored_state['panes'] and
                not restored_state['panes'][0]['minimized']):
            break
    restored_pane = (restored_state['panes'][0]
                     if restored_state and restored_state['panes'] else {})
    check('restoring the installation pane succeeds',
          restored is not None and restored.returncode == 0)
    check('restore returns to the exact 80x25 PTY and saved rectangle',
          restored_pane.get('size') == PTY_SIZE and
          restored_pane.get('geom') == SAVED_GEOM and
          not restored_pane.get('minimized'))
    check('restore presentation completes before it is observed',
          wait_presented(client, after=frames_before_restore))
    rows = client.screen.display
    restored_frame = (
        rows[12][19] in ('┌', '╔') and
        rows[12][100] in ('┐', '╗') and
        rows[38][19] in ('└', '╚') and
        rows[38][100] in ('┘', '╝'))
    check('restored frame is centred at its advertised dimensions',
          restored_frame)
finally:
    if client is not None:
        if client.alive():
            client.send(b'\x11d', 0.25)
            client.wait_exit(timeout=5.0)
        client.close()
    stlib.close_all_daemons(home)

stlib.report()
