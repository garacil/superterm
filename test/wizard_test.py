#!/usr/bin/env python3
"""superterm test: session wizard menu, panes, and post-connect commands."""
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
ROOT = '/tmp/opencode/stwizard'
W, H = 110, 35
os.makedirs(ROOT, exist_ok=True)


class Session:
    def __init__(self):
        self.screen = pyte.Screen(W, H)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update({
                'TERM': 'xterm',
                'SHELL': '/bin/bash',
                'HOME': ROOT,
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

    def send(self, data, seconds=0.7):
        os.write(self.fd, data)
        self.drain(seconds)

    def text(self):
        return '\n'.join(''.join(row).rstrip() for row in self.screen.display)

    def close(self):
        try:
            os.write(self.fd, b'\x1bq')
            self.drain(0.4)
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
    print(f'{name:36}: ' + ('OK' if condition else 'FAIL'))
    if not condition:
        fails.append(name)


s = Session()
try:
    s.drain(1.2)
    s.send(b'\x1bs')  # Session
    check('session menu shows wizard', 'Quick session wizard' in s.text())
    s.send(b'w')
    s.send(b'2\r')
    s.send(b'bash -i\r')
    s.send(b'echo WIZARD_ONE\r')
    s.send(b'bash -i\r')
    s.send(b'echo WIZARD_TWO\r', 1.2)
    text = s.text()
    check('wizard creates two panes', 'WIZARD_ONE' in text and 'WIZARD_TWO' in text)
    check('wizard creates a divider', '│' in text)

    s.send(b'\x1bh')  # Help
    check('help menu is accessible', 'Help and shortcuts' in s.text())
    s.send(b'\r')
    check('help dialog opens', 'F2/F3 split' in s.text())
finally:
    s.close()


sys.exit(1 if fails else 0)
