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
BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'bin', 'superterm'))
W, H = 110, 35

os.makedirs(HOME, exist_ok=True)
os.makedirs(HOME + '/.superterm', exist_ok=True)
for path in (HOME + '/.superterm/session.ini', HOME + '/.superterm/superterm.ini'):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass

CONFIG = '\n'.join([
    '[t1]', 'name=one', 'enabled=1', 'type=local',
    'cmd=/usr/bin/bash -i',
    '', '[t2]', 'name=two', 'enabled=1', 'type=local',
    'cmd=/usr/bin/bash -i',
    '', '[t3]', 'name=beta', 'enabled=1', 'type=local',
    'cmd=/usr/bin/bash -i',
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
                'SHELL': '/usr/bin/bash',
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
                    self.stream.feed(os.read(self.fd, 65536))
                except OSError:
                    return
                except Exception:
                    pass

    def text(self):
        return '\n'.join(row.rstrip() for row in self.screen.display)

    def close_without_save(self):
        try:
            os.write(self.fd, b'\x1bq')
            self.drain(0.5)
        except OSError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass


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
    check('template starts two panes', 'one' in text and 'two' in text)
    os.write(s.fd, b'\x1br')
    s.drain(0.4)
    check('template menu opens', 'Profiles' in s.text())
    check('template menu lists alpha', 'alpha' in s.text())
    os.write(s.fd, b'\x1b')
    s.drain(0.2)

    # F8 changes from the split dashboard to the single logs window.
    os.write(s.fd, b'\x1b[19~')
    s.drain(0.8)
    check('window switch works', 'two' in s.text())

    # Return to the template menu and select the second template.
    os.write(s.fd, b'\x1br')
    s.drain(0.2)
    os.write(s.fd, b'\x1b[B\r')
    s.drain(1.0)
    check('hot template switch works', 'beta' in s.text())
finally:
    s.close_without_save()

sys.exit(1 if fails else 0)
