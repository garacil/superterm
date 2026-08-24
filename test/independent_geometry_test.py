#!/usr/bin/env python3
"""Each client owns a viewport; only explicit commands resize the PTY."""
import configparser
import glob
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('independent-geometry')
with open(HOME + '/.superterm/superterm.ini', 'w') as fh:
    fh.write('[ui]\nlanguage=en\nbackground=none\n'
             '[session]\nserver=always\nautosave=0\nautorestore=0\n'
             'resize_policy=session\n')


def pane_size(session):
    result = run_cli(['list', session], HOME, env={'LANG': 'C'})
    for line in result.stdout.splitlines():
        if not line.startswith('1 '):
            continue
        for token in line.split():
            if 'x' not in token or not token[0].isdigit():
                continue
            try:
                cols, rows = (int(v) for v in token.split('x', 1))
                return cols, rows
            except ValueError:
                pass
    return None


a = stlib.Client(HOME, w=120, h=36, lang='en')
a.drain(2.5)
sockets = stlib.session_sockets(HOME)
check('session exists', len(sockets) == 1)
session = os.path.basename(sockets[0])[:-5] if sockets else ''
initial = pane_size(session)
check('canonical PTY has initial size', initial is not None)

sidecars = glob.glob(HOME + '/.superterm/sessions/*.ini')
policy_ok = False
if len(sidecars) == 1:
    cp = configparser.ConfigParser()
    cp.read(sidecars[0])
    policy_ok = cp.get('session', 'resize_policy', fallback='') == 'session'
check('daemon advertises session policy', policy_ok)

# Attaching a smaller client must not send its window size to the daemon.
b = stlib.Client(HOME, args=['--attach'], w=70, h=22, lang='en')
b.drain(3.0)
check('smaller client attaches', b.alive())
check('attach leaves canonical size', pane_size(session) == initial)

run_cli(['send', session + ':1', 'echo BOTH_VIEWPORTS_OK'], HOME)
a.wait_until(lambda text: 'BOTH_VIEWPORTS_OK' in text, 5.0)
b.wait_until(lambda text: 'BOTH_VIEWPORTS_OK' in text, 5.0)
check('large viewport stays live', 'BOTH_VIEWPORTS_OK' in a.text())
check('small viewport stays live', 'BOTH_VIEWPORTS_OK' in b.text())

# A real host resize changes only B's crop/padding. The pane process keeps the
# same TIOCSWINSZ and A is not redrawn to B's geometry.
b.resize(56, 18, 2.0)
check('host resize leaves canonical size', pane_size(session) == initial)

# Put the application cursor near the canonical bottom-right and enable SGR
# mouse reporting. B must pan to the cursor; a click in B's local viewport is
# translated back through those offsets before reaching the application.
cols, rows = initial
# A first window uses host width-2 and host height-4 for its terminal view.
view_w = b.w - 2
view_h = b.h - 4
target_col = min(cols - 15, view_w + 8)
target_row = min(rows - 5, view_h + 5)
command = ("printf '\\033[H\\033[?1000h\\033[?1006h'; sleep 1.5; "
           f"printf '\\033[{target_row};{target_col}H'; cat -v")
run_cli(['send', session + ':1', command], HOME)
screen_x, screen_y = 10, 8
click = f'\x1b[<0;{screen_x};{screen_y}M'.encode()
time.sleep(0.4)
b.drain(0.2)
b.send(click, 0.2)       # while the cursor (and viewport) are at the origin
time.sleep(1.2)
b.drain(0.3)
b.send(click, 0.8)       # after the cursor moved beyond the small viewport
a.drain(0.8)
mouse_reports = [(int(x), int(y)) for x, y in
                 re.findall(r'\^\[\[<0;(\d+);(\d+)M', a.text())]
base_col, base_row = screen_x - 1, screen_y - 2
translated = len(mouse_reports) >= 2 and mouse_reports[-2] == (
    base_col, base_row) and mouse_reports[-1][0] > base_col and \
    mouse_reports[-1][1] > base_row and mouse_reports[-1][0] <= cols and \
    mouse_reports[-1][1] <= rows
check('viewport follows canonical cursor', target_col > view_w and
      target_row > view_h)
check('mouse coordinates include viewport', translated)
a.send(b'\x03', 0.5)
a.send(b"printf '\033[?1000l\033[?1006l'\r", 0.8)

# An explicit control operation is deliberately global and authoritative.
result = run_cli(['resize', session + ':1', '90x25'], HOME)
check('explicit canonical resize succeeds', result.returncode == 0)
end = time.time() + 5.0
while time.time() < end and pane_size(session) != (90, 25):
    time.sleep(0.1)
check('explicit resize changes canonical', pane_size(session) == (90, 25))

# Disconnecting and resizing the remaining host are viewport-only too.
b.send(b'\x11', 0.3)
b.send(b'd', 0.8)
b.close()
time.sleep(0.8)
check('disconnect leaves canonical size', pane_size(session) == (90, 25))
a.resize(135, 42, 1.5)
check('large host resize is viewport-only', pane_size(session) == (90, 25))

a.send(b'\x1bx', 1.0)
a.close()
stlib.close_all_daemons(HOME)
stlib.report()
