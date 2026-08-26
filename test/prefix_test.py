#!/usr/bin/env python3
"""superterm test: configurable prefix key and migration.

Covers ParsePrefixKey end to end: the default is Ctrl-Q (0x11), the old
numeric prefix=2 migrates to Ctrl-Q, an explicit textual ctrl-b is
honored, and the detach session name is sanitized ([A-Za-z0-9._-]).
"""
import os, pty, time, select, fcntl, termios, struct, shutil, glob, sys

BIN = os.environ.get('SUPERTERM_TEST_BIN', os.path.abspath(os.path.join(
    os.path.dirname(__file__), '..', 'bin', 'superterm')))
HOME = '/tmp/opencode/sthome-prefix'
W, H = 100, 30

sys.path.insert(0, os.path.dirname(__file__))
import socket as _socket
import pyte

fails = []
def check(name, cond):
    print(f"{name:34}: {'OK' if cond else 'FAIL'}")
    if not cond:
        fails.append(name)

def reset_home():
    shutil.rmtree(HOME, ignore_errors=True)
    os.makedirs(HOME + '/.superterm', exist_ok=True)

def write_ini(prefix_line):
    with open(HOME + '/.superterm/superterm.ini', 'w') as f:
        f.write('[keymap]\n' + prefix_line + '\n')

class Client:
    def __init__(self, args=None):
        self.screen = pyte.Screen(W, H)
        self.stream = pyte.ByteStream(self.screen)
        pid, fd = pty.fork()
        if pid == 0:
            os.environ.update(TERM='xterm', SHELL='/bin/bash', HOME=HOME,
                              SUPERTERM_INI=HOME + '/no-sys.ini')
            os.execv(BIN, [BIN] + (args or []))
        self.pid, self.fd = pid, fd
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', H, W, 0, 0))

    def drain(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    data = os.read(self.fd, 65536)
                    if not data:
                        return
                    self.stream.feed(data)
                except OSError:
                    return
                except Exception:
                    pass

    def send(self, data, seconds=0.6):
        os.write(self.fd, data)
        self.drain(seconds)

    def text(self):
        return "\n".join(row.rstrip() for row in self.screen.display)

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass
        time.sleep(0.3)

def client_exited(c, timeout=3.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            pid, _st = os.waitpid(c.pid, os.WNOHANG)
        except ChildProcessError:
            return True
        if pid:
            return True
        c.drain(0.1)
    return False

def detach_works(prefix_byte):
    """Starts, sends prefix+d and returns whether the client detached (exited
    leaving the socket alive); with always-server there is no name dialog."""
    c = Client()
    c.drain(2.0)
    try:
        os.write(c.fd, prefix_byte)
    except OSError:
        pass
    c.drain(0.4)
    try:
        os.write(c.fd, b'd')
    except OSError:
        pass
    ok = client_exited(c) and bool(
        glob.glob(HOME + '/.superterm/sessions/*.sock'))
    if not ok:
        c.send(b'\x1bx', 0.8)     # it was not a prefix: use the one Exit key
    c.close()
    # clean up the session left alive for the next round
    for sock in glob.glob(HOME + '/.superterm/sessions/*.sock'):
        try:
            s = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
            s.settimeout(1.0)
            s.connect(sock)
            s.sendall(struct.pack('<BBhI', 5, 0, -1, 0))
            s.close()
        except OSError:
            pass
    time.sleep(0.4)
    return ok

# ---- 1: default with no ini = Ctrl-Q ----
reset_home()
check("default Ctrl-Q separa", detach_works(b'\x11'))

# ---- 2: old numeric prefix=2 migrates to Ctrl-Q ----
reset_home()
write_ini('prefix=2')
check("prefix=2 migra a Ctrl-Q", detach_works(b'\x11'))

# ---- 3: explicit textual ctrl-b is honored ----
reset_home()
write_ini('prefix=ctrl-b')
check("prefix=ctrl-b respeta Ctrl-B", detach_works(b'\x02'))

# ---- 4: with explicit ctrl-b, Ctrl-Q is NOT a prefix ----
reset_home()
write_ini('prefix=ctrl-b')
check("ctrl-b: Ctrl-Q no es prefijo", not detach_works(b'\x11'))

# ---- 5: prefix-s opens the session picker ----
reset_home()
c = Client()
c.drain(2.0)
c.send(b'\x11', 0.4)
c.send(b's', 1.0)
t = c.text()
check("prefijo-s abre selector", 'Attach' in t or 'Conectar' in t or 'Sessions' in t or 'Sesiones' in t)
c.send(b'\x1b', 0.6)
c.send(b'\x1bx', 0.8)
c.close()

# ---- 6: the session name is sanitized (no ../ nor spaces) ----
reset_home()
c = Client(['--session', '../evil name!'])
c.drain(2.5)
c.close()
time.sleep(0.5)
socks = [os.path.basename(p) for p in glob.glob(HOME + '/.superterm/sessions/*.sock')]
inside = glob.glob(HOME + '/.superterm/*.sock') + glob.glob('/tmp/opencode/*.sock')
ok_name = len(socks) == 1 and all(ch.isalnum() or ch in '._-' for ch in socks[0][:-5])
check("nombre saneado dentro del dir", ok_name and '..' not in socks[0])
check("sin sockets fuera del dir", not inside)

# cleanup: close the daemon left alive
for sock in glob.glob(HOME + '/.superterm/sessions/*.sock'):
    try:
        s = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(sock)
        s.sendall(struct.pack('<BBhI', 5, 0, -1, 0))
        s.close()
    except OSError:
        pass
time.sleep(0.4)
shutil.rmtree(HOME, ignore_errors=True)

print()
if fails:
    print(f"RESULT: FAIL ({len(fails)}): {', '.join(fails)}")
    sys.exit(1)
print("RESULT: PASS")
