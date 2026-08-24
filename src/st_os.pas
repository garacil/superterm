(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_os - small cross-platform OS compatibility shims

  The bulk of superterm is POSIX (GNU/Linux and macOS). A handful of trivial
  OS calls -- the current pid and the private-file permission bits -- are used
  by units that are otherwise platform independent (config, session, window
  classes, profiles). Routing those two operations through here lets those
  units drop their direct BaseUnix dependency and compile unchanged on Windows,
  where file permissions are an ACL concern the port handles elsewhere (or not
  at all for a single-user desktop) rather than a chmod bit.

  This unit deliberately owns nothing stateful. It is the seam, not a platform
  layer: the heavy platform code (PTYs, sockets, poll, the console driver)
  lives in its own units guarded by {$IFDEF WINDOWS}.
*)

unit st_os;

{$mode objfpc}{$H+}

interface

// Current process id, as a plain integer for logging and unique temp names.
function OsGetPid: LongInt;
// Parent process id, or 0 where the platform does not expose it cheaply.
function OsGetPPid: LongInt;

// Tighten a freshly written file or directory to owner-only access. On POSIX
// this is chmod 600 / 700; on Windows it is currently a no-op (a single-user
// profile directory is already under the user's account), kept as a named
// call so the intent survives and a future ACL implementation has one place
// to live.
procedure OsRestrictFile(const APath: string);   // 0600 equivalent
procedure OsRestrictDir(const APath: string);     // 0700 equivalent

implementation

uses
  {$IFDEF WINDOWS}
  Windows;
  {$ELSE}
  BaseUnix;
  {$ENDIF}

function OsGetPid: LongInt;
begin
  {$IFDEF WINDOWS}
  Result := LongInt(GetCurrentProcessId);
  {$ELSE}
  Result := LongInt(FpGetPid);
  {$ENDIF}
end;

function OsGetPPid: LongInt;
begin
  {$IFDEF WINDOWS}
  // Windows has no cheap direct getppid; the parent is not needed for the
  // crash report's core information, so 0 is an honest "unknown".
  Result := 0;
  {$ELSE}
  Result := LongInt(FpGetPPid);
  {$ENDIF}
end;

procedure OsRestrictFile(const APath: string);
begin
  {$IFDEF WINDOWS}
  // ACL tightening is deferred; a single-user %APPDATA% profile inherits the
  // account's protection. Intentionally a no-op, not an error.
  {$ELSE}
  FpChmod(PAnsiChar(APath), &600);
  {$ENDIF}
end;

procedure OsRestrictDir(const APath: string);
begin
  {$IFDEF WINDOWS}
  {$ELSE}
  FpChmod(PAnsiChar(APath), &700);
  {$ENDIF}
end;

end.
