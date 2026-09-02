#!/usr/bin/env python3
"""superterm test: editable, persistent per-window titles.

Covers the class default title, renaming a window (Panes -> Rename title...),
that a custom title is not overwritten by the periodic cwd-based refresh, and
that it survives an autosave/autorestore round trip.
"""
import os, pty, time, select, fcntl, termios, struct, shutil, sys

BIN = os.environ.get('SUPERTERM_TEST_BIN', os.path.abspath(os.path.join(
    os.path.dirname(__file__), '..', 'bin', 'superterm')))
HOME = '/tmp/opencode/sttitle-test'
W, H = 100, 28

sys.path.insert(0, os.path.dirname(__file__))
import pyte
import stlib

fails = []
def check(name, cond):
    print(f"{name:34}: {'OK' if cond else 'FAIL'}")
    if not cond:
        fails.append(name)

def reset(ini):
    shutil.rmtree(HOME, ignore_errors=True)
    os.makedirs(HOME + '/.superterm', exist_ok=True)
    open(HOME + '/.superterm/superterm.ini', 'w').write(ini)

def launch():
    sc = pyte.Screen(W, H)
    st = pyte.ByteStream(sc)
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(TERM='xterm', SHELL='/bin/bash', HOME=HOME,
                          SUPERTERM_INI=HOME + '/no.ini')
        os.execv(BIN, [BIN])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', H, W, 0, 0))
    return sc, st, pid, fd

def drain(sc, st, fd, t):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                d = os.read(fd, 65536)
            except OSError:
                return
            if not d:
                return
            stlib.feed_pyte(st, d, 'title')

def text(sc):
    return "\n".join("".join(sc.buffer[y][x].data for x in range(W))
                     for y in range(H))

# ---- 1: rename, no-overwrite, persistence ----
reset('[ui]\nlanguage=en\n[session]\nserver=detach\n'
      'autosave=1\nautorestore=1\n')
sc, st, pid, fd = launch()
drain(sc, st, fd, 2.0)
os.write(fd, b'\x1bp'); drain(sc, st, fd, 0.6)   # Panes menu
os.write(fd, b'i'); drain(sc, st, fd, 0.7)        # Rename title (accel i)
check('rename dialog opens',
      'Window title' in text(sc) or 'Rename window' in text(sc))
for _ in range(30):
    os.write(fd, b'\x08'); time.sleep(0.005)
os.write(fd, b'MY-TITLE\r'); drain(sc, st, fd, 0.8)
check('title set to custom', 'MY-TITLE' in text(sc))
os.write(fd, b'cd /etc\r'); drain(sc, st, fd, 2.2)  # would refresh title from cwd
check('custom title not overwritten by cwd', 'MY-TITLE' in text(sc))
os.write(fd, b'\x1bx'); drain(sc, st, fd, 1.5)      # local Exit autosaves
time.sleep(0.4)
try:
    os.close(fd)
except OSError:
    pass
sc, st, pid, fd = launch()
drain(sc, st, fd, 2.5)
check('custom title restored after save', 'MY-TITLE' in text(sc))
os.write(fd, b'\x1bx'); drain(sc, st, fd, 0.8)
try:
    os.close(fd)
except OSError:
    pass

# ---- 2: class default title ----
reset('''[ui]
language=en
[session]
default_profile=dummy
server=detach
[class.mybox]
name=mybox
enabled=1
title=Production DB
cmd=
[profile.dummy]
name=dummy
enabled=1
windows=w
[profile.dummy.window.w]
layout=L
panes=p
[profile.dummy.window.w.pane.p]
cmd=
''')
sc, st, pid, fd = launch()
drain(sc, st, fd, 2.0)
os.write(fd, b'\x1bc'); drain(sc, st, fd, 0.5)   # Classes menu
os.write(fd, b'2'); drain(sc, st, fd, 0.9)        # open class mybox
check('class default title on window', 'Production DB' in text(sc))
os.write(fd, b'\x1bx'); drain(sc, st, fd, 0.8)
try:
    os.close(fd)
except OSError:
    pass

shutil.rmtree(HOME, ignore_errors=True)
print()
if fails:
    print(f"RESULT: FAIL ({len(fails)}): {', '.join(fails)}")
    sys.exit(1)
print("RESULT: PASS")
