#!/usr/bin/env python3
"""superterm test: resize a terminal window with xterm mouse events."""
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
ROOT = '/tmp/opencode/stmouse'
HOME = ROOT + '/home'
WIDTH, HEIGHT = 381, 104
os.makedirs(HOME + '/.superterm', exist_ok=True)


class Session:
    def __init__(self):
        self.screen = pyte.Screen(WIDTH, HEIGHT)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update({
                'TERM': os.environ.get('SUPERTERM_TEST_TERM', 'xterm'),
                'SHELL': '/bin/bash',
                'HOME': HOME,
                'SUPERTERM_INI': ROOT + '/none.ini',
            })
            os.execv(BIN, [BIN])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', HEIGHT, WIDTH, 0, 0))

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

    def mouse(self, code, x, y, motion=False, release=False):
        if motion:
            code += 32
        suffix = 'm' if release else 'M'
        os.write(self.fd, f'\x1b[<{code};{x};{y}{suffix}'.encode())

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


def frame_right():
    for row in s.screen.display:
        if '╔' in row and '╗' in row:
            return row.index('╗')
    return -1


s = Session()
try:
    s.drain(1.5)
    before = frame_right()
    check('mouse frame starts full width', before == WIDTH - 3)

    # The frame grow handle is the bottom-right cell. Coordinates are 1-based
    # in the xterm SGR mouse protocol and global in the terminal screen.
    start_x, start_y = WIDTH - 2, HEIGHT - 2
    end_x, end_y = WIDTH - 22, HEIGHT - 7
    s.mouse(0, start_x, start_y)
    s.mouse(0, end_x, end_y, motion=True)
    s.mouse(0, end_x, end_y, release=True)
    s.drain(1.0)

    after = frame_right()
    check('mouse resize changes frame width', 0 < after < before)
    check('mouse resize keeps statusline', 'V-split' in ''.join(s.screen.display[-1]))
finally:
    try:
        os.write(s.fd, b'\x1bq')
        s.drain(0.5)
    except OSError:
        pass
    s.close()


sys.exit(1 if fails else 0)
