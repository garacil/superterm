(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_cli_help - contextual command-line reference

  This is the single presentation point for public CLI help.  The command
  parser resolves aliases and passes a normalized topic here; every page then
  follows the same SYNOPSIS / ARGUMENTS / OPTIONS / BEHAVIOR / EXAMPLES shape.
  Keeping examples beside the exact accepted spellings makes the output useful
  to people, scripts which audit a release, and agents which must construct a
  command without guessing.
*)

unit st_cli_help;

{$mode objfpc}{$H+}

interface

uses
  st_config;

procedure PrintCliHelpIndex(ALanguage: TUiLanguage);
function PrintCliHelpTopic(const ANormalizedTopic: string;
  ALanguage: TUiLanguage): boolean;
procedure PrintSshServerHelp(ALanguage: TUiLanguage);

implementation

uses
  SysUtils;

procedure H(ALanguage: TUiLanguage; const AEnglish, ASpanish: string);
begin
  if ALanguage = ulSpanish then
    WriteLn(ASpanish)
  else
    WriteLn(AEnglish);
end;

procedure Blank;
begin
  WriteLn;
end;

procedure Page(ALanguage: TUiLanguage; const AEnglish, ASpanish: string);
begin
  H(ALanguage, AEnglish, ASpanish);
  H(ALanguage, StringOfChar('=', Length(AEnglish)),
    StringOfChar('=', Length(ASpanish)));
end;

procedure SeeAlso(ALanguage: TUiLanguage; const AEnglish, ASpanish: string);
begin
  H(ALanguage, 'SEE ALSO', 'VEASE TAMBIEN');
  H(ALanguage, '  ' + AEnglish, '  ' + ASpanish);
  Blank;
end;

procedure PrintCliHelpIndex(ALanguage: TUiLanguage);
begin
  H(ALanguage,
    'superterm ' + SUPERTERM_VERSION +
      ' - detachable terminal sessions for GNU/Linux and macOS',
    'superterm ' + SUPERTERM_VERSION +
      ' - sesiones de terminal separables para GNU/Linux y macOS');
  Blank;
  H(ALanguage, 'Usage:', 'Uso:');
  H(ALanguage, '  superterm [--session NAME]',
    '  superterm [--sesion NOMBRE]');
  H(ALanguage, '  superterm COMMAND [ARGUMENTS] [OPTIONS]',
    '  superterm ORDEN [ARGUMENTOS] [OPCIONES]');
  H(ALanguage, '  superterm --help [TOPIC]',
    '  superterm --ayuda [TEMA]');
  H(ALanguage, '  superterm help [TOPIC]',
    '  superterm ayuda [TEMA]');
  H(ALanguage, '  superterm -h [TOPIC]',
    '  superterm -h [TEMA]');
  H(ALanguage, '  superterm ''-?'' [TOPIC]',
    '  superterm ''-?'' [TEMA]');
  Blank;
  H(ALanguage, 'CONTEXTUAL HELP', 'AYUDA CONTEXTUAL');
  H(ALanguage,
    '  Use "superterm --help TOPIC" for complete syntax, behavior and examples.',
    '  Usa "superterm --ayuda TEMA" para sintaxis, conducta y ejemplos completos.');
  H(ALanguage,
    '  "superterm help TOPIC" and "superterm COMMAND --help" use the same page.',
    '  "superterm ayuda TEMA" y "superterm ORDEN --ayuda" usan la misma pagina.');
  H(ALanguage,
    '  Topic and command aliases are case-insensitive and accent-insensitive.',
    '  Los alias de temas y ordenes ignoran mayusculas y acentos.');
  Blank;
  H(ALanguage, 'MAIN TOPICS', 'TEMAS PRINCIPALES');
  H(ALanguage,
    '  superterm --help startup      interactive launch and legacy flags',
    '  superterm --ayuda inicio      arranque interactivo y flags antiguos');
  H(ALanguage,
    '  superterm --help targets      SESSION, SESSION:PANE and "." rules',
    '  superterm --ayuda destinos    reglas de SESION, SESION:PANEL y "."');
  H(ALanguage,
    '  superterm --help sessions     list, attach and terminate sessions',
    '  superterm --ayuda sesiones    listar, conectar y terminar sesiones');
  H(ALanguage,
    '  superterm --help panes        ordered input and screen capture',
    '  superterm --ayuda paneles     entrada ordenada y captura de pantalla');
  H(ALanguage,
    '  superterm --help windows      create, resize and arrange panes',
    '  superterm --ayuda ventanas    crear, ajustar y organizar paneles');
  H(ALanguage,
    '  superterm --help ssh          connect with a standard SSH client',
    '  superterm --ayuda ssh         conectar con un cliente SSH estandar');
  H(ALanguage,
    '  superterm --help ssh-server   configure the dedicated OpenSSH service',
    '  superterm --ayuda servidor-ssh  configurar el servicio OpenSSH dedicado');
  H(ALanguage,
    '  superterm --help reference    exit codes, language, aliases, version',
    '  superterm --ayuda referencia  codigos, idioma, alias y version');
  H(ALanguage,
    '  superterm --help all          complete deterministic reference',
    '  superterm --ayuda todo        referencia completa y determinista');
  Blank;
  H(ALanguage, 'COMMAND PAGES', 'PAGINAS DE ORDEN');
  H(ALanguage,
    '  list, attach, kill; send, capture; new, close, focus, rename, resize',
    '  listar, conectar, matar; enviar, capturar; nueva, cerrar, foco, renombrar, tamano');
  H(ALanguage,
    '  minimize, restore, zoom, organize',
    '  minimizar, restaurar, ampliar, organizar');
  Blank;
  H(ALanguage, 'QUICK EXAMPLES', 'EJEMPLOS RAPIDOS');
  H(ALanguage, '  superterm --help sessions',
    '  superterm --ayuda sesiones');
  H(ALanguage, '  superterm send prod:2 --key C-c',
    '  superterm enviar prod:2 --tecla C-c');
  H(ALanguage, '  superterm capture prod:Logs --history -o logs.txt',
    '  superterm capturar prod:Logs --historico -o logs.txt');
  H(ALanguage, '  ssh -p 8022 user@server',
    '  ssh -p 8022 usuario@servidor');
end;

procedure HelpStartup(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'STARTUP', 'INICIO');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm', '  superterm');
  H(ALanguage, '  superterm --session NAME',
    '  superterm --sesion NOMBRE');
  H(ALanguage, '  superterm attach [SESSION]',
    '  superterm conectar [SESION]');
  H(ALanguage, '  superterm --attach [SESSION]',
    '  superterm --attach [SESION]');
  H(ALanguage, '  superterm --list-sessions',
    '  superterm --list-sessions');
  H(ALanguage, '  superterm version',
    '  superterm version');
  H(ALanguage, '  superterm --version',
    '  superterm --version');
  H(ALanguage, '  superterm -V',
    '  superterm -V');
  Blank;
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage,
    '  --session NAME, --sesion NOMBRE  name the session created at launch',
    '  --session NAME, --sesion NOMBRE  nombra la sesion creada al arrancar');
  H(ALanguage,
    '  --attach [SESSION]                legacy spelling of attach',
    '  --attach [SESION]                 forma historica de conectar');
  H(ALanguage,
    '  --list-sessions                   legacy session table (exit 0 if empty)',
    '  --list-sessions                   tabla historica (sale 0 si esta vacia)');
  H(ALanguage,
    '  --help/--ayuda, -h, -? [TOPIC]    contextual help',
    '  --help/--ayuda, -h, -? [TEMA]     ayuda contextual');
  H(ALanguage,
    '  --version, -V, version            print exact release identity',
    '  --version, -V, version            imprime la identidad exacta');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  Plain startup opens the TUI. With server=always (the default), that',
    '  El arranque simple abre el IDE. Con server=always (predeterminado),');
  H(ALanguage,
    '  first visible terminal is already a client of its session daemon.',
    '  ese primer terminal visible ya es cliente del daemon de su sesion.');
  H(ALanguage,
    '  NAME keeps A-Z, a-z, 0-9, dot, underscore and hyphen; other bytes become',
    '  NOMBRE conserva A-Z, a-z, 0-9, punto, subrayado y guion; lo demas pasa');
  H(ALanguage,
    '  hyphens, leading dots/hyphens are removed, and the result is at most 64.',
    '  a guion, se quitan puntos/guiones iniciales y el maximo es 64.');
  H(ALanguage,
    '  If sanitizing removes the entire name, the resulting name is "sesion".',
    '  Si el saneado elimina todo el nombre, el resultado es "sesion".');
  H(ALanguage,
    '  If sessions already exist, plain startup offers their picker and New',
    '  Si ya hay sesiones, el arranque ofrece su selector y Nueva sesion,');
  H(ALanguage,
    '  session; creation asks for a name and a profile, including Empty.',
    '  que pregunta nombre y perfil de partida, incluido Vacio.');
  H(ALanguage,
    '  Attach never reshapes the desktop; Detach leaves panes/processes live.',
    '  Conectar no remodela el escritorio; Detach conserva paneles/procesos.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm --session incident-42',
    '  superterm --sesion incidencia-42');
  H(ALanguage, '  superterm attach prod',
    '  superterm conectar prod');
  H(ALanguage, '  superterm --attach          # picker when several are live',
    '  superterm --attach          # selector si hay varias vivas');
  H(ALanguage, '  superterm --list-sessions',
    '  superterm --list-sessions');
  Blank;
  SeeAlso(ALanguage, 'superterm --help sessions; superterm --help ssh',
    'superterm --ayuda sesiones; superterm --ayuda ssh');
end;

procedure HelpTargets(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'TARGETS', 'DESTINOS');
  H(ALanguage, 'GRAMMAR', 'GRAMATICA');
  H(ALanguage, '  SESSION          one live session',
    '  SESION           una sesion viva');
  H(ALanguage, '  SESSION:PANE     one pane inside that session',
    '  SESION:PANEL     un panel dentro de esa sesion');
  H(ALanguage, '  SESSION.PANE     legacy pane separator; prefer colon',
    '  SESION.PANEL     separador historico; se prefiere dos puntos');
  H(ALanguage, '  .                the only live session; focused pane if needed',
    '  .                la unica sesion viva; panel enfocado si hace falta');
  H(ALanguage, '  .:PANE           one pane of the only live session',
    '  .:PANEL          un panel de la unica sesion viva');
  H(ALanguage, '  .PANE or :PANE   legacy shorthand for .:PANE',
    '  .PANEL o :PANEL  abreviatura historica de .:PANEL');
  Blank;
  H(ALanguage, 'SESSION RESOLUTION', 'RESOLUCION DE SESION');
  H(ALanguage,
    '  Resolution tries exact name, sanitized name, unique case-insensitive',
    '  Se prueba nombre exacto, nombre saneado y prefijo unico sin distinguir');
  H(ALanguage,
    '  name and finally a unique case-insensitive prefix. "." is valid only',
    '  mayusculas. "." solo es valido cuando existe exactamente una sesion');
  H(ALanguage,
    '  when exactly one session is live. Ambiguity is an error, never a guess.',
    '  viva. Una ambiguedad es error: nunca se elige al azar.');
  H(ALanguage,
    '  Colon is unambiguous. With legacy SESSION.PANE, an existing whole dotted',
    '  Los dos puntos no son ambiguos. Con SESION.PANEL historico, una sesion');
  H(ALanguage,
    '  session name wins; otherwise the last dot separates its pane.',
    '  viva con ese nombre completo gana; si no, separa el ultimo punto.');
  Blank;
  H(ALanguage, 'PANE RESOLUTION', 'RESOLUCION DE PANEL');
  H(ALanguage,
    '  PANE is a 1-based index shown in the window title, or a unique',
    '  PANEL es el indice desde 1 mostrado en el titulo, o una subcadena');
  H(ALanguage,
    '  accent/case-insensitive title substring. Omitting :PANE selects the',
    '  unica del titulo sin distinguir acentos/mayusculas. Omitir :PANEL');
  H(ALanguage,
    '  focused pane. Commands report all candidates instead of guessing.',
    '  selecciona el panel enfocado. Una ambiguedad muestra candidatos.');
  Blank;
  H(ALanguage, 'COMMAND-SPECIFIC RULES', 'REGLAS SEGUN ORDEN');
  H(ALanguage,
    '  kill requires an explicit SESSION name; "." is rejected.',
    '  matar exige un nombre de SESION explicito; rechaza ".".');
  H(ALanguage,
    '  new accepts SESSION[:PANE]; PANE is the split anchor when present.',
    '  nueva acepta SESION[:PANEL]; PANEL es el ancla de la division.');
  H(ALanguage,
    '  organize accepts a SESSION, while pane operations require a TARGET.',
    '  organizar acepta SESION; las operaciones de panel exigen DESTINO.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm list production',
    '  superterm listar produccion');
  H(ALanguage, '  superterm send prod:2 uptime',
    '  superterm enviar prod:2 uptime');
  H(ALanguage, '  superterm capture prod:Logs --history',
    '  superterm capturar prod:Logs --historico');
  H(ALanguage, '  superterm focus .:Monitor',
    '  superterm foco .:Monitor');
  Blank;
  SeeAlso(ALanguage, 'superterm --help sessions; superterm --help panes',
    'superterm --ayuda sesiones; superterm --ayuda paneles');
end;

procedure HelpList(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'COMMAND: list', 'ORDEN: listar');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm list [SESSION]',
    '  superterm listar [SESION]');
  H(ALanguage, 'ALIASES', 'ALIAS');
  H(ALanguage, '  list, ls, listar', '  listar, list, ls');
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage, '  none', '  ninguna');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  Without SESSION, prints NAME PROFILE PANES CLIENTS CREATED for every',
    '  Sin SESION muestra NOMBRE PERFIL PANELES CLIENTES CREADA para cada');
  H(ALanguage,
    '  live session. With SESSION, prints each pane index, title, type, target,',
    '  sesion viva. Con SESION muestra indice, titulo, tipo, destino, comando,');
  H(ALanguage,
    '  command, terminal size and history. Flags are * focus, M minimized,',
    '  tamano e historial. Los flags son * foco, M minimizado, Z maximizado');
  H(ALanguage,
    '  Z IDE-maximized and ! dead. No sessions exits 1; the legacy',
    '  y ! muerto. Sin sesiones sale 1; el alias historico --list-sessions');
  H(ALanguage,
    '  --list-sessions spelling preserves its historical exit 0.',
    '  conserva su salida historica 0.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm list', '  superterm listar');
  H(ALanguage, '  superterm list prod', '  superterm listar prod');
  H(ALanguage, '  superterm ls prod', '  superterm ls prod');
  Blank;
  SeeAlso(ALanguage, 'superterm --help sessions; superterm --help targets',
    'superterm --ayuda sesiones; superterm --ayuda destinos');
end;

procedure HelpAttach(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'COMMAND: attach', 'ORDEN: conectar');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm attach [SESSION]',
    '  superterm conectar [SESION]');
  H(ALanguage, '  superterm --attach [SESSION]     (legacy spelling)',
    '  superterm --attach [SESION]      (forma historica)');
  H(ALanguage, 'ALIASES', 'ALIAS');
  H(ALanguage, '  attach, conectar, --attach',
    '  conectar, attach, --attach');
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage, '  none', '  ninguna');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  Attaches the interactive TUI to a live session. If SESSION is omitted,',
    '  Conecta el IDE interactivo a una sesion viva. Sin SESION conecta');
  H(ALanguage,
    '  one live session is selected directly and several open the picker.',
    '  directamente si solo hay una; si hay varias abre el selector.');
  H(ALanguage,
    '  Attach is viewer-only: it does not restart panes or change geometry.',
    '  Conectar solo anade un visor: no reinicia paneles ni cambia geometria.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm attach prod', '  superterm conectar prod');
  H(ALanguage, '  superterm --attach', '  superterm --attach');
  Blank;
  SeeAlso(ALanguage, 'superterm --help sessions; superterm --help targets',
    'superterm --ayuda sesiones; superterm --ayuda destinos');
end;

procedure HelpKill(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'COMMAND: kill', 'ORDEN: matar');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm kill SESSION',
    '  superterm matar SESION');
  H(ALanguage, 'ALIASES', 'ALIAS');
  H(ALanguage, '  kill, matar', '  matar, kill');
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage, '  none', '  ninguna');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  Permanently closes the named session daemon and every process inside.',
    '  Cierra permanentemente el daemon nombrado y todos sus procesos.');
  H(ALanguage,
    '  The explicit name is mandatory; "." is refused to prevent accidents.',
    '  El nombre explicito es obligatorio; se rechaza "." para evitar errores.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm list', '  superterm listar');
  H(ALanguage, '  superterm kill incident-42',
    '  superterm matar incidencia-42');
  Blank;
  SeeAlso(ALanguage, 'superterm --help sessions; superterm --help list',
    'superterm --ayuda sesiones; superterm --ayuda listar');
end;

procedure HelpSessions(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'SESSIONS', 'SESIONES');
  H(ALanguage,
    'Live sessions are per-user daemons. At most 8 interactive clients share',
    'Las sesiones son daemons por usuario. Hasta 8 clientes interactivos');
  H(ALanguage,
    'one. Detach or network loss removes only that viewer; interactive Exit',
    'comparten una. Detach o perder red solo elimina ese visor; Salir cierra');
  H(ALanguage,
    'closes its viewer while peers remain, but the last Exit closes the session.',
    'su visor si quedan otros, pero el ultimo Salir cierra la sesion.');
  H(ALanguage,
    'kill is the explicit administrative close. A zero-pane desktop persists.',
    'matar es el cierre administrativo. Un escritorio con cero paneles persiste.');
  H(ALanguage,
    'With pane slots but every child dead, a detached daemon reaps after 60 s.',
    'Con slots pero todos los procesos muertos, el daemon se retira tras 60 s.');
  H(ALanguage,
    'Complete command pages follow.',
    'A continuacion aparecen las paginas completas.');
  Blank;
  HelpList(ALanguage);
  HelpAttach(ALanguage);
  HelpKill(ALanguage);
end;

procedure HelpSend(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'COMMAND: send', 'ORDEN: enviar');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm send [OPTIONS] TARGET [TEXT...]',
    '  superterm enviar [OPCIONES] DESTINO [TEXTO...]');
  H(ALanguage, '  superterm send TARGET -',
    '  superterm enviar DESTINO -');
  H(ALanguage, 'ALIASES', 'ALIAS');
  H(ALanguage, '  send, enviar', '  enviar, send');
  Blank;
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage,
    '  -n, --no-enter, --sin-intro       do not append Enter',
    '  -n, --sin-intro, --no-enter       no anade Intro');
  H(ALanguage,
    '      --noenter, --sinintro          compatibility spellings',
    '      --sinintro, --noenter          formas de compatibilidad');
  H(ALanguage,
    '  -k, --key NAME, --tecla NOMBRE    send a named key; repeatable',
    '  -k, --tecla NOMBRE, --key NAME    envia una tecla; repetible');
  H(ALanguage,
    '  --  after TARGET                    remaining words are literal text',
    '  --  tras DESTINO                    el resto es texto literal');
  Blank;
  H(ALanguage, 'INPUT OPERAND', 'OPERANDO DE ENTRADA');
  H(ALanguage,
    '  -                                   read raw stdin; no Enter is added',
    '  -                                   lee stdin crudo; no anade Intro');
  Blank;
  H(ALanguage, 'NAMED KEYS', 'TECLAS CON NOMBRE');
  H(ALanguage,
    '  Enter/Return/Intro Esc/Escape Tab BackTab/TabAtras Space/Espacio',
    '  Enter/Return/Intro Esc/Escape Tab BackTab/TabAtras Space/Espacio');
  H(ALanguage,
    '  Backspace/BS/Retroceso  Up/Down/Left/Right (Arriba/Abajo/Izquierda/Derecha)',
    '  Backspace/BS/Retroceso  Up/Down/Left/Right (Arriba/Abajo/Izquierda/Derecha)');
  H(ALanguage,
    '  Home/Inicio End/Fin PgUp/RePag PgDn/AvPag Ins Del/Supr F1..F12',
    '  Home/Inicio End/Fin PgUp/RePag PgDn/AvPag Ins Del/Supr F1..F12');
  H(ALanguage,
    '  C-a..C-z, Ctrl-a..Ctrl-z or ^a..^z; M-x or Alt-x',
    '  C-a..C-z, Ctrl-a..Ctrl-z o ^a..^z; M-x o Alt-x');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  Options are accepted before TARGET and after it until literal TEXT',
    '  Las opciones se aceptan antes de DESTINO y despues hasta que empieza');
  H(ALanguage,
    '  begins. TEXT words are joined with spaces. Enter is appended unless',
    '  TEXTO literal. Sus palabras se unen con espacios. Se anade Intro salvo');
  H(ALanguage,
    '  -n is present. Named keys are appended in option order after the text.',
    '  con -n. Las teclas se anaden despues del texto en orden de opcion.');
  H(ALanguage,
    '  At least one of TEXT, raw stdin or a named key must produce bytes.',
    '  TEXTO, stdin crudo o alguna tecla deben producir al menos un byte.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm send prod:2 make test',
    '  superterm enviar prod:2 make test');
  H(ALanguage, '  superterm send . -n partial',
    '  superterm enviar . -n parcial');
  H(ALanguage, '  superterm send prod:Editor --key C-c --key F5',
    '  superterm enviar prod:Editor --tecla C-c --tecla F5');
  H(ALanguage, '  superterm send prod:1 -- --not-a-superterm-option',
    '  superterm enviar prod:1 -- --no-es-opcion-de-superterm');
  H(ALanguage, '  cat script.sh | superterm send prod:1 -',
    '  cat script.sh | superterm enviar prod:1 -');
  Blank;
  SeeAlso(ALanguage, 'superterm --help targets; superterm --help capture',
    'superterm --ayuda destinos; superterm --ayuda capturar');
end;

procedure HelpCapture(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'COMMAND: capture', 'ORDEN: capturar');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm capture TARGET [OPTIONS]',
    '  superterm capturar DESTINO [OPCIONES]');
  H(ALanguage, 'ALIASES', 'ALIAS');
  H(ALanguage, '  capture, capturar', '  capturar, capture');
  Blank;
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage,
    '  -H, --history, --historico        whole scrollback plus visible screen',
    '  -H, --historico, --history        todo el historial mas la pantalla');
  H(ALanguage,
    '  -l, --lines N, --lineas N         only the last N terminal rows',
    '  -l, --lineas N, --lines N         solo las ultimas N filas de terminal');
  H(ALanguage,
    '  -o, --output FILE, --salida FILE  write bytes to FILE, not stdout',
    '  -o, --salida FICHERO, --output FILE  escribe en FICHERO, no en stdout');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  The default is the current visible pane as plain UTF-8 text. -H and',
    '  Por defecto vuelca la pantalla visible como texto UTF-8. -H y -l');
  H(ALanguage,
    '  -l select mutually exclusive capture modes; the last one wins.',
    '  eligen modos excluyentes; prevalece el ultimo indicado.');
  H(ALanguage,
    '  Output is streamable and contains no UI border or ANSI styling.',
    '  La salida es un flujo sin marco del IDE ni estilos ANSI.');
  H(ALanguage,
    '  Short flags are case-sensitive: -H means history; immediate -h is help.',
    '  Los flags cortos distinguen caso: -H es historial; -h inmediato es ayuda.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm capture prod:2',
    '  superterm capturar prod:2');
  H(ALanguage, '  superterm capture prod:Logs --history | grep ERROR',
    '  superterm capturar prod:Logs --historico | grep ERROR');
  H(ALanguage, '  superterm capture . --lines 200 --output last.txt',
    '  superterm capturar . --lineas 200 --salida ultimas.txt');
  Blank;
  SeeAlso(ALanguage, 'superterm --help targets; superterm --help send',
    'superterm --ayuda destinos; superterm --ayuda enviar');
end;

procedure HelpPanes(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'PANE I/O', 'E/S DE PANELES');
  H(ALanguage,
    'send injects ordered terminal input; capture reads the daemon-owned screen.',
    'enviar inyecta entrada ordenada; capturar lee la pantalla del daemon.');
  Blank;
  HelpSend(ALanguage);
  HelpCapture(ALanguage);
end;

procedure HelpNew(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'COMMAND: new', 'ORDEN: nueva');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm new SESSION[:PANE] [OPTIONS]',
    '  superterm nueva SESION[:PANEL] [OPCIONES]');
  H(ALanguage, 'ALIASES', 'ALIAS');
  H(ALanguage, '  new, nueva, nuevo',
    '  nueva, nuevo, new');
  Blank;
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage,
    '  -c, --class NAME, --clase NOMBRE  start from a configured class',
    '  -c, --clase NOMBRE, --class NAME  parte de una clase configurada');
  H(ALanguage,
    '  --cmd COMMAND, --comando ORDEN     command inside the pane shell',
    '  --cmd COMMAND, --comando ORDEN     orden dentro del shell del panel');
  H(ALanguage,
    '  --cwd DIR, --dir DIR, --directorio DIR  initial directory',
    '  --cwd DIR, --dir DIR, --directorio DIR  directorio inicial');
  H(ALanguage,
    '  -t, --title NAME, --titulo NOMBRE  fixed visible title',
    '  -t, --titulo NOMBRE, --title NAME  titulo visible fijo');
  H(ALanguage,
    '  -d, --down, --abajo                split below (default)',
    '  -d, --abajo, --down                divide abajo (predeterminado)');
  H(ALanguage,
    '  -r, --right, --derecha             split to the right',
    '  -r, --derecha, --right             divide a la derecha');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  PANE, when present, is the existing split anchor; otherwise the focused',
    '  PANEL, si aparece, es el ancla de division; si no, se usa el enfocado.');
  H(ALanguage,
    '  pane is used. In a zero-pane desktop the new pane becomes the root.',
    '  En un escritorio con cero paneles, el nuevo se convierte en la raiz.');
  H(ALanguage,
    '  Class defaults are resolved by the daemon before the pane is published.',
    '  El daemon resuelve la clase antes de publicar el panel definitivo.');
  H(ALanguage,
    '  Explicit command, directory and title override their corresponding',
    '  Comando, directorio y titulo explicitos prevalecen sobre los valores');
  H(ALanguage,
    '  class values. A session holds at most 16 panes.',
    '  de la clase. Una sesion admite como maximo 16 paneles.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm new prod --class local-shell --right',
    '  superterm nueva prod --clase local-shell --derecha');
  H(ALanguage,
    '  superterm new prod:Logs --cmd "tail -f /var/log/syslog" -t Live',
    '  superterm nueva prod:Logs --comando "tail -f /var/log/syslog" -t Vivo');
  H(ALanguage, '  superterm new . --cwd /tmp --down',
    '  superterm nueva . --directorio /tmp --abajo');
  Blank;
  SeeAlso(ALanguage, 'superterm --help targets; superterm --help windows',
    'superterm --ayuda destinos; superterm --ayuda ventanas');
end;

procedure HelpClose(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'COMMAND: close', 'ORDEN: cerrar');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm close TARGET',
    '  superterm cerrar DESTINO');
  H(ALanguage, 'ALIASES', 'ALIAS');
  H(ALanguage, '  close, cerrar', '  cerrar, close');
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage, '  none', '  ninguna');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  Closes the pane and its process. The control CLI refuses the last pane;',
    '  Cierra el panel y su proceso. La CLI de control rechaza el ultimo;');
  H(ALanguage,
    '  use kill for the whole session or the UI to keep an empty desktop.',
    '  usa matar para la sesion o el IDE para conservar un escritorio vacio.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm close prod:Scratch',
    '  superterm cerrar prod:Temporal');
  Blank;
  SeeAlso(ALanguage, 'superterm --help targets; superterm --help kill',
    'superterm --ayuda destinos; superterm --ayuda matar');
end;

procedure HelpFocus(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'COMMAND: focus', 'ORDEN: foco');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm focus TARGET',
    '  superterm foco DESTINO');
  H(ALanguage, 'ALIASES', 'ALIAS');
  H(ALanguage, '  focus, select, foco, seleccionar',
    '  foco, seleccionar, focus, select');
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage, '  none', '  ninguna');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  Sets the one shared focused pane. Focusing a minimized pane restores it.',
    '  Fija el unico foco compartido. Enfocar uno minimizado lo restaura.');
  H(ALanguage,
    '  With exactly one live session, later TARGET "." follows that focus.',
    '  Con una unica sesion viva, un DESTINO "." posterior sigue ese foco.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm select prod:Editor',
    '  superterm seleccionar prod:Editor');
  Blank;
  SeeAlso(ALanguage, 'superterm --help targets; superterm --help windows',
    'superterm --ayuda destinos; superterm --ayuda ventanas');
end;

procedure HelpRename(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'COMMAND: rename', 'ORDEN: renombrar');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm rename TARGET NEW_NAME...',
    '  superterm renombrar DESTINO NUEVO_NOMBRE...');
  H(ALanguage, 'ALIASES', 'ALIAS');
  H(ALanguage, '  rename, renombrar', '  renombrar, rename');
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage, '  none; every word after TARGET belongs to the title',
    '  ninguna; todo lo posterior a DESTINO pertenece al titulo');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  Joins all words after TARGET, including words beginning with "-", into',
    '  Une todo lo posterior a DESTINO, incluso palabras que empiezan por "-",');
  H(ALanguage,
    '  one trimmed non-empty fixed title. The shell cannot overwrite it.',
    '  en un titulo fijo recortado y no vacio. El shell no lo sobrescribe.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm rename prod:2 Production logs',
    '  superterm renombrar prod:2 Logs de produccion');
  H(ALanguage, '  superterm rename prod:2 --paused',
    '  superterm renombrar prod:2 --pausado');
  Blank;
  SeeAlso(ALanguage, 'superterm --help targets; superterm --help windows',
    'superterm --ayuda destinos; superterm --ayuda ventanas');
end;

procedure HelpResize(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'COMMAND: resize', 'ORDEN: tamano');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm resize TARGET COLSxROWS',
    '  superterm tamano DESTINO COLSxFILAS');
  H(ALanguage, 'ALIASES', 'ALIAS');
  H(ALanguage, '  resize, tamano, redimensionar',
    '  tamano, redimensionar, resize');
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage, '  none', '  ninguna');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  Changes the canonical shared terminal grid and sends TIOCSWINSZ.',
    '  Cambia la rejilla canonica compartida y envia TIOCSWINSZ.');
  H(ALanguage,
    '  COLS must be 4..1000 and ROWS 2..500. Restore an IDE-maximized or',
    '  COLS debe ser 4..1000 y FILAS 2..500. Restaura antes un panel');
  H(ALanguage,
    '  fullscreen pane first. Every viewer receives the same final size.',
    '  maximizado o fullscreen. Todos reciben el mismo tamano final.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm resize prod:Editor 120x40',
    '  superterm redimensionar prod:Editor 120x40');
  Blank;
  SeeAlso(ALanguage, 'superterm --help targets; superterm --help restore',
    'superterm --ayuda destinos; superterm --ayuda restaurar');
end;

procedure HelpMinimize(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'COMMAND: minimize', 'ORDEN: minimizar');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm minimize TARGET',
    '  superterm minimizar DESTINO');
  H(ALanguage, 'ALIASES', 'ALIAS');
  H(ALanguage, '  minimize, minimizar', '  minimizar, minimize');
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage, '  none', '  ninguna');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  Atomically minimizes the shared window for every viewer.',
    '  Minimiza atomicamente la ventana compartida para todos los visores.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm minimize prod:Monitor',
    '  superterm minimizar prod:Monitor');
  Blank;
  SeeAlso(ALanguage, 'superterm --help targets; superterm --help restore',
    'superterm --ayuda destinos; superterm --ayuda restaurar');
end;

procedure HelpRestore(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'COMMAND: restore', 'ORDEN: restaurar');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm restore TARGET',
    '  superterm restaurar DESTINO');
  H(ALanguage, 'ALIASES', 'ALIAS');
  H(ALanguage, '  restore, restaurar', '  restaurar, restore');
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage, '  none', '  ninguna');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  Clears minimized, IDE-maximized and fullscreen state and returns the',
    '  Quita minimizado, maximizado IDE y fullscreen, y devuelve panel y PTY');
  H(ALanguage,
    '  pane and PTY to their saved normal geometry.',
    '  a su geometria normal guardada.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm restore prod:Monitor',
    '  superterm restaurar prod:Monitor');
  Blank;
  SeeAlso(ALanguage, 'superterm --help targets; superterm --help windows',
    'superterm --ayuda destinos; superterm --ayuda ventanas');
end;

procedure HelpZoom(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'COMMAND: zoom', 'ORDEN: ampliar');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm zoom TARGET',
    '  superterm ampliar DESTINO');
  H(ALanguage, 'ALIASES', 'ALIAS');
  H(ALanguage, '  zoom, ampliar', '  ampliar, zoom');
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage, '  none', '  ninguna');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  IDE-maximizes and focuses TARGET, restoring any previous maximum.',
    '  Maximiza DESTINO dentro del IDE, le da foco y restaura el maximo anterior.');
  H(ALanguage,
    '  This keeps menu/status/frame; it is not prefix f (Ctrl-Q f by default)',
    '  Conserva menu/estado/marco; no es fullscreen con prefijo f (Ctrl-Q f)');
  H(ALanguage,
    '  fullscreen.',
    '  de forma predeterminada.');
  H(ALanguage,
    '  The committed rectangle fits the smallest host currently attached.',
    '  El rectangulo final cabe en el host conectado de menor tamano.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm zoom prod:Editor',
    '  superterm ampliar prod:Editor');
  Blank;
  SeeAlso(ALanguage, 'superterm --help targets; superterm --help restore',
    'superterm --ayuda destinos; superterm --ayuda restaurar');
end;

procedure HelpOrganize(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'COMMAND: organize', 'ORDEN: organizar');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm organize SESSION [MODE]',
    '  superterm organizar SESION [MODO]');
  H(ALanguage, 'ALIASES', 'ALIAS');
  H(ALanguage, '  organize, organizar', '  organizar, organize');
  H(ALanguage, 'ARGUMENTS', 'ARGUMENTOS');
  H(ALanguage,
    '  MODE: grid/rejilla (default), tile/mosaico, cascade/cascada',
    '  MODO: rejilla/grid (predeterminado), mosaico/tile, cascada/cascade');
  H(ALanguage, 'OPTIONS', 'OPCIONES');
  H(ALanguage, '  none', '  ninguna');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  Computes one shared arrangement, restores minimized/maximized states',
    '  Calcula una disposicion compartida, restaura estados minimizados o');
  H(ALanguage,
    '  and resizes every PTY to its resulting canonical rectangle.',
    '  maximizados y ajusta cada PTY a su rectangulo canonico.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm organize prod grid',
    '  superterm organizar prod rejilla');
  H(ALanguage, '  superterm organize prod tile',
    '  superterm organizar prod mosaico');
  H(ALanguage, '  superterm organize . cascade',
    '  superterm organizar . cascada');
  Blank;
  SeeAlso(ALanguage, 'superterm --help sessions; superterm --help windows',
    'superterm --ayuda sesiones; superterm --ayuda ventanas');
end;

procedure HelpWindows(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'WINDOW MANAGEMENT', 'GESTION DE VENTANAS');
  H(ALanguage,
    'These commands enter the same daemon FIFO as interactive actions. Their',
    'Estas ordenes entran en la misma FIFO del daemon que las acciones del IDE.');
  H(ALanguage,
    'settled result is shared by all clients. Complete command pages follow.',
    'El resultado final es comun para todos. Paginas completas:');
  H(ALanguage,
    'A one-shot CLI action never waits for a layout lock: busy returns exit 1.',
    'Una accion CLI nunca espera un lock de layout: ocupado devuelve salida 1.');
  H(ALanguage,
    'Focus is lock-free unless it must restore a minimized pane.',
    'El foco no usa lock salvo si debe restaurar un panel minimizado.');
  Blank;
  HelpNew(ALanguage);
  HelpClose(ALanguage);
  HelpFocus(ALanguage);
  HelpRename(ALanguage);
  HelpResize(ALanguage);
  HelpMinimize(ALanguage);
  HelpRestore(ALanguage);
  HelpZoom(ALanguage);
  HelpOrganize(ALanguage);
end;

procedure HelpExitCodes(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'EXIT CODES', 'CODIGOS DE SALIDA');
  H(ALanguage, '  0  success', '  0  exito');
  H(ALanguage,
    '  1  not found, ambiguous/rejected operation, no sessions, or SSH admin',
    '  1  ausente, ambiguo/rechazado, sin sesiones o fallo de administracion');
  H(ALanguage,
    '     or validation failure',
    '     o validacion SSH');
  H(ALanguage,
    '  2  invalid command line, option, key name, help topic or argument',
    '  2  orden, opcion, tecla, tema de ayuda o argumento invalido');
  H(ALanguage,
    '  3  connection/protocol failure; ssh-server status also uses 3 when down',
    '  3  fallo de conexion/protocolo; servidor-ssh estado usa 3 si esta parado');
  Blank;
  H(ALanguage,
    'Diagnostics go to stderr; command data and help go to stdout. Help never',
    'Los diagnosticos van a stderr; datos y ayuda van a stdout. La ayuda nunca');
  H(ALanguage,
    'requires a live session. Unknown help topics return 2 instead of guessing.',
    'exige sesion viva. Un tema desconocido sale 2 en vez de adivinar.');
  Blank;
  H(ALanguage, 'EXAMPLE', 'EJEMPLO');
  H(ALanguage, '  superterm capture prod:Logs || echo "capture failed: $?"',
    '  superterm capturar prod:Logs || echo "fallo de captura: $?"');
  Blank;
  SeeAlso(ALanguage, 'superterm --help reference; superterm --help sessions',
    'superterm --ayuda referencia; superterm --ayuda sesiones');
end;

procedure HelpLanguage(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'LANGUAGE AND ALIASES', 'IDIOMA Y ALIAS');
  H(ALanguage,
    'Control commands and their documented options accept English and Spanish.',
    'Las ordenes de control y sus opciones aceptan ingles y espanol.');
  H(ALanguage,
    'Command/topic names and long control options ignore case and accents.',
    'Ordenes/temas y opciones largas ignoran mayusculas y acentos.');
  H(ALanguage,
    'Short options remain exact and case-sensitive: capture -H is history,',
    'Las opciones cortas son exactas: capturar -H es historial, mientras');
  H(ALanguage,
    'while immediate -h, -?, --help or --ayuda requests help. Output follows',
    'que -h, -?, --help o --ayuda inmediatos piden ayuda. La salida sigue');
  H(ALanguage,
    '[ui] language in ~/.superterm/superterm.ini, or LANG when no config exists.',
    '[ui] language en ~/.superterm/superterm.ini, o LANG si no hay config.');
  H(ALanguage,
    '--ayuda selects the help operation but does not override the configured',
    '--ayuda selecciona la operacion, pero no fuerza un idioma distinto del');
  H(ALanguage,
    'output language. Direct ssh-server administration runs before HOME is read,',
    'configurado. La administracion ssh-server se ejecuta antes de leer HOME');
  H(ALanguage,
    'so it uses LANG; "servidor-ssh ayuda" selects Spanish explicitly.',
    'y usa LANG; "servidor-ssh ayuda" selecciona espanol explicitamente.');
  H(ALanguage,
    'Legacy startup flags keep the exact spellings shown by --help startup.',
    'Los flags historicos conservan la forma exacta de --ayuda inicio.');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  superterm send prod:2 --key C-c',
    '  superterm enviar prod:2 --tecla C-c');
  H(ALanguage, '  LANG=es_ES.UTF-8 superterm --ayuda sesiones',
    '  LANG=C superterm --help sessions');
  Blank;
  SeeAlso(ALanguage, 'superterm --help reference; superterm --help startup',
    'superterm --ayuda referencia; superterm --ayuda inicio');
end;

procedure HelpVersion(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'VERSION', 'VERSION');
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  superterm version', '  superterm version');
  H(ALanguage, '  superterm --version', '  superterm --version');
  H(ALanguage, '  superterm -V', '  superterm -V');
  Blank;
  H(ALanguage, 'OUTPUT', 'SALIDA');
  H(ALanguage, '  superterm ' + SUPERTERM_VERSION,
    '  superterm ' + SUPERTERM_VERSION);
  H(ALanguage,
    'All three forms print exactly one line and exit 0.',
    'Las tres formas imprimen exactamente una linea y salen 0.');
  Blank;
  SeeAlso(ALanguage, 'superterm --help reference; superterm --help startup',
    'superterm --ayuda referencia; superterm --ayuda inicio');
end;

procedure HelpSshClient(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'STANDARD SSH CLIENT ENTRY', 'ENTRADA CON CLIENTE SSH ESTANDAR');
  H(ALanguage, 'PURPOSE', 'PROPOSITO');
  H(ALanguage,
    '  Connect an ordinary OpenSSH client to a dedicated encrypted TCP port',
    '  Conecta un cliente OpenSSH ordinario a un puerto TCP cifrado dedicado');
  H(ALanguage,
    '  and enter the same per-user SuperTerm session engine as a local client.',
    '  y entra en el mismo motor de sesiones por usuario que un cliente local.');
  Blank;
  H(ALanguage, 'SYNOPSIS', 'SINOPSIS');
  H(ALanguage, '  ssh -p PORT USER@HOST',
    '  ssh -p PUERTO USUARIO@HOST');
  Blank;
  H(ALanguage, 'CLIENT OPTIONS USED IN COMMON CASES',
    'OPCIONES DE CLIENTE PARA CASOS HABITUALES');
  H(ALanguage,
    '  -p PORT             select the dedicated SuperTerm listener port',
    '  -p PUERTO           elige el puerto dedicado de SuperTerm');
  H(ALanguage,
    '  -tt                 force a PTY only when the caller has no terminal',
    '  -tt                 fuerza PTY solo si el proceso no tiene terminal');
  H(ALanguage,
    '  -i PRIVATE_KEY      use a client key stored under a nonstandard name',
    '  -i CLAVE_PRIVADA    usa una clave cliente con nombre no estandar');
  H(ALanguage,
    '  -o IdentitiesOnly=yes  diagnose by offering only the selected identity',
    '  -o IdentitiesOnly=yes  diagnostica ofreciendo solo esa identidad');
  H(ALanguage,
    'These are OpenSSH client options, not SuperTerm options.',
    'Estas son opciones del cliente OpenSSH, no opciones de SuperTerm.');
  Blank;
  H(ALanguage, 'AUTHENTICATION', 'AUTENTICACION');
  H(ALanguage,
    '  OpenSSH first tries normal client identities/agent. If the service',
    '  OpenSSH prueba primero las identidades/agente normales. Si el servicio');
  H(ALanguage,
    '  enables passwords, it can then ask for the account password accepted',
    '  habilita contrasenas, puede pedir la admitida por PAM para la cuenta.');
  H(ALanguage,
    '  by PAM. Private keys stay on the client; authorize copies only .pub.',
    '  Las privadas quedan en el cliente; autorizar solo copia el fichero .pub.');
  H(ALanguage,
    '  On first contact, verify the host fingerprint before accepting it.',
    '  En el primer contacto, verifica la huella del host antes de aceptarla.');
  Blank;
  H(ALanguage, 'SESSION ROUTING (~/.superterm/superterm.ini)',
    'RUTA DE SESION (~/.superterm/superterm.ini)');
  H(ALanguage, '  [session]', '  [session]');
  H(ALanguage, '  ssh_session=last', '  ssh_session=last');
  H(ALanguage, '  default_session=daily-ssh', '  default_session=diaria-ssh');
  H(ALanguage, '  default_profile=daily', '  default_profile=diaria');
  H(ALanguage,
    '  last (default) returns to ssh_last_session while that daemon is live,',
    '  last (predeterminado) vuelve a ssh_last_session si su daemon esta vivo;');
  H(ALanguage,
    '  otherwise it uses the same fallback chain as default.',
    '  si no, usa la misma cadena alternativa que default.');
  H(ALanguage,
    '  default always uses default_session, then default_profile, then "session".',
    '  default usa siempre default_session, luego default_profile y "session".');
  H(ALanguage,
    '  default_session selects the name; default_profile supplies initial panes.',
    '  default_session elige nombre; default_profile aporta paneles iniciales.');
  H(ALanguage,
    '  ssh_last_session is an atomically managed routing hint, not a saved',
    '  ssh_last_session es una pista de ruta gestionada atomicamente, no una');
  H(ALanguage,
    '  desktop; normally do not edit it. If the chosen session is absent, the',
    '  copia del escritorio; no se edita. Si falta la sesion elegida, la primera');
  H(ALanguage,
    '  first login creates it from default_profile, or empty if none resolves.',
    '  conexion la crea desde default_profile, o vacia si no resuelve ninguno.');
  H(ALanguage,
    '  A per-user/name lock serializes simultaneous first logins.',
    '  Un lock por usuario/nombre serializa primeras conexiones simultaneas.');
  Blank;
  H(ALanguage, 'SESSION BEHAVIOR', 'COMPORTAMIENTO DE SESION');
  H(ALanguage,
    '  The login is forced into an interactive SuperTerm UI. Detach, closing',
    '  El login queda forzado al IDE interactivo. Detach, cerrar el terminal');
  H(ALanguage,
    '  the terminal or losing the network drops only that viewer. Reconnect',
    '  o perder la red solo elimina ese visor. Reconectar recupera la sesion');
  H(ALanguage,
    '  receives the exact live desktop. Remote exec, no-PTY, SCP/SFTP, X11,',
    '  viva exacta. Exec remoto, sin PTY, SCP/SFTP, X11 y forwarding se');
  H(ALanguage,
    '  agent and forwarding requests are deliberately rejected.',
    '  rechazan deliberadamente.');
  Blank;
  H(ALanguage, 'OPTIONAL CLIENT ALIAS (~/.ssh/config)',
    'ALIAS OPCIONAL DEL CLIENTE (~/.ssh/config)');
  H(ALanguage, '  Host superterm', '  Host superterm');
  H(ALanguage, '      HostName server', '      HostName servidor');
  H(ALanguage, '      Port 8022', '      Port 8022');
  H(ALanguage, '      User user', '      User usuario');
  H(ALanguage, '  Then connect with: ssh superterm',
    '  Despues conecta con: ssh superterm');
  Blank;
  H(ALanguage, 'EXAMPLES', 'EJEMPLOS');
  H(ALanguage, '  ssh -p 8022 user@server',
    '  ssh -p 8022 usuario@servidor');
  H(ALanguage,
    '  ssh -tt -i ~/.ssh/superterm_ed25519 -p 8022 user@server',
    '  ssh -tt -i ~/.ssh/superterm_ed25519 -p 8022 usuario@servidor');
  Blank;
  SeeAlso(ALanguage,
    'superterm --help ssh-server; https://github.com/garacil/superterm/tree/main/docs',
    'superterm --ayuda servidor-ssh; https://github.com/garacil/superterm/tree/main/docs');
end;

procedure PrintSshServerHelp(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'DEDICATED SSH/TCP SERVER', 'SERVIDOR SSH/TCP DEDICADO');
  H(ALanguage, 'PURPOSE', 'PROPOSITO');
  H(ALanguage,
    '  Runs a second instance of the system OpenSSH sshd as an encrypted TCP',
    '  Ejecuta una segunda instancia del sshd OpenSSH del sistema como entrada');
  H(ALanguage,
    '  entry to SuperTerm. Persistent configuration, host keys and managed',
    '  TCP cifrada a SuperTerm. La configuracion persistente, host keys y');
  H(ALanguage,
    '  user keys live below /etc/superterm/sshd. Its PID and service descriptor',
    '  claves gestionadas viven bajo /etc/superterm/sshd. El PID y descriptor');
  H(ALanguage,
    '  are separate too. It never edits or restarts the ordinary host sshd.',
    '  de servicio tambien son propios. Nunca edita ni reinicia el sshd normal.');
  H(ALanguage,
    '  This release listens on TCP only, never UDP.',
    '  Esta release solo escucha TCP, nunca UDP.');
  Blank;
  H(ALanguage, 'ADMIN SYNOPSIS (root except help)',
    'SINOPSIS ADMINISTRATIVA (root salvo ayuda)');
  H(ALanguage, '  superterm ssh-server setup',
    '  superterm servidor-ssh configurar');
  H(ALanguage, '  superterm ssh-server check',
    '  superterm servidor-ssh comprobar');
  H(ALanguage, '  superterm ssh-server restart',
    '  superterm servidor-ssh reiniciar');
  H(ALanguage, '  superterm ssh-server status',
    '  superterm servidor-ssh estado');
  H(ALanguage, '  superterm ssh-server enable',
    '  superterm servidor-ssh habilitar');
  H(ALanguage, '  superterm ssh-server disable',
    '  superterm servidor-ssh deshabilitar');
  H(ALanguage, '  superterm ssh-server uninstall-service',
    '  superterm servidor-ssh desinstalar-servicio');
  H(ALanguage, '  superterm ssh-server authorize USER KEY.pub',
    '  superterm servidor-ssh autorizar USUARIO CLAVE.pub');
  H(ALanguage, '  superterm ssh-server list-keys [USER]',
    '  superterm servidor-ssh listar-claves [USUARIO]');
  H(ALanguage, '  superterm ssh-server revoke USER FINGERPRINT',
    '  superterm servidor-ssh revocar USUARIO HUELLA');
  H(ALanguage, '  superterm ssh-server revoke USER KEY.pub',
    '  superterm servidor-ssh revocar USUARIO CLAVE.pub');
  H(ALanguage, '  superterm ssh-server help',
    '  superterm servidor-ssh ayuda');
  H(ALanguage, '  superterm ssh-server --help',
    '  superterm servidor-ssh --ayuda');
  H(ALanguage, '  superterm ssh-server COMMAND --help',
    '  superterm servidor-ssh ORDEN --ayuda');
  H(ALanguage,
    '  HELP_OPTION is --help, --ayuda, -h or ''-?'' and must be the sole',
    '  OPCION_AYUDA es --help, --ayuda, -h o ''-?'' y debe ser el unico');
  H(ALanguage,
    '  argument after the namespace or after a recognized COMMAND.',
    '  argumento tras el namespace o tras una ORDEN reconocida.');
  Blank;
  H(ALanguage, 'COMMAND BEHAVIOR', 'COMPORTAMIENTO DE ORDENES');
  H(ALanguage,
    '  setup              create/validate state and install+enable the service',
    '  configurar         crea/valida estado e instala+habilita el servicio');
  H(ALanguage,
    '                     without replacing an existing server.ini or keys',
    '                     sin sustituir un server.ini ni claves existentes');
  H(ALanguage,
    '  check              validate pending server.ini without publishing it',
    '  comprobar          valida server.ini pendiente sin publicarlo');
  H(ALanguage,
    '  restart            validate, publish, restart, health-check; roll back',
    '  reiniciar          valida, publica, reinicia y comprueba; si falla restaura');
  H(ALanguage,
    '                     generated config, descriptor and service on failure',
    '                     generado, descriptor y servicio si algo falla');
  H(ALanguage,
    '  status             query the dedicated service; exit 3 when not running',
    '  estado             consulta el servicio; sale 3 cuando no esta activo');
  H(ALanguage,
    '  enable             start+enable the previously accepted configuration',
    '  habilitar          arranca+activa la configuracion ya aceptada');
  H(ALanguage,
    '                     without reading a pending server.ini edit',
    '                     sin leer una edicion pendiente de server.ini');
  H(ALanguage,
    '  disable            stop+disable the dedicated SuperTerm service name',
    '  deshabilitar       para+desactiva el nombre de servicio de SuperTerm');
  H(ALanguage,
    '                     while keeping its descriptor, configuration and keys',
    '                     conservando descriptor, configuracion y claves');
  H(ALanguage,
    '  uninstall-service  remove only a recognized SuperTerm service descriptor',
    '  desinstalar-servicio  retira solo un descriptor reconocido de SuperTerm');
  H(ALanguage,
    '                     and keep server.ini, generated config and every key',
    '                     y conserva server.ini, generado y todas las claves');
  H(ALanguage,
    '  authorize          add one public key to the central USER store',
    '  autorizar          anade una clave publica al almacen central de USUARIO');
  H(ALanguage,
    '                     (one unadorned public-key line; never a private key)',
    '                     (una linea de clave publica sin opciones; no privada)');
  H(ALanguage,
    '                     repeating the same key succeeds without duplicating it',
    '                     repetir la misma clave tiene exito y no la duplica');
  H(ALanguage,
    '  list-keys          show one user or every central key file',
    '  listar-claves      muestra un usuario o todos los ficheros centrales');
  H(ALanguage,
    '                     USER must exist; the all-files form may show orphans',
    '                     USUARIO debe existir; listar todo puede mostrar huerfanos');
  H(ALanguage,
    '  revoke             remove the exact fingerprint or supplied public key',
    '  revocar            retira la huella exacta o la clave publica indicada');
  H(ALanguage,
    '                     (all matches; absent key is an error)',
    '                     (todas las coincidencias; si falta es un error)');
  H(ALanguage,
    '                     Use the complete SHA256: token from list-keys.',
    '                     Usa el SHA256: completo obtenido con listar-claves.');
  H(ALanguage,
    '  run/ejecutar       INTERNAL service-manager wrapper; do not invoke',
    '  run/ejecutar       wrapper INTERNO del gestor; no se invoca a mano');
  H(ALanguage,
    '                     validates and execs sshd -D; no extra supervisor',
    '                     valida y ejecuta sshd -D; no deja otro supervisor');
  Blank;
  H(ALanguage, 'ACCEPTED ADMIN ALIASES', 'ALIAS ADMINISTRATIVOS ACEPTADOS');
  H(ALanguage,
    '  ssh-server/servidor-ssh',
    '  ssh-server/servidor-ssh');
  H(ALanguage,
    '  setup/init/configurar/preparar/inicializar',
    '  setup/init/configurar/preparar/inicializar');
  H(ALanguage,
    '  check/comprobar/verificar; restart/reiniciar; status/estado',
    '  check/comprobar/verificar; restart/reiniciar; status/estado');
  H(ALanguage,
    '  enable/habilitar/activar; disable/deshabilitar/desactivar',
    '  enable/habilitar/activar; disable/deshabilitar/desactivar');
  H(ALanguage,
    '  authorize/autorizar; revoke/revocar; list-keys/listar-claves',
    '  authorize/autorizar; revoke/revocar; list-keys/listar-claves');
  H(ALanguage,
    '  uninstall-service/desinstalar-servicio; help/ayuda; run/ejecutar',
    '  uninstall-service/desinstalar-servicio; help/ayuda; run/ejecutar');
  Blank;
  H(ALanguage, 'PUBLIC CONFIGURATION', 'CONFIGURACION PUBLICA');
  H(ALanguage, '  /etc/superterm/sshd/server.ini:',
    '  /etc/superterm/sshd/server.ini:');
  H(ALanguage, '    [server]', '    [server]');
  H(ALanguage, '    config_version=1', '    config_version=1');
  H(ALanguage, '    listen=127.0.0.1:8022,[::1]:8022',
    '    listen=127.0.0.1:8022,[::1]:8022');
  H(ALanguage, '    allow_root=0', '    allow_root=0');
  H(ALanguage, '    password_authentication=1',
    '    password_authentication=1');
  H(ALanguage, '    managed_authorized_keys=1',
    '    managed_authorized_keys=1');
  H(ALanguage, '    user_authorized_keys=1',
    '    user_authorized_keys=1');
  H(ALanguage,
    '  The file is at most 65536 bytes and has exactly one [server] section.',
    '  El fichero mide como maximo 65536 bytes y tiene una sola seccion [server].');
  H(ALanguage,
    '  Section/key names ignore case. Blank lines and comments starting # or ;',
    '  Secciones y claves ignoran caso. Admite lineas vacias y comentarios');
  H(ALanguage,
    '  are valid; settings outside the section, unknown keys and duplicates fail.',
    '  con # o punto y coma; valores fuera, claves desconocidas o repetidas fallan.');
  H(ALanguage,
    '  In production it must be a root-owned regular file, not a symlink, and',
    '  En produccion debe ser regular, de root, no symlink y sin escritura para');
  H(ALanguage,
    '  not writable by group or others.',
    '  grupo ni otros.');
  H(ALanguage,
    '  config_version must be exactly 1.',
    '  config_version debe ser exactamente 1.');
  H(ALanguage,
    '  config_version, listen and allow_root are required. The three auth',
    '  config_version, listen y allow_root son obligatorios. Los tres');
  H(ALanguage,
    '  switches are optional only for compatibility with older version-1 files.',
    '  selectores de autenticacion solo son opcionales por compatibilidad.');
  H(ALanguage,
    '  Legacy defaults are password_authentication=0, managed_authorized_keys=1',
    '  Los valores antiguos son password_authentication=0,');
  H(ALanguage,
    '  and user_authorized_keys=0 when those switches are omitted.',
    '  managed_authorized_keys=1 y user_authorized_keys=0 si se omiten.');
  H(ALanguage,
    '  listen accepts 1..32 unique TCP host:port endpoints (port 1..65535).',
    '  listen acepta 1..32 endpoints TCP host:puerto sin repetir');
  H(ALanguage,
    '  Each endpoint is at most 320 bytes and requires an explicit host. IPv6',
    '  (puerto 1..65535). Cada endpoint mide como maximo 320 bytes y exige host.');
  H(ALanguage,
    '  uses [address]:port; a scoped address may contain %. Duplicates ignore case.',
    '  IPv6 usa [direccion]:puerto y admite zona con %. Duplicados ignoran caso.');
  H(ALanguage,
    '  The generated default listens only on loopback; explicitly add a LAN',
    '  El valor inicial solo escucha loopback; anade de forma explicita una');
  H(ALanguage,
    '  address, for example listen=192.0.2.10:8022.',
    '  direccion LAN, por ejemplo listen=192.0.2.10:8022.');
  H(ALanguage,
    '  Use 0.0.0.0:8022 and [::]:8022 deliberately for all interfaces.',
    '  Usa 0.0.0.0:8022 y [::]:8022 deliberadamente para todas las interfaces.');
  Blank;
  H(ALanguage, 'AUTHENTICATION POLICY', 'POLITICA DE AUTENTICACION');
  H(ALanguage,
    '  All four boolean values accept 1/0, true/false, yes/no or on/off.',
    '  Los cuatro booleanos aceptan 1/0, true/false, yes/no u on/off.');
  H(ALanguage,
    '  password_authentication uses the account password through PAM; no',
    '  password_authentication usa mediante PAM la contrasena de la cuenta;');
  H(ALanguage,
    '  password is stored by SuperTerm. managed_authorized_keys reads',
    '  SuperTerm no guarda contrasenas. managed_authorized_keys lee');
  H(ALanguage,
    '  /etc/superterm/sshd/authorized_keys/USER; user_authorized_keys reads',
    '  /etc/superterm/sshd/authorized_keys/USUARIO; user_authorized_keys lee');
  H(ALanguage,
    '  each account''s ~/.ssh/authorized_keys. At least one method is required.',
    '  ~/.ssh/authorized_keys de cada cuenta. Se exige al menos un metodo.');
  H(ALanguage,
    '  SuperTerm never edits the user file. authorize/revoke affect only the',
    '  SuperTerm nunca edita el fichero del usuario. autorizar/revocar solo');
  H(ALanguage,
    '  central store and take effect only when managed_authorized_keys=1.',
    '  cambian el almacen central, activo con managed_authorized_keys=1.');
  H(ALanguage,
    '  Password plus keys means either method, not two-factor authentication.',
    '  Contrasena mas claves significa un metodo u otro, no doble factor.');
  H(ALanguage,
    '  PAM still applies account/session policy to public-key logins.',
    '  PAM aun aplica politica de cuenta/sesion a logins con clave publica.');
  H(ALanguage,
    '  allow_root=1 still requires public keys and never permits root passwords.',
    '  allow_root=1 aun exige claves publicas y nunca admite contrasena de root.');
  H(ALanguage,
    '  allow_root=0 rejects root even with a key. There is no user allowlist:',
    '  allow_root=0 rechaza root incluso con clave. No hay lista de usuarios:');
  H(ALanguage,
    '  any system account accepted by NSS/PAM/OpenSSH follows this policy.',
    '  toda cuenta admitida por NSS/PAM/OpenSSH sigue esta politica.');
  H(ALanguage,
    '  USER is an existing system account: 1..64 letters, digits, dot, hyphen',
    '  USUARIO es una cuenta del sistema: 1..64 letras, digitos, punto, guion');
  H(ALanguage,
    '  or underscore, and it cannot begin with dot or hyphen.',
    '  o subrayado, y no puede comenzar por punto ni guion.');
  Blank;
  H(ALanguage, 'MANAGED KEY RULES', 'REGLAS DE CLAVES GESTIONADAS');
  H(ALanguage,
    '  KEY.pub is a regular, non-symlink file of at most 65536 bytes containing',
    '  CLAVE.pub es regular, no symlink, de hasta 65536 bytes y contiene una');
  H(ALanguage,
    '  exactly one non-comment key. Options are rejected; comments are removed.',
    '  sola clave no comentada. Rechaza opciones y elimina comentarios.');
  H(ALanguage,
    '  Accepted type prefixes are ssh-, ecdsa- and sk-, then ssh-keygen performs',
    '  Admite prefijos ssh-, ecdsa- y sk-; despues ssh-keygen hace la validacion');
  H(ALanguage,
    '  authoritative validation. Each user may hold 4096 keys or 1 MiB total.',
    '  autoritativa. Cada usuario admite 4096 claves o 1 MiB total.');
  H(ALanguage,
    '  A fingerprint is the exact 15..128-byte SHA256: token printed by list-keys.',
    '  Una huella es el SHA256: exacto de 15..128 bytes que imprime listar-claves.');
  Blank;
  H(ALanguage, 'OWNED PATHS', 'RUTAS PROPIAS');
  H(ALanguage,
    '  /etc/superterm/sshd/server.ini      public persistent configuration',
    '  /etc/superterm/sshd/server.ini      configuracion publica persistente');
  H(ALanguage,
    '  /etc/superterm/sshd/sshd_config.generated  generated; never edit it',
    '  /etc/superterm/sshd/sshd_config.generated  generado; no se edita');
  H(ALanguage,
    '  /etc/superterm/sshd/ssh_host_ed25519_key   dedicated host identity',
    '  /etc/superterm/sshd/ssh_host_ed25519_key   identidad host dedicada');
  H(ALanguage,
    '  /etc/superterm/sshd/ssh_host_ed25519_key.pub  public host identity',
    '  /etc/superterm/sshd/ssh_host_ed25519_key.pub  identidad host publica');
  H(ALanguage,
    '  /etc/superterm/sshd/authorized_keys/USER   centrally managed keys',
    '  /etc/superterm/sshd/authorized_keys/USUARIO  claves centrales');
  H(ALanguage,
    '  /etc/superterm/sshd/.admin.lock            serialized admin changes',
    '  /etc/superterm/sshd/.admin.lock            cambios admin serializados');
  H(ALanguage,
    '  /var/run/superterm-sshd.pid         dedicated runtime PID file',
    '  /var/run/superterm-sshd.pid         fichero PID propio de ejecucion');
  H(ALanguage,
    '  /etc/systemd/system/superterm-sshd.service  GNU/Linux service',
    '  /etc/systemd/system/superterm-sshd.service  servicio GNU/Linux');
  H(ALanguage,
    '  /Library/LaunchDaemons/org.superterm.sshd.plist  macOS service',
    '  /Library/LaunchDaemons/org.superterm.sshd.plist  servicio macOS');
  Blank;
  H(ALanguage, 'INSTALLATION SAFETY REQUIREMENTS',
    'REQUISITOS DE SEGURIDAD DE INSTALACION');
  H(ALanguage,
    '  sshd must be /usr/bin/sshd or /usr/sbin/sshd. ssh-keygen must be one of',
    '  sshd debe ser /usr/bin/sshd o /usr/sbin/sshd. ssh-keygen debe ser uno de');
  H(ALanguage,
    '  /usr/bin/ssh-keygen, /usr/local/bin/ssh-keygen or',
    '  /usr/bin/ssh-keygen, /usr/local/bin/ssh-keygen o');
  H(ALanguage,
    '  /opt/homebrew/bin/ssh-keygen, with protected ownership and path.',
    '  /opt/homebrew/bin/ssh-keygen, con propietario y ruta protegidos.');
  H(ALanguage,
    '  The SuperTerm executable and every ancestor must be protected, root-owned',
    '  El ejecutable SuperTerm y sus directorios deben estar protegidos, ser de');
  H(ALanguage,
    '  and executable by SSH users; setuid/setgid is rejected. Install the package:',
    '  root y ejecutables por usuarios SSH; rechaza setuid/setgid. Instala el');
  H(ALanguage,
    '  setup from a user-owned source checkout correctly fails closed.',
    '  paquete: configurar desde un checkout de usuario falla de forma segura.');
  H(ALanguage,
    '  /etc/ssh/sshrc must be absent because OpenSSH would run it before the',
    '  /etc/ssh/sshrc debe estar ausente: OpenSSH lo ejecutaria antes del');
  H(ALanguage,
    '  forced command and provides no directive to disable it.',
    '  comando forzado y no ofrece directiva para deshabilitarlo.');
  Blank;
  H(ALanguage, 'CLIENT SYNOPSIS', 'SINOPSIS DEL CLIENTE');
  H(ALanguage, '  ssh -p 8022 user@server',
    '  ssh -p 8022 usuario@servidor');
  H(ALanguage,
    '  Interactive ssh allocates a PTY automatically. Use -tt only from a',
    '  ssh interactivo asigna PTY automaticamente. Usa -tt solo desde un');
  H(ALanguage,
    '  non-terminal caller; use -i only for a nonstandard client key path.',
    '  proceso sin terminal; usa -i solo para una clave cliente no estandar.');
  H(ALanguage,
    '  authorize reads a public-key file on the server; client -i names the',
    '  autorizar lee una clave publica en el servidor; -i nombra la privada');
  H(ALanguage,
    '  matching private key on the client. Never copy that private key.',
    '  correspondiente en el cliente. Nunca copies esa clave privada.');
  Blank;
  H(ALanguage, 'FORCED SSH POLICY', 'POLITICA SSH FORZADA');
  H(ALanguage,
    '  Every login is forced to superterm --ssh-entry with one PTY. Remote exec,',
    '  Todo login queda forzado a superterm --ssh-entry con un PTY. Se rechazan');
  H(ALanguage,
    '  no-PTY, SCP/SFTP, subsystems, X11, agent, TCP and Unix forwarding are',
    '  exec remoto, sin PTY, SCP/SFTP, subsistemas, X11 y forwarding de agente,');
  H(ALanguage,
    '  rejected. UserRC, AcceptEnv, SetEnv, Match and Include are disabled.',
    '  TCP y Unix. UserRC, AcceptEnv, SetEnv, Match e Include estan desactivados.');
  H(ALanguage,
    '  MaxSessions=1, MaxAuthTries=3, LoginGraceTime=30 and',
    '  MaxSessions=1, MaxAuthTries=3, LoginGraceTime=30 y');
  H(ALanguage,
    '  MaxStartups=10:30:30; keepalive is 30 seconds times 3.',
    '  MaxStartups=10:30:30; keepalive es 30 segundos por 3.');
  H(ALanguage,
    '  Detach, terminal close and network loss keep the SuperTerm session live.',
    '  Detach, cerrar terminal o perder red conserva viva la sesion SuperTerm.');
  Blank;
  H(ALanguage, 'ADMIN EXIT CODES', 'CODIGOS DE SALIDA ADMINISTRATIVOS');
  H(ALanguage, '  0  success or help', '  0  exito o ayuda');
  H(ALanguage,
    '  1  privilege, configuration, key, service or validation failure',
    '  1  fallo de privilegio, configuracion, clave, servicio o validacion');
  H(ALanguage,
    '  2  unknown command or invalid argument count',
    '  2  orden desconocida o numero de argumentos invalido');
  H(ALanguage,
    '  3  status found the dedicated service inactive',
    '  3  estado encontro inactivo el servicio dedicado');
  Blank;
  H(ALanguage, 'SAFE SETUP EXAMPLE', 'EJEMPLO DE CONFIGURACION SEGURA');
  H(ALanguage, '  sudo superterm ssh-server setup',
    '  sudo superterm servidor-ssh configurar');
  H(ALanguage, '  sudoedit /etc/superterm/sshd/server.ini',
    '  sudoedit /etc/superterm/sshd/server.ini');
  H(ALanguage, '  sudo superterm ssh-server check',
    '  sudo superterm servidor-ssh comprobar');
  H(ALanguage, '  sudo superterm ssh-server restart',
    '  sudo superterm servidor-ssh reiniciar');
  H(ALanguage, '  sudo superterm ssh-server status',
    '  sudo superterm servidor-ssh estado');
  H(ALanguage, '  ssh -p 8022 user@server',
    '  ssh -p 8022 usuario@servidor');
  Blank;
  H(ALanguage, 'ROOT PUBLIC-KEY EXAMPLE', 'EJEMPLO ROOT SOLO CON CLAVE');
  H(ALanguage, '  # in /etc/superterm/sshd/server.ini:',
    '  # en /etc/superterm/sshd/server.ini:');
  H(ALanguage, '  allow_root=1', '  allow_root=1');
  H(ALanguage, '  managed_authorized_keys=1',
    '  managed_authorized_keys=1');
  H(ALanguage,
    '  sudo superterm ssh-server authorize root /path/root_ed25519.pub',
    '  sudo superterm servidor-ssh autorizar root /ruta/root_ed25519.pub');
  H(ALanguage, '  sudo superterm ssh-server check',
    '  sudo superterm servidor-ssh comprobar');
  H(ALanguage, '  sudo superterm ssh-server restart',
    '  sudo superterm servidor-ssh reiniciar');
  H(ALanguage, '  ssh -i ~/.ssh/root_ed25519 -p 8022 root@server',
    '  ssh -i ~/.ssh/root_ed25519 -p 8022 root@servidor');
  Blank;
  H(ALanguage, 'ADMIN COMMAND EXAMPLES', 'EJEMPLOS DE ORDENES ADMINISTRATIVAS');
  H(ALanguage, '  sudo superterm ssh-server setup',
    '  sudo superterm servidor-ssh configurar');
  H(ALanguage, '  sudo superterm ssh-server check',
    '  sudo superterm servidor-ssh comprobar');
  H(ALanguage, '  sudo superterm ssh-server restart',
    '  sudo superterm servidor-ssh reiniciar');
  H(ALanguage, '  sudo superterm ssh-server status',
    '  sudo superterm servidor-ssh estado');
  H(ALanguage, '  sudo superterm ssh-server enable',
    '  sudo superterm servidor-ssh habilitar');
  H(ALanguage, '  sudo superterm ssh-server disable',
    '  sudo superterm servidor-ssh deshabilitar');
  H(ALanguage, '  sudo superterm ssh-server uninstall-service',
    '  sudo superterm servidor-ssh desinstalar-servicio');
  H(ALanguage,
    '  sudo superterm ssh-server authorize user ~/.ssh/superterm_ed25519.pub',
    '  sudo superterm servidor-ssh autorizar usuario ~/.ssh/superterm_ed25519.pub');
  H(ALanguage, '  sudo superterm ssh-server list-keys',
    '  sudo superterm servidor-ssh listar-claves');
  H(ALanguage, '  sudo superterm ssh-server list-keys user',
    '  sudo superterm servidor-ssh listar-claves usuario');
  H(ALanguage,
    '  sudo superterm ssh-server revoke user ~/.ssh/old_superterm_ed25519.pub',
    '  sudo superterm servidor-ssh revocar usuario ~/.ssh/old_superterm_ed25519.pub');
  H(ALanguage, '  superterm ssh-server help',
    '  superterm servidor-ssh ayuda');
  Blank;
  H(ALanguage,
    'Full reference: https://github.com/garacil/superterm/blob/main/docs/SSH_SERVER.md',
    'Referencia: https://github.com/garacil/superterm/blob/main/docs/SSH_SERVER.md');
  Blank;
  SeeAlso(ALanguage, 'superterm --help ssh; superterm --help exit-codes',
    'superterm --ayuda ssh; superterm --ayuda codigos');
end;

procedure HelpInternals(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'RESERVED INTERNAL ENTRY POINTS',
    'PUNTOS DE ENTRADA INTERNOS RESERVADOS');
  H(ALanguage,
    '  --ssh-entry       exact one-argument OpenSSH ForceCommand adapter',
    '  --ssh-entry       adaptador ForceCommand OpenSSH de un solo argumento');
  H(ALanguage,
    '  ssh-server run    foreground wrapper used by systemd or launchd',
    '  servidor-ssh ejecutar  wrapper usado por systemd o launchd');
  Blank;
  H(ALanguage, 'BEHAVIOR', 'COMPORTAMIENTO');
  H(ALanguage,
    '  These forms are implementation protocols, not user commands. Never put',
    '  Estas formas son protocolos internos, no ordenes de usuario. Nunca las');
  H(ALanguage,
    '  them in scripts: --ssh-entry validates sshd-owned PTY/environment state,',
    '  uses en scripts: --ssh-entry valida el PTY/entorno que pertenece a sshd,');
  H(ALanguage,
    '  and run requires the root service boundary before it execs system sshd.',
    '  y ejecutar exige el limite root antes de ejecutar el sshd del sistema.');
  H(ALanguage,
    '  Use "ssh -p PORT USER@HOST" and the public ssh-server admin commands.',
    '  Usa "ssh -p PUERTO USUARIO@HOST" y las ordenes admin publicas.');
  Blank;
  SeeAlso(ALanguage, 'superterm --help ssh-server; superterm --help reference',
    'superterm --ayuda servidor-ssh; superterm --ayuda referencia');
end;

procedure HelpReference(ALanguage: TUiLanguage);
begin
  Page(ALanguage, 'AUTOMATION REFERENCE', 'REFERENCIA DE AUTOMATIZACION');
  H(ALanguage,
    'Stable exit values, diagnostics, language selection and version output',
    'Valores de salida, diagnosticos, idioma y version estables para scripts');
  H(ALanguage,
    'for scripts and agents. Complete reference pages follow.',
    'y agentes. A continuacion aparecen sus paginas completas.');
  Blank;
  HelpExitCodes(ALanguage);
  HelpLanguage(ALanguage);
  HelpVersion(ALanguage);
  HelpInternals(ALanguage);
end;

procedure HelpAll(ALanguage: TUiLanguage);
begin
  PrintCliHelpIndex(ALanguage);
  Blank;
  HelpStartup(ALanguage);
  HelpTargets(ALanguage);
  HelpSessions(ALanguage);
  HelpPanes(ALanguage);
  HelpWindows(ALanguage);
  HelpSshClient(ALanguage);
  PrintSshServerHelp(ALanguage);
  HelpReference(ALanguage);
end;

function PrintCliHelpTopic(const ANormalizedTopic: string;
  ALanguage: TUiLanguage): boolean;
begin
  Result := True;
  case ANormalizedTopic of
    '', 'help', 'ayuda', 'index', 'indice', 'topics', 'temas':
      PrintCliHelpIndex(ALanguage);
    'startup', 'start', 'run', 'inicio', 'arranque':
      HelpStartup(ALanguage);
    'targets', 'target', 'destinos', 'destino':
      HelpTargets(ALanguage);
    'sessions', 'session', 'sesiones', 'sesion':
      HelpSessions(ALanguage);
    'list', 'ls', 'listar': HelpList(ALanguage);
    'attach', 'conectar': HelpAttach(ALanguage);
    'kill', 'matar': HelpKill(ALanguage);
    'panes', 'pane', 'paneles', 'panel', 'io': HelpPanes(ALanguage);
    'send', 'enviar': HelpSend(ALanguage);
    'capture', 'capturar': HelpCapture(ALanguage);
    'windows', 'window', 'ventanas', 'ventana': HelpWindows(ALanguage);
    'new', 'nueva', 'nuevo': HelpNew(ALanguage);
    'close', 'cerrar': HelpClose(ALanguage);
    'focus', 'select', 'foco', 'seleccionar': HelpFocus(ALanguage);
    'rename', 'renombrar': HelpRename(ALanguage);
    'resize', 'tamano', 'redimensionar': HelpResize(ALanguage);
    'minimize', 'minimizar': HelpMinimize(ALanguage);
    'restore', 'restaurar': HelpRestore(ALanguage);
    'zoom', 'ampliar': HelpZoom(ALanguage);
    'organize', 'organizar': HelpOrganize(ALanguage);
    'ssh', 'ssh-client', 'cliente-ssh': HelpSshClient(ALanguage);
    'ssh-server', 'server-ssh', 'servidor-ssh':
      PrintSshServerHelp(ALanguage);
    'reference', 'automation', 'referencia', 'automatizacion':
      HelpReference(ALanguage);
    'exit-codes', 'exitcodes', 'codes', 'status', 'codigos', 'salida':
      HelpExitCodes(ALanguage);
    'language', 'languages', 'idioma', 'idiomas', 'aliases', 'alias':
      HelpLanguage(ALanguage);
    'version': HelpVersion(ALanguage);
    'internals', 'internal', 'internos', 'interno': HelpInternals(ALanguage);
    'all', 'complete', 'todo', 'completo': HelpAll(ALanguage);
  else
    Result := False;
  end;
end;

end.
