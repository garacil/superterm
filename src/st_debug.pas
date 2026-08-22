(*
  Unit: st_debug - optional debug/flow log (SUPERTERM_DEBUG=file)

  Serious tracing tool: set SUPERTERM_DEBUG to a path and every process
  (client and session daemon) appends timestamped, pid-tagged lines
  describing what it does and the exact data flow to the terminal --
  per-frame byte counts and changed-cell counts, passthrough transitions,
  repaints and the launch milestones. The file is opened once per process
  and kept open (flushed per line) so tracing every frame is cheap.
*)

unit st_debug;

{$mode objfpc}{$H+}

interface

procedure DebugLog(const S: string);
// true when SUPERTERM_DEBUG is set: lets hot paths skip building a
// message string when tracing is off (zero cost in normal use)
function DebugActive: boolean;

implementation

uses
  SysUtils, baseunix;

var
  Lock: TRTLCriticalSection;
  Resolved: boolean = False;
  Enabled: boolean = False;
  LogFile: Text;
  LogOpen: boolean = False;

procedure EnsureOpen;
var
  FN: string;
begin
  if Resolved then
    Exit;
  Resolved := True;
  FN := GetEnvironmentVariable('SUPERTERM_DEBUG');
  if FN = '' then
    Exit;
  Enabled := True;
  try
    AssignFile(LogFile, FN);
    // append: client and daemon share one file, told apart by [pid]
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

procedure DebugLog(const S: string);
begin
  if not DebugActive then
    Exit;
  EnterCriticalsection(Lock);
  try
    if LogOpen then
    begin
      WriteLn(LogFile, FormatDateTime('hh:nn:ss.zzz', Now), ' [',
        FpGetPid, '] ', S);
      Flush(LogFile);
    end;
  except
  end;
  LeaveCriticalsection(Lock);
end;

initialization
  Lock := Default(TRTLCriticalSection);
  InitCriticalSection(Lock);

finalization
  if LogOpen then
    CloseFile(LogFile);
  DoneCriticalSection(Lock);

end.
