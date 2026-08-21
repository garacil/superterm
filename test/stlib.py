#!/usr/bin/env python3
"""stlib: shared test fixture for the superterm suite.

Provides:
- Client: a pyte+PTY superterm instance with DSR auto-answer and wait_until.
- fresh_home(name): a unique, wiped HOME per test file.
- close_all_daemons(home): teardown that terminates every session daemon
  created under a HOME (FRAME_CLOSE, then SIGKILL by sidecar pid). Registered
  atexit by fresh_home; a leftover daemon is reported as a failure.
- raw_frame/read_frame: the daemon wire protocol (8-byte header + payload).
- run_cli(*args): run the superterm binary without a PTY (CLI commands).
"""
import atexit
import configparser
import fcntl
import glob
import os
import pty
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import termios
import time

sys.path.insert(0, os.path.dirname(__file__))
import pyte  # noqa: E402

BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), '..',
                                   'bin', 'superterm'))

_fails = []
_registered_homes = []


def check(name, cond, width=36):
    print(f"{name:{width}}: {'OK' if cond else 'FAIL'}")
    if not cond:
        _fails.append(name)


def fails():
    return _fails


def report():
    """Final verdict; also fails if any daemon outlived the test."""
    leftovers = []
    for home in _registered_homes:
        leftovers += _live_daemons(home)
    if leftovers:
        check('no leftover daemons', False)
        for pid, name in leftovers:
            print(f"  leftover daemon pid={pid} session={name}")
        for home in _registered_homes:
            close_all_daemons(home)
    print()
    if _fails:
        print(f"RESULT: FAIL ({len(_fails)}): {', '.join(_fails)}")
        sys.exit(1)
    print('RESULT: PASS')
    sys.exit(0)


def fresh_home(testname):
    """Unique wiped HOME for this test; daemons cleaned up at exit."""
    home = '/tmp/opencode/st-' + testname
    shutil.rmtree(home, ignore_errors=True)
    os.makedirs(home + '/.superterm', exist_ok=True)
    if home not in _registered_homes:
        _registered_homes.append(home)
        atexit.register(close_all_daemons, home)
    return home


# ---------------------------------------------------------------- protocol

FRAME_ATTACH = 1
FRAME_INPUT = 2
FRAME_RESIZE = 3
FRAME_DETACH = 4
FRAME_CLOSE = 5


def raw_frame(kind, pane, payload=b''):
    """8-byte packed header (Kind, Reserved, Pane:int16, Size:uint32)."""
    return struct.pack('<BBhI', kind, 0, pane, len(payload)) + payload


def read_frame(sock, timeout=5.0):
    """Read one frame; returns (kind, pane, payload) or None on EOF."""
    sock.settimeout(timeout)
    hdr = b''
    while len(hdr) < 8:
        chunk = sock.recv(8 - len(hdr))
        if not chunk:
            return None
        hdr += chunk
    kind, _res, pane, size = struct.unpack('<BBhI', hdr)
    data = b''
    while len(data) < size:
        chunk = sock.recv(min(65536, size - len(data)))
        if not chunk:
            return None
        data += chunk
    return kind, pane, data


def pas_string(s):
    """Serialize a Pascal WriteString: int32 length + bytes."""
    b = s.encode('utf-8') if isinstance(s, str) else s
    return struct.pack('<i', len(b)) + b


def read_pas_string(buf, ofs):
    """Read a WriteString from a bytes buffer; returns (value, new_ofs)."""
    (ln,) = struct.unpack_from('<i', buf, ofs)
    ofs += 4
    val = buf[ofs:ofs + ln].decode('utf-8', 'replace')
    return val, ofs + ln


def sessions_dir(home):
    return home + '/.superterm/sessions'


def session_sockets(home):
    return sorted(glob.glob(sessions_dir(home) + '/*.sock'))


def _sidecar_pids(home):
    out = []
    for ini in glob.glob(sessions_dir(home) + '/*.ini'):
        cp = configparser.ConfigParser()
        try:
            cp.read(ini)
            pid = cp.getint('session', 'pid', fallback=0)
            name = cp.get('session', 'name', fallback='?')
            if pid > 0:
                out.append((pid, name))
        except Exception:
            pass
    return out


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _live_daemons(home):
    return [(pid, name) for pid, name in _sidecar_pids(home) if _alive(pid)]


def close_all_daemons(home):
    """Ask every session daemon under home to close; escalate to SIGKILL."""
    for sock_path in session_sockets(home):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(1.0)
            s.connect(sock_path)
            s.sendall(raw_frame(FRAME_CLOSE, -1))
            s.close()
        except OSError:
            pass
    deadline = time.time() + 2.0
    while time.time() < deadline and _live_daemons(home):
        time.sleep(0.1)
    for pid, _name in _live_daemons(home):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    shutil.rmtree(sessions_dir(home), ignore_errors=True)


# ---------------------------------------------------------------- processes

def run_cli(args, home, env=None, stdin=None, timeout=30):
    """Run superterm without a PTY (CLI commands); returns CompletedProcess."""
    e = dict(os.environ, HOME=home, TERM='xterm',
             SUPERTERM_INI=home + '/no-sys.ini')
    if env:
        e.update(env)
    return subprocess.run([BIN] + list(args), capture_output=True, text=True,
                          env=e, input=stdin, timeout=timeout)


class Client:
    """A pyte-rendered interactive superterm on a PTY."""

    def __init__(self, home, args=None, w=110, h=32, env=None, lang=None,
                 dsr_row=5, dsr_col=1):
        self.w, self.h = w, h
        self.home = home
        self.screen = pyte.Screen(w, h)
        self.stream = pyte.ByteStream(self.screen)
        self.dsr = (dsr_row, dsr_col)
        if lang is not None:
            ini = home + '/.superterm/superterm.ini'
            os.makedirs(os.path.dirname(ini), exist_ok=True)
            if not os.path.exists(ini):
                with open(ini, 'w') as f:
                    f.write(f'[ui]\nlanguage={lang}\n')
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            e = dict(TERM='xterm', SHELL='/bin/bash', HOME=home,
                     SUPERTERM_INI=home + '/no-sys.ini', LANG='C.UTF-8')
            if env:
                e.update(env)
            os.environ.update(e)
            os.execv(BIN, [BIN] + (args or []))
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', h, w, 0, 0))
        self._raw = b''

    def drain(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    d = os.read(self.fd, 65536)
                    if not d:
                        return
                except OSError:
                    return
                self._raw += d
                if b'\x1b[6n' in d:
                    row, col = self.dsr
                    try:
                        os.write(self.fd, f'\x1b[{row};{col}R'.encode())
                    except OSError:
                        pass
                try:
                    self.stream.feed(d)
                except Exception:
                    pass

    def send(self, data, seconds=0.8):
        try:
            os.write(self.fd, data)
        except OSError:
            pass   # the client already exited (e.g. after an immediate detach)
        self.drain(seconds)

    def text(self):
        return '\n'.join(row.rstrip() for row in self.screen.display)

    def raw(self):
        return self._raw

    def wait_until(self, pred, timeout=12.0):
        end = time.time() + timeout
        while time.time() < end:
            self.drain(0.2)
            if pred(self.text()):
                return True
        return pred(self.text())

    def wait_exit(self, timeout=5.0):
        """Wait for the child to exit; returns exit status or None."""
        end = time.time() + timeout
        while time.time() < end:
            try:
                pid, st = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                return 0
            if pid:
                return st
            self.drain(0.1)
        return None

    def alive(self):
        try:
            return os.waitpid(self.pid, os.WNOHANG) == (0, 0)
        except ChildProcessError:
            return False

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            pass
