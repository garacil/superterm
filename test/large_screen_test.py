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

sys.path.insert(0, os.path.dirname(__file__))
import stlib


BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'bin', 'superterm'))
HOME = stlib.fresh_home('large-screen')


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
                'SUPERTERM_INI': HOME + '/no-sys.ini',
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


def frame_corners(session):
    return {
        (y, x, char)
        for y, row in enumerate(session.screen.display)
        for x, char in enumerate(row)
        if char in '╔╗╚┘'
    }


def expected_corners(session):
    return {
        (1, 0, '╔'),
        (1, session.width - 3, '╗'),
        (session.height - 3, 0, '╚'),
        (session.height - 3, session.width - 3, '┘'),
    }


def settle(session, timeout=20.0):
    """Wait for the layout to reach its final shape.

    A resize is not one paint: the mode change, the bounds change and the
    relayout each produce one, and at 4096 or 8192 columns a single frame is
    hundreds of thousands of cells. Measured here, the 4096-column restore
    needs a bit over two seconds. Sampling on a fixed pause read an
    intermediate frame and reported stale corners that were simply the
    previous layout still on screen -- which is what the 3.3 'known issue'
    really was. Wait for the shape instead; the assertions below still fail
    if it never arrives.
    """
    want = expected_corners(session)
    end = time.time() + timeout
    while time.time() < end:
        session.drain(0.25)
        if frame_corners(session) == want:
            return time.time()
    return None


def check_layout(session, label):
    rows = session.screen.display
    width = session.width
    height = session.height
    top = rows[1]
    bottom = rows[height - 3]
    status = rows[height - 1]
    expected = expected_corners(session)
    corners = frame_corners(session)
    check(f'{label}: full frame', expected <= corners)
    check(f'{label}: no stale corners', corners == expected)
    check(f'{label}: status at bottom', 'F2 Split' in ''.join(status))
    check(f'{label}: frame dimensions', len(top) == width and len(bottom) == width)


s = Session(4096, 35)
try:
    settle(s)
    check_layout(s, '4096x35 startup')

    s.send(b"printf '\\033[44m\\033[2J\\033[H'\r", 1.2)
    background_cells = [s.screen.buffer[10][x].bg for x in range(2, s.width - 3)]
    check('4096x35 background fills',
          background_cells and all(color == 'blue' for color in background_cells))
    s.send(b"printf '\\033[107m\\033[2J\\033[H'\r", 1.2)
    bright_background_cells = [s.screen.buffer[10][x].bg
                               for x in range(2, s.width - 3)]
    check('4096x35 bright background fills',
          bright_background_cells and
          all(color == 'brightwhite' for color in bright_background_cells))

    s.set_size(8192, 35)
    settle(s)
    check_layout(s, '8192x35 maximum')

    s.set_size(300, 80)
    settle(s)
    check_layout(s, '300x80 resize')

    s.set_size(4096, 35)
    settle(s)
    check_layout(s, '4096x35 restore')
finally:
    try:
        s.send(b'\x1bq', 0.5)
    except OSError:
        pass
    s.close()
    stlib.close_all_daemons(HOME)

sys.exit(1 if fails else 0)
