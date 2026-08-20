#!/usr/bin/env python3
"""superterm test: wide terminal geometry and resize redraws."""
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
ROOT = '/tmp/opencode/stlarge'
HOME = ROOT + '/home'
os.makedirs(HOME + '/.superterm', exist_ok=True)


class Session:
    def __init__(self, width, height):
        self.width = width
        self.height = height
        self.screen = pyte.Screen(width, height)
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
        self.set_size(width, height, reset_screen=False)

    def set_size(self, width, height, reset_screen=True):
        self.width = width
        self.height = height
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', height, width, 0, 0))
        if reset_screen:
            self.screen = pyte.Screen(width, height)
            self.stream = pyte.ByteStream(self.screen)

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


def check_layout(session, label):
    rows = session.screen.display
    width = session.width
    height = session.height
    top = rows[1]
    bottom = rows[height - 3]
    status = rows[height - 1]
    expected = {
        (1, 0, '╔'),
        (1, width - 3, '╗'),
        (height - 3, 0, '╚'),
        (height - 3, width - 3, '┘'),
    }
    corners = {
        (y, x, char)
        for y, row in enumerate(rows)
        for x, char in enumerate(row)
        if char in '╔╗╚┘'
    }
    check(f'{label}: full frame', expected <= corners)
    check(f'{label}: no stale corners', corners == expected)
    check(f'{label}: status at bottom', 'V-split' in ''.join(status))
    check(f'{label}: frame dimensions', len(top) == width and len(bottom) == width)


s = Session(4096, 35)
try:
    s.drain(1.5)
    check_layout(s, '4096x35 startup')

    s.send(b"printf '\\033[44m\\033[2J\\033[H'\r", 1.2)
    background_cells = [s.screen.buffer[10][x].bg for x in range(2, s.width - 2)]
    check('4096x35 background fills',
          background_cells and all(color == 'blue' for color in background_cells))

    s.set_size(8192, 35)
    s.drain(1.8)
    check_layout(s, '8192x35 maximum')

    s.set_size(300, 80)
    s.drain(1.2)
    check_layout(s, '300x80 resize')

    s.set_size(4096, 35)
    s.drain(1.2)
    check_layout(s, '4096x35 restore')
finally:
    try:
        s.send(b'\x1bq', 0.5)
    except OSError:
        pass
    s.close()


sys.exit(1 if fails else 0)
