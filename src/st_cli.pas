(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_cli - session control command line

  Friendly subcommands inspired by tmux: list sessions and panes with
  details, send text to any pane, capture the screen or the history,
  and manage the session. All commands and options are accepted in
  English AND in Spanish (case- and accent-insensitive); messages and
  help come out in the language configured in [ui] language.

  Exit codes: 0 ok, 1 not found/ambiguous, 2 usage error,
  3 connection failure or old daemon without control support.
*)

unit st_cli;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, st_config, st_server, st_cli_help;

type
  // pane row of the control LIST (live data only the daemon has)
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

// Processes the command line. True means a CLI command was handled and
// AExitCode contains its status. False delegates normal TUI/attach startup to
// the caller. Returning normally is intentional: Halt skips finalization of
// this routine's managed strings and dynamic arrays in FPC 3.2.x.
function RunCli(out AExitCode: integer): boolean;

// queries LIST/INFO of a session through its socket (also used by the
// attached UI to capture live cmd/cwd when saving a profile)
function FetchList(const ASocket: string; WithPanes: boolean;
  out L: TListInfo): boolean;

implementation

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

// normalizes a token for comparison: lowercase, no leading dashes and
// no accents (two-byte UTF-8 sequences -> ascii)
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
        $A1, $81: R := R + 'a';   // a-acute
        $A9, $89: R := R + 'e';   // e-acute
        $AD, $8D: R := R + 'i';   // i-acute
        $B3, $93: R := R + 'o';   // o-acute
        $BA, $9A: R := R + 'u';   // u-acute
        $BC, $9C: R := R + 'u';   // u-diaeresis
        $B1, $91: R := R + 'n';   // n-tilde
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
  // no leading dashes: '--lineas' and 'lineas' compare as equal
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

// ---------------------------------------------------------------- targets

function ListLive(out Infos: TSessionInfoArray): boolean;
begin
  Result := EnumerateSessions(Infos);
end;

// True when the whole token resolves as a live session.  This disambiguates
// legacy SESSION.PANE from a real dotted session name without changing the
// canonical and unambiguous SESSION:PANE grammar.
function WholeSessionSpecExists(const Spec: string): boolean;
var
  Infos: TSessionInfoArray;
  I, Matches: integer;
begin
  Result := False;
  if (Spec = '') or (not ListLive(Infos)) then
    Exit;
  for I := 0 to High(Infos) do
    if (Infos[I].Name = Spec) or
       (Infos[I].Name = SanitizeSessionName(Spec)) then
      Exit(True);
  Matches := 0;
  for I := 0 to High(Infos) do
    if SameText(Infos[I].Name, Spec) then
      Inc(Matches);
  if Matches = 1 then
    Exit(True);
  Matches := 0;
  for I := 0 to High(Infos) do
    if (Length(Spec) <= Length(Infos[I].Name)) and
       SameText(Copy(Infos[I].Name, 1, Length(Spec)), Spec) then
      Inc(Matches);
  Result := Matches = 1;
end;

// Splits canonical SESSION:PANE first.  The old SESSION.PANE, .PANE and
// :PANE spellings remain compatible, but an existing whole dotted session
// wins the only ambiguous case.  In particular, '.:PANE' must split on ':'.
procedure SplitTargetSpec(const Spec: string; out Ses, Pane: string);
var
  I: integer;
begin
  Ses := Spec;
  Pane := '';
  I := Pos(':', Spec);
  if I > 0 then
  begin
    Ses := Copy(Spec, 1, I - 1);
    Pane := Copy(Spec, I + 1, MaxInt);
    Exit;
  end;
  if (Length(Spec) > 1) and (Spec[1] = '.') then
  begin
    Ses := '';
    Pane := Copy(Spec, 2, MaxInt);
    Exit;
  end;
  if WholeSessionSpecExists(Spec) then
    Exit;
  for I := Length(Spec) downto 1 do
    if Spec[I] = '.' then
    begin
      Ses := Copy(Spec, 1, I - 1);
      Pane := Copy(Spec, I + 1, MaxInt);
      Exit;
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

// resolves the session name: exact -> sanitized -> case-insensitive ->
// unique prefix; '' or '.' = the only live one
function ResolveSession(const AName: string; ADefaultOk: boolean;
  out AInfo: TSessionInfo): integer;   // 0 ok, 1 error (already printed)
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
  // exact
  for i := 0 to High(Infos) do
    if Infos[i].Name = AName then
    begin
      AInfo := Infos[i];
      Exit(0);
    end;
  // sanitized
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
  // unique prefix
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

// ------------------------------------------------- LIST/INFO reads

type
  TBlobGrab = class
    Blob: TByteArray;
    procedure OnData(const AChunk: TByteArray);
  end;

  TTextGrab = class
    Text: RawByteString;
    Sink: TStream;   // if not nil, goes straight through (file/stdout)
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

// resolves the pane inside a session: 1-based index or unique title
// substring; '' = focused pane
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

// ---------------------------------------------------------------- keys

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

// ---------------------------------------------------------------- commands

function CmdList(const AArgs: array of string;
  ALegacy: boolean = False): integer;
var
  Infos: TSessionInfoArray;
  Info: TSessionInfo;
  L: TListInfo;
  i, rc: integer;
  Ses, TypeS, Target, Flags, Att: string;
begin
  L := Default(TListInfo);
  Ses := '';
  if (Length(AArgs) > 1) or
     ((Length(AArgs) = 1) and IsFlag(AArgs[0])) then
  begin
    ErrLn(T('superterm: usage: list [SESSION]',
      'superterm: uso: listar [SESION]'));
    Exit(2);
  end;
  if Length(AArgs) = 1 then
    Ses := AArgs[0];
  // no argument: sessions table
  if Ses = '' then
  begin
    if not ListLive(Infos) then
    begin
      WriteLn(T('superterm: no sessions are running',
        'superterm: no hay sesiones activas'));
      // the legacy --list-sessions alias always exited with 0
      if ALegacy then
        Exit(0);
      Exit(1);
    end;
    WriteLn(Format('%-24s %-16s %5s %8s  %s',
      [T('NAME', 'NOMBRE'), T('PROFILE', 'PERFIL'),
       T('PANES', 'PANELES'), T('CLIENTS', 'CLIENTES'),
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
  // with a session: pane details
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
    // the -n/-k flags are accepted before the target AND after (until
    // the text begins); '--' forces the rest to be literal text
    if not TextStarted then
    begin
      if AArgs[i] = '--' then
      begin
        TextStarted := True;
        Inc(i);
        continue;
      end;
      case NormToken(AArgs[i]) of
        'n', 'noenter', 'no-enter', 'sinintro', 'sin-intro':
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
          // unknown option after the target: the literal text begins
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
    // raw stdin, no Enter
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
        TargetSpec := AArgs[i]
      else
      begin
        ErrLn(T('superterm: usage: capture TARGET [OPTIONS]',
          'superterm: uso: capturar DESTINO [OPCIONES]'));
        Exit(2);
      end;
    end;
    Inc(i);
  end;
  if TargetSpec = '' then
  begin
    ErrLn(T('superterm: a target is required (SESSION[:PANE], or ''.'' for the only session).',
      'superterm: falta el destino (SESION[:PANEL], o ''.'' para la unica sesion).'));
    Exit(2);
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
  rc: integer;
  Ses: string;
  Info: TSessionInfo;
begin
  if (Length(AArgs) <> 1) or IsFlag(AArgs[0]) then
  begin
    ErrLn(T('superterm: usage: kill SESSION',
      'superterm: uso: matar SESION'));
    Exit(2);
  end;
  Ses := AArgs[0];
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

// ------------------------------------------------- window management

function PasStr(const S: string): TByteArray;
var
  L: Longint;
begin
  Result := nil;
  L := Length(S);
  SetLength(Result, SizeOf(Longint) + L);
  Move(L, Result[0], SizeOf(Longint));
  if L > 0 then
    Move(S[1], Result[SizeOf(Longint)], L);
end;

procedure AppendBytes(var Dst: TByteArray; const Src: TByteArray);
var
  Ofs: integer;
begin
  Ofs := Length(Dst);
  SetLength(Dst, Ofs + Length(Src));
  if Length(Src) > 0 then
    Move(Src[0], Dst[Ofs], Length(Src));
end;

// runs a WINOP on an already resolved target; prints errors
function DoWinOp(const AInfo: TSessionInfo; APane: integer; AOp: byte;
  const AExtra: TByteArray; out AReply: string): integer;
var
  Payload: TByteArray;
begin
  Payload := nil;
  SetLength(Payload, 1);
  Payload[0] := AOp;
  AppendBytes(Payload, AExtra);
  if CtlSimple(AInfo.SocketPath, FRAME_CTL_WINOP, APane, Payload,
    AReply) then
    Exit(0);
  if AReply = 'session is attached' then
  begin
    ErrLn(T('superterm: the session is attached; detach it first',
      'superterm: la sesion esta conectada; separala primero'));
    Exit(1);
  end;
  if AReply <> '' then
  begin
    ErrLn('superterm: ' + AReply);
    Exit(1);
  end;
  ErrLn(Format(T('superterm: cannot connect to session ''%s''',
    'superterm: no se puede conectar con la sesion ''%s'''), [AInfo.Name]));
  Exit(3);
end;

// Resolves the one exact TARGET accepted by simple window operations.
function GrabTarget(const AArgs: array of string; ARequired: boolean;
  out AInfo: TSessionInfo; out APane: integer): integer;
var
  rc: integer;
  Spec, Ses, PaneSpec: string;
begin
  Spec := '';
  if Length(AArgs) = 0 then
  begin
    if ARequired then
    begin
      ErrLn(T('superterm: a target is required. Try ''--help''.',
        'superterm: falta el destino. Prueba ''--ayuda''.'));
      Exit(2);
    end;
  end;
  if Length(AArgs) <> 1 then
  begin
    ErrLn(T('superterm: this window command accepts exactly one TARGET',
      'superterm: esta orden de ventana acepta exactamente un DESTINO'));
    Exit(2);
  end;
  Spec := AArgs[0];
  if (Spec = '') and ARequired then
  begin
    ErrLn(T('superterm: a target is required. Try ''--help''.',
      'superterm: falta el destino. Prueba ''--ayuda''.'));
    Exit(2);
  end;
  if IsFlag(Spec) then
  begin
    ErrLn(T('superterm: this window command accepts exactly one TARGET',
      'superterm: esta orden de ventana acepta exactamente un DESTINO'));
    Exit(2);
  end;
  SplitTargetSpec(Spec, Ses, PaneSpec);
  rc := ResolveSession(Ses, True, AInfo);
  if rc <> 0 then
    Exit(rc);
  Result := ResolvePane(AInfo.SocketPath, AInfo.Name, PaneSpec, APane);
end;

function CmdSimpleOp(const AArgs: array of string; AOp: byte;
  ANeedTarget: boolean): integer;
var
  Info: TSessionInfo;
  Pane, rc: integer;
  Reply: string;
begin
  rc := GrabTarget(AArgs, ANeedTarget, Info, Pane);
  if rc <> 0 then
    Exit(rc);
  Result := DoWinOp(Info, Pane, AOp, nil, Reply);
end;

function CmdNew(const AArgs: array of string): integer;
var
  Info: TSessionInfo;
  Pane, rc, i: integer;
  Reply, ClassS, CmdS, CwdS, TitleS, Spec, Ses, PaneSpec: string;
  DirB: byte;
  Extra: TByteArray;
begin
  ClassS := '';
  CmdS := '';
  CwdS := '';
  TitleS := '';
  DirB := 0;   // down by default
  Spec := '';
  i := 0;
  while i <= High(AArgs) do
  begin
    case NormToken(AArgs[i]) of
      'c', 'class', 'clase':
        begin
          if i = High(AArgs) then Exit(2);
          ClassS := AArgs[i + 1];
          Inc(i);
        end;
      'cmd', 'comando':
        begin
          if i = High(AArgs) then Exit(2);
          CmdS := AArgs[i + 1];
          Inc(i);
        end;
      'cwd', 'dir', 'directorio':
        begin
          if i = High(AArgs) then Exit(2);
          CwdS := AArgs[i + 1];
          Inc(i);
        end;
      't', 'title', 'titulo':
        begin
          if i = High(AArgs) then Exit(2);
          TitleS := AArgs[i + 1];
          Inc(i);
        end;
      'd', 'down', 'abajo': DirB := 0;
      'r', 'right', 'derecha': DirB := 1;
    else
      if IsFlag(AArgs[i]) then
      begin
        ErrLn(Format(T('superterm: unknown option ''%s''',
          'superterm: opcion desconocida ''%s'''), [AArgs[i]]));
        Exit(2);
      end;
      if Spec = '' then
        Spec := AArgs[i]
      else
      begin
        ErrLn(T('superterm: new accepts exactly one SESSION[:PANE] target',
          'superterm: nueva acepta un solo destino SESION[:PANEL]'));
        Exit(2);
      end;
    end;
    Inc(i);
  end;
  if Spec = '' then
  begin
    ErrLn(T('superterm: a session is required (or ''.'' for the only one). Try ''superterm new --help''.',
      'superterm: falta la sesion (o ''.'' para la unica). Prueba ''superterm nueva --ayuda''.'));
    Exit(2);
  end;
  SplitTargetSpec(Spec, Ses, PaneSpec);
  rc := ResolveSession(Ses, True, Info);
  if rc <> 0 then
    Exit(rc);
  Pane := -1;
  if PaneSpec <> '' then
  begin
    rc := ResolvePane(Info.SocketPath, Info.Name, PaneSpec, Pane);
    if rc <> 0 then
      Exit(rc);
  end;
  Extra := nil;
  SetLength(Extra, 1);
  Extra[0] := DirB;
  AppendBytes(Extra, PasStr(ClassS));
  AppendBytes(Extra, PasStr(CmdS));
  AppendBytes(Extra, PasStr(CwdS));
  AppendBytes(Extra, PasStr(TitleS));
  Result := DoWinOp(Info, Pane, WINOP_NEWPANE, Extra, Reply);
  if Result = 0 then
    WriteLn(Format(T('superterm: pane %s created in ''%s''',
      'superterm: panel %s creado en ''%s'''), [Reply, Info.Name]));
end;

function CmdRename(const AArgs: array of string): integer;
var
  Info: TSessionInfo;
  Pane, rc, i: integer;
  Reply, Spec, Ses, PaneSpec, NewName: string;
begin
  if (Length(AArgs) < 2) or IsFlag(AArgs[0]) then
  begin
    ErrLn(T('superterm: usage: rename TARGET NEW_NAME',
      'superterm: uso: renombrar DESTINO NUEVO_NOMBRE'));
    Exit(2);
  end;
  Spec := AArgs[0];
  NewName := '';
  for i := 1 to High(AArgs) do
  begin
    if NewName <> '' then
      NewName := NewName + ' ';
    NewName := NewName + AArgs[i];
  end;
  NewName := Trim(NewName);
  if NewName = '' then
  begin
    ErrLn(T('superterm: usage: rename TARGET NEW_NAME',
      'superterm: uso: renombrar DESTINO NUEVO_NOMBRE'));
    Exit(2);
  end;
  SplitTargetSpec(Spec, Ses, PaneSpec);
  rc := ResolveSession(Ses, True, Info);
  if rc <> 0 then
    Exit(rc);
  rc := ResolvePane(Info.SocketPath, Info.Name, PaneSpec, Pane);
  if rc <> 0 then
    Exit(rc);
  Result := DoWinOp(Info, Pane, WINOP_RENAME, PasStr(NewName), Reply);
  if Result = 0 then
    WriteLn(Format(T('superterm: pane %d renamed to "%s"',
      'superterm: panel %d renombrado a "%s"'), [Pane + 1, NewName]));
end;

function CmdResize(const AArgs: array of string): integer;
var
  Info: TSessionInfo;
  Pane, rc, XPos: integer;
  Reply, Spec, Size: string;
  Ses, PaneSpec: string;
  Cols, Rows: Longint;
  Extra: TByteArray;
begin
  if (Length(AArgs) <> 2) or IsFlag(AArgs[0]) then
  begin
    ErrLn(T('superterm: usage: resize TARGET COLSxROWS  (e.g. 100x30)',
      'superterm: uso: tamano DESTINO COLSxFILAS  (ej. 100x30)'));
    Exit(2);
  end;
  Spec := AArgs[0];
  Size := AArgs[1];
  XPos := Pos('x', LowerCase(Size));
  if (Spec = '') or (XPos = 0) then
  begin
    ErrLn(T('superterm: usage: resize TARGET COLSxROWS  (e.g. 100x30)',
      'superterm: uso: tamano DESTINO COLSxFILAS  (ej. 100x30)'));
    Exit(2);
  end;
  Cols := StrToIntDef(Copy(Size, 1, XPos - 1), 0);
  Rows := StrToIntDef(Copy(Size, XPos + 1, MaxInt), 0);
  SplitTargetSpec(Spec, Ses, PaneSpec);
  rc := ResolveSession(Ses, True, Info);
  if rc <> 0 then
    Exit(rc);
  rc := ResolvePane(Info.SocketPath, Info.Name, PaneSpec, Pane);
  if rc <> 0 then
    Exit(rc);
  Extra := nil;
  SetLength(Extra, 2 * SizeOf(Longint));
  Move(Cols, Extra[0], SizeOf(Longint));
  Move(Rows, Extra[SizeOf(Longint)], SizeOf(Longint));
  Result := DoWinOp(Info, Pane, WINOP_RESIZE, Extra, Reply);
end;

function CmdOrganize(const AArgs: array of string): integer;
var
  Info: TSessionInfo;
  rc: integer;
  Reply, Ses, HowS: string;
  HowB: byte;
  Extra: TByteArray;
begin
  if (Length(AArgs) < 1) or (Length(AArgs) > 2) or IsFlag(AArgs[0]) then
  begin
    ErrLn(T('superterm: usage: organize SESSION [grid|tile|cascade]',
      'superterm: uso: organizar SESION [rejilla|mosaico|cascada]'));
    Exit(2);
  end;
  Ses := AArgs[0];
  HowS := '';
  if Length(AArgs) = 2 then
  begin
    case NormToken(AArgs[1]) of
      'tile', 'mosaico': HowS := 'tile';
      'cascade', 'cascada': HowS := 'cascade';
      'grid', 'rejilla': HowS := 'grid';
    else
    begin
      ErrLn(Format(T('superterm: unknown organize mode ''%s''',
        'superterm: modo de organizacion desconocido ''%s'''), [AArgs[1]]));
      Exit(2);
    end;
    end;
  end;
  rc := ResolveSession(Ses, True, Info);
  if rc <> 0 then
    Exit(rc);
  case HowS of
    'tile': HowB := 1;
    'cascade': HowB := 2;
  else
    HowB := 0;   // grid
  end;
  Extra := nil;
  SetLength(Extra, 1);
  Extra[0] := HowB;
  Result := DoWinOp(Info, -1, WINOP_ORGANIZE, Extra, Reply);
end;

// ---------------------------------------------------------------- dispatch

const
  CLI_NONE = 0;
  CLI_LIST = 1;
  CLI_SEND = 2;
  CLI_CAPTURE = 3;
  CLI_KILL = 4;
  CLI_NEW = 5;
  CLI_CLOSE = 6;
  CLI_FOCUS = 7;
  CLI_MINIMIZE = 8;
  CLI_RESTORE = 9;
  CLI_ZOOM = 10;
  CLI_ORGANIZE = 11;
  CLI_RENAME = 12;
  CLI_RESIZE = 13;
  CLI_ATTACH = 14;
  CLI_VERSION = 15;

// One alias table drives both execution and command-specific help.  Topic
// aliases which are not executable commands remain in st_cli_help.
function CommandIdFromToken(const S: string): integer;
begin
  case NormToken(S) of
    'list', 'listar', 'ls': Result := CLI_LIST;
    'send', 'enviar': Result := CLI_SEND;
    'capture', 'capturar': Result := CLI_CAPTURE;
    'kill', 'matar': Result := CLI_KILL;
    'new', 'nueva', 'nuevo': Result := CLI_NEW;
    'close', 'cerrar': Result := CLI_CLOSE;
    'focus', 'foco', 'select', 'seleccionar': Result := CLI_FOCUS;
    'minimize', 'minimizar': Result := CLI_MINIMIZE;
    'restore', 'restaurar': Result := CLI_RESTORE;
    'zoom', 'ampliar': Result := CLI_ZOOM;
    'organize', 'organizar': Result := CLI_ORGANIZE;
    'rename', 'renombrar': Result := CLI_RENAME;
    'resize', 'tamano', 'redimensionar': Result := CLI_RESIZE;
    'attach', 'conectar': Result := CLI_ATTACH;
    'version': Result := CLI_VERSION;
  else
    Result := CLI_NONE;
  end;
end;

// Help is an option only in option position.  Never scan arbitrary payload:
// `send . help`, `send . -- --help` and `rename . help` are legitimate data.
function IsHelpOption(const S: string): boolean;
begin
  // Long control options follow the CLI's case/accent-insensitive contract.
  // Keep short -H distinct because capture uses it for history.
  Result := (S = '-h') or (S = '-?') or
    ((Copy(S, 1, 2) = '--') and
     ((NormToken(S) = 'help') or (NormToken(S) = 'ayuda')));
end;

function ShowHelpTopic(const ATopic: string; out AExitCode: integer): boolean;
var
  N: string;
begin
  N := NormToken(ATopic);
  Result := PrintCliHelpTopic(N, CurrentLanguage);
  if Result then
    AExitCode := 0
  else
  begin
    ErrLn(Format(T('superterm: unknown help topic ''%s''.',
      'superterm: tema de ayuda desconocido ''%s''.'), [ATopic]));
    ErrLn(T('Try ''superterm --help'' to list every topic.',
      'Prueba ''superterm --ayuda'' para listar todos los temas.'));
    AExitCode := 2;
  end;
end;

function RunCli(out AExitCode: integer): boolean;
var
  i, rc, CmdIdx: integer;
  Cmd, N: string;
  Rest: array of string;
  AttInfo: TSessionInfo;
begin
  Result := False;
  AExitCode := 0;
  SetLength(CliArgs, ParamCount);
  for i := 1 to ParamCount do
    CliArgs[i - 1] := ParamStr(i);
  if Length(CliArgs) = 0 then
    Exit;   // normal TUI startup

  Cmd := CliArgs[0];
  N := NormToken(Cmd);

  // Top-level help is an index or exactly one contextual topic.  A typo is a
  // usage error rather than a successful but unrelated global page.
  if (N = 'help') or (N = 'ayuda') or IsHelpOption(Cmd) then
  begin
    if Length(CliArgs) > 2 then
    begin
      ErrLn(T('superterm: help accepts at most one topic.',
        'superterm: ayuda acepta como maximo un tema.'));
      AExitCode := 2;
      Exit(True);
    end;
    if Length(CliArgs) = 1 then
      PrintCliHelpIndex(CurrentLanguage)
    else
      ShowHelpTopic(CliArgs[1], AExitCode);
    Exit(True);
  end;

  // The classic startup flags are parsed later by superterm.lpr.  Recognize
  // their option-position help here so no help request can open the TUI.
  if ((Cmd = '--attach') or (Cmd = '--session') or (Cmd = '--sesion')) and
     (Length(CliArgs) > 1) and
     (IsHelpOption(CliArgs[1]) or IsHelpOption(CliArgs[High(CliArgs)])) then
  begin
    if not (((Length(CliArgs) = 2) and IsHelpOption(CliArgs[1])) or
            ((Length(CliArgs) = 3) and (not IsFlag(CliArgs[1])) and
             IsHelpOption(CliArgs[2]))) then
    begin
      ErrLn(T('superterm: command help accepts no additional arguments.',
        'superterm: la ayuda de una orden no acepta argumentos adicionales.'));
      AExitCode := 2;
      Exit(True);
    end;
    if Cmd = '--attach' then
      PrintCliHelpTopic('attach', CurrentLanguage)
    else
      PrintCliHelpTopic('startup', CurrentLanguage);
    Exit(True);
  end;

  // --session/--sesion is the only remaining classic startup form. Validate
  // it here, then let superterm.lpr perform the actual interactive startup.
  if (Cmd = '--session') or (Cmd = '--sesion') then
  begin
    if (Length(CliArgs) <> 2) or IsFlag(CliArgs[1]) then
    begin
      ErrLn(T('superterm: usage: --session NAME',
        'superterm: uso: --sesion NOMBRE'));
      AExitCode := 2;
      Exit(True);
    end;
    Exit(False);
  end;

  // legacy --list-sessions keeps its historical exit status and table
  if Cmd = '--list-sessions' then
  begin
    if (Length(CliArgs) > 1) and
       (IsHelpOption(CliArgs[1]) or IsHelpOption(CliArgs[High(CliArgs)])) then
    begin
      if Length(CliArgs) <> 2 then
      begin
        ErrLn(T('superterm: command help accepts no additional arguments.',
          'superterm: la ayuda de una orden no acepta argumentos adicionales.'));
        AExitCode := 2;
        Exit(True);
      end;
      PrintCliHelpTopic('list', CurrentLanguage);
      Exit(True);
    end;
    if Length(CliArgs) <> 1 then
    begin
      ErrLn(T('superterm: --list-sessions accepts no arguments',
        'superterm: --list-sessions no acepta argumentos'));
      AExitCode := 2;
      Exit(True);
    end;
    AExitCode := CmdList([], True);
    Exit(True);
  end;

  CmdIdx := CommandIdFromToken(Cmd);
  if (CmdIdx = CLI_VERSION) or (Cmd = '-V') then
  begin
    if (Length(CliArgs) > 1) and
       (IsHelpOption(CliArgs[1]) or IsHelpOption(CliArgs[High(CliArgs)])) then
    begin
      if Length(CliArgs) <> 2 then
      begin
        ErrLn(T('superterm: command help accepts no additional arguments.',
          'superterm: la ayuda de una orden no acepta argumentos adicionales.'));
        AExitCode := 2;
        Exit(True);
      end;
      PrintCliHelpTopic('version', CurrentLanguage);
    end
    else if Length(CliArgs) <> 1 then
    begin
      ErrLn(T('superterm: version accepts no arguments',
        'superterm: version no acepta argumentos'));
      AExitCode := 2;
    end
    else
      WriteLn('superterm ', SUPERTERM_VERSION);
    Exit(True);
  end;

  if CmdIdx = CLI_NONE then
  begin
    if IsFlag(Cmd) then
      ErrLn(Format(T('superterm: unknown option ''%s''. Try ''superterm --help''.',
        'superterm: opcion desconocida ''%s''. Prueba ''superterm --ayuda''.'),
        [Cmd]))
    else
      ErrLn(Format(T('superterm: unknown command ''%s''. Try ''superterm --help''.',
        'superterm: orden desconocida ''%s''. Prueba ''superterm --ayuda''.'),
        [Cmd]));
    AExitCode := 2;
    Exit(True);
  end;

  // Context help is accepted in the unambiguous option position immediately
  // after the command.  The remainder belongs to that command's grammar.
  if (Length(CliArgs) > 1) and IsHelpOption(CliArgs[1]) then
  begin
    if Length(CliArgs) > 2 then
    begin
      ErrLn(T('superterm: command help accepts no additional arguments.',
        'superterm: la ayuda de una orden no acepta argumentos adicionales.'));
      AExitCode := 2;
      Exit(True);
    end;
    ShowHelpTopic(N, AExitCode);
    Exit(True);
  end;

  if CmdIdx = CLI_ATTACH then
  begin
    if (Length(CliArgs) > 2) or
       ((Length(CliArgs) = 2) and IsFlag(CliArgs[1])) then
    begin
      ErrLn(T('superterm: usage: attach [SESSION]',
        'superterm: uso: conectar [SESION]'));
      AExitCode := 2;
      Exit(True);
    end;
    // Resolve the name here for exact/sanitized/prefix matching and delegate
    // the interactive attach to the ordinary TUI startup.
    AttachRequested := True;
    if (Length(CliArgs) > 1) and (not IsFlag(CliArgs[1])) then
    begin
      rc := ResolveSession(CliArgs[1], True, AttInfo);
      if rc <> 0 then
      begin
        AExitCode := rc;
        Exit(True);
      end;
      AttachSocket := AttInfo.SocketPath;
    end;
    Exit(False);
  end;

  Rest := nil;
  SetLength(Rest, Length(CliArgs) - 1);
  for i := 1 to High(CliArgs) do
    Rest[i - 1] := CliArgs[i];

  rc := 2;
  case CmdIdx of
    CLI_LIST: rc := CmdList(Rest);
    CLI_SEND: rc := CmdSend(Rest);
    CLI_CAPTURE: rc := CmdCapture(Rest);
    CLI_KILL: rc := CmdKill(Rest);
    CLI_NEW: rc := CmdNew(Rest);
    CLI_CLOSE: rc := CmdSimpleOp(Rest, WINOP_KILL, True);
    CLI_FOCUS: rc := CmdSimpleOp(Rest, WINOP_FOCUS, True);
    CLI_MINIMIZE: rc := CmdSimpleOp(Rest, WINOP_MINIMIZE, True);
    CLI_RESTORE: rc := CmdSimpleOp(Rest, WINOP_RESTORE, True);
    CLI_ZOOM: rc := CmdSimpleOp(Rest, WINOP_ZOOM, True);
    CLI_ORGANIZE: rc := CmdOrganize(Rest);
    CLI_RENAME: rc := CmdRename(Rest);
    CLI_RESIZE: rc := CmdResize(Rest);
  end;
  AExitCode := rc;
  Result := True;
end;

end.
