program daemon_probe;

// Checks the process model the Windows session server needs: a child of the
// interactive process, started with DETACHED_PROCESS (no console), creates a
// ConPTY through the project's own st_conpty, keeps reading it after the
// parent has exited, and survives the parent's console window being closed.
// It also reports whether the parent sits inside a job object, which decides
// whether CREATE_BREAKAWAY_FROM_JOB is needed.
//
//   fpc -Mobjfpc -Sh -Fusrc -FUbuild/units/win-release -FEbin test/windows/daemon_probe.pas
//   bin\daemon_probe.exe            (parent: spawns the child and exits)
//   type %TEMP%\daemon_probe.log    (a few seconds later: the child's log)

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, st_conpty;

const
  DETACHED_PROCESS_ = $00000008;
  CREATE_BREAKAWAY_FROM_JOB_ = $01000000;
  CREATE_NEW_PROCESS_GROUP_ = $00000200;
  CREATE_UNICODE_ENVIRONMENT_ = $00000400;
  JobObjectExtendedLimitInformation_ = 9;
  JOB_OBJECT_LIMIT_BREAKAWAY_OK_ = $0800;
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE_ = $2000;

function IsProcessInJob(hProcess, hJob: THandle; out Res: BOOL): BOOL; stdcall;
  external 'kernel32' name 'IsProcessInJob';
function QueryInformationJobObject(hJob: THandle; InfoClass: DWORD;
  lpInfo: Pointer; cbInfo: DWORD; lpReturn: PDWORD): BOOL; stdcall;
  external 'kernel32' name 'QueryInformationJobObject';

var
  LogPath: string;

procedure Log(const S: string);
var
  F: TextFile;
begin
  AssignFile(F, LogPath);
  if FileExists(LogPath) then Append(F) else Rewrite(F);
  WriteLn(F, FormatDateTime('hh:nn:ss.zzz', Now), ' [', GetCurrentProcessId, '] ', S);
  CloseFile(F);
end;

procedure RunChild;
var
  Pty: TConPty;
  Buf: array[0..4095] of byte;
  N, Total: integer;
  S: RawByteString;
  Started: QWord;
begin
  Log('child started, no console: ' + BoolToStr(GetConsoleWindow = 0, True));
  Pty := TConPty.Create;
  try
    if not Pty.Spawn('cmd.exe /c "for /l %i in (1,1,10) do (echo tick %i & ping -n 2 127.0.0.1 >nul)"',
      '', 80, 25) then
    begin
      Log('spawn failed: ' + IntToStr(GetLastError));
      Exit;
    end;
    Log('conpty child pid ' + IntToStr(Pty.ProcessId));
    Total := 0;
    Started := GetTickCount64;
    while (GetTickCount64 - Started < 60000) do
    begin
      N := Pty.ReadOutput(Buf, True);
      if N > 0 then
      begin
        SetLength(S, N);
        Move(Buf[0], S[1], N);
        Inc(Total, N);
        Log('read ' + IntToStr(N) + ' bytes: ' + StringReplace(StringReplace(Copy(S, 1, 60), #27, '^[', [rfReplaceAll]), #13#10, '|', [rfReplaceAll]));
      end
      else if not Pty.Alive then
        Break
      else
        Sleep(20);
    end;
    Log('child exit code ' + IntToStr(Pty.ExitCode) + ', total bytes ' + IntToStr(Total));
    Pty.Close;
  finally
    Pty.Free;
  end;
  Log('child done');
end;

procedure RunParent;
var
  InJob: BOOL;
  Limits: array[0..255] of byte;   // JOBOBJECT_EXTENDED_LIMIT_INFORMATION
  Flags: DWORD;
  Si: TStartupInfoW;
  Pi: TProcessInformation;
  Cmd: UnicodeString;
  Exe: array[0..MAX_PATH] of WideChar;
  CreateFlags: DWORD;
  Ok: BOOL;
  Sa: TSecurityAttributes;
  Nul: THandle;
begin
  InJob := False;
  IsProcessInJob(GetCurrentProcess, 0, InJob);
  WriteLn('parent in a job: ', InJob);
  if InJob then
  begin
    FillChar(Limits, SizeOf(Limits), 0);
    if QueryInformationJobObject(0, JobObjectExtendedLimitInformation_, @Limits[0], SizeOf(Limits), nil) then
    begin
      Flags := PDWORD(@Limits[16])^;   // BasicLimitInformation.LimitFlags
      WriteLn('job limit flags: 0x', IntToHex(Flags, 8),
        ' breakaway_ok=', (Flags and JOB_OBJECT_LIMIT_BREAKAWAY_OK_) <> 0,
        ' kill_on_close=', (Flags and JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE_) <> 0);
    end
    else
      WriteLn('QueryInformationJobObject failed: ', GetLastError);
  end;
  if FileExists(LogPath) then SysUtils.DeleteFile(LogPath);
  GetModuleFileNameW(0, Exe, MAX_PATH);
  Cmd := '"' + UnicodeString(Exe) + '" child';
  UniqueString(Cmd);
  Sa.nLength := SizeOf(Sa); Sa.bInheritHandle := True; Sa.lpSecurityDescriptor := nil;
  Nul := CreateFileW('NUL', GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, @Sa, OPEN_EXISTING, 0, 0);
  Si := Default(TStartupInfoW);
  Si.cb := SizeOf(Si);
  Si.dwFlags := STARTF_USESTDHANDLES;
  Si.hStdInput := Nul; Si.hStdOutput := Nul; Si.hStdError := Nul;
  Pi := Default(TProcessInformation);
  CreateFlags := DETACHED_PROCESS_ or CREATE_NEW_PROCESS_GROUP_ or CREATE_UNICODE_ENVIRONMENT_;
  Ok := False;
  if InJob then
  begin
    Ok := CreateProcessW(nil, PWideChar(Cmd), nil, nil, True, CreateFlags or CREATE_BREAKAWAY_FROM_JOB_, nil, nil, Si, Pi);
    WriteLn('spawn with CREATE_BREAKAWAY_FROM_JOB: ', Ok, ' err=', GetLastError);
  end;
  if not Ok then
  begin
    Ok := CreateProcessW(nil, PWideChar(Cmd), nil, nil, True, CreateFlags, nil, nil, Si, Pi);
    WriteLn('spawn detached: ', Ok, ' err=', GetLastError);
  end;
  if Ok then
  begin
    WriteLn('child pid ', Pi.dwProcessId, '; parent exits now. Log: ', LogPath);
    CloseHandle(Pi.hThread); CloseHandle(Pi.hProcess);
  end;
  CloseHandle(Nul);
end;

begin
  LogPath := IncludeTrailingPathDelimiter(SysUtils.GetEnvironmentVariable('TEMP')) + 'daemon_probe.log';
  if (ParamCount >= 1) and (ParamStr(1) = 'child') then
    RunChild
  else
    RunParent;
end.
