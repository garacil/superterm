(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_wclass - window classes: reusable named definition
  (open command, ssh connection target or free command, post-connect
  command). They absorb the old [t-*] terminal definitions.
*)

unit st_wclass;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, IniFiles, st_os, st_config;

type
  // the kind is derived on load and never persisted:
  // connect present -> wcCommand; host present -> wcSSH; else -> wcLocal
  TWClassKind = (wcLocal, wcSSH, wcCommand);
  TWClassOrigin = (coUser, coSystem);

  TWindowClass = record
    Name: string;          // canonical name (section suffix)
    Enabled: boolean;
    Kind: TWClassKind;     // derived, not persisted
    Origin: TWClassOrigin; // in memory only: user = editable
    Title: string;         // default window title ('' = use Name)
    Shell: string;         // local: shell to launch ('' = config shell)
    Cmd: string;           // command on open (local or remote ssh)
    Cwd: string;           // working directory
    Host: string;          // structured ssh
    User: string;
    Port: integer;
    KeyFile: string;
    Password: string;      // stored in the INI as base64
    Connect: string;       // free-command connection (wins over host)
    PostConnect: string;   // command after connecting
    ScrollBack: integer;
    // preferred size, in cells, of a window opened from this class.
    // 0 = automatic: the global default, or two thirds of the desktop when
    // that is unset too. The window frame adds one cell on each side.
    Cols, Rows: integer;
  end;
  TWindowClassArray = array of TWindowClass;

function DefaultWindowClass: TWindowClass;

// the SINGLE predicate for legacy [t-*] sections: shared by the reader
// and the writer; if they diverged, the writer could erase foreign ones
function IsLegacyTermSection(const Sec: string): boolean;

// loads [class.*] and the legacy [t-*] from a file; derives Kind
procedure LoadWindowClasses(const FileName: string; AOrigin: TWClassOrigin;
  out AClasses: TWindowClassArray);

// merge by name (case-insensitive); Target wins on collision
procedure MergeWindowClasses(var Target: TWindowClassArray;
  const Extra: TWindowClassArray);

// finds a class by name (case-insensitive); -1 if not present
function FindClassByName(const A: TWindowClassArray;
  const AName: string): integer;

// writes the user-origin classes to FileName atomically,
// preserving foreign sections; absorbs legacy [t-*] on save
procedure SaveWindowClasses(const FileName: string;
  const AClasses: TWindowClassArray);

// structured argv for ssh (wcSSH); with sshpass if there is a password
procedure BuildWindowClassExec(const C: TWindowClass; out ProgramName: string;
  Args: TStringList; out Secret: string; const CommandOverride: string = '');

// effective command for wcLocal/wcCommand combining class and pane
// overrides according to the unified semantics:
//   wcCommand -> connection + post via stdin (pipe)
//   wcLocal   -> cmd (+post via stdin); post only -> post; exec shell
function ComposePaneCommand(const C: TWindowClass;
  const PaneCmd, PanePost, PaneConnect, AShell: string;
  ALoginShell: boolean): string;

// delivers the post-connect command via the connection's standard input
function WizardCommand(const AConnect, APostConnect: string): string;

// runs a command and then leaves an interactive shell on the same PTY
function CommandWithInteractiveShell(const Command, AShell: string;
  LoginShell: boolean): string;

implementation

uses
  base64;

function DefaultWindowClass: TWindowClass;
begin
  Result := Default(TWindowClass);
  Result.Enabled := True;
  Result.Kind := wcLocal;
  Result.Origin := coUser;
  Result.ScrollBack := DEFAULT_SCROLLBACK;
end;

function IsLegacyTermSection(const Sec: string): boolean;
begin
  // historical: any section starting with 't' except [template.*];
  // the new [class.*]/[profile.*] and config ones do not start with 't'
  Result := (Sec <> '') and (Sec[1] = 't') and
    (LowerCase(Copy(Sec, 1, Length('template.'))) <> 'template.');
end;

// TIniFile strips one pair of outer quotes on read: wrap with another
// identical layer when the value starts and ends with the same quote
function IniQuoteGuard(const S: string): string;
begin
  Result := S;
  if (Length(S) >= 2) and (S[1] in ['''', '"']) and
     (S[Length(S)] = S[1]) then
    Result := S[1] + S + S[1];
end;

function DeriveKind(const C: TWindowClass): TWClassKind;
begin
  if C.Connect <> '' then
    Result := wcCommand
  else if C.Host <> '' then
    Result := wcSSH
  else
    Result := wcLocal;
end;

function ParseBoolStr(const V: string; Def: boolean): boolean;
begin
  if V = '' then
    Result := Def
  else
    Result := SameText(V, '1') or SameText(V, 'true') or
      SameText(V, 'yes') or SameText(V, 'on');
end;

procedure LoadWindowClasses(const FileName: string; AOrigin: TWClassOrigin;
  out AClasses: TWindowClassArray);
var
  Ini: TIniFile;
  SL: TStringList;
  i: integer;
  Sec, S: string;
  C: TWindowClass;
  IsClass: boolean;
begin
  AClasses := nil;
  if not FileExists(FileName) then
    Exit;
  Ini := TIniFile.Create(FileName);
  SL := TStringList.Create;
  try
    Ini.ReadSections(SL);
    for i := 0 to SL.Count - 1 do
    begin
      Sec := SL[i];
      IsClass := LowerCase(Copy(Sec, 1, Length('class.'))) = 'class.';
      if not (IsClass or IsLegacyTermSection(Sec)) then
        continue;
      C := DefaultWindowClass;
      C.Origin := AOrigin;
      if IsClass then
        C.Name := Ini.ReadString(Sec, 'name', Copy(Sec, Length('class.') + 1,
          MaxInt))
      else
        C.Name := Ini.ReadString(Sec, 'name', Copy(Sec, 2, MaxInt));
      if Trim(C.Name) = '' then
        continue;
      C.Enabled := ParseBoolStr(Ini.ReadString(Sec, 'enabled', '1'), True);
      C.Title := Ini.ReadString(Sec, 'title', '');
      C.Shell := Ini.ReadString(Sec, 'shell', '');
      C.Cmd := Ini.ReadString(Sec, 'cmd', '');
      C.Cwd := Ini.ReadString(Sec, 'cwd', '');
      C.Host := Ini.ReadString(Sec, 'host', '');
      C.User := Ini.ReadString(Sec, 'user', '');
      C.Port := Ini.ReadInteger(Sec, 'port', 0);
      C.KeyFile := Ini.ReadString(Sec, 'key', '');
      C.Connect := Ini.ReadString(Sec, 'connect', '');
      C.PostConnect := Ini.ReadString(Sec, 'postconnect', '');
      C.ScrollBack := Ini.ReadInteger(Sec, 'scrollback', DEFAULT_SCROLLBACK);
      if C.ScrollBack < 0 then
        C.ScrollBack := 0;
      if C.ScrollBack > MAX_SCROLLBACK then
        C.ScrollBack := MAX_SCROLLBACK;
      C.Cols := Ini.ReadInteger(Sec, 'cols', 0);
      if (C.Cols < 0) or (C.Cols > MAX_WIN_COLS) then
        C.Cols := 0;
      C.Rows := Ini.ReadInteger(Sec, 'rows', 0);
      if (C.Rows < 0) or (C.Rows > MAX_WIN_ROWS) then
        C.Rows := 0;
      S := Ini.ReadString(Sec, 'password', '');
      if S <> '' then
      begin
        try
          C.Password := DecodeStringBase64(S);
        except
          C.Password := S;   // not encoded
        end;
      end;
      C.Kind := DeriveKind(C);
      SetLength(AClasses, Length(AClasses) + 1);
      AClasses[High(AClasses)] := C;
    end;
  finally
    SL.Free;
    Ini.Free;
  end;
end;

function FindClassByName(const A: TWindowClassArray; const AName: string): integer;
var
  i: integer;
begin
  Result := -1;
  for i := 0 to High(A) do
    if SameText(A[i].Name, AName) then
      Exit(i);
end;

procedure MergeWindowClasses(var Target: TWindowClassArray;
  const Extra: TWindowClassArray);
var
  i: integer;
begin
  for i := 0 to High(Extra) do
    if FindClassByName(Target, Extra[i].Name) < 0 then
    begin
      SetLength(Target, Length(Target) + 1);
      Target[High(Target)] := Extra[i];
    end;
end;

procedure SaveWindowClasses(const FileName: string;
  const AClasses: TWindowClassArray);
var
  Ini: TIniFile;
  SL: TStringList;
  i: integer;
  Sec, TempName: string;
begin
  TempName := FileName + '.tmp.' + IntToStr(OsGetPid);
  if FileExists(TempName) then
    DeleteFile(TempName);
  // copy of the current content to preserve foreign sections
  SL := TStringList.Create;
  try
    if FileExists(FileName) then
      SL.LoadFromFile(FileName);
    SL.SaveToFile(TempName);
  finally
    SL.Free;
  end;
  Ini := TIniFile.Create(TempName);
  SL := TStringList.Create;
  try
    // erase everything of ours: [class.*] and the legacy [t-*]
    // (so the first save absorbs and migrates the user's [t-*])
    Ini.ReadSections(SL);
    for i := 0 to SL.Count - 1 do
      if IsLegacyTermSection(SL[i]) or
         (LowerCase(Copy(SL[i], 1, Length('class.'))) = 'class.') then
        Ini.EraseSection(SL[i]);
    for i := 0 to High(AClasses) do
    begin
      if AClasses[i].Origin <> coUser then
        continue;
      Sec := 'class.' + AClasses[i].Name;
      Ini.WriteString(Sec, 'name', AClasses[i].Name);
      Ini.WriteInteger(Sec, 'enabled', Ord(AClasses[i].Enabled));
      if AClasses[i].Title <> '' then
        Ini.WriteString(Sec, 'title', IniQuoteGuard(AClasses[i].Title));
      if AClasses[i].Shell <> '' then
        Ini.WriteString(Sec, 'shell', AClasses[i].Shell);
      if AClasses[i].Cmd <> '' then
        Ini.WriteString(Sec, 'cmd', IniQuoteGuard(AClasses[i].Cmd));
      if AClasses[i].Cwd <> '' then
        Ini.WriteString(Sec, 'cwd', IniQuoteGuard(AClasses[i].Cwd));
      if AClasses[i].Host <> '' then
        Ini.WriteString(Sec, 'host', AClasses[i].Host);
      if AClasses[i].User <> '' then
        Ini.WriteString(Sec, 'user', AClasses[i].User);
      if AClasses[i].Port > 0 then
        Ini.WriteInteger(Sec, 'port', AClasses[i].Port);
      if AClasses[i].KeyFile <> '' then
        Ini.WriteString(Sec, 'key', AClasses[i].KeyFile);
      if AClasses[i].Password <> '' then
        Ini.WriteString(Sec, 'password',
          EncodeStringBase64(AClasses[i].Password));
      if AClasses[i].Connect <> '' then
        Ini.WriteString(Sec, 'connect', IniQuoteGuard(AClasses[i].Connect));
      if AClasses[i].PostConnect <> '' then
        Ini.WriteString(Sec, 'postconnect',
          IniQuoteGuard(AClasses[i].PostConnect));
      if (AClasses[i].ScrollBack > 0) and
         (AClasses[i].ScrollBack <> DEFAULT_SCROLLBACK) then
        Ini.WriteInteger(Sec, 'scrollback', AClasses[i].ScrollBack);
      if AClasses[i].Cols > 0 then
        Ini.WriteInteger(Sec, 'cols', AClasses[i].Cols);
      if AClasses[i].Rows > 0 then
        Ini.WriteInteger(Sec, 'rows', AClasses[i].Rows);
    end;
    Ini.UpdateFile;
    // the file may contain passwords
    OsRestrictFile(TempName);
  finally
    SL.Free;
    Ini.Free;
  end;
  if not RenameFile(TempName, FileName) then
    DeleteFile(TempName);
end;

procedure BuildWindowClassExec(const C: TWindowClass; out ProgramName: string;
  Args: TStringList; out Secret: string; const CommandOverride: string);
var
  Target, Path, Item: string;
  Start, Sep: integer;
  HaveSshPass: boolean;
begin
  ProgramName := '';
  Secret := '';
  Args.Clear;
  if (not C.Enabled) or (C.Kind <> wcSSH) then
    Exit;
  // The ssh arguments are structured. The remote command is a single
  // argument because the SSH server passes it to its login shell.
  HaveSshPass := False;
  if C.Password <> '' then
  begin
    Secret := C.Password;
    Path := GetEnvironmentVariable('PATH');
    Start := 1;
    while Start <= Length(Path) + 1 do
    begin
      Sep := Pos(':', Path, Start);
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
    // the command sshpass executes: without this 'ssh', sshpass would
    // eat the '-tt' below ("invalid option -- 't'") instead of ssh
    Args.Add('ssh');
  end
  else
  begin
    ProgramName := 'ssh';
    Args.Add('ssh');
  end;
  Args.Add('-tt');
  if C.Port > 0 then
  begin
    Args.Add('-p');
    Args.Add(IntToStr(C.Port));
  end;
  if C.KeyFile <> '' then
  begin
    Args.Add('-i');
    Args.Add(ExpandUserPath(C.KeyFile));
  end;
  Args.Add('-o');
  Args.Add('StrictHostKeyChecking=accept-new');
  if C.User <> '' then
    Target := C.User + '@' + C.Host
  else
    Target := C.Host;
  Args.Add(Target);
  if CommandOverride <> '' then
    Args.Add(CommandOverride)
  else if C.PostConnect <> '' then
    Args.Add(C.PostConnect)
  else if C.Cmd <> '' then
    Args.Add(C.Cmd);
end;

function WizardCommand(const AConnect, APostConnect: string): string;
begin
  Result := Trim(AConnect);
  if Result = '' then
    Exit;
  if Trim(APostConnect) <> '' then
    Result := 'printf ''%s\n'' ' + ShellQuote(Trim(APostConnect)) +
      ' | (' + Result + ')';
end;

function CommandWithInteractiveShell(const Command, AShell: string;
  LoginShell: boolean): string;
var
  Tail, RawTail, ModeArg: string;
begin
  Result := Trim(Command);
  if Result = '' then
    Exit;
  if LoginShell then
    ModeArg := ' -l'
  else
    ModeArg := ' -i';
  Tail := '; exec ' + ShellQuote(AShell) + ModeArg;
  RawTail := '; exec ' + AShell + ModeArg;
  // Old profiles/classes often added their own fallback explicitly. Keep
  // this idempotent so those configurations do not produce two nested
  // shells that require `exit` twice.
  if EndsText(Tail, Result) or EndsText(RawTail, Result) then
    Exit;
  // Run the application in a subshell. A saved launcher may itself start
  // with `exec` (tmux profiles commonly do); without this boundary it
  // replaces the only shell and the pane dies as soon as the application
  // exits. The outer shell always survives to become an interactive prompt.
  Result := '( ' + Result + ' )' + Tail;
end;

function ComposePaneCommand(const C: TWindowClass;
  const PaneCmd, PanePost, PaneConnect, AShell: string;
  ALoginShell: boolean): string;
var
  EffCmd, EffPost, EffConnect: string;
begin
  // the pane fields override the class ones
  EffCmd := PaneCmd;
  if EffCmd = '' then
    EffCmd := C.Cmd;
  EffPost := PanePost;
  if EffPost = '' then
    EffPost := C.PostConnect;
  EffConnect := PaneConnect;
  if EffConnect = '' then
    EffConnect := C.Connect;
  if EffConnect <> '' then
  begin
    // free-command connection: post goes via the connection's stdin
    Result := CommandWithInteractiveShell(
      WizardCommand(EffConnect, EffPost), AShell, ALoginShell);
    Exit;
  end;
  // local
  if EffCmd <> '' then
  begin
    if EffPost <> '' then
      Result := WizardCommand(EffCmd, EffPost)
    else
      Result := EffCmd;
    Result := CommandWithInteractiveShell(Result, AShell, ALoginShell);
    Exit;
  end;
  if EffPost <> '' then
  begin
    // post-connect only: run it and stay in an interactive shell
    // (a pipe to the shell would die when stdin closes)
    Result := CommandWithInteractiveShell(EffPost, AShell, ALoginShell);
    Exit;
  end;
  Result := '';
end;

end.
