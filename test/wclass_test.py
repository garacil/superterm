#!/usr/bin/env python3
"""superterm test: window classes ([class.*] y legadas [t-*]) de INI usuario+sistema."""
import os, pty, time, select, sys, fcntl, termios, struct, shutil
import pyte

BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'bin', 'superterm'))
HOME = '/tmp/opencode/sthome-wclass'
USERINI = HOME + '/.superterm/superterm.ini'
SYSINI = HOME + '/system.ini'
SESS = HOME + '/.superterm/session.ini'
W, H = 110, 35

TOKENS = ('CLASS_USER_TOKEN', 'LEGACY_TOKEN', 'SHADOW_USER_TOKEN',
          'SHADOW_SYS_TOKEN', 'FREECONN_TOKEN', 'POSTONLY_TOKEN')

# entorno aislado: HOME propio e INI de sistema propio, limpios al empezar
shutil.rmtree(HOME, ignore_errors=True)
os.makedirs(HOME + '/.superterm', exist_ok=True)

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

# ---- fase 0: sesion de 1 panel para que las clases no auto-arranquen ----
s = Session()
s.drain(2.0)
s.send(b'\x1bx', 1.0)          # Alt-X: guardar y salir
s.close()
time.sleep(0.4)
check("bootstrap session saved", os.path.exists(SESS))

# ---- clases: [class.*] en INI de usuario, [t-*] y colision en el de sistema ----
with open(USERINI, 'w') as f:
    f.write("""[class.local-echo]
name=local-echo
enabled=1
cmd=echo CLASS_USER_TOKEN; exec /bin/bash -i

[class.shadowme]
name=shadowme
enabled=1
cmd=echo SHADOW_USER_TOKEN; exec /bin/bash -i

[class.freeconn]
name=freeconn
enabled=1
connect=bash -i
postconnect=echo FREECONN_TOKEN

[class.postonly]
name=postonly
enabled=1
postconnect=echo POSTONLY_TOKEN
""")
with open(SYSINI, 'w') as f:
    f.write("""[t-syslegacy]
name=syslegacy
enabled=1
type=local
cmd=echo LEGACY_TOKEN; exec /bin/bash -i

[class.SHADOWME]
name=SHADOWME
enabled=1
cmd=echo SHADOW_SYS_TOKEN; exec /bin/bash -i
""")

# menu Clases (Alt-C): '1 Local shell', luego clases con digitos 2..9 en orden
# usuario-primero: 2 local-echo, 3 shadowme, 4 freeconn, 5 postonly, 6 syslegacy
def open_class(sess, digit, t=1.5):
    sess.send(b'\x1bc', 0.6)   # Alt-C abre el menu
    sess.send(digit, t)        # digito con el menu abierto = abrir clase

def close_pane(sess):
    sess.send(b'\x1bp', 0.5)   # Alt-P: menu Panes
    sess.send(b'c', 1.0)       # Close pane

s = Session()
s.drain(2.5)
scr = s.text()
check("menu Classes visible", "Classes" in scr)
check("no class autostart", all(t not in scr for t in TOKENS))

# contenido del menu con Alt-C abierto
s.send(b'\x1bc', 0.6)
scr = s.text()
check("menu: Local shell row", "Local shell" in scr)
check("menu: user local-echo", "local-echo" in scr)
check("menu: legacy syslegacy", "syslegacy" in scr)
check("menu: shadowme user name", "shadowme" in scr)
check("menu: sys dup suppressed", "SHADOWME" not in scr)
check("menu: freeconn+postonly", ("freeconn" in scr) and ("postonly" in scr))

# 1: clase [class.*] del INI de usuario abre panel con su cmd
s.send(b'2', 1.5)
scr = s.text()
check("user class opens pane", "CLASS_USER_TOKEN" in scr)
close_pane(s)
check("user class pane closed", "CLASS_USER_TOKEN" not in s.text())

# 2: clase legada [t-*] del INI de sistema
open_class(s, b'6')
scr = s.text()
check("legacy class opens pane", "LEGACY_TOKEN" in scr)
close_pane(s)

# 3: shadowing: la clase de usuario tapa a la de sistema homonima
open_class(s, b'3')
scr = s.text()
check("shadow: user token wins", "SHADOW_USER_TOKEN" in scr)
check("shadow: sys token hidden", "SHADOW_SYS_TOKEN" not in scr)
close_pane(s)

# 4: connect= libre con postconnect por stdin (pipe)
open_class(s, b'4')
scr = s.text()
check("connect+post via stdin", "FREECONN_TOKEN" in scr)
close_pane(s)

# 5: solo postconnect: ejecuta y deja una shell interactiva viva
open_class(s, b'5')
scr = s.text()
check("postonly token printed", "POSTONLY_TOKEN" in scr)
s.send(b'echo STILL_$((41+1))_ALIVE\r', 1.2)
scr = s.text()
check("postonly shell alive", "STILL_42_ALIVE" in scr)

s.send(b'\x1bq', 1.0)          # Alt-Q: salir sin guardar
s.close()

sys.exit(1 if fails else 0)
