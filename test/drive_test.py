#!/usr/bin/env python3
"""superterm FV test v2: render output with pyte and check the actual screen."""
import os, pty, time, select, sys, fcntl, termios, struct
import pyte

BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'bin', 'superterm'))
HOME = '/tmp/opencode/sthome'
os.makedirs(HOME, exist_ok=True)
SESS = HOME + '/.superterm/session.ini'

W, H = 110, 35

class Session:
    def __init__(self):
        self.screen = pyte.Screen(W, H)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ['TERM'] = 'xterm'
            os.environ['SHELL'] = '/bin/bash'
            os.environ['HOME'] = HOME
            os.environ['SUPERTERM_INI'] = HOME + '/no-sys.ini'  # sin config de sistema
            os.execv(BIN, [BIN])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', H, W, 0, 0))

    def drain(self, t):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    d = os.read(self.fd, 65536)
                except OSError:
                    return
                try:
                    self.stream.feed(d)
                except Exception:
                    pass

    def send(self, s, t=1.0):
        os.write(self.fd, s)
        self.drain(t)

    def text(self):
        return "\n".join(row.rstrip() for row in self.screen.display)

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
def check(name, cond):
    print(f"{name:24}: {'OK' if cond else 'FAIL'}")
    if not cond:
        fails.append(name)

if os.path.exists(SESS):
    os.remove(SESS)

s = Session()
s.drain(2.0)
scr = s.text()
check("menubar Panels", "Panes" in scr)
check("statusline F2", "F2 Split" in scr)
check("window frame 1 shell", scr.count("╔") >= 1)
check("OSC prompt hidden", "3008;start=" not in scr)

s.send(b"echo ST_A=1\r", 1.0)
s.send(b"echo ST_B=2\r", 1.0)
scr = s.text()
check("cmd output visible", "ST_A=1" in scr and "ST_B=2" in scr)

# split vertical: F2 (xterm: ESC OQ)
s.send(b'\x1bOQ', 1.0)
scr = s.text()
check("after split: 2 windows", scr.count("╔") + scr.count("┌") >= 2)

# type in new pane
s.send(b"echo ST_SPLIT_OK\r", 1.0)
scr = s.text()
check("second pane interactive", "ST_SPLIT_OK" in scr)

# close pane: menu via Alt-P then C: Panels -> Close
s.send(b'\x1bp', 0.4)
s.send(b'c', 1.0)
scr = s.text()
check("pane closed", "ST_SPLIT_OK" not in scr)

# quit saving
s.send(b'\x1bx', 0.8)
s.drain(0.5)
s.close()
time.sleep(0.3)
check("session saved", os.path.exists(SESS))
if os.path.exists(SESS):
    print("--- session.ini ---")
    print(open(SESS).read()[:400])

sys.exit(1 if fails else 0)
