#!/usr/bin/env python3
"""superterm test: named templates, windows, SQLite-compatible model, switching."""
import os
import pty
import select
import sys
import fcntl
import termios
import struct
import time

import pyte

ROOT = '/tmp/opencode/sttemplate'
HOME = ROOT + '/home'
SYSINI = ROOT + '/superterm.ini'
BIN = os.environ.get('SUPERTERM_TEST_BIN', os.path.abspath(os.path.join(
    os.path.dirname(__file__), '..', 'bin', 'superterm')))
W, H = 110, 35

sys.path.insert(0, os.path.dirname(__file__))
from stlib import close_all_daemons, feed_pyte, wait_pid

close_all_daemons(HOME)
os.makedirs(HOME, exist_ok=True)
os.makedirs(HOME + '/.superterm', exist_ok=True)
for path in (HOME + '/.superterm/session.ini', HOME + '/.superterm/superterm.ini'):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass

CONFIG = '\n'.join([
    '[t1]', 'name=one', 'title=ALPHA_ONE', 'enabled=1', 'type=local',
    'cmd=/bin/bash -i',
    '', '[t2]', 'name=two', 'title=ALPHA_TWO', 'enabled=1', 'type=local',
    'cmd=/bin/bash -i',
    '', '[t3]', 'name=beta', 'title=BETA_ONLY', 'enabled=1', 'type=local',
    'cmd=/bin/bash -i',
    '', '[template.alpha]', 'name=alpha', 'enabled=1',
    'default_session=main', 'sessions=main',
    '', '[template.alpha.session.main]', 'enabled=1',
    'focused_window=0', 'windows=dashboard,logs',
    '', '[template.alpha.session.main.window.dashboard]', 'enabled=1',
    'layout=V:500;L;L', 'focused_pane=0', 'panes=first,second',
    '', '[template.alpha.session.main.window.dashboard.pane.first]',
    'enabled=1', 'terminal=one',
    '', '[template.alpha.session.main.window.dashboard.pane.second]',
    'enabled=1', 'terminal=two',
    '', '[template.alpha.session.main.window.logs]', 'enabled=1',
    'layout=L', 'focused_pane=0', 'panes=logs',
    '', '[template.alpha.session.main.window.logs.pane.logs]',
    'enabled=1', 'terminal=two',
    '', '[template.beta]', 'name=beta-template', 'enabled=1',
    'default_session=main', 'sessions=main',
    '', '[template.beta.session.main]', 'enabled=1', 'windows=remote',
    '', '[template.beta.session.main.window.remote]', 'enabled=1',
    'layout=L', 'panes=remote',
    '', '[template.beta.session.main.window.remote.pane.remote]',
    'enabled=1', 'terminal=beta',
]) + '\n'
with open(SYSINI, 'w') as f:
    f.write(CONFIG)


class Session:
    def __init__(self):
        self.screen = pyte.Screen(W, H)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update({
                'TERM': 'xterm',
                'SHELL': '/bin/bash',
                'HOME': HOME,
                'SUPERTERM_INI': SYSINI,
            })
            os.execv(BIN, [BIN])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', H, W, 0, 0))

    def drain(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            readable, _, _ = select.select([self.fd], [], [], 0.05)
            if readable:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    return
                feed_pyte(self.stream, data, 'template')

    def text(self):
        return '\n'.join(row.rstrip() for row in self.screen.display)

    def close(self):
        try:
            os.write(self.fd, b'\x1bx')
            self.drain(0.5)
        except OSError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass
        wait_pid(self.pid)


fails = []


def check(name, condition):
    print(f'{name:30}: ' +
          ('OK' if condition else 'FAIL'))
    if not condition:
        fails.append(name)


s = Session()
try:
    s.drain(1.5)
    text = s.text()
    check('template starts two panes',
          'ALPHA_ONE' in text and 'ALPHA_TWO' in text)
    os.write(s.fd, b'\x1br')
    s.drain(0.4)
    check('template menu opens', 'Profiles' in s.text())
    check('template menu lists alpha', 'alpha' in s.text())
    os.write(s.fd, b'\x1b')
    s.drain(0.2)

    # F8 changes from the split dashboard already proved above to the single
    # logs window. These titles are parsed by st_wclass; ignored keys in a
    # legacy pane section must never be used as an oracle.
    # The menu can cover a title and its closing repaint may be coalesced with
    # F8 on a loaded host.  `text` is the already-proven dashboard presentation
    # captured before opening that transient overlay.
    dashboard_before_f8 = text
    os.write(s.fd, b'\x1b[19~')
    deadline = time.time() + 5.0
    logs_after_f8 = dashboard_before_f8
    while time.time() < deadline:
        s.drain(0.2)
        logs_after_f8 = s.text()
        if (logs_after_f8 != dashboard_before_f8 and
                'ALPHA_TWO' in logs_after_f8 and
                'ALPHA_ONE' not in logs_after_f8):
            break
    check('F8 visibly changes window state',
          logs_after_f8 != dashboard_before_f8 and
          'ALPHA_TWO' in logs_after_f8 and
          'ALPHA_ONE' not in logs_after_f8)

    # Return to the template menu and select the second template.
    os.write(s.fd, b'\x1br')
    s.drain(0.2)
    os.write(s.fd, b'\x1b[B\r')
    s.drain(1.0)
    check('hot template switch works', 'BETA_ONLY' in s.text())
finally:
    s.close()
    close_all_daemons(HOME)

sys.exit(1 if fails else 0)
