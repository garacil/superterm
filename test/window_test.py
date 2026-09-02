#!/usr/bin/env python3
"""superterm test: window move/zoom/minimize controls and restoration."""
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
HOME = stlib.fresh_home('window')
with open(HOME + '/.superterm/superterm.ini', 'w') as config:
    config.write('[ui]\n'
                 'language=en\n'
                 'background=none\n'
                 '[session]\n'
                 'server=always\n'
                 'autosave=0\n'
                 'autorestore=0\n')

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
                'SUPERTERM_INI': HOME + '/no-sys.ini',
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
        end = time.time() + 3.0
        status = None
        while time.time() < end:
            try:
                pid, status = os.waitpid(self.pid, os.WNOHANG)
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
                    pid, status = os.waitpid(self.pid, os.WNOHANG)
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
                        pid, status = os.waitpid(self.pid, os.WNOHANG)
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


s = Session()
try:
    s.drain(1.5)
    check('window shortcuts visible',
          'Ctrl-Q f Full screen' in s.text() and 'F8 Window' in s.text())

    s.send(b'\x1bOQ')                  # F2: vertical split
    s.send(b'echo WINDOW_TWO_VISIBLE\r')
    check('split window created', 'WINDOW_TWO_VISIBLE' in s.text())

    # Fullscreen: the pane enters passthrough (its raw bytes
    # own the terminal), so superterm's chrome disappears
    s.send(stlib.FULLSCREEN_CHORD, 1.3)
    check('maximize enters passthrough', 'Detach' not in s.text())

    # The same chord restores the window manager.
    s.send(stlib.FULLSCREEN_CHORD, 1.3)
    check('restore leaves passthrough',
          'Detach' in s.text() and '┌' in s.screen.display[1])

    # fresh marker: the passthrough resize cycle made bash reprint, so the
    # first marker scrolled off; this also proves the pane survived it
    s.send(b'echo WINDOW_TWO_AGAIN\r')
    check('pane alive after passthrough', 'WINDOW_TWO_AGAIN' in s.text())

    # count window frames by top-left corners (active '╔' + inactive '┌'):
    # the resize churn scrolls echo markers away, so verify structurally
    def windows():
        corners = 0
        icons = 0
        rows = s.screen.display
        for y, row in enumerate(rows):
            for x, char in enumerate(row):
                if char not in ('┌', '╔'):
                    continue
                corners += 1
                # A minimized window is a two-row icon. It still has a top
                # corner, so the old raw corner count called an icon a normal
                # window and made this assertion fail even when minimize was
                # visibly correct.
                if (y + 1 < len(rows) and
                        rows[y + 1][x] in ('└', '╚')):
                    icons += 1
        return corners - icons

    check('two windows before minimize', windows() == 2)
    # xterm modifyOtherKeys form decoded by st_kbd: CSI 20;3~ is Alt-F9.
    # ESC + an unmodified F9 is two independent sequences and can leave a
    # literal Escape pending, so it is not an honest shortcut test.
    s.send(b'\x1b[20;3~')               # Alt-F9: minimize focused window
    check('window minimized', windows() == 1)

    s.send(b'\x1bw')                  # Alt-W: whole-window actions live here
    menu = s.text()
    check('window-wide actions listed',
          'Minimize all windows' in menu and 'Restore all windows' in menu)
    s.send(b'r')                      # mnemonic: Restore all
    check('all windows restored', windows() == 2)

    # Exercise both batch commands from Windows. Per-pane restore entries stay
    # in Panes, and prove that both windows reached the minimized state.
    s.send(b'\x1bw')
    s.send(b'a')                      # Minimize all windows
    s.send(b'\x1bp')
    menu = s.text()
    check('all windows minimized',
          'Restore 1' in menu and 'Restore 2' in menu)
    s.send(b'\x1b')
    s.send(b'\x1bw')
    s.send(b'r')                      # Restore all windows
    check('batch restore shows all windows', windows() == 2)
finally:
    try:
        s.send(b'\x1bx', 0.5)          # Alt-X: the single Exit path
    except OSError:
        pass
    stlib.close_all_daemons(HOME)
    s.close()

sys.exit(1 if fails else 0)
