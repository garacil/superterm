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
    DefaultProfile: string;  // perfil por defecto (nuevo modelo)
    DefaultTemplate: string; // legado: para derivar DefaultProfile
    DefaultSession: string;  // legado
    DefaultWindow: string;
    Language: TUiLanguage;
  end;

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

function ShellQuote(const S: string): string;

procedure LoadConfig(out Cfg: TConfig);
procedure SaveConfig(const Cfg: TConfig);

var
  // idioma efectivo de la interfaz, compartido por todas las unidades de UI
  CurrentLanguage: TUiLanguage = ulEnglish;

// devuelve el texto del idioma activo (todas las cadenas de UI van en pares)
function UiText(const EnglishText, SpanishText: string): string;

// marca uniforme de elemento activo en listas tipo radio: '(*) ' / '( ) '
function ActiveMark(AActive: boolean): string;

implementation

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

function UiText(const EnglishText, SpanishText: string): string;
begin
  if CurrentLanguage = ulSpanish then
    Result := SpanishText
  else
    Result := EnglishText;
end;

function ActiveMark(AActive: boolean): string;
begin
  if AActive then
    Result := '(*) '
  else
    Result := '( ) ';
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
  Cfg.DefaultProfile := '';
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
    Cfg.DefaultProfile := Ini.ReadString('session', 'default_profile',
      Cfg.DefaultProfile);
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
    Ini.WriteString('session', 'default_profile', Cfg.DefaultProfile);
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

end.
