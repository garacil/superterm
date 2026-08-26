#!/usr/bin/env python3
"""Every supported wide host resize becomes the new canonical desktop.

The session is born at 4096x35, grows to FreeVision's 8192-column limit,
shrinks in both axes and returns. At every step its precomputed proportional
window rectangle and PTY size change in the same transaction. This keeps the
extreme-width renderer covered without retaining the obsolete contract where
every post-attach SIGWINCH was only a local viewport change.
"""
import fcntl
import glob
import os
import pty
import select
import signal
import stat
import struct
import sys
import termios
import time

import pyte

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


BIN = os.environ.get('SUPERTERM_TEST_BIN', os.path.abspath(os.path.join(
    os.path.dirname(__file__), '..', 'bin', 'superterm')))
HOME = stlib.fresh_home('large-screen')
DEBUG_LOG = HOME + '/large-screen-debug.log'
CANON_WIDTH = 4096
CANON_HEIGHT = 35


def diagnostic_tail(path, limit=65536):
    """Read a bounded tail only from the exact regular file globbed."""
    try:
        before = os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError as error:
        return f'[cannot lstat diagnostic: {error}]\n'
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        return '[diagnostic path is not a regular non-symlink file]\n'
    flags = os.O_RDONLY
    if hasattr(os, 'O_NOFOLLOW'):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags)
    except OSError as error:
        return f'[cannot open diagnostic: {error}]\n'
    try:
        after = os.fstat(fd)
        if (not stat.S_ISREG(after.st_mode) or
                (before.st_dev, before.st_ino) !=
                (after.st_dev, after.st_ino)):
            return '[diagnostic file changed identity before open]\n'
        os.lseek(fd, max(0, after.st_size - limit), os.SEEK_SET)
        chunks = []
        remaining = limit
        while remaining > 0:
            chunk = os.read(fd, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        return b''.join(chunks).decode('utf-8', 'replace')
    except OSError as error:
        return f'[cannot read diagnostic: {error}]\n'
    finally:
        os.close(fd)


with open(HOME + '/.superterm/superterm.ini', 'w') as config:
    config.write('[ui]\n'
                 'language=en\n'
                 'background=none\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n')


class Session:
    def __init__(self, width, height):
        self.width = width
        self.height = height
        self.screen = pyte.Screen(width, height)
        self.stream = pyte.ByteStream(self.screen)
        self.raw_tail = bytearray()
        self.wait_status = None
        # Install the unusually wide PTY geometry before SuperTerm can inspect
        # it.  Without this gate Darwin can schedule the child through exec
        # first, so the session is born from the PTY's transient 0x0/default
        # size and may exit before the parent's TIOCSWINSZ arrives.
        start_read, start_write = os.pipe()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.close(start_write)
            try:
                os.read(start_read, 1)
            finally:
                os.close(start_read)
            os.environ.update({
                'TERM': 'xterm',
                'SHELL': '/bin/bash',
                'HOME': HOME,
                'SUPERTERM_INI': HOME + '/no-sys.ini',
                'SUPERTERM_DEBUG': DEBUG_LOG,
                'SUPERTERM_DEBUG_FULL': '1',
            })
            os.execv(BIN, [BIN])
        os.close(start_read)
        try:
            self.set_size(width, height, reset_screen=False)
            os.write(start_write, b'1')
        finally:
            os.close(start_write)

    def set_size(self, width, height, reset_screen=True):
        self.width = width
        self.height = height
        # A real emulator changes its cell surface before the kernel delivers
        # SIGWINCH. Reset the pyte surface in that same order. Doing ioctl
        # first races SuperTerm's fast atomic repaint: bytes can reach the old
        # stream and then be discarded when this test replaces it.
        if reset_screen:
            self.screen = pyte.Screen(width, height)
            self.stream = pyte.ByteStream(self.screen)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', height, width, 0, 0))

    def drain(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            readable, _, _ = select.select([self.fd], [], [], 0.05)
            if readable:
                try:
                    data = os.read(self.fd, 65536)
                    if not data:
                        self.poll_status(0.5)
                        return
                    self.raw_tail.extend(data)
                    if len(self.raw_tail) > 65536:
                        del self.raw_tail[:-65536]
                    self.stream.feed(data)
                except OSError:
                    self.poll_status(0.5)
                    return
                except Exception:
                    pass

    def send(self, data, seconds=0.8):
        os.write(self.fd, data)
        self.drain(seconds)

    def poll_status(self, timeout=0.0):
        """Record, but never invent, the exact Darwin/Linux child result."""
        if self.wait_status is not None:
            return self.wait_status
        deadline = time.monotonic() + max(0.0, timeout)
        while True:
            try:
                waited, status = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                return self.wait_status
            if waited == self.pid:
                self.wait_status = status
                return status
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.02)

    def diagnose_exit(self, label):
        """Print evidence when the extreme-width child disappears early."""
        status = self.poll_status(0.5)
        if status is None:
            outcome = 'still running or not yet waitable'
        elif os.WIFEXITED(status):
            outcome = f'exit={os.WEXITSTATUS(status)}'
        elif os.WIFSIGNALED(status):
            outcome = f'signal={os.WTERMSIG(status)}'
        elif os.WIFSTOPPED(status):
            outcome = f'stopped={os.WSTOPSIG(status)}'
        else:
            outcome = f'wait_status={status}'
        print(f'  {label}: child pid={self.pid} {outcome}')
        if self.raw_tail:
            print('  PTY tail:')
            print(bytes(self.raw_tail[-4096:]).decode('utf-8', 'replace'))
        debug_tail = diagnostic_tail(DEBUG_LOG)
        if debug_tail is not None:
            print('  debug log tail:')
            print(debug_tail)
        reports = sorted(glob.glob(
            f'/tmp/superterm-crash-*-{self.pid}-*.log'))
        for path in reports:
            print(f'  crash report: {path}')
            print(diagnostic_tail(path) or '[diagnostic disappeared]\n')

    def close(self):
        end = time.time() + 4.0
        while time.time() < end:
            try:
                pid, _status = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                pid = self.pid
            if pid:
                break
            self.drain(0.1)
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


def frame_corners(session):
    return {
        (y, x, char)
        for y, row in enumerate(session.screen.display)
        for x, char in enumerate(row)
        if char in '╔╗╚┘'
    }


def expected_corners(rectangle):
    left, top, right, bottom = rectangle
    return {
        (top, left, '╔'),
        (top, right, '╗'),
        (bottom, left, '╚'),
        (bottom, right, '┘'),
    }


def scaled_single_pane(rectangle, old_host, new_host):
    """Mirror the integer ScaleEdge rule used for a shared host resize."""
    left, top, right, bottom = rectangle
    old_width, old_height = old_host[0], old_host[1] - 2
    new_width, new_height = new_host[0], new_host[1] - 2

    def edge(value, old_size, new_size):
        return (value * new_size + old_size // 2) // old_size

    new_left = edge(left, old_width, new_width)
    new_top = edge(top - 1, old_height, new_height)
    new_right = edge(right + 1, old_width, new_width)
    new_bottom = edge(bottom, old_height, new_height)
    new_left = max(0, min(new_left, new_width - 16))
    new_top = max(0, min(new_top, new_height - 6))
    new_right = min(new_width, max(new_right, new_left + 16))
    new_bottom = min(new_height, max(new_bottom, new_top + 6))
    return ((new_left, new_top + 1, new_right - 1, new_bottom),
            (new_right - new_left - 2, new_bottom - new_top - 2))


def pane_size(session_name):
    """Read the exact PTY WxH owned by the daemon."""
    result = stlib.run_cli(['list', session_name], HOME, env={'LANG': 'C'})
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        if not line.startswith('1 '):
            continue
        for token in line.split():
            if 'x' not in token or not token[0].isdigit():
                continue
            try:
                return tuple(int(part) for part in token.split('x', 1))
            except ValueError:
                pass
    return None


def settle(session, rectangle, timeout=15.0):
    """Wait for the physical surface to present the new shared desktop."""
    want = expected_corners(rectangle)
    end = time.time() + timeout
    while time.time() < end:
        session.drain(0.25)
        if frame_corners(session) == want:
            return time.time()
    return None


def check_layout(session, label, rectangle):
    rows = session.screen.display
    width = session.width
    height = session.height
    left, frame_top, right, frame_bottom = rectangle
    top = rows[frame_top]
    bottom = rows[frame_bottom]
    status = rows[height - 1]
    expected = expected_corners(rectangle)
    corners = frame_corners(session)
    check(f'{label}: full frame', expected <= corners)
    check(f'{label}: no stale corners', corners == expected)
    check(f'{label}: status at bottom', 'F2 Split' in ''.join(status))
    check(f'{label}: surface dimensions',
          len(top) == width and len(bottom) == width)
    check(f'{label}: frame matches scaled bounds',
          rows[frame_top][left] in '╔┌' and
          rows[frame_top][right] in '╗┐' and
          rows[frame_bottom][left] in '╚└' and
          rows[frame_bottom][right] in '╝┘')
    check(f'{label}: scaled frame stays on surface',
          0 <= left < right < width and 1 <= frame_top < frame_bottom < height - 1)


s = Session(CANON_WIDTH, CANON_HEIGHT)
session_name = ''
canonical_pty = None
try:
    current_host = (CANON_WIDTH, CANON_HEIGHT)
    current_rect = (0, 1, CANON_WIDTH - 3, CANON_HEIGHT - 3)
    startup_settled = settle(s, current_rect) is not None
    check('4096x35 startup settles', startup_settled)
    if not startup_settled:
        s.diagnose_exit('4096x35 startup')
    check_layout(s, '4096x35 startup', current_rect)
    sockets = stlib.session_sockets(HOME)
    check('one canonical session exists', len(sockets) == 1)
    if len(sockets) == 1:
        session_name = os.path.basename(sockets[0])[:-5]
    canonical_pty = pane_size(session_name) if session_name else None
    check('canonical PTY matches 4096x35 desktop',
          canonical_pty == (4092, 30))

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

    next_host = (8192, 35)
    current_rect, expected_pty = scaled_single_pane(
        current_rect, current_host, next_host)
    current_host = next_host
    s.set_size(*current_host)
    check('8192x35 resize settles', settle(s, current_rect) is not None)
    check_layout(s, '8192x35 maximum', current_rect)
    check('8192x35 changes shared PTY WxH',
          pane_size(session_name) == expected_pty)

    next_host = (300, 80)
    current_rect, expected_pty = scaled_single_pane(
        current_rect, current_host, next_host)
    current_host = next_host
    s.set_size(*current_host)
    check('300x80 resize settles', settle(s, current_rect) is not None)
    check_layout(s, '300x80 resize', current_rect)
    check('300x80 changes shared PTY WxH',
          pane_size(session_name) == expected_pty)

    next_host = (4096, 35)
    current_rect, expected_pty = scaled_single_pane(
        current_rect, current_host, next_host)
    current_host = next_host
    s.set_size(*current_host)
    check('4096x35 restore settles', settle(s, current_rect) is not None)
    check_layout(s, '4096x35 restore', current_rect)
    check('restore changes PTY back exactly',
          pane_size(session_name) == expected_pty)
finally:
    try:
        s.send(b'\x1bx', 0.5)
    except OSError:
        pass
    s.close()
    stlib.close_all_daemons(HOME)

stlib.report()
