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
          'F5 Full screen' in s.text() and 'F8 Window' in s.text())

    s.send(b'\x1bOQ')                  # F2: vertical split
    s.send(b'echo WINDOW_TWO_VISIBLE\r')
    check('split window created', 'WINDOW_TWO_VISIBLE' in s.text())

    # F5 maximize: a full-screen pane now enters passthrough (its raw bytes
    # own the terminal), so superterm's chrome disappears
    s.send(b'\x1b[15~', 1.3)           # F5: maximize -> passthrough
    check('maximize enters passthrough', 'Detach' not in s.text())

    # F5 again un-maximizes and reclaims the screen for the window manager
    s.send(b'\x1b[15~', 1.3)           # F5: restore -> back to windows
    check('restore leaves passthrough',
          'Detach' in s.text() and '┌' in s.screen.display[1])

    # fresh marker: the passthrough resize cycle made bash reprint, so the
    # first marker scrolled off; this also proves the pane survived it
    s.send(b'echo WINDOW_TWO_AGAIN\r')
    check('pane alive after passthrough', 'WINDOW_TWO_AGAIN' in s.text())

    # count window frames by top-left corners (active '╔' + inactive '┌'):
    # the resize churn scrolls echo markers away, so verify structurally
    def windows():
        t = s.text()
        return t.count('┌') + t.count('╔')

    check('two windows before minimize', windows() == 2)
    s.send(b'\x1b\x1b[20~')            # Alt-F9: minimize focused window
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
        s.send(b'\x1bq', 0.5)          # Alt-Q: quit without saving
    except OSError:
        pass
    s.close()

sys.exit(1 if fails else 0)
