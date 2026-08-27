# The superterm control CLI / La CLI de control de superterm

Since 3.0, superterm turns every session into a server from the moment it starts:
the visible terminal is just the first attached client. This document
describes the command-line interface that drives those sessions from any
other shell. **Every control command and its documented long command-local
options are accepted in English and in Spanish**; command/topic names and long
options ignore case and accents. Short options are exact and case-sensitive.
Historical startup flags keep the exact spelling shown by
`superterm --help startup`. Messages follow the `[ui] language` setting (or
`LANG` when no configuration exists yet).
Root administration of the optional dedicated OpenSSH TCP entry is documented
separately in [SSH_SERVER.md](SSH_SERVER.md).

La versión en español está en la segunda mitad de este documento.

## Live contextual reference / Referencia contextual integrada

The executable carries a navigable, complete reference generated from one
help implementation. Start at the index and request only the page you need:

```sh
superterm --help
superterm --help startup
superterm --help targets
superterm --help sessions
superterm --help panes
superterm --help windows
superterm --help ssh
superterm --help ssh-server
superterm --help reference
superterm --help all
```

`superterm help TOPIC` and `superterm COMMAND --help` reach the same command
pages. Spanish aliases work too, for example `superterm --ayuda sesiones` and
`superterm enviar --ayuda`; `-h` and the quoted form `'-?'` are short aliases
for `--help`. `--help all` emits the entire deterministic
reference for humans, scripts and AI agents. Help needs no live session or
root privileges, has no ANSI control sequences or side effects, and an unknown
topic is a usage error (exit code 2) instead of a guessed page.

El ejecutable contiene esa misma referencia navegable en español. Empieza con
`superterm --ayuda`, consulta una página con `superterm --ayuda TEMA` o
`superterm ORDEN --ayuda`, y usa `superterm --ayuda todo` para obtenerla
completa en una salida estable, sin abrir el IDE ni modificar estado.

---

## English

### Targets

```
SESSION            one live session; pane commands use its focused pane
SESSION:PANE       canonical pane form: 1-based index or unique title text
SESSION.PANE       legacy pane separator; prefer the unambiguous colon
.                  the only live session (its focused pane by default)
.:PANE             one pane of the only live session
.PANE or :PANE     legacy shorthand for .:PANE
```

Session resolution tries the exact name, its sanitized form, a unique
case-insensitive name and finally a unique case-insensitive prefix. `.` is
valid only when exactly one session is live. `PANE` is the 1-based number in
the window title or a unique case- and accent-insensitive title substring.

The colon form is canonical and unambiguous. For compatibility,
`SESSION.PANE` is still accepted: an existing whole dotted session name wins;
otherwise the last dot separates the pane.

`kill` always requires the session name. `send`, `capture` and the window
commands always require an explicit target (`.` counts as explicit).

### Sessions

```
superterm list [SESSION]         sessions table, or pane details of one
superterm attach [SESSION]       attach the interactive terminal
superterm kill SESSION           terminate a session and its programs
superterm --session NAME         name the session created at launch
```

`list` prints NAME, PROFILE, PANES, CLIENTS and CREATED. With a session
argument it prints per pane: index, title, type (`local`/`ssh`/`command`),
target (`user@host`), the live running command, terminal size, scrollback
lines and flags (`*` focused, `M` minimized, `Z` zoomed, `!` dead).

### Panes

```
superterm send TARGET TEXT...    type into a pane (appends Enter)
  -n, --no-enter, --sin-intro    do not append Enter
  -k, --key, --tecla NAME        send a named key (repeatable):
                                 Enter/Return/Intro Esc/Escape Tab/BackTab
                                 Space Backspace Up Down Left Right Home End
                                 PgUp PgDn Ins Del F1..F12 C-a..C-z M-x
                                 (the help page lists every Spanish alias)
  --                             remaining words are literal text
  -                              read raw stdin (no Enter appended)
superterm capture TARGET         print the visible screen as UTF-8 text
  -H, --history                  the whole scrollback plus the screen
  -l, --lines N                  only the last N lines
  -o, --output FILE              write to a file instead of stdout
```

### Windows

These work with or without clients attached; attached clients see every
change live.

```
superterm new SESSION[:PANE]     open (split) a new pane
  -c, --class NAME               window class from your configuration
  --cmd COMMAND                  run an ad-hoc command
  --cwd, --dir, --directorio DIR starting directory
  -t, --title NAME               pane title
  -d, --down | -r, --right       split direction (default: down)
superterm close TARGET           close a pane
superterm focus TARGET           set the focused pane ('.' follows it when unique)
superterm rename TARGET NAME     set a title retained by the live session
superterm resize TARGET WxH      explicitly resize the shared PTY, e.g. 100x30
superterm minimize TARGET        minimize the window
superterm restore TARGET         undo minimize and zoom
superterm zoom TARGET            maximize and focus the window
superterm organize SESSION [grid|tile|cascade]
```

`resize` accepts a normal or minimized window. A maximized/fullscreen pane must
be restored first so its canonical frame and PTY cannot describe different grids.
The control CLI deliberately refuses to close the last pane; use `kill` to
terminate the session, or close it inside the UI when an empty live desktop is
what you want.

### Exit codes

- `0`: success.
- `1`: session/pane not found, ambiguous or rejected operation, no sessions,
  or SSH administration/validation failure.
- `2`: invalid command line, option, key name, help topic or argument.
- `3`: connection/protocol failure; `ssh-server status` also uses 3 when the
  dedicated service is down.

Diagnostics go to stderr; command data and help go to stdout.

### Examples

```
superterm send prod:2 tail -f /var/log/syslog
superterm capture prod:2 --history | grep ERROR
cat script.sh | superterm send prod:1 -
superterm new prod --cmd "htop" -t Monitor --right
superterm focus prod:Monitor && superterm send -n . q
superterm organize prod grid
superterm list prod
```

### Multi-user sessions

Up to 8 clients can attach to one session (`superterm attach` from several
terminals). The daemon owns one desktop: window positions and sizes, minimize,
zoom, fullscreen and focus are the same for every client. Input from all
viewers remains enabled and the daemon processes it in arrival order. The
desktop has one canonical character size retained by its profile/session.
Attach and physical `SIGWINCH` reports are client metadata only: they never
adapt the desktop or send `TIOCSWINSZ` to a pane. A smaller terminal receives
horizontal and vertical scrollbars for a viewport initially anchored at
canonical `(0,0)`; a larger terminal has unused margin.

Only an explicit IDE action changes the desktop. `Desktop -> Adjust to this
terminal size` adopts that client's usable character area, `Desktop -> Modify
dimensions...` accepts `20x25` through `8192x4094`, and `Desktop -> Show
current dimensions...` reports logical, complete-IDE, terminal and viewport
sizes. Shrinking does not scale windows or resize normal/minimized PTYs. Bounds
stay exact unless no safe draggable title cell would remain visible, in which
case the daemon translates that window by the minimum amount. Maximize and
fullscreen always derive from the canonical desktop, never from the smallest
or newest client. Raw fullscreen passes the geometry gate only when every
attached terminal has the same physical grid and it exactly matches canonical
fullscreen; otherwise viewers use the synchronized renderer and their
scrollable viewport.

Moves, incremental resizes and optional maximize/fullscreen outlines are
relayed while they happen, not only as a final result. During move/resize the
themed status line shows `Window X,Y  WxH` in canonical character coordinates
for the active window—not the desktop. Its size is available from `Desktop ->
Show current dimensions...`.
Per-pane leases allow different viewers to manipulate different panes
concurrently; a maximize hand-off also acquires the previous maximized pane
because both states change atomically. A peer commit cannot rewind the gesture
still held by another viewer. Minimized icons have stable holes: restore frees
one and the next minimize reuses the first free slot without moving the others.
Minimizing the focused pane preserves shared focus until an explicit focus
action selects another pane. Minimize and restore are delivered as one atomic
shared transition.
A stalled client pauses output briefly and is disconnected after a grace
period so it can never block the session. Legacy (pre-3.0) clients still
attach exclusively, exactly as before.

`Ctrl-Q d` disconnects only that viewer. No save or restore occurs: the live
daemon object remains exactly as it was, and the next attach receives it.

Exiting an interactive client with `Alt-X` disconnects only that client while
another UI is attached. The last interactive client to exit closes the
session. A live detached session already is the current state; there is no
separate save/no-save exit. The explicit
`superterm kill SESSION` command is always administrative and closes the
whole session regardless of how many clients are attached.

### Dedicated SSH/TCP entry

The commands above control one user's live SuperTerm sessions. The separate
root-only namespace below administers the optional OpenSSH listener:

```sh
sudo superterm ssh-server setup
sudo superterm ssh-server check
sudo superterm ssh-server restart
sudo superterm ssh-server status
sudo superterm ssh-server enable
sudo superterm ssh-server disable
sudo superterm ssh-server uninstall-service
sudo superterm ssh-server authorize USER KEY.pub
sudo superterm ssh-server list-keys [USER]
sudo superterm ssh-server revoke USER SHA256:...
```

After its explicit TCP endpoint is configured, a standard interactive client
uses `ssh -p PORT USER@HOST`. This is a second `sshd` process and service. Its
persistent configuration and host keys live under `/etc/superterm/sshd`; its
PID and service descriptor use their native system paths. It neither edits nor
restarts the host's ordinary SSH service. The authenticated entry is
forced into this same per-user session engine. Network loss and Detach retain
the live session. Remote exec, no-PTY sessions, SCP/SFTP and forwarding are
deliberately rejected. See [SSH_SERVER.md](SSH_SERVER.md) for the complete
authentication, setup and recovery contract.
The built-in summaries are available through `superterm --help ssh` and
`superterm --help ssh-server` without root privileges.

---

## Español

### Destinos

```
SESION             una sesión viva; las órdenes de panel usan el enfocado
SESION:PANEL       forma canónica: índice desde 1 o texto único del título
SESION.PANEL       separador histórico; se prefieren los dos puntos
.                  la única sesión viva (su panel enfocado por defecto)
.:PANEL            un panel de la única sesión
.PANEL o :PANEL    abreviatura histórica de .:PANEL
```

La sesión se resuelve por nombre exacto, forma saneada, nombre único sin
distinguir mayúsculas y, finalmente, prefijo único sin distinguir mayúsculas.
`.` solo es válido cuando existe exactamente una sesión viva. `PANEL` es el
número desde 1 mostrado en el título o una subcadena única del título sin
distinguir mayúsculas ni acentos.

La forma con dos puntos es canónica y no ambigua. Por compatibilidad se acepta
`SESION.PANEL`: si existe una sesión viva con el nombre completo y puntos,
esta gana; en caso contrario, el último punto separa el panel.

`matar` exige siempre el nombre de la sesión. `enviar`, `capturar` y las
órdenes de ventanas exigen siempre destino explícito (`.` cuenta como
explícito).

### Sesiones

```
superterm listar [SESION]        tabla de sesiones, o detalle de una
superterm conectar [SESION]      conecta el terminal interactivo
superterm matar SESION           termina una sesión y sus programas
superterm --sesion NOMBRE        nombra la sesión creada al arrancar
```

`listar` imprime NOMBRE, PERFIL, PANELES, CLIENTES y CREADA. Con una
sesión, imprime por panel: índice, título, tipo (`local`/`ssh`/`command`),
destino (`usuario@host`), el comando vivo, tamaño del terminal, líneas de
historial y estado (`*` foco, `M` minimizada, `Z` zoom, `!` muerto).

### Paneles

```
superterm enviar DESTINO TEXTO...  escribe en un panel (añade Intro)
  -n, --sin-intro, --no-enter      no añadir Intro
  -k, --tecla, --key NOMBRE        envía una tecla con nombre (repetible):
                                   Enter/Return/Intro Esc/Escape Tab/TabAtras
                                   Espacio Retroceso Arriba Abajo Izquierda
                                   Derecha Inicio Fin RePag AvPag Ins Supr
                                   F1..F12 C-a..C-z M-x
  --                               el resto son palabras de texto literal
  -                                lee stdin en crudo (sin Intro)
superterm capturar DESTINO         vuelca la pantalla visible como UTF-8
  -H, --historico                  todo el historial más la pantalla
  -l, --lineas N                   solo las últimas N líneas
  -o, --salida FICHERO             escribe a fichero en vez de stdout
```

### Ventanas

Funcionan con o sin clientes conectados; los conectados ven cada cambio
en vivo.

```
superterm nueva SESION[:PANEL]   abre (divide) un panel nuevo
  -c, --clase NOMBRE             clase de ventana de tu configuración
  --comando ORDEN                ejecuta una orden ad-hoc
  --cwd, --dir, --directorio DIR  directorio inicial
  -t, --titulo NOMBRE            título del panel
  -d, --abajo | -r, --derecha    dirección de la división (por defecto: abajo)
superterm cerrar DESTINO         cierra un panel
superterm foco DESTINO           fija el foco ('.' lo sigue si la sesión es única)
superterm renombrar DESTINO NOMBRE  fija un título retenido en la sesión viva
superterm tamano DESTINO WxH     redimensiona el PTY compartido, ej. 100x30
superterm minimizar DESTINO      minimiza la ventana
superterm restaurar DESTINO      deshace minimizar y zoom
superterm ampliar DESTINO        maximiza la ventana y le da el foco
superterm organizar SESION [rejilla|mosaico|cascada]
```

`tamano` acepta una ventana normal o minimizada. Antes hay que restaurar un
panel maximizado/fullscreen para que su marco canónico y su PTY no describan
rejillas distintas.
La CLI de control rechaza deliberadamente cerrar el último panel; usa `matar`
para terminar la sesión, o ciérralo desde el IDE si quieres conservar un
escritorio vivo vacío.

### Códigos de salida

- `0`: éxito.
- `1`: sesión/panel ausente, ambiguo u operación rechazada, sin sesiones, o
  fallo de administración/validación SSH.
- `2`: orden, opción, tecla, tema de ayuda o argumento inválido.
- `3`: fallo de conexión/protocolo; `servidor-ssh estado` también usa 3 cuando
  el servicio dedicado está parado.

Los diagnósticos van a stderr; los datos de órdenes y la ayuda van a stdout.

### Ejemplos

```
superterm enviar prod:2 tail -f /var/log/syslog
superterm capturar prod:2 --historico | grep ERROR
cat script.sh | superterm enviar prod:1 -
superterm nueva prod --comando "htop" -t Monitor --derecha
superterm foco prod:Monitor && superterm enviar -n . q
superterm organizar prod rejilla
superterm listar prod
```

### Sesiones multiusuario

Hasta 8 clientes pueden conectarse a una misma sesión (`superterm
conectar` desde varios terminales). El daemon posee un único escritorio:
posiciones y tamaños, minimizar, zoom y pantalla completa son iguales para
todos, incluido el panel enfocado. La entrada de todos los clientes sigue
habilitada y el daemon la procesa por orden de llegada. El perfil/sesión
conserva un único tamaño canónico en caracteres. Un attach o un `SIGWINCH`
físico solo actualiza metadatos del cliente: jamás adapta el escritorio ni
envía `TIOCSWINSZ` a un panel. Un terminal pequeño obtiene barras horizontal y
vertical para un área visible inicialmente anclada en `(0,0)`; uno grande deja
margen.

El escritorio solo cambia por una acción explícita del IDE. `Escritorio ->
Ajustar al tamaño de este terminal` adopta el área útil de ese cliente,
`Escritorio -> Modificar dimensiones...` acepta desde `20x25` hasta
`8192x4094`, y `Escritorio -> Mostrar dimensiones actuales...` muestra los
tamaños lógico, IDE completo, terminal y área visible. Al reducir no se escalan
las ventanas ni cambian los PTY normales/minimizados. Sus dimensiones y
posiciones se conservan, salvo que no quede visible ningún punto seguro para
arrastrar el título; entonces el daemon traslada solo lo mínimo. Maximizar y
fullscreen siempre derivan del escritorio canónico, nunca del cliente menor o
del último en conectar. El passthrough crudo supera la condición geométrica
solo cuando todos los terminales conectados tienen el mismo tamaño físico y
este coincide exactamente con el fullscreen canónico; en otro caso conservan
el renderer sincronizado y su área desplazable.

Los movimientos, cambios de tamaño graduales y contornos opcionales de
maximizar/fullscreen se retransmiten mientras ocurren, no solo como resultado
final. Durante mover/redimensionar, la barra de estado muestra `Ventana X,Y  WxH`
en coordenadas canónicas y con el tema activo. Es la geometría de esa ventana,
no la del escritorio; esta última se consulta en `Escritorio -> Mostrar
dimensiones actuales...`. Los leases por panel permiten que
distintos clientes manipulen paneles diferentes a la vez; el relevo de
maximizado también adquiere el panel maximizado anterior porque ambos estados
cambian de forma atómica. El commit de uno no puede hacer retroceder el gesto
que otro aún mantiene. Los iconos minimizados conservan sus huecos: restaurar
libera uno y el siguiente minimizado reutiliza el primero libre sin mover los
demás. Minimizar el panel enfocado conserva el foco compartido hasta una acción
explícita de foco. Minimizar y restaurar son transiciones compartidas y
atómicas. Un cliente atascado pausa la salida brevemente y se
desconecta pasado un periodo de
gracia, de modo que nunca bloquea la sesión. Los clientes antiguos (anteriores
a 3.0) siguen conectando en exclusiva, igual que siempre.

`Ctrl-Q d` desconecta únicamente ese visor. No se guarda ni se restaura nada:
el objeto vivo del daemon queda exactamente como estaba y el siguiente attach
lo recibe directamente.

Salir de un cliente interactivo con `Alt-X` desconecta solo ese cliente
mientras haya otra interfaz conectada. Cuando sale el último cliente
interactivo, se cierra la sesión. Una sesión viva separada ya es el estado
actual; no hay salidas distintas con/sin guardado. El comando
administrativo explícito `superterm matar SESION` siempre cierra la sesión
completa, independientemente del número de clientes conectados.

### Entrada SSH/TCP dedicada

Las órdenes anteriores controlan las sesiones vivas de un usuario. Este
namespace separado, ejecutado como root salvo la ayuda, administra el listener
OpenSSH opcional:

```sh
sudo superterm servidor-ssh configurar
sudo superterm servidor-ssh comprobar
sudo superterm servidor-ssh reiniciar
sudo superterm servidor-ssh estado
sudo superterm servidor-ssh habilitar
sudo superterm servidor-ssh deshabilitar
sudo superterm servidor-ssh desinstalar-servicio
sudo superterm servidor-ssh autorizar USUARIO CLAVE.pub
sudo superterm servidor-ssh listar-claves [USUARIO]
sudo superterm servidor-ssh revocar USUARIO SHA256:...
```

Tras configurar su endpoint TCP explícito, un cliente interactivo estándar
entra con `ssh -p PUERTO USUARIO@HOST`. Es un segundo proceso `sshd` y servicio.
Su configuración persistente y host keys viven bajo `/etc/superterm/sshd`; el
PID y descriptor del servicio usan las rutas nativas del sistema. No edita ni
reinicia el SSH ordinario del host. La entrada autenticada queda
forzada a este mismo motor de sesiones por usuario. Perder la red o hacer
Detach conserva la sesión viva. Se rechazan deliberadamente exec remoto,
sesiones sin PTY, SCP/SFTP y forwarding. El contrato completo de autenticación,
instalación y recuperación está en [SSH_SERVER.md](SSH_SERVER.md).
Los resúmenes integrados están en `superterm --ayuda ssh` y
`superterm --ayuda servidor-ssh`, sin privilegios root.
