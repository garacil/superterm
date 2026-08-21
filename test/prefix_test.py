#!/usr/bin/env python3
"""superterm test: tecla prefijo configurable y migracion.

Cubre ParsePrefixKey de extremo a extremo: el default es Ctrl-Q (0x11), el
prefix=2 numerico antiguo migra a Ctrl-Q, un ctrl-b textual explicito se
respeta, y el nombre de sesion del detach se sanea ([A-Za-z0-9._-]).
"""
import os, pty, time, select, fcntl, termios, struct, shutil, glob, sys

BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'bin', 'superterm'))
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
    """Arranca, manda prefijo+d y devuelve si el cliente separo (salio
    dejando el socket vivo); en servidor-siempre no hay dialogo de nombre."""
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
        c.send(b'\x1bq', 0.8)     # no era prefijo: salir sin guardar
    c.close()
    # limpiar la sesion que quedo viva para la siguiente ronda
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

# ---- 1: default sin ini = Ctrl-Q ----
reset_home()
check("default Ctrl-Q separa", detach_works(b'\x11'))

# ---- 2: prefix=2 numerico antiguo migra a Ctrl-Q ----
reset_home()
write_ini('prefix=2')
check("prefix=2 migra a Ctrl-Q", detach_works(b'\x11'))

# ---- 3: ctrl-b textual explicito se respeta ----
reset_home()
write_ini('prefix=ctrl-b')
check("prefix=ctrl-b respeta Ctrl-B", detach_works(b'\x02'))

# ---- 4: con ctrl-b explicito, Ctrl-Q NO es prefijo ----
reset_home()
write_ini('prefix=ctrl-b')
check("ctrl-b: Ctrl-Q no es prefijo", not detach_works(b'\x11'))

# ---- 5: prefijo-s abre el selector de sesiones ----
reset_home()
c = Client()
c.drain(2.0)
c.send(b'\x11', 0.4)
c.send(b's', 1.0)
t = c.text()
check("prefijo-s abre selector", 'Attach' in t or 'Conectar' in t or 'Sessions' in t or 'Sesiones' in t)
c.send(b'\x1b', 0.6)
c.send(b'\x1bq', 0.8)
c.close()

# ---- 6: el nombre de sesion se sanea (sin ../ ni espacios) ----
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

# limpieza: cerrar el daemon que quedo vivo
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
