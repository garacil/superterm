#!/usr/bin/env python3
"""superterm test: bilingual CLI (list/send/capture/kill, help, exit codes)."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli

HOME = stlib.fresh_home('cli')

# ---- ayuda y errores de uso (sin sesiones) ----
r = run_cli(['--help'], HOME, env={'LANG': 'C'})
check('--help exits 0', r.returncode == 0)
check('--help is English by default', 'Usage:' in r.stdout)
r = run_cli(['--ayuda'], HOME)
check('--ayuda exits 0', r.returncode == 0)
r = run_cli(['help', 'send'], HOME, env={'LANG': 'C'})
check('help send shows send help', 'send' in r.stdout and '-n' in r.stdout)
r = run_cli(['sned'], HOME)
check('unknown command exit 2', r.returncode == 2)
check('unknown command on stderr', 'sned' in r.stderr)
r = run_cli(['list'], HOME)
check('list with no sessions exit 1', r.returncode == 1)
r = run_cli(['send'], HOME)
check('send without target exit 2', r.returncode == 2)

# ---- espanol por config ----
os.makedirs(HOME + '/.superterm', exist_ok=True)
with open(HOME + '/.superterm/superterm.ini', 'w') as f:
    f.write('[ui]\nlanguage=es\n')
r = run_cli(['--help'], HOME)
check('help follows config language (es)', 'Uso:' in r.stdout)
r = run_cli(['listar'], HOME)
check('spanish command accepted', r.returncode == 1)
check('spanish error message', 'sesiones' in r.stderr or 'sesiones' in r.stdout)
os.remove(HOME + '/.superterm/superterm.ini')

# ---- fallback por LANG sin config ----
r = run_cli(['--help'], HOME, env={'LANG': 'es_ES.UTF-8'})
check('LANG=es fallback', 'Uso:' in r.stdout)
r = run_cli(['--help'], HOME, env={'LANG': 'C'})
check('LANG=C stays English', 'Usage:' in r.stdout)

# ---- montar una sesion separada de verdad ----
c = stlib.Client(HOME, w=100, h=28)
c.drain(2.0)
c.send(b'seq 1 120\r', 1.2)
c.send(b'\x11', 0.4)
c.send(b'd', 0.9)
c.send(b'\r', 1.5)
time.sleep(0.6)
c.close()
socks = stlib.session_sockets(HOME)
check('detached session for CLI', len(socks) == 1)
SES = os.path.basename(socks[0])[:-5]

# ---- list ----
r = run_cli(['list'], HOME)
check('list sessions exit 0', r.returncode == 0)
check('list shows session', SES in r.stdout)
check('list shows clients column', 'CLIENTS' in r.stdout or
      'CLIENTES' in r.stdout)
r = run_cli(['list', SES], HOME)
check('list panes exit 0', r.returncode == 0)
check('list panes has TYPE local', 'local' in r.stdout)
check('list panes has size', 'x' in r.stdout)
r = run_cli(['listar', SES], HOME, env={'LANG': 'es_ES.UTF-8'})
check('listar panes in Spanish', 'TITULO' in r.stdout or 'PANEL' in r.stdout)

# ---- send + capture (ciclo completo por CLI) ----
r = run_cli(['send', '.', 'echo', 'CLI_TOKEN_7'], HOME)
check('send exit 0', r.returncode == 0)
time.sleep(0.8)
r = run_cli(['capture', '.'], HOME)
check('capture visible exit 0', r.returncode == 0)
check('capture sees sent text', 'CLI_TOKEN_7' in r.stdout)
r = run_cli(['capture', '.', '--history'], HOME)
check('capture history includes scrollback',
      any(l.strip() == '1' for l in r.stdout.splitlines()))
r = run_cli(['capturar', '.', '--lineas', '5'], HOME)
check('capturar --lineas exact', len(r.stdout.splitlines()) == 5)
out = HOME + '/cap.txt'
r = run_cli(['capture', '.', '-o', out], HOME)
check('capture -o writes file', r.returncode == 0 and
      os.path.exists(out) and 'CLI_TOKEN_7' in open(out).read())
check('capture -o keeps stdout clean', r.stdout == '')

# ---- send con teclas y sin intro ----
r = run_cli(['send', '-n', '.', 'partial'], HOME)
check('send -n exit 0', r.returncode == 0)
r = run_cli(['send', '.', '-k', 'C-c'], HOME)
check('send -k C-c exit 0', r.returncode == 0)
r = run_cli(['send', '.', '-k', 'NoSuchKey'], HOME)
check('unknown key exit 2', r.returncode == 2)

# ---- stdin crudo ----
r = run_cli(['send', SES + ':1', '-'], HOME, stdin='echo VIA_STDIN\r')
check('send stdin exit 0', r.returncode == 0)
time.sleep(0.8)
r = run_cli(['capture', '.'], HOME)
check('stdin text arrived', 'VIA_STDIN' in r.stdout)

# ---- destinos malos ----
r = run_cli(['send', 'nada:1', 'x'], HOME)
check('bad session exit 1', r.returncode == 1)
r = run_cli(['send', SES + ':9', 'x'], HOME)
check('bad pane exit 1', r.returncode == 1)

# ---- kill ----
r = run_cli(['kill'], HOME)
check('kill without name exit 2', r.returncode == 2)
r = run_cli(['matar', SES], HOME)
check('matar session exit 0', r.returncode == 0)
time.sleep(0.5)
check('session gone after kill', stlib.session_sockets(HOME) == [])

stlib.report()
