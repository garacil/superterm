#!/usr/bin/env python3
"""superterm test: ephemeral control frames on a detached session daemon.

Speaks the raw frame protocol (no CLI): CTL_LIST/CTL_SEND/CTL_CAPTURE/CTL_INFO
as first frames on fresh connections, without occupying the attach slot.
"""
import os
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, raw_frame, read_frame, read_pas_string

FRAME_CTL_LIST = 11
FRAME_CTL_SEND = 12
FRAME_CTL_CAPTURE = 13
FRAME_CTL_WINOP = 14
FRAME_CTL_INFO = 15
FRAME_CTL_OK = 40
FRAME_CTL_ERR = 41
FRAME_CTL_DATA = 42
FRAME_CTL_END = 43
CAPTURE_VISIBLE = 0
CAPTURE_ALL = 1
CAPTURE_LAST_N = 2

HOME = stlib.fresh_home('control')


def ctl(sock_path, kind, pane=-1, payload=b''):
    """One-shot control request; returns list of (kind, pane, data) frames."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(8.0)
    s.connect(sock_path)
    s.sendall(raw_frame(kind, pane, payload))
    frames = []
    try:
        while True:
            fr = read_frame(s, timeout=8.0)
            if fr is None:
                break
            frames.append(fr)
            if fr[0] in (FRAME_CTL_END, FRAME_CTL_OK, FRAME_CTL_ERR):
                break
    finally:
        s.close()
    return frames


def capture_text(sock_path, pane, mode, n=0):
    payload = struct.pack('<ii', mode, n)
    frames = ctl(sock_path, FRAME_CTL_CAPTURE, pane, payload)
    ok = frames and frames[-1][0] == FRAME_CTL_END
    text = b''.join(d for k, _p, d in frames if k == FRAME_CTL_DATA)
    return ok, text.decode('utf-8', 'replace')


def parse_list(data):
    """Parse the CTL_LIST reply blob."""
    ofs = 0
    name, ofs = read_pas_string(data, ofs)
    profile, ofs = read_pas_string(data, ofs)
    panecount, focused, attached, deskw, deskh = struct.unpack_from(
        '<iiiii', data, ofs)
    ofs += 20
    panes = []
    for _ in range(panecount):
        title, ofs = read_pas_string(data, ofs)
        term, ofs = read_pas_string(data, ofs)
        (kind,) = struct.unpack_from('<B', data, ofs); ofs += 1
        host, ofs = read_pas_string(data, ofs)
        user, ofs = read_pas_string(data, ofs)
        cmd, ofs = read_pas_string(data, ofs)
        cwd, ofs = read_pas_string(data, ofs)
        cols, rows, hist, bx, by, bw, bh = struct.unpack_from(
            '<iiiiiii', data, ofs)
        ofs += 28
        zoomed, minimized, alive = struct.unpack_from('<BBB', data, ofs)
        ofs += 3
        panes.append(dict(title=title, term=term, kind=kind, host=host,
                          user=user, cmd=cmd, cwd=cwd, cols=cols, rows=rows,
                          hist=hist, alive=alive))
    return dict(name=name, profile=profile, panecount=panecount,
                focused=focused, attached=attached, panes=panes)


# ---- montar una sesion separada con scrollback e historial conocidos ----
c = stlib.Client(HOME, w=100, h=28)
c.drain(2.0)
c.send(b'seq 1 200\r', 1.5)
c.send(b"printf 'ACENTOS: \\303\\241\\303\\251\\303\\261 FIN\\n'\r", 0.8)
c.send(b"printf 'ANCHO: \\346\\274\\242\\345\\255\\227 FIN\\n'\r", 0.8)
c.wait_until(lambda t: 'ANCHO' in t)
c.send(b'\x11', 0.4)
c.send(b'd', 0.9)
c.send(b'\r', 1.5)          # aceptar nombre sugerido
time.sleep(0.6)
c.close()

socks = stlib.session_sockets(HOME)
check('detached session exists', len(socks) == 1)
SOCK = socks[0]

# ---- CTL_LIST ----
frames = ctl(SOCK, FRAME_CTL_LIST)
ok = len(frames) == 2 and frames[0][0] == FRAME_CTL_DATA and \
    frames[1][0] == FRAME_CTL_END
check('list replies data+end', ok)
info = parse_list(frames[0][2]) if ok else {}
check('list session name', bool(info.get('name')))
check('list pane count 1', info.get('panecount') == 1)
check('list pane alive', ok and info['panes'][0]['alive'] == 1)
check('list pane local kind', ok and info['panes'][0]['kind'] == 0)
check('list pane size', ok and info['panes'][0]['cols'] > 10)
check('list history lines counted', ok and info['panes'][0]['hist'] > 100)
check('list not attached', info.get('attached') == 0)

# ---- CTL_INFO ----
frames = ctl(SOCK, FRAME_CTL_INFO)
check('info replies', len(frames) == 2 and frames[1][0] == FRAME_CTL_END)

# ---- CTL_SEND + CAPTURE visible ----
frames = ctl(SOCK, FRAME_CTL_SEND, 0, b'echo CTL_TOKEN_42\r')
check('send replies ok', bool(frames) and frames[-1][0] == FRAME_CTL_OK)
time.sleep(0.8)
ok, text = capture_text(SOCK, 0, CAPTURE_VISIBLE)
check('capture visible works', ok)
check('sent text reached shell', 'CTL_TOKEN_42' in text)
check('capture visible excludes scrollback',
      '\n1\n' not in '\n' + text)

# ---- CAPTURE all (historial completo) ----
ok, text = capture_text(SOCK, 0, CAPTURE_ALL)
check('capture all works', ok)
lines = text.splitlines()
check('capture all includes scrollback', any(l.strip() == '1' for l in lines))
check('capture all includes visible', 'CTL_TOKEN_42' in text)
check('capture utf-8 accents', 'ACENTOS: áéñ FIN' in text)
check('capture wide chars', 'ANCHO: 漢字 FIN' in text)

# ---- CAPTURE last-N exacto ----
ok, text = capture_text(SOCK, 0, CAPTURE_LAST_N, 5)
check('capture last-5 works', ok)
check('capture last-5 exact rows', len(text.splitlines()) == 5)

# ---- errores ----
frames = ctl(SOCK, FRAME_CTL_SEND, 9, b'x')
check('send bad pane errors',
      bool(frames) and frames[-1][0] == FRAME_CTL_ERR)
frames = ctl(SOCK, FRAME_CTL_CAPTURE, 7, struct.pack('<ii', 0, 0))
check('capture bad pane errors',
      bool(frames) and frames[-1][0] == FRAME_CTL_ERR)

# ---- robustez: frame desconocido / malformado no matan al daemon ----
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3.0)
s.connect(SOCK)
s.sendall(raw_frame(99, -1, b'garbage'))
s.close()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3.0)
s.connect(SOCK)
s.sendall(b'\x0b\x00')      # cabecera truncada
s.close()
time.sleep(1.5)
frames = ctl(SOCK, FRAME_CTL_INFO)
check('daemon survives junk frames',
      len(frames) == 2 and frames[1][0] == FRAME_CTL_END)

# ---- control funciona con un cliente ENGANCHADO ----
c2 = stlib.Client(HOME, args=['--attach'], w=100, h=28)
c2.drain(2.5)
frames = ctl(SOCK, FRAME_CTL_LIST)
ok = len(frames) == 2 and frames[1][0] == FRAME_CTL_END
check('list works while attached', ok)
if ok:
    info = parse_list(frames[0][2])
    check('attached count is 1', info.get('attached') == 1)
frames = ctl(SOCK, FRAME_CTL_SEND, 0, b'echo WHILE_ATTACHED\r')
check('send works while attached',
      bool(frames) and frames[-1][0] == FRAME_CTL_OK)
c2.wait_until(lambda t: 'WHILE_ATTACHED' in t)
check('attached client sees sent text', 'WHILE_ATTACHED' in c2.text())
c2.send(b'\x1bx', 1.0)      # Alt-X: cierre definitivo
time.sleep(0.6)
c2.close()

stlib.report()
