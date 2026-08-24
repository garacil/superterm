(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_config - configuration and paths
*)

unit st_config;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, BaseUnix;

type
  TUiLanguage = (ulEnglish, ulSpanish);
  // rpSession: one stable PTY geometry, independent client viewports.
  // rpSmallest: compatibility policy, common minimum of attached clients.
  TResizePolicy = (rpSession, rpSmallest);

  TConfig = record
    Shell: string;         // shell for autologin
    LoginShell: boolean;   // argv0 = -bash (reads .profile)
    User: string;          // autologin user (informative, already logged in)
    PrefixKey: integer;    // prefix key (17 = Ctrl-Q; 1..26 = Ctrl-A..Z)
    AutoSave: boolean;     // save session on exit
    AutoRestore: boolean;  // restore session on startup
    // draw the window contents while it is being dragged. Off = wireframe
    // drag: only the frame moves and the interior stays transparent, which
    // makes a drag cost the perimeter instead of the whole area -- a big win
    // on slow links. Default on (the familiar behaviour).
    DragContent: boolean;
    // draw a short expanding/contracting outline when F5 zooms a pane in or
    // out. Purely cosmetic and off by default: the instant transition is the
    // fast one, this is for whoever wants it to look nicer.
    ZoomAnim: boolean;
    // ASCII art picture shown on the desktop behind the windows, by file
    // name (see ~/.superterm/backgrounds and /usr/share/superterm/
    // backgrounds); 'none' is the plain pattern. BackgroundMode is the
    // classic wallpaper layout: center, tile, stretch or fit.
    Background: string;
    BackgroundMode: string;
    DefaultProfile: string;  // default profile (new model)
    DefaultTemplate: string; // legacy: used to derive DefaultProfile
    DefaultSession: string;  // legacy
    DefaultWindow: string;
    Language: TUiLanguage;
    Palette: string;       // 'color' (classic TP) | 'bw' | 'mono'
    // 'always': every session is born with a server and the terminal is a
    // client (controllable via CLI from startup); 'detach': classic mode,
    // the server only exists after detaching with prefix + d
    ServerMode: string;
    // Maximum total threads in a session daemon, INCLUDING its permanent
    // client/socket reactor. 1 is the original single-threaded event loop;
    // 0 means automatic (bounded by the CPUs available to the process).
    MultiThread: integer;
    ResizePolicy: TResizePolicy;
    // size, in cells, of a window opened from a class that does not fix its
    // own. 0 = automatic, which is two thirds of the desktop. The window
    // frame adds one cell on each side.
    NewWinCols: integer;
    NewWinRows: integer;
    // colour of the desktop behind the windows, as one of the sixteen the
    // text palette holds (0 = black, the default). A flat fill needs no more
    // than that, and staying inside the palette keeps it free: no per-cell
    // overlay entry for an area that covers the whole screen.
    DesktopColor: integer;
    // paint our own black ground instead of leaving it to the host terminal.
    // On by default: a terminal with a transparent background, or one whose
    // palette calls something else 'black', otherwise shows through
    // everything superterm draws. Turn it off to keep that transparency.
    SolidBg: boolean;
  end;

function ConfigDir: string;
function ConfigFile: string;
function SessionFile: string;
function SystemConfigFile: string;   // /etc/superterm/superterm.ini (or $SUPERTERM_INI)
function ExpandUserPath(const S: string): string;
function ParseUiLanguage(const S: string): TUiLanguage;
function UiLanguageCode(ALanguage: TUiLanguage): string;
function MultiThreadCode(AValue: integer): string;
function ParseMultiThread(const S: string; ADefault: integer = 1): integer;
function ResizePolicyCode(AValue: TResizePolicy): string;
function ParseResizePolicy(const S: string;
  ADefault: TResizePolicy = rpSession): TResizePolicy;

const
  DEFAULT_SCROLLBACK = 10000;
  MAX_SCROLLBACK = 100000;
  // the same bounds the daemon validates a resize against (WINOP_RESIZE)
  MAX_WIN_COLS = 1000;
  MAX_WIN_ROWS = 500;

{$I st_version.inc}

function ShellQuote(const S: string): string;

procedure LoadConfig(out Cfg: TConfig);
procedure SaveConfig(const Cfg: TConfig);

var
  // effective UI language, shared by all the UI units
  CurrentLanguage: TUiLanguage = ulEnglish;

// returns the text for the active language (all UI strings come in pairs)
function UiText(const EnglishText, SpanishText: string): string;

// uniform active-item mark in radio-style lists: '(*) ' / '( ) '
function ActiveMark(AActive: boolean): string;

// prefix key: parsing ('ctrl-q', 'q' or a number; the numeric 2 of the old
// default migrates to 17/Ctrl-Q to avoid clashing with remote tmux), saved
// code and label for the interface
function ParsePrefixKey(const S: string): integer;
function PrefixKeyCode(AKey: integer): string;   // 'ctrl-q'
function PrefixKeyLabel(AKey: integer): string;  // 'Ctrl-Q'

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

function ParseMultiThread(const S: string; ADefault: integer): integer;
var
  V: integer;
  T: string;
begin
  T := LowerCase(Trim(S));
  if T = 'auto' then
    Exit(0);
  if (T = 'off') or (T = 'single') then
    Exit(1);
  if not TryStrToInt(T, V) or (V < 1) then
    Exit(ADefault);
  // There are at most MAX_PANES workers plus the socket reactor. Keep a
  // generous parser ceiling here so st_config does not depend on st_layout;
  // the daemon applies its tighter CPU/pane cap.
  if V > 256 then
    V := 256;
  Result := V;
end;

function MultiThreadCode(AValue: integer): string;
begin
  if AValue = 0 then
    Result := 'auto'
  else
    Result := IntToStr(AValue);
end;

function ParseResizePolicy(const S: string;
  ADefault: TResizePolicy): TResizePolicy;
var
  T: string;
begin
  T := LowerCase(Trim(S));
  if (T = 'session') or (T = 'independent') or (T = 'fixed') then
    Exit(rpSession);
  if (T = 'smallest') or (T = 'minimum') or (T = 'shared') then
    Exit(rpSmallest);
  Result := ADefault;
end;

function ResizePolicyCode(AValue: TResizePolicy): string;
begin
  if AValue = rpSmallest then
    Result := 'smallest'
  else
    Result := 'session';
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

function ParsePrefixKey(const S: string): integer;
var
  T: string;
  V, Code: integer;
begin
  Result := 17; // Ctrl-Q: does not collide with the remote tmux's Ctrl-B
  T := LowerCase(Trim(S));
  if T = '' then
    Exit;
  Code := 0;
  V := 0;
  Val(T, V, Code);
  if Code = 0 then
  begin
    // numeric: 2 was the old default (Ctrl-B) and no user chose it on
    // purpose; an explicit value is honored via 'ctrl-b'
    if (V >= 1) and (V <= 26) and (V <> 2) then
      Result := V;
    Exit;
  end;
  if (Length(T) = 6) and (Copy(T, 1, 5) = 'ctrl-') and
     (T[6] in ['a'..'z']) then
    Result := Ord(T[6]) - Ord('a') + 1
  else if (Length(T) = 1) and (T[1] in ['a'..'z']) then
    Result := Ord(T[1]) - Ord('a') + 1;
end;

function PrefixKeyCode(AKey: integer): string;
begin
  if (AKey >= 1) and (AKey <= 26) then
    Result := 'ctrl-' + Chr(Ord('a') + AKey - 1)
  else
    Result := 'ctrl-q';
end;

function PrefixKeyLabel(AKey: integer): string;
begin
  if (AKey >= 1) and (AKey <= 26) then
    Result := 'Ctrl-' + Chr(Ord('A') + AKey - 1)
  else
    Result := 'Ctrl-Q';
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
  Cfg.PrefixKey := 17; // Ctrl-Q (does not collide with remote tmux/screen)
  Cfg.AutoSave := True;
  Cfg.AutoRestore := True;
  Cfg.DragContent := True;
  Cfg.ZoomAnim := False;
  Cfg.Background := 'phoenix';
  Cfg.BackgroundMode := 'center';
  Cfg.DefaultProfile := '';
  Cfg.DefaultTemplate := '';
  Cfg.DefaultSession := '';
  Cfg.DefaultWindow := '';
  Cfg.Language := ulEnglish;
  Cfg.Palette := 'color';
  Cfg.ServerMode := 'always';
  Cfg.MultiThread := 1;
  Cfg.ResizePolicy := rpSession;
  Cfg.NewWinCols := 0;
  Cfg.NewWinRows := 0;
  Cfg.DesktopColor := 0;        // black
  Cfg.SolidBg := True;
end;

procedure LoadConfig(out Cfg: TConfig);
var
  Ini: TIniFile;
  EnvThreads, EnvResize: string;
begin
  SetDefaults(Cfg);
  if not FileExists(ConfigFile) then
  begin
    EnvThreads := GetEnvironmentVariable('SUPERTERM_MULTITHREAD');
    if EnvThreads <> '' then
      Cfg.MultiThread := ParseMultiThread(EnvThreads, Cfg.MultiThread);
    EnvResize := GetEnvironmentVariable('SUPERTERM_RESIZE_POLICY');
    if EnvResize <> '' then
      Cfg.ResizePolicy := ParseResizePolicy(EnvResize, Cfg.ResizePolicy);
    Exit;
  end;
  Ini := TIniFile.Create(ConfigFile);
  try
    Cfg.Shell := Ini.ReadString('autologin', 'shell', Cfg.Shell);
    Cfg.LoginShell := Ini.ReadBool('autologin', 'login', Cfg.LoginShell);
    Cfg.User := Ini.ReadString('autologin', 'user', Cfg.User);
    Cfg.PrefixKey := ParsePrefixKey(Ini.ReadString('keymap', 'prefix', ''));
    Cfg.ServerMode := LowerCase(Trim(Ini.ReadString('session', 'server',
      Cfg.ServerMode)));
    if (Cfg.ServerMode <> 'always') and (Cfg.ServerMode <> 'detach') then
      Cfg.ServerMode := 'always';
    Cfg.MultiThread := ParseMultiThread(Ini.ReadString('session',
      'multithread', MultiThreadCode(Cfg.MultiThread)), Cfg.MultiThread);
    Cfg.ResizePolicy := ParseResizePolicy(Ini.ReadString('session',
      'resize_policy', ResizePolicyCode(Cfg.ResizePolicy)),
      Cfg.ResizePolicy);
    Cfg.AutoSave := Ini.ReadBool('session', 'autosave', Cfg.AutoSave);
    Cfg.AutoRestore := Ini.ReadBool('session', 'autorestore', Cfg.AutoRestore);
    Cfg.DragContent := Ini.ReadBool('session', 'dragcontent', Cfg.DragContent);
    Cfg.ZoomAnim := Ini.ReadBool('session', 'zoomanim', Cfg.ZoomAnim);
    Cfg.DesktopColor := Ini.ReadInteger('ui', 'desktop_color',
      Cfg.DesktopColor);
    Cfg.SolidBg := Ini.ReadBool('ui', 'solid_background', Cfg.SolidBg);
    if (Cfg.DesktopColor < 0) or (Cfg.DesktopColor > 15) then
      Cfg.DesktopColor := 0;
    Cfg.NewWinCols := Ini.ReadInteger('ui', 'newwincols', Cfg.NewWinCols);
    Cfg.NewWinRows := Ini.ReadInteger('ui', 'newwinrows', Cfg.NewWinRows);
    if (Cfg.NewWinCols < 0) or (Cfg.NewWinCols > MAX_WIN_COLS) then
      Cfg.NewWinCols := 0;
    if (Cfg.NewWinRows < 0) or (Cfg.NewWinRows > MAX_WIN_ROWS) then
      Cfg.NewWinRows := 0;
    Cfg.Background := LowerCase(Trim(Ini.ReadString('ui', 'background',
      Cfg.Background)));
    Cfg.BackgroundMode := LowerCase(Trim(Ini.ReadString('ui', 'background_mode',
      Cfg.BackgroundMode)));
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
    Cfg.Palette := LowerCase(Trim(Ini.ReadString('ui', 'palette',
      Cfg.Palette)));
    if (Cfg.Palette <> 'bw') and (Cfg.Palette <> 'mono') then
      Cfg.Palette := 'color';
  finally
    Ini.Free;
  end;
  // Per-launch override for deterministic debugging and concurrency tests.
  // The detached daemon inherits it through fork, so the selected topology
  // cannot diverge between the launching client and its session server.
  EnvThreads := GetEnvironmentVariable('SUPERTERM_MULTITHREAD');
  if EnvThreads <> '' then
    Cfg.MultiThread := ParseMultiThread(EnvThreads, Cfg.MultiThread);
  EnvResize := GetEnvironmentVariable('SUPERTERM_RESIZE_POLICY');
  if EnvResize <> '' then
    Cfg.ResizePolicy := ParseResizePolicy(EnvResize, Cfg.ResizePolicy);
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
    Ini.WriteString('keymap', 'prefix', PrefixKeyCode(Cfg.PrefixKey));
    Ini.WriteString('session', 'server', Cfg.ServerMode);
    Ini.WriteString('session', 'multithread',
      MultiThreadCode(Cfg.MultiThread));
    Ini.WriteString('session', 'resize_policy',
      ResizePolicyCode(Cfg.ResizePolicy));
    Ini.WriteBool('session', 'autosave', Cfg.AutoSave);
    Ini.WriteBool('session', 'autorestore', Cfg.AutoRestore);
    Ini.WriteBool('session', 'dragcontent', Cfg.DragContent);
    Ini.WriteBool('session', 'zoomanim', Cfg.ZoomAnim);
    Ini.WriteInteger('ui', 'desktop_color', Cfg.DesktopColor);
    Ini.WriteBool('ui', 'solid_background', Cfg.SolidBg);
    Ini.WriteInteger('ui', 'newwincols', Cfg.NewWinCols);
    Ini.WriteInteger('ui', 'newwinrows', Cfg.NewWinRows);
    Ini.WriteString('ui', 'background', Cfg.Background);
    Ini.WriteString('ui', 'background_mode', Cfg.BackgroundMode);
    Ini.WriteString('session', 'default_profile', Cfg.DefaultProfile);
    Ini.WriteString('session', 'default_template', Cfg.DefaultTemplate);
    Ini.WriteString('session', 'default_session', Cfg.DefaultSession);
    Ini.WriteString('session', 'default_window', Cfg.DefaultWindow);
    Ini.WriteString('ui', 'language', UiLanguageCode(Cfg.Language));
    Ini.WriteString('ui', 'palette', Cfg.Palette);
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
