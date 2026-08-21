(*
  Autor: Germán Luis Aracil Boned
  Proyecto: superterm - terminal con autologin, splits y sesiones
  Unidad: st_cli - linea de comandos de control de sesiones

  Subcomandos amables inspirados en tmux: listar sesiones y paneles con
  detalles, enviar texto a cualquier panel, capturar pantalla o historial,
  y gestionar la sesion. Todos los comandos y opciones se aceptan en ingles
  Y en espanol (insensibles a mayusculas y acentos); los mensajes y la
  ayuda salen en el idioma configurado en [ui] language.

  Codigos de salida: 0 ok, 1 no encontrado/ambiguo, 2 error de uso,
  3 fallo de conexion o daemon antiguo sin soporte de control.
*)

unit st_cli;

{$mode objfpc}{$H+}

interface

// procesa la linea de comandos; si era un comando de CLI, ejecuta y hace
// Halt con su codigo; si no (arranque normal de la TUI o --attach), vuelve
procedure RunCli;

implementation

uses
  Classes, SysUtils, st_config, st_server;

type
  THelpLine = record
    En, Es: string;
  end;

var
  CliArgs: array of string;

// ---------------------------------------------------------------- util

function T(const AEn, AEs: string): string;
begin
  if CurrentLanguage = ulSpanish then
    Result := AEs
  else
    Result := AEn;
end;

// normaliza un token para comparar: minusculas, sin guiones iniciales y
// sin acentos (secuencias UTF-8 de dos bytes -> ascii)
function NormToken(const S: string): string;
var
  i: integer;
  R: string;
  b1, b2: byte;
begin
  R := '';
  i := 1;
  while i <= Length(S) do
  begin
    b1 := byte(S[i]);
    if (b1 = $C3) and (i < Length(S)) then
    begin
      b2 := byte(S[i + 1]);
      case b2 of
        $A1, $81: R := R + 'a';   // á Á
        $A9, $89: R := R + 'e';   // é É
        $AD, $8D: R := R + 'i';   // í Í
        $B3, $93: R := R + 'o';   // ó Ó
        $BA, $9A: R := R + 'u';   // ú Ú
        $BC, $9C: R := R + 'u';   // ü Ü
        $B1, $91: R := R + 'n';   // ñ Ñ
      else
        R := R + S[i] + S[i + 1];
      end;
      Inc(i, 2);
    end
    else
    begin
      R := R + LowerCase(S[i]);
      Inc(i);
    end;
  end;
  // sin guiones iniciales: '--lineas' y 'lineas' comparan igual
  while (R <> '') and (R[1] = '-') do
    Delete(R, 1, 1);
  Result := R;
end;

function IsFlag(const S: string): boolean;
begin
  Result := (S <> '') and (S[1] = '-') and (S <> '-');
end;

procedure ErrLn(const S: string);
begin
  WriteLn(StdErr, S);
end;

// ---------------------------------------------------------------- destinos

function ListLive(out Infos: TSessionInfoArray): boolean;
begin
  Result := EnumerateSessions(Infos);
end;

// separa 'sesion:panel' / 'sesion.panel' / '.' / '.panel' / ':panel'
procedure SplitTargetSpec(const Spec: string; out Ses, Pane: string);
var
  i: integer;
begin
  Ses := Spec;
  Pane := '';
  for i := 1 to Length(Spec) do
    if Spec[i] in [':', '.'] then
    begin
      Ses := Copy(Spec, 1, i - 1);
      Pane := Copy(Spec, i + 1, MaxInt);
      Break;
    end;
end;

function AllDigits(const S: string): boolean;
var
  i: integer;
begin
  Result := S <> '';
  for i := 1 to Length(S) do
    if not (S[i] in ['0'..'9']) then
      Exit(False);
end;

// resuelve el nombre de sesion: exacto -> sanitizado -> case-insensitive ->
// prefijo unico; '' o '.' = la unica viva
function ResolveSession(const AName: string; ADefaultOk: boolean;
  out AInfo: TSessionInfo): integer;   // 0 ok, 1 error (ya impreso)
var
  Infos: TSessionInfoArray;
  i, Hit, Matches: integer;
  Cand: string;
begin
  Result := 1;
  AInfo := Default(TSessionInfo);
  if not ListLive(Infos) then
  begin
    ErrLn(T('superterm: no sessions are running',
      'superterm: no hay sesiones activas'));
    Exit;
  end;
  if (AName = '') or (AName = '.') then
  begin
    if not ADefaultOk then
    begin
      ErrLn(T('superterm: a session name is required here',
        'superterm: aqui es obligatorio el nombre de la sesion'));
      Exit;
    end;
    if Length(Infos) = 1 then
    begin
      AInfo := Infos[0];
      Exit(0);
    end;
    Cand := '';
    for i := 0 to High(Infos) do
    begin
      if Cand <> '' then
        Cand := Cand + ', ';
      Cand := Cand + Infos[i].Name;
    end;
    ErrLn(Format(T('superterm: several sessions are running; name one: %s',
      'superterm: hay varias sesiones activas; indica una: %s'), [Cand]));
    Exit;
  end;
  // exacto
  for i := 0 to High(Infos) do
    if Infos[i].Name = AName then
    begin
      AInfo := Infos[i];
      Exit(0);
    end;
  // sanitizado
  for i := 0 to High(Infos) do
    if Infos[i].Name = SanitizeSessionName(AName) then
    begin
      AInfo := Infos[i];
      Exit(0);
    end;
  // case-insensitive
  Hit := -1;
  Matches := 0;
  for i := 0 to High(Infos) do
    if SameText(Infos[i].Name, AName) then
    begin
      Hit := i;
      Inc(Matches);
    end;
  if Matches = 1 then
  begin
    AInfo := Infos[Hit];
    Exit(0);
  end;
  // prefijo unico
  Hit := -1;
  Matches := 0;
  Cand := '';
  for i := 0 to High(Infos) do
    if (Length(AName) <= Length(Infos[i].Name)) and
       SameText(Copy(Infos[i].Name, 1, Length(AName)), AName) then
    begin
      Hit := i;
      Inc(Matches);
      if Cand <> '' then
        Cand := Cand + ', ';
      Cand := Cand + Infos[i].Name;
    end;
  if Matches = 1 then
  begin
    AInfo := Infos[Hit];
    Exit(0);
  end;
  if Matches > 1 then
    ErrLn(Format(T('superterm: ''%s'' matches several sessions: %s',
      'superterm: ''%s'' coincide con varias sesiones: %s'), [AName, Cand]))
  else
    ErrLn(Format(T('superterm: no session named ''%s''',
      'superterm: no hay ninguna sesion llamada ''%s'''), [AName]));
end;

// ------------------------------------------------- lecturas de LIST/INFO

type
  TPaneRow = record
    Title, Term, Host, User, Cmd, Cwd: string;
    Kind: byte;
    Cols, Rows, Hist: Longint;
    BX, BY, BW, BH: Longint;
    Zoomed, Minimized, Alive: boolean;
  end;
  TPaneRows = array of TPaneRow;

  TListInfo = record
    Name, Profile: string;
    PaneCount, Focused, Attached, DeskW, DeskH: Longint;
    Panes: TPaneRows;
  end;

  TBlobGrab = class
    Blob: TByteArray;
    procedure OnData(const AChunk: TByteArray);
  end;

  TTextGrab = class
    Text: RawByteString;
    Sink: TStream;   // si no es nil, va directo (fichero/stdout)
    procedure OnData(const AChunk: TByteArray);
  end;

procedure TBlobGrab.OnData(const AChunk: TByteArray);
var
  Ofs: integer;
begin
  Ofs := Length(Blob);
  SetLength(Blob, Ofs + Length(AChunk));
  if Length(AChunk) > 0 then
    Move(AChunk[0], Blob[Ofs], Length(AChunk));
end;

procedure TTextGrab.OnData(const AChunk: TByteArray);
var
  S: RawByteString;
begin
  if Length(AChunk) = 0 then
    Exit;
  SetString(S, PAnsiChar(@AChunk[0]), Length(AChunk));
  if Sink <> nil then
    Sink.WriteBuffer(S[1], Length(S))
  else
    Text := Text + S;
end;

function BlobStr(const B: TByteArray; var Ofs: integer): string;
var
  L: Longint;
begin
  Result := '';
  L := Default(Longint);
  if Ofs + SizeOf(Longint) > Length(B) then
    Exit;
  Move(B[Ofs], L, SizeOf(L));
  Inc(Ofs, SizeOf(L));
  if (L < 0) or (Ofs + L > Length(B)) then
    Exit;
  SetLength(Result, L);
  if L > 0 then
    Move(B[Ofs], Result[1], L);
  Inc(Ofs, L);
end;

function BlobInt(const B: TByteArray; var Ofs: integer): Longint;
begin
  Result := 0;
  if Ofs + SizeOf(Longint) > Length(B) then
    Exit;
  Move(B[Ofs], Result, SizeOf(Longint));
  Inc(Ofs, SizeOf(Longint));
end;

function BlobByte(const B: TByteArray; var Ofs: integer): byte;
begin
  Result := 0;
  if Ofs < Length(B) then
  begin
    Result := B[Ofs];
    Inc(Ofs);
  end;
end;

function FetchList(const ASocket: string; WithPanes: boolean;
  out L: TListInfo): boolean;
var
  G: TBlobGrab;
  Ofs, i: integer;
  Kind: byte;
begin
  Result := False;
  L := Default(TListInfo);
  G := TBlobGrab.Create;
  try
    if WithPanes then
      Kind := FRAME_CTL_LIST
    else
      Kind := FRAME_CTL_INFO;
    if not CtlStream(ASocket, Kind, -1, nil, @G.OnData) then
      Exit;
    Ofs := 0;
    L.Name := BlobStr(G.Blob, Ofs);
    L.Profile := BlobStr(G.Blob, Ofs);
    L.PaneCount := BlobInt(G.Blob, Ofs);
    L.Focused := BlobInt(G.Blob, Ofs);
    L.Attached := BlobInt(G.Blob, Ofs);
    L.DeskW := BlobInt(G.Blob, Ofs);
    L.DeskH := BlobInt(G.Blob, Ofs);
    if WithPanes then
    begin
      SetLength(L.Panes, L.PaneCount);
      for i := 0 to L.PaneCount - 1 do
      begin
        L.Panes[i].Title := BlobStr(G.Blob, Ofs);
        L.Panes[i].Term := BlobStr(G.Blob, Ofs);
        L.Panes[i].Kind := BlobByte(G.Blob, Ofs);
        L.Panes[i].Host := BlobStr(G.Blob, Ofs);
        L.Panes[i].User := BlobStr(G.Blob, Ofs);
        L.Panes[i].Cmd := BlobStr(G.Blob, Ofs);
        L.Panes[i].Cwd := BlobStr(G.Blob, Ofs);
        L.Panes[i].Cols := BlobInt(G.Blob, Ofs);
        L.Panes[i].Rows := BlobInt(G.Blob, Ofs);
        L.Panes[i].Hist := BlobInt(G.Blob, Ofs);
        L.Panes[i].BX := BlobInt(G.Blob, Ofs);
        L.Panes[i].BY := BlobInt(G.Blob, Ofs);
        L.Panes[i].BW := BlobInt(G.Blob, Ofs);
        L.Panes[i].BH := BlobInt(G.Blob, Ofs);
        L.Panes[i].Zoomed := BlobByte(G.Blob, Ofs) <> 0;
        L.Panes[i].Minimized := BlobByte(G.Blob, Ofs) <> 0;
        L.Panes[i].Alive := BlobByte(G.Blob, Ofs) <> 0;
      end;
    end;
    Result := True;
  finally
    G.Free;
  end;
end;

// resuelve el panel dentro de una sesion: indice 1-based o subcadena de
// titulo unica; '' = panel enfocado
function ResolvePane(const ASocket, ASession, ASpec: string;
  out APane: integer): integer;
var
  L: TListInfo;
  i, Hit, Matches: integer;
  Cand: string;
begin
  Result := 1;
  APane := -1;
  if not FetchList(ASocket, True, L) then
  begin
    ErrLn(Format(T('superterm: cannot connect to session ''%s''',
      'superterm: no se puede conectar con la sesion ''%s'''), [ASession]));
    Exit(3);
  end;
  if ASpec = '' then
  begin
    APane := L.Focused;
    if (APane < 0) or (APane >= L.PaneCount) then
      APane := 0;
    Exit(0);
  end;
  if AllDigits(ASpec) then
  begin
    APane := StrToIntDef(ASpec, 0) - 1;
    if (APane < 0) or (APane >= L.PaneCount) then
    begin
      ErrLn(Format(T('superterm: session ''%s'' has no pane %s (valid: 1..%d)',
        'superterm: la sesion ''%s'' no tiene panel %s (validos: 1..%d)'),
        [ASession, ASpec, L.PaneCount]));
      Exit(1);
    end;
    Exit(0);
  end;
  Hit := -1;
  Matches := 0;
  Cand := '';
  for i := 0 to L.PaneCount - 1 do
    if Pos(NormToken(ASpec), NormToken(L.Panes[i].Title)) > 0 then
    begin
      Hit := i;
      Inc(Matches);
      if Cand <> '' then
        Cand := Cand + ', ';
      Cand := Cand + Format('%d (%s)', [i + 1, Trim(L.Panes[i].Title)]);
    end;
  if Matches = 1 then
  begin
    APane := Hit;
    Exit(0);
  end;
  if Matches > 1 then
    ErrLn(Format(T('superterm: ''%s'' matches several panes of ''%s'': %s',
      'superterm: ''%s'' coincide con varios paneles de ''%s'': %s'),
      [ASpec, ASession, Cand]))
  else
    ErrLn(Format(T('superterm: no pane matches ''%s'' in ''%s''',
      'superterm: ningun panel coincide con ''%s'' en ''%s'''),
      [ASpec, ASession]));
end;

// ---------------------------------------------------------------- ayuda

procedure PrintLines(const L: array of THelpLine);
var
  i: integer;
begin
  for i := 0 to High(L) do
    WriteLn(T(L[i].En, L[i].Es));
end;

procedure HelpGlobal;
const
  L: array[0..33] of THelpLine = (
    (En: 'superterm %V - detachable terminal sessions for GNU/Linux and macOS';
     Es: 'superterm %V - sesiones de terminal separables para GNU/Linux y macOS'),
    (En: ''; Es: ''),
    (En: 'Usage:'; Es: 'Uso:'),
    (En: '  superterm                              start the interactive terminal';
     Es: '  superterm                              abre el terminal interactivo'),
    (En: '  superterm <command> [TARGET] [options]';
     Es: '  superterm <orden> [DESTINO] [opciones]'),
    (En: '  superterm help <command>               detailed help with examples';
     Es: '  superterm ayuda <orden>                ayuda detallada con ejemplos'),
    (En: ''; Es: ''),
    (En: 'Targets:  SESSION | SESSION:PANE | .    (pane = number shown in the';
     Es: 'Destinos: SESION | SESION:PANEL | .     (panel = numero del titulo de'),
    (En: '          window title, or part of its title; ''.'' = the only session)';
     Es: '          la ventana, o parte de su titulo; ''.'' = la unica sesion)'),
    (En: ''; Es: ''),
    (En: 'Sessions:'; Es: 'Sesiones:'),
    (En: '  list      [SESSION]        list sessions, or the panes of one';
     Es: '  listar    [SESION]         lista sesiones, o los paneles de una'),
    (En: '  attach    [SESSION]        attach the terminal UI';
     Es: '  conectar  [SESION]         conecta el terminal interactivo'),
    (En: '  kill      SESSION          terminate a session and its programs';
     Es: '  matar     SESION           termina una sesion y sus programas'),
    (En: ''; Es: ''),
    (En: 'Panes:'; Es: 'Paneles:'),
    (En: '  send      TARGET TEXT...   type into a pane (adds Enter; -n raw)';
     Es: '  enviar    DESTINO TEXTO... escribe en un panel (anade Intro; -n no)'),
    (En: '  capture   [TARGET]         print a pane (screen, -H history, -l N)';
     Es: '  capturar  [DESTINO]        vuelca un panel (pantalla, -H todo, -l N)'),
    (En: ''; Es: ''),
    (En: 'General:'; Es: 'General:'),
    (En: '  help [command]   version   (also --help/--ayuda, --version)';
     Es: '  ayuda [orden]    version   (tambien --help/--ayuda, --version)'),
    (En: ''; Es: ''),
    (En: 'Every command and option is also accepted in Spanish (enviar,';
     Es: 'Todas las ordenes y opciones se aceptan tambien en ingles (send,'),
    (En: 'listar, capturar, --ayuda, ...). Messages follow [ui] language.';
     Es: 'list, capture, --help, ...). Los mensajes siguen [ui] language.'),
    (En: 'Legacy --attach and --list-sessions still work.';
     Es: 'Los antiguos --attach y --list-sessions siguen funcionando.'),
    (En: ''; Es: ''),
    (En: 'Examples:'; Es: 'Ejemplos:'),
    (En: '  superterm send prod:2 tail -f /var/log/syslog';
     Es: '  superterm enviar prod:2 tail -f /var/log/syslog'),
    (En: '  superterm capture prod:2 --lines 200 -o log.txt';
     Es: '  superterm capturar prod:2 --lineas 200 -o log.txt'),
    (En: '  superterm capture . --history | grep ERROR';
     Es: '  superterm capturar . --historico | grep ERROR'),
    (En: '  superterm list prod'; Es: '  superterm listar prod'),
    (En: '  superterm send . make'; Es: '  superterm enviar . make'),
    (En: '  cat script.sh | superterm send prod:1 -';
     Es: '  cat script.sh | superterm enviar prod:1 -'),
    (En: ''; Es: ''));
var
  i: integer;
  S: string;
begin
  for i := 0 to High(L) do
  begin
    S := T(L[i].En, L[i].Es);
    S := StringReplace(S, '%V', SUPERTERM_VERSION, []);
    WriteLn(S);
  end;
end;

procedure HelpSend;
const
  L: array[0..14] of THelpLine = (
    (En: 'superterm send - type text into a pane of a session';
     Es: 'superterm enviar - escribe texto en un panel de una sesion'),
    (En: ''; Es: ''),
    (En: 'Usage:  superterm send [options] TARGET TEXT...';
     Es: 'Uso:    superterm enviar [opciones] DESTINO TEXTO...'),
    (En: '        superterm send TARGET -          (raw stdin, no Enter added)';
     Es: '        superterm enviar DESTINO -       (stdin crudo, sin Intro)'),
    (En: ''; Es: ''),
    (En: 'TARGET is required; use ''.'' for the only session. Everything after';
     Es: 'El DESTINO es obligatorio; ''.'' = la unica sesion. Todo lo que sigue'),
    (En: 'TARGET is sent literally, then Enter (unless -n).';
     Es: 'al DESTINO se envia literal, y despues Intro (salvo con -n).'),
    (En: ''; Es: ''),
    (En: 'Options:'; Es: 'Opciones:'),
    (En: '  -n, --no-enter   (es: --sin-intro)   do not append Enter';
     Es: '  -n, --sin-intro  (en: --no-enter)    no anadir Intro'),
    (En: '  -k, --key NAME   (es: --tecla)       send a named key (repeatable):';
     Es: '  -k, --tecla NOMBRE (en: --key)       envia una tecla (repetible):'),
    (En: '       Enter Esc Tab Space Up Down Left Right Home End PgUp PgDn';
     Es: '       Intro Esc Tab Espacio Arriba Abajo Izquierda Derecha ...'),
    (En: '       F1..F12  C-a..C-z (^C)  M-x (Alt)';
     Es: '       F1..F12  C-a..C-z (^C)  M-x (Alt)'),
    (En: ''; Es: ''),
    (En: 'Examples:  superterm send prod:2 ls -la  |  superterm send . -k C-c';
     Es: 'Ejemplos:  superterm enviar prod:2 ls -la | superterm enviar . -k C-c'));
begin
  PrintLines(L);
end;

procedure HelpCapture;
const
  L: array[0..12] of THelpLine = (
    (En: 'superterm capture - print a pane as plain UTF-8 text';
     Es: 'superterm capturar - vuelca un panel como texto plano UTF-8'),
    (En: ''; Es: ''),
    (En: 'Usage:  superterm capture [TARGET] [options]';
     Es: 'Uso:    superterm capturar [DESTINO] [opciones]'),
    (En: ''; Es: ''),
    (En: 'By default prints the visible screen of the focused pane.';
     Es: 'Por defecto vuelca la pantalla visible del panel enfocado.'),
    (En: ''; Es: ''),
    (En: 'Options:'; Es: 'Opciones:'),
    (En: '  -H, --history    (es: --historico)   the whole scrollback + screen';
     Es: '  -H, --historico  (en: --history)     todo el historial + pantalla'),
    (En: '  -l, --lines N    (es: --lineas)      only the last N lines';
     Es: '  -l, --lineas N   (en: --lines)       solo las ultimas N lineas'),
    (En: '  -o, --output F   (es: --salida)      write to a file, not stdout';
     Es: '  -o, --salida F   (en: --output)      escribe a fichero, no stdout'),
    (En: ''; Es: ''),
    (En: 'Examples:  superterm capture prod:2 -H | grep ERROR';
     Es: 'Ejemplos:  superterm capturar prod:2 -H | grep ERROR'),
    (En: '           superterm capture . --lines 100 -o out.txt';
     Es: '           superterm capturar . --lineas 100 -o out.txt'));
begin
  PrintLines(L);
end;

procedure HelpList;
const
  L: array[0..9] of THelpLine = (
    (En: 'superterm list - list sessions, or the panes of one session';
     Es: 'superterm listar - lista sesiones, o los paneles de una sesion'),
    (En: ''; Es: ''),
    (En: 'Usage:  superterm list            (sessions table)';
     Es: 'Uso:    superterm listar          (tabla de sesiones)'),
    (En: '        superterm list SESSION    (pane details of one session)';
     Es: '        superterm listar SESION   (detalle de paneles de una)'),
    (En: ''; Es: ''),
    (En: 'Pane columns: index, title, type (local/ssh/command), target';
     Es: 'Columnas: indice, titulo, tipo (local/ssh/command), destino'),
    (En: '(user@host), running command, size, history lines, flags';
     Es: '(usuario@host), comando en curso, tamano, lineas de historial'),
    (En: '(* focused, M minimized, Z zoomed, ! dead).';
     Es: 'y estado (* foco, M minimizada, Z zoom, ! muerto).'),
    (En: ''; Es: ''),
    (En: 'Example:  superterm list prod'; Es: 'Ejemplo:  superterm listar prod'));
begin
  PrintLines(L);
end;

procedure HelpKill;
const
  L: array[0..5] of THelpLine = (
    (En: 'superterm kill - terminate a session and every program inside it';
     Es: 'superterm matar - termina una sesion y todos sus programas'),
    (En: ''; Es: ''),
    (En: 'Usage:  superterm kill SESSION     (the name is always required)';
     Es: 'Uso:    superterm matar SESION     (el nombre es siempre obligatorio)'),
    (En: ''; Es: ''),
    (En: 'Example:  superterm kill prod'; Es: 'Ejemplo:  superterm matar prod'),
    (En: ''; Es: ''));
begin
  PrintLines(L);
end;

// ---------------------------------------------------------------- teclas

function KeyBytes(const AName: string): RawByteString;
var
  N: string;
  C: char;
begin
  Result := '';
  N := NormToken(AName);
  if (N = 'enter') or (N = 'return') or (N = 'intro') then Exit(#13);
  if (N = 'esc') or (N = 'escape') then Exit(#27);
  if N = 'tab' then Exit(#9);
  if (N = 'backtab') or (N = 'tabatras') then Exit(#27'[Z');
  if (N = 'space') or (N = 'espacio') then Exit(' ');
  if (N = 'backspace') or (N = 'bs') or (N = 'retroceso') then Exit(#127);
  if (N = 'up') or (N = 'arriba') then Exit(#27'[A');
  if (N = 'down') or (N = 'abajo') then Exit(#27'[B');
  if (N = 'right') or (N = 'derecha') then Exit(#27'[C');
  if (N = 'left') or (N = 'izquierda') then Exit(#27'[D');
  if (N = 'home') or (N = 'inicio') then Exit(#27'[H');
  if (N = 'end') or (N = 'fin') then Exit(#27'[F');
  if (N = 'pgup') or (N = 'repag') then Exit(#27'[5~');
  if (N = 'pgdn') or (N = 'avpag') then Exit(#27'[6~');
  if N = 'ins' then Exit(#27'[2~');
  if (N = 'del') or (N = 'supr') then Exit(#27'[3~');
  if (Length(N) >= 2) and (N[1] = 'f') and AllDigits(Copy(N, 2, MaxInt)) then
    case StrToIntDef(Copy(N, 2, MaxInt), 0) of
      1: Exit(#27'OP');
      2: Exit(#27'OQ');
      3: Exit(#27'OR');
      4: Exit(#27'OS');
      5: Exit(#27'[15~');
      6: Exit(#27'[17~');
      7: Exit(#27'[18~');
      8: Exit(#27'[19~');
      9: Exit(#27'[20~');
      10: Exit(#27'[21~');
      11: Exit(#27'[23~');
      12: Exit(#27'[24~');
    end;
  // C-x / ctrl-x / ^x
  if (Length(N) = 2) and (N[1] = '^') and (N[2] in ['a'..'z']) then
    Exit(chr(Ord(N[2]) - Ord('a') + 1));
  if (Copy(N, 1, 2) = 'c-') and (Length(N) = 3) and (N[3] in ['a'..'z']) then
    Exit(chr(Ord(N[3]) - Ord('a') + 1));
  if (Copy(N, 1, 5) = 'ctrl-') and (Length(N) = 6) and
     (N[6] in ['a'..'z']) then
    Exit(chr(Ord(N[6]) - Ord('a') + 1));
  // M-x / alt-x
  if (Copy(N, 1, 2) = 'm-') and (Length(N) = 3) then
  begin
    C := N[3];
    Exit(#27 + C);
  end;
  if (Copy(N, 1, 4) = 'alt-') and (Length(N) = 5) then
  begin
    C := N[5];
    Exit(#27 + C);
  end;
end;

// ---------------------------------------------------------------- comandos

function CmdList(const AArgs: array of string): integer;
var
  Infos: TSessionInfoArray;
  Info: TSessionInfo;
  L: TListInfo;
  i, rc: integer;
  Ses, TypeS, Target, Flags, Att: string;
begin
  L := Default(TListInfo);
  // sin argumento: tabla de sesiones
  Ses := '';
  for i := 0 to High(AArgs) do
    if not IsFlag(AArgs[i]) then
    begin
      Ses := AArgs[i];
      Break;
    end;
  if Ses = '' then
  begin
    if not ListLive(Infos) then
    begin
      WriteLn(T('superterm: no sessions are running',
        'superterm: no hay sesiones activas'));
      Exit(1);
    end;
    WriteLn(Format('%-24s %-16s %5s %8s  %s',
      [T('NAME', 'NOMBRE'), T('PROFILE', 'PERFIL'),
       T('PANES', 'PANEL'), T('CLIENTS', 'CLIENTES'),
       T('CREATED', 'CREADA')]));
    for i := 0 to High(Infos) do
    begin
      Att := '-';
      if FetchList(Infos[i].SocketPath, False, L) then
        Att := IntToStr(L.Attached);
      WriteLn(Format('%-24s %-16s %5d %8s  %s',
        [Infos[i].Name, Infos[i].Profile, Infos[i].PaneCount, Att,
         Infos[i].Created]));
    end;
    Exit(0);
  end;
  // con sesion: detalle de paneles
  rc := ResolveSession(Ses, True, Info);
  if rc <> 0 then
    Exit(rc);
  if not FetchList(Info.SocketPath, True, L) then
  begin
    ErrLn(Format(T('superterm: cannot connect to session ''%s''',
      'superterm: no se puede conectar con la sesion ''%s'''), [Info.Name]));
    Exit(3);
  end;
  WriteLn(Format('%-5s %-22s %-8s %-20s %-16s %-8s %6s  %s',
    [T('PANE', 'PANEL'), T('TITLE', 'TITULO'), T('TYPE', 'TIPO'),
     T('TARGET', 'DESTINO'), T('COMMAND', 'COMANDO'),
     T('SIZE', 'TAMANO'), 'HIST', T('FLAGS', 'ESTADO')]));
  for i := 0 to L.PaneCount - 1 do
  begin
    case L.Panes[i].Kind of
      0: TypeS := 'local';
      1: TypeS := 'ssh';
      2: TypeS := 'command';
    else
      TypeS := '?';
    end;
    Target := '-';
    if L.Panes[i].Host <> '' then
    begin
      if L.Panes[i].User <> '' then
        Target := L.Panes[i].User + '@' + L.Panes[i].Host
      else
        Target := L.Panes[i].Host;
    end;
    Flags := '';
    if i = L.Focused then Flags := Flags + '*';
    if L.Panes[i].Minimized then Flags := Flags + 'M';
    if L.Panes[i].Zoomed then Flags := Flags + 'Z';
    if not L.Panes[i].Alive then Flags := Flags + '!';
    WriteLn(Format('%-5d %-22s %-8s %-20s %-16s %4dx%-3d %6d  %s',
      [i + 1, Copy(Trim(L.Panes[i].Title), 1, 22), TypeS,
       Copy(Target, 1, 20), Copy(L.Panes[i].Cmd, 1, 16),
       L.Panes[i].Cols, L.Panes[i].Rows, L.Panes[i].Hist, Flags]));
  end;
  Exit(0);
end;

function CmdSend(const AArgs: array of string): integer;
var
  i, rc, Pane: integer;
  NoEnter, TargetSeen, TextStarted: boolean;
  TargetSpec, Ses, PaneSpec: string;
  Text: RawByteString;
  Keys: RawByteString;
  K: RawByteString;
  Info: TSessionInfo;
  Reply: string;
  Payload: TByteArray;
  Buf: array[0..4095] of byte;
  N: integer;
begin
  NoEnter := False;
  TargetSeen := False;
  TextStarted := False;
  TargetSpec := '';
  Text := '';
  Keys := '';
  i := 0;
  while i <= High(AArgs) do
  begin
    // los flags -n/-k se aceptan antes del destino Y despues (hasta que
    // empiece el texto); '--' fuerza que el resto sea texto literal
    if not TextStarted then
    begin
      if AArgs[i] = '--' then
      begin
        TextStarted := True;
        Inc(i);
        continue;
      end;
      case NormToken(AArgs[i]) of
        'n', 'noenter', 'sinintro':
          begin
            NoEnter := True;
            Inc(i);
            continue;
          end;
        'k', 'key', 'tecla':
          begin
            if i = High(AArgs) then
            begin
              ErrLn(T('superterm: --key needs a key name',
                'superterm: --tecla necesita un nombre de tecla'));
              Exit(2);
            end;
            K := KeyBytes(AArgs[i + 1]);
            if K = '' then
            begin
              ErrLn(Format(T('superterm: unknown key ''%s''',
                'superterm: tecla desconocida ''%s'''), [AArgs[i + 1]]));
              Exit(2);
            end;
            Keys := Keys + K;
            Inc(i, 2);
            continue;
          end;
      end;
      if IsFlag(AArgs[i]) then
      begin
        if TargetSeen then
        begin
          // opcion desconocida tras el destino: empieza el texto literal
          TextStarted := True;
          continue;
        end;
        ErrLn(Format(T('superterm: unknown option ''%s''. Try ''superterm send --help''.',
          'superterm: opcion desconocida ''%s''. Prueba ''superterm enviar --ayuda''.'),
          [AArgs[i]]));
        Exit(2);
      end;
      if not TargetSeen then
      begin
        TargetSpec := AArgs[i];
        TargetSeen := True;
        Inc(i);
        continue;
      end;
      TextStarted := True;
      continue;
    end;
    if Text <> '' then
      Text := Text + ' ';
    Text := Text + AArgs[i];
    Inc(i);
  end;
  if not TargetSeen then
  begin
    ErrLn(T('superterm: ''send'' needs a target. Try ''superterm send --help''.',
      'superterm: ''enviar'' necesita un destino. Prueba ''superterm enviar --ayuda''.'));
    Exit(2);
  end;
  SplitTargetSpec(TargetSpec, Ses, PaneSpec);
  rc := ResolveSession(Ses, True, Info);
  if rc <> 0 then
    Exit(rc);
  rc := ResolvePane(Info.SocketPath, Info.Name, PaneSpec, Pane);
  if rc <> 0 then
    Exit(rc);
  if Text = '-' then
  begin
    // stdin crudo, sin Intro
    Text := '';
    repeat
      N := FileRead(StdInputHandle, Buf, SizeOf(Buf));
      if N > 0 then
        SetString(K, PAnsiChar(@Buf[0]), N)
      else
        K := '';
      Text := Text + K;
    until N <= 0;
  end
  else
  begin
    if (Text <> '') and (not NoEnter) then
      Text := Text + #13;
  end;
  Text := Text + Keys;
  if Text = '' then
  begin
    ErrLn(T('superterm: nothing to send',
      'superterm: nada que enviar'));
    Exit(2);
  end;
  Payload := nil;
  SetLength(Payload, Length(Text));
  Move(Text[1], Payload[0], Length(Text));
  if not CtlSimple(Info.SocketPath, FRAME_CTL_SEND, Pane, Payload, Reply) then
  begin
    if Reply <> '' then
    begin
      ErrLn('superterm: ' + Reply);
      Exit(1);
    end;
    ErrLn(Format(T('superterm: cannot connect to session ''%s''',
      'superterm: no se puede conectar con la sesion ''%s'''), [Info.Name]));
    Exit(3);
  end;
  Exit(0);
end;

function CmdCapture(const AArgs: array of string): integer;
var
  i, rc, Pane: integer;
  Mode, NLines: Longint;
  OutFile, TargetSpec, Ses, PaneSpec: string;
  Info: TSessionInfo;
  G: TTextGrab;
  Payload: TByteArray;
  FS: TStream;
begin
  Mode := CAPTURE_VISIBLE;
  NLines := 0;
  OutFile := '';
  TargetSpec := '';
  i := 0;
  while i <= High(AArgs) do
  begin
    case NormToken(AArgs[i]) of
      'h', 'history', 'historico':
        Mode := CAPTURE_ALL;
      'l', 'lines', 'lineas':
        begin
          if (i = High(AArgs)) or (not AllDigits(AArgs[i + 1])) then
          begin
            ErrLn(T('superterm: --lines needs a number',
              'superterm: --lineas necesita un numero'));
            Exit(2);
          end;
          Mode := CAPTURE_LAST_N;
          NLines := StrToIntDef(AArgs[i + 1], 0);
          Inc(i);
        end;
      'o', 'output', 'salida':
        begin
          if i = High(AArgs) then
          begin
            ErrLn(T('superterm: --output needs a file name',
              'superterm: --salida necesita un fichero'));
            Exit(2);
          end;
          OutFile := AArgs[i + 1];
          Inc(i);
        end;
    else
      if IsFlag(AArgs[i]) then
      begin
        ErrLn(Format(T('superterm: unknown option ''%s''. Try ''superterm capture --help''.',
          'superterm: opcion desconocida ''%s''. Prueba ''superterm capturar --ayuda''.'),
          [AArgs[i]]));
        Exit(2);
      end;
      if TargetSpec = '' then
        TargetSpec := AArgs[i];
    end;
    Inc(i);
  end;
  SplitTargetSpec(TargetSpec, Ses, PaneSpec);
  rc := ResolveSession(Ses, True, Info);
  if rc <> 0 then
    Exit(rc);
  rc := ResolvePane(Info.SocketPath, Info.Name, PaneSpec, Pane);
  if rc <> 0 then
    Exit(rc);
  Payload := nil;
  SetLength(Payload, 2 * SizeOf(Longint));
  Move(Mode, Payload[0], SizeOf(Longint));
  Move(NLines, Payload[SizeOf(Longint)], SizeOf(Longint));
  G := TTextGrab.Create;
  FS := nil;
  try
    if OutFile <> '' then
    begin
      FS := TFileStream.Create(OutFile, fmCreate);
      G.Sink := FS;
    end
    else
      G.Sink := THandleStream.Create(StdOutputHandle);
    rc := 0;
    if not CtlStream(Info.SocketPath, FRAME_CTL_CAPTURE, Pane, Payload,
      @G.OnData) then
    begin
      ErrLn(Format(T('superterm: cannot capture from session ''%s''',
        'superterm: no se puede capturar de la sesion ''%s'''), [Info.Name]));
      rc := 3;
    end;
  finally
    if G.Sink <> nil then
      G.Sink.Free;
    G.Free;
  end;
  Exit(rc);
end;

function CmdKill(const AArgs: array of string): integer;
var
  i, rc: integer;
  Ses: string;
  Info: TSessionInfo;
begin
  Ses := '';
  for i := 0 to High(AArgs) do
    if not IsFlag(AArgs[i]) then
    begin
      Ses := AArgs[i];
      Break;
    end;
  if (Ses = '') or (Ses = '.') then
  begin
    ErrLn(T('superterm: ''kill'' always needs the session name',
      'superterm: ''matar'' necesita siempre el nombre de la sesion'));
    Exit(2);
  end;
  rc := ResolveSession(Ses, False, Info);
  if rc <> 0 then
    Exit(rc);
  if CloseSessionAt(Info.SocketPath) then
  begin
    WriteLn(Format(T('superterm: session ''%s'' terminated',
      'superterm: sesion ''%s'' terminada'), [Info.Name]));
    Exit(0);
  end;
  ErrLn(Format(T('superterm: could not terminate session ''%s''',
    'superterm: no se pudo terminar la sesion ''%s'''), [Info.Name]));
  Exit(3);
end;

// ---------------------------------------------------------------- despacho

function IsHelpToken(const S: string): boolean;
var
  N: string;
begin
  N := NormToken(S);
  Result := (N = 'help') or (N = 'ayuda') or (S = '-?') or (S = '-h');
end;

procedure RunCli;
var
  i, rc, CmdIdx: integer;
  Cmd, N: string;
  Rest: array of string;
  WantHelp: boolean;
  AttInfo: TSessionInfo;
begin
  SetLength(CliArgs, ParamCount);
  for i := 1 to ParamCount do
    CliArgs[i - 1] := ParamStr(i);
  if Length(CliArgs) = 0 then
    Exit;   // arranque normal de la TUI

  Cmd := CliArgs[0];
  N := NormToken(Cmd);

  // legado: --attach y --list-sessions siguen su camino de siempre
  if Cmd = '--attach' then
    Exit;   // lo procesa superterm.lpr como hasta ahora
  if Cmd = '--list-sessions' then
    N := 'list';

  if (N = 'version') or (Cmd = '-V') then
  begin
    WriteLn('superterm ', SUPERTERM_VERSION);
    Halt(0);
  end;

  WantHelp := False;
  CmdIdx := -1;
  case N of
    'list', 'listar', 'ls': CmdIdx := 1;
    'send', 'enviar': CmdIdx := 2;
    'capture', 'capturar': CmdIdx := 3;
    'kill', 'matar': CmdIdx := 4;
    'attach', 'conectar':
      begin
        // resuelve el nombre aqui (mejor matching) y delega el enganche
        // interactivo en el arranque normal de la TUI
        AttachRequested := True;
        if (Length(CliArgs) > 1) and (not IsFlag(CliArgs[1])) then
        begin
          rc := ResolveSession(CliArgs[1], True, AttInfo);
          if rc <> 0 then
            Halt(rc);
          AttachSocket := AttInfo.SocketPath;
        end;
        Exit;
      end;
    'help', 'ayuda':
      begin
        if Length(CliArgs) > 1 then
        begin
          case NormToken(CliArgs[1]) of
            'list', 'listar', 'ls': begin HelpList; Halt(0); end;
            'send', 'enviar': begin HelpSend; Halt(0); end;
            'capture', 'capturar': begin HelpCapture; Halt(0); end;
            'kill', 'matar': begin HelpKill; Halt(0); end;
          end;
        end;
        HelpGlobal;
        Halt(0);
      end;
  else
    if IsHelpToken(Cmd) or (Cmd = '--help') or (Cmd = '--ayuda') then
    begin
      HelpGlobal;
      Halt(0);
    end;
    // no es un comando de CLI: arranque normal (sin argumentos extra)
    if IsFlag(Cmd) then
      Exit;   // flags desconocidos: que los vea el arranque clasico
    ErrLn(Format(T('superterm: unknown command ''%s''. Try ''superterm --help''.',
      'superterm: orden desconocida ''%s''. Prueba ''superterm --ayuda''.'),
      [Cmd]));
    Halt(2);
  end;

  // ayuda por comando: superterm send --help
  for i := 1 to High(CliArgs) do
    if IsHelpToken(CliArgs[i]) or (CliArgs[i] = '--help') or
       (CliArgs[i] = '--ayuda') then
      WantHelp := True;
  if WantHelp then
  begin
    case CmdIdx of
      1: HelpList;
      2: HelpSend;
      3: HelpCapture;
      4: HelpKill;
    end;
    Halt(0);
  end;

  Rest := nil;
  SetLength(Rest, Length(CliArgs) - 1);
  for i := 1 to High(CliArgs) do
    Rest[i - 1] := CliArgs[i];

  rc := 2;
  case CmdIdx of
    1: rc := CmdList(Rest);
    2: rc := CmdSend(Rest);
    3: rc := CmdCapture(Rest);
    4: rc := CmdKill(Rest);
  end;
  Halt(rc);
end;

end.
