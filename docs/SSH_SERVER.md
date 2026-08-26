# Servidor SSH dedicado de SuperTerm

SuperTerm puede publicar su interfaz por TCP usando el `sshd` OpenSSH del
sistema. OpenSSH se ocupa del cifrado, la autenticacion de las cuentas, el PTY
y los cambios de tamano; el proceso que abre despues es el mismo cliente
SuperTerm que se usa localmente. Ese cliente se conecta al daemon de la sesion
por su socket Unix privado, por lo que solo existe un escritorio canonico y
un unico protocolo de sesiones.

No entrega el *shell* SSH convencional: la instancia puede autenticar con una
contrasena aceptada por la politica PAM de `sshd` o con claves publicas, pero
rechaza comandos remotos,
SFTP, forwarding, X11, agente SSH y sesiones sin PTY. Una vez autenticado, el
usuario si puede abrir panes y ejecutar en ellos los comandos que permita su
configuracion normal de SuperTerm; esos procesos se ejecutan con el UID de la
cuenta autenticada (incluido root solo si se habilita explicitamente). Por
tanto esta instancia puede sustituir el acceso SSH **interactivo** de un
servidor compatible, pero no sustituye todavia los usos de `sshd` para `scp`,
SFTP, automatizacion de comandos o tuneles. Tampoco es un sandbox de los
programas que el propio usuario arranque dentro de SuperTerm.

Perder la conexion cierra solamente el cliente: la sesion SuperTerm permanece
viva y el siguiente cliente la recibe tal como quedo.

Este documento es la referencia del conjunto completo: instalacion,
arquitectura, autenticacion, ciclo de vida de procesos, sesiones, operacion,
diagnostico y limites de seguridad. La configuracion que se edita es siempre
`server.ini`; los demas ficheros generados se explican para poder auditarlos,
no para modificarlos a mano.

## Resultado inmediato: `ssh` normal, servicio separado

Una vez preparado el listener, un cliente OpenSSH estandar entra directamente
en SuperTerm con una orden normal:

```sh
ssh -p 8022 german@192.168.0.214
```

Desde una terminal interactiva no hace falta `-tt`: `ssh` ya solicita un PTY.
Tampoco hace falta indicar `IdentityFile` si la clave es una identidad habitual
del cliente; si no coincide ninguna y se ha habilitado la contrasena, OpenSSH
la solicita y PAM decide si la cuenta puede entrar.

El `sshd` ordinario del host permanece intacto y puede seguir atendiendo en su
puerto habitual. La separacion es concreta y comprobable:

| Propiedad | SSH ordinario del host | SSH dedicado de SuperTerm |
|---|---|---|
| Proceso y servicio | Servicio SSH existente | Servicio propio de SuperTerm |
| Direcciones/puertos | Los ya configurados, normalmente puerto 22 | Lista `listen` explicita, por ejemplo puerto 8022 |
| Configuracion y host keys | `/etc/ssh` | `/etc/superterm/sshd` |
| Sesion resultante | Shell, comando o subsistema normal | Interfaz SuperTerm forzada |
| SCP/SFTP/tuneles | Segun la politica normal | Rechazados deliberadamente |

`setup`, `restart`, `disable` y `uninstall-service` solo administran la
instancia dedicada: no escriben `/etc/ssh/sshd_config`, no sustituyen las host
keys ordinarias y no paran ni reinician el servicio normal. Ambas instancias
reutilizan el mismo binario OpenSSH instalado, las cuentas NSS y la politica
PAM de `sshd`; opcionalmente la dedicada tambien puede **leer** el
`~/.ssh/authorized_keys` de cada cuenta, pero SuperTerm nunca lo modifica.
Esa reutilizacion esta declarada para no confundir aislamiento operativo con
una segunda base de cuentas o una segunda implementacion criptografica.

## Arquitectura: dos transportes, una sola sesion

OpenSSH y SuperTerm no compiten ni implementan dos servidores de terminal.
Cada uno resuelve una frontera distinta:

```text
equipo cliente
  ssh(1) + terminal grafico
          |
          | TCP cifrado, autenticado y con PTY
          v
sshd dedicado de SuperTerm (root, puerto configurado)
          |
          | ForceCommand, ya con la cuenta autenticada
          v
superterm --ssh-entry (UID german, root u otra cuenta)
          |
          | AF_UNIX privado: ~/.superterm/sessions/NOMBRE.sock
          v
daemon de esa sesion SuperTerm (mismo UID)
          |
          +-- PTY/pane 1 -> proceso de la cuenta
          +-- PTY/pane 2 -> proceso de la cuenta
          `-- estado canonico -> todos los clientes adjuntos
```

Hay dos planos de transporte deliberadamente separados:

- El plano exterior es SSH sobre TCP. OpenSSH implementa intercambio de
  claves, cifrado, integridad, autenticacion, PAM, asignacion de PTY,
  keepalive y cambios `SIGWINCH`.
- El plano interior es el protocolo binario de sesiones de SuperTerm sobre un
  socket Unix `0600`. Es el mismo protocolo que usa un cliente local; nunca se
  encapsula directamente en TCP ni se expone a la LAN.

Esta separacion deja un solo punto de verdad. El daemon de sesion es el unico
propietario de panes, PTYs, geometria, foco compartido y revision del
escritorio. Cada entrada SSH es solo otro visor/controlador del mismo objeto.
No existe una copia de la sesion dentro de `sshd`.

| Componente | Se ejecuta como | Responsabilidad | Persistencia |
|---|---|---|---|
| `sshd` dedicado | root mientras escucha; OpenSSH reduce privilegios por conexion | TCP, criptografia, autenticacion, PAM y PTY exterior | Servicio del sistema |
| `superterm --ssh-entry` | usuario autenticado | Validar que es una entrada interactiva, resolver la sesion y hacer attach o crearla | Dura lo que el cliente SSH |
| daemon SuperTerm de sesion | mismo usuario | Poseer PTYs, procesos, escritorio y sockets de clientes | Sobrevive a cero visores |
| procesos de los panes | mismo usuario | Shells y aplicaciones elegidas por el perfil/clase | Viven dentro de la sesion |
| `ssh(1)` remoto | usuario del equipo cliente | Verificar la host key, aportar credenciales y transportar el terminal | Dura lo que la conexion |

No debe confundirse el daemon `sshd` global con los daemons SuperTerm por
usuario y sesion. Reiniciar el listener SSH no equivale a cerrar escritorios:
systemd usa `KillMode=process` y launchd `AbandonProcessGroup`, y los daemons
SuperTerm ya viven en sesiones/grupos de proceso independientes.

Conceptualmente, cada conexion pasa del listener root a la separacion de
privilegios de OpenSSH: monitor privilegiado, autenticacion y proceso de
sesion reducido al UID/GID/grupos autenticados. La forma exacta y los nombres
de esos procesos pueden variar entre versiones de OpenSSH. Al crear una
sesion, SuperTerm usa `setsid` y doble `fork`; el daemon final queda separado
del PTY SSH y reparentado al recolector del sistema, con entrada/salida estandar
en `/dev/null`. Los procesos de pane quedan bajo ese daemon. Para una entrada
root, naturalmente, el tramo SuperTerm y sus panes conservan UID 0.

La instancia posee claves y `sshd_config` propios, pero reutiliza
deliberadamente la politica PAM del servicio `sshd` del host —normalmente
`/etc/pam.d/sshd`—, incluidos hooks de cuenta, credenciales y apertura/cierre
de sesion. Separar `/etc/superterm/sshd` no aisla ni duplica PAM.

## Recorrido exacto de una conexion

1. `ssh` conecta a una direccion y puerto declarados en `listen`. El cliente
   verifica la clave de **host** de esta instancia, independiente de la del
   `sshd` ordinario del equipo.
2. OpenSSH negocia el canal cifrado y autentica una cuenta conocida por NSS.
   Segun `server.ini`, acepta una contrasena admitida por PAM, una clave
   publica autorizada o cualquiera de las dos.
3. OpenSSH exige que la cuenta tenga un shell existente y ejecutable. La
   politica PAM configurada puede denegarla por bloqueo, caducidad, horario u
   otra regla incluso despues de aceptar una clave. Despues abre la sesion
   PAM, crea un PTY y baja el proceso al UID/GID y grupos de esa cuenta.
4. `ForceCommand` sustituye cualquier shell solicitado por la ruta fija
   `superterm --ssh-entry`. OpenSSH la entrega al shell de login de la cuenta
   con `-c`; la ruta se valida como literal seguro y ningun texto remoto se
   concatena a ella. La configuracion ya ha rechazado forwarding, X11, agente,
   entorno de cliente, RC de usuario y subsistemas.
5. La entrada comprueba `SSH_CONNECTION` y `SSH_TTY`. Tambien exige que
   `SSH_ORIGINAL_COMMAND` no exista: incluso un comando remoto vacio se
   considera una peticion `exec` y se rechaza.
6. SuperTerm resuelve una sesion para **esa cuenta**, nunca para todo el
   sistema. En modo `last` prueba la ultima sesion viva; despues usa
   `default_session`, `default_profile` y finalmente `session`.
7. Un bloqueo POSIX por usuario y nombre serializa la primera creacion. Dos
   logins simultaneos pueden terminar adjuntos al mismo daemon, pero no
   publicar dos sesiones con el mismo nombre.
8. Si el socket ya esta vivo, se hace attach. Si no existe, el primer cliente
   construye el perfil —o un escritorio vacio—, publica el daemon y se
   reconecta a el por el mismo protocolo Unix.
9. La salida de los panes llega al daemon, este actualiza el estado canonico y
   transmite el resultado a todos los visores. La entrada por teclado se
   procesa en orden; las operaciones estructurales usan las reglas de revision
   y bloqueo de pane de la sesion compartida.
10. Detach, cierre del emulador, timeout o perdida de red eliminan solo ese
    visor. OpenSSH cierra el canal y su PTY exterior; el EOF del socket Unix
    hace `DropClient`, no `FRAME_CLOSE`. Los panes y su daemon siguen vivos y
    la siguiente conexion recibe un snapshot canonico.

El cifrado termina en OpenSSH en el mismo host. Desde ahi hasta el daemon de
sesion se usa un socket local protegido por permisos Unix. No hay doble
cifrado, serializacion SSH propia ni claves privadas dentro de SuperTerm.

## Tres tipos de clave que no deben mezclarse

| Elemento | Donde esta | Quien posee el secreto | Para que sirve |
|---|---|---|---|
| Clave de host `ssh_host_ed25519_key` | servidor, `/etc/superterm/sshd` | root del servidor | Identifica el servicio ante los clientes |
| Clave publica autorizada | servidor, almacen central o `~/.ssh/authorized_keys` | No contiene secreto | Autoriza una identidad de cliente para una cuenta |
| Clave privada de usuario | equipo cliente, normalmente `~/.ssh/id_*` | Usuario del cliente | Demuestra que posee la clave publica autorizada |

`authorize` recibe solamente el fichero `.pub`. Copiar una clave privada al
servidor no es necesario y reduce la seguridad. La entrada que aparece en
`known_hosts` tampoco autoriza al usuario: protege al cliente frente a un
servidor falso.

## Estado persistente

La configuracion, la identidad de host y el almacen central de esta instancia
estan separados del SSH normal del sistema:

```text
/etc/superterm/sshd/
|-- .admin.lock
|-- server.ini
|-- sshd_config.generated
|-- ssh_host_ed25519_key
|-- ssh_host_ed25519_key.pub
`-- authorized_keys/
    |-- german
    `-- root
```

SuperTerm no modifica `/etc/ssh`. Segun `user_authorized_keys`, OpenSSH puede
leer tambien el `~/.ssh/authorized_keys` normal de la cuenta, pero SuperTerm no
lo escribe ni lo borra. Usa exclusivamente el `sshd` de sistema en
`/usr/sbin/sshd` o `/usr/bin/sshd` y comprueba que `/etc/ssh` sea una ruta
protegida. OpenSSH ejecutaria
`/etc/ssh/sshrc` antes incluso del `ForceCommand` aunque se configure
`PermitUserRC no`; como no existe una directiva que lo desactive, SuperTerm
rechaza el arranque si ese fichero existe. Esta comprobacion explicita evita
prometer un aislamiento que OpenSSH no puede proporcionar por configuracion.
El directorio, la configuracion y los ficheros centrales de claves autorizadas
pertenecen a root y no son escribibles por otros usuarios. La clave privada de
host usa modo `0600`. Las claves autorizadas son publicas y cada fichero
central se llama como un usuario real del sistema. Con `StrictModes yes`,
OpenSSH comprueba igualmente propietario y permisos del home y del
`authorized_keys` particular antes de aceptar una clave de usuario.

`sshd_config.generated` es un artefacto: no debe editarse. SuperTerm construye
un candidato, lo comprueba con el mismo `sshd` que va a ejecutarlo y solo lo
reemplaza si pasan `sshd -t` y `sshd -T`. Una actualizacion conserva
`server.ini`, la identidad del servidor y todas las autorizaciones.

`server.ini` es el estado pendiente y `sshd_config.generated` es el ultimo
estado aceptado. `check` valida el pendiente sin publicarlo. `restart` publica
temporalmente un candidato ya validado, reinicia y comprueba salud; si algo
falla intenta restaurar el artefacto, descriptor y estado de servicio
anteriores. El wrapper vuelve a validar en cada arranque las directivas que
SuperTerm fija como frontera de seguridad. No pretende fijar todos los
cifrados, KEX, MAC, algoritmos de clave ni la politica PAM del OpenSSH
instalado.

El estado de cada cuenta no se guarda en `/etc/superterm/sshd`:

```text
~/.superterm/
|-- superterm.ini                 preferencias y ruta SSH de ese usuario
`-- sessions/
    |-- NOMBRE.ini               identidad/metadatos del daemon vivo
    `-- NOMBRE.sock              transporte local privado, modo 0600
```

Los procesos y el contenido de pantalla estan vivos en memoria en el daemon,
no serializados en `NOMBRE.ini`. El sidecar publica metadatos de descubrimiento,
incluidos PID e identidad de nacimiento; la frontera real de conexion es el
directorio privado, el socket `0600` y su listener vivo. Al retirar una sesion,
el daemon comprueba que sigue poseyendo el inode del socket antes de borrarlo.
Eliminar esos ficheros a mano mientras el daemon vive no es una forma valida
de cerrar una sesion. Debe usarse el menu de SuperTerm o su CLI de sesiones.

| Estado | Sobrevive a desconectar SSH | Sobrevive a reiniciar `sshd` | Sobrevive a reiniciar el host |
|---|---|---|---|
| Daemon, panes y procesos SuperTerm | Si | Si | No |
| Preferencias/perfiles del usuario | Si | Si | Si |
| Host key y claves autorizadas centrales | Si | Si | Si |
| Ruta `ssh_last_session` | Si | Si | Si, pero solo se usa si la sesion sigue viva |

Una sesion viva es su propia restauracion exacta: detach no guarda ni vuelve a
cargar un escritorio. Tras reiniciar el host ya no existe ese proceso vivo;
la siguiente entrada crea una sesion nueva desde el perfil configurado.

## Configuracion

El formato publico y estable es `/etc/superterm/sshd/server.ini`:

```ini
[server]
config_version=1
listen=127.0.0.1:8022,[::1]:8022
allow_root=0
password_authentication=1
managed_authorized_keys=1
user_authorized_keys=1
```

`listen` es una lista de uno a 32 endpoints TCP separados por comas. Cada
elemento lleva su propio puerto, entre 1 y 65535, de modo que se pueden combinar
interfaces y puertos distintos. Esta version no abre listeners UDP:

```ini
listen=127.0.0.1:8022,[::1]:8022,192.0.2.20:2222,[2001:db8::20]:2222
```

IPv6 siempre va entre corchetes. Para escuchar en todas las interfaces se
usan explicitamente `0.0.0.0` y `[::]`. El valor inicial solo escucha en
loopback; publicar el servicio en una red requiere cambiarlo deliberadamente.

`allow_root=0` rechaza a root aunque exista
`authorized_keys/root`. Con `allow_root=1` root sigue limitado a clave publica
y a la interfaz SuperTerm forzada: nunca se admite la contrasena de root.

Las tres opciones de autenticacion son independientes:

- `password_authentication=1` admite una contrasena a traves de la politica
  PAM del servicio `sshd`. SuperTerm no recibe ni guarda esa contrasena.
  `KbdInteractiveAuthentication` permanece
  desactivado para no publicar dos caminos equivalentes de contrasena.
- `managed_authorized_keys=1` lee las claves administradas por SuperTerm en
  `/etc/superterm/sshd/authorized_keys/USUARIO`.
- `user_authorized_keys=1` reutiliza las claves publicas normales de cada
  cuenta en `.ssh/authorized_keys`. Las claves privadas nunca se copian al
  servidor: permanecen en el cliente SSH.

La politica efectiva resultante es:

| Contrasena | Alguna fuente de claves | Resultado para usuarios normales | Resultado para root |
|---|---|---|---|
| `0` | si | Solo clave publica | Solo clave si `allow_root=1` |
| `1` | no | Solo contrasena/PAM | Exige `allow_root=0`; con `allow_root=1` toda la configuracion es invalida |
| `1` | si | Contrasena **o** clave publica | Solo clave si `allow_root=1` |
| `0` | no | Configuracion invalida | Configuracion invalida |

Cuando ambos caminos estan activos, `AuthenticationMethods any` significa
"cualquiera de los metodos habilitados", no "sin autenticacion". SuperTerm
comprueba esa semantica en la salida efectiva de `sshd -T`. No configura una
autenticacion de dos factores; para eso haria falta una politica distinta y
pruebas especificas.

Al menos uno de esos caminos debe quedar habilitado. `allow_root=1` exige
ademas alguna fuente de claves porque la contrasena de root continua prohibida.
Un `server.ini` nuevo escribe explicitamente `1/1/1`. Por seguridad, un
fichero version 1 creado por una version anterior que no contenga estas tres
claves conserva su antigua politica `0/1/0`; basta anadirlas explicitamente y
ejecutar `check` y `restart` para adoptar la nueva politica.

Tras editar `server.ini`, validar antes de reiniciar:

```sh
sudo superterm ssh-server check
sudo superterm ssh-server restart
```

Una configuracion invalida no sustituye la ultima configuracion generada ni
detiene un servicio que ya funciona.

## Ejemplo aplicado: acceso de `german` y `root`

Las cuentas deben existir en la base de usuarios del sistema. Para que
`german` entre con contrasena o clave y `root` solo con clave, la seccion es:

```ini
[server]
config_version=1
listen=192.168.0.214:8022
allow_root=1
password_authentication=1
managed_authorized_keys=1
user_authorized_keys=1
```

Despues se autoriza, como minimo, una clave publica para root. Puede
autorizarse otra para `german`; si no, `german` aun puede usar una contrasena
que la politica PAM de `sshd` acepte para esa cuenta:

```sh
sudo superterm ssh-server authorize german /ruta/cliente_superterm.pub
sudo superterm ssh-server authorize root /ruta/cliente_superterm.pub
sudo superterm ssh-server check
sudo superterm ssh-server restart
sudo superterm ssh-server list-keys german
sudo superterm ssh-server list-keys root
```

No se activa una contrasena especial de SuperTerm. OpenSSH consulta la
politica PAM de `sshd`, que puede usar `pam_unix`, LDAP u otro backend del
host. `PermitRootLogin`
se genera como `prohibit-password`, por lo que una contrasena de root nunca
funciona en este servicio aunque `password_authentication=1`.

Estas opciones no son una lista exclusiva de usuarios. Con contrasena y
`user_authorized_keys` habilitados, cualquier otra cuenta NSS valida que pase
PAM y tenga un shell ejecutable puede autenticarse bajo la misma politica.
`allow_root` solo decide la excepcion de root. Limitar el servicio
exclusivamente a `german` y `root` requeriria una allowlist explicita en una
version futura o una restriccion equivalente en la politica PAM del host.

Comandos de conexion para ese ejemplo:

```sh
ssh -p 8022 german@192.168.0.214
ssh -p 8022 root@192.168.0.214
```

Si la clave privada tiene un nombre no estandar:

```sh
ssh -tt -o IdentitiesOnly=yes \
  -i ~/.ssh/superterm_192_168_0_214_ed25519 \
  -p 8022 german@192.168.0.214
```

`-tt` fuerza el PTY; desde una terminal interactiva ordinaria suele bastar
sin el. `IdentitiesOnly=yes` evita probar otras claves del agente y resulta
util para diagnostico, pero tampoco es obligatorio cuando la clave esperada
ya es una identidad normal del cliente.

## Instalacion y servicio

El binario `sshd` debe estar instalado. En Debian/Ubuntu lo aporta
`openssh-server`; macOS incluye `/usr/sbin/sshd`. SuperTerm usa una instancia
propia en primer plano, supervisada por systemd en GNU/Linux o por un
LaunchDaemon en macOS.

La preparacion es idempotente:

```sh
sudo superterm ssh-server setup
sudo superterm ssh-server status
```

`setup` crea `server.ini` y la clave de host Ed25519 solo cuando faltan. En
cada ejecucion vuelve a construir y validar el artefacto generado y el
descriptor del servicio, y despues habilita el servicio al arranque. Nunca
reemplaza la clave **privada**, las autorizaciones ni el `server.ini`
existente; normaliza la privada a `0600` y puede regenerar su mitad publica si
falta o no corresponde a ella.

En una instalacion real, la ruta absoluta de `superterm` y todos sus
directorios antecesores deben pertenecer a root y no ser escribibles por grupo
u otros usuarios. Esto evita que alguien sustituya el `ForceCommand`. En
macOS conviene usar una jerarquia dedicada protegida por root, por ejemplo
`/opt/superterm/bin`. `/usr/local/bin` solo sirve si ese directorio y todos sus
antecesores tambien pertenecen a root y no son escribibles por otros; una ruta
Homebrew escribible por un usuario sera rechazada deliberadamente para este
servicio privilegiado.

`make install` solo copia el programa y nunca habilita por sorpresa un servicio
privilegiado. Tras una primera instalacion, o despues de actualizar el binario,
se ejecuta `sudo superterm ssh-server setup` para construir y validar el
descriptor correspondiente a esa version. La operacion conserva
`server.ini`, las claves y las autorizaciones.

Administracion del servicio:

```sh
sudo superterm ssh-server enable
sudo superterm ssh-server disable
sudo superterm ssh-server restart
sudo superterm ssh-server status
```

Cada orden tiene un alcance deliberadamente distinto:

| Orden | Lee el pendiente | Publica configuracion | Cambia el gestor de servicios |
|---|---:|---:|---:|
| `setup` | Si | Si, tras validar | Instala/actualiza y habilita el descriptor |
| `check` | Si | No | No |
| `restart` | Si | Si, tras validar | Reinicia y comprueba salud; revierte si falla |
| `enable` | No; usa el artefacto aceptado | No | Habilita y arranca |
| `disable` | No | No | Detiene y deshabilita el listener |
| `status` | No | No | Solo consulta |
| `uninstall-service` | No | No | Retira un descriptor reconocido como propio |

La administracion toma un bloqueo exclusivo con espera acotada. Los cambios
se escriben en ficheros temporales regulares con `O_EXCL`/`O_NOFOLLOW`, se
validan y se renombran dentro del directorio protegido. `restart` captura el
artefacto generado, el descriptor y el estado previo del servicio; si la
activacion o la comprobacion de salud falla, intenta restaurar exactamente los
tres. Las claves de host, las autorizaciones y `server.ini` nunca se borran
como parte de ese rollback.

El bloqueo cubre las operaciones que validan o mutan estado, incluido
`check`. `status` y la ayuda solo consultan sin tomarlo; `list-keys` asegura
primero el arbol protegido y despues enumera, tambien sin ese bloqueo. El
wrapper exclusivo `run` tampoco es una lectura ni una operacion administrativa:
valida el artefacto publicado y arranca el listener. Todos ven generaciones
completas porque la publicacion usa renombres atomicos.

El comando interno `ssh-server run` no es el camino de administracion. Es el
wrapper usado por systemd/launchd: vuelve a validar el artefacto aceptado con
el `sshd` instalado y finalmente hace `exec` de `sshd -D -e`. Por eso el PID
principal del servicio termina siendo el propio OpenSSH y no queda un
supervisor SuperTerm adicional.

Rutas del gestor y runtime:

- GNU/Linux: `/etc/systemd/system/superterm-sshd.service` y
  `/var/run/superterm-sshd.pid`.
- macOS: `/Library/LaunchDaemons/org.superterm.sshd.plist` y el mismo PID file
  privado bajo `/var/run`.

`restart` no habilita un servicio que ya se deshabilito. Despues de `disable`
se usa `enable`; `setup` tambien prepara y habilita una instalacion completa.

Para retirar solo la integracion con el gestor de servicios:

```sh
sudo superterm ssh-server uninstall-service
```

El comando detiene y deshabilita exclusivamente el descriptor que reconoce
como propio. Conserva `server.ini`, las claves de host y todas las claves
autorizadas en `/etc/superterm/sshd`, de modo que una reinstalacion mantiene la
identidad. Un marcador de propiedad versionado y los campos invariantes del
servicio permiten reconocer de forma estricta un descriptor de una version
anterior aunque evolucione su contenido. `make uninstall` ejecuta primero esta
misma operacion; con `DESTDIR`
solo modifica el arbol de empaquetado y nunca el gestor del host. Una
desinstalacion local sin privilegios tampoco toca el gestor: un servicio root
valido no puede apuntar a ese binario propiedad del usuario.

En GNU/Linux la salida de `sshd -e` queda en el journal de la unidad. El
descriptor macOS no configura `StandardOutPath` ni `StandardErrorPath`, por lo
que no promete un fichero persistente equivalente; `ssh-server status` muestra
el estado y el ultimo resultado que conserva launchd. Los fallos del cliente y
del daemon de sesion siguen usando `SUPERTERM_DEBUG`, `SUPERTERM_CRASH_DIR` y
los mecanismos descritos en `DEBUGGING.md` y `HEAP_DEBUGGING.md`.

## Autorizar claves centrales

El almacen central se modifica solamente mediante el administrador de
SuperTerm. Este valida el usuario, el fichero y la clave con las herramientas
OpenSSH, rechaza opciones de `authorized_keys`, descarta los comentarios no
autenticados, evita duplicados y reemplaza el fichero de forma atomica:

```sh
sudo superterm ssh-server authorize german /ruta/id_ed25519.pub
sudo superterm ssh-server list-keys german
sudo superterm ssh-server revoke german SHA256:HUELLA
```

Autorizar o revocar afecta a autenticaciones nuevas; no expulsa clientes que
ya estan conectados. Los comandos tienen tambien sus alias espanoles indicados
por `superterm ssh-server help`. Estos comandos no modifican el
`.ssh/authorized_keys` particular; ese segundo almacen sigue bajo el control
normal de su usuario y conserva toda la semantica de OpenSSH. Por ejemplo,
puede contener opciones que restrinjan aun mas una entrada o una linea
`cert-authority`. Ninguna opcion particular puede relajar el `ForceCommand` o
las prohibiciones globales; una opcion `no-pty` puede autenticar la clave pero
hace que la entrada SuperTerm se rechace por carecer de PTY.

## Conexion y sesiones

Conexion interactiva normal:

```sh
ssh -p 8022 german@192.168.0.214
```

Un cliente interactivo solicita PTY automaticamente. `ssh -tt` solo es
necesario al invocarlo desde un entorno sin terminal o que no quiera asignarlo.
OpenSSH prueba sus claves habituales; si ninguna coincide y la contrasena esta
habilitada, pide la contrasena que validara PAM para `german`. En la primera conexion muestra
la huella de la clave de host y la conserva en el `known_hosts` del cliente.
La opcion `-p` debe preceder al destino en la sintaxis portable de OpenSSH.

Para reducirlo incluso a `ssh superterm`, puede guardarse esto en el cliente,
sin reemplazar ninguna otra entrada de `~/.ssh/config`:

```sshconfig
Host superterm
    HostName 192.168.0.214
    Port 8022
    User german
    RequestTTY force
```

Si se usa una clave con un nombre no estandar, se anade tambien una linea
`IdentityFile ~/.ssh/NOMBRE_DE_LA_CLAVE`.

La entrada SSH resuelve la sesion por usuario con estas opciones de
`~/.superterm/superterm.ini`:

- `ssh_session=last` (predeterminado) vuelve a la ultima sesion a la que ese
  usuario entro correctamente por SSH. Si la pista no existe o el daemon ya
  no vive, usa `default_session`, despues `default_profile` y por ultimo
  `session`.
- `ssh_session=default` ignora la ultima ruta y entra siempre en esa cadena
  predeterminada.
- `ssh_last_session` es una pista privada que SuperTerm actualiza
  atomicamente solo despues de un attach correcto. No guarda escritorios,
  panes, geometria ni procesos y no debe editarse normalmente.

Si esa sesion ya vive, se hace attach sin cambiar su geometria. Si no existe,
la primera conexion la crea con `default_profile`; un perfil inexistente o no
configurado produce un escritorio vacio. `default_session` decide el **nombre**
de la sesion, no su contenido inicial. La geometria inicial procede de ese
primer PTY. Un bloqueo por usuario y nombre impide que dos conexiones
simultaneas creen dos daemons.

Desde el menu `Sessions` se puede crear otra sesion en cualquier momento. El
dialogo pide un nombre y el perfil de partida, e incluye
`<Empty (no profile)>` para comenzar con un escritorio sin ventanas. El menu
`Profiles` permite crear antes un perfil vacio o guardar el escritorio actual
como perfil. Crear o cambiar de sesion solo separa el cliente de la anterior;
no destruye el daemon anterior. Con `ssh_session=last`, al hacer detach y
conectar de nuevo se recibe exactamente esa nueva sesion, no una sesion fija
anterior.

Detach desde el menu, cierre de la ventana SSH o perdida de red conservan la
sesion. `Exit` es distinto: envia un cierre explicito de sesion; si quedan
otros visores solo sale ese cliente, y si era el ultimo detiene y elimina la
sesion. Con cero visores, una sesion cuyos panes hayan muerto todos puede
autorecolectarse tras su periodo de gracia; un escritorio deliberadamente
vacio, con cero panes, permanece disponible para reattach.

### Varios clientes sobre la misma sesion

Attach no crea una geometria privada. Todos reciben el mismo arbol de panes,
posiciones, tamanos, estado minimizado/maximizado/fullscreen, foco compartido,
contenido y orden de salida. Un cliente que no quepa fisicamente muestra esa
misma vista dentro de su terminal; no obliga al daemon a fabricar un segundo
escritorio.

La conexion de un visor por si sola no redimensiona los PTYs. Un cambio de
tamano posterior que el programa acepta es una operacion canonica y se
propaga a todos. Cuando las geometrías de los hosts difieren, las operaciones
que necesitan un area comun —como fullscreen sincronizado— se limitan al
viewport minimo compatible. El passthrough crudo de fullscreen (`prefijo f`,
`Ctrl-Q f` por defecto) solo se usa cuando las
geometrias fisicas coinciden; en caso contrario permanece el renderer IDE
compartido.

La escritura de varios clientes se entrega en el orden en que el reactor la
acepta. Los cambios estructurales de una ventana se serializan con revision y
bloqueo por pane, de modo que dos usuarios pueden actuar a la vez sobre panes
distintos sin mezclar commits. El portapapeles de SuperTerm es la excepcion
intencionada: es memoria local del cliente y no viaja por la sesion.

Cada daemon admite como maximo ocho visores interactivos. Las conexiones
efimeras del CLI de control se gestionan en slots separados y no consumen uno
de esos ocho. La salida hacia cada visor tiene un buffer acotado: un cliente
que deja de leer y supera el umbral de atasco se desconecta de forma
independiente, sin bloquear los PTYs ni a los demas.

Cliente y daemon deben hablar la misma version del protocolo de attach
(`ATTACH_PROTO_VER`, actualmente 15). Tras actualizar el binario, un daemon
antiguo puede rechazar un cliente nuevo —o al reves— en lugar de interpretar
un snapshot incompatible. Se cierra de forma explicita esa sesion antigua o
se usa temporalmente un cliente de su misma version; nunca se fuerza el attach.

## Verificacion y diagnostico

### Comprobacion despues de instalar o actualizar

```sh
sudo superterm ssh-server check
sudo superterm ssh-server status
sudo superterm ssh-server list-keys german
ssh -vv -p 8022 german@192.168.0.214
```

`check` solo valida el `server.ini` pendiente. Para verificar exactamente lo
que esta ejecutando OpenSSH se puede inspeccionar el artefacto aceptado:

```sh
sudo /usr/sbin/sshd -T \
  -f /etc/superterm/sshd/sshd_config.generated
```

En sistemas usrmerge el binario puede estar en `/usr/bin/sshd`; SuperTerm
elige y valida una de esas dos rutas protegidas. En la salida efectiva deben
aparecer, entre otros, el `listenaddress` deseado, el `forcecommand` absoluto,
`disableforwarding yes`, las fuentes exactas de `authorizedkeysfile` y la
combinacion esperada de `passwordauthentication`, `pubkeyauthentication` y
`authenticationmethods`.

En GNU/Linux, los eventos del listener se consultan con:

```sh
sudo journalctl -u superterm-sshd.service -b
```

`LogLevel VERBOSE` permite ver cuenta, origen, metodo y huella de la clave
aceptada sin registrar contrasenas ni claves privadas. En macOS se usa
`superterm ssh-server status` y las herramientas de log de launchd; el
descriptor no promete un fichero de texto privado.

### Fallos frecuentes

| Sintoma | Causa probable | Comprobacion segura |
|---|---|---|
| `Connection refused` | Servicio parado o direccion/puerto no publicado | `ssh-server status`, `server.ini`, listener del sistema |
| `Address already in use` al activar | Otro proceso ocupa una direccion/puerto de `listen` | Identificar el listener; no matar procesos sin verificar su propietario |
| Timeout antes de autenticar | Interfaz equivocada o firewall | Comparar IP de destino con cada entrada `listen` |
| Aviso de host key desconocida | Primera conexion a esta instancia/puerto | Comparar con `ssh-keygen -lf /etc/superterm/sshd/ssh_host_ed25519_key.pub` en el servidor |
| Host key cambiada | Se sustituyo la identidad o se conecta a otro equipo | No borrar `known_hosts` a ciegas; verificar primero la huella del servidor |
| `Permission denied (publickey)` | Clave privada equivocada, publica no autorizada o permisos rechazados por `StrictModes` | `ssh -vv`, `list-keys`, propietario/modos de `~/.ssh` |
| Pide contrasena aunque hay clave | Ninguna identidad ofrecida fue aceptada | Probar `IdentitiesOnly=yes -i RUTA` y revisar la huella, no copiar privadas al servidor |
| `root` no entra por contrasena | Comportamiento obligatorio | Usar clave y comprobar `allow_root=1` |
| `interactive SSH PTY is required` | `ssh -T`, tuberia sin PTY o cliente no interactivo | Solicitar PTY con `-t`/`-tt` |
| `remote commands and subsystems are disabled` | Se envio comando, SCP o SFTP | Entrar sin comando; esas funciones no forman parte del servicio |
| Vuelve a otra sesion | La ultima ya no vive, se usa modo `default`, o la pista pertenece a otro usuario | Revisar `[session]`, `superterm --list-sessions` bajo esa cuenta |
| La conexion cae pero panes siguen | Detach por EOF/keepalive | Es el comportamiento esperado; reconectar |
| `check` rechaza `/etc/ssh/sshrc` | OpenSSH lo ejecutaria fuera del control de `ForceCommand` | Auditar/retirar ese hook global; no omitir la validacion |
| Rechazo de ruta no protegida | El binario o un directorio antecesor es escribible/no pertenece a root | Instalar en una jerarquia root y volver a ejecutar `setup` |
| Clave publica de host ausente o distinta | El `.pub` no deriva de la privada conservada | `setup` puede reparar solo la mitad publica; verificar despues la huella |
| `protocol version ... need ...` | Cliente y daemon pertenecen a builds incompatibles | Cerrar expresamente la sesion antigua o usar el binario coincidente |

Nunca se debe depurar pasando una contrasena en argv, en `server.ini`, en una
URL o en un log. `sshpass` solo pertenece a clases de pane SSH **salientes**;
no participa en la autenticacion entrante de este servicio.

### Pruebas automatizadas que cubren la integracion

Despues de construir el binario de pruebas, las comprobaciones principales
son:

```sh
make test-runtime
SUPERTERM_TEST_BIN="$PWD/bin/superterm-test" \
  python3 test/ssh_server_config_test.py
SUPERTERM_TEST_BIN="$PWD/bin/superterm-test" \
  python3 test/ssh_entry_test.py
SUPERTERM_TEST_BIN="$PWD/bin/superterm-test" \
  python3 test/ssh_transport_test.py
SUPERTERM_TEST_BIN="$PWD/bin/superterm-test" \
  python3 test/ssh_service_uninstall_test.py
```

- `ssh_server_config_test.py` usa un `sshd` real para validar la matriz de
  autenticacion, `-t`, `-T`, publicacion atomica, rollback, permisos, claves y
  politica fail-closed.
- `ssh_entry_test.py` prueba creacion simultanea, seleccion `last/default`,
  detach, reattach, perfil y escritorio vacio sobre el protocolo de sesion.
- `ssh_transport_test.py` levanta un listener TCP OpenSSH aislado y entra con
  el cliente `ssh` estandar; cubre dos visores, perdida abrupta, resize,
  rechazo de exec/SFTP/forwarding y reattach.
- `ssh_service_uninstall_test.py` prueba propiedad del descriptor, fallos del
  gestor, rollback y que la desinstalacion preserve todo `/etc/superterm/sshd`.

La bateria completa se ejecuta con `make test`. Algunos caminos de privilegio
se omiten de forma explicita si la cuenta de prueba no permite reproducirlos;
un `SKIP` identificado no debe presentarse como una prueba ejecutada.

## Mapa de implementacion y fuentes auditadas

El flujo SuperTerm se puede seguir sin saltos en estas unidades:

| Fichero | Puntos principales |
|---|---|
| [`src/st_ssh_server.pas`](../src/st_ssh_server.pas) | `BuildGeneratedConfig`, validacion efectiva `sshd -T`, activacion/rollback, systemd/launchd y administracion de claves |
| [`src/st_ssh_entry.pas`](../src/st_ssh_entry.pas) | `PrepareSshEntry`, bloqueo de primera creacion, ruta `last/default` y actualizacion de `ssh_last_session` |
| [`src/superterm.lpr`](../src/superterm.lpr) | Despacho temprano de `ssh-server` y del argumento reservado `--ssh-entry` |
| [`src/st_fvui.pas`](../src/st_fvui.pas) | Construccion diferida del perfil, attach y promocion del workspace al daemon |
| [`src/st_server.pas`](../src/st_server.pas) | Socket Unix, protocolo v15, snapshots, reactor, clientes, PTYs, `DropClient` y doble fork |
| [`src/st_config.pas`](../src/st_config.pas) | Lectura y escritura atomica de la politica de ruta SSH por usuario |

La referencia OpenSSH Portable auditada es `V_10_5_P1`, commit
[`b3f7344209832eea8ece447d871ea748767c444b`](https://github.com/openssh/openssh-portable/commit/b3f7344209832eea8ece447d871ea748767c444b).
En la copia de estudio `/opt/openssh-portable-10.5p1` se verificaron:

- `sshd.c` para carga de host keys y listener;
- `sshd-session.c` para separacion de privilegios pre/post-auth;
- `auth.c`, `auth2-pubkey.c` y `auth2-pubkeyfile.c` para cuenta,
  `AuthorizedKeysFile`, firma y `StrictModes`;
- `auth-passwd.c` y `auth-pam.c` para password, control de cuenta,
  credenciales y sesion PAM;
- `session.c` para PTY, `SIGWINCH`, `ForceCommand`, entorno, RC y ejecucion
  del shell con `-c`;
- `serverloop.c` y `monitor.c` para cierre de canales, PTY y monitor.

La copia de `/opt` es solo material de auditoria y no es una dependencia del
programa instalado. En ejecucion se usa exclusivamente el OpenSSH protegido
del sistema y se vuelve a comprobar su configuracion efectiva.

## Limites de seguridad y compatibilidad

- Solo se aceptan cuentas conocidas por NSS cuyo shell exista y sea
  ejecutable. La politica PAM de `sshd` puede aplicar bloqueo, caducidad,
  horario y otras reglas; su control de cuenta tambien se ejecuta despues de
  una clave publica valida.
- La autenticacion efectiva es exactamente `password`, `publickey` o
  cualquiera de ambos, segun `server.ini`. Keyboard-interactive, GSSAPI,
  hostbased, `TrustedUserCAKeys` global y comandos externos de autorizacion
  permanecen desactivados. Si se habilita el `authorized_keys` particular,
  ese fichero conserva opciones OpenSSH como `cert-authority`; el almacen
  central de SuperTerm solo admite claves simples sin opciones.
- `ssh host comando`, `ssh -T`, SCP/SFTP y cualquier forwarding se rechazan.
- El comando forzado usa una ruta absoluta de SuperTerm y no acepta texto del
  cliente.
- El wrapper rechaza `Match` e `Include`, comprueba la politica efectiva con
  `sshd -T` y no permite fuentes distintas de las dos configuradas, variables
  de entorno del cliente ni subsistemas.
- Los nombres de usuario, direcciones, puertos y claves se validan antes de
  llegar a un fichero de OpenSSH o a un proceso externo.
- El daemon SSH no interpreta el protocolo binario de sesiones y nunca expone
  el socket Unix por TCP.
- Un equipo necesita el binario OpenSSH `sshd`, una compilacion con PAM
  funcional para autenticar contrasenas y una plataforma soportada por
  SuperTerm/FPC. Por eso esta arquitectura puede reemplazar el acceso
  interactivo en servidores GNU/Linux y macOS compatibles, pero no literalmente
  en cualquier dispositivo embebido que solo disponga de Dropbear, carezca de
  PAM o no pueda ejecutar SuperTerm.

La implementacion delega deliberadamente en OpenSSH sus bucles `poll`,
autenticacion, PTY y recoleccion de hijos.
