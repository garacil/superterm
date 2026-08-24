#!/usr/bin/env python3
"""superterm test: /etc-style terminal definitions, scrollback, quit-no-save."""
import os, pty, time, select, sys, fcntl, termios, struct, subprocess, re
import pyte

sys.path.insert(0, os.path.dirname(__file__))
from stlib import close_all_daemons

BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'bin', 'superterm'))
HOME = '/tmp/opencode/st-sysconfig'
os.makedirs(HOME, exist_ok=True)
SESS = HOME + '/.superterm/session.ini'
SYSINI = HOME + '/sys_test.ini'
W, H = 110, 35

# This legacy test deliberately reuses one fixed HOME for four launches. An
# interrupted earlier run, or the previous phase's daemon still completing
# shutdown, must not turn the next launch into the live-session picker.
close_all_daemons(HOME)

class Session:
    def __init__(self, sysini=SYSINI):
        self.screen = pyte.Screen(W, H)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ['TERM'] = 'xterm'
            os.environ['SHELL'] = '/bin/bash'
            os.environ['HOME'] = HOME
            os.environ['SUPERTERM_INI'] = sysini
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
        return "\n".join(r.rstrip() for r in self.screen.display)
    def close(self):
        try: os.close(self.fd)
        except OSError: pass
        try: os.waitpid(self.pid, 0)
        except ChildProcessError: pass

fails = []
def check(name, cond):
    print(f"{name:30}: {'OK' if cond else 'FAIL'}")
    if not cond:
        fails.append(name)

def pgrep(pat):
    return subprocess.run(['pgrep', '-f', pat], capture_output=True, text=True).stdout.strip()

# ---- part 1: terminals defined in sysini ----
with open(SYSINI, 'w') as f:
    f.write("""[t1]
name=uno
enabled=1
type=local
cmd=sleep 321
scrollback=10000

[t2]
name=dos
enabled=1
type=local
cmd=sleep 555

[t3]
name=apagado
enabled=0
type=local
cmd=sleep 777
""")
if os.path.exists(SESS):
    os.remove(SESS)

s = Session()
s.drain(2.5)
scr = s.text()
check("menu Terminals visible", "Classes" in scr)
check("titulo pane uno", "uno" in scr)
check("titulo pane dos", "dos" in scr)
check("t1 arrancado", pgrep('sleep 321') != '')
check("t2 arrancado", pgrep('sleep 555') != '')
time.sleep(0.3)
check("t3 disabled no arranca", pgrep('sleep 777') == '')

# exit WITHOUT saving: Alt-Q
s.send(b'\x1bq', 1.0)
s.close()
time.sleep(0.4)
check("Alt-Q no guarda sesion", not os.path.exists(SESS))
close_all_daemons(HOME)

# ---- part 2: scrollback with a single terminal ----
with open(SYSINI, 'w') as f:
    f.write("""[t1]
name=solo
enabled=1
type=local
cmd=
scrollback=10000
""")
if os.path.exists(SESS):
    os.remove(SESS)

s = Session()
s.drain(2.5)
s.send(b'seq 1 200\r', 2.0)
scr = s.text()
check("live: ultimos numeros", re.search(r'\b19[0-9]\b', scr) is not None)
check("live: primeros no visibles", re.search(r'\b1[0-4][0-9]\b', scr) is None)

# Alt-PgUp (ESC + PgUp) = scroll back one page
s.send(b'\x1b\x1b[5~', 1.0)
scr = s.text()
check("scrolled: muestra historial", re.search(r'\b1[0-4][0-9]\b', scr) is not None)

# Alt-PgDn = back to the present
s.send(b'\x1b\x1b[6~', 1.0)
scr = s.text()
check("scroll fwd: de nuevo vivo", re.search(r'\b19[0-9]\b', scr) is not None)

# Alt-Home / Alt-End (sequences the RTL translates to kbAltHome/kbAltEnd)
s.send(b'\x1b\x1b[1~', 0.8)
scr = s.text()
check("alt-home: top historial", re.search(r'\b[1-9]\b', scr) is not None and re.search(r'\b19[0-9]\b', scr) is None)
s.send(b'\x1b\x1b[4~', 0.8)
scr = s.text()
check("alt-end: bottom", re.search(r'\b19[0-9]\b', scr) is not None)

s.send(b'\x1bq', 0.8)   # without saving
s.close()
time.sleep(0.3)
check("sin sesion tras Alt-Q", not os.path.exists(SESS))
close_all_daemons(HOME)

# ---- part 3: saving with Alt-X restores the defined terminal ----
s = Session()
s.drain(2.0)
s.send(b'\x1bx', 1.0)   # exit saving
s.close()
deadline = time.time() + 3.0
while time.time() < deadline and not os.path.exists(SESS):
    time.sleep(0.1)
check("Alt-X guarda sesion", os.path.exists(SESS))
if os.path.exists(SESS):
    txt = open(SESS).read()
    check("session referencia term=solo", 'term=solo' in txt)
close_all_daemons(HOME)

s = Session()
s.drain(2.5)
scr = s.text()
check("restaura terminal por nombre", "solo" in scr)
s.send(b'\x1bq', 0.8)
s.close()
close_all_daemons(HOME)

sys.exit(1 if fails else 0)
