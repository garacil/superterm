# Correccion de `htop` al restaurar sesiones

## Problema

Una sesion guarda para cada panel el comando (`cmd`) y, cuando procede, sus
argumentos (`argc` y `argN`) en `src/st_session.pas`. Al restaurar la sesion,
`src/st_fvui.pas` vuelve a crear el panel y entrega el comando guardado a
`TPty.Spawn`.

Antes del fix, un comando restaurado como `htop` se ejecutaba como el script
de un shell no interactivo:

```text
<shell> -l -c "htop"
```

Cuando se pulsaba `q` en `htop`, `htop` terminaba y tambien terminaba ese
shell `-c`. El panel ya no conservaba un shell interactivo al que volver.

## Solucion

En `src/st_fvui.pas:194` se anadio
`CommandWithInteractiveShell(const Command, Shell: string; LoginShell: boolean)`.
La funcion hace exactamente esto:

```pascal
Result := Trim(Command);
if Result = '' then
  Exit;
Result := Result + '; exec ' + ShellQuote(Shell);
if LoginShell then
  Result := Result + ' -l'
else
  Result := Result + ' -i';
```

Por tanto, el comando restaurado `htop` se convierte en:

```text
<shell> -l -c "htop; exec '<shell>' -l"
```

Si la configuracion no usa shell de login, el sufijo es `exec '<shell>' -i`.
`ShellQuote` cita el ejecutable del shell antes de incorporarlo al script.

La funcion se aplica a los dos formatos que puede restaurar una sesion:

- `Pin[i].Args`: primero se reconstruye con `ArgsAsShell` y despues se anade
  el shell interactivo.
- `Pin[i].Cmd`: se envuelve directamente de la misma forma.

Esto ocurre en `src/st_fvui.pas:950-956`. Los paneles sin comando siguen
pasando una cadena vacia a `StartPane`, que conserva el comportamiento normal
de lanzar directamente el shell de login.

`src/st_pty.pas:400-440` sigue siendo el responsable de ejecutar el script
con `<shell> -l -c` o `<shell> -c`. El cambio no modifica `htop` ni anade un
caso especial para ese programa: hace que cualquier comando restaurado vuelva
a un shell interactivo cuando termina. `exec` reutiliza el mismo proceso y el
mismo PTY, en lugar de crear un shell intermedio adicional.

## Comprobacion

`test/restore_test.py:89-128` construye una sesion con `/usr/bin/true`, que
termina inmediatamente, y despues escribe `echo RESTORED_SHELL` en el panel
restaurado. La comprobacion solo pasa si el comando terminado ha dejado un
shell interactivo funcionando. Ese caso reproduce el ciclo de vida de `htop`
sin depender de tiempos ni de la salida de una aplicacion de pantalla
completa.

El flujo pertenece al manejo de PTY propio de Superterm en GNU/Linux: Linux es
el kernel y el userland del proyecto GNU proporciona el shell y las utilidades
que ejecutan la cadena. No depende de tmux ni requiere modificar `htop`.
