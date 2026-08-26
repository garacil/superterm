#!/usr/bin/env python3
"""superterm test: resize a terminal window with xterm mouse events."""
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

import pyte

sys.path.insert(0, os.path.dirname(__file__))
import stlib


BIN = os.environ.get('SUPERTERM_TEST_BIN', os.path.abspath(os.path.join(
    os.path.dirname(__file__), '..', 'bin', 'superterm')))
HOME = stlib.fresh_home('mouse')
WIDTH, HEIGHT = 381, 104
with open(HOME + '/.superterm/superterm.ini', 'w') as config:
    config.write('[ui]\n'
                 'language=en\n'
                 'background=none\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n')


class Session:
    def __init__(self):
        self.screen = pyte.Screen(WIDTH, HEIGHT)
        self.stream = pyte.ByteStream(self.screen)
        start_read, start_write = os.pipe()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.close(start_write)
            try:
                os.read(start_read, 1)
            finally:
                os.close(start_read)
            os.environ.update({
                'TERM': os.environ.get('SUPERTERM_TEST_TERM', 'xterm'),
                'SHELL': '/bin/bash',
                'HOME': HOME,
                'SUPERTERM_INI': HOME + '/no-sys.ini',
            })
            os.execv(BIN, [BIN])
        os.close(start_read)
        try:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                        struct.pack('HHHH', HEIGHT, WIDTH, 0, 0))
            os.write(start_write, b'1')
        finally:
            os.close(start_write)

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
        end = time.time() + 3.0
        while time.time() < end:
            try:
                pid, _status = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                pid = self.pid
            if pid:
                break
            time.sleep(0.05)
        else:
            try:
                os.kill(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            end = time.time() + 1.0
            while time.time() < end:
                try:
                    pid, _status = os.waitpid(self.pid, os.WNOHANG)
                except ChildProcessError:
                    pid = self.pid
                if pid:
                    break
                time.sleep(0.05)
            else:
                try:
                    os.kill(self.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                end = time.time() + 1.0
                while time.time() < end:
                    try:
                        pid, _status = os.waitpid(self.pid, os.WNOHANG)
                    except ChildProcessError:
                        break
                    if pid:
                        break
                    time.sleep(0.05)
        try:
            os.close(self.fd)
        except OSError:
            pass


fails = []


def check(name, condition):
    print(f'{name:34}: ' + ('OK' if condition else 'FAIL'))
    if not condition:
        fails.append(name)


def frame_rect():
    for top, row in enumerate(s.screen.display):
        if '╔' not in row or '╗' not in row:
            continue
        left, right = row.index('╔'), row.index('╗')
        for bottom in range(top + 2, s.screen.lines):
            if (s.screen.display[bottom][left] in ('╚', '└') and
                    s.screen.display[bottom][right] in ('╝', '┘')):
                return left, top, right, bottom
    return None


s = Session()
try:
    s.drain(1.5)
    before = frame_rect()
    # FPC's Unix Video layer exposes a 240-column logical startup desktop;
    # the wider physical terminal is only this client's viewport/margin.
    check('mouse frame starts on fixed desktop',
          before == (0, 1, 237, 101))

    # The frame grow handle is the bottom-right cell. Coordinates are 1-based
    # in the xterm SGR mouse protocol and global in the terminal screen.
    if before is not None:
        _left, _top, right, bottom = before
        end_right, end_bottom = right - 20, bottom - 5
        s.mouse(0, right + 1, bottom + 1)
        s.mouse(0, end_right + 1, end_bottom + 1, motion=True)
        s.mouse(0, end_right + 1, end_bottom + 1, release=True)
    s.drain(1.0)

    after = frame_rect()
    check('mouse resize changes exact fixed-desktop frame',
          after == (0, 1, 217, 96))
    check('mouse resize keeps statusline', 'F2 Split' in ''.join(s.screen.display[-1]))
finally:
    try:
        os.write(s.fd, b'\x1bx')
        s.drain(0.5)
    except OSError:
        pass
    stlib.close_all_daemons(HOME)
    s.close()


sys.exit(1 if fails else 0)
