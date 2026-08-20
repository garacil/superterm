#!/usr/bin/env python3
"""superterm console cursor test: every way of leaving the client must put
the cursor back where the command was launched, not on the console's
first line. Covers plain exit (Alt-Q), live detach (Ctrl-Q d), and
permanent close from a reattached client (Alt-X).

Emulates a REAL xterm-family terminal (Konsole): answers the DSR query
ESC[6n with the launch position. On genuine xterm terminals the RTL video
driver homes the cursor (ESC[H) before entering the alternate screen
(?1049h), and ?1049h re-saves that homed position into the same slot used
by DECSC/SCOSC, so the ESC[u ESC 8 fallback restores line 1. pyte does not
model that slot sharing, which is why the pyte-based checks cannot catch
it. This test verifies at the byte level that the final cursor movement
emitted on exit is an explicit repositioning to the DSR-reported spot.
"""
import os, pty, re, time, select, sys, fcntl, termios, struct

BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'bin', 'superterm'))
HOME = '/tmp/opencode/sthome-cursor'
SOCK = HOME + '/.superterm/sessions/session.sock'

# autosanado: una ejecucion fallida anterior puede dejar un daemon vivo y su
# socket; matarlo y limpiar el directorio de sesiones antes de empezar
import glob as _glob, shutil as _shutil, socket as _socket, struct as _struct
def _purge_sessions():
    d = HOME + '/.superterm/sessions'
    for sock in _glob.glob(d + '/*.sock'):
        try:
            s = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
            s.settimeout(1.0)
            s.connect(sock)
            # FRAME_CLOSE (kind=5, longitud 0) al daemon zombi
            s.sendall(_struct.pack('<II', 5, 0))
            s.close()
        except OSError:
            pass
    time.sleep(0.5)
    _shutil.rmtree(d, ignore_errors=True)
_purge_sessions()
os.makedirs(HOME, exist_ok=True)

W, H = 100, 30

fails = []
def check(name, cond):
    print(f"{name:34}: {'OK' if cond else 'FAIL'}")
    if not cond:
        fails.append(name)

def run_session(args, row, col, quit_bytes, settle=3.0):
    """Launch superterm, answer DSR with (row,col), leave via quit_bytes.
    Returns (dsr_answered, teardown_bytes)."""
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm'
        os.environ['SHELL'] = '/bin/bash'
        os.environ['HOME'] = HOME
        os.environ['SUPERTERM_INI'] = HOME + '/no-sys.ini'
        os.execv(BIN, [BIN] + args)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', H, W, 0, 0))
    buf = b''
    answered = False
    end = time.time() + settle
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                buf += os.read(fd, 65536)
            except OSError:
                break
            if not answered and b'\x1b[6n' in buf:
                os.write(fd, b'\x1b[%d;%dR' % (row, col))
                answered = True
    os.write(fd, quit_bytes)
    out = b''
    end = time.time() + 3.0
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                d = os.read(fd, 65536)
            except OSError:
                break
            if not d:
                break
            out += d
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    return answered, out

def final_position_ok(name, out, row, col):
    """The LAST absolute move must be (row,col) with no ESC[H after it."""
    moves = re.findall(rb'\x1b\[(\d+);(\d+)H', out)
    ok = bool(moves) and (int(moves[-1][0]), int(moves[-1][1])) == (row, col)
    if ok:
        tail = out[out.rfind(b'\x1b[%d;%dH' % (row, col)):]
        ok = b'\x1b[H' not in tail[1:]
    check(name, ok)

# 1. salida normal sin guardar: Alt-Q
answered, out = run_session([], 23, 7, b'\x1bq')
check("DSR consultado (Alt-Q)", answered)
final_position_ok("cursor tras salir con Alt-Q", out, 23, 7)

# 2. detach dejando todo en ejecucion: Ctrl-Q d (+\r acepta el nombre)
answered, out = run_session([], 11, 5, b'\x11d\r')
check("DSR consultado (detach)", answered)
final_position_ok("cursor tras detach Ctrl-Q d", out, 11, 5)
check("servidor sigue vivo tras detach", os.path.exists(SOCK))

# 3. reattach y cierre definitivo: superterm --attach + Alt-X
answered, out = run_session(['--attach'], 17, 3, b'\x1bx')
check("DSR consultado (--attach)", answered)
final_position_ok("cursor tras cierre definitivo", out, 17, 3)
time.sleep(0.5)
check("socket eliminado tras cierre", not os.path.exists(SOCK))

sys.exit(1 if fails else 0)
