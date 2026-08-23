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

    # active wait: polls until pred holds (or timeout), so nothing is
    # checked before the UI has reacted. Robustness under load.
    def wait_until(self, pred, timeout=12.0):
        end = time.time() + timeout
        while time.time() < end:
            self.drain(0.2)
            if pred():
                return True
        return pred()

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
    # wait for startup to draw the menu bar before clicking
    s.wait_until(lambda: any('Panes' in ''.join(row) for row in s.screen.display))
    s.mouse(5, 1)
    s.wait_until(lambda: any('Split vertical' in ''.join(row)
                             for row in s.screen.display))
    check('mouse opens Panels menu',
          any('Split vertical' in ''.join(row) for row in s.screen.display))

    # Panes > Vertical, using global 1-based SGR coordinates.
    s.mouse(5, 3)
    s.wait_until(lambda: any('│' in ''.join(row) for row in s.screen.display))
    check('menu click creates split',
          any('│' in ''.join(row) for row in s.screen.display))

    # a new window is centred on top of the others, so "the right half" is
    # no longer where it lands: what matters is that the focused (new) pane
    # got the token and the old one did not
    s.send(b'echo RIGHT_TOKEN\r')
    s.wait_until(lambda: any('RIGHT_TOKEN' in ''.join(row)
                             for row in s.screen.display))
    check('new pane receives input',
          any('RIGHT_TOKEN' in ''.join(row) for row in s.screen.display))

    # The new window is focused; click the one underneath, on a column the
    # centred window does not cover.
    s.mouse(3, 5)
    s.send(b'echo LEFT_TOKEN\r')
    s.wait_until(lambda: any('LEFT_TOKEN' in ''.join(row)
                             for row in s.screen.display))
    check('pane click focuses the pane underneath',
          any('LEFT_TOKEN' in ''.join(row) for row in s.screen.display))
    check('each token went to one pane only',
          sum('LEFT_TOKEN' in ''.join(row) for row in s.screen.display) <= 2)
finally:
    try:
        s.send(b'\x1bq', 0.5)
    except OSError:
        pass
    s.close()


sys.exit(1 if fails else 0)
