#!/usr/bin/env python3
"""superterm test: session restore across runs."""
import configparser
import errno, os, pty, re, time, select, sys, fcntl, termios, struct, subprocess, shlex
import pyte

sys.path.insert(0, os.path.dirname(__file__))
from stlib import close_all_daemons, wait_pid

BIN = os.environ.get('SUPERTERM_TEST_BIN', os.path.abspath(os.path.join(
    os.path.dirname(__file__), '..', 'bin', 'superterm')))
HOME = '/tmp/opencode/st-restore'
os.makedirs(HOME, exist_ok=True)
SESS = HOME + '/.superterm/session.ini'
DEBUG_LOG = HOME + '/foreground-debug.log'
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
            if sys.platform.startswith('linux'):
                # Upstream Linux can omit CONFIG_PROC_CHILDREN. Exercise the
                # O(all-procs) compatibility fallback while this suite also
                # proves exact foreground/background classification.
                os.environ['SUPERTERM_TESTING'] = '1'
                os.environ['SUPERTERM_TEST_PROC_CHILDREN_FALLBACK'] = '1'
                os.environ['SUPERTERM_TEST_FOREGROUND_DIAG'] = '1'
                os.environ['SUPERTERM_DEBUG'] = DEBUG_LOG
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


def process_table():
    """Portable PID tree snapshot; never selects a process by global name."""
    try:
        result = subprocess.run(
            ['/bin/ps', '-A', '-o', 'pid=', '-o', 'ppid=', '-o', 'pgid=',
             '-o', 'stat=', '-o', 'args='],
            capture_output=True, text=True, timeout=3.0, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    rows = {}
    if result.returncode != 0:
        return rows
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) < 4:
            continue
        try:
            pid, ppid, pgid = map(int, parts[:3])
        except ValueError:
            continue
        rows[pid] = {
            'ppid': ppid, 'pgid': pgid, 'stat': parts[3],
            'args': parts[4] if len(parts) == 5 else '',
        }
    return rows


def restored_processes(root_pid, timeout=8.0):
    """Return exact pane leaders and sleep descendants rooted at this UI."""
    final = ([], [])
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        rows = process_table()
        leaders = sorted(pid for pid, row in rows.items()
                         if row['ppid'] == root_pid and
                         not row['stat'].startswith('Z'))
        descendants = set(leaders)
        changed = True
        while changed:
            before = len(descendants)
            descendants.update(
                pid for pid, row in rows.items()
                if row['ppid'] in descendants and
                not row['stat'].startswith('Z'))
            changed = len(descendants) != before
        sleeps = []
        for pid in sorted(descendants):
            try:
                argv = shlex.split(rows[pid]['args'])
            except ValueError:
                continue
            if (len(argv) == 2 and
                    os.path.basename(argv[0]) == 'sleep' and
                    argv[1] == '987'):
                sleeps.append(pid)
        final = leaders, sleeps
        if len(leaders) == 2 and len(sleeps) == 1:
            break
        time.sleep(0.04)
    return final


def live_sleep_parent(root_pid, argument='987', timeout=8.0):
    """Return the exact sleep and shell PIDs below this one test client."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        rows = process_table()
        descendants = {root_pid}
        changed = True
        while changed:
            before = len(descendants)
            descendants.update(
                pid for pid, row in rows.items()
                if row['ppid'] in descendants and
                not row['stat'].startswith('Z'))
            changed = len(descendants) != before
        for pid in sorted(descendants - {root_pid}):
            try:
                argv = shlex.split(rows[pid]['args'])
            except (KeyError, ValueError):
                continue
            if (len(argv) == 2 and
                    os.path.basename(argv[0]) == 'sleep' and
                    argv[1] == argument):
                return pid, rows[pid]['ppid']
        time.sleep(0.04)
    return None, None


def foreground_diagnostics(offset, shell_pid):
    """Read only structured markers for this command's exact live shell."""
    try:
        with open(DEBUG_LOG, encoding='utf-8', errors='replace') as stream:
            stream.seek(offset)
            lines = stream.readlines()
    except OSError:
        return []
    marker = re.compile(
        rf'foreground-diag shell={shell_pid} (.+)$')
    return [match.group(1) for line in lines
            if (match := marker.search(line)) is not None]

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
if sys.platform.startswith('linux'):
    # One background child at an interactive prompt must not be mistaken for
    # foreground merely because job control makes it share bash's pgrp.
    a.send(b'set +m; sleep 986 &\r', 0.3)
a.send(b'\x1bOQ', 1.2)              # F2 vertical split
if sys.platform.startswith('linux'):
    # Exercise the optional Linux path as it is actually used: with job
    # control disabled TIOCGPGRP still names bash, so the product must prove
    # that bash is synchronously waiting for its one direct child. Some
    # hardened runners deny /proc/PID/syscall even to the process ancestor;
    # only that exact, repeatedly observed kernel restriction may skip this
    # optional probe. The required portable save/restore oracle then runs via
    # an unambiguous foreground process group.
    try:
        foreground_log_offset = os.path.getsize(DEBUG_LOG)
    except OSError:
        foreground_log_offset = 0
    a.send(b'set +m; cd /tmp; sleep 987\r', 0.2)
else:
    a.send(b'set -m; cd /tmp; sleep 987\r', 0.2)
# Saving immediately after a fixed sleep races the periodic process query on
# a loaded runner.  Require the real window title to identify the foreground
# process first; matching only pane text would accept the echoed command.
foreground_observed = a.wait_until(
    lambda rows: any('sleep' in row.lower() and
                     any(ch in row for ch in '═─') for row in rows))
if sys.platform.startswith('linux'):
    sleep_pid, shell_pid = live_sleep_parent(a.pid)
    markers = foreground_diagnostics(foreground_log_offset, shell_pid)
    accepted = (sleep_pid is not None and
                f'accepted child={sleep_pid}' in markers)
    if foreground_observed and accepted:
        check('A: Linux wait fallback', True)
    else:
        denied_markers = [detail for detail in markers
                          if detail.startswith('wait=read-failed errno=')]
        allowed_denials = {
            f'wait=read-failed errno={errno.EPERM}',
            f'wait=read-failed errno={errno.EACCES}',
        }
        restricted = (shell_pid is not None and len(denied_markers) >= 3 and
                      len(denied_markers) == len(markers) and
                      all(detail in allowed_denials
                          for detail in denied_markers))
        if restricted:
            print('A: Linux wait fallback : SKIP '
                  '(/proc/PID/syscall repeatedly denied for exact live '
                  f'shell {shell_pid}; {denied_markers})')
        else:
            print('  Linux fallback diagnostic:',
                  f'sleep={sleep_pid} shell={shell_pid}',
                  f'visible={foreground_observed} accepted={accepted}',
                  markers)
            check('A: Linux wait fallback', False)
        # Stop only this pane's exact foreground command, wait until it has
        # gone, then run the mandatory cross-platform persistence assertion.
        a.send(b'\x03', 0.3)
        stop_deadline = time.monotonic() + 4.0
        old_sleep_stopped = False
        while time.monotonic() < stop_deadline:
            row = process_table().get(sleep_pid)
            if row is None or row['stat'].startswith('Z'):
                old_sleep_stopped = True
                break
            time.sleep(0.04)
        check('A: exact fallback child stopped', old_sleep_stopped)
        foreground_observed = False
        if old_sleep_stopped:
            a.send(b'set -m; cd /tmp; sleep 987\r', 0.2)
            foreground_observed = a.wait_until(
                lambda rows: any('sleep' in row.lower() and
                                 any(ch in row for ch in '═─')
                                 for row in rows))
            new_sleep_pid, _ = live_sleep_parent(a.pid)
            check('A: portable foreground replacement',
                  foreground_observed and new_sleep_pid is not None and
                  new_sleep_pid != sleep_pid)
check("A: foreground observed", foreground_observed)
a.send(b'\x1bx', 1.0)               # Alt-X: local autosave on Exit
a.close()
time.sleep(0.4)

check("A: session exists", os.path.exists(SESS))
if os.path.exists(SESS):
    txt = open(SESS).read()
    print("--- session.ini ---")
    print(txt)
    saved = configparser.ConfigParser(interpolation=None)
    saved.read(SESS)
    check("A: layout V saved", 'V:' in txt)
    check("A: background ignored",
          saved.get('pane0', 'cmd', fallback='').strip() == '')
    check("A: cmd captured",
          saved.get('pane1', 'cmd', fallback='').strip() == 'sleep 987')

# --- run B: restore
b = Session()
b.drain(2.5)
# The top restored window can cover most of the other one, so prove the live
# PTY topology instead of accepting text from session.ini.  Only direct
# children of this exact SuperTerm PID are pane leaders; the command oracle is
# likewise restricted to their descendant tree and exact two-argument argv.
restored_leaders, restored_sleeps = restored_processes(b.pid)
check("B: two panes restored", len(restored_leaders) == 2)
check("B: command restarted", len(restored_sleeps) == 1)
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
check("D: DeskW/H round-trip",
      f'deskw={DESKW}' in txt and f'deskh={DESKH}' in txt)

sys.exit(1 if fails else 0)
