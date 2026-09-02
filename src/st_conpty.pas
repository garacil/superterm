(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_conpty - Windows pseudo-console (ConPTY) backend

  The POSIX side of superterm allocates a PTY with posix_openpt/openpty and
  forks a child onto its slave. Windows has no fork and no PTY device; the
  equivalent since Windows 10 1809 (build 17763) is the *pseudo console*
  (ConPTY): CreatePseudoConsole binds an input pipe and an output pipe to a
  hidden console device, and a process launched with that console attribute
  reads/writes VT sequences through those pipes exactly as a program on a
  Unix PTY reads/writes its terminal.

  This unit is the Windows analogue of the master side of st_pty.TPty:

    - Spawn      creates the two pipes, the ConPTY, and the child process
                 (CreateProcess with a PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
                 attribute list), returning the master read/write pipe ends.
    - ReadOutput / WriteInput move bytes across those pipes.
    - Resize     calls ResizePseudoConsole so SIGWINCH-style reflow happens.
    - Close      tears the child down through a Job Object (the Windows way
                 to kill a whole process tree, replacing kill(-pgid)).

  It deliberately exposes only handles and byte buffers; the readiness model
  (how the daemon waits on many of these at once) is a separate concern the
  Windows wait layer handles, because a ConPTY output pipe is a HANDLE that
  does not mix into the POSIX fpPoll set.

  Requires Windows 10 1809+. IsConPtyAvailable reports whether the three
  kernel32 entry points resolved, so a caller can degrade gracefully on an
  older host instead of failing at load time.
*)

unit st_conpty;

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils;

type
  // Opaque ConPTY handle. kernel32 types it as a distinct HPCON but it is
  // pointer-sized; keep it as HANDLE for the FFI.
  HPCON = THandle;

  TConPty = class
  private
    FHPC: HPCON;
    FInWrite: THandle;    // master -> child stdin  (we write here)
    FInRead: THandle;     // child's stdin end, owned by the ConPTY
    FOutRead: THandle;    // child stdout/stderr -> master (we read here)
    FOutWrite: THandle;   // child's output end, owned by the ConPTY
    FProc: TProcessInformation;
    FJob: THandle;
    FAttrList: pointer;
    FCols, FRows: integer;
    FAlive: boolean;
    procedure CloseHandleSafe(var H: THandle);
    function BuildConPty(ACols, ARows: integer): boolean;
  public
    constructor Create;
    destructor Destroy; override;
    // Launch ACommand (a full command line, CreateProcess semantics) under a
    // fresh pseudo console of ACols x ARows, starting in ACwd (or the current
    // directory when empty). Returns False and leaves the object dead on any
    // failure. AExtraEnv, when non-empty, is a list of NAME=VALUE lines that
    // are added on top of the inherited environment.
    function Spawn(const ACommand, ACwd: string; ACols, ARows: integer;
      const AExtraEnv: string = ''): boolean;
    // Non-blocking-ish read of whatever the child has produced. Returns the
    // byte count (0 when nothing is pending and APeekFirst is True; a blocking
    // read otherwise). ReadOutput uses a peek so a single-threaded caller does
    // not stall; the daemon path will instead wait on the handle first.
    function ReadOutput(out Buf: array of byte; APeekFirst: boolean): integer;
    // Feed bytes to the child's stdin. Returns bytes written (best effort).
    function WriteInput(const S: RawByteString): integer;
    // Re-size the pseudo console; the child sees the console resize event.
    procedure Resize(ACols, ARows: integer);
    // Whether the child is still running (polled via the process handle).
    function Alive: boolean;
    // Exit code once the child has exited, else STILL_ACTIVE.
    function ExitCode: DWORD;
    // Terminate the child (and its whole tree via the job) and release all
    // handles. Idempotent.
    procedure Close;
    property Cols: integer read FCols;
    property Rows: integer read FRows;
    property ProcessId: DWORD read FProc.dwProcessId;
    property OutputHandle: THandle read FOutRead;   // for the wait layer
  end;

// True when the running Windows exposes the ConPTY API (Win10 1809+).
function IsConPtyAvailable: boolean;

implementation

uses
  Classes;

const
  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = $00020016;
  EXTENDED_STARTUPINFO_PRESENT        = $00080000;
  STILL_ACTIVE_                       = $103;
  { consoleapi.h also defines PSEUDOCONSOLE_INHERIT_CURSOR (1) for
    CreatePseudoConsole's dwFlags. SuperTerm always starts a pane with a fresh
    cursor, so the flag is not declared here until something needs it. }

  // JOBOBJECT_EXTENDED_LIMIT_INFORMATION / kill-on-close
  JobObjectExtendedLimitInformation   = 9;
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE  = $2000;

type
  // STARTUPINFOEX is not declared in FPC 3.2.2's Windows unit.
  STARTUPINFOEXW = record
    StartupInfo: TStartupInfoW;
    lpAttributeList: pointer;
  end;

  // Minimal shapes of the job-object limit structs we set.
  IO_COUNTERS = record
    ReadOperationCount: UInt64;
    WriteOperationCount: UInt64;
    OtherOperationCount: UInt64;
    ReadTransferCount: UInt64;
    WriteTransferCount: UInt64;
    OtherTransferCount: UInt64;
  end;

  JOBOBJECT_BASIC_LIMIT_INFORMATION = record
    PerProcessUserTimeLimit: LARGE_INTEGER;
    PerJobUserTimeLimit: LARGE_INTEGER;
    LimitFlags: DWORD;
    MinimumWorkingSetSize: SIZE_T;
    MaximumWorkingSetSize: SIZE_T;
    ActiveProcessLimit: DWORD;
    Affinity: ULONG_PTR;
    PriorityClass: DWORD;
    SchedulingClass: DWORD;
  end;

  JOBOBJECT_EXTENDED_LIMIT_INFORMATION = record
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION;
    IoInfo: IO_COUNTERS;
    ProcessMemoryLimit: SIZE_T;
    JobMemoryLimit: SIZE_T;
    PeakProcessMemoryUsed: SIZE_T;
    PeakJobMemoryUsed: SIZE_T;
  end;

// --- kernel32 entry points not present in FPC 3.2.2's Windows unit ----------

function CreatePseudoConsole(size: COORD; hInput, hOutput: THandle;
  dwFlags: DWORD; out phPC: HPCON): HRESULT; stdcall;
  external 'kernel32' name 'CreatePseudoConsole';
function ResizePseudoConsole(hPC: HPCON; size: COORD): HRESULT; stdcall;
  external 'kernel32' name 'ResizePseudoConsole';
procedure ClosePseudoConsole(hPC: HPCON); stdcall;
  external 'kernel32' name 'ClosePseudoConsole';

function InitializeProcThreadAttributeList(lpAttributeList: pointer;
  dwAttributeCount, dwFlags: DWORD; var lpSize: SIZE_T): BOOL; stdcall;
  external 'kernel32' name 'InitializeProcThreadAttributeList';
function UpdateProcThreadAttribute(lpAttributeList: pointer; dwFlags: DWORD;
  Attribute: ULONG_PTR; lpValue: pointer; cbSize: SIZE_T;
  lpPreviousValue: pointer; lpReturnSize: pointer): BOOL; stdcall;
  external 'kernel32' name 'UpdateProcThreadAttribute';
procedure DeleteProcThreadAttributeList(lpAttributeList: pointer); stdcall;
  external 'kernel32' name 'DeleteProcThreadAttributeList';

// Job-object calls, also absent from FPC 3.2.2's Windows unit.
function CreateJobObjectW(lpJobAttributes: PSecurityAttributes;
  lpName: PWideChar): THandle; stdcall;
  external 'kernel32' name 'CreateJobObjectW';
function SetInformationJobObject(hJob: THandle;
  JobObjectInformationClass: DWORD; lpJobObjectInformation: pointer;
  cbJobObjectInformationLength: DWORD): BOOL; stdcall;
  external 'kernel32' name 'SetInformationJobObject';
function AssignProcessToJobObject(hJob, hProcess: THandle): BOOL; stdcall;
  external 'kernel32' name 'AssignProcessToJobObject';

var
  ConPtyProbed: boolean = False;
  ConPtyOk: boolean = False;

function BuildEnvironmentBlock(const AExtra: string): UnicodeString;
var
  Vars, Extra: TStringList;
  Env, P: PWideChar;
  Entry, Name: string;
  Eq, I, Existing: integer;

  procedure PutEntry(const AEntry: string);
  begin
    Eq := Pos('=', AEntry);
    if Eq <= 1 then
      Exit;
    Name := Copy(AEntry, 1, Eq - 1);
    Existing := Vars.IndexOfName(Name);
    if Existing >= 0 then
      Vars.Delete(Existing);
    Vars.Add(AEntry);
  end;

begin
  Result := '';
  Vars := TStringList.Create;
  Extra := TStringList.Create;
  try
    Vars.NameValueSeparator := '=';
    Vars.CaseSensitive := False;
    Vars.Sorted := True;
    Vars.Duplicates := dupIgnore;
    Env := GetEnvironmentStringsW;
    if Env <> nil then
    begin
      P := Env;
      while P^ <> #0 do
      begin
        Entry := UTF8Encode(UnicodeString(P));
        PutEntry(Entry);
        Inc(P, Length(UnicodeString(P)) + 1);
      end;
      FreeEnvironmentStringsW(Env);
    end;
    Extra.Text := StringReplace(AExtra, #0, LineEnding, [rfReplaceAll]);
    for I := 0 to Extra.Count - 1 do
      if Trim(Extra[I]) <> '' then
        PutEntry(Trim(Extra[I]));
    for I := 0 to Vars.Count - 1 do
      Result := Result + UTF8Decode(Vars[I]) + WideChar(#0);
    // CreateProcess requires a double-NUL terminator, including for an empty
    // environment. Pascal strings may contain embedded NULs safely.
    Result := Result + WideChar(#0);
    if Length(Result) = 1 then
      Result := Result + WideChar(#0);
  finally
    Extra.Free;
    Vars.Free;
  end;
end;

function IsConPtyAvailable: boolean;
var
  Lib: THandle;
begin
  if not ConPtyProbed then
  begin
    ConPtyProbed := True;
    Lib := GetModuleHandle('kernel32.dll');
    ConPtyOk := (Lib <> 0) and
      (GetProcAddress(Lib, 'CreatePseudoConsole') <> nil) and
      (GetProcAddress(Lib, 'ResizePseudoConsole') <> nil) and
      (GetProcAddress(Lib, 'ClosePseudoConsole') <> nil);
  end;
  Result := ConPtyOk;
end;

constructor TConPty.Create;
begin
  inherited Create;
  FHPC := 0;
  FInWrite := INVALID_HANDLE_VALUE;
  FInRead := INVALID_HANDLE_VALUE;
  FOutRead := INVALID_HANDLE_VALUE;
  FOutWrite := INVALID_HANDLE_VALUE;
  FJob := 0;
  FAttrList := nil;
  FProc := Default(TProcessInformation);
  FAlive := False;
end;

destructor TConPty.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TConPty.CloseHandleSafe(var H: THandle);
begin
  if (H <> 0) and (H <> INVALID_HANDLE_VALUE) then
    CloseHandle(H);
  H := INVALID_HANDLE_VALUE;
end;

// Create the two pipes and the pseudo console. The child's ends (FInRead,
// FOutWrite) are handed to CreatePseudoConsole; from that point the ConPTY
// owns them and this side keeps only the master ends (FInWrite, FOutRead).
function TConPty.BuildConPty(ACols, ARows: integer): boolean;
var
  Sz: COORD;
  Hr: HRESULT;
  Sa: TSecurityAttributes;
begin
  Result := False;
  Sa := Default(TSecurityAttributes);
  Sa.nLength := SizeOf(Sa);
  Sa.bInheritHandle := False;

  if not CreatePipe(FInRead, FInWrite, @Sa, 0) then
    Exit;
  if not CreatePipe(FOutRead, FOutWrite, @Sa, 0) then
  begin
    CloseHandleSafe(FInRead);
    CloseHandleSafe(FInWrite);
    Exit;
  end;

  if ACols < 1 then ACols := 80;
  if ARows < 1 then ARows := 24;
  Sz.X := ACols;
  Sz.Y := ARows;
  Hr := CreatePseudoConsole(Sz, FInRead, FOutWrite, 0, FHPC);
  if Hr <> S_OK then
  begin
    CloseHandleSafe(FInRead);
    CloseHandleSafe(FInWrite);
    CloseHandleSafe(FOutRead);
    CloseHandleSafe(FOutWrite);
    Exit;
  end;
  FCols := ACols;
  FRows := ARows;
  Result := True;
end;

function TConPty.Spawn(const ACommand, ACwd: string; ACols, ARows: integer;
  const AExtraEnv: string): boolean;
var
  Si: STARTUPINFOEXW;
  AttrSize: SIZE_T;
  CmdLine: WideString;
  EnvBlock: UnicodeString;
  CwdW: WideString;
  CwdPtr: PWideChar;
  EnvPtr: PWideChar;
  Ok: BOOL;
  Jeli: JOBOBJECT_EXTENDED_LIMIT_INFORMATION;
  HpcValue: HPCON;
  HpcAsPointer: Pointer absolute HpcValue;
begin
  Result := False;
  if not IsConPtyAvailable then
    Exit;
  if not BuildConPty(ACols, ARows) then
    Exit;

  // Build the PROC_THREAD_ATTRIBUTE_LIST holding the pseudo-console handle.
  AttrSize := 0;
  InitializeProcThreadAttributeList(nil, 1, 0, AttrSize);
  if AttrSize = 0 then
  begin
    Close;
    Exit;
  end;
  FAttrList := GetMem(AttrSize);
  if FAttrList = nil then
  begin
    Close;
    Exit;
  end;
  if not InitializeProcThreadAttributeList(FAttrList, 1, 0, AttrSize) then
  begin
    Close;
    Exit;
  end;
  // The attribute value IS the pseudo-console handle, passed where the API
  // expects a void*. Alias it rather than casting an ordinal to a pointer,
  // which is not portable and is a fatal hint in this build.
  HpcValue := FHPC;
  if not UpdateProcThreadAttribute(FAttrList, 0,
       PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, HpcAsPointer, SizeOf(HPCON),
       nil, nil) then
  begin
    Close;
    Exit;
  end;

  Si := Default(STARTUPINFOEXW);
  Si.StartupInfo.cb := SizeOf(STARTUPINFOEXW);
  Si.lpAttributeList := FAttrList;

  // CreateProcessW mutates its command-line buffer, so hand it a writable copy.
  CmdLine := UTF8Decode(ACommand);
  if CmdLine = '' then
    CmdLine := 'cmd.exe';
  UniqueString(CmdLine);

  CwdPtr := nil;
  CwdW := '';
  if ACwd <> '' then
  begin
    CwdW := UTF8Decode(ACwd);
    CwdPtr := PWideChar(CwdW);
  end;

  // A child launched into a pseudo console must NOT inherit stray handles, and
  // must carry EXTENDED_STARTUPINFO_PRESENT so the attribute list is honoured.
  // Build a private Unicode environment: inherited values plus the pane's
  // TERM/COLORTERM/session metadata overlays.
  EnvBlock := BuildEnvironmentBlock(AExtraEnv);
  EnvPtr := PWideChar(EnvBlock);
  Ok := CreateProcessW(nil, PWideChar(CmdLine), nil, nil, False,
    EXTENDED_STARTUPINFO_PRESENT or CREATE_UNICODE_ENVIRONMENT,
    EnvPtr, CwdPtr, @Si.StartupInfo, @FProc);

  if not Ok then
  begin
    Close;
    Exit;
  end;

  // These two ends were supplied to CreatePseudoConsole only to connect its
  // channels. Once the child exists the host must close its copies so EOF and
  // broken-pipe state propagate correctly; the ConPTY retains what it needs.
  CloseHandleSafe(FInRead);
  CloseHandleSafe(FOutWrite);

  // Kill-on-close job so losing the master tears down the whole child tree,
  // the Windows stand-in for signalling the process group in KillPane.
  FJob := CreateJobObjectW(nil, nil);
  if FJob <> 0 then
  begin
    Jeli := Default(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    Jeli.BasicLimitInformation.LimitFlags := JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(FJob, JobObjectExtendedLimitInformation,
      @Jeli, SizeOf(Jeli));
    AssignProcessToJobObject(FJob, FProc.hProcess);
  end;

  FAlive := True;
  Result := True;
end;

function TConPty.ReadOutput(out Buf: array of byte; APeekFirst: boolean): integer;
var
  Avail, Got: DWORD;
begin
  Result := 0;
  if (FOutRead = INVALID_HANDLE_VALUE) or (Length(Buf) = 0) then
    Exit;
  if APeekFirst then
  begin
    Avail := 0;
    // PeekNamedPipe works on the anonymous pipe CreatePipe returns and lets a
    // single-threaded caller avoid blocking; the daemon path waits on the
    // handle instead and reads unconditionally.
    if not PeekNamedPipe(FOutRead, nil, 0, nil, @Avail, nil) then
    begin
      FAlive := False;    // broken pipe: the child has gone
      Exit;
    end;
    if Avail = 0 then
      Exit;
  end;
  Got := 0;
  // Address-of, not a read: Buf is an out parameter that ReadFile fills.
  if not ReadFile(FOutRead, PByte(@Buf[0])^, Length(Buf), Got, nil) then
  begin
    FAlive := False;
    Exit;
  end;
  Result := Got;
end;

function TConPty.WriteInput(const S: RawByteString): integer;
var
  Written: DWORD;
begin
  Result := 0;
  if (FInWrite = INVALID_HANDLE_VALUE) or (S = '') then
    Exit;
  Written := 0;
  if WriteFile(FInWrite, PAnsiChar(S)^, Length(S), Written, nil) then
    Result := Written;
end;

procedure TConPty.Resize(ACols, ARows: integer);
var
  Sz: COORD;
begin
  if (FHPC = 0) or (ACols < 1) or (ARows < 1) then
    Exit;
  Sz.X := ACols;
  Sz.Y := ARows;
  if ResizePseudoConsole(FHPC, Sz) = S_OK then
  begin
    FCols := ACols;
    FRows := ARows;
  end;
end;

function TConPty.Alive: boolean;
begin
  Result := FAlive and (ExitCode = STILL_ACTIVE_);
end;

function TConPty.ExitCode: DWORD;
var
  Code: DWORD;
begin
  Result := STILL_ACTIVE_;
  if FProc.hProcess = 0 then
    Exit;
  Code := 0;
  if GetExitCodeProcess(FProc.hProcess, Code) then
    Result := Code;
end;

procedure TConPty.Close;
begin
  FAlive := False;
  // Break both synchronous pipe directions before ClosePseudoConsole. Older
  // ConPTY implementations can wait for their output writer during Close;
  // leaving our read handle open while nobody drains it can deadlock teardown.
  CloseHandleSafe(FInWrite);
  CloseHandleSafe(FOutRead);
  CloseHandleSafe(FInRead);
  CloseHandleSafe(FOutWrite);
  // Closing the kill-on-close job terminates any surviving process tree.
  if FJob <> 0 then
  begin
    CloseHandle(FJob);
    FJob := 0;
  end
  else if FProc.hProcess <> 0 then
    TerminateProcess(FProc.hProcess, 1);
  if FHPC <> 0 then
  begin
    ClosePseudoConsole(FHPC);
    FHPC := 0;
  end;
  if FAttrList <> nil then
  begin
    DeleteProcThreadAttributeList(FAttrList);
    FreeMem(FAttrList);
    FAttrList := nil;
  end;
  if FProc.hProcess <> 0 then
  begin
    CloseHandle(FProc.hProcess);
    FProc.hProcess := 0;
  end;
  if FProc.hThread <> 0 then
  begin
    CloseHandle(FProc.hThread);
    FProc.hThread := 0;
  end;
end;

end.
