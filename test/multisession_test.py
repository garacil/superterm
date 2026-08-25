#!/usr/bin/env python3
"""superterm test: named detached sessions, picker, --attach and --list-sessions."""
import os, pty, time, select, sys, fcntl, termios, struct, subprocess
import pyte

sys.path.insert(0, os.path.dirname(__file__))
import stlib  # noqa: E402

BIN = os.environ.get('SUPERTERM_TEST_BIN', os.path.abspath(os.path.join(
    os.path.dirname(__file__), '..', 'bin', 'superterm')))
HOME = stlib.fresh_home('multisession')
SYSINI = HOME + '/no.ini'
SESSDIR = HOME + '/.superterm/sessions'
W, H = 110, 35

def spath(name):
    return os.path.join(SESSDIR, name + '.sock')

def mpath(name):
    return os.path.join(SESSDIR, name + '.ini')

def wait_gone(path, timeout=3.0):
    end = time.time() + timeout
    while time.time() < end:
        if not os.path.exists(path):
            return True
        time.sleep(0.1)
    return not os.path.exists(path)

class Client:
    def __init__(self, args=()):
        self.screen = pyte.Screen(W, H)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ['TERM'] = 'xterm'
            os.environ['SHELL'] = '/bin/bash'
            os.environ['HOME'] = HOME
            os.environ['SUPERTERM_INI'] = SYSINI
            os.execv(BIN, [BIN, *args])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', H, W, 0, 0))
    def drain(self, t):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if not r:
                continue
            try:
                d = os.read(self.fd, 65536)
            except OSError:
                return
            if not d:
                return
            if b'\033[6n' in d:
                os.write(self.fd, b'\033[10;20R')
            try:
                self.stream.feed(d)
            except Exception:
                pass
    def send(self, s, t=1.0):
        os.write(self.fd, s)
        self.drain(t)
    def text(self):
        return "\n".join(r.rstrip() for r in self.screen.display)
    def wait(self, timeout=5.0):
        end = time.time() + timeout
        while time.time() < end:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return status
            self.drain(0.05)
        return None
    def close(self):
        try: os.close(self.fd)
        except OSError: pass

def exited_ok(status):
    return status is not None and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0

def detach_now(c):
    # always-server: the session is named from startup already and
    # prefix + d detaches with no dialog at all
    c.send(b'\x11', 0.4)
    c.send(b'd', 0.8)
    return 'Session name:' not in c.text()

fails = []
def check(name, cond):
    print(f"{name:30}: {'OK' if cond else 'FAIL'}")
    if not cond:
        fails.append(name)

def run_cli(*args):
    # LANG=C: the assertions in this test check the English format
    env = dict(os.environ, HOME=HOME, SUPERTERM_INI=SYSINI, LANG='C')
    return subprocess.run([BIN, *args], capture_output=True, text=True, env=env)

# ---- 1: session A named at launch with --session alfa ----
a = Client(['--session', 'alfa'])
a.drain(1.5)
a.send(b'echo SESION_A_TOKEN\r', 0.8)
check("A token visible", "SESION_A_TOKEN" in a.text())
check("alfa live at launch", os.path.exists(spath('alfa')))
check("detach needs no prompt", detach_now(a))
check("A client exits", exited_ok(a.wait()))
a.close()
check("alfa socket exists", os.path.exists(spath('alfa')))
check("alfa sidecar exists", os.path.exists(mpath('alfa')))
check("alfa sidecar has name", 'name=alfa' in open(mpath('alfa')).read())

# ---- 2: normal startup with a live session -> picker; Esc continues normally ----
b = Client(['--session', 'beta'])
b.drain(1.5)
scr = b.text()
check("picker on startup", "Detached sessions" in scr)
check("picker lists alfa", "alfa" in scr)
b.send(b'\x1b', 0.5)                       # Esc: normal startup
# the picker area is only repainted with the next pane output
b.send(b'echo SESION_B_TOKEN\r', 1.2)
scr = b.text()
check("esc continues startup", "SESION_B_TOKEN" in scr)
check("picker dismissed", "Detached sessions" not in scr)
detach_now(b)
check("B client exits", exited_ok(b.wait()))
b.close()
check("two session pairs", all(os.path.exists(p) for p in
      (spath('alfa'), mpath('alfa'), spath('beta'), mpath('beta'))))

# ---- 3: --list-sessions with no pty ----
res = run_cli('--list-sessions')
check("list exit 0", res.returncode == 0)
check("list shows alfa+beta", ('alfa' in res.stdout) and ('beta' in res.stdout))
lines = [l for l in res.stdout.splitlines() if l.strip()]
check("list header columns", len(lines) >= 3 and all(
    col in lines[0] for col in ('NAME', 'PROFILE', 'PANES', 'CREATED'))
    and ('CLIENTS' in lines[0] or 'CLIENTES' in lines[0]))
rows = {l.split()[0]: l for l in lines[1:]}
check("list row panes numeric", all(
    any(tok.isdigit() for tok in rows[n].split()[1:]) for n in ('alfa', 'beta')
    if n in rows) and 'alfa' in rows and 'beta' in rows)

# ---- 4: --attach beta by name; re-detach without prompt ----
c = Client(['--attach', 'beta'])
c.drain(2.0)
check("attach beta shows token", "SESION_B_TOKEN" in c.text())
c.send(b'\x11', 0.4)
c.send(b'd', 0.8)                           # in RemoteMode detaches with no InputBox
check("remote detach no prompt", "Session name:" not in c.text())
check("detached client exits", exited_ok(c.wait()))
c.close()
check("both still live", os.path.exists(spath('alfa')) and os.path.exists(spath('beta')))

# ---- 5: connect to alfa from the picker and close it with Alt-X ----
d = Client()
d.drain(1.5)
lines = d.screen.display
alfa_row = next((i for i, l in enumerate(lines) if 'alfa' in l), -1)
beta_row = next((i for i, l in enumerate(lines) if 'beta' in l), -1)
check("picker lists both", alfa_row >= 0 and beta_row >= 0)
# initial focus already lands on the list (insertion order): direct Enter
if alfa_row > beta_row:
    d.send(b'\x1b[B', 0.3)                 # alfa is the second row
d.send(b'\r', 2.0)                         # Enter = Attach button (default)
scr = d.text()
check("picker attaches alfa", "SESION_A_TOKEN" in scr)
check("alfa not beta", "SESION_B_TOKEN" not in scr)
d.send(b'\x1bx', 1.0)                      # Alt-X: permanent close
check("close client exits", exited_ok(d.wait()))
d.close()
check("alfa socket removed", wait_gone(spath('alfa')))
check("alfa sidecar removed", wait_gone(mpath('alfa')))
check("beta pair remains", os.path.exists(spath('beta')) and os.path.exists(mpath('beta')))

# ---- 6: cleanup: close beta; the directory ends up with no sessions ----
e = Client(['--attach', 'beta'])
e.drain(1.5)
e.send(b'\x1bx', 1.0)
check("beta close exits", exited_ok(e.wait()))
e.close()
check("beta socket removed", wait_gone(spath('beta')))
check("beta sidecar removed", wait_gone(mpath('beta')))
leftover = [f for f in os.listdir(SESSDIR) if f.endswith(('.sock', '.ini'))]
check("sessions dir empty", leftover == [])

# ---- 7: purge of orphaned sockets in --list-sessions ----
open(spath('zombi'), 'w').close()
with open(mpath('zombi'), 'w') as f:
    f.write('[session]\nname=zombi\n')
# the purge spares recent sockets (<5s, bind->listen window): age it
_old = time.time() - 30
os.utime(spath('zombi'), (_old, _old))
res = run_cli('--list-sessions')
check("stale list exit 0", res.returncode == 0)
check("zombi not listed", 'zombi' not in res.stdout)
check("zombi purged", not os.path.exists(spath('zombi')) and not os.path.exists(mpath('zombi')))

sys.exit(1 if fails else 0)
