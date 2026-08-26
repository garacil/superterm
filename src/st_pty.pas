(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_pty - pseudoterminals (spawn, io, resize, state)
*)

unit st_pty;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, baseunix, unix, termio, ctypes;

const
  MAXREAD = 65536;

const
  // More than this waiting for one pane's program means the program is not
  // reading at all; refuse rather than grow without bound.
  PENDING_INPUT_MAX = 1 shl 20;
  PTY_WRITE_BUDGET = 256 * 1024;

type
  TStringArray = array of string;
  TConfiguredLaunchKind = (clkNone, clkShell, clkArgv);

  TPty = class
  private
    FMaster: cint;
    FPid: TPid;
    FPidIdentity: string;
    FPendingInput: RawByteString;
    FAlive: boolean;
    FShellBase: string;
    FPendingSecret: RawByteString;
    FPromptBuffer: RawByteString;
    FLaunchKind: TConfiguredLaunchKind;
    FLaunchProgram: string;
    FLaunchArgs: TStringArray;
    FLaunchShell: string;
    FLaunchCommand: string;
    FLaunchCwd: string;
    FLaunchExtraEnv: string;
    FLaunchSecret: string;
    FLaunchCols, FLaunchRows: integer;
    FLaunchLoginShell: boolean;
    FFallbackShell: string;
    FFallbackCommand: string;
    FFallbackCwd: string;
    FFallbackLoginShell: boolean;
    FLaunchPending: boolean;
    function SpawnInternal(const AProgram: string;
      const AArgs: array of string; const ACwd: string;
      ACols, ARows: integer; const AExtraEnv, ASecret: string): boolean;
  public
    TitleCmd: string;   // command in progress (for title/session)
    TitleCwd: string;   // current cwd
    TitleArgs: TStringArray;
    constructor Create;
    destructor Destroy; override;
    property Master: cint read FMaster;
    property Pid: TPid read FPid;
    property Alive: boolean read FAlive write FAlive;
    property LaunchPending: boolean read FLaunchPending;
    function Spawn(const AShell, ACwd, ACommand: string; ACols, ARows: integer;
      const AExtraEnv: string = ''; ALoginShell: boolean = True): boolean;
    function SpawnArgv(const AProgram: string; const AArgs: array of string;
      const ACwd: string; ACols, ARows: integer;
      const AExtraEnv: string = ''; const ASecret: string = ''): boolean;
    // A server-first workspace records an exact launch without forking in the
    // UI.  After StartDetachedServer's grandchild owns this TPty object, it
    // executes the same launch and consequently becomes the pane's real OS
    // parent and sole waitpid owner.
    procedure ConfigureShell(const AShell, ACwd, ACommand: string;
      ACols, ARows: integer; const AExtraEnv: string;
      ALoginShell: boolean; const AFallbackShell, AFallbackCwd,
      AFallbackCommand: string; AFallbackLoginShell: boolean);
    procedure ConfigureArgv(const AProgram: string;
      const AArgs: array of string; const ACwd: string;
      ACols, ARows: integer; const AExtraEnv, ASecret: string;
      const AFallbackShell, AFallbackCwd, AFallbackCommand: string;
      AFallbackLoginShell: boolean);
    function SpawnConfigured(out AUsedFallback: boolean): boolean;
    function ReadBuf(out Buf: array of byte): integer;
    function WriteStr(const S: RawByteString): boolean;
    // push queued input toward the pane; safe to call at any time
    procedure FlushInput;
    function InputPending: boolean;
    procedure Resize(ACols, ARows: integer);
    procedure KillPane;
    // Session-daemon close path: signal and retire without waiting in the
    // sole socket reactor. The returned direct-child PID is reaped later by
    // the daemon's non-blocking child collector.
    function TerminateNoWait: TPid;
    // Observe a direct child's exit with waitid(WNOWAIT), seal its process
    // group while the leader PID is still reserved, then let the caller reap.
    function ExitPendingNoReap(out AChildPid: TPid): boolean;
    // releases the PTY without touching the child: the process becomes
    // property of the session daemon (the parent closes its master copy)
    procedure Abandon;
    // PTY EOF invalidates the process-group identity immediately.
    procedure MarkDead;
    // The daemon reaped one of its own pane leaders. Keep the master open so
    // buffered output reaches the screen before EOF, but retire the PID now.
    procedure MarkReaped;
    procedure MarkExited;
    procedure QueryState;
  end;

{$IFDEF DARWIN}
{ Darwin/BSD PTY: a single openpty() hands back both master and slave, and
  login_tty() wires the slave as the child's controlling terminal. The SysV
  posix_openpt/grantpt/unlockpt/ptsname sequence used on Linux fails to spawn
  on macOS, so it is compiled out here. Both live in libc (util.h). }
function openpty(amaster, aslave: pcint; name: PAnsiChar;
  termp, winp: pointer): cint; cdecl; external 'c' name 'openpty';
function login_tty(fd: cint): cint; cdecl; external 'c' name 'login_tty';
{$ELSE}
function posix_openpt(flags: cint): cint; cdecl; external 'c' name 'posix_openpt';
function grantpt(fd: cint): cint; cdecl; external 'c' name 'grantpt';
function unlockpt(fd: cint): cint; cdecl; external 'c' name 'unlockpt';
function ptsname(fd: cint): PAnsiChar; cdecl; external 'c' name 'ptsname';
{$ENDIF}

// Identity of the session the panes belong to, handed to every pane as
// SUPERTERM_SESSION_CHAIN = <ancestors>:<this>. Generated once, before the
// first spawn; the daemon is a fork of the client, so both use one value and
// panes spawned later by the daemon carry the same id. A superterm started
// inside a pane reads the chain and refuses to attach to any session on it:
// attaching to an ancestor is the mirror that never ends, at any depth.
function PaneSessionId: string;
function PaneSessionChain: string;

function FindChildProcs(ParentPid: TPid; out Children: array of TPid): integer;
function ProcArgs(Pid: TPid): TStringArray;
function ProcCmdLine(Pid: TPid): string;
function ProcCwd(Pid: TPid): string;
// Kernel-issued process birth identity.  A numeric PID alone is never safe
// to retain after the process may have exited and been recycled.
function ProcBirthIdentity(Pid: TPid): string;

function FirstWordOf(const S: string): string;

implementation

uses
  st_debug, StrUtils
  {$IFDEF LINUX}, PThreads, SysCall{$ENDIF};

const
  PTY_EXEC_POLL_MS = 100;
  PTY_EXEC_WAIT_POLLS = 50;
  PTY_REAP_POLL_MS = 10;
  PTY_REAP_ATTEMPTS = 200;

{$IFDEF DARWIN}
const
  ST_WAITID_WNOWAIT = $00000020;
{$ELSE}
const
  ST_WAITID_WNOWAIT = $01000000;
{$ENDIF}

const
  ST_WAITID_P_PID = 1;
  ST_WAITID_WEXITED = $00000004;

function cwaitid(AIdType: cint; AId: cuint; AInfo: pointer;
  AOptions: cint): cint; cdecl; external 'c' name 'waitid';

{$IFDEF LINUX}
type
  // Linux BaseUnix.TSigSet is the compact kernel syscall mask, whereas
  // pthread_sigmask/sigpending use libc's 1024-bit sigset_t. Use the exact
  // public type shipped by FPC's pthreads unit instead of guessing its ABI.
  TThreadSignalSet = PThreads.TSigSet;
{$ELSE}
type
  // Darwin BaseUnix exposes the public libc sigset_t directly.
  TThreadSignalSet = BaseUnix.TSigSet;
{$ENDIF}

function c_pthread_sigmask(AHow: cint; ANewSet, AOldSet: pointer): cint;
  cdecl; external 'c' name 'pthread_sigmask';
function c_sigemptyset(ASet: pointer): cint;
  cdecl; external 'c' name 'sigemptyset';
function c_sigaddset(ASet: pointer; ASignal: cint): cint;
  cdecl; external 'c' name 'sigaddset';
function c_sigpending(ASet: pointer): cint;
  cdecl; external 'c' name 'sigpending';
function c_sigismember(ASet: pointer; ASignal: cint): cint;
  cdecl; external 'c' name 'sigismember';
function c_sigwait(ASet: pointer; ASignal: pcint): cint;
  cdecl; external 'c' name 'sigwait';

function PipeWriteNoSigPipe(AFd: cint; ABuffer: pointer; ACount: TSize;
  out AError: cint): TSsize;
var
  BlockSet, OldSet, PendingSet: TThreadSignalSet;
  PendingBefore, PendingAfter: boolean;
  ReceivedSignal: cint;
begin
  Result := -1;
  AError := ESysEINVAL;
  BlockSet := Default(TThreadSignalSet);
  OldSet := Default(TThreadSignalSet);
  if (c_sigemptyset(@BlockSet) <> 0) or
     (c_sigaddset(@BlockSet, SIGPIPE) <> 0) then
    Exit;
  // Blocking only in this calling thread makes the individual pipe write
  // safe without changing SIGPIPE handling for the UI, reactor or workers.
  // pthread_sigmask returns an error number directly and does not use errno.
  if c_pthread_sigmask(SIG_BLOCK, @BlockSet, @OldSet) <> 0 then
    Exit;
  PendingSet := Default(TThreadSignalSet);
  PendingBefore := (c_sigpending(@PendingSet) = 0) and
    (c_sigismember(@PendingSet, SIGPIPE) = 1);
  Result := FpWrite(AFd, ABuffer, ACount);
  if Result < 0 then
    AError := FpGetErrNo
  else
    AError := 0;
  // POSIX queues SIGPIPE to the thread which performed a failed write. If
  // this call introduced it, consume precisely that pending signal before
  // restoring the old mask. Never consume a SIGPIPE which was already
  // pending on entry.
  if (Result < 0) and (AError = ESysEPIPE) and (not PendingBefore) then
  begin
    PendingSet := Default(TThreadSignalSet);
    PendingAfter := (c_sigpending(@PendingSet) = 0) and
      (c_sigismember(@PendingSet, SIGPIPE) = 1);
    if PendingAfter then
    begin
      ReceivedSignal := 0;
      c_sigwait(@BlockSet, @ReceivedSignal);
    end;
  end;
  c_pthread_sigmask(SIG_SETMASK, @OldSet, nil);
end;

function FirstWordOf(const S: string): string;
var
  i: integer;
begin
  Result := Trim(S);
  i := Pos(' ', Result);
  if i > 0 then
    Result := Copy(Result, 1, i - 1);
end;

var
  SessionIdCache: string = '';

function PaneSessionId: string;
begin
  if SessionIdCache = '' then
    SessionIdCache := IntToHex(fpGetPid, 8) + '-' +
      IntToHex(GetTickCount64 and $FFFFFFFFFFFF, 12);
  Result := SessionIdCache;
end;

function PaneSessionChain: string;
var
  Above: string;
begin
  Result := PaneSessionId;
  Above := GetEnvironmentVariable('SUPERTERM_SESSION_CHAIN');
  if (Above <> '') and (Pos(Result, Above) = 0) then
    Result := Above + ':' + Result;
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
    // SUPERTERM_INI: a pane's own superterm must read the same system
    // configuration as its parent (and tests can keep a nested client
    // isolated); SUPERTERM_ALLOW_NESTED is deliberately NOT inherited
    Add('SUPERTERM_INI', GetEnvironmentVariable('SUPERTERM_INI'));
    if AExtra <> '' then
      L.Add(AExtra);
    L.Add('SUPERTERM=1');
    L.Add('SUPERTERM_SESSION_CHAIN=' + PaneSessionChain);
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
    FileWrite(Fd, B, 1);
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
{$IFDEF DARWIN}
  Sfd: cint;
{$ELSE}
  SlaveName: string;
{$ENDIF}
  NewPid: TPid;
  ws: TWinSize;
  Argv, Envp: PPAnsiChar;
  PassPipe, ExecPipe: TFildes;
  B: byte;
  N, Left, Offset, Flags, Attempt, WaitAttempts, TestAttempts: integer;
  WriteError: cint;
  WaitStatus: cint;
  Waited: TPid;
  PollItem: TPollFD;
  TestText: string;
  SecretPtr: PAnsiChar;
  UseSecretPipe, SecretWritten: boolean;

  procedure AbortSpawnedChild;
  var
    I: integer;
  begin
    // NewPid remains our unreaped child throughout this procedure, so both
    // its PID and (once setsid succeeds) its PGID are kernel-reserved exact
    // identities.  Signal before waitpid, then retire the master as one
    // failed spawn transaction.
    FpKill(NewPid, SIGKILL);
    FpKill(-NewPid, SIGKILL);
    WaitStatus := 0;
    for I := 1 to PTY_REAP_ATTEMPTS do
    begin
      Waited := FpWaitPid(NewPid, WaitStatus, WNOHANG);
      if Waited = NewPid then
        Break;
      if (Waited < 0) and (FpGetErrNo <> ESysEINTR) then
        Break;
      if I < PTY_REAP_ATTEMPTS then
        Sleep(PTY_REAP_POLL_MS);
    end;
    FpClose(Mfd);
  end;
begin
  // settle the session identity in THIS process before forking: BuildEnv
  // runs in the child, and an id first generated there would die with the
  // exec -- leaving every pane, and the daemon, with a different one
  PaneSessionId;
  Result := False;
  FAlive := False;
  FMaster := -1;
  FPid := -1;
  FPidIdentity := '';
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

  ws.ws_col := ACols;
  ws.ws_row := ARows;
  ws.ws_xpixel := 0;
  ws.ws_ypixel := 0;
{$IFDEF DARWIN}
  // Darwin/BSD: one openpty() call returns both fds and applies the window
  // size. Replaces the SysV posix_openpt/grantpt/unlockpt/ptsname path, which
  // fails to spawn on macOS.
  Mfd := -1;
  Sfd := -1;
  if openpty(@Mfd, @Sfd, nil, nil, @ws) <> 0 then
  begin
    FpClose(ExecPipe[0]);
    FpClose(ExecPipe[1]);
    if PassPipe[0] >= 0 then FpClose(PassPipe[0]);
    if PassPipe[1] >= 0 then FpClose(PassPipe[1]);
    Exit;
  end;
  // A PTY master must never survive an exec into a pane process.
  FpFcntl(Mfd, 2, 1); // F_SETFD=2, FD_CLOEXEC=1
{$ELSE}
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
  if FpIOCtl(Mfd, TIOCSWINSZ, @ws) <> 0 then
  begin
    FpClose(Mfd);
    FpClose(ExecPipe[0]);
    FpClose(ExecPipe[1]);
    if PassPipe[0] >= 0 then FpClose(PassPipe[0]);
    if PassPipe[1] >= 0 then FpClose(PassPipe[1]);
    Exit;
  end;
{$ENDIF}

  // The parent waits for this descriptor to close on successful exec.
  FpFcntl(ExecPipe[1], 2, 1);

  NewPid := fpFork;
  if NewPid = 0 then
  begin
    // child
    FpClose(ExecPipe[0]);
    if PassPipe[1] >= 0 then
      FpClose(PassPipe[1]);
    // Do not inherit the master in the child before setting up the slave.
    FpClose(Mfd);
{$IFDEF DARWIN}
    // login_tty(slave) = setsid + TIOCSCTTY + dup2 slave->0/1/2 (+close slave).
    if login_tty(Sfd) <> 0 then
      ChildFail(ExecPipe[1]);
{$ELSE}
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
{$ENDIF}
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
{$IFDEF DARWIN}
    FpClose(Sfd);
{$ENDIF}
    FpClose(Mfd);
    FpClose(ExecPipe[0]);
    FpClose(ExecPipe[1]);
    if PassPipe[0] >= 0 then FpClose(PassPipe[0]);
    if PassPipe[1] >= 0 then FpClose(PassPipe[1]);
    Exit;
  end;

{$IFDEF DARWIN}
  FpClose(Sfd);   // parent keeps only the master
{$ENDIF}
  FpClose(ExecPipe[1]);
  if PassPipe[0] >= 0 then
    FpClose(PassPipe[0]);

  // A byte means setup/exec failed; EOF means the close-on-exec handshake
  // succeeded and the new process owns the slave terminal. Never perform a
  // blocking read here: this function also runs during daemon publication,
  // and one child stuck before exec must not freeze the session creator.
  Flags := FpFcntl(ExecPipe[0], F_GETFL, 0);
  if (Flags < 0) or
     (FpFcntl(ExecPipe[0], F_SETFL, Flags or O_NONBLOCK) < 0) then
    WaitAttempts := 0
  else
    WaitAttempts := PTY_EXEC_WAIT_POLLS;
  TestText := GetEnvironmentVariable('SUPERTERM_TEST_PTY_EXEC_POLLS');
  if (GetEnvironmentVariable('SUPERTERM_TESTING') = '1') and
     TryStrToInt(TestText, TestAttempts) and (TestAttempts >= 1) and
     (TestAttempts <= WaitAttempts) then
    WaitAttempts := TestAttempts;
  B := 0;
  N := -1;
  for Attempt := 1 to WaitAttempts do
  begin
    N := FileRead(ExecPipe[0], B, 1);
    if N >= 0 then
      Break;
    if (FpGetErrNo <> ESysEINTR) and (FpGetErrNo <> ESysEAGAIN) and
       (FpGetErrNo <> ESysEWOULDBLOCK) then
      Break;
    if FpGetErrNo = ESysEINTR then
      Continue;
    PollItem := Default(TPollFD);
    PollItem.fd := ExecPipe[0];
    PollItem.events := POLLIN;
    FpPoll(@PollItem, 1, PTY_EXEC_POLL_MS);
  end;
  // The last poll may itself have observed the close/byte. Consume that
  // result once before classifying the fixed attempt budget as exhausted.
  if N < 0 then
    N := FileRead(ExecPipe[0], B, 1);
  FpClose(ExecPipe[0]);

  // Do not feed sshpass until the close-on-exec handshake proves that the
  // child reached exec.  Otherwise a pre-exec child which never consumes fd
  // 3 could fill the pipe and block session publication before the bounded
  // handshake even starts.  The write side is non-blocking and has the same
  // fixed no-progress budget as exec; a partial password is never published
  // as a live pane.
  if UseSecretPipe then
  begin
    SecretWritten := False;
    if N = 0 then
    begin
      Flags := FpFcntl(PassPipe[1], F_GETFL, 0);
      if (Flags >= 0) and
         (FpFcntl(PassPipe[1], F_SETFL, Flags or O_NONBLOCK) >= 0) then
      begin
        SecretPtr := PAnsiChar(ASecret);
        Offset := 0;
        Left := Length(ASecret);
        while Left > 0 do
        begin
          N := PipeWriteNoSigPipe(PassPipe[1], SecretPtr + Offset, Left,
            WriteError);
          if N > 0 then
          begin
            Inc(Offset, N);
            Dec(Left, N);
            Continue;
          end;
          if (N < 0) and (WriteError = ESysEINTR) then
            Continue;
          if (N >= 0) or
             ((WriteError <> ESysEAGAIN) and
              (WriteError <> ESysEWOULDBLOCK)) or
             (WaitAttempts <= 0) then
            Break;
          Dec(WaitAttempts);
          PollItem := Default(TPollFD);
          PollItem.fd := PassPipe[1];
          PollItem.events := POLLOUT;
          N := FpPoll(@PollItem, 1, PTY_EXEC_POLL_MS);
          if (N < 0) and (FpGetErrNo <> ESysEINTR) then
            Break;
        end;
        SecretWritten := Left = 0;
      end;
    end;
    FpClose(PassPipe[1]);
    PassPipe[1] := -1;
    if SecretWritten then
      N := 0
    else
      N := -1;
  end;
  if N <> 0 then
  begin
    // Failure byte, hard error, timeout or incomplete password.
    AbortSpawnedChild;
    Exit;
  end;

  // The master must not block. A pane's program that has stopped reading
  // fills the line discipline in a few kilobytes, and a blocking write from
  // the daemon's event loop then freezes every pane and every client of the
  // session until that one program reads again. Both readers already treat
  // EAGAIN as "nothing to read", so this only makes the writers honest.
  N := FpFcntl(Mfd, F_GETFL, 0);
  if N >= 0 then
    FpFcntl(Mfd, F_SETFL, N or O_NONBLOCK);
  FPidIdentity := ProcBirthIdentity(NewPid);
  if (GetEnvironmentVariable('SUPERTERM_TESTING') = '1') and
     (GetEnvironmentVariable('SUPERTERM_TEST_PTY_EMPTY_IDENTITY') = '1') then
    FPidIdentity := '';
  if FPidIdentity = '' then
  begin
    // A numeric PID without its kernel birth generation can never become
    // signalling authority.  The unreaped child is still exact here, so it
    // can be cancelled safely instead of publishing an unverifiable pane.
    AbortSpawnedChild;
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

constructor TPty.Create;
begin
  inherited Create;
  // fd 0 and PID 0 are valid values with special meanings. A configured but
  // not-yet-spawned TPty must therefore establish safe destructor invariants
  // explicitly instead of relying on TObject's zero-filled allocation.
  FMaster := -1;
  FPid := -1;
  FPidIdentity := '';
  FAlive := False;
  FLaunchKind := clkNone;
  FLaunchPending := False;
end;

procedure TPty.ConfigureShell(const AShell, ACwd, ACommand: string;
  ACols, ARows: integer; const AExtraEnv: string; ALoginShell: boolean;
  const AFallbackShell, AFallbackCwd, AFallbackCommand: string;
  AFallbackLoginShell: boolean);
begin
  FLaunchKind := clkShell;
  FLaunchProgram := '';
  FLaunchArgs := nil;
  FLaunchShell := AShell;
  FLaunchCommand := ACommand;
  FLaunchCwd := ACwd;
  FLaunchExtraEnv := AExtraEnv;
  FLaunchSecret := '';
  FLaunchCols := ACols;
  FLaunchRows := ARows;
  FLaunchLoginShell := ALoginShell;
  FFallbackShell := AFallbackShell;
  FFallbackCwd := AFallbackCwd;
  FFallbackCommand := AFallbackCommand;
  FFallbackLoginShell := AFallbackLoginShell;
  FLaunchPending := True;
end;

procedure TPty.ConfigureArgv(const AProgram: string;
  const AArgs: array of string; const ACwd: string; ACols, ARows: integer;
  const AExtraEnv, ASecret: string; const AFallbackShell, AFallbackCwd,
  AFallbackCommand: string; AFallbackLoginShell: boolean);
var
  I: integer;
begin
  FLaunchKind := clkArgv;
  FLaunchProgram := AProgram;
  SetLength(FLaunchArgs, Length(AArgs));
  for I := 0 to High(AArgs) do
    FLaunchArgs[I] := AArgs[I];
  FLaunchShell := '';
  FLaunchCommand := '';
  FLaunchCwd := ACwd;
  FLaunchExtraEnv := AExtraEnv;
  FLaunchSecret := ASecret;
  FLaunchCols := ACols;
  FLaunchRows := ARows;
  FLaunchLoginShell := False;
  FFallbackShell := AFallbackShell;
  FFallbackCwd := AFallbackCwd;
  FFallbackCommand := AFallbackCommand;
  FFallbackLoginShell := AFallbackLoginShell;
  FLaunchPending := True;
end;

function TPty.SpawnConfigured(out AUsedFallback: boolean): boolean;
begin
  AUsedFallback := False;
  if not FLaunchPending then
    Exit(False);
  case FLaunchKind of
    clkShell:
      Result := Spawn(FLaunchShell, FLaunchCwd, FLaunchCommand,
        FLaunchCols, FLaunchRows, FLaunchExtraEnv, FLaunchLoginShell);
    clkArgv:
      Result := SpawnArgv(FLaunchProgram, FLaunchArgs, FLaunchCwd,
        FLaunchCols, FLaunchRows, FLaunchExtraEnv, FLaunchSecret);
  else
    Result := False;
  end;
  if Result then
  begin
    FLaunchPending := False;
    Exit;
  end;
  if FFallbackShell = '' then
    Exit;
  AUsedFallback := True;
  Result := Spawn(FFallbackShell, FFallbackCwd, FFallbackCommand,
    FLaunchCols, FLaunchRows, '', FFallbackLoginShell);
  if Result then
    FLaunchPending := False;
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
  Args := Default(TStringArray);
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
  Result := FileRead(FMaster, Buf[0], Length(Buf));
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

// Feed the pane's program. The master is non-blocking, so a program that has
// stopped reading gives EAGAIN instead of parking the caller for ever; what
// does not fit is held here and pushed out by FlushInput as the program
// drains it. False means the input was refused outright (dead pane, or more
// pending than PENDING_INPUT_MAX), and callers must say so rather than
// reporting success.
function TPty.WriteStr(const S: RawByteString): boolean;
begin
  Result := False;
  if (FMaster < 0) or (S = '') then
    Exit;
  if Length(FPendingInput) + Length(S) > PENDING_INPUT_MAX then
    Exit;
  FPendingInput := FPendingInput + S;
  // Write only what the non-blocking master accepts immediately. The event
  // loop watches POLLOUT while a remainder exists, so input for one stopped
  // program can never delay sockets or the other panes.
  FlushInput;
  Result := True;
end;

// Push whatever is immediately accepted by the non-blocking master. A partial
// write leaves the rest for its next POLLOUT event.
procedure TPty.FlushInput;
var
  N, Want, Total: integer;
begin
  if (FMaster < 0) or (FPendingInput = '') then
    Exit;
  Total := 0;
  repeat
    Want := Length(FPendingInput);
    if Want > PTY_WRITE_BUDGET - Total then
      Want := PTY_WRITE_BUDGET - Total;
    if Want <= 0 then
      Exit;
    N := FpWrite(FMaster, PAnsiChar(FPendingInput), Want);
    if N > 0 then
    begin
      Delete(FPendingInput, 1, N);
      Inc(Total, N);
      if FPendingInput = '' then
        Exit;
      continue;
    end;
    if (N < 0) and (fpgeterrno = ESysEINTR) then
      continue;
    if (N < 0) and (fpgeterrno <> ESysEAGAIN) then
    begin
      FPendingInput := '';        // the pane is gone; drop what is left
      Exit;
    end;
    Exit;                         // not reading: wait for POLLOUT
  until False;
end;

function TPty.InputPending: boolean;
begin
  Result := FPendingInput <> '';
end;

procedure TPty.Resize(ACols, ARows: integer);
var
  ws: TWinSize;
begin
  // A server-first pane is configured before the daemon spawns it.  Window
  // layout may settle again in that interval; keep the pending launch at the
  // same final size as its screen model instead of silently spawning with
  // the provisional rectangle.
  if FLaunchPending then
  begin
    FLaunchCols := ACols;
    FLaunchRows := ARows;
  end;
  if FMaster < 0 then
    Exit;
  ws.ws_col := ACols;
  ws.ws_row := ARows;
  ws.ws_xpixel := 0;
  ws.ws_ypixel := 0;
  FpIOCtl(FMaster, TIOCSWINSZ, @ws);
  DebugLog(Format('resize master=%d cols=%d rows=%d', [FMaster, ACols, ARows]));
end;

function TPty.ExitPendingNoReap(out AChildPid: TPid): boolean;
var
  {$IFDEF DARWIN}
  Info: TSigInfo_t;
  {$ELSE}
  Info: TSigInfo;
  {$ENDIF}
  R, E: integer;
begin
  Result := False;
  AChildPid := FPid;
  if AChildPid <= 0 then
    Exit;
  Info := Default({$IFDEF DARWIN}TSigInfo_t{$ELSE}TSigInfo{$ENDIF});
  repeat
    R := cwaitid(ST_WAITID_P_PID, cuint(AChildPid), @Info,
      ST_WAITID_WEXITED or WNOHANG or ST_WAITID_WNOWAIT);
    if R = 0 then
      Break;
    E := FpGetErrNo;
  until E <> ESysEINTR;
  if R <> 0 then
    Exit;
  // POSIX requires a no-event WNOHANG result to set si_pid to zero. Never use
  // other siginfo bytes as the discriminator: Linux may populate si_signo in
  // that case. P_PID additionally lets us demand the exact expected child.
  {$IFDEF DARWIN}
  if Info.si_pid <> AChildPid then
  {$ELSE}
  if Info._sifields._sigchld._pid <> AChildPid then
  {$ENDIF}
    Exit;
  // The leader PID/PGID remains reserved until the caller's waitpid. Seal
  // descendants now; no numeric reuse can occur between these signals and
  // the reap.
  FpKill(-AChildPid, SIGHUP);
  FpKill(-AChildPid, SIGTERM);
  FpKill(-AChildPid, SIGKILL);
  Result := True;
end;

function TPty.TerminateNoWait: TPid;
var
  IdentityMatches: boolean;
begin
  Result := FPid;
  IdentityMatches := (Result > 0) and (FPidIdentity <> '') and
    (ProcBirthIdentity(Result) = FPidIdentity);
  if IdentityMatches then
  begin
    // All calls happen while the exact leader still owns its PID. Signal the
    // whole private session group in one non-blocking sequence; ReapChildren
    // collects a direct child later without parking the socket reactor.
    FpKill(-Result, SIGHUP);
    FpKill(-Result, SIGTERM);
    FpKill(-Result, SIGKILL);
  end
  else if (Result > 0) and DebugActive then
    DebugLog(Format('pty: refusing async signal for unverifiable pid=%d',
      [Result]));
  if FMaster >= 0 then
  begin
    FpClose(FMaster);
    FMaster := -1;
  end;
  FPid := -1;
  FPidIdentity := '';
  FAlive := False;
  FPendingInput := '';
  FPendingSecret := '';
  FPromptBuffer := '';
end;

procedure TPty.KillPane;
var
  st, E: cint;
  ChildPid: TPid;
  I: integer;
  Waited: TPid;
  Reaped, IsOurChild, DirectChildExact, GroupAlive,
    IdentityMatches, SignalAuthorized: boolean;

  function StoredIdentityMatches: boolean;
  begin
    Result := (FPidIdentity <> '') and
      (ProcBirthIdentity(ChildPid) = FPidIdentity);
    if (GetEnvironmentVariable('SUPERTERM_TESTING') = '1') and
       (GetEnvironmentVariable(
         'SUPERTERM_TEST_PTY_KILL_IDENTITY_FAIL') = '1') then
      Result := False;
  end;
begin
  if FMaster >= 0 then
  begin
    FpClose(FMaster);
    FMaster := -1;
  end;
  if FPid > 0 then
  begin
    st := Default(cint);
    ChildPid := FPid;
    IdentityMatches := StoredIdentityMatches;
    Reaped := False;
    IsOurChild := True;
    DirectChildExact := False;
    // If the birth-identity backend has a transient failure, waitpid with
    // WNOHANG is a second kernel authority available only to the real parent:
    // return 0 proves this exact PID is still our direct, unreaped child.
    // A returned PID reaps it, and ECHILD grants no authority at all.
    if not IdentityMatches then
    begin
      repeat
        Waited := FpWaitPid(ChildPid, st, WNOHANG);
        if Waited >= 0 then
          Break;
        E := FpGetErrNo;
      until E <> ESysEINTR;
      if Waited = ChildPid then
        Reaped := True
      else if Waited = 0 then
        DirectChildExact := True
      else
        IsOurChild := False;
    end;
    SignalAuthorized := (not Reaped) and
      (IdentityMatches or DirectChildExact);
    // Spawned children are session leaders and therefore process-group
    // leaders. Signal the whole group so ssh/shell descendants do not leak.
    if SignalAuthorized then
    begin
      fpkill(-ChildPid, SIGHUP);
      fpkill(-ChildPid, SIGTERM);
    end;
    for I := 1 to 50 do
    begin
      if Reaped or (not IsOurChild) then
        Break;
      Waited := fpWaitPid(ChildPid, st, WNOHANG);
      if Waited = ChildPid then
      begin
        Reaped := True;
        DirectChildExact := False;
        Break;
      end;
      if Waited = 0 then
        DirectChildExact := True;
      if Waited < 0 then
      begin
        E := FpGetErrNo;
        if E = ESysEINTR then
          Continue;
        // After promotion the daemon owns the PTY master but POSIX cannot
        // transfer parenthood: waitpid correctly returns ECHILD. It must
        // still terminate the known pane process group.
        if E = ESysECHILD then
          IsOurChild := False;
        DirectChildExact := False;
        Break;
      end;
      Sleep(1);
    end;
    // Before a final numeric signal, require authority which is true now.
    // The latest waitpid(0) keeps a direct child's PID reserved; inherited
    // panes instead revalidate their stored kernel birth generation.
    SignalAuthorized := (not Reaped) and
      ((IsOurChild and DirectChildExact) or
       ((not IsOurChild) and StoredIdentityMatches));
    GroupAlive := SignalAuthorized and ((FpKill(-ChildPid, 0) = 0) or
      (FpGetErrNo = ESysEPERM));
    if (not Reaped) and GroupAlive then
      fpkill(-ChildPid, SIGKILL);
    if (not Reaped) and IsOurChild then
    begin
      // Only a real parent can complete waitpid here. For an inherited
      // pre-promotion pane, its creator deliberately keeps the zombie until
      // the daemon publishes the reap-safe event; waiting for group
      // disappearance here would add two seconds to every close.
      for I := 1 to 200 do
      begin
        Waited := fpWaitPid(ChildPid, st, WNOHANG);
        if Waited = ChildPid then
        begin
          Reaped := True;
          Break;
        end
        else if (Waited < 0) and (FpGetErrNo <> ESysEINTR) then
          Break;
        Sleep(10);
      end;
    end;
    FPid := -1;
    FPidIdentity := '';
  end;
  FAlive := False;
  FPendingSecret := '';
  FPromptBuffer := '';
end;

procedure TPty.MarkExited;
begin
  // The caller has already reaped the leader. Do not signal its old numeric
  // process-group ID afterwards: when it was the last member, that ID may be
  // reused immediately. Explicit close performs HUP/TERM before waitpid.
  if FMaster >= 0 then
  begin
    FpClose(FMaster);
    FMaster := -1;
  end;
  FAlive := False;
  FPid := -1;
  FPidIdentity := '';
  FPendingSecret := '';
  FPromptBuffer := '';
end;

procedure TPty.MarkReaped;
begin
  // waitpid has already removed the leader. Never signal its numeric PGID
  // afterwards: if it was the final member, that number is reusable between
  // the reap and a kill. Keep the master open so any already-buffered output
  // is drained before EOF retires the pane.
  FPid := -1;
  FPidIdentity := '';
end;

procedure TPty.Abandon;
begin
  if FMaster >= 0 then
  begin
    FpClose(FMaster);
    FMaster := -1;
  end;
  FPid := 0;   // KillPane/Destroy no longer signal anyone
  FPidIdentity := '';
  FAlive := False;
end;

procedure TPty.MarkDead;
var
  ChildPid: TPid;
begin
  ChildPid := FPid;
  // EOF retires the terminal, but the leader may still be waitable and a
  // background descendant may have closed the slave before continuing. Seal
  // only a kernel-verified generation, then retain PID+identity until the
  // daemon's WNOWAIT/reap pass completes.
  if (ChildPid > 0) and (FPidIdentity <> '') and
     (ProcBirthIdentity(ChildPid) = FPidIdentity) then
  begin
    FpKill(-ChildPid, SIGHUP);
    FpKill(-ChildPid, SIGTERM);
    FpKill(-ChildPid, SIGKILL);
  end;
  if FMaster >= 0 then
  begin
    FpClose(FMaster);
    FMaster := -1;
  end;
  FAlive := False;
  FPendingSecret := '';
  FPromptBuffer := '';
end;

{$IFNDEF DARWIN}
type
  TProcStatInfo = record
    Pid, ParentPid, Pgrp, SessionId, TtyPgrp: TPid;
    State: AnsiChar;
    StartTicks: QWord;
  end;

function ReadProcText(const Path: RawByteString; Limit: integer;
  out Data: RawByteString): boolean;
var
  Fd, Flags, N: integer;
begin
  Result := False;
  Data := '';
  if Limit < 2 then
    Exit;
  Fd := FpOpen(PAnsiChar(Path), O_RDONLY, 0);
  if Fd < 0 then
    Exit;
  try
    Flags := FpFcntl(Fd, F_GETFD, 0);
    if Flags >= 0 then
      FpFcntl(Fd, F_SETFD, Flags or 1 {FD_CLOEXEC});
    SetLength(Data, Limit);
    N := FileRead(Fd, Data[1], Limit);
  finally
    FpClose(Fd);
  end;
  // A full buffer may end inside a PID/stat token. Fail closed rather than
  // turn a truncated procfs read into process identity.
  if (N < 0) or (N >= Limit) then
  begin
    Data := '';
    Exit;
  end;
  SetLength(Data, N);
  Result := True;
end;

function ReadProcStatInfo(Pid: TPid; out Info: TProcStatInfo): boolean;
var
  Line, Token: RawByteString;
  CloseParen, P, StartPos, FieldNo, Value: integer;
begin
  Result := False;
  Info := Default(TProcStatInfo);
  if (Pid <= 0) or
     (not ReadProcText('/proc/' + IntToStr(Pid) + '/stat', 4096, Line)) then
    Exit;
  // Linux field 2 (comm) may itself contain spaces and ')'. Only the final
  // ')' safely separates it from fields 3..N.
  CloseParen := Length(Line);
  while (CloseParen > 0) and (Line[CloseParen] <> ')') do
    Dec(CloseParen);
  if CloseParen <= 0 then
    Exit;
  Info.Pid := Pid;
  P := CloseParen + 1;
  FieldNo := 0;
  while P <= Length(Line) do
  begin
    while (P <= Length(Line)) and (Line[P] in [' ', #9, #10, #13]) do
      Inc(P);
    if P > Length(Line) then
      Break;
    StartPos := P;
    while (P <= Length(Line)) and
          not (Line[P] in [' ', #9, #10, #13]) do
      Inc(P);
    Inc(FieldNo);
    Token := Copy(Line, StartPos, P - StartPos);
    case FieldNo of
      1:
        begin
          if Length(Token) <> 1 then
            Exit;
          Info.State := Token[1];
        end;
      2:
        begin
          if not TryStrToInt(Token, Value) then Exit;
          Info.ParentPid := Value;
        end;
      3:
        begin
          if not TryStrToInt(Token, Value) then Exit;
          Info.Pgrp := Value;
        end;
      4:
        begin
          if not TryStrToInt(Token, Value) then Exit;
          Info.SessionId := Value;
        end;
      6:
        begin
          if not TryStrToInt(Token, Value) then Exit;
          Info.TtyPgrp := Value;
        end;
      20:
        begin
          if not TryStrToQWord(Token, Info.StartTicks) then Exit;
          Break;
        end;
    end;
  end;
  Result := (FieldNo >= 20) and (Info.State <> #0);
end;
{$ENDIF}

function FindChildProcs(ParentPid: TPid; out Children: array of TPid): integer;
{$IFDEF LINUX}
var
  Line, Token: RawByteString;
  P, StartPos, Candidate: integer;
  SR: TSearchRec;
  Info: TProcStatInfo;
{$ENDIF}
begin
  Result := 0;
  {$IFDEF LINUX}
  if (ParentPid <= 0) or (Length(Children) = 0) then
    Exit;
  if not ((GetEnvironmentVariable('SUPERTERM_TESTING') = '1') and
          (GetEnvironmentVariable(
            'SUPERTERM_TEST_PROC_CHILDREN_FALLBACK') = '1')) and
     ReadProcText('/proc/' + IntToStr(ParentPid) + '/task/' +
       IntToStr(ParentPid) + '/children', 65536, Line) then
  begin
    // CONFIG_PROC_CHILDREN exposes the direct children of this task in one
    // file. This is O(children), unlike scanning every process for every idle
    // shell, so it remains the normal Linux path.
    P := 1;
    while P <= Length(Line) do
    begin
      while (P <= Length(Line)) and (Line[P] in [' ', #9, #10, #13]) do
        Inc(P);
      if P > Length(Line) then
        Break;
      StartPos := P;
      while (P <= Length(Line)) and (Line[P] in ['0'..'9']) do
        Inc(P);
      Token := Copy(Line, StartPos, P - StartPos);
      if (Token = '') or (not TryStrToInt(Token, Candidate)) or
         (Candidate <= 0) then
        Exit(0);
      if Result < Length(Children) then
      begin
        Children[Result] := Candidate;
        Inc(Result);
      end;
      while (P <= Length(Line)) and
            not (Line[P] in [' ', #9, #10, #13]) do
        Inc(P);
    end;
    Exit;
  end;
  // CONFIG_PROC_CHILDREN is optional in upstream Linux. Preserve the
  // portable procfs fallback for kernels which omit that file; the stat
  // parser still validates the final ')' and the observed parent relation.
  if FindFirst('/proc/*', faDirectory, SR) <> 0 then
    Exit;
  try
    repeat
      if TryStrToInt(SR.Name, Candidate) and (Candidate > 0) and
         ReadProcStatInfo(Candidate, Info) and
         (Info.ParentPid = ParentPid) and
         (Result < Length(Children)) then
      begin
        Children[Result] := Candidate;
        Inc(Result);
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  {$ENDIF}
end;

function ProcArgs(Pid: TPid): TStringArray;
type
  TCmdBuf = array[0..4095] of byte;
var
  f: file of byte;
  buf: TCmdBuf;
  n, i, Start: integer;
  sl: RawByteString;
begin
  Result := nil;
  if Pid <= 0 then
    Exit;
  buf := Default(TCmdBuf);
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
type
  TLinkBuf = array[0..1023] of char;
var
  link: string;
  buf: TLinkBuf;
  n: longint;
begin
  Result := '';
  if Pid <= 0 then
    Exit;
  link := '/proc/' + IntToStr(Pid) + '/cwd';
  buf := Default(TLinkBuf);
  n := fpReadLink(PAnsiChar(link), buf, SizeOf(buf) - 1);
  if n > 0 then
  begin
    buf[n] := #0;
    Result := StrPas(buf);
  end;
end;

{$IFDEF DARWIN}
{ Darwin has no /proc. Pane titles and session-restore command capture are
  fed by libproc (child enumeration, cwd) + sysctl KERN_PROCARGS2 (argv). }
const
  CTL_KERN_                = 1;
  KERN_ARGMAX_             = 8;
  KERN_PROCARGS2_          = 49;
  PROC_PIDVNODEPATHINFO_   = 9;
  VNODE_INFO_PATH_OFFSET_  = 152;   { offsetof(struct vnode_info_path, vip_path) }
  PROC_VNODEPATHINFO_SIZE_ = 2352;  { sizeof(struct proc_vnodepathinfo) }

type
  TVnodePathBuf = array[0..PROC_VNODEPATHINFO_SIZE_ - 1] of byte;

function proc_listchildpids(ppid: cint; buffer: pointer; buffersize: cint): cint;
  cdecl; external 'c' name 'proc_listchildpids';
function proc_pidinfo(pid, flavor: cint; arg: qword; buffer: pointer;
  buffersize: cint): cint; cdecl; external 'c' name 'proc_pidinfo';
function c_sysctl(name: pcint; namelen: cuint; oldp: pointer; oldlenp: pcsize_t;
  newp: pointer; newlen: csize_t): cint; cdecl; external 'c' name 'sysctl';

function DarwinDeepestChild(ppid: TPid): TPid;
var
  pids: array[0..1023] of cint;
  ret, cnt, i: integer;
begin
  Result := 0;
  { proc_listchildpids already divides by sizeof(pid_t) internally, so the
    return value is the child count, not a byte length. }
  ret := proc_listchildpids(ppid, @pids[0], SizeOf(pids));
  if ret <= 0 then
    Exit;
  cnt := ret;
  if cnt > Length(pids) then
    cnt := Length(pids);
  for i := 0 to cnt - 1 do
    if pids[i] > Result then
      Result := pids[i];
end;

function DarwinProcArgv(Pid: TPid): TStringArray;
var
  mib: array[0..2] of cint;
  argmax: cint;
  sz: csize_t;
  buf: array of byte;
  argc, taken, p, lim, st: integer;
begin
  Result := nil;
  { Keep Darwin's DFA diagnostics clean even when this unit is compiled by a
    small standalone helper rather than through the normal project build. }
  buf := nil;
  argc := 0;
  if Pid <= 0 then
    Exit;
  mib[0] := CTL_KERN_;
  mib[1] := KERN_ARGMAX_;
  argmax := 0;
  sz := SizeOf(argmax);
  if c_sysctl(@mib[0], 2, @argmax, @sz, nil, 0) <> 0 then
    Exit;
  if (argmax <= 0) or (argmax > 4 * 1024 * 1024) then
    Exit;
  SetLength(buf, argmax);
  mib[0] := CTL_KERN_;
  mib[1] := KERN_PROCARGS2_;
  mib[2] := Pid;
  sz := argmax;
  if c_sysctl(@mib[0], 3, @buf[0], @sz, nil, 0) <> 0 then
    Exit;
  if sz < SizeOf(cint) then
    Exit;
  argc := pcint(@buf[0])^;
  if argc <= 0 then
    Exit;
  lim := sz;
  p := SizeOf(cint);
  { skip exec_path }
  while (p < lim) and (buf[p] <> 0) do Inc(p);
  { skip NUL padding before argv[0] }
  while (p < lim) and (buf[p] = 0) do Inc(p);
  taken := 0;
  while (taken < argc) and (p < lim) do
  begin
    st := p;
    while (p < lim) and (buf[p] <> 0) do Inc(p);
    SetLength(Result, taken + 1);
    SetString(Result[taken], PAnsiChar(@buf[st]), p - st);
    Inc(taken);
    while (p < lim) and (buf[p] = 0) do Inc(p);
  end;
end;

function DarwinProcCwd(Pid: TPid): string;
var
  buf: TVnodePathBuf;
  ret: cint;
begin
  Result := '';
  if Pid <= 0 then
    Exit;
  buf := Default(TVnodePathBuf);
  ret := proc_pidinfo(Pid, PROC_PIDVNODEPATHINFO_, 0, @buf[0], SizeOf(buf));
  if ret <= VNODE_INFO_PATH_OFFSET_ then
    Exit;
  if buf[VNODE_INFO_PATH_OFFSET_] = Ord('/') then
    Result := StrPas(PAnsiChar(@buf[VNODE_INFO_PATH_OFFSET_]));
  { macOS firmlinks /tmp, /var and /etc under /private; proc_pidinfo returns the
    physical path. Present the user-facing path so captured cwd matches what the
    user typed (and the Linux equivalent). }
  if (Copy(Result, 1, 12) = '/private/tmp') or
     (Copy(Result, 1, 12) = '/private/var') or
     (Copy(Result, 1, 12) = '/private/etc') then
    Delete(Result, 1, 8);
end;
{$ENDIF}

function ProcBirthIdentity(Pid: TPid): string;
{$IFDEF DARWIN}
const
  PROC_PIDTBSDINFO_ = 3;
type
  {$push}{$packrecords C}
  TProcBsdInfo = record
    pbi_flags, pbi_status, pbi_xstatus, pbi_pid: cuint32;
    pbi_ppid, pbi_uid, pbi_gid, pbi_ruid: cuint32;
    pbi_rgid, pbi_svuid, pbi_svgid, rfu_1: cuint32;
    pbi_comm: array[0..15] of AnsiChar;
    pbi_name: array[0..31] of AnsiChar;
    pbi_nfiles, pbi_pgid, pbi_pjobc, e_tdev, e_tpgid: cuint32;
    pbi_nice: cint32;
    pbi_start_tvsec, pbi_start_tvusec: cuint64;
  end;
  {$pop}
var
  Info: TProcBsdInfo;
  N: cint;
begin
  Result := '';
  if Pid <= 0 then
    Exit;
  // This is the exact public proc_bsdinfo layout from sys/proc_info.h.
  // Refuse an unexpected ABI instead of reading offsets from the wrong
  // structure and turning them into signalling authority.
  N := SizeOf(Info);
  if N <> 136 then
    Exit;
  Info := Default(TProcBsdInfo);
  N := proc_pidinfo(Pid, PROC_PIDTBSDINFO_, 0, @Info, SizeOf(Info));
  if (N <> SizeOf(Info)) or (Info.pbi_pid <> cuint32(Pid)) then
    Exit;
  Result := 'darwin:' + UIntToStr(Info.pbi_start_tvsec) + ':' +
    UIntToStr(Info.pbi_start_tvusec);
end;
{$ELSE}
var
  Info: TProcStatInfo;
begin
  Result := '';
  if ReadProcStatInfo(Pid, Info) then
    Result := 'proc:' + UIntToStr(Info.StartTicks);
end;
{$ENDIF}

{$IFDEF LINUX}
function TryProcQWord(const Token: RawByteString; out Value: QWord): boolean;
var
  Normalized: string;
begin
  Normalized := string(Token);
  if (Length(Normalized) > 2) and (Normalized[1] = '0') and
     (UpCase(Normalized[2]) = 'X') then
    Normalized := '$' + Copy(Normalized, 3, MaxInt);
  Result := TryStrToQWord(Normalized, Value);
end;

function ProcWaitsForChild(Pid: TPid): boolean;
type
  TProcTokens = array[0..4] of RawByteString;
var
  Line: RawByteString;
  Tokens: TProcTokens;
  P, StartPos, Count: integer;
  SysNo, WaitOptions: QWord;
  Matched: boolean;
begin
  Result := False;
  Tokens := Default(TProcTokens);
  WaitOptions := 0;
  Matched := False;
  if (Pid <= 0) or
     (not ReadProcText('/proc/' + IntToStr(Pid) + '/syscall', 512, Line)) then
    Exit;
  P := 1;
  Count := 0;
  while (P <= Length(Line)) and (Count <= High(Tokens)) do
  begin
    while (P <= Length(Line)) and (Line[P] in [' ', #9, #10, #13]) do
      Inc(P);
    if P > Length(Line) then
      Break;
    StartPos := P;
    while (P <= Length(Line)) and
          not (Line[P] in [' ', #9, #10, #13]) do
      Inc(P);
    Tokens[Count] := Copy(Line, StartPos, P - StartPos);
    Inc(Count);
  end;
  if (Count < 4) or (not TryProcQWord(Tokens[0], SysNo)) then
    Exit;
  {$if declared(syscall_nr_wait4)}
  if SysNo = QWord(syscall_nr_wait4) then
  begin
    // wait4(pid, status, options, rusage): WNOHANG is bit zero.
    if not TryProcQWord(Tokens[3], WaitOptions) then
      Exit;
    Matched := True;
  end;
  {$endif}
  {$if declared(syscall_nr_waitid)}
  if (not Matched) and (SysNo = QWord(syscall_nr_waitid)) then
  begin
    // waitid(idtype, id, info, options, rusage): options is argument four.
    if (Count < 5) or (not TryProcQWord(Tokens[4], WaitOptions)) then
      Exit;
    Matched := True;
  end;
  {$endif}
  if not Matched then
    Exit;
  Result := (WaitOptions and 1 {WNOHANG}) = 0;
end;

function SameProcInstance(const A, B: TProcStatInfo): boolean;
begin
  Result := (A.Pid = B.Pid) and (A.ParentPid = B.ParentPid) and
    (A.Pgrp = B.Pgrp) and (A.SessionId = B.SessionId) and
    (A.TtyPgrp = B.TtyPgrp) and (A.StartTicks = B.StartTicks) and
    (A.State <> 'Z') and (B.State <> 'Z');
end;

function SoleDirectChild(ParentPid: TPid; out ChildPid: TPid): boolean;
type
  TChildPair = array[0..1] of TPid;
var
  Children: TChildPair;
  N: integer;
begin
  ChildPid := 0;
  Children := Default(TChildPair);
  N := FindChildProcs(ParentPid, Children);
  Result := N = 1;
  if Result then
    ChildPid := Children[0];
end;

function TrySynchronousShellChild(ShellPid, ForegroundPgrp: TPid;
  out ChildPid: TPid; out ChildArgs: TStringArray;
  out ChildCwd: string): boolean;
var
  ShellBefore, ShellAfter, ChildBefore, ChildAfter: TProcStatInfo;
  ConfirmedChild: TPid;
begin
  Result := False;
  ChildPid := 0;
  ChildArgs := nil;
  ChildCwd := '';
  // With job control disabled, foreground and background children share the
  // shell's pgrp. Linux still exposes the one decisive distinction: an idle
  // shell blocks on tty input, while a shell synchronously awaiting its only
  // child blocks in wait4/waitid. Anything ambiguous fails closed.
  if (not ReadProcStatInfo(ShellPid, ShellBefore)) or
     (ShellBefore.State = 'Z') or
     (ShellBefore.Pgrp <> ForegroundPgrp) or
     (ShellBefore.TtyPgrp <> ForegroundPgrp) or
     (not ProcWaitsForChild(ShellPid)) or
     (not SoleDirectChild(ShellPid, ChildPid)) or
     (not ReadProcStatInfo(ChildPid, ChildBefore)) or
     (ChildBefore.State = 'Z') or
     (ChildBefore.ParentPid <> ShellPid) or
     (ChildBefore.Pgrp <> ShellBefore.Pgrp) or
     (ChildBefore.SessionId <> ShellBefore.SessionId) or
     (ChildBefore.TtyPgrp <> ShellBefore.TtyPgrp) then
    Exit;
  ChildArgs := ProcArgs(ChildPid);
  ChildCwd := ProcCwd(ChildPid);
  if (Length(ChildArgs) = 0) or (ChildCwd = '') then
    Exit;
  // procfs files are individual observations, not one atomic snapshot.
  // Re-read both generations, relation, pgrp and the shell wait state after
  // argv/cwd so PID reuse or a child exiting between reads cannot publish
  // metadata belonging to another process.
  if (not ReadProcStatInfo(ChildPid, ChildAfter)) or
     (not ReadProcStatInfo(ShellPid, ShellAfter)) or
     (not SameProcInstance(ChildBefore, ChildAfter)) or
     (not SameProcInstance(ShellBefore, ShellAfter)) or
     (not SoleDirectChild(ShellPid, ConfirmedChild)) or
     (ConfirmedChild <> ChildPid) or
     (not ProcWaitsForChild(ShellPid)) then
  begin
    ChildPid := 0;
    ChildArgs := nil;
    ChildCwd := '';
    Exit;
  end;
  Result := True;
end;
{$ENDIF}

procedure TPty.QueryState;
{$IFDEF DARWIN}
var
  best: TPid;
  ForegroundPgrp: cint;
  Args: TStringArray;
  cmdline, base: string;
  i: integer;
begin
  if (not FAlive) or (FPid <= 0) then
    Exit;
  // The process attached directly to the PTY may be a launcher which keeps
  // an interactive shell ready for when the application exits. The terminal
  // foreground process group identifies the application the user is actually
  // interacting with, regardless of those extra parent shells.
  best := 0;
  ForegroundPgrp := 0;
  if (FMaster >= 0) and (TCGetPGrp(FMaster, ForegroundPgrp) = 0) and
     (ForegroundPgrp > 0) then
  begin
    Args := DarwinProcArgv(ForegroundPgrp);
    if Length(Args) > 0 then
      best := ForegroundPgrp;
  end;
  if best <= 0 then
    best := DarwinDeepestChild(FPid);
  if best <= 0 then
    best := FPid;
  Args := DarwinProcArgv(best);
  TitleCwd := DarwinProcCwd(best);
  cmdline := '';
  for i := 0 to High(Args) do
  begin
    if i > 0 then
      cmdline := cmdline + ' ';
    cmdline := cmdline + Args[i];
  end;
  base := ExtractFileName(FirstWordOf(cmdline));
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
{$ELSE}
var
  Kids: array[0..15] of TPid;
  n, i: integer;
  best: TPid;
  {$IFDEF LINUX}
  ChildPid: TPid;
  ChildCwd: string;
  ChildArgs: TStringArray;
  {$ENDIF}
  ForegroundPgrp: cint;
  cmdline: string;
  base: string;
  Args: TStringArray;
begin
  if (not FAlive) or (FPid <= 0) then
    Exit;
  best := 0;
  ForegroundPgrp := 0;
  // Ask the PTY which job owns its foreground. Looking only at FPid's direct
  // children loses the real application when a profile command is protected
  // by an outer shell so the pane can return to a prompt after `exit`.
  if (FMaster >= 0) and (TCGetPGrp(FMaster, ForegroundPgrp) = 0) and
     (ForegroundPgrp > 0) and (Length(ProcArgs(ForegroundPgrp)) > 0) then
    best := ForegroundPgrp;
  if best <= 0 then
  begin
    n := FindChildProcs(FPid, Kids);
    for i := 0 to n - 1 do
      if Kids[i] > best then
        best := Kids[i];
  end;
  if best > 0 then
  begin
    Args := ProcArgs(best);
    cmdline := ProcCmdLine(best);
    TitleCwd := ProcCwd(best);
  end
  else
  begin
    best := FPid;
    Args := ProcArgs(FPid);
    cmdline := ProcCmdLine(FPid);
    TitleCwd := ProcCwd(FPid);
  end;
  base := ExtractFileName(FirstWordOf(cmdline));
  if (base <> '') and (base[1] = '-') then
    Delete(base, 1, 1);
  // Bash with `set +m` keeps its own process group in TIOCGPGRP while it
  // synchronously waits for a command in the same group.  Preserve the tty
  // query as the primary path. Linux alone exposes the current wait syscall,
  // so only there can the direct child be resolved without mistaking an idle
  // background job for the foreground command.
  {$IFDEF LINUX}
  if SameText(base, FShellBase) then
  begin
    if TrySynchronousShellChild(best, ForegroundPgrp, ChildPid,
      ChildArgs, ChildCwd) then
    begin
      best := ChildPid;
      Args := ChildArgs;
      cmdline := '';
      for i := 0 to High(Args) do
      begin
        if i > 0 then
          cmdline := cmdline + ' ';
        cmdline := cmdline + Args[i];
      end;
      TitleCwd := ChildCwd;
    end;
  end;
  {$ENDIF}
  // if the "command" is the login shell itself, store empty; compare
  // by basename: the cmdline may carry the full path (/bin/bash)
  base := ExtractFileName(FirstWordOf(cmdline));
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
{$ENDIF}

end.
