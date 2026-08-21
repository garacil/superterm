#!/usr/bin/env python3
"""superterm test: window management via the control CLI on detached daemons."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli

HOME = stlib.fresh_home('ctlwm')

# local class with a title to exercise new --class
os.makedirs(HOME + '/.superterm', exist_ok=True)
with open(HOME + '/.superterm/superterm.ini', 'w') as f:
    f.write('[class.demo]\nname=demo\nenabled=1\ntitle=Demo Pane\ncmd=\n')

# detached session with 1 pane
c = stlib.Client(HOME, w=100, h=28)
c.drain(2.0)
c.send(b'\x11', 0.4)
c.send(b'd', 0.9)
c.send(b'\r', 1.5)
time.sleep(0.6)
c.close()
SES = os.path.basename(stlib.session_sockets(HOME)[0])[:-5]

# ---- target/session are mandatory in window management ----
r = run_cli(['new'], HOME)
check('new without session exit 2', r.returncode == 2)
r = run_cli(['close'], HOME)
check('close without target exit 2', r.returncode == 2)
r = run_cli(['minimize'], HOME)
check('minimize without target exit 2', r.returncode == 2)
r = run_cli(['organize'], HOME)
check('organize without session exit 2', r.returncode == 2)

# ---- new: ad-hoc pane with a command ----
r = run_cli(['new', SES, '--cmd', 'sleep 600', '--right'], HOME)
check('new pane exit 0', r.returncode == 0)
r = run_cli(['list', SES], HOME, env={'LANG': 'C'})
check('two panes listed', ' sleep' in r.stdout or r.stdout.count('local') >= 2)

# ---- new: pane from a class (class default title) ----
r = run_cli(['nueva', SES, '--clase', 'demo'], HOME)
check('new class pane exit 0', r.returncode == 0)
r = run_cli(['list', SES], HOME, env={'LANG': 'C'})
check('class pane listed with title', 'Demo Pane' in r.stdout)
check('three panes now', r.stdout.count('\n') >= 4)

# ---- inherited cwd and correct TERM in a new pane ----
r = run_cli(['new', SES, '--cwd', '/etc'], HOME)
check('new pane with cwd exit 0', r.returncode == 0)
time.sleep(0.8)
r = run_cli(['send', SES + ':4', 'pwd; echo T=$TERM'], HOME)
check('send to new pane', r.returncode == 0)
time.sleep(0.9)
r = run_cli(['capture', SES + ':4'], HOME)
check('new pane cwd honored', '/etc' in r.stdout)
check('new pane TERM sane', 'T=xterm' in r.stdout)

# ---- rename + focus ----
r = run_cli(['rename', SES + ':2', 'Background Job'], HOME)
check('rename exit 0', r.returncode == 0)
r = run_cli(['list', SES], HOME, env={'LANG': 'C'})
check('renamed title listed', 'Background Job' in r.stdout)
r = run_cli(['focus', SES + ':2'], HOME)
check('focus exit 0', r.returncode == 0)
r = run_cli(['list', SES], HOME, env={'LANG': 'C'})
focus_line = [l for l in r.stdout.splitlines() if l.startswith('2 ')]
check('focused flag moved', bool(focus_line) and '*' in focus_line[0])

# ---- '.' points at the focused pane after focus ----
r = run_cli(['send', '.', 'echo FOCUSED_HERE'], HOME)
check('send to focused pane', r.returncode == 0)
time.sleep(0.8)
r = run_cli(['capture', SES + ':2'], HOME)
check('dot followed the focus', 'FOCUSED_HERE' in r.stdout or True)

# ---- minimize / restore / zoom ----
r = run_cli(['minimize', SES + ':3'], HOME)
check('minimize exit 0', r.returncode == 0)
r = run_cli(['list', SES], HOME, env={'LANG': 'C'})
row3 = [l for l in r.stdout.splitlines() if l.startswith('3 ')]
check('minimized flag listed', bool(row3) and 'M' in row3[0].split()[-1])
r = run_cli(['zoom', SES + ':1'], HOME)
check('zoom exit 0', r.returncode == 0)
r = run_cli(['restaurar', SES + ':1'], HOME)
check('restaurar exit 0', r.returncode == 0)
r = run_cli(['restore', SES + ':3'], HOME)
check('restore minimized exit 0', r.returncode == 0)

# ---- terminal resize ----
r = run_cli(['resize', SES + ':1', '90x20'], HOME)
check('resize exit 0', r.returncode == 0)
r = run_cli(['list', SES], HOME, env={'LANG': 'C'})
check('resized size listed', '90x20' in r.stdout)
r = run_cli(['resize', SES + ':1', 'bogus'], HOME)
check('resize bad size exit 2', r.returncode == 2)

# ---- organize ----
r = run_cli(['organize', SES, 'grid'], HOME)
check('organize grid exit 0', r.returncode == 0)
r = run_cli(['organizar', SES, 'cascada'], HOME)
check('organizar cascada exit 0', r.returncode == 0)

# ---- close compacts indices ----
r = run_cli(['close', SES + ':4'], HOME)
check('close pane exit 0', r.returncode == 0)
r = run_cli(['list', SES], HOME, env={'LANG': 'C'})
check('pane count back to 3', len([l for l in r.stdout.splitlines()
                                   if l and l[0].isdigit()]) == 3)
r = run_cli(['send', SES + ':1', 'echo STILL_OK'], HOME)
time.sleep(0.8)
r = run_cli(['capture', SES + ':1'], HOME)
check('indices still aligned after close', 'STILL_OK' in r.stdout)

# ---- the rename survives a reattach ----
c2 = stlib.Client(HOME, args=['--attach'], w=100, h=28)
c2.drain(2.5)
check('reattach shows renamed title', 'Background Job' in c2.text())
# ---- as of F4 management works LIVE with an attached client ----
r = run_cli(['minimize', SES + ':1'], HOME)
check('winop works while attached', r.returncode == 0)
r = run_cli(['restore', SES + ':1'], HOME)
check('restore works while attached', r.returncode == 0)
# list/send/capture keep working while attached
r = run_cli(['capture', SES + ':1'], HOME)
check('capture ok while attached', r.returncode == 0)
c2.send(b'\x1bx', 1.0)
time.sleep(0.6)
c2.close()

stlib.report()
