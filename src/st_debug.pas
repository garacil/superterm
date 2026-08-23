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
  signal, the faulting address, how long the process had been up, a stack
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
  SysUtils, BaseUnix;

const
  RING_SIZE = 400;      // lines of context kept for a crash report
  // where a debug build traces when nothing says otherwise
  DEFAULT_DEBUG_LOG = '/tmp/st-crash.log';

var
  Lock: TRTLCriticalSection;
  Resolved: boolean = False;
  Enabled: boolean = False;
  FullMode: boolean = False;
  LogFile: Text;
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
begin
  if Resolved then
    Exit;
  Resolved := True;
  FullMode := GetEnvironmentVariable('SUPERTERM_DEBUG_FULL') = '1';
  FN := GetEnvironmentVariable('SUPERTERM_DEBUG');
{$IFDEF DEBUG}
  // A build made with 'make debug' traces by default: that is what it is
  // for, and having to remember two environment variables meant the one
  // crash worth catching was caught without any context. Either variable
  // given from outside still wins, including SUPERTERM_DEBUG_FULL=0.
  if FN = '' then
    FN := DEFAULT_DEBUG_LOG;
  if GetEnvironmentVariable('SUPERTERM_DEBUG_FULL') = '' then
    FullMode := True;
{$ENDIF}
  if FN = '' then
    Exit;
  Enabled := True;
  try
    AssignFile(LogFile, FN);
    // append: client and daemon share one file, told apart by [pid] and role
    if FileExists(FN) then
      Append(LogFile)
    else
      Rewrite(LogFile);
    LogOpen := True;
  except
    Enabled := False;
  end;
end;

function DebugActive: boolean;
begin
  if not Resolved then
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
begin
  Role := ARole;
end;

// Keep the line for a future crash report whether or not the flow log is on.
procedure RingAdd(const S: string);
begin
  Ring[RingHead] := S;
  RingHead := (RingHead + 1) mod RING_SIZE;
  if RingCount < RING_SIZE then
    Inc(RingCount);
end;

procedure DebugLog(const S: string);
var
  Line: string;
begin
  if not Resolved then
    DebugActive;
  Line := FormatDateTime('hh:nn:ss.zzz', Now) + ' [' + IntToStr(FpGetPid) +
    ' ' + Role + '] ' + S;
  EnterCriticalsection(Lock);
  try
    RingAdd(Line);
    if LogOpen then
    begin
      WriteLn(LogFile, Line);
      Flush(LogFile);
    end;
  except
  end;
  LeaveCriticalsection(Lock);
end;

// --- crash report ------------------------------------------------------

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

// One file per crash, never overwritten: role, pid, the time to the second
// and a short tag drawn from the clock, so two crashes in the same second --
// a client and its daemon going down together, or a fast retry -- both
// survive to be read.
function ReportPath: string;
var
  Tag: string;
begin
  Tag := IntToHex(GetTickCount64 and $FFFFFF, 6);
  Result := '/tmp/superterm-crash-' + Role + '-' + IntToStr(FpGetPid) + '-' +
    FormatDateTime('yyyymmdd-hhnnss', Now) + '-' + Tag + '.log';
end;

// Write everything known about this process to APath. Called from a signal
// handler, so it stays with plain file writes and does not allocate more than
// it must.
procedure WriteReport(const APath, AReason: string; AFrame: pointer);
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
    WriteLn(F, 'pid       : ', FpGetPid, '   parent: ', FpGetPPid);
    WriteLn(F, 'uptime    : ',
      FormatFloat('0.0', (Now - StartedAt) * 24 * 60 * 60), ' s');
    WriteLn(F, 'flow log  : ', GetEnvironmentVariable('SUPERTERM_DEBUG'));
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
    WriteLn(F, '--- last ', RingCount, ' log lines ---');
    for i := 0 to RingCount - 1 do
    begin
      // oldest first
      idx := (RingHead - RingCount + i + RING_SIZE * 2) mod RING_SIZE;
      WriteLn(F, Ring[idx]);
    end;
    WriteLn(F, '=== end of report ===');
  finally
    CloseFile(F);
  end;
end;

procedure DumpNow(const AReason: string);
begin
  WriteReport(ReportPath, AReason, get_frame);
end;

procedure CrashHandler(ASig: cint); cdecl;
var
  P: string;
begin
  P := ReportPath;
  WriteReport(P, SignalName(ASig), get_frame);
  if LogOpen then
  begin
    WriteLn(LogFile, '*** FATAL ', SignalName(ASig), ' -- report in ', P);
    Flush(LogFile);
  end;
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

initialization
  Lock := Default(TRTLCriticalSection);
  InitCriticalSection(Lock);
  StartedAt := Now;

finalization
  if LogOpen then
    CloseFile(LogFile);
  DoneCriticalSection(Lock);

end.
