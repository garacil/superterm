#!/usr/bin/env python3
"""superterm test: window move/zoom/minimize controls and restoration."""
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

import pyte

BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'bin', 'superterm'))
ROOT = '/tmp/opencode/stwindow'
HOME = ROOT + '/home'
os.makedirs(HOME + '/.superterm', exist_ok=True)
SESS = HOME + '/.superterm/session.ini'
try:
    os.remove(SESS)
except FileNotFoundError:
    pass

W, H = 110, 35


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
                'SUPERTERM_INI': ROOT + '/none.ini',
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
                except Exception:
                    return

    def send(self, data, seconds=0.8):
        os.write(self.fd, data)
        self.drain(seconds)

    def text(self):
        return '\n'.join(row.rstrip() for row in self.screen.display)

    def close(self):
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
    print(f'{name:34}: ' + ('OK' if condition else 'FAIL'))
    if not condition:
        fails.append(name)


s = Session()
try:
    s.drain(1.5)
    check('window shortcuts visible',
          'F5 Zoom' in s.text() and 'F8 Window' in s.text())

    s.send(b'\x1bOQ')                  # F2: vertical split
    s.send(b'echo WINDOW_TWO_VISIBLE\r')
    check('split window created', 'WINDOW_TWO_VISIBLE' in s.text())

    s.send(b'\x1b[15~')                # F5: maximize focused window
    top = s.screen.display[1]
    check('window maximized', '↕' in top and '┌' not in top)

    s.send(b'\x1b[15~')                # F5: restore focused window
    check('window restored', '┌' in s.screen.display[1])

    s.send(b'\x1b\x1b[20~')            # Alt-F9: minimize focused window
    check('window minimized', 'WINDOW_TWO_VISIBLE' not in s.text())

    s.send(b'\x1bp')                  # Alt-P: Panes (restaurar vive aqui)
    menu = s.text()
    check('restore entries listed',
          'Restore all' in menu and 'Restore 2' in menu)
    s.send(b'r')                      # mnemonic: Restore all
    check('all windows restored', 'WINDOW_TWO_VISIBLE' in s.text())
finally:
    try:
        s.send(b'\x1bq', 0.5)          # Alt-Q: quit without saving
    except OSError:
        pass
    s.close()

sys.exit(1 if fails else 0)
