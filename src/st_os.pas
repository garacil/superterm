(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_os - small OS helpers for otherwise system-independent units

  superterm is POSIX (GNU/Linux and macOS). A handful of trivial OS calls --
  the current and parent pid, the home and configuration directories and the
  private-file permission bits -- are used by units that need nothing else
  from the system (config, session, window classes, profiles). Routing them
  through here keeps those units free of a direct BaseUnix dependency.

  This unit deliberately owns nothing stateful: the heavy platform code
  (PTYs, sockets, poll, the console driver) lives in its own units.
*)

unit st_os;

{$mode objfpc}{$H+}

interface

// Current process id, as a plain integer for logging and unique temp names.
function OsGetPid: LongInt;
// Parent process id.
function OsGetPPid: LongInt;
// User home and per-user superterm configuration directory (~/.superterm),
// normalized without a trailing separator.
function OsUserHome: string;
function OsConfigDir: string;

// Tighten a freshly written file or directory to owner-only access
// (chmod 600 / 700).
procedure OsRestrictFile(const APath: string);   // 0600 equivalent
procedure OsRestrictDir(const APath: string);     // 0700 equivalent

implementation

uses
  SysUtils,
  BaseUnix;

function OsGetPid: LongInt;
begin
  Result := LongInt(FpGetPid);
end;

function OsGetPPid: LongInt;
begin
  Result := LongInt(FpGetPPid);
end;

function OsUserHome: string;
begin
  Result := SysUtils.GetEnvironmentVariable('HOME');
  if Result = '' then
    Result := SysUtils.GetUserDir;
  Result := ExcludeTrailingPathDelimiter(Result);
end;

function OsConfigDir: string;
begin
  Result := IncludeTrailingPathDelimiter(OsUserHome) + '.superterm';
  Result := ExcludeTrailingPathDelimiter(Result);
end;

procedure OsRestrictFile(const APath: string);
begin
  FpChmod(PAnsiChar(APath), &600);
end;

procedure OsRestrictDir(const APath: string);
begin
  FpChmod(PAnsiChar(APath), &700);
end;

end.
