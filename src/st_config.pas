(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_config - configuration and paths
*)

unit st_config;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, ctypes, st_os
  {$IFDEF UNIX}, BaseUnix, Unix{$ENDIF}
  {$IFDEF WINDOWS}, Windows{$ENDIF};

type
  EConfigWriteError = class(EInOutError);

  TUiLanguage = (ulEnglish, ulSpanish);

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
    // draw a short expanding/contracting outline when fullscreen zooms a pane in or
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
    // SSH entry routing is independent of the canonical desktop. "last"
    // resumes the last session successfully used through this account;
    // "default" always resolves DefaultSession/DefaultProfile instead.
    SshSessionMode: string;
    SshLastSession: string;  // managed pointer, never a saved workspace
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

  // Field-scoped persistence prevents two attached clients changing
  // independent preferences from overwriting each other's stale TConfig
  // snapshot. SaveConfig remains the explicit full-record operation.
  TConfigField = (cfShell, cfLoginShell, cfUser, cfPrefixKey,
    cfServerMode, cfMultiThread, cfAutoSave, cfAutoRestore, cfDragContent,
    cfZoomAnim, cfDesktopColor, cfSolidBg, cfNewWinCols, cfNewWinRows,
    cfBackground, cfBackgroundMode, cfDefaultProfile, cfDefaultTemplate,
    cfDefaultSession, cfSshSessionMode, cfSshLastSession, cfDefaultWindow,
    cfLanguage, cfPalette);
  TConfigFields = set of TConfigField;

function ConfigDir: string;
function ConfigFile: string;
// Reads only [ui] language without creating/chmodding ConfigDir.  Early CLI
// help uses this so observing documentation cannot mutate the caller's HOME.
function TryReadUserUiLanguage(out ALanguage: TUiLanguage): boolean;
function SessionFile: string;
function SystemConfigFile: string;   // /etc/superterm/superterm.ini (or $SUPERTERM_INI)
function ExpandUserPath(const S: string): string;
function ParseUiLanguage(const S: string): TUiLanguage;
function UiLanguageCode(ALanguage: TUiLanguage): string;
function MultiThreadCode(AValue: integer): string;
function ParseMultiThread(const S: string; ADefault: integer = 1): integer;

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
procedure SaveConfigFields(const Cfg: TConfig; const Fields: TConfigFields);
// Update the selected window only if the current on-disk default still names
// ExpectedProfile.  This keeps the profile/window pair from two clients in
// one locked generation instead of combining a fresh profile with stale UI
// state. False is a harmless compare failure; no file is replaced.
function SaveDefaultWindowIfProfile(const ExpectedProfile,
  NewWindow: string): boolean;

// Every writer of superterm.ini uses this stable side lock. It is never
// renamed or removed, so separate clients serialize read-modify-replace
// transactions across configuration, profiles and window classes.
function AcquireConfigFileLock(const FileName: string): cint;
procedure ReleaseConfigFileLock(var Fd: cint);

// Shared atomic rewrite primitive for every superterm.ini domain. The
// temporary is born mode 0600 beside the destination, initially contains an
// exact copy of the current file, and is never published by cleanup code.
// Precondition: the caller MUST hold AcquireConfigFileLock(FileName) until
// commit or temporary cleanup completes.
function BeginConfigRewriteLocked(const FileName, Tag: string): string;
procedure CommitConfigRewriteLocked(var TempName: string;
  const FileName: string);

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

const
  CONFIG_LOCK_WAIT_MS = 30000;
  CONFIG_LOCK_POLL_MS = 20;
  CONFIG_LOCK_ATTEMPTS = CONFIG_LOCK_WAIT_MS div CONFIG_LOCK_POLL_MS;
  {$IFDEF UNIX}
  ST_FD_CLOEXEC = 1;
  {$ENDIF}
  {$IFDEF WINDOWS}
  // Present in the Windows 10 SDK used by FPC, but missing from FPC 3.2.2's
  // translated constants.
  ST_MOVEFILE_WRITE_THROUGH = $00000008;
  ST_FILE_FLAG_OPEN_REPARSE_POINT = $00200000;
  {$ENDIF}

var
  ConfigTempSerial: QWord = 0;

{$IFDEF WINDOWS}
type
  TWindowsConfigLockSlot = record
    Handle: THandle;
    InUse: boolean;
  end;

var
  WindowsConfigLockGuard: TRTLCriticalSection;
  WindowsConfigLocks: array of TWindowsConfigLockSlot;

function RememberWindowsConfigLock(AHandle: THandle): cint;
var
  I: integer;
begin
  EnterCriticalsection(WindowsConfigLockGuard);
  try
    for I := 0 to High(WindowsConfigLocks) do
      if not WindowsConfigLocks[I].InUse then
      begin
        WindowsConfigLocks[I].Handle := AHandle;
        WindowsConfigLocks[I].InUse := True;
        Exit(I);
      end;
    I := Length(WindowsConfigLocks);
    SetLength(WindowsConfigLocks, I + 1);
    WindowsConfigLocks[I].Handle := AHandle;
    WindowsConfigLocks[I].InUse := True;
    Result := I;
  finally
    LeaveCriticalsection(WindowsConfigLockGuard);
  end;
end;

function ForgetWindowsConfigLock(var AToken: cint): THandle;
begin
  Result := INVALID_HANDLE_VALUE;
  if AToken < 0 then
    Exit;
  EnterCriticalsection(WindowsConfigLockGuard);
  try
    if (AToken <= High(WindowsConfigLocks)) and
       WindowsConfigLocks[AToken].InUse then
    begin
      Result := WindowsConfigLocks[AToken].Handle;
      WindowsConfigLocks[AToken].Handle := INVALID_HANDLE_VALUE;
      WindowsConfigLocks[AToken].InUse := False;
    end;
    AToken := -1;
  finally
    LeaveCriticalsection(WindowsConfigLockGuard);
  end;
end;

procedure FinalizeWindowsConfigLocks;
var
  I: integer;
  Ov: TOverlapped;
begin
  for I := 0 to High(WindowsConfigLocks) do
    if WindowsConfigLocks[I].InUse then
    begin
      Ov := Default(TOverlapped);
      UnlockFileEx(WindowsConfigLocks[I].Handle, 0, 1, 0, @Ov);
      CloseHandle(WindowsConfigLocks[I].Handle);
      WindowsConfigLocks[I].InUse := False;
    end;
  WindowsConfigLocks := nil;
end;
{$ENDIF}

function ConfigDir: string;
begin
  Result := OsConfigDir;
  if not DirectoryExists(Result) then
    ForceDirectories(Result);
  if DirectoryExists(Result) then
    OsRestrictDir(Result);
end;

function ExpandUserPath(const S: string): string;
var
  Home: string;
begin
  Result := S;
  if (Length(S) >= 2) and (S[1] = '~') and (S[2] in ['/', '\']) then
  begin
    Home := OsUserHome;
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
  Result := IncludeTrailingPathDelimiter(ConfigDir) + 'superterm.ini';
end;

function TryReadUserUiLanguage(out ALanguage: TUiLanguage): boolean;
var
  Ini: TIniFile;
  FileName: string;
begin
  Result := False;
  ALanguage := ulEnglish;
  // Deliberately construct the same path without calling ConfigDir: that
  // routine creates the directory and enforces mode 0700 for write paths.
  FileName := IncludeTrailingPathDelimiter(OsConfigDir) + 'superterm.ini';
  if not FileExists(FileName) then
    Exit;
  try
    // FPC TIniFile read methods leave Dirty false; with no Write*/UpdateFile
    // call, construction/read/destruction is a strictly read-only operation.
    Ini := TIniFile.Create(FileName);
    try
      ALanguage := ParseUiLanguage(Ini.ReadString('ui', 'language', 'en'));
      Result := True;
    finally
      Ini.Free;
    end;
  except
    // Help and read-only CLI diagnostics remain available even if a user
    // configuration disappears or becomes unreadable during this probe.
    Result := False;
    ALanguage := ulEnglish;
  end;
end;

function SessionFile: string;
begin
  Result := IncludeTrailingPathDelimiter(ConfigDir) + 'session.ini';
end;

procedure SetDefaults(out Cfg: TConfig);
var
  Sh: string;
begin
  {$IFDEF WINDOWS}
  Sh := SysUtils.GetEnvironmentVariable('COMSPEC');
  if Sh = '' then Sh := 'cmd.exe';
  {$ELSE}
  Sh := SysUtils.GetEnvironmentVariable('SHELL');
  if Sh = '' then Sh := '/bin/bash';
  {$ENDIF}
  Cfg.Shell := Sh;
  {$IFDEF WINDOWS}
  Cfg.LoginShell := False;
  Cfg.User := SysUtils.GetEnvironmentVariable('USERNAME');
  {$ELSE}
  Cfg.LoginShell := True;
  Cfg.User := SysUtils.GetEnvironmentVariable('USER');
  {$ENDIF}
  Cfg.PrefixKey := 17; // Ctrl-Q (does not collide with remote tmux/screen)
  Cfg.AutoSave := True;
  Cfg.AutoRestore := True;
  Cfg.DragContent := True;
  Cfg.ZoomAnim := False;
  // The original alien artwork keeps its historical on-disk identifier
  // "goody" so existing installations and profiles remain compatible.
  Cfg.Background := 'goody';
  Cfg.BackgroundMode := 'center';
  Cfg.DefaultProfile := '';
  Cfg.DefaultTemplate := '';
  Cfg.DefaultSession := '';
  Cfg.SshSessionMode := 'last';
  Cfg.SshLastSession := '';
  Cfg.DefaultWindow := '';
  Cfg.Language := ulEnglish;
  // Keep the upstream first-install presentation on every platform.
  Cfg.Palette := 'mono';
  {$IFDEF WINDOWS}
  Cfg.ServerMode := 'detach'; // native detach/multi-client is Phase 2
  {$ELSE}
  Cfg.ServerMode := 'always';
  {$ENDIF}
  Cfg.MultiThread := 1;
  Cfg.NewWinCols := 0;
  Cfg.NewWinRows := 0;
  Cfg.DesktopColor := 0;        // black
  Cfg.SolidBg := True;
end;

procedure LoadConfig(out Cfg: TConfig);
var
  Ini: TIniFile;
  EnvThreads: string;
begin
  SetDefaults(Cfg);
  if not FileExists(ConfigFile) then
  begin
    EnvThreads := SysUtils.GetEnvironmentVariable('SUPERTERM_MULTITHREAD');
    if EnvThreads <> '' then
      Cfg.MultiThread := ParseMultiThread(EnvThreads, Cfg.MultiThread);
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
    Cfg.SshSessionMode := LowerCase(Trim(Ini.ReadString('session',
      'ssh_session', Cfg.SshSessionMode)));
    if (Cfg.SshSessionMode <> 'last') and
       (Cfg.SshSessionMode <> 'default') then
      Cfg.SshSessionMode := 'last';
    Cfg.SshLastSession := Trim(Ini.ReadString('session',
      'ssh_last_session', Cfg.SshLastSession));
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
  EnvThreads := SysUtils.GetEnvironmentVariable('SUPERTERM_MULTITHREAD');
  if EnvThreads <> '' then
    Cfg.MultiThread := ParseMultiThread(EnvThreads, Cfg.MultiThread);
end;

function AcquireConfigFileLock(const FileName: string): cint;
var
  {$IFDEF WINDOWS}
  H: THandle;
  Ov: TOverlapped;
  Info: TByHandleFileInformation;
  LockName: UnicodeString;
  E: DWORD;
  {$ELSE}
  Flags, E: cint;
  St: Stat;
  LockName: RawByteString;
  {$ENDIF}
  Attempt, Attempts, V: integer;
  S: string;
begin
  {$IFDEF WINDOWS}
  Result := -1;
  LockName := UTF8Decode(FileName + '.lock');
  H := CreateFileW(PWideChar(LockName), GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_ALWAYS,
    FILE_ATTRIBUTE_NORMAL or ST_FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if H = INVALID_HANDLE_VALUE then
  begin
    E := GetLastOSError;
    raise EConfigWriteError.CreateFmt(
      'Cannot open configuration lock %s: %s',
      [FileName + '.lock', SysErrorMessage(E)]);
  end;
  try
    Info := Default(TByHandleFileInformation);
    if not GetFileInformationByHandle(H, Info) or
       ((Info.dwFileAttributes and
        (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) <> 0) then
      raise EConfigWriteError.CreateFmt(
        'Configuration lock is not a regular file: %s',
        [FileName + '.lock']);
    Attempts := CONFIG_LOCK_ATTEMPTS;
    S := SysUtils.GetEnvironmentVariable('SUPERTERM_TEST_CONFIG_LOCK_POLLS');
    if (SysUtils.GetEnvironmentVariable('SUPERTERM_TESTING') = '1') and
       TryStrToInt(S, V) and (V >= 1) and (V <= Attempts) then
      Attempts := V;
    Ov := Default(TOverlapped);
    E := ERROR_SUCCESS;
    for Attempt := 1 to Attempts do
    begin
      if LockFileEx(H, LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY,
        0, 1, 0, @Ov) then
      begin
        Result := RememberWindowsConfigLock(H);
        H := INVALID_HANDLE_VALUE;
        Exit;
      end;
      E := GetLastOSError;
      if E <> ERROR_LOCK_VIOLATION then
        Break;
      if Attempt < Attempts then
        Sleep(CONFIG_LOCK_POLL_MS);
    end;
    if E = ERROR_LOCK_VIOLATION then
      raise EConfigWriteError.CreateFmt(
        'Timed out waiting for configuration lock %s', [FileName])
    else
      raise EConfigWriteError.CreateFmt('Cannot lock configuration %s: %s',
        [FileName, SysErrorMessage(E)]);
  finally
    if H <> INVALID_HANDLE_VALUE then
      CloseHandle(H);
  end;
  {$ELSE}
  Result := -1;
  LockName := RawByteString(FileName + '.lock');
  Flags := O_RDWR or O_CREAT;
  {$IF DEFINED(LINUX) OR DEFINED(BSD) OR DEFINED(DARWIN)}
  Flags := Flags or Open_NoFollow;
  {$ENDIF}
  repeat
    Result := FpOpen(LockName, Flags, &600);
    E := FpGetErrNo;
  until (Result >= 0) or (E <> ESysEINTR);
  if Result < 0 then
    raise EConfigWriteError.CreateFmt(
      'Cannot open configuration lock %s: %s',
      [string(LockName), SysErrorMessage(E)]);
  if FpFcntl(Result, F_SETFD, ST_FD_CLOEXEC) < 0 then
  begin
    E := FpGetErrNo;
    FpClose(Result);
    Result := -1;
    raise EConfigWriteError.CreateFmt(
      'Cannot protect configuration lock %s: %s',
      [string(LockName), SysErrorMessage(E)]);
  end;
  St := Default(Stat);
  if (FpFStat(Result, St) <> 0) or (not FpS_ISREG(St.st_mode)) or
     (St.st_uid <> FpGetEUid) or ((St.st_mode and &22) <> 0) then
  begin
    FpClose(Result);
    Result := -1;
    raise EConfigWriteError.CreateFmt(
      'Configuration lock is not a protected regular file: %s',
      [string(LockName)]);
  end;
  Attempts := CONFIG_LOCK_ATTEMPTS;
  S := SysUtils.GetEnvironmentVariable('SUPERTERM_TEST_CONFIG_LOCK_POLLS');
  if (SysUtils.GetEnvironmentVariable('SUPERTERM_TESTING') = '1') and
     TryStrToInt(S, V) and (V >= 1) and (V <= Attempts) then
    Attempts := V;
  for Attempt := 1 to Attempts do
  begin
    if FpFlock(Result, LOCK_EX or LOCK_NB) = 0 then
      Exit;
    E := FpGetErrNo;
    if E = ESysEINTR then
      Continue;
    if (E <> ESysEAGAIN) and (E <> ESysEWOULDBLOCK) then
      Break;
    if Attempt < Attempts then
      Sleep(CONFIG_LOCK_POLL_MS);
  end;
  FpClose(Result);
  Result := -1;
  if (E = ESysEAGAIN) or (E = ESysEWOULDBLOCK) then
    raise EConfigWriteError.CreateFmt(
      'Timed out waiting for configuration lock %s', [FileName])
  else
    raise EConfigWriteError.CreateFmt('Cannot lock configuration %s: %s',
      [FileName, SysErrorMessage(E)]);
  {$ENDIF}
end;

procedure ReleaseConfigFileLock(var Fd: cint);
{$IFDEF WINDOWS}
var
  H: THandle;
  Ov: TOverlapped;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  H := ForgetWindowsConfigLock(Fd);
  if H = INVALID_HANDLE_VALUE then
    Exit;
  Ov := Default(TOverlapped);
  UnlockFileEx(H, 0, 1, 0, @Ov);
  CloseHandle(H);
  {$ELSE}
  if Fd < 0 then
    Exit;
  FpFlock(Fd, LOCK_UN);
  FpClose(Fd);
  Fd := -1;
  {$ENDIF}
end;

function BeginConfigRewriteLocked(const FileName, Tag: string): string;
var
  {$IFDEF WINDOWS}
  H: THandle;
  E: DWORD;
  Info: TByHandleFileInformation;
  TempWide: UnicodeString;
  {$ELSE}
  Flags, Fd, E: cint;
  St: Stat;
  {$ENDIF}
  Source: TFileStream;
  Target: THandleStream;
begin
  {$IFDEF WINDOWS}
  H := INVALID_HANDLE_VALUE;
  repeat
    Inc(ConfigTempSerial);
    Result := FileName + '.tmp.' + IntToStr(OsGetPid) + '.' +
      IntToStr(ConfigTempSerial) + '.' + Tag;
    TempWide := UTF8Decode(Result);
    H := CreateFileW(PWideChar(TempWide), GENERIC_READ or GENERIC_WRITE, 0,
      nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
    if H = INVALID_HANDLE_VALUE then
      E := GetLastOSError
    else
      E := ERROR_SUCCESS;
  until (H <> INVALID_HANDLE_VALUE) or
    ((E <> ERROR_FILE_EXISTS) and (E <> ERROR_ALREADY_EXISTS));
  if H = INVALID_HANDLE_VALUE then
    raise EConfigWriteError.CreateFmt(
      'Cannot create configuration temporary %s: %s',
      [Result, SysErrorMessage(E)]);
  try
    Info := Default(TByHandleFileInformation);
    if not GetFileInformationByHandle(H, Info) or
       ((Info.dwFileAttributes and
        (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) <> 0) then
      raise EConfigWriteError.CreateFmt(
        'Configuration temporary is not a regular file: %s', [Result]);
    Target := THandleStream.Create(H);
    try
      if FileExists(FileName) then
      begin
        Source := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
        try
          Target.CopyFrom(Source, 0);
        finally
          Source.Free;
        end;
      end;
    finally
      Target.Free;
    end;
  except
    CloseHandle(H);
    DeleteFileW(PWideChar(TempWide));
    raise;
  end;
  if not CloseHandle(H) then
  begin
    E := GetLastOSError;
    DeleteFileW(PWideChar(TempWide));
    raise EConfigWriteError.CreateFmt(
      'Cannot close configuration temporary %s: %s',
      [Result, SysErrorMessage(E)]);
  end;
  OsRestrictFile(Result);
  {$ELSE}
  repeat
    Inc(ConfigTempSerial);
    Result := FileName + '.tmp.' + IntToStr(FpGetPid) + '.' +
      IntToStr(ConfigTempSerial) + '.' + Tag;
    Flags := O_WRONLY or O_CREAT or O_EXCL;
    {$IF DEFINED(LINUX) OR DEFINED(BSD) OR DEFINED(DARWIN)}
    Flags := Flags or Open_NoFollow;
    {$ENDIF}
    repeat
      Fd := FpOpen(RawByteString(Result), Flags, &600);
      E := FpGetErrNo;
    until (Fd >= 0) or (E <> ESysEINTR);
  until (Fd >= 0) or (E <> ESysEEXIST);
  if Fd < 0 then
    raise EConfigWriteError.CreateFmt(
      'Cannot create configuration temporary %s: %s',
      [Result, SysErrorMessage(E)]);
  try
    if FpFcntl(Fd, F_SETFD, ST_FD_CLOEXEC) < 0 then
      raise EConfigWriteError.CreateFmt(
        'Cannot protect configuration temporary %s: %s',
        [Result, SysErrorMessage(FpGetErrNo)]);
    if FpChmod(RawByteString(Result), &600) <> 0 then
      raise EConfigWriteError.CreateFmt(
        'Cannot protect configuration temporary %s: %s',
        [Result, SysErrorMessage(FpGetErrNo)]);
    St := Default(Stat);
    if (FpFStat(Fd, St) <> 0) or (not FpS_ISREG(St.st_mode)) or
       (St.st_uid <> FpGetEUid) or ((St.st_mode and &77) <> 0) then
      raise EConfigWriteError.CreateFmt(
        'Configuration temporary is not a protected regular file: %s',
        [Result]);
    Target := THandleStream.Create(Fd);
    try
      if FileExists(FileName) then
      begin
        Source := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
        try
          Target.CopyFrom(Source, 0);
        finally
          Source.Free;
        end;
      end;
    finally
      Target.Free;
    end;
  except
    FpClose(Fd);
    FpUnlink(RawByteString(Result));
    raise;
  end;
  if FpClose(Fd) <> 0 then
  begin
    E := FpGetErrNo;
    FpUnlink(RawByteString(Result));
    raise EConfigWriteError.CreateFmt(
      'Cannot close configuration temporary %s: %s',
      [Result, SysErrorMessage(E)]);
  end;
  {$ENDIF}
end;

{$IFDEF UNIX}
procedure SyncParentDirectoryBestEffort(const FileName: string);
var
  DirName: string;
  Fd: cint;
begin
  DirName := ExtractFileDir(FileName);
  if DirName = '' then
    DirName := '.';
  Fd := FpOpen(RawByteString(DirName), O_RDONLY, 0);
  if Fd < 0 then
    Exit;
  FpFcntl(Fd, F_SETFD, ST_FD_CLOEXEC);
  FpFsync(Fd);
  FpClose(Fd);
end;
{$ENDIF}

procedure CommitConfigRewriteLocked(var TempName: string;
  const FileName: string);
var
  {$IFDEF WINDOWS}
  H: THandle;
  E: DWORD;
  Info: TByHandleFileInformation;
  TempWide, FileWide: UnicodeString;
  {$ELSE}
  Flags, Fd, E: cint;
  St: Stat;
  {$ENDIF}
begin
  {$IFDEF WINDOWS}
  TempWide := UTF8Decode(TempName);
  FileWide := UTF8Decode(FileName);
  H := CreateFileW(PWideChar(TempWide), GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL or ST_FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if H = INVALID_HANDLE_VALUE then
  begin
    E := GetLastOSError;
    raise EConfigWriteError.CreateFmt(
      'Cannot reopen configuration temporary %s: %s',
      [TempName, SysErrorMessage(E)]);
  end;
  try
    Info := Default(TByHandleFileInformation);
    if not GetFileInformationByHandle(H, Info) or
       ((Info.dwFileAttributes and
        (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) <> 0) then
      raise EConfigWriteError.CreateFmt(
        'Configuration temporary is not a regular file: %s', [TempName]);
    if not FlushFileBuffers(H) then
    begin
      E := GetLastOSError;
      raise EConfigWriteError.CreateFmt(
        'Cannot sync configuration temporary %s: %s',
        [TempName, SysErrorMessage(E)]);
    end;
  finally
    CloseHandle(H);
  end;
  if not MoveFileExW(PWideChar(TempWide), PWideChar(FileWide),
    MOVEFILE_REPLACE_EXISTING or ST_MOVEFILE_WRITE_THROUGH) then
  begin
    E := GetLastOSError;
    raise EConfigWriteError.CreateFmt(
      'Cannot atomically replace configuration file %s: %s',
      [FileName, SysErrorMessage(E)]);
  end;
  TempName := '';
  {$ELSE}
  Flags := O_RDONLY;
  {$IF DEFINED(LINUX) OR DEFINED(BSD) OR DEFINED(DARWIN)}
  Flags := Flags or Open_NoFollow;
  {$ENDIF}
  repeat
    Fd := FpOpen(RawByteString(TempName), Flags, 0);
    E := FpGetErrNo;
  until (Fd >= 0) or (E <> ESysEINTR);
  if Fd < 0 then
    raise EConfigWriteError.CreateFmt(
      'Cannot reopen configuration temporary %s: %s',
      [TempName, SysErrorMessage(E)]);
  try
    if FpFcntl(Fd, F_SETFD, ST_FD_CLOEXEC) < 0 then
      raise EConfigWriteError.CreateFmt(
        'Cannot protect configuration temporary %s: %s',
        [TempName, SysErrorMessage(FpGetErrNo)]);
    St := Default(Stat);
    if (FpFStat(Fd, St) <> 0) or (not FpS_ISREG(St.st_mode)) or
       (St.st_uid <> FpGetEUid) or ((St.st_mode and &77) <> 0) then
      raise EConfigWriteError.CreateFmt(
        'Configuration temporary is not a protected regular file: %s',
        [TempName]);
    if FpFsync(Fd) <> 0 then
      raise EConfigWriteError.CreateFmt(
        'Cannot sync configuration temporary %s: %s',
        [TempName, SysErrorMessage(FpGetErrNo)]);
  finally
    FpClose(Fd);
  end;
  if FpRename(RawByteString(TempName), RawByteString(FileName)) <> 0 then
  begin
    E := FpGetErrNo;
    raise EConfigWriteError.CreateFmt(
      'Cannot atomically replace configuration file %s: %s',
      [FileName, SysErrorMessage(E)]);
  end;
  TempName := '';
  SyncParentDirectoryBestEffort(FileName);
  {$ENDIF}
end;

procedure SaveConfigFields(const Cfg: TConfig; const Fields: TConfigFields);
var
  Ini: TIniFile;
  FileName, TempName: string;
  LockFd: cint;
begin
  FileName := ConfigFile;
  LockFd := AcquireConfigFileLock(FileName);
  try
    TempName := BeginConfigRewriteLocked(FileName, 'config');
    try
      Ini := TIniFile.Create(TempName);
      try
        Ini.CacheUpdates := True;
        if cfShell in Fields then
          Ini.WriteString('autologin', 'shell', Cfg.Shell);
        if cfLoginShell in Fields then
          Ini.WriteBool('autologin', 'login', Cfg.LoginShell);
        if cfUser in Fields then
          Ini.WriteString('autologin', 'user', Cfg.User);
        if cfPrefixKey in Fields then
          Ini.WriteString('keymap', 'prefix', PrefixKeyCode(Cfg.PrefixKey));
        if cfServerMode in Fields then
          Ini.WriteString('session', 'server', Cfg.ServerMode);
        if cfMultiThread in Fields then
          Ini.WriteString('session', 'multithread',
            MultiThreadCode(Cfg.MultiThread));
        if cfAutoSave in Fields then
          Ini.WriteBool('session', 'autosave', Cfg.AutoSave);
        if cfAutoRestore in Fields then
          Ini.WriteBool('session', 'autorestore', Cfg.AutoRestore);
        if cfDragContent in Fields then
          Ini.WriteBool('session', 'dragcontent', Cfg.DragContent);
        if cfZoomAnim in Fields then
          Ini.WriteBool('session', 'zoomanim', Cfg.ZoomAnim);
        if cfDesktopColor in Fields then
          Ini.WriteInteger('ui', 'desktop_color', Cfg.DesktopColor);
        if cfSolidBg in Fields then
          Ini.WriteBool('ui', 'solid_background', Cfg.SolidBg);
        if cfNewWinCols in Fields then
          Ini.WriteInteger('ui', 'newwincols', Cfg.NewWinCols);
        if cfNewWinRows in Fields then
          Ini.WriteInteger('ui', 'newwinrows', Cfg.NewWinRows);
        if cfBackground in Fields then
          Ini.WriteString('ui', 'background', Cfg.Background);
        if cfBackgroundMode in Fields then
          Ini.WriteString('ui', 'background_mode', Cfg.BackgroundMode);
        if cfDefaultProfile in Fields then
          Ini.WriteString('session', 'default_profile', Cfg.DefaultProfile);
        if cfDefaultTemplate in Fields then
          Ini.WriteString('session', 'default_template', Cfg.DefaultTemplate);
        if cfDefaultSession in Fields then
          Ini.WriteString('session', 'default_session', Cfg.DefaultSession);
        if cfSshSessionMode in Fields then
          Ini.WriteString('session', 'ssh_session', Cfg.SshSessionMode);
        if cfSshLastSession in Fields then
          Ini.WriteString('session', 'ssh_last_session', Cfg.SshLastSession);
        if cfDefaultWindow in Fields then
          Ini.WriteString('session', 'default_window', Cfg.DefaultWindow);
        if cfLanguage in Fields then
          Ini.WriteString('ui', 'language', UiLanguageCode(Cfg.Language));
        if cfPalette in Fields then
          Ini.WriteString('ui', 'palette', Cfg.Palette);
        Ini.UpdateFile;
      finally
        Ini.Free;
      end;
      CommitConfigRewriteLocked(TempName, FileName);
    finally
      if TempName <> '' then
        SysUtils.DeleteFile(TempName);
    end;
  finally
    ReleaseConfigFileLock(LockFd);
  end;
end;

procedure SaveConfig(const Cfg: TConfig);
begin
  SaveConfigFields(Cfg, [Low(TConfigField)..High(TConfigField)]);
end;

function SaveDefaultWindowIfProfile(const ExpectedProfile,
  NewWindow: string): boolean;
var
  Ini: TIniFile;
  FileName, TempName, CurrentProfile: string;
  LockFd: cint;
begin
  Result := False;
  if ExpectedProfile = '' then
    Exit;
  FileName := ConfigFile;
  LockFd := AcquireConfigFileLock(FileName);
  try
    TempName := BeginConfigRewriteLocked(FileName, 'default-window');
    try
      Ini := TIniFile.Create(TempName);
      try
        CurrentProfile := Ini.ReadString('session', 'default_profile', '');
        if not SameText(CurrentProfile, ExpectedProfile) then
          Exit;
        Ini.CacheUpdates := True;
        Ini.WriteString('session', 'default_window', NewWindow);
        Ini.UpdateFile;
      finally
        Ini.Free;
      end;
      CommitConfigRewriteLocked(TempName, FileName);
      Result := True;
    finally
      if TempName <> '' then
        SysUtils.DeleteFile(TempName);
    end;
  finally
    ReleaseConfigFileLock(LockFd);
  end;
end;

function SystemConfigFile: string;
{$IFDEF WINDOWS}
var
  Base: string;
{$ENDIF}
begin
  Result := SysUtils.GetEnvironmentVariable('SUPERTERM_INI');
  if Result = '' then
    {$IFDEF WINDOWS}
    begin
      Base := SysUtils.GetEnvironmentVariable('PROGRAMDATA');
      if Base = '' then
        Result := IncludeTrailingPathDelimiter(ConfigDir) + 'superterm.ini'
      else
        Result := IncludeTrailingPathDelimiter(Base) + 'superterm' +
          PathDelim + 'superterm.ini';
    end
    {$ELSE}
    Result := '/etc/superterm/superterm.ini';
    {$ENDIF}
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

{$IFDEF WINDOWS}
initialization
  InitCriticalSection(WindowsConfigLockGuard);

finalization
  FinalizeWindowsConfigLocks;
  DoneCriticalSection(WindowsConfigLockGuard);
{$ENDIF}

end.
