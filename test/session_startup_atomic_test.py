#!/usr/bin/env python3
"""Fault-injected detached startup is bounded and ownership-safe.

The hooks are compiled into the ordinary fork path but are reachable only
with SUPERTERM_TESTING=1.  Every case owns a unique HOME and verifies that a
timeout/constructor exception leaves the original local PTY usable and no
published daemon behind, including a timeout after the child-only ownership
hook has run.
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


def write_config(home, session_name):
    with open(os.path.join(home, '.superterm', 'superterm.ini'), 'w',
              encoding='utf-8') as stream:
        stream.write(f'''[ui]
language=en
background=none
[session]
server=always
default_session={session_name}
default_profile=startup
autosave=0
autorestore=0
[profile.startup]
name=startup
enabled=1
focused_window=0
windows=main
[profile.startup.window.main]
enabled=1
layout=L
focused_pane=0
panes=p
[profile.startup.window.main.pane.p]
enabled=1
title=STARTUP
cmd=echo LOCAL_READY; exec /bin/bash -i
''')


for stage in ('intermediate-hang', 'daemon-hang-pre',
              'constructor-partial', 'daemon-hang-post'):
    home = stlib.fresh_home('session-startup-' + stage)
    session = 'fault-' + stage
    write_config(home, session)
    started = time.monotonic()
    client = stlib.Client(home, w=92, h=28, lang='en', env={
        'SUPERTERM_TESTING': '1',
        'SUPERTERM_TEST_DAEMON_STAGE': stage,
        # Three fixed 100 ms polls keep the fault suite quick. Production is
        # fixed at 300 polls (30 seconds).
        'SUPERTERM_TEST_STARTUP_POLLS': '3',
    })
    try:
        client.drain(2.0)
        elapsed = time.monotonic() - started
        check(stage + ' startup returns within bound', elapsed < 4.0)
        check(stage + ' keeps original client alive', client.alive())
        check(stage + ' leaves no published session',
              stlib.session_sockets(home) == [])
        token = ('LOCAL_' + stage.replace('-', '_')).upper()
        client.send(('echo ' + token + '\r').encode(), 0.8)
        check(stage + ' keeps original PTY writable', token in client.text())
    finally:
        client.close()
        stlib.close_all_daemons(home)

stlib.report()
