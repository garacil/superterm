#!/usr/bin/env python3
"""superterm test: mouse menu activation and pane focus under tmux TERM."""
import fcntl
import os
import pty
import pyte
import select
import struct
import sys
import termios
import time


BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'bin', 'superterm'))
ROOT = '/tmp/opencode/stmouse-focus'
HOME = ROOT + '/home'
W, H = 110, 35
os.makedirs(HOME, exist_ok=True)


class Session:
    def __init__(self):
        self.screen = pyte.Screen(W, H)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update({
                'TERM': 'tmux-256color',
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
                except OSError:
                    return
                except Exception:
                    pass

    def send(self, data, seconds=0.8):
        os.write(self.fd, data)
        self.drain(seconds)

    def mouse(self, x, y):
        os.write(self.fd, f'\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m'.encode())
        self.drain(0.5)

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
    print(f'{name:36}: ' + ('OK' if condition else 'FAIL'))
    if not condition:
        fails.append(name)


s = Session()
try:
    s.drain(1.5)
    s.mouse(5, 1)
    check('mouse opens Panels menu',
          any('Split vertical' in ''.join(row) for row in s.screen.display))

    # Paneles > Vertical, using global 1-based SGR coordinates.
    s.mouse(5, 3)
    check('menu click creates split',
          any('│' in ''.join(row) for row in s.screen.display))

    s.send(b'echo RIGHT_TOKEN\r')
    check('new pane receives input',
          any('RIGHT_TOKEN' in ''.join(row[W // 2:])
              for row in s.screen.display))

    # The split initially focuses the right pane; click the old left pane.
    s.mouse(10, 5)
    s.send(b'echo LEFT_TOKEN\r')
    check('pane click focuses left pane',
          any('LEFT_TOKEN' in ''.join(row[:W // 2])
              for row in s.screen.display))
    check('left token not sent to right pane',
          not any('LEFT_TOKEN' in ''.join(row[W // 2:])
                  for row in s.screen.display))
finally:
    try:
        s.send(b'\x1bq', 0.5)
    except OSError:
        pass
    s.close()


sys.exit(1 if fails else 0)
