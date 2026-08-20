#!/usr/bin/env python3
"""superterm test: detach keeps live PTYs and reattach restores their screen."""
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
HOME = '/tmp/opencode/stdetach-test'
SOCKET = os.path.join(HOME, '.superterm', 'sessions', 'session.sock')
META = os.path.join(HOME, '.superterm', 'sessions', 'session.ini')
PIDFILE = os.path.join(HOME, 'pane.pid')
W, H = 110, 35

os.makedirs(os.path.join(HOME, '.superterm'), exist_ok=True)
for path in (SOCKET, META, PIDFILE):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


class Client:
    def __init__(self, args=()):
        self.screen = pyte.Screen(W, H)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update({
                'TERM': 'xterm',
                'SHELL': '/bin/bash',
                'HOME': HOME,
                'SUPERTERM_INI': os.path.join(HOME, 'none.ini'),
            })
            os.execv(BIN, [BIN, *args])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', H, W, 0, 0))

    def drain(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            readable, _, _ = select.select([self.fd], [], [], 0.05)
            if not readable:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return
            if not data:
                return
            if b'\033[6n' in data:
                os.write(self.fd, b'\033[10;20R')
            try:
                self.stream.feed(data)
            except Exception:
                pass

    def send(self, data, seconds=0.8):
        os.write(self.fd, data)
        self.drain(seconds)

    def text(self):
        return '\n'.join(row.rstrip() for row in self.screen.display)

    def wait(self, timeout=5.0):
        end = time.time() + timeout
        while time.time() < end:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return status
            self.drain(0.05)
        return None


fails = []


def check(name, condition):
    print(f'{name:30}: ' + ('OK' if condition else 'FAIL'))
    if not condition:
        fails.append(name)


first = Client()
first.stream.feed(b'\033[10;20H')
first.drain(1.5)
check('detach menu is visible', 'Detach' in first.text())
first.send(f'echo $$ > {PIDFILE}; sleep 1; echo DETACHED_OUTPUT\r'.encode(), 0.3)
first.send(b'\x11d', 0.8)
first.send(b'\r', 1.0)   # aceptar el nombre por defecto ('session')
first_status = first.wait()
check('client exits after Ctrl-Q d', first_status is not None and
      os.WIFEXITED(first_status) and os.WEXITSTATUS(first_status) == 0)
check('cursor restored after detach',
      first.screen.cursor.x == 19 and first.screen.cursor.y == 9)
check('server socket remains', os.path.exists(SOCKET))
check('session sidecar written', os.path.exists(META))

pane_pid = None
for _ in range(30):
    try:
        pane_pid = int(open(PIDFILE).read().strip())
        break
    except (FileNotFoundError, ValueError):
        time.sleep(0.1)
check('pane process survives detach', pane_pid is not None and
      os.path.exists(f'/proc/{pane_pid}'))
time.sleep(1.0)

second = Client(['--attach'])
second.drain(2.0)
check('reattach shows detached output', 'DETACHED_OUTPUT' in second.text())
second.send(b'echo ATTACHED_OK\r', 1.0)
check('reattached pane accepts input', 'ATTACHED_OK' in second.text())
second.send(b'\x1bx', 1.0)
second_status = second.wait()
check('permanent close exits client', second_status is not None and
      os.WIFEXITED(second_status) and os.WEXITSTATUS(second_status) == 0)
check('server socket is removed', not os.path.exists(SOCKET))
check('session sidecar removed', not os.path.exists(META))

if pane_pid is not None:
    try:
        os.kill(pane_pid, 0)
        pane_alive = True
    except ProcessLookupError:
        pane_alive = False
    except PermissionError:
        pane_alive = True
    check('permanent close terminates pane', not pane_alive)

exit_client = Client()
exit_client.stream.feed(b'\033[10;20H')
exit_client.drain(1.5)
exit_client.send(b'\x1bx', 1.0)
exit_status = exit_client.wait()
check('cursor restored after exit',
      exit_status is not None and exit_client.screen.cursor.x == 19 and
      exit_client.screen.cursor.y == 9)
try:
    os.close(exit_client.fd)
except OSError:
    pass

sys.exit(1 if fails else 0)
