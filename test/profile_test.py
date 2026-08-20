#!/usr/bin/env python3
"""superterm test: perfiles [profile.*], plantillas legadas aplanadas y guardado."""
import os, pty, time, select, sys, fcntl, termios, struct, shutil
import pyte

BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'bin', 'superterm'))
HOME = '/tmp/opencode/sthome-profile'
USERINI = HOME + '/.superterm/superterm.ini'
SYSINI = HOME + '/system.ini'
W, H = 110, 35

# entorno aislado: HOME propio e INI de sistema propio, limpios al empezar
shutil.rmtree(HOME, ignore_errors=True)
os.makedirs(HOME + '/.superterm', exist_ok=True)

# INI de usuario: perfil dev (2 paneles), plantilla legada a absorber,
# y secciones ajenas ([session], [class.*]) que deben sobrevivir al guardado
with open(USERINI, 'w') as f:
    f.write("""[session]
default_profile=dev

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

# INI de sistema: plantilla legada de una sola sesion -> perfil 'legacy1'
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

# ---- 1: default_profile=dev activa el perfil escrito a mano al arrancar ----
s = Session()
s.drain(2.0)
scr = s.text()
check("dev pane a token", "PROF_PANE_A" in scr)
check("dev pane b token", "PROF_PANE_B" in scr)
check("dev two panes", scr.count("╔") + scr.count("┌") >= 2)

# menu Windows (Alt-W) lista las ventanas del perfil activo
s.send(b'\x1bw', 0.5)
scr = s.text()
check("windows menu lists web", "(*) web" in scr)
s.send(b'\x1b', 0.4)               # cerrar el menu

# ---- 2: menu Profiles (Alt-R) con marca (*) en el activo ----
s.send(b'\x1br', 0.5)
scr = s.text()
check("profiles menu open", "Save current as profile" in scr)
check("dev has active mark", "(*) dev" in scr)
check("menu lists oldtpl", "oldtpl" in scr)
check("menu lists legacy1", "legacy1" in scr)

# ---- 3: activar la plantilla legada aplanada (fila 3: dev, oldtpl, legacy1) ----
s.send(b'\x1b[B', 0.2)
s.send(b'\x1b[B', 0.2)
s.send(b'\r', 1.5)
scr = s.text()
check("legacy profile token", "LEGACY_PROF_TOKEN" in scr)
check("workspace switched", "PROF_PANE_A" not in scr)

# ---- 4: guardar el area de trabajo como perfil 'captured' ----
# marcadores capturables: cwd del panel y comando en primer plano de una sola
# palabra (python3), que sobrevive al ciclo escribir/releer del INI
s.send(b'cd /tmp/opencode/sthome-profile\r', 0.5)
s.send(b'python3\r', 1.0)
s.send(b'\x1br', 0.5)
s.send(b's', 0.6)
scr = s.text()
check("save-as input box", "Profile name:" in scr)
s.send(b'\x1b[3~' * 40, 0.3)       # Supr: vaciar el nombre prellenado (cursor al inicio)
s.send(b'captured', 0.3)
s.send(b'\r', 1.5)
scr = s.text()
check("save-as toast", "Profile saved: captured" in scr)
s.send(b'\r', 0.5)                 # cerrar el toast

txt = open(USERINI).read()
check("ini has profile.captured", "[profile.captured]" in txt)
check("ini has layout key", "layout=" in txt)
check("ini captured marker cmd", ("cmd=python3" in txt) or ("cmd='python3'" in txt))
check("ini captured marker cwd", "cwd=/tmp/opencode/sthome-profile" in txt)
check("ini keeps default_profile", "default_profile=dev" in txt)
check("ini keeps class section", "[class.keepme]" in txt)

# ---- 5: absorcion de [template.*] del usuario al guardar ----
check("template absorbed", "[template.oldtpl]" not in txt)
check("oldtpl now a profile", "[profile.oldtpl]" in txt)

s.send(b'\x1bq', 1.0)              # salir sin guardar
s.close()
time.sleep(0.4)

# ---- 6: reinicio: captured y oldtpl listados y activables ----
s = Session()
s.drain(2.0)
scr = s.text()
check("restart: dev default", "PROF_PANE_A" in scr)
s.send(b'\x1br', 0.5)
scr = s.text()
check("restart menu: oldtpl", "oldtpl" in scr)
check("restart menu: captured", "captured" in scr)

# activar oldtpl (fila 2: dev, oldtpl, captured, legacy1)
s.send(b'\x1b[B', 0.2)
s.send(b'\r', 1.5)
scr = s.text()
check("oldtpl activates", "OLDTPL_TOKEN" in scr)

# activar captured (fila 3): su panel relanza el python3 capturado
s.send(b'\x1br', 0.5)
s.send(b'\x1b[B', 0.2)
s.send(b'\x1b[B', 0.2)
s.send(b'\r', 1.8)
scr = s.text()
check("captured switches away", "OLDTPL_TOKEN" not in scr)
check("captured repl prompt", ">>>" in scr)
s.send(b'print(40600+2)\r', 0.8)
scr = s.text()
check("captured activates", "40602" in scr)

s.send(b'\x1bq', 1.0)              # salir sin guardar
s.close()

sys.exit(1 if fails else 0)
