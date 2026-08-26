(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_ssh_entry - restricted OpenSSH ForceCommand entry point

  OpenSSH owns TCP, encryption, authentication and the PTY.  This unit only
  resolves the per-user canonical session and serialises its first creation;
  the ordinary TSessionClient and Unix socket protocol remain unchanged.
*)

unit st_ssh_entry;

{$mode objfpc}{$H+}

interface

// True only for the fixed ForceCommand argv accepted by this unit.
function IsSshEntryRequest: boolean;

// Validates the OpenSSH environment, resolves/locks the configured default
// session and sets st_server's normal attach/start globals.  On a missing
// session the creation lock remains held until ReleaseSshEntryCreationLock.
function PrepareSshEntry(out AError: string): boolean;

// Records only the routing pointer after a successful SSH attach.  Session
// geometry, panes and processes remain exclusively in the daemon.
procedure RememberSshEntrySession(const AName: string);

// Idempotent.  The parent calls it immediately after promotion; the forked
// daemon child calls it too so it never retains an unrelated lock descriptor.
procedure ReleaseSshEntryCreationLock;

implementation

uses
  SysUtils, BaseUnix, st_config, st_server;

const
  CREATE_WAIT_MS = 30000;
  CREATE_RETRY_MS = 50;
  CREATE_WAIT_ATTEMPTS = CREATE_WAIT_MS div CREATE_RETRY_MS;

function IsSshEntryRequest: boolean;
begin
  Result := (ParamCount = 1) and (ParamStr(1) = '--ssh-entry');
end;

procedure ReleaseSshEntryCreationLock;
begin
  ReleaseHeldSessionNameLock;
end;

procedure RememberSshEntrySession(const AName: string);
var
  Cfg: TConfig;
  Canonical: string;
begin
  if not SshEntryMode then
    Exit;
  Canonical := SanitizeSessionName(Trim(AName));
  if (Canonical = '') or (Canonical <> Trim(AName)) then
    Exit;
  try
    LoadConfig(Cfg);
    if SameText(Cfg.SshLastSession, Canonical) then
      Exit;
    Cfg.SshLastSession := Canonical;
    SaveConfigFields(Cfg, [cfSshLastSession]);
  except
    // A routing hint must never tear down a successfully attached terminal.
    // The next login can still use default_session or create the fallback.
  end;
end;

function SessionPathLive(const AName: string; out APath: string): boolean;
begin
  APath := SessionSocketPathFor(AName);
  Result := SessionIsLive(APath);
end;

function TryCreationLock(const AName: string; out AError: string): boolean;
var
  S: string;
  Attempt, Attempts, V: integer;
  LockResult: TSessionNameLockResult;
begin
  Result := False;
  AError := '';
  ReleaseSshEntryCreationLock;
  Attempts := CREATE_WAIT_ATTEMPTS;
  S := GetEnvironmentVariable('SUPERTERM_TEST_CREATE_POLLS');
  if (GetEnvironmentVariable('SUPERTERM_TESTING') = '1') and
     TryStrToInt(S, V) and (V >= 1) and (V <= Attempts) then
    Attempts := V;
  for Attempt := 1 to Attempts do
  begin
    LockResult := TryHoldSessionNameLock(AName);
    if LockResult = snlAcquired then
      Exit(True);
    if LockResult = snlError then
    begin
      AError := UiText('cannot lock session creation',
        'no se puede bloquear la creacion de la sesion');
      ReleaseSshEntryCreationLock;
      Exit;
    end;
    // listen() precedes the daemon READY acknowledgement.  Seeing a
    // connectable socket while this lock is still owned is therefore not
    // publication: attaching at that point can block on an incomplete
    // snapshot forever.  Acquire the lock first, then recheck liveness in
    // PrepareSshEntry after the creator has completed or rolled back.
    if Attempt < Attempts then
      Sleep(CREATE_RETRY_MS);
  end;

  AError := UiText('timed out waiting for the default session',
    'se agoto la espera de la sesion predeterminada');
  ReleaseSshEntryCreationLock;
end;

function PrepareSshEntry(out AError: string): boolean;
var
  Cfg: TConfig;
  SessionName, LastName, Path: string;
begin
  Result := False;
  AError := '';
  if not IsSshEntryRequest then
  begin
    AError := UiText('invalid SSH entry command',
      'comando de entrada SSH no valido');
    Exit;
  end;
  // OpenSSH exports SSH_ORIGINAL_COMMAND only for an exec/subsystem request.
  // getenv must be used here: an interactive shell omits the variable, while
  // an explicitly empty exec request exports it with an empty value.  The
  // high-level GetEnvironmentVariable API collapses those two states.
  if (GetEnvironmentVariable('SSH_CONNECTION') = '') or
     (GetEnvironmentVariable('SSH_TTY') = '') then
  begin
    AError := UiText('an interactive SSH PTY is required',
      'se necesita un PTY SSH interactivo');
    Exit;
  end;
  if FpGetEnv(PChar('SSH_ORIGINAL_COMMAND')) <> nil then
  begin
    AError := UiText('remote commands and subsystems are disabled',
      'los comandos remotos y subsistemas estan desactivados');
    Exit;
  end;

  LoadConfig(Cfg);
  SessionName := '';
  LastName := Trim(Cfg.SshLastSession);
  if SameText(Cfg.SshSessionMode, 'last') and (LastName <> '') and
     (SanitizeSessionName(LastName) = LastName) and
     SessionPathLive(LastName, Path) then
    SessionName := LastName;
  if SessionName = '' then
    SessionName := Trim(Cfg.DefaultSession);
  if SessionName = '' then
    SessionName := Trim(Cfg.DefaultProfile);
  if SessionName = '' then
    SessionName := 'session';
  SessionName := SanitizeSessionName(SessionName);

  SshEntryMode := True;
  CliSessionName := SessionName;
  AttachRequested := False;
  AttachSocket := '';
  // Every entry takes the per-name lock before trusting even a connectable
  // socket.  listen() happens before READY during first publication, so a
  // lock-free fast probe here would let a simultaneous login attach to a
  // half-created daemon.  Established sessions take this uncontended lock
  // only for the following liveness recheck and release it immediately.
  // Missing sessions keep it through profile construction and publication.
  Result := TryCreationLock(SessionName, AError);
  if not Result then
    Exit;
  if SessionPathLive(SessionName, Path) then
  begin
    AttachRequested := True;
    AttachSocket := Path;
    ReleaseSshEntryCreationLock;
  end;
end;

finalization
  ReleaseSshEntryCreationLock;

end.
