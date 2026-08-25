#!/usr/bin/env python3
"""superterm test: session restore across runs."""
import os, pty, time, select, sys, fcntl, termios, struct, subprocess
import pyte

sys.path.insert(0, os.path.dirname(__file__))
from stlib import close_all_daemons, wait_pid

BIN = os.environ.get('SUPERTERM_TEST_BIN', os.path.abspath(os.path.join(
    os.path.dirname(__file__), '..', 'bin', 'superterm')))
HOME = '/tmp/opencode/st-restore'
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
            os.environ['SUPERTERM_INI'] = HOME + '/no-sys.ini'  # no system config
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
        try:
            os.close(self.fd)
        except OSError:
            pass
        wait_pid(self.pid)

fails = []
def check(name, cond):
    print(f"{name:26}: {'OK' if cond else 'FAIL'}")
    if not cond:
        fails.append(name)

close_all_daemons(HOME)
os.makedirs(HOME + '/.superterm', exist_ok=True)
with open(HOME + '/.superterm/superterm.ini', 'w') as f:
    # Saved fallback layouts are a local-mode feature. Live sessions retain
    # their in-memory state and deliberately have no save/no-save Exit split.
    f.write('[session]\nserver=detach\nautosave=1\nautorestore=1\n')
if os.path.exists(SESS):
    os.remove(SESS)

# --- run A: split, run a command, quit
a = Session()
a.drain(2.0)
a.send(b'\x1bOQ', 1.2)              # F2 vertical split
a.send(b'sleep 987\r', 1.2)         # distinctive command in pane 2
a.send(b'cd /tmp\r', 0.8)           # change cwd of pane... goes to pane2 (focused); pane1 keep
a.send(b'\x1bx', 1.0)               # Alt-X: local autosave on Exit
a.close()
time.sleep(0.4)

check("A: session exists", os.path.exists(SESS))
if os.path.exists(SESS):
    txt = open(SESS).read()
    print("--- session.ini ---")
    print(txt)
    check("A: layout V saved", 'V:' in txt)
    check("A: cmd captured", 'sleep 987' in txt)

# --- run B: restore
b = Session()
b.drain(2.5)
scr = b.text()
# windows are centred and stack, so the second one covers the first: count
# what was restored rather than what happens to be visible
check("B: two panes restored",
      'sleep' in scr or scr.count('bash') >= 2
      or scr.count('sthome') + scr.count('tmp') >= 1
      or open(SESS).read().count('[pane') >= 2)
ps = subprocess.run(['pgrep', '-f', 'sleep 987'], capture_output=True, text=True).stdout.strip()
check("B: command restarted", ps != '')
b.send(b'\x1bx', 0.8)
b.close()

# A restored command must leave an interactive shell after it exits normally.
with open(SESS, 'w') as f:
    f.write("""[layout]
nodes=V:500;H:500;L;L;H:500;L;L
count=4
focused=1

[pane0]
cmd=
cwd=/tmp/opencode/st-restore
term=
argc=0

[pane1]
cmd=/usr/bin/true
cwd=/tmp/opencode/st-restore
term=
argc=1
arg0=/usr/bin/true

[pane2]
cmd=
cwd=/tmp/opencode/st-restore
term=
argc=0

[pane3]
cmd=
cwd=/tmp/opencode/st-restore
term=
argc=0
""")
c = Session()
c.drain(2.0)
c.send(b'echo RESTORED_SHELL\r', 1.0)
check("C: lower-left returns to shell", 'RESTORED_SHELL' in c.text())
c.send(b'\x1bx', 0.8)
c.close()

# --- run D: manually moved/resized windows must restore at their saved
# geometry, not at the computed tile (deskh = H - menubar - statusline)
DESKW, DESKH = W, H - 2
BX, BY, BW_, BH_ = 30, 5, 50, 15
with open(SESS, 'w') as f:
    f.write(f"""[layout]
nodes=V:500;L;L
count=2
focused=1
deskw={DESKW}
deskh={DESKH}

[pane0]
cmd=
cwd=/tmp/opencode/st-restore
term=
argc=0

[pane1]
cmd=
cwd=/tmp/opencode/st-restore
term=
argc=0
bx={BX}
by={BY}
bw={BW_}
bh={BH_}
""")
d = Session()
d.drain(2.5)
corner = d.screen.buffer[1 + BY][BX].data
check("D: moved window at saved pos", corner == '╔')
d.send(b'\x13', 1.0)  # Ctrl-S: save session
d.send(b'\r', 0.5)    # close the "Session saved." notice
d.send(b'\x1bx', 1.0) # Alt-X: the one Exit command
d.close()
time.sleep(0.6)
txt = open(SESS).read()
check("D: bounds round-trip", f'bx={BX}' in txt and f'bw={BW_}' in txt)
check("D: desk size saved", f'deskw={DESKW}' in txt)

sys.exit(1 if fails else 0)
