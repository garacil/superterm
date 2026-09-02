#!/usr/bin/env python3
"""Profile default is explicit and survives save/exit bookkeeping."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


HOME = stlib.fresh_home('profile-default')
INI = os.path.join(HOME, '.superterm', 'superterm.ini')
with open(INI, 'w') as f:
    f.write('''[ui]
language=en
[session]
default_profile=alpha
default_window=main
server=always
autosave=0
autorestore=0

[profile.alpha]
name=alpha
enabled=1
focused_window=0
windows=main
[profile.alpha.window.main]
enabled=1
layout=L
focused_pane=0
panes=p
[profile.alpha.window.main.pane.p]
enabled=1
cmd=printf ALPHA_PROFILE\\n; exec /bin/bash -i

[profile.beta]
name=beta
enabled=1
focused_window=0
windows=work
[profile.beta.window.work]
enabled=1
layout=L
focused_pane=0
panes=p
[profile.beta.window.work.pane.p]
enabled=1
cmd=printf BETA_PROFILE\\n; exec /bin/bash -i
''')

c = stlib.Client(HOME, w=100, h=30, lang='en')
c.drain(2.5)


def click_text(label):
    """Click the middle of the first visible occurrence of label."""
    for y, row in enumerate(c.screen.display):
        x = row.find(label)
        if x >= 0:
            px = x + max(1, len(label) // 2) + 1
            py = y + 1
            c.send(f'\x1b[<0;{px};{py}M\x1b[<0;{px};{py}m'.encode(), 0.8)
            return True
    return False


def open_manager():
    c.send(b'\x1br', 0.4)
    c.send(b'm', 0.8)
    return 'Set default' in c.text() and 'alpha' in c.text() and 'beta' in c.text()


def default_row(name):
    return any(name in row and '(default)' in row
               for row in c.screen.display)


check('alpha profile starts', 'ALPHA_PROFILE' in c.text())
check('profile manager opens', open_manager())
check('initial default is alpha', default_row('alpha'))
check('select beta row', click_text('beta'))
check('set-default button clicked', click_text('Set default'))

# The manager closes after Set default. Reopening must show the new mark.
check('manager reopens after set default', open_manager())
check('beta immediately marked default', default_row('beta'))
c.send(b'\x1b', 0.5)

# Ctrl-S used to call RememberProfileSelection, which silently changed the
# default back to the active alpha profile. It must now remember only the
# active window when alpha itself is the configured default.
c.send(b'\x13', 0.8)
if 'Profile selection saved' in c.text():
    c.send(b'\r', 0.5)
check('manager reopens after Ctrl-S', open_manager())
check('beta remains default after Ctrl-S', default_row('beta'))
c.send(b'\x1b', 0.4)

with open(INI) as f:
    saved = f.read()
check('default persisted in config', 'default_profile=beta' in saved)
check('default window follows beta', 'default_window=work' in saved)

c.send(b'\x1bx', 0.8)
c.close()
stlib.close_all_daemons(HOME)
stlib.report()
