(*
  Autor: Germán Luis Aracil Boned
  Proyecto: superterm - terminal con autologin, splits y sesiones
  Unidad: st_config - configuración y rutas
*)

unit st_config;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, BaseUnix;

type
  TUiLanguage = (ulEnglish, ulSpanish);

  TConfig = record
    Shell: string;         // shell para autologin
    LoginShell: boolean;   // argv0 = -bash (lee .profile)
    User: string;          // usuario del autologin (informativo, ya logueado)
    PrefixKey: integer;    // tecla prefijo (2 = Ctrl-B)
    AutoSave: boolean;     // guardar sesion al salir
    AutoRestore: boolean;  // restaurar sesion al arrancar
    DefaultTemplate: string;
    DefaultSession: string;
    DefaultWindow: string;
    Language: TUiLanguage;
  end;

  TTermKind = (tkLocal, tkSSH);

  TTerminalDef = record
    Name: string;          // etiqueta descriptiva
    Enabled: boolean;
    Kind: TTermKind;       // local = terminal del sistema; ssh = remoto
    Shell: string;         // local: shell a lanzar ('' = shell de la config)
    Cmd: string;           // comando a ejecutar ('' = shell interactivo)
    Cwd: string;           // local: directorio de trabajo
    Host: string;          // ssh: servidor
    User: string;          // ssh: usuario
    Port: integer;         // ssh: puerto
    KeyFile: string;       // ssh: clave privada (-i), '' = agente/default
    Password: string;      // ssh: contrasena (sshpass -e), '' = no usar
    ScrollBack: integer;   // lineas de historial (default 10000)
  end;

  TTerminalArray = array of TTerminalDef;

function ConfigDir: string;
function ConfigFile: string;
function SessionFile: string;
function SystemConfigFile: string;   // /etc/superterm/superterm.ini (o $SUPERTERM_INI)
function ExpandUserPath(const S: string): string;
function ParseUiLanguage(const S: string): TUiLanguage;
function UiLanguageCode(ALanguage: TUiLanguage): string;

const
  DEFAULT_SCROLLBACK = 10000;
  MAX_SCROLLBACK = 100000;

procedure ClearTerminal(var T: TTerminalDef);
function DefaultTerminal: TTerminalDef;  // terminal local con shell de login
procedure LoadSystemTerminals(const FileName: string; out Terms: TTerminalArray);
function TerminalCommand(const T: TTerminalDef): string;    // cmd para Spawn
function ShellQuote(const S: string): string;
procedure BuildTerminalExec(const T: TTerminalDef; out ProgramName: string;
  Args: TStringList; out Secret: string;
  const CommandOverride: string = '');
function TerminalEnvPass(const T: TTerminalDef): string;    // compatibilidad: siempre ''

procedure LoadConfig(out Cfg: TConfig);
procedure SaveConfig(const Cfg: TConfig);

implementation

uses
  base64, StrUtils;

function ConfigDir: string;
begin
  Result := GetEnvironmentVariable('HOME') + '/.superterm';
  if not DirectoryExists(Result) then
    ForceDirectories(Result);
  if DirectoryExists(Result) then
    FpChmod(PAnsiChar(Result), &700);
end;

function ExpandUserPath(const S: string): string;
var
  Home: string;
begin
  Result := S;
  if (Length(S) >= 2) and (S[1] = '~') and (S[2] = '/') then
  begin
    Home := GetEnvironmentVariable('HOME');
    if Home <> '' then
      Result := IncludeTrailingPathDelimiter(Home) + Copy(S, 3, MaxInt);
  end;
end;

function ParseUiLanguage(const S: string): TUiLanguage;
var
  Value: string;
begin
  Value := LowerCase(Trim(S));
  if (Value = 'es') or (Value = 'spanish') or (Value = 'espanol') then
    Result := ulSpanish
  else
    Result := ulEnglish;
end;

function UiLanguageCode(ALanguage: TUiLanguage): string;
begin
  if ALanguage = ulSpanish then
    Result := 'es'
  else
    Result := 'en';
end;

function ConfigFile: string;
begin
  Result := ConfigDir + '/superterm.ini';
end;

function SessionFile: string;
begin
  Result := ConfigDir + '/session.ini';
end;

procedure SetDefaults(out Cfg: TConfig);
var
  Sh: string;
begin
  Sh := GetEnvironmentVariable('SHELL');
  if Sh = '' then Sh := '/bin/bash';
  Cfg.Shell := Sh;
  Cfg.LoginShell := True;
  Cfg.User := GetEnvironmentVariable('USER');
  Cfg.PrefixKey := 2; // Ctrl-B
  Cfg.AutoSave := True;
  Cfg.AutoRestore := True;
  Cfg.DefaultTemplate := '';
  Cfg.DefaultSession := '';
  Cfg.DefaultWindow := '';
  Cfg.Language := ulEnglish;
end;

procedure LoadConfig(out Cfg: TConfig);
var
  Ini: TIniFile;
begin
  SetDefaults(Cfg);
  if not FileExists(ConfigFile) then
    Exit;
  Ini := TIniFile.Create(ConfigFile);
  try
    Cfg.Shell := Ini.ReadString('autologin', 'shell', Cfg.Shell);
    Cfg.LoginShell := Ini.ReadBool('autologin', 'login', Cfg.LoginShell);
    Cfg.User := Ini.ReadString('autologin', 'user', Cfg.User);
    Cfg.PrefixKey := Ini.ReadInteger('keymap', 'prefix', Cfg.PrefixKey);
    Cfg.AutoSave := Ini.ReadBool('session', 'autosave', Cfg.AutoSave);
    Cfg.AutoRestore := Ini.ReadBool('session', 'autorestore', Cfg.AutoRestore);
    Cfg.DefaultTemplate := Ini.ReadString('session', 'default_template',
      Cfg.DefaultTemplate);
    Cfg.DefaultSession := Ini.ReadString('session', 'default_session',
      Cfg.DefaultSession);
    Cfg.DefaultWindow := Ini.ReadString('session', 'default_window',
      Cfg.DefaultWindow);
    Cfg.Language := ParseUiLanguage(Ini.ReadString('ui', 'language',
      UiLanguageCode(Cfg.Language)));
  finally
    Ini.Free;
  end;
end;

procedure SaveConfig(const Cfg: TConfig);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(ConfigFile);
  try
    Ini.WriteString('autologin', 'shell', Cfg.Shell);
    Ini.WriteBool('autologin', 'login', Cfg.LoginShell);
    Ini.WriteString('autologin', 'user', Cfg.User);
    Ini.WriteInteger('keymap', 'prefix', Cfg.PrefixKey);
    Ini.WriteBool('session', 'autosave', Cfg.AutoSave);
    Ini.WriteBool('session', 'autorestore', Cfg.AutoRestore);
    Ini.WriteString('session', 'default_template', Cfg.DefaultTemplate);
    Ini.WriteString('session', 'default_session', Cfg.DefaultSession);
    Ini.WriteString('session', 'default_window', Cfg.DefaultWindow);
    Ini.WriteString('ui', 'language', UiLanguageCode(Cfg.Language));
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

function SystemConfigFile: string;
begin
  Result := GetEnvironmentVariable('SUPERTERM_INI');
  if Result = '' then
    Result := '/etc/superterm/superterm.ini';
end;

procedure ClearTerminal(var T: TTerminalDef);
begin
  T.Name := '';
  T.Enabled := False;
  T.Kind := tkLocal;
  T.Shell := '';
  T.Cmd := '';
  T.Cwd := '';
  T.Host := '';
  T.User := '';
  T.Port := 0;
  T.KeyFile := '';
  T.Password := '';
  T.ScrollBack := 0;
end;

function DefaultTerminal: TTerminalDef;
begin
  Result.Name := '';
  Result.Enabled := False;
  Result.Kind := tkLocal;
  Result.Shell := '';
  Result.Cmd := '';
  Result.Cwd := '';
  Result.Host := '';
  Result.User := '';
  Result.Port := 0;
  Result.KeyFile := '';
  Result.Password := '';
  Result.ScrollBack := 0;
  Result.Name := 'terminal';
  Result.Enabled := True;
  Result.Kind := tkLocal;
  Result.Shell := '';
  Result.Cmd := '';
  Result.Cwd := '';
  Result.ScrollBack := DEFAULT_SCROLLBACK;
end;

function ShellQuote(const S: string): string;
var
  I: integer;
begin
  // Single-quote every shell argument. Embedded quotes are represented by
  // closing the quote, emitting an escaped quote, and reopening it.
  Result := '''';
  for I := 1 to Length(S) do
    if S[I] = '''' then
      Result := Result + '''\'''''
    else
      Result := Result + S[I];
  Result := Result + '''';
end;

function TerminalCommand(const T: TTerminalDef): string;
var
  S: string;
begin
  Result := '';
  if not T.Enabled then
    Exit;
  if T.Kind = tkLocal then
  begin
    if T.Cmd <> '' then
      Result := T.Cmd
    else
      Result := '';   // '': Spawn lanza la shell de login por defecto
    Exit;
  end;
  // ssh
  S := 'ssh -tt';
  if T.Port > 0 then
    S := S + ' -p ' + ShellQuote(IntToStr(T.Port));
  if T.KeyFile <> '' then
    S := S + ' -i ' + ShellQuote(ExpandUserPath(T.KeyFile));
  S := S + ' -o StrictHostKeyChecking=accept-new';
  if T.User <> '' then
    S := S + ' ' + ShellQuote(T.User + '@' + T.Host)
  else
    S := S + ' ' + ShellQuote(T.Host);
  if T.Password <> '' then
    S := 'sshpass -d 3 ' + S;
  if T.Cmd <> '' then
    S := S + ' ' + ShellQuote(T.Cmd);
  Result := S;
end;

procedure BuildTerminalExec(const T: TTerminalDef; out ProgramName: string;
  Args: TStringList; out Secret: string;
  const CommandOverride: string);
var
  Target: string;
  Path, Item: string;
  Start, Sep: integer;
  HaveSshPass: boolean;
begin
  ProgramName := '';
  Secret := '';
  Args.Clear;
  if not T.Enabled then
    Exit;
  if T.Kind = tkLocal then
    Exit;

  // Keep SSH arguments structured. The remote command is intentionally one
  // argument because the SSH server may pass it to its login shell.
  HaveSshPass := False;
  if T.Password <> '' then
  begin
    Secret := T.Password;
    Path := GetEnvironmentVariable('PATH');
    Start := 1;
    while Start <= Length(Path) + 1 do
    begin
      Sep := PosEx(':', Path, Start);
      if Sep = 0 then
        Sep := Length(Path) + 1;
      Item := Copy(Path, Start, Sep - Start);
      if Item = '' then
        Item := '.';
      if FileExists(IncludeTrailingPathDelimiter(Item) + 'sshpass') then
      begin
        HaveSshPass := True;
        Break;
      end;
      Start := Sep + 1;
    end;
  end;
  if HaveSshPass then
  begin
    ProgramName := 'sshpass';
    Args.Add('sshpass');
    Args.Add('-d');
    Args.Add('3');
  end
  else
  begin
    ProgramName := 'ssh';
    Args.Add('ssh');
  end;
  Args.Add('-tt');
  if T.Port > 0 then
  begin
    Args.Add('-p');
    Args.Add(IntToStr(T.Port));
  end;
  if T.KeyFile <> '' then
  begin
    Args.Add('-i');
    Args.Add(ExpandUserPath(T.KeyFile));
  end;
  Args.Add('-o');
  Args.Add('StrictHostKeyChecking=accept-new');
  if T.User <> '' then
    Target := T.User + '@' + T.Host
  else
    Target := T.Host;
  Args.Add(Target);
  if CommandOverride <> '' then
    Args.Add(CommandOverride)
  else if T.Cmd <> '' then
    Args.Add(T.Cmd);
end;

function TerminalEnvPass(const T: TTerminalDef): string;
begin
  // Passwords are now sent through a private pipe to sshpass -d 3.
  Result := '';
end;

procedure LoadSystemTerminals(const FileName: string; out Terms: TTerminalArray);
var
  Ini: TIniFile;
  SL: TStringList;
  i: integer;
  Sec, S: string;

  function ToStr(const V: string): string;
  begin
    if V = '' then Result := '' else Result := V;
  end;

  function ToBool(const V: string; Def: boolean): boolean;
  begin
    if V = '' then
      Result := Def
    else
      Result := SameText(V, '1') or SameText(V, 'true') or SameText(V, 'yes') or SameText(V, 'on');
  end;

var
  T: TTerminalDef;
  KindS: string;
begin
  Terms := nil;
  if not FileExists(FileName) then
    Exit;
  Ini := TIniFile.Create(FileName);
  SL := TStringList.Create;
  try
    Ini.ReadSections(SL);
    for i := 0 to SL.Count - 1 do
    begin
      Sec := SL[i];
      if (Sec = '') or (Sec[1] <> 't') or
         (LowerCase(Copy(Sec, 1, Length('template.'))) = 'template.') or
         (Sec = 'autologin') or (Sec = 'keymap') or (Sec = 'session') then
        continue;
      T := DefaultTerminal;
      T.Name := Ini.ReadString(Sec, 'name', Copy(Sec, 2, MaxInt));
      T.Enabled := ToBool(Ini.ReadString(Sec, 'enabled', '1'), True);
      KindS := LowerCase(Ini.ReadString(Sec, 'type', 'local'));
      if (KindS = 'ssh') or (KindS = 'remote') then
        T.Kind := tkSSH
      else
        T.Kind := tkLocal;
      T.Shell := ToStr(Ini.ReadString(Sec, 'shell', ''));
      T.Cmd := ToStr(Ini.ReadString(Sec, 'cmd', ''));
      T.Cwd := ToStr(Ini.ReadString(Sec, 'cwd', ''));
      T.Host := ToStr(Ini.ReadString(Sec, 'host', ''));
      T.User := ToStr(Ini.ReadString(Sec, 'user', ''));
      T.Port := Ini.ReadInteger(Sec, 'port', 0);
      T.KeyFile := ToStr(Ini.ReadString(Sec, 'key', ''));
      T.ScrollBack := Ini.ReadInteger(Sec, 'scrollback', DEFAULT_SCROLLBACK);
      if T.ScrollBack < 0 then
        T.ScrollBack := 0;
      if T.ScrollBack > MAX_SCROLLBACK then
        T.ScrollBack := MAX_SCROLLBACK;
      S := Ini.ReadString(Sec, 'password', '');
      if S <> '' then
      begin
        try
          T.Password := DecodeStringBase64(S);
        except
          T.Password := S;   // sin codificar
        end;
      end;
      SetLength(Terms, Length(Terms) + 1);
      Terms[High(Terms)] := T;
    end;
  finally
    SL.Free;
    Ini.Free;
  end;
end;

end.
