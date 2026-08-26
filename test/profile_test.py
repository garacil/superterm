#!/usr/bin/env python3
"""superterm test: [profile.*] profiles, flattened legacy templates and saving."""
import configparser
import os, pty, time, select, sys, fcntl, termios, struct, shutil, re, shlex
import pyte

from stlib import wait_pid

BIN = os.environ.get('SUPERTERM_TEST_BIN', os.path.abspath(os.path.join(
    os.path.dirname(__file__), '..', 'bin', 'superterm')))
HOME = '/tmp/opencode/sthome-profile'
USERINI = HOME + '/.superterm/superterm.ini'
SYSINI = HOME + '/system.ini'
W, H = 110, 35

# isolated environment: own HOME and own system INI, clean at start
shutil.rmtree(HOME, ignore_errors=True)
os.makedirs(HOME + '/.superterm', exist_ok=True)

# user INI: dev profile (2 panes), legacy template to absorb,
# and unrelated sections ([session], [class.*]) that must survive saving
with open(USERINI, 'w') as f:
    f.write("""[session]
default_profile=dev
server=detach
autosave=0
autorestore=0

[class.keepme]
name=keepme
enabled=0
cmd=echo KEEPME

[profile.dev]
name=dev
enabled=1
focused_window=0
windows=web

[profile.dev.window.web]
enabled=1
layout=V:500;L;L
focused_pane=0
panes=a,b

[profile.dev.window.web.pane.a]
enabled=1
cmd=echo PROF_PANE_A; exec /bin/bash -i

[profile.dev.window.web.pane.b]
enabled=1
cmd=echo PROF_PANE_B; exec /bin/bash -i

[template.oldtpl]
name=oldtpl
enabled=1
sessions=main

[template.oldtpl.session.main]
enabled=1
windows=w1

[template.oldtpl.session.main.window.w1]
enabled=1
layout=L
panes=p1

[template.oldtpl.session.main.window.w1.pane.p1]
enabled=1
cmd=echo OLDTPL_TOKEN; exec /bin/bash -i
""")

# system INI: single-session legacy template -> profile 'legacy1'
with open(SYSINI, 'w') as f:
    f.write("""[template.legacy1]
name=legacy1
enabled=1
sessions=main

[template.legacy1.session.main]
enabled=1
windows=main

[template.legacy1.session.main.window.main]
enabled=1
layout=L
panes=p1

[template.legacy1.session.main.window.main.pane.p1]
enabled=1
cmd=echo LEGACY_PROF_TOKEN; exec /bin/bash -i
""")

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
    def wait_until(self, pred, timeout=8.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.drain(0.2)
            if pred(self.screen.display):
                return True
        return pred(self.screen.display)
    def close(self):
        try: os.close(self.fd)
        except OSError: pass
        wait_pid(self.pid)

fails = []
def check(name, cond):
    print(f"{name:30}: {'OK' if cond else 'FAIL'}")
    if not cond:
        fails.append(name)

# ---- 1: default_profile=dev activates the hand-written profile at startup ----
s = Session()
s.drain(2.0)
scr = s.text()
check("dev pane a token", "PROF_PANE_A" in scr)
check("dev pane b token", "PROF_PANE_B" in scr)
check("dev two panes", scr.count("╔") + scr.count("┌") >= 2)

# Windows menu (Alt-W) lists the windows of the active profile
s.send(b'\x1bw', 0.5)
scr = s.text()
check("windows menu lists web", "(*) web" in scr)
s.send(b'\x1b', 0.4)               # close the menu

# ---- 2: Profiles menu (Alt-R) with the (*) mark on the active one ----
s.send(b'\x1br', 0.5)
scr = s.text()
check("profiles menu open", "Save current as profile" in scr)
check("dev has active mark", "(*) dev" in scr)
check("menu lists oldtpl", "oldtpl" in scr)
check("menu lists legacy1", "legacy1" in scr)

# ---- 3: activate the flattened legacy template (row 3: dev, oldtpl, legacy1) ----
s.send(b'\x1b[B', 0.2)
s.send(b'\x1b[B', 0.2)
s.send(b'\r', 1.5)
scr = s.text()
check("legacy profile token", "LEGACY_PROF_TOKEN" in scr)
check("workspace switched", "PROF_PANE_A" not in scr)

# ---- 4: save the workspace as profile 'captured' ----
# capturable markers: the pane's cwd and a single-word foreground
# command (python3), which survives the INI write/re-read cycle
s.send(b'cd /tmp/opencode/sthome-profile\r', 0.5)
if sys.platform.startswith('linux'):
    s.send(b'set +m\r', 0.3)        # exercise Linux's wait4 fallback
else:
    # Darwin libproc exposes pgrp/argv but not a shell's current wait syscall;
    # keep this test on the normal, unambiguous terminal-foreground path.
    s.send(b'set -m\r', 0.3)
s.send(b'python3\r', 0.2)
# The pane process scanner is deliberately periodic.  Synchronize with its
# visible title instead of assuming a one-second CI runner deadline.  The
# executable is commonly "python3" on GNU/Linux and "Python" after Apple's
# /usr/bin/python3 stub re-execs the framework binary.
python_observed = s.wait_until(
    lambda rows: any('python' in row.lower() and
                     any(ch in row for ch in '═─') for row in rows) and
                 any('>>>' in row for row in rows))
check("foreground Python observed", python_observed)
s.send(b'\x1br', 0.5)
s.send(b's', 0.6)
scr = s.text()
check("save-as input box", "Profile name:" in scr)
s.send(b'\x1b[3~' * 40, 0.3)       # Delete: empty the prefilled name (cursor at start)
s.send(b'captured', 0.3)
s.send(b'\r', 1.5)
scr = s.text()
check("save-as toast", "Profile saved: captured" in scr)
s.send(b'\r', 0.5)                 # close the toast

txt = open(USERINI).read()
saved_ini = configparser.ConfigParser()
saved_ini.read(USERINI)
captured_titles = [
    saved_ini.get(section, 'title', fallback='').strip().lower()
    for section in saved_ini.sections()
    if section.startswith('profile.captured.window.') and '.pane.' in section
]
captured_cmds = [
    saved_ini.get(section, 'cmd', fallback='').strip()
    for section in saved_ini.sections()
    if section.startswith('profile.captured.window.') and '.pane.' in section
]


def captured_python(value):
    """Recognise the actual executable recorded from argv, not one OS path."""
    try:
        argv = shlex.split(value)
    except ValueError:
        return False
    if len(argv) != 1:
        return False
    executable = argv[0]
    basename = os.path.basename(executable).lower()
    return re.fullmatch(r'python(?:3(?:\.\d+)?)?', basename) is not None


check("ini has profile.captured", "[profile.captured]" in txt)
check("ini has layout key", "layout=" in txt)
# macOS /usr/bin/python3 may re-exec Python.framework/Python; parse the saved
# argv and validate its executable instead of grepping one framework spelling.
check("ini captured marker cmd",
      len(captured_cmds) == 1 and captured_python(captured_cmds[0]))
check("ini captured marker cwd", "cwd=/tmp/opencode/sthome-profile" in txt)
check("ini captured visible basename title",
      len(captured_titles) == 1 and
      captured_titles[0] in {'python3', 'python'})
check("ini captured scrollback", "scrollback=10000" in txt)
check("ini keeps default_profile", "default_profile=dev" in txt)
check("ini keeps class section", "[class.keepme]" in txt)

# ---- 5: absorption of the user's [template.*] when saving ----
check("template absorbed", "[template.oldtpl]" not in txt)
check("oldtpl now a profile", "[profile.oldtpl]" in txt)

s.send(b'\x1bx', 1.0)              # the single Exit path
s.close()
time.sleep(0.4)

# ---- 6: restart: captured and oldtpl listed and activatable ----
s = Session()
s.drain(2.0)
scr = s.text()
check("restart: dev default", "PROF_PANE_A" in scr)
s.send(b'\x1br', 0.5)
scr = s.text()
check("restart menu: oldtpl", "oldtpl" in scr)
check("restart menu: captured", "captured" in scr)

# activate oldtpl (row 2: dev, oldtpl, captured, legacy1)
s.send(b'\x1b[B', 0.2)
s.send(b'\r', 1.5)
scr = s.text()
check("oldtpl activates", "OLDTPL_TOKEN" in scr)

# activate captured (row 3): its pane relaunches the captured python3
s.send(b'\x1br', 0.5)
s.send(b'\x1b[B', 0.2)
s.send(b'\x1b[B', 0.2)
s.send(b'\r', 1.8)
captured_title_observed = s.wait_until(
    lambda rows: any(captured_titles and captured_titles[0] in row.lower() and
                     any(ch in row for ch in '═─') for row in rows) and
                 any('>>>' in row for row in rows),
    2.0)
scr = s.text()
check("captured switches away", "OLDTPL_TOKEN" not in scr)
check("captured repl prompt", ">>>" in scr)
check("captured restores pane title", captured_title_observed)
s.send(b'print(40600+2)\r', 0.8)
scr = s.text()
check("captured activates", "40602" in scr)

s.send(b'\x1bx', 1.0)              # the single Exit path
s.close()

sys.exit(1 if fails else 0)
