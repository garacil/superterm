(*
  Autor: Germán Luis Aracil Boned
  Proyecto: superterm - terminal con autologin, splits y sesiones
  Unidad: st_pty - pseudoterminales (spawn, io, resize, estado)
*)

unit st_pty;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, baseunix, unix, termio, ctypes;

const
  MAXREAD = 65536;

type
  TStringArray = array of string;

  TPty = class
  private
    FMaster: cint;
    FPid: TPid;
    FAlive: boolean;
    FShellBase: string;
    FPendingSecret: RawByteString;
    FPromptBuffer: RawByteString;
    function SpawnInternal(const AProgram: string;
      const AArgs: array of string; const ACwd: string;
      ACols, ARows: integer; const AExtraEnv, ASecret: string): boolean;
  public
    TitleCmd: string;   // comando en curso (para titulo/sesion)
    TitleCwd: string;   // cwd en curso
    TitleArgs: TStringArray;
    destructor Destroy; override;
    property Master: cint read FMaster;
    property Pid: TPid read FPid;
    property Alive: boolean read FAlive write FAlive;
    function Spawn(const AShell, ACwd, ACommand: string; ACols, ARows: integer;
      const AExtraEnv: string = ''; ALoginShell: boolean = True): boolean;
    function SpawnArgv(const AProgram: string; const AArgs: array of string;
      const ACwd: string; ACols, ARows: integer;
      const AExtraEnv: string = ''; const ASecret: string = ''): boolean;
    function ReadBuf(out Buf: array of byte): integer;
    function WriteStr(const S: RawByteString): boolean;
    procedure Resize(ACols, ARows: integer);
    procedure KillPane;
    procedure MarkDead;
    procedure MarkExited;
    procedure QueryState;
  end;

function posix_openpt(flags: cint): cint; cdecl; external 'c' name 'posix_openpt';
function grantpt(fd: cint): cint; cdecl; external 'c' name 'grantpt';
function unlockpt(fd: cint): cint; cdecl; external 'c' name 'unlockpt';
function ptsname(fd: cint): PAnsiChar; cdecl; external 'c' name 'ptsname';

function FindChildProcs(ParentPid: TPid; out Children: array of TPid): integer;
function ProcArgs(Pid: TPid): TStringArray;
function ProcCmdLine(Pid: TPid): string;
function ProcCwd(Pid: TPid): string;

function FirstWordOf(const S: string): string;

implementation

uses
  st_debug, StrUtils;

function FirstWordOf(const S: string): string;
var
  i: integer;
begin
  Result := Trim(S);
  i := Pos(' ', Result);
  if i > 0 then
    Result := Copy(Result, 1, i - 1);
end;

function BuildEnv(const AExtra: string): PPAnsiChar;
var
  L: TStringList;
  i: integer;
  P: PPAnsiChar;
  procedure Add(const N, V: string);
  begin
    if V <> '' then
      L.Add(N + '=' + V);
  end;
begin
  L := TStringList.Create;
  try
    Add('TERM', GetEnvironmentVariable('TERM'));
    if L.Count = 0 then
      L.Add('TERM=xterm-256color');
    Add('COLORTERM', 'truecolor');
    Add('HOME', GetEnvironmentVariable('HOME'));
    Add('USER', GetEnvironmentVariable('USER'));
    Add('LOGNAME', GetEnvironmentVariable('LOGNAME'));
    Add('SHELL', GetEnvironmentVariable('SHELL'));
    Add('PATH', GetEnvironmentVariable('PATH'));
    Add('LANG', GetEnvironmentVariable('LANG'));
    Add('SSH_AUTH_SOCK', GetEnvironmentVariable('SSH_AUTH_SOCK'));
    Add('SSH_AGENT_PID', GetEnvironmentVariable('SSH_AGENT_PID'));
    Add('XDG_RUNTIME_DIR', GetEnvironmentVariable('XDG_RUNTIME_DIR'));
    Add('DISPLAY', GetEnvironmentVariable('DISPLAY'));
    Add('WAYLAND_DISPLAY', GetEnvironmentVariable('WAYLAND_DISPLAY'));
    if AExtra <> '' then
      L.Add(AExtra);
    L.Add('SUPERTERM=1');
    GetMem(P, (L.Count + 1) * SizeOf(Pointer));
    for i := 0 to L.Count - 1 do
      // The list is freed below. Keep independent copies for execve.
      P[i] := StrNew(PChar(L[i]));
    P[L.Count] := nil;
    Result := P;
  finally
    L.Free;
  end;
end;

procedure FreeEnv(P: PPAnsiChar);
var
  I: integer;
begin
  if P = nil then
    Exit;
  I := 0;
  while P[I] <> nil do
  begin
    StrDispose(P[I]);
    Inc(I);
  end;
  FreeMem(P);
end;

procedure FreeArgv(P: PPAnsiChar);
var
  I: integer;
begin
  if P = nil then
    Exit;
  I := 0;
  while P[I] <> nil do
  begin
    StrDispose(P[I]);
    Inc(I);
  end;
  FreeMem(P);
end;

function MakeArgv(const AProgram: string; const AArgs: array of string): PPAnsiChar;
var
  I, N: integer;
begin
  N := Length(AArgs);
  if N = 0 then
    N := 1;
  GetMem(Result, (N + 1) * SizeOf(Pointer));
  if Length(AArgs) = 0 then
    Result[0] := StrNew(PChar(ExtractFileName(AProgram)))
  else
    for I := 0 to Length(AArgs) - 1 do
      Result[I] := StrNew(PChar(AArgs[I]));
  Result[N] := nil;
end;

procedure ChildFail(Fd: cint);
var
  B: byte;
begin
  B := 1;
  if Fd >= 0 then
    FpWrite(Fd, B, 1);
  FpExit(127);
end;

procedure ExecPath(const AProgram: string; Argv, Envp: PPAnsiChar);
var
  Path, Item, Candidate: string;
  Start, Sep: integer;
begin
  if Pos('/', AProgram) > 0 then
  begin
    FpExecVPE(AProgram, Argv, Envp);
    Exit;
  end;
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
    Candidate := IncludeTrailingPathDelimiter(Item) + AProgram;
    FpExecVPE(Candidate, Argv, Envp);
    Start := Sep + 1;
  end;
end;

function TPty.SpawnInternal(const AProgram: string; const AArgs: array of string;
  const ACwd: string; ACols, ARows: integer;
  const AExtraEnv, ASecret: string): boolean;
var
  Mfd: cint;
  SlaveName: string;
  NewPid: TPid;
  ws: TWinSize;
  Argv, Envp: PPAnsiChar;
  PassPipe, ExecPipe: TFildes;
  B: byte;
  N, Left, Offset: integer;
  SecretPtr: PAnsiChar;
  UseSecretPipe: boolean;
begin
  Result := False;
  FAlive := False;
  FMaster := -1;
  FPid := -1;
  FPendingSecret := '';
  FPromptBuffer := '';
  Argv := nil;
  Envp := nil;
  PassPipe[0] := -1;
  PassPipe[1] := -1;
  ExecPipe[0] := -1;
  ExecPipe[1] := -1;

  UseSecretPipe := (ASecret <> '') and
    SameText(ExtractFileName(AProgram), 'sshpass');
  if UseSecretPipe and (FpPipe(PassPipe) <> 0) then
    Exit;
  if FpPipe(ExecPipe) <> 0 then
  begin
    if PassPipe[0] >= 0 then FpClose(PassPipe[0]);
    if PassPipe[1] >= 0 then FpClose(PassPipe[1]);
    Exit;
  end;

  Mfd := posix_openpt(O_RDWR or O_NOCTTY);
  if Mfd < 0 then
  begin
    FpClose(ExecPipe[0]);
    FpClose(ExecPipe[1]);
    if PassPipe[0] >= 0 then FpClose(PassPipe[0]);
    if PassPipe[1] >= 0 then FpClose(PassPipe[1]);
    Exit;
  end;
  // A PTY master must never survive an exec into a pane process.
  FpFcntl(Mfd, 2, 1); // F_SETFD=2, FD_CLOEXEC=1 on GNU/Linux
  if grantpt(Mfd) <> 0 then
  begin
    FpClose(Mfd);
    FpClose(ExecPipe[0]);
    FpClose(ExecPipe[1]);
    if PassPipe[0] >= 0 then FpClose(PassPipe[0]);
    if PassPipe[1] >= 0 then FpClose(PassPipe[1]);
    Exit;
  end;
  if unlockpt(Mfd) <> 0 then
  begin
    FpClose(Mfd);
    FpClose(ExecPipe[0]);
    FpClose(ExecPipe[1]);
    if PassPipe[0] >= 0 then FpClose(PassPipe[0]);
    if PassPipe[1] >= 0 then FpClose(PassPipe[1]);
    Exit;
  end;
  SlaveName := StrPas(ptsname(Mfd));
  if SlaveName = '' then
  begin
    FpClose(Mfd);
    FpClose(ExecPipe[0]);
    FpClose(ExecPipe[1]);
    if PassPipe[0] >= 0 then FpClose(PassPipe[0]);
    if PassPipe[1] >= 0 then FpClose(PassPipe[1]);
    Exit;
  end;

  ws.ws_col := ACols;
  ws.ws_row := ARows;
  ws.ws_xpixel := 0;
  ws.ws_ypixel := 0;
  if FpIOCtl(Mfd, TIOCSWINSZ, @ws) <> 0 then
  begin
    FpClose(Mfd);
    FpClose(ExecPipe[0]);
    FpClose(ExecPipe[1]);
    if PassPipe[0] >= 0 then FpClose(PassPipe[0]);
    if PassPipe[1] >= 0 then FpClose(PassPipe[1]);
    Exit;
  end;

  // The parent waits for this descriptor to close on successful exec.
  FpFcntl(ExecPipe[1], 2, 1);

  NewPid := fpFork;
  if NewPid = 0 then
  begin
    // hijo
    FpClose(ExecPipe[0]);
    if PassPipe[1] >= 0 then
      FpClose(PassPipe[1]);
    // Do not inherit the master in the child before opening the slave.
    FpClose(Mfd);
    if FpSetsid < 0 then
      ChildFail(ExecPipe[1]);
    Mfd := FpOpen(SlaveName, O_RDWR, 0);
    if Mfd < 0 then
      ChildFail(ExecPipe[1]);
    if FpIOCtl(Mfd, TIOCSCTTY, nil) <> 0 then
      ChildFail(ExecPipe[1]);
    if (FpDup2(Mfd, 0) < 0) or (FpDup2(Mfd, 1) < 0) or
       (FpDup2(Mfd, 2) < 0) then
      ChildFail(ExecPipe[1]);
    if Mfd > 2 then
      FpClose(Mfd);
    if PassPipe[0] >= 0 then
    begin
      if FpDup2(PassPipe[0], 3) < 0 then
        ChildFail(ExecPipe[1]);
      if PassPipe[0] <> 3 then
        FpClose(PassPipe[0]);
    end;
    if ACwd <> '' then
      if FpChdir(ACwd) <> 0 then
        ChildFail(ExecPipe[1]);

    Argv := MakeArgv(AProgram, AArgs);
    Envp := BuildEnv(AExtraEnv);
    ExecPath(AProgram, Argv, Envp);
    // If any exec attempt returned, report failure to the parent.
    ChildFail(ExecPipe[1]);
  end;

  if NewPid < 0 then
  begin
    FpClose(Mfd);
    FpClose(ExecPipe[0]);
    FpClose(ExecPipe[1]);
    if PassPipe[0] >= 0 then FpClose(PassPipe[0]);
    if PassPipe[1] >= 0 then FpClose(PassPipe[1]);
    Exit;
  end;

  FpClose(ExecPipe[1]);
  if PassPipe[0] >= 0 then
    FpClose(PassPipe[0]);
  if UseSecretPipe then
  begin
    SecretPtr := PAnsiChar(ASecret);
    Offset := 0;
    Left := Length(ASecret);
    while Left > 0 do
    begin
      N := FpWrite(PassPipe[1], SecretPtr + Offset, Left);
      if N > 0 then
      begin
        Inc(Offset, N);
        Dec(Left, N);
      end
      else if fpgeterrno <> ESysEINTR then
        Break;
    end;
    FpClose(PassPipe[1]);
  end;

  // A byte means setup/exec failed; EOF means the close-on-exec handshake
  // succeeded and the new process owns the slave terminal.
  N := FpRead(ExecPipe[0], B, 1);
  FpClose(ExecPipe[0]);
  if N > 0 then
  begin
    FpWaitPid(NewPid, N, 0);
    FpClose(Mfd);
    Exit;
  end;

  FMaster := Mfd;
  FPid := NewPid;
  FAlive := True;
  FShellBase := ExtractFileName(AProgram);
  if (ASecret <> '') and (not UseSecretPipe) then
    FPendingSecret := ASecret;
  Result := True;
  DebugLog(Format('spawn ok master=%d pid=%d program=%s cwd=%s', [Mfd, NewPid, AProgram, ACwd]));
end;

destructor TPty.Destroy;
begin
  KillPane;
  inherited Destroy;
end;

function TPty.Spawn(const AShell, ACwd, ACommand: string; ACols, ARows: integer;
  const AExtraEnv: string; ALoginShell: boolean): boolean;
var
  Base, Dash0, Script: string;
  Args: TStringArray;
begin
  Base := ExtractFileName(AShell);
  if ACommand = '' then
  begin
    if (not ALoginShell) then
      Dash0 := Base
    else if Copy(Base, 1, 1) = '-' then
      Dash0 := Base
    else
      Dash0 := '-' + Base;
    Result := SpawnInternal(AShell, [Dash0], ACwd, ACols, ARows,
      AExtraEnv, '');
  end
  else
  begin
    // Run the configured script as-is. Prefixing it with exec breaks valid
    // scripts such as "printf ...; exec $SHELL" and fallback terminals.
    Script := ACommand;
    if ALoginShell then
    begin
      SetLength(Args, 4);
      Args[0] := Base;
      Args[1] := '-l';
      Args[2] := '-c';
      Args[3] := Script;
    end
    else
    begin
      SetLength(Args, 3);
      Args[0] := Base;
      Args[1] := '-c';
      Args[2] := Script;
    end;
    Result := SpawnInternal(AShell, Args, ACwd, ACols, ARows,
      AExtraEnv, '');
  end;
end;

function TPty.SpawnArgv(const AProgram: string; const AArgs: array of string;
  const ACwd: string; ACols, ARows: integer;
  const AExtraEnv: string; const ASecret: string): boolean;
begin
  Result := SpawnInternal(AProgram, AArgs, ACwd, ACols, ARows,
    AExtraEnv, ASecret);
end;

function TPty.ReadBuf(out Buf: array of byte): integer;
var
  S: RawByteString;
  Lower, Tail: string;
  Keep, Start: integer;
begin
  Result := FpRead(FMaster, Buf[0], Length(Buf));
  if (Result > 0) and (FPendingSecret <> '') then
  begin
    SetString(S, PAnsiChar(@Buf[0]), Result);
    FPromptBuffer := FPromptBuffer + S;
    Keep := Length(FPromptBuffer) - 256;
    if Keep > 0 then
      Delete(FPromptBuffer, 1, Keep);
    Lower := LowerCase(FPromptBuffer);
    Start := LastDelimiter(#10#13, Lower);
    if Start > 0 then
      Tail := Trim(Copy(Lower, Start + 1, MaxInt))
    else
      Tail := Trim(Lower);
    if (Length(Tail) <= 128) and
       ((RightStr(Tail, 9) = 'password:') or
        ((Pos('passphrase for', Tail) > 0) and
         (Length(Tail) > 0) and (Tail[Length(Tail)] = ':'))) then
    begin
      // ssh reads the secret from the terminal; keep it out of argv/env.
      WriteStr(FPendingSecret + #13);
      FPendingSecret := '';
      FPromptBuffer := '';
    end;
  end;
end;

function TPty.WriteStr(const S: RawByteString): boolean;
var
  N, Left, Offset: integer;
begin
  Result := False;
  if (FMaster < 0) or (S = '') then
    Exit;
  Left := Length(S);
  Offset := 0;
  while Left > 0 do
  begin
    N := FpWrite(FMaster, PAnsiChar(S) + Offset, Left);
    if N > 0 then
    begin
      Inc(Offset, N);
      Dec(Left, N);
    end
    else if fpgeterrno <> ESysEINTR then
      Exit;
  end;
  Result := True;
end;

procedure TPty.Resize(ACols, ARows: integer);
var
  ws: TWinSize;
begin
  if FMaster < 0 then
    Exit;
  ws.ws_col := ACols;
  ws.ws_row := ARows;
  ws.ws_xpixel := 0;
  ws.ws_ypixel := 0;
  FpIOCtl(FMaster, TIOCSWINSZ, @ws);
  DebugLog(Format('resize master=%d cols=%d rows=%d', [FMaster, ACols, ARows]));
end;

procedure TPty.KillPane;
var
  st: cint;
  ChildPid: TPid;
  I: integer;
begin
  if FMaster >= 0 then
  begin
    FpClose(FMaster);
    FMaster := -1;
  end;
  if FPid > 0 then
  begin
    ChildPid := FPid;
    // Spawned children are session leaders and therefore process-group
    // leaders. Signal the whole group so ssh/shell descendants do not leak.
    fpkill(-ChildPid, SIGHUP);
    fpkill(-ChildPid, SIGTERM);
    for I := 1 to 50 do
    begin
      if fpWaitPid(ChildPid, st, WNOHANG) = ChildPid then
        Break;
      Sleep(1);
    end;
    if fpWaitPid(ChildPid, st, WNOHANG) = 0 then
    begin
      fpkill(-ChildPid, SIGKILL);
      fpWaitPid(ChildPid, st, 0);
    end;
    FPid := -1;
  end;
  FAlive := False;
  FPendingSecret := '';
  FPromptBuffer := '';
end;

procedure TPty.MarkExited;
begin
  if FPid > 0 then
  begin
    // The leader has exited, but jobs in its process group may remain.
    fpkill(-FPid, SIGHUP);
    fpkill(-FPid, SIGTERM);
  end;
  if FMaster >= 0 then
  begin
    FpClose(FMaster);
    FMaster := -1;
  end;
  FAlive := False;
  FPid := -1;
  FPendingSecret := '';
  FPromptBuffer := '';
end;

procedure TPty.MarkDead;
begin
  if FMaster >= 0 then
  begin
    FpClose(FMaster);
    FMaster := -1;
  end;
  FAlive := False;
  FPendingSecret := '';
  FPromptBuffer := '';
end;

function IsNumeric(const S: string): boolean;
var
  i: integer;
begin
  Result := S <> '';
  for i := 1 to Length(S) do
    if not (S[i] in ['0'..'9']) then
      Exit(False);
end;

function FindChildProcs(ParentPid: TPid; out Children: array of TPid): integer;
var
  SR: TSearchRec;
  f: Text;
  line: string;
  parts: TStringList;
  ppid: TPid;
begin
  Result := 0;
  if FindFirst('/proc/*', faDirectory, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') or (not IsNumeric(SR.Name)) then
        continue;
      AssignFile(f, '/proc/' + SR.Name + '/stat');
      {$push}{$I-}
      Reset(f);
      {$pop}
      if IOResult <> 0 then
        continue;
      ReadLn(f, line);
      CloseFile(f);
      line := Copy(line, Pos(')', line) + 2, MaxInt);
      parts := TStringList.Create;
      try
        parts.Delimiter := ' ';
        parts.StrictDelimiter := True;
        parts.DelimitedText := line;
        if parts.Count >= 2 then
        begin
          ppid := StrToIntDef(parts[1], 0);
          if ppid = ParentPid then
          begin
            if Result < Length(Children) then
            begin
              Children[Result] := StrToIntDef(SR.Name, 0);
              Inc(Result);
            end;
          end;
        end;
      finally
        parts.Free;
      end;
    until FindNext(SR) <> 0;
  end;
  FindClose(SR);
end;

function ProcArgs(Pid: TPid): TStringArray;
var
  f: file of byte;
  buf: array[0..4095] of byte;
  n, i, Start: integer;
  sl: RawByteString;
begin
  Result := nil;
  if Pid <= 0 then
    Exit;
  AssignFile(f, '/proc/' + IntToStr(Pid) + '/cmdline');
  {$push}{$I-}
  Reset(f);
  {$pop}
  if IOResult <> 0 then
    Exit;
  n := 0;
  BlockRead(f, buf, SizeOf(buf), n);
  CloseFile(f);
  if n <= 0 then
    Exit;
  SetString(sl, PAnsiChar(@buf[0]), n);
  Start := 1;
  for i := 1 to Length(sl) do
    if sl[i] = #0 then
    begin
      SetLength(Result, Length(Result) + 1);
      SetString(Result[High(Result)], PAnsiChar(@sl[Start]), i - Start);
      Start := i + 1;
    end;
  if Start <= Length(sl) then
  begin
    SetLength(Result, Length(Result) + 1);
    SetString(Result[High(Result)], PAnsiChar(@sl[Start]),
      Length(sl) - Start + 1);
  end;
end;

function ProcCmdLine(Pid: TPid): string;
var
  Args: TStringArray;
  I: integer;
begin
  Result := '';
  Args := ProcArgs(Pid);
  for I := 0 to High(Args) do
  begin
    if I > 0 then
      Result := Result + ' ';
    Result := Result + Args[I];
  end;
end;

function ProcCwd(Pid: TPid): string;
var
  link: string;
  buf: array[0..1023] of char;
  n: longint;
begin
  Result := '';
  if Pid <= 0 then
    Exit;
  link := '/proc/' + IntToStr(Pid) + '/cwd';
  FillChar(buf, SizeOf(buf), 0);
  n := fpReadLink(PAnsiChar(link), buf, SizeOf(buf) - 1);
  if n > 0 then
  begin
    buf[n] := #0;
    Result := StrPas(buf);
  end;
end;

procedure TPty.QueryState;
var
  Kids: array[0..15] of TPid;
  n, i: integer;
  best: TPid;
  cmdline: string;
  base: string;
  Args: TStringArray;
begin
  if (not FAlive) or (FPid <= 0) then
    Exit;
  best := 0;
  n := FindChildProcs(FPid, Kids);
  for i := 0 to n - 1 do
    if Kids[i] > best then
      best := Kids[i];
  if best > 0 then
  begin
    Args := ProcArgs(best);
    cmdline := ProcCmdLine(best);
    TitleCwd := ProcCwd(best);
  end
  else
  begin
    Args := ProcArgs(FPid);
    cmdline := ProcCmdLine(FPid);
    TitleCwd := ProcCwd(FPid);
  end;
  // si el "comando" es la propia shell de login, guardar vacio
  base := FirstWordOf(cmdline);
  if (base <> '') and (base[1] = '-') then
    Delete(base, 1, 1);
  if (base = '') or SameText(base, FShellBase) then
  begin
    TitleCmd := '';
    TitleArgs := nil;
  end
  else
  begin
    TitleCmd := cmdline;
    TitleArgs := Args;
  end;
end;

end.
