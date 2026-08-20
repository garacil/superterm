(*
  Unidad: st_debug - log de depuracion opcional (SUPERTERM_DEBUG=fichero)
*)

unit st_debug;

{$mode objfpc}{$H+}

interface

procedure DebugLog(const S: string);

implementation

uses
  SysUtils, baseunix;

var
  Lock: TRTLCriticalSection;

procedure DebugLog(const S: string);
var
  F: Text;
  FN: string;
begin
  FN := GetEnvironmentVariable('SUPERTERM_DEBUG');
  if FN = '' then
    Exit;
  EnterCriticalsection(Lock);
  try
    AssignFile(F, FN);
    if FileExists(FN) then
      Append(F)
    else
      Rewrite(F);
    WriteLn(F, FormatDateTime('hh:nn:ss.zzz', Now), ' [', FpGetPid, '] ', S);
    CloseFile(F);
  except
  end;
  LeaveCriticalsection(Lock);
end;

initialization
  InitCriticalSection(Lock);

finalization
  DoneCriticalSection(Lock);

end.
