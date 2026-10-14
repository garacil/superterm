#!/usr/bin/env python3
"""superterm test: a GNU/Linux virtual console gets its mouse from GPM.

There is no virtual console to sit on here, so the test-only build is told
which console it is on and where gpm listens, and this suite plays gpm: it
accepts the client, checks the connect request, and writes gpm's own event
records (src/headers/gpm.h) -- a move, a click, a wheel notch. On a console
nothing else draws a pointer, so the renderer must paint the cell under it
and repaint it when the pointer leaves. When the client goes, its connection
must go with it: a daemon forked from the client keeping a copy would leave
gpm writing events for a console that nobody reads.
"""
import os
import select
import shutil
import socket
import struct
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib


VT = 7
# wide enough to show the whole fixed logical desktop, as mouse_test does
W, H = 381, 104
CONNECT = struct.Struct('<HHHHii')          # Gpm_Connect, 16 bytes
EVENT = struct.Struct('<BBHhhhhiiihh')      # Gpm_Event, 28 bytes
GPM_MOVE, GPM_DRAG, GPM_DOWN, GPM_UP = 1, 2, 4, 8
GPM_B_LEFT, GPM_B_UP = 4, 16

HOME = stlib.fresh_home('gpm-console')
with open(HOME + '/.superterm/superterm.ini', 'w') as config:
    config.write('[ui]\n'
                 'language=en\n'
                 'background=none\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n')

# sun_path holds about 107 bytes; keep the fake gpm socket short.
GPM_DIR = tempfile.mkdtemp(prefix='stgpm')
GPM_PATH = os.path.join(GPM_DIR, 'gpmctl')
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(GPM_PATH)
listener.listen(4)


def gpm_event(kind, x, y, buttons=0, wdy=0):
    # buttons, modifiers, vc, dx, dy, x, y, type, clicks, margin, wdx, wdy
    return EVENT.pack(buttons, 0, VT, 0, 0, x, y, kind, 0, 0, 0, wdy)


def accept(client, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        ready, _, _ = select.select([listener], [], [], 0.05)
        if ready:
            conn, _ = listener.accept()
            return conn
        client.drain(0.05)
    return None


def read_exact(conn, size, timeout):
    data = b''
    deadline = time.time() + timeout
    while len(data) < size and time.time() < deadline:
        ready, _, _ = select.select([conn], [], [], 0.05)
        if not ready:
            continue
        chunk = conn.recv(size - len(data))
        if not chunk:
            break
        data += chunk
    return data


def cell(client, x, y):
    char = client.screen.buffer[y][x]
    return char.fg, char.bg, char.reverse


def wait_cell(client, x, y, pred, timeout=4.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        client.drain(0.1)
        if pred(cell(client, x, y)):
            return True
    return pred(cell(client, x, y))


def frame_rect(client):
    rows = client.screen.display
    for top, row in enumerate(rows):
        if '╔' not in row or '╗' not in row:
            continue
        left, right = row.index('╔'), row.index('╗')
        for bottom in range(top + 2, len(rows)):
            if (rows[bottom][left] in ('╚', '└') and
                    rows[bottom][right] in ('╝', '┘')):
                return left, top, right, bottom
    return None


def wait_frame(client, expected, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        client.drain(0.1)
        if frame_rect(client) == expected:
            return True
    return frame_rect(client) == expected


def drag(conn, client, x1, y1, x2, y2):
    """A left-button drag between two 0-based cells, as gpm reports it."""
    conn.sendall(gpm_event(GPM_DOWN, x1 + 1, y1 + 1, GPM_B_LEFT))
    client.drain(0.2)
    conn.sendall(gpm_event(GPM_DRAG, x2 + 1, y2 + 1, GPM_B_LEFT))
    client.drain(0.2)
    conn.sendall(gpm_event(GPM_UP, x2 + 1, y2 + 1, GPM_B_LEFT))
    client.drain(0.4)


def wait_eof(conn, client, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        ready, _, _ = select.select([conn], [], [], 0.05)
        if ready:
            try:
                if not conn.recv(4096):
                    return True
            except OSError:
                return True
        if client is not None:
            client.drain(0.05)
    return False


client = None
conn = None
try:
    client = stlib.Client(HOME, w=W, h=H, env={
        'TERM': 'linux',
        'SUPERTERM_TESTING': '1',
        'SUPERTERM_TEST_CONSOLE_VT': str(VT),
        'SUPERTERM_TEST_GPM_SOCKET': GPM_PATH,
    })
    conn = accept(client, 8.0)
    stlib.check('client connects to gpm', conn is not None)
    request = read_exact(conn, CONNECT.size, 3.0) if conn else b''
    fields = CONNECT.unpack(request) if len(request) == CONNECT.size else None
    stlib.check('connect request is one Gpm_Connect', fields is not None)
    if fields is None:
        fields = (0, 0, 0, 0, 0, 0)
    event_mask, default_mask, min_mod, max_mod, pid, vc = fields
    stlib.check('request names the console', vc == VT)
    stlib.check('request takes every bare event',
                event_mask == GPM_MOVE | GPM_DRAG | GPM_DOWN | GPM_UP)
    stlib.check('gpm keeps no default handling and modified events',
                default_mask == 0 and min_mod == 0 and max_mod == 0)
    stlib.check('request carries the client pid', pid == client.pid)
    stlib.check('menu bar becomes visible',
                client.wait_until(lambda text: 'Panes' in text, 8.0))
    raw = client.raw()
    stlib.check('a console is never sent xterm mouse modes',
                b'\x1b[?1000h' not in raw and b'\x1b[?1002h' not in raw and
                b'\x1b[?1006h' not in raw)

    # A hover moves only the pointer: the cell under it changes colour and
    # gets its own colours back when the pointer moves on.
    px, py = 60, 0
    before = cell(client, px, py)
    conn.sendall(gpm_event(GPM_MOVE, px + 1, py + 1))
    stlib.check('pointer is painted under the mouse',
                wait_cell(client, px, py, lambda c: c != before))
    target = cell(client, px, py + 5)
    conn.sendall(gpm_event(GPM_MOVE, px + 1, py + 6))
    stlib.check('pointer leaves its old cell intact',
                wait_cell(client, px, py, lambda c: c == before))
    stlib.check('pointer follows the mouse',
                wait_cell(client, px, py + 5, lambda c: c != target))

    # gpm's click on Panes: DOWN carries the whole set, UP the released one.
    conn.sendall(gpm_event(GPM_DOWN, 5, 1, GPM_B_LEFT) +
                 gpm_event(GPM_UP, 5, 1, GPM_B_LEFT))
    stlib.check('gpm click opens the Panes menu',
                client.wait_until(lambda text: 'Split vertical' in text, 5.0))
    client.send(b'\x1b', 0.6)
    stlib.check('menu closes again',
                client.wait_until(lambda text: 'Split vertical' not in text,
                                  4.0))

    # A wheel notch arrives as gpm's GPM_B_UP button and must not leave a
    # button held: the next click still opens the menu.
    conn.sendall(gpm_event(GPM_DOWN, 40, 10, GPM_B_UP, wdy=1) +
                 gpm_event(GPM_UP, 40, 10, GPM_B_UP))
    client.drain(0.5)
    conn.sendall(gpm_event(GPM_DOWN, 5, 1, GPM_B_LEFT) +
                 gpm_event(GPM_UP, 5, 1, GPM_B_LEFT))
    stlib.check('wheel leaves no button held',
                client.wait_until(lambda text: 'Split vertical' in text, 5.0))
    client.send(b'\x1b', 0.6)

    # The window manager: resize by the grow handle, move by the title bar,
    # maximize by a double click on the title, all from gpm drags and clicks.
    full = frame_rect(client)
    stlib.check('pane frame is visible', full is not None)
    if full is not None:
        left, top, right, bottom = full
        small = (left, top, right - 20, bottom - 5)
        drag(conn, client, right, bottom, small[2], small[3])
        stlib.check('gpm drag resizes the window', wait_frame(client, small))
        moved = (small[0] + 10, small[1] + 5, small[2] + 10, small[3] + 5)
        drag(conn, client, left + 8, top, left + 18, top + 5)
        stlib.check('gpm drag moves the window', wait_frame(client, moved))
        title_x, title_y = moved[0] + 8, moved[1]
        for _ in range(2):
            conn.sendall(gpm_event(GPM_DOWN, title_x + 1, title_y + 1,
                                   GPM_B_LEFT))
            client.drain(0.12)
            conn.sendall(gpm_event(GPM_UP, title_x + 1, title_y + 1,
                                   GPM_B_LEFT))
            client.drain(0.12)

        def maximized():
            rect = frame_rect(client)
            return (rect is not None and rect[:2] == full[:2] and
                    rect[2] >= full[2] and rect[3] >= full[3])
        deadline = time.time() + 5.0
        while time.time() < deadline and not maximized():
            client.drain(0.1)
        # maximized fills the whole desktop, which the first window did not
        stlib.check('gpm double click maximizes the window', maximized())

    # gpm restarting drops every client after it has served them. The client
    # must come back by itself, with the same request, and keep working.
    conn.close()
    conn = accept(client, 6.0)
    stlib.check('client reconnects after gpm goes away', conn is not None)
    again = read_exact(conn, CONNECT.size, 3.0) if conn else b''
    stlib.check('reconnect repeats the same request',
                len(again) == CONNECT.size and
                CONNECT.unpack(again)[5] == VT and
                CONNECT.unpack(again)[4] == client.pid)
    if conn is not None:
        conn.sendall(gpm_event(GPM_MOVE, 41, 11))
        conn.sendall(gpm_event(GPM_DOWN, 5, 1, GPM_B_LEFT) +
                     gpm_event(GPM_UP, 5, 1, GPM_B_LEFT))
    stlib.check('reconnected gpm still opens the menu',
                client.wait_until(lambda text: 'Split vertical' in text, 5.0))
    client.send(b'\x1b', 0.6)

    # Detach: the client exits and the daemon stays. If the daemon had kept
    # the socket it inherited, gpm would never see this connection close.
    client.send(b'\x11', 0.4)
    client.send(b'd', 0.8)
    status = client.wait_exit(6.0)
    stlib.check('client exits after Ctrl-Q d',
                status is not None and os.WIFEXITED(status) and
                os.WEXITSTATUS(status) == 0)
    stlib.check('one server socket remains',
                len(stlib.session_sockets(HOME)) == 1)
    stlib.check('gpm sees the connection close with the client',
                wait_eof(conn, None, 4.0))
finally:
    if conn is not None:
        conn.close()
    stlib.close_all_daemons(HOME)
    if client is not None:
        client.wait_exit(2.0)
        client.close()

# gpm refuses a console the user does not own by closing the connection
# without a single event. That is final: no reconnect storm (each attempt is
# a warning in gpm's log), and the interface keeps working from the keyboard.
REFUSED_HOME = stlib.fresh_home('gpm-console-refused')
with open(REFUSED_HOME + '/.superterm/superterm.ini', 'w') as config:
    config.write('[ui]\nlanguage=en\nbackground=none\n'
                 '[session]\nserver=always\nautosave=0\nautorestore=0\n')
client = None
try:
    client = stlib.Client(REFUSED_HOME, w=100, h=30, env={
        'TERM': 'linux',
        'SUPERTERM_TESTING': '1',
        'SUPERTERM_TEST_CONSOLE_VT': str(VT),
        'SUPERTERM_TEST_GPM_SOCKET': GPM_PATH,
    })
    refused = accept(client, 8.0)
    stlib.check('refused client connected once', refused is not None)
    if refused is not None:
        read_exact(refused, CONNECT.size, 3.0)
        refused.close()
    stlib.check('a refusal is not retried',
                accept(client, 4.0) is None)
    stlib.check('refused client keeps its interface',
                client.wait_until(lambda text: 'Panes' in text, 6.0) and
                client.alive())
    client.send(b'\x11mp', 0.8)       # prefix, menu bar, Panes
    stlib.check('keyboard still drives the menu after a refusal',
                client.wait_until(lambda text: 'Split vertical' in text, 4.0))
    client.send(b'\x1b', 0.4)
finally:
    stlib.close_all_daemons(REFUSED_HOME)
    if client is not None:
        client.wait_exit(2.0)
        client.close()
    listener.close()
    shutil.rmtree(GPM_DIR, ignore_errors=True)

stlib.report()
