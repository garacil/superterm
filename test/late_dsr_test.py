#!/usr/bin/env python3
"""A late cursor-position report is not an F3/window command."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('late-dsr')
with open(HOME + '/.superterm/superterm.ini', 'w') as fh:
    fh.write('[ui]\nlanguage=en\nbackground=none\n'
             '[session]\nserver=always\nautosave=0\nautorestore=0\n')

a = stlib.Client(HOME, w=100, h=30, lang='en')
a.drain(2.0)
sockets = stlib.session_sockets(HOME)
check('session exists', len(sockets) == 1)
session = os.path.basename(sockets[0])[:-5] if sockets else ''


def pane_count():
    result = run_cli(['list', session], HOME, env={'LANG': 'C'})
    return sum(1 for line in result.stdout.splitlines()
               if line.split() and line.split()[0].isdigit())


initial = pane_count()
check('creator has one pane', initial == 1)

# Do not read the child PTY while CaptureConsoleCursor performs its bounded
# 0.2-second DSR read. Only afterwards consume its output and answer CSI 6 n;
# this guarantees the CPR reaches the already-installed keyboard driver.
b = stlib.Client(HOME, args=['--attach', session], w=100, h=30, lang='en')
time.sleep(0.35)
b.drain(2.0)
a.drain(0.5)
check('client actually receives DSR request', b'\x1b[6n' in b.raw())
check('late DSR client attaches', b.alive())
check('late DSR creates no phantom pane', pane_count() == initial)

# A normal F3/CSI-R ambiguity must not leave queued bytes or destabilize the
# following real input. The shared pane receives this marker exactly once.
b.send(b"printf '\\033[2J\\033[HAFTER_LATE_DSR\\n'\r", 0.7)
captured = run_cli(['capture', session + ':1'], HOME).stdout
check('input after late DSR is intact', captured.count('AFTER_LATE_DSR') == 1)

for client in (b, a):
    client.send(b'\x11', 0.10)
    client.send(b'd', 0.35)
    client.wait_exit(timeout=5.0)
    client.close()
stlib.close_all_daemons(HOME)
stlib.report()
