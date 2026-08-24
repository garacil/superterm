#!/usr/bin/env python3
"""A console application restored by a profile returns to a live shell."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


HOME = stlib.fresh_home('profile-shell-fallback')
INI = os.path.join(HOME, '.superterm', 'superterm.ini')
with open(INI, 'w') as f:
    f.write('''[ui]
language=en
[session]
default_profile=apps
server=always
autosave=0
autorestore=0
[profile.apps]
name=apps
enabled=1
focused_window=0
windows=main
[profile.apps.window.main]
enabled=1
layout=L
focused_pane=0
panes=console
[profile.apps.window.main.pane.console]
enabled=1
title=Console app
cmd=exec /bin/sh -c "echo PROFILE_APP_STARTED; read answer; echo PROFILE_APP_EXITED"
''')

c = stlib.Client(HOME, w=100, h=30, lang='en')
c.drain(2.5)
check('profile application starts', 'PROFILE_APP_STARTED' in c.text())

# This line lets the simulated console application terminate. Its command
# starts with exec on purpose: that was the path that replaced the launcher
# shell and left an EXITED pane with no prompt.
c.send(b'quit\r', 1.2)
check('profile application exits', 'PROFILE_APP_EXITED' in c.text())
c.send(b'echo SHELL_AFTER_PROFILE_APP\r', 1.2)
check('interactive shell remains', 'SHELL_AFTER_PROFILE_APP' in c.text())

c.send(b'echo SECOND_COMMAND_OK\r', 0.8)
check('shell accepts later commands', 'SECOND_COMMAND_OK' in c.text())
c.send(b'\x1bq', 0.8)
c.close()
stlib.close_all_daemons(HOME)
stlib.report()
