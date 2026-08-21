#!/usr/bin/env python3
"""superterm test: varios clientes interactivos sobre una misma sesion.

Cubre: adhesion versionada (v2) y exclusividad del cliente legado,
difusion de salida a todos los clientes, gestion de ventanas en vivo
(rename/new/close por CLI con clientes enganchados), negociacion de
tamano minimo, desconexion del cliente rezagado y aviso de cierre.
"""
import os
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, raw_frame, read_frame, run_cli

FRAME_ATTACH = 1
FRAME_SESSION = 20
FRAME_SCREEN = 21
FRAME_READY = 22

HOME = stlib.fresh_home('multiclient')


def clients_column(home):
    """CLIENTS de la fila de sesion: el token antes de la fecha CREATED."""
    r = run_cli(['list'], home, env={'LANG': 'C'})
    for line in r.stdout.splitlines():
        toks = line.split()
        if len(toks) >= 4 and toks[0] != 'NAME':
            try:
                return int(toks[-3])
            except ValueError:
                continue
    return -1


def attach_raw(sock_path, payload):
    """ATTACH crudo; devuelve (socket, ok_snapshot)."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(8.0)
    s.connect(sock_path)
    s.sendall(raw_frame(FRAME_ATTACH, -1, payload))
    ok = False
    try:
        fr = read_frame(s, timeout=5.0)
        if fr is not None and fr[0] == FRAME_SESSION:
            while True:
                fr = read_frame(s, timeout=5.0)
                if fr is None:
                    break
                if fr[0] == FRAME_READY:
                    ok = True
                    break
                if fr[0] != FRAME_SCREEN:
                    break
    except (socket.timeout, OSError):
        pass
    return s, ok


# ---- sesion separada con 1 panel ----
c = stlib.Client(HOME, w=100, h=28)
c.drain(2.0)
c.send(b'\x11', 0.4)
c.send(b'd', 0.9)
c.send(b'\r', 1.5)
time.sleep(0.6)
c.close()
socks = stlib.session_sockets(HOME)
check('detached session exists', len(socks) == 1)
SOCK = socks[0]
SES = os.path.basename(SOCK)[:-5]

# ---- cliente legado (ATTACH sin payload) solo, aun funciona ----
s, ok = attach_raw(SOCK, b'')
check('legacy attach alone still served', ok)
s.close()
time.sleep(0.8)

# ---- dos clientes interactivos reales ----
a = stlib.Client(HOME, args=['--attach'], w=100, h=28)
a.drain(2.5)
b = stlib.Client(HOME, args=['--attach'], w=80, h=24)
b.drain(2.5)
check('client A attached', a.alive())
check('client B attached', b.alive())
check('two clients listed', clients_column(HOME) == 2)

# ---- la entrada de A la ven A y B (merge + difusion) ----
a.send(b'echo MC_TOKEN_77\r', 0.5)
a.wait_until(lambda t: 'MC_TOKEN_77' in t)
b.wait_until(lambda t: 'MC_TOKEN_77' in t)
check('client A sees its own input', 'MC_TOKEN_77' in a.text())
check('client B sees broadcast output', 'MC_TOKEN_77' in b.text())

# ---- control efimero sigue funcionando con 2 enganchados ----
r = run_cli(['capture', '.'], HOME)
check('capture with 2 clients', r.returncode == 0 and 'MC_TOKEN_77' in r.stdout)

# ---- un cliente legado es rechazado mientras hay clientes v2 ----
s, ok = attach_raw(SOCK, b'')
check('legacy attach rejected while shared', not ok)
s.close()

# ---- gestion de ventanas EN VIVO (la guardia de F3 ya no existe) ----
r = run_cli(['rename', SES + ':1', 'Panel Compartido'], HOME)
check('rename while attached exit 0', r.returncode == 0)
a.wait_until(lambda t: 'Panel Compartido' in t)
b.wait_until(lambda t: 'Panel Compartido' in t)
check('client A sees new title', 'Panel Compartido' in a.text())
check('client B sees new title', 'Panel Compartido' in b.text())

r = run_cli(['new', SES, '--cmd', 'sleep 600', '-t', 'Trabajo Largo'], HOME)
check('new pane while attached exit 0', r.returncode == 0)
r = run_cli(['list', SES], HOME, env={'LANG': 'C'})
check('daemon has 2 panes', len([l for l in r.stdout.splitlines()
                                 if l and l[0].isdigit()]) == 2)
a.wait_until(lambda t: 'Trabajo Largo' in t)
b.wait_until(lambda t: 'Trabajo Largo' in t)
check('client A gained the window', 'Trabajo Largo' in a.text())
check('client B gained the window', 'Trabajo Largo' in b.text())

# ---- negociacion de tamano: la pantalla del panel 1 cabe en B (80 col) ----
r = run_cli(['list', SES], HOME, env={'LANG': 'C'})
row1 = [l for l in r.stdout.splitlines() if l.startswith('1 ')]
size_ok = False
if row1:
    for tok in row1[0].split():
        if 'x' in tok and tok[0].isdigit():
            cols = int(tok.split('x')[0])
            size_ok = cols <= 80
            break
check('pane 1 sized to smallest client', size_ok)

# ---- cerrar el panel nuevo por CLI: ambos clientes compactan ----
r = run_cli(['close', SES + ':2'], HOME)
check('close while attached exit 0', r.returncode == 0)
a.wait_until(lambda t: 'Trabajo Largo' not in t)
b.wait_until(lambda t: 'Trabajo Largo' not in t)
check('client A dropped the window', 'Trabajo Largo' not in a.text())
check('client B dropped the window', 'Trabajo Largo' not in b.text())
run_cli(['send', SES + ':1', 'echo AFTER_CLOSE_OK'], HOME)
a.wait_until(lambda t: 'AFTER_CLOSE_OK' in t)
b.wait_until(lambda t: 'AFTER_CLOSE_OK' in t)
check('panes still aligned in A', 'AFTER_CLOSE_OK' in a.text())
check('panes still aligned in B', 'AFTER_CLOSE_OK' in b.text())

# ---- cliente rezagado: enganchado v2 que no lee no bloquea al daemon ----
lag, ok = attach_raw(SOCK, struct.pack('<iiii', 2, 0, 0, 1))
check('laggard attached', ok)
check('three clients listed', clients_column(HOME) == 3)
run_cli(['send', SES + ':1',
         'yes LAGGARD_FLOOD | head -c 10000000; echo PUMP_DONE'], HOME)
# drenar A y B mientras esperamos: son lectores vivos y no deben caer;
# el rezagado no progresa y el daemon lo corta pasado el periodo de gracia
deadline = time.time() + 45
while time.time() < deadline:
    a.drain(0.3)
    b.drain(0.3)
    if clients_column(HOME) == 2:
        break
check('laggard dropped, live clients kept', clients_column(HOME) == 2)
lag.close()
# drenar a la vez: si solo se atiende a uno, el otro acabaria cortado
# por la misma regla de rezagados que acabamos de comprobar
deadline = time.time() + 90
while time.time() < deadline:
    a.drain(0.2)
    b.drain(0.2)
    if 'PUMP_DONE' in a.text() and 'PUMP_DONE' in b.text():
        break
check('client A survived the flood', 'PUMP_DONE' in a.text())
check('client B survived the flood', 'PUMP_DONE' in b.text())
r = run_cli(['list'], HOME, env={'LANG': 'C'})
check('daemon alive after flood', r.returncode == 0 and SES in r.stdout)

# ---- matar la sesion: ambos clientes reciben el aviso y salen ----
r = run_cli(['kill', SES], HOME)
check('kill with clients attached exit 0', r.returncode == 0)
time.sleep(1.5)
a.send(b'\r', 0.5)   # aceptar el aviso "la sesion se cerro"
b.send(b'\r', 0.5)
check('client A exited after shutdown', a.wait_exit(timeout=8.0) is not None)
check('client B exited after shutdown', b.wait_exit(timeout=8.0) is not None)
check('session gone', stlib.session_sockets(HOME) == [])

stlib.report()
