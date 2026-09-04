(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_debug - flow log and crash dump

  Two things live here.

  THE FLOW LOG. Set SUPERTERM_DEBUG to a path and every process -- client and
  session daemon -- appends timestamped, pid-tagged lines describing what it
  does and the exact data flow to the terminal: per-frame byte and changed-cell
  counts, passthrough transitions, repaints and the launch milestones. The file
  is opened once per process and kept open, so tracing every frame is cheap.
  SUPERTERM_DEBUG_FULL=1 additionally records the chatty events -- every PTY
  read, every protocol frame, every client event -- which is a lot of volume
  but is what you want when chasing something that only happens after hours.
  A build made with 'make debug' does both by itself, writing to
  /tmp/st-crash.log, because a crash report with no history is of no use and
  remembering two variables is not something anyone does under pressure.
  Either variable given from outside still wins; a release build is silent
  unless asked.

  THE CRASH DUMP. A daemon that dies takes every pane with it and leaves the
  clients saying 'connection lost', with nothing to look at afterwards. So the
  fatal signals are trapped and, before the process goes down, a report is
  written to /tmp/superterm-crash-<role>-<pid>-<time>-<tag>.log containing the
  signal, process identity, how long the process had been up, a stack
  backtrace with file and line when the binary carries debug info, and the
  last few hundred log lines from a ring buffer that is kept even when the
  flow log is switched off -- so a crash always arrives with its context. The
  default handler is then restored and the signal re-raised, so systemd still
  gets its core dump and nothing that already worked is lost.
*)

unit st_debug;

{$mode objfpc}{$H+}

interface

procedure DebugLog(const S: string);
// true when SUPERTERM_DEBUG is set: lets hot paths skip building a
// message string when tracing is off (zero cost in normal use)
function DebugActive: boolean;
// true when SUPERTERM_DEBUG_FULL=1: the chatty per-read, per-frame detail
function DebugFull: boolean;

// Name this process in the log and in any crash report ('client', 'daemon').
// A daemon dying is a very different event from a client dying, and the
// report is useless if it does not say which one this was.
procedure DebugSetRole(const ARole: string);

// Trap the fatal signals and write a report before dying. Safe to call more
// than once; the first call wins.
procedure InstallCrashHandler;

// Write the same report on demand, without dying. Useful from a debugger or
// when something looks wrong but has not crashed.
procedure DumpNow(const AReason: string);

implementation

uses
  SysUtils, st_os
  // BaseUnix already supplies cint and TSsize; a ctypes nobody references
  // would be a fatal "unit not used" hint on Unix.
  {$IFDEF UNIX}, BaseUnix{$ENDIF}
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  {$IFDEF SUPERTERM_HEAPTRACE}, HeapTrc{$ENDIF};

const
  RING_SIZE = 400;      // lines of context kept for a crash report
  {$IFDEF UNIX}
  // Full debug logs can contain commands, paths and terminal contents. Keep a
  // newly created file private even when the caller has a permissive umask.
  LOG_CREATE_MODE = S_IRUSR or S_IWUSR;
  {$ENDIF}

// Directory crash reports and the debug-build default log land in: /tmp on
// POSIX, %TEMP% on Windows. GetTempDir resolves TMPDIR/TEMP per platform, so a
// report is always written somewhere the user can reach.
function CrashDir: string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir);
end;

type
  TLogSnapshot = array of string;

var
  Lock: TRTLCriticalSection;
  // Published with the RTL interlocked primitives only after Enabled,
  // FullMode and LogFD are complete. A plain Boolean fast-path could observe
  // True before those fields on another worker core and lose its first line.
  ResolveState: Longint = 0;
  Enabled: boolean = False;
  FullMode: boolean = False;
  {$IFDEF WINDOWS}
  LogHandle: THandle = INVALID_HANDLE_VALUE;
  {$ELSE}
  LogFD: cint = -1;
  {$ENDIF}
  LogOpen: boolean = False;
  Role: string = 'main';
  StartedAt: TDateTime;
  // Ring buffer of recent lines, kept even when the flow log is off so that a
  // crash report always has the run-up to the fault in it.
  Ring: array[0..RING_SIZE - 1] of string;
  RingHead: integer = 0;
  RingCount: integer = 0;
  HandlerInstalled: boolean = False;

procedure EnsureOpen;
var
  FN: string;
  {$IFDEF WINDOWS}
  WideFN: UnicodeString;
  {$ELSE}
  OpenErr: cint;
  {$ENDIF}
begin
  // EnsureOpen is called with Lock held. The atomic read pairs with the final
  // InterlockedExchange below for callers which take the resolved fast path.
  if System.InterlockedCompareExchange(ResolveState, 1, 1) <> 0 then
    Exit;
  FullMode := SysUtils.GetEnvironmentVariable('SUPERTERM_DEBUG_FULL') = '1';
  FN := SysUtils.GetEnvironmentVariable('SUPERTERM_DEBUG');
{$IFDEF DEBUG}
  // A build made with 'make debug' traces by default: that is what it is
  // for, and having to remember two environment variables meant the one
  // crash worth catching was caught without any context. Either variable
  // given from outside still wins, including SUPERTERM_DEBUG_FULL=0.
  if FN = '' then
    FN := CrashDir + 'st-crash.log';
  if SysUtils.GetEnvironmentVariable('SUPERTERM_DEBUG_FULL') = '' then
    FullMode := True;
{$ENDIF}
  if FN = '' then
  begin
    System.InterlockedExchange(ResolveState, 1);
    Exit;
  end;
  // Every client and daemon shares this path. Open it once in append mode so
  // the OS, rather than a racy FileExists/Rewrite pair, owns placement at EOF.
  {$IFDEF WINDOWS}
  WideFN := UTF8Decode(FN);
  LogHandle := CreateFileW(PWideChar(WideFN), FILE_APPEND_DATA,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  LogOpen := LogHandle <> INVALID_HANDLE_VALUE;
  {$ELSE}
  repeat
    LogFD := FpOpen(RawByteString(FN), O_WRONLY or O_CREAT or O_APPEND,
      LOG_CREATE_MODE);
    OpenErr := FpGetErrNo;
  until (LogFD >= 0) or (OpenErr <> ESysEINTR);
  LogOpen := LogFD >= 0;
  {$ENDIF}
  Enabled := LogOpen;
  System.InterlockedExchange(ResolveState, 1);
end;

function DebugActive: boolean;
begin
  if System.InterlockedCompareExchange(ResolveState, 1, 1) = 0 then
  begin
    EnterCriticalsection(Lock);
    try
      EnsureOpen;
    finally
      LeaveCriticalsection(Lock);
    end;
  end;
  Result := Enabled;
end;

function DebugFull: boolean;
begin
  DebugActive;          // resolves the environment on first use
  Result := Enabled and FullMode;
end;

procedure DebugSetRole(const ARole: string);
{$IFDEF SUPERTERM_HEAPTRACE}
var
  HeapBase: string;
{$ENDIF}
begin
  Role := ARole;
  {$IFDEF SUPERTERM_HEAPTRACE}
  // HeapTrc's HEAPTRC=log= option is one inherited filename. A session fork
  // would therefore mix the client and daemon reports and concurrent exits
  // could interleave them. Redirect again after every role/PID transition so
  // each process owns one complete, attributable dump.
  HeapBase := SysUtils.GetEnvironmentVariable('SUPERTERM_HEAP_LOG');
  if HeapBase <> '' then
    HeapTrc.SetHeapTraceOutput(HeapBase + '-' + Role + '-' +
      IntToStr(OsGetPid) + '.log');
  {$ENDIF}
end;

// Keep the line for a future crash report whether or not the flow log is on.
procedure RingAdd(const S: string);
begin
  Ring[RingHead] := S;
  RingHead := (RingHead + 1) mod RING_SIZE;
  if RingCount < RING_SIZE then
    Inc(RingCount);
end;

// Submit the complete record in one write(2), so O_APPEND protects it as one
// append operation against every other process using the flow log.  EINTR
// before any byte was accepted retries the same complete record.  A partial
// write is exceptional for a blocking regular file, but advancing the offset
// avoids duplicating its prefix and preserves all bytes if one does occur.
function WriteLogLine(const ALine: string): boolean;
var
  Data: RawByteString;
  Offset, DataLen: SizeInt;
  {$IFDEF WINDOWS}
  Written: DWORD;
  {$ELSE}
  Written: TSsize;
  WriteErr: cint;
  {$ENDIF}
begin
  Result := False;
  if not LogOpen then
    Exit;
  Data := RawByteString(ALine + LineEnding);
  DataLen := Length(Data);
  Offset := 1;
  while Offset <= DataLen do
  begin
    {$IFDEF WINDOWS}
    Written := 0;
    if not WriteFile(LogHandle, Data[Offset], DWORD(DataLen - Offset + 1),
      Written, nil) then
      Exit;
    {$ELSE}
    Written := FpWrite(LogFD, PChar(@Data[Offset]), DataLen - Offset + 1);
    {$ENDIF}
    if Written > 0 then
    begin
      Inc(Offset, Written);
      Continue;
    end;
    if Written = 0 then
      Exit;
    {$IFNDEF WINDOWS}
    WriteErr := FpGetErrNo;
    if WriteErr <> ESysEINTR then
      Exit;
    {$ENDIF}
  end;
  Result := True;
end;

procedure DebugLog(const S: string);
var
  Line, ThreadId: string;
begin
  if System.InterlockedCompareExchange(ResolveState, 1, 1) = 0 then
    DebugActive;
  {$IFDEF DARWIN}
  // The BSD RTL models pthread_t as a pointer.  Formatting that native type
  // directly avoids the non-portable pointer-to-ordinal cast diagnosed by
  // FPC on Apple Silicon.
  ThreadId := Format('%p', [GetThreadID]);
  {$ELSE}
  ThreadId := UIntToStr(QWord(System.GetThreadID));
  {$ENDIF}
  Line := FormatDateTime('hh:nn:ss.zzz', Now) + ' [' + IntToStr(OsGetPid) +
    ' ' + Role + ' tid=' + ThreadId + '] ' + S;
  EnterCriticalsection(Lock);
  try
    RingAdd(Line);
    if LogOpen then
      WriteLogLine(Line);
  except
  end;
  LeaveCriticalsection(Lock);
end;

// Managed strings cannot be read safely while another thread replaces their
// ring slot.  Normal on-demand dumps therefore take an ordered copy under the
// same critical section used by DebugLog and do all file I/O after releasing
// it.  SetLength/string assignment use the FPC RTL's managed-type reference
// counting; the lock keeps the source references stable for that operation.
procedure SnapshotRing(out ARecent: TLogSnapshot);
var
  I, Idx: integer;
begin
  ARecent := nil;
  EnterCriticalsection(Lock);
  try
    SetLength(ARecent, RingCount);
    for I := 0 to RingCount - 1 do
    begin
      Idx := (RingHead - RingCount + I + RING_SIZE * 2) mod RING_SIZE;
      ARecent[I] := Ring[Idx];
    end;
  finally
    LeaveCriticalsection(Lock);
  end;
end;

// --- crash report ------------------------------------------------------

{$IFDEF UNIX}
function SignalName(ASig: cint): string;
begin
  case ASig of
    SIGSEGV: Result := 'SIGSEGV (invalid memory access)';
    SIGBUS:  Result := 'SIGBUS (bad address)';
    SIGFPE:  Result := 'SIGFPE (arithmetic fault)';
    SIGILL:  Result := 'SIGILL (illegal instruction)';
    SIGABRT: Result := 'SIGABRT (aborted)';
  else
    Result := 'signal ' + IntToStr(ASig);
  end;
end;
{$ENDIF}

// One file per crash, never overwritten: role, pid, the time to the second
// and a short tag drawn from the clock, so two crashes in the same second --
// a client and its daemon going down together, or a fast retry -- both
// survive to be read.
function ReportPath: string;
var
  Tag: string;
begin
  Tag := IntToHex(GetTickCount64 and $FFFFFF, 6);
  Result := CrashDir + 'superterm-crash-' + Role + '-' + IntToStr(OsGetPid) +
    '-' + FormatDateTime('yyyymmdd-hhnnss', Now) + '-' + Tag + '.log';
end;

// Write everything known about this process to APath. Called from a signal
// handler, so it stays with plain file writes and does not allocate more than
// it must.
procedure WriteReport(const APath, AReason: string; AFrame: pointer;
  const ARecent: array of string; ARecentHead, ARecentCount: integer;
  ARecentOrdered: boolean);
var
  F: Text;
  i, idx: integer;
begin
  {$I-}
  AssignFile(F, APath);
  Rewrite(F);
  {$I+}
  if IOResult <> 0 then
    Exit;
  try
    WriteLn(F, '=== superterm crash report ===');
    WriteLn(F, 'when      : ', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    WriteLn(F, 'reason    : ', AReason);
    WriteLn(F, 'role      : ', Role);
    WriteLn(F, 'pid       : ', OsGetPid, '   parent: ', OsGetPPid);
    WriteLn(F, 'uptime    : ',
      FormatFloat('0.0', (Now - StartedAt) * 24 * 60 * 60), ' s');
    WriteLn(F, 'flow log  : ', SysUtils.GetEnvironmentVariable('SUPERTERM_DEBUG'));
    WriteLn(F, '');
    WriteLn(F, '--- backtrace (file and line when built with make debug) ---');
    try
      // BackTraceStrFunc resolves an address through the line-info tables the
      // debug build carries; on a release build it prints bare addresses,
      // which are still usable against the matching binary.
      WriteLn(F, BackTraceStrFunc(get_caller_addr(AFrame)));
      WriteLn(F, BackTraceStrFunc(get_caller_addr(get_caller_frame(AFrame))));
      Dump_Stack(F, AFrame);
    except
      WriteLn(F, '(backtrace unavailable)');
    end;
    WriteLn(F, '');
    WriteLn(F, '--- last ', ARecentCount, ' log lines ---');
    for i := 0 to ARecentCount - 1 do
    begin
      if ARecentOrdered then
        idx := i
      else
        // CrashHandler cannot lock: the fatal signal may have interrupted a
        // thread inside DebugLog.  Preserve the old best-effort ring walk in
        // that async context instead of risking a guaranteed mutex deadlock.
        idx := (ARecentHead - ARecentCount + i + Length(ARecent) * 2) mod
          Length(ARecent);
      WriteLn(F, ARecent[idx]);
    end;
    WriteLn(F, '=== end of report ===');
  finally
    CloseFile(F);
  end;
end;

procedure DumpNow(const AReason: string);
var
  Recent: TLogSnapshot;
begin
  Recent := nil;
  try
    SnapshotRing(Recent);
    WriteReport(ReportPath, AReason, get_frame, Recent, 0,
      Length(Recent), True);
  except
    // A diagnostic requested while handling another exception must never be
    // the reason the daemon leaves its main loop.
  end;
end;

{$IFDEF WINDOWS}
// Windows has no POSIX signals; the equivalent last-breath hook is an
// unhandled-exception filter. It writes the same report (backtrace + ring
// buffer) and then defers to the previously installed filter so WER / a
// debugger still gets its turn.
type
  TTopLevelFilter = function(ExceptionInfo: pointer): LongInt; stdcall;

// Not declared in FPC 3.2.2's Windows unit; bind it from kernel32.
function SetUnhandledExceptionFilter(lpTopLevelExceptionFilter: pointer):
  pointer; stdcall; external 'kernel32' name 'SetUnhandledExceptionFilter';

var
  PrevFilter: TTopLevelFilter = nil;

function WinCrashFilter(ExceptionInfo: pointer): LongInt; stdcall;
var
  P: string;
begin
  P := ReportPath;
  // As with the POSIX signal handler, do not take Lock from a fatal callback:
  // the exception may have interrupted DebugLog while this thread owned it.
  WriteReport(P, 'unhandled exception', get_frame, Ring, RingHead, RingCount,
    False);
  if LogOpen then
    WriteLogLine('*** FATAL unhandled exception -- report in ' + P);
  // EXCEPTION_CONTINUE_SEARCH: let the default handler (WER) run next.
  Result := EXCEPTION_CONTINUE_SEARCH;
  if Assigned(PrevFilter) then
    Result := PrevFilter(ExceptionInfo);
end;

procedure InstallCrashHandler;
begin
  if HandlerInstalled then
    Exit;
  HandlerInstalled := True;
  PrevFilter := TTopLevelFilter(SetUnhandledExceptionFilter(@WinCrashFilter));
end;
{$ELSE}
procedure CrashHandler(ASig: cint); cdecl;
var
  P: string;
begin
  P := ReportPath;
  // No SnapshotRing here: a signal can interrupt DebugLog while it owns Lock.
  WriteReport(P, SignalName(ASig), get_frame, Ring, RingHead, RingCount,
    False);
  if LogOpen then
    WriteLogLine('*** FATAL ' + SignalName(ASig) + ' -- report in ' + P);
  // restore the default action and re-raise, so the kernel still produces the
  // core dump systemd-coredump would have collected anyway
  FpSignal(ASig, SignalHandler(SIG_DFL));
  FpKill(FpGetPid, ASig);
end;

procedure InstallCrashHandler;
begin
  if HandlerInstalled then
    Exit;
  HandlerInstalled := True;
  FpSignal(SIGSEGV, @CrashHandler);
  FpSignal(SIGBUS, @CrashHandler);
  FpSignal(SIGFPE, @CrashHandler);
  FpSignal(SIGILL, @CrashHandler);
  FpSignal(SIGABRT, @CrashHandler);
end;
{$ENDIF}

initialization
  Lock := Default(TRTLCriticalSection);
  InitCriticalSection(Lock);
  StartedAt := Now;

finalization
  if LogOpen then
    {$IFDEF WINDOWS}
    CloseHandle(LogHandle);
    {$ELSE}
    FpClose(LogFD);
    {$ENDIF}
  DoneCriticalSection(Lock);

end.
