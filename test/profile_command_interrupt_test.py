#!/usr/bin/env python3
"""Ctrl-C stops a restored profile command without killing its pane shell."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check, run_cli


HOME = stlib.fresh_home('profile-command-interrupt')
CONFIG = os.path.join(HOME, '.superterm', 'superterm.ini')
with open(CONFIG, 'w', encoding='utf-8') as stream:
    stream.write('''[ui]
language=en
background=none
desktop_notifications=0
[autologin]
shell=/bin/bash
login=1
[session]
server=always
default_profile=interrupt
default_window=main
autosave=0
autorestore=0

[profile.interrupt]
name=interrupt
enabled=1
focused_window=0
windows=main
[profile.interrupt.window.main]
enabled=1
layout=L
focused_pane=0
panes=stream
[profile.interrupt.window.main.pane.stream]
enabled=1
title=RANDOM
cmd=printf 'PROFILE_COMMAND_RUNNING\\n'; cat /dev/random >/dev/null
''')


client = None
try:
    client = stlib.Client(HOME, w=100, h=30, lang='en')
    started = client.wait_until(
        lambda text: 'PROFILE_COMMAND_RUNNING' in text, 10.0)
    check('persisted profile command starts', started)

    # The terminal driver delivers this as SIGINT to its foreground process
    # group. It must end only the configured command, not the shell which
    # supervises the pane and becomes interactive afterwards.
    if started:
        client.send(b'\x03', 0.4)
        client.send(b"printf 'PROFILE_SHELL_SURVIVED\\n'\r", 0.0)
    survived = client.wait_until(
        lambda text: 'PROFILE_SHELL_SURVIVED' in text, 8.0)
    check('Ctrl-C leaves an interactive pane shell', survived)

    sockets = stlib.session_sockets(HOME)
    session = os.path.basename(sockets[0])[:-5] if len(sockets) == 1 else ''
    listed = run_cli(['list', session], HOME) if session else None
    check('interrupted profile pane remains live',
          listed is not None and listed.returncode == 0 and
          any(line.startswith('1 ') for line in listed.stdout.splitlines()))
    captured = run_cli(['capture', session + ':1'], HOME) if session else None
    check('surviving shell state is canonical',
          captured is not None and captured.returncode == 0 and
          'PROFILE_SHELL_SURVIVED' in captured.stdout)
finally:
    if client is not None:
        if client.alive():
            client.send(b'\x1bx', 0.5)
            client.wait_exit(5.0)
        client.close()
    stlib.close_all_daemons(HOME)

stlib.report()
