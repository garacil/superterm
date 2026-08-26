(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_ssh_server - dedicated OpenSSH service administration

  This unit deliberately does not implement SSH.  It builds a small,
  fail-closed configuration for the operating system's OpenSSH daemon and
  keeps all persistent SSH state below /etc/superterm/sshd.  The forced
  command enters SuperTerm, so the existing Unix-socket session daemon remains
  the only owner of sessions and their protocol.

  The public server.ini is stable.  sshd_config.generated is disposable and
  is replaced only after the installed sshd accepts both -t and -T.  Host keys
  and centrally managed authorized keys are never passed through a shell.
*)

unit st_ssh_server;

{$mode objfpc}{$H+}

interface

// True means ParamStr(1) was ssh-server/servidor-ssh and the command was
// handled.  As in st_cli, returning normally lets FPC finalize managed data.
function RunSshServerAdmin(out AExitCode: integer): boolean;

implementation

uses
  Classes, SysUtils, BaseUnix, Unix, Users, st_config, st_cli_help;

const
  DEFAULT_SSHD_ROOT = '/etc/superterm/sshd';
  DEFAULT_SERVER_INI =
    '[server]' + LineEnding +
    'config_version=1' + LineEnding +
    'listen=127.0.0.1:8022,[::1]:8022' + LineEnding +
    'allow_root=0' + LineEnding +
    'password_authentication=1' + LineEnding +
    'managed_authorized_keys=1' + LineEnding +
    'user_authorized_keys=1' + LineEnding;
  MAX_CONFIG_SIZE = 65536;
  MAX_KEY_LINE = 65536;
  MAX_AUTHORIZED_FILE = MAX_CONFIG_SIZE * 16;
  MAX_AUTHORIZED_KEYS = 4096;
  ST_FD_CLOEXEC = 1;
  ADMIN_LOCK_POLL_MS = 20;
  ADMIN_LOCK_POLL_ATTEMPTS = 1500;
  // This stable token is the package ownership boundary across releases.
  // Descriptor details may evolve, but future binaries can still recognise
  // an older SuperTerm-owned file without accepting a generic generated-file
  // comment or an unrelated service with the same filename.
  MANAGED_SERVICE_MARKER =
    'X-SuperTerm-Managed-Service: org.superterm.sshd/v1';
  {$IFDEF DARWIN}
  // Apple files-974.120.2 installs this exact, root-owned system alias.
  // It is the only symbolic-link directory accepted by the privileged path
  // checks; every other component is still inspected with lstat(2).
  DARWIN_ETC_ALIAS = '/etc';
  DARWIN_ETC_LINK_TARGET = 'private/etc';
  {$ENDIF}
  {$IFNDEF DARWIN}
  SERVICE_NAME = 'superterm-sshd.service';
  {$ELSE}
  // launchctl(1) returns bootstrap error 113 ("Could not find specified
  // service") when a service target is not registered.  Its human-readable
  // `print` output is explicitly not an API, so never classify by text.
  LAUNCHCTL_SERVICE_NOT_FOUND = 113;
  {$ENDIF}
  LAUNCHD_LABEL = 'org.superterm.sshd';

type
  ESshAdmin = class(Exception);

  TSshServerConfig = record
    Listen: array of string;
    AllowRoot: boolean;
    PasswordAuthentication: boolean;
    ManagedAuthorizedKeys: boolean;
    UserAuthorizedKeys: boolean;
  end;

  TListenScratch = array[0..31] of string;

  TFileSnapshot = record
    Exists: boolean;
    Data: string;
    Mode: TMode;
  end;

  TServiceSnapshot = record
    Captured: boolean;
    Enabled: boolean;
    Active: boolean;
  end;

var
  TempSerial: QWord = 0;

function NormToken(const S: string): string;
var
  i: integer;
  b1, b2: byte;
begin
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    b1 := byte(S[i]);
    if (b1 = $C3) and (i < Length(S)) then
    begin
      b2 := byte(S[i + 1]);
      case b2 of
        $A1, $81: Result := Result + 'a';
        $A9, $89: Result := Result + 'e';
        $AD, $8D: Result := Result + 'i';
        $B3, $93: Result := Result + 'o';
        $BA, $9A, $BC, $9C: Result := Result + 'u';
        $B1, $91: Result := Result + 'n';
      else
        Result := Result + S[i] + S[i + 1];
      end;
      Inc(i, 2);
    end
    else
    begin
      Result := Result + LowerCase(S[i]);
      Inc(i);
    end;
  end;
  while (Result <> '') and (Result[1] = '-') do
    Delete(Result, 1, 1);
end;

function TokenIn(const S: string; const Values: array of string): boolean;
var
  I: integer;
begin
  for I := Low(Values) to High(Values) do
    if S = Values[I] then
      Exit(True);
  Result := False;
end;

function TestingMode: boolean;
begin
  {$IFDEF SUPERTERM_TEST_BUILD}
  Result := GetEnvironmentVariable('SUPERTERM_TESTING') = '1';
  {$ELSE}
  // Test path and executable overrides are intentionally absent from the
  // installed binary.  An environment variable must never turn a root-run
  // administration command into an arbitrary executable launcher.
  Result := False;
  {$ENDIF}
end;

function ProductionRoot: boolean;
begin
  Result := (not TestingMode) or
    (GetEnvironmentVariable('SUPERTERM_SSHD_ROOT') = '');
end;

function ContainsControl(const S: string): boolean;
var
  i: integer;
begin
  for i := 1 to Length(S) do
    if (byte(S[i]) < 32) or (byte(S[i]) = 127) then
      Exit(True);
  Result := False;
end;

function SshdRoot: string;
var
  Override: string;
begin
  Override := GetEnvironmentVariable('SUPERTERM_SSHD_ROOT');
  if Override = '' then
    Exit(DEFAULT_SSHD_ROOT);
  if not TestingMode then
    raise ESshAdmin.Create(
      'SUPERTERM_SSHD_ROOT is available only in the non-installed test build');
  if (Override[1] <> '/') or ContainsControl(Override) then
    raise ESshAdmin.Create('SUPERTERM_SSHD_ROOT must be an absolute safe path');
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(Override));
  if (Result = '') or (Result = '/') then
    raise ESshAdmin.Create('SUPERTERM_SSHD_ROOT may not be the filesystem root');
end;

function RootPath(const Leaf: string): string;
begin
  Result := IncludeTrailingPathDelimiter(SshdRoot) + Leaf;
end;

function IniPath: string;
begin
  Result := RootPath('server.ini');
end;

function GeneratedConfigPath: string;
begin
  Result := RootPath('sshd_config.generated');
end;

function HostKeyPath: string;
begin
  Result := RootPath('ssh_host_ed25519_key');
end;

function AuthorizedKeysDir: string;
begin
  Result := RootPath('authorized_keys');
end;

function PidFilePath: string;
begin
  // A private pid file is mandatory: never collide with the host's sshd.
  // Test roots keep every artefact isolated; the real instance keeps runtime
  // state out of the persistent key/configuration directory.
  if ProductionRoot then
    Result := '/var/run/superterm-sshd.pid'
  else
    Result := RootPath('superterm-sshd.pid');
end;

function ErrnoText: string;
var
  E: cint;
begin
  E := FpGetErrNo;
  Result := SysErrorMessage(E) + ' (errno ' + IntToStr(E) + ')';
end;

procedure RequireRoot;
begin
  // Tests are permitted without privileges only when every write is rooted
  // below an explicit isolated override. SUPERTERM_TESTING alone can never
  // grant access to the production paths.
  if TestingMode and (not ProductionRoot) then
    Exit;
  if FpGetEUid <> 0 then
    raise ESshAdmin.Create('this command must be run as root');
end;

function LStatPath(const Path: string; out St: Stat): boolean;
var
  Tmp: Stat;
begin
  Tmp := Default(Stat);
  Result := FpLStat(RawByteString(Path), Tmp) = 0;
  St := Tmp;
end;

{$IFDEF DARWIN}
function DarwinEtcAliasPath: string;
{$IFDEF SUPERTERM_TEST_BUILD}
var
  Override: string;
{$ENDIF}
begin
  Result := DARWIN_ETC_ALIAS;
  {$IFDEF SUPERTERM_TEST_BUILD}
  // This path is present only in the separate test executable.  It lets the
  // Darwin suite reproduce Apple's relative /etc link below its private HOME
  // without writing to the real root filesystem.
  Override := GetEnvironmentVariable('SUPERTERM_TEST_DARWIN_ETC_ALIAS');
  if TestingMode and (Override <> '') then
  begin
    if (Override[1] <> '/') or ContainsControl(Override) then
      raise ESshAdmin.Create(
        'SUPERTERM_TEST_DARWIN_ETC_ALIAS must be an absolute safe path');
    Result := ExcludeTrailingPathDelimiter(ExpandFileName(Override));
    if (Result = '') or (Result = '/') then
      raise ESshAdmin.Create(
        'SUPERTERM_TEST_DARWIN_ETC_ALIAS may not be the filesystem root');
  end;
  {$ENDIF}
end;
{$ENDIF}

procedure CheckSafeDirectory(const Path: string; RequireRootOwner: boolean);
var
  St: Stat;
  {$IFDEF DARWIN}
  TargetBuf: array[0..4095] of char;
  LinkTarget: RawByteString;
  TargetLen: cint;
  AliasParent, PhysicalParent, PhysicalTarget: string;
  {$ENDIF}
begin
  if not LStatPath(Path, St) then
    raise ESshAdmin.CreateFmt('directory does not exist: %s', [Path]);
  if not FpS_ISDIR(St.st_mode) then
  begin
    {$IFDEF DARWIN}
    // macOS deliberately installs /etc as the relative root-owned link
    // "private/etc". FPC's FpLStat correctly reports the link itself, while
    // OpenSSH safe_path() first canonicalises it with realpath(). Accept only
    // this documented system alias, then validate both the namespace that
    // owns the link and every directory in its physical target. No arbitrary
    // or nested symbolic-link ancestor is accepted.
    if (Path = DarwinEtcAliasPath) and FpS_ISLNK(St.st_mode) then
    begin
      if RequireRootOwner and (St.st_uid <> 0) then
        raise ESshAdmin.CreateFmt('system directory alias is not owned by root: %s',
          [Path]);
      TargetLen := FpReadLink(PChar(RawByteString(Path)), @TargetBuf[0],
        SizeOf(TargetBuf));
      if TargetLen < 0 then
        raise ESshAdmin.CreateFmt('cannot inspect system directory alias %s: %s',
          [Path, ErrnoText]);
      if TargetLen >= SizeOf(TargetBuf) then
        raise ESshAdmin.CreateFmt('system directory alias target is too long: %s',
          [Path]);
      SetString(LinkTarget, PChar(@TargetBuf[0]), TargetLen);
      if LinkTarget <> DARWIN_ETC_LINK_TARGET then
        raise ESshAdmin.CreateFmt('unexpected system directory alias target: %s',
          [Path]);
      AliasParent := ExcludeTrailingPathDelimiter(ExtractFileDir(Path));
      if AliasParent = '' then
        AliasParent := '/';
      PhysicalParent := IncludeTrailingPathDelimiter(AliasParent) + 'private';
      PhysicalTarget := IncludeTrailingPathDelimiter(AliasParent) +
        DARWIN_ETC_LINK_TARGET;
      CheckSafeDirectory(AliasParent, RequireRootOwner);
      CheckSafeDirectory(PhysicalParent, RequireRootOwner);
      CheckSafeDirectory(PhysicalTarget, RequireRootOwner);
      Exit;
    end;
    {$ENDIF}
    raise ESshAdmin.CreateFmt('not a directory (or is a symlink): %s', [Path]);
  end;
  if RequireRootOwner and (St.st_uid <> 0) then
    raise ESshAdmin.CreateFmt('directory is not owned by root: %s', [Path]);
  if RequireRootOwner and ((St.st_mode and &22) <> 0) then
    raise ESshAdmin.CreateFmt('directory is writable by group/others: %s', [Path]);
end;

// OpenSSH's safe_path() checks every directory leading to an executable.
// The forced command serves every authenticated account, so protecting only
// the final inode would still let the owner of a parent directory replace it.
procedure CheckProtectedAncestors(const FilePath: string);
var
  Dir, Parent: string;
begin
  if not ProductionRoot then
    Exit;
  Dir := ExcludeTrailingPathDelimiter(ExtractFileDir(FilePath));
  if Dir = '' then
    Dir := '/';
  while True do
  begin
    CheckSafeDirectory(Dir, True);
    if Dir = '/' then
      Break;
    Parent := ExcludeTrailingPathDelimiter(ExtractFileDir(Dir));
    if Parent = '' then
      Parent := '/';
    if Parent = Dir then
      raise ESshAdmin.CreateFmt('cannot validate executable path: %s',
        [FilePath]);
    Dir := Parent;
  end;
end;

procedure CheckSafeRegular(const Path: string; RequireRootOwner: boolean;
  ForbiddenMode: TMode);
var
  St: Stat;
begin
  if not LStatPath(Path, St) then
    raise ESshAdmin.CreateFmt('file does not exist: %s', [Path]);
  if not FpS_ISREG(St.st_mode) then
    raise ESshAdmin.CreateFmt('not a regular file (or is a symlink): %s', [Path]);
  if RequireRootOwner and (St.st_uid <> 0) then
    raise ESshAdmin.CreateFmt('file is not owned by root: %s', [Path]);
  if (St.st_mode and ForbiddenMode) <> 0 then
    raise ESshAdmin.CreateFmt('unsafe permissions on file: %s', [Path]);
end;

procedure EnsureOneDirectory(const Path: string; Mode: TMode;
  CheckOwnership: boolean);
var
  St: Stat;
begin
  if LStatPath(Path, St) then
  begin
    if not FpS_ISDIR(St.st_mode) then
      raise ESshAdmin.CreateFmt('path is not a real directory: %s', [Path]);
  end
  else if FpGetErrNo = ESysENOENT then
  begin
    if (FpMkdir(RawByteString(Path), Mode) <> 0) and
       (FpGetErrNo <> ESysEEXIST) then
      raise ESshAdmin.CreateFmt('cannot create directory %s: %s',
        [Path, ErrnoText]);
  end
  else
    raise ESshAdmin.CreateFmt('cannot inspect directory %s: %s',
      [Path, ErrnoText]);
  CheckSafeDirectory(Path, CheckOwnership);
  if FpChmod(RawByteString(Path), Mode) <> 0 then
    raise ESshAdmin.CreateFmt('cannot set permissions on %s: %s',
      [Path, ErrnoText]);
end;

procedure EnsureDirectories;
var
  Parent: string;
begin
  {$IFDEF DARWIN}
  {$IFDEF SUPERTERM_TEST_BUILD}
  // Exercise the exact production alias validator in an isolated fake tree.
  // The installed binary contains neither the override nor this test hook.
  if TestingMode and
     (GetEnvironmentVariable('SUPERTERM_TEST_DARWIN_ETC_ALIAS') <> '') then
    CheckSafeDirectory(DarwinEtcAliasPath, False);
  {$ENDIF}
  {$ENDIF}
  Parent := ExtractFileDir(SshdRoot);
  if ProductionRoot then
  begin
    CheckSafeDirectory('/etc', True);
    if not DirectoryExists(Parent) then
    begin
      if (FpMkdir(RawByteString(Parent), &755) <> 0) and
         (FpGetErrNo <> ESysEEXIST) then
        raise ESshAdmin.CreateFmt('cannot create directory %s: %s',
          [Parent, ErrnoText]);
    end;
    CheckSafeDirectory(Parent, True);
  end
  else if not ForceDirectories(Parent) then
    raise ESshAdmin.CreateFmt('cannot create test parent directory: %s', [Parent]);

  EnsureOneDirectory(SshdRoot, &755, ProductionRoot);
  // sshd reads authorized keys after temporarily adopting the target UID.
  EnsureOneDirectory(AuthorizedKeysDir, &755, ProductionRoot);
end;

function UniqueTempName(const NearPath, Tag: string): string;
var
  St: Stat;
begin
  repeat
    Inc(TempSerial);
    Result := NearPath + '.' + Tag + '.tmp.' + IntToStr(FpGetPid) + '.' +
      IntToStr(TempSerial);
  until not LStatPath(Result, St);
end;

procedure WriteAll(Fd: cint; const Data: RawByteString);
var
  Done: SizeInt;
  N: TSSize;
  E: cint;
begin
  Done := 0;
  while Done < Length(Data) do
  begin
    N := FpWrite(Fd, PChar(Data) + Done, Length(Data) - Done);
    E := FpGetErrNo;
    if N > 0 then
      Inc(Done, N)
    else if (N < 0) and (E = ESysEINTR) then
      Continue
    else
      raise ESshAdmin.CreateFmt('cannot write temporary file: %s',
        [SysErrorMessage(E)]);
  end;
end;

function WriteTemporary(const Target, Data: string; Mode: TMode): string;
var
  Fd: cint;
  Flags: cint;
begin
  Result := UniqueTempName(Target, 'write');
  Flags := O_WRONLY or O_CREAT or O_EXCL;
  {$IF DEFINED(LINUX) OR DEFINED(BSD) OR DEFINED(DARWIN)}
  Flags := Flags or O_NOFOLLOW;
  {$ENDIF}
  Fd := FpOpen(RawByteString(Result), Flags, Mode);
  if Fd < 0 then
    raise ESshAdmin.CreateFmt('cannot create temporary file %s: %s',
      [Result, ErrnoText]);
  try
    WriteAll(Fd, RawByteString(Data));
    // The name is unique inside a root-owned, non-writable directory.  FPC
    // 3.2.2 exposes chmod(2), not fchmod(2), through BaseUnix.
    if FpChmod(RawByteString(Result), Mode) <> 0 then
      raise ESshAdmin.CreateFmt('cannot set temporary file permissions: %s',
        [ErrnoText]);
    if FpFsync(Fd) <> 0 then
      raise ESshAdmin.CreateFmt('cannot sync temporary file %s: %s',
        [Result, ErrnoText]);
  except
    FpClose(Fd);
    FpUnlink(RawByteString(Result));
    raise;
  end;
  if FpClose(Fd) <> 0 then
  begin
    FpUnlink(RawByteString(Result));
    raise ESshAdmin.CreateFmt('cannot close temporary file %s: %s',
      [Result, ErrnoText]);
  end;
end;

procedure SyncParentDirectoryBestEffort(const Path: string);
var
  DirName: string;
  Fd: cint;
begin
  // fsyncing the temporary protects its bytes; syncing the containing
  // directory after rename protects the new name across a crash.  Some Unix
  // filesystems reject directory fsync, so this durability extension is
  // deliberately best-effort just like the configuration writer.
  DirName := ExtractFileDir(Path);
  if DirName = '' then
    DirName := '.';
  Fd := FpOpen(RawByteString(DirName), O_RDONLY, 0);
  if Fd < 0 then
    Exit;
  FpFcntl(Fd, F_SETFD, ST_FD_CLOEXEC);
  FpFsync(Fd);
  FpClose(Fd);
end;

procedure SyncRegularTemporary(const Path: string);
var
  Fd, Flags, E: cint;
  St: Stat;
begin
  Flags := O_RDONLY;
  {$IF DEFINED(LINUX) OR DEFINED(BSD) OR DEFINED(DARWIN)}
  Flags := Flags or O_NOFOLLOW;
  {$ENDIF}
  repeat
    Fd := FpOpen(RawByteString(Path), Flags, 0);
    E := FpGetErrNo;
  until (Fd >= 0) or (E <> ESysEINTR);
  if Fd < 0 then
    raise ESshAdmin.CreateFmt('cannot open temporary file %s: %s',
      [Path, SysErrorMessage(E)]);
  try
    St := Default(Stat);
    if (FpFStat(Fd, St) <> 0) or not FpS_ISREG(St.st_mode) then
      raise ESshAdmin.CreateFmt('temporary path is not a regular file: %s',
        [Path]);
    if FpFcntl(Fd, F_SETFD, ST_FD_CLOEXEC) < 0 then
      raise ESshAdmin.CreateFmt('cannot protect temporary file %s: %s',
        [Path, ErrnoText]);
    if FpFsync(Fd) <> 0 then
      raise ESshAdmin.CreateFmt('cannot sync temporary file %s: %s',
        [Path, ErrnoText]);
  finally
    FpClose(Fd);
  end;
end;

procedure ReplaceWithTemporary(const TempPath, Target: string);
var
  St: Stat;
begin
  // WriteTemporary already did this, but key files produced by ssh-keygen
  // enter through the same replacement primitive.  Keeping durability in
  // one primitive prevents a future caller from publishing unsynced bytes.
  try
    SyncRegularTemporary(TempPath);
  except
    FpUnlink(RawByteString(TempPath));
    raise;
  end;
  if LStatPath(Target, St) and not FpS_ISREG(St.st_mode) then
  begin
    FpUnlink(RawByteString(TempPath));
    raise ESshAdmin.CreateFmt('refusing to replace non-regular path: %s',
      [Target]);
  end;
  if FpRename(RawByteString(TempPath), RawByteString(Target)) <> 0 then
  begin
    FpUnlink(RawByteString(TempPath));
    raise ESshAdmin.CreateFmt('cannot atomically replace %s: %s',
      [Target, ErrnoText]);
  end;
  SyncParentDirectoryBestEffort(Target);
end;

procedure AtomicWrite(const Target, Data: string; Mode: TMode);
var
  TempPath: string;
begin
  TempPath := WriteTemporary(Target, Data, Mode);
  ReplaceWithTemporary(TempPath, Target);
end;

function LoadSmallFile(const Path: string; MaxSize: Int64): string;
var
  St: Stat;
  Fd, Flags, E: cint;
  Buf: array[0..4095] of byte;
  N: TSSize;
  OldLen: SizeInt;
begin
  Result := '';
  Flags := O_RDONLY or O_NONBLOCK;
  {$IF DEFINED(LINUX) OR DEFINED(BSD) OR DEFINED(DARWIN)}
  Flags := Flags or O_NOFOLLOW;
  {$ENDIF}
  repeat
    Fd := FpOpen(RawByteString(Path), Flags, 0);
    E := FpGetErrNo;
  until (Fd >= 0) or (E <> ESysEINTR);
  if Fd < 0 then
    raise ESshAdmin.CreateFmt('cannot open regular file %s: %s',
      [Path, SysErrorMessage(E)]);
  try
    St := Default(Stat);
    if (FpFStat(Fd, St) <> 0) or not FpS_ISREG(St.st_mode) then
      raise ESshAdmin.CreateFmt('not a regular file: %s', [Path]);
    if (St.st_size < 0) or (St.st_size > MaxSize) then
      raise ESshAdmin.CreateFmt('file is too large: %s', [Path]);
    repeat
      N := FpRead(Fd, PChar(@Buf[0]), SizeOf(Buf));
      E := FpGetErrNo;
      if N > 0 then
      begin
        if Length(Result) + N > MaxSize then
          raise ESshAdmin.CreateFmt('file is too large: %s', [Path]);
        OldLen := Length(Result);
        SetLength(Result, OldLen + N);
        Move(Buf[0], Result[OldLen + 1], N);
      end;
    until (N = 0) or ((N < 0) and (E <> ESysEINTR));
    if N < 0 then
      raise ESshAdmin.CreateFmt('cannot read file %s: %s',
        [Path, SysErrorMessage(E)]);
  finally
    FpClose(Fd);
  end;
  if Pos(#0, Result) <> 0 then
    raise ESshAdmin.CreateFmt('NUL byte in file: %s', [Path]);
end;

function IsSafeConfigToken(const S: string; AllowPercent: boolean): boolean;
var
  i: integer;
begin
  if (S = '') or ContainsControl(S) then
    Exit(False);
  for i := 1 to Length(S) do
    if not (S[i] in ['a'..'z', 'A'..'Z', '0'..'9', '/', '.', '_', '-',
      '+', ':', '[', ']', '*', '@']) and not (AllowPercent and (S[i] = '%')) then
      Exit(False);
  Result := True;
end;

function IsSafeExecutablePath(const S: string): boolean;
var
  i: integer;
begin
  // ForceCommand is passed to the login shell with `-c` by OpenSSH. Keep the
  // executable path shell-literal instead of accepting sshd_config tokens
  // such as '*', '[' or ']' which acquire a second meaning there.
  Result := (S <> '') and (S[1] = '/') and (not ContainsControl(S));
  if not Result then
    Exit;
  for i := 1 to Length(S) do
    if not (S[i] in ['a'..'z', 'A'..'Z', '0'..'9', '/', '.', '_', '-', '+']) then
      Exit(False);
end;

function FindTrustedExecutable(const Candidates: array of string;
  const TestOverride: string): string;
var
  i: integer;
  St: Stat;
  Candidate: string;
begin
  if TestingMode and (GetEnvironmentVariable(TestOverride) <> '') then
  begin
    Candidate := ExpandFileName(GetEnvironmentVariable(TestOverride));
    if (Candidate = '') or (Candidate[1] <> '/') then
      raise ESshAdmin.CreateFmt('%s must be an absolute path', [TestOverride]);
    if LStatPath(Candidate, St) and FpS_ISREG(St.st_mode) and
       (FpAccess(RawByteString(Candidate), X_OK) = 0) then
      Exit(Candidate);
    raise ESshAdmin.CreateFmt('invalid test executable in %s', [TestOverride]);
  end;
  for i := Low(Candidates) to High(Candidates) do
    if LStatPath(Candidates[i], St) and FpS_ISREG(St.st_mode) and
       (FpAccess(RawByteString(Candidates[i]), X_OK) = 0) and
       ((not ProductionRoot) or
        ((St.st_uid = 0) and ((St.st_mode and &22) = 0))) then
      Exit(Candidates[i]);
  Result := '';
end;

function SshdExecutable: string;
{$IFDEF SUPERTERM_TEST_BUILD}
var
  Expected: string;
{$ENDIF}
begin
  // SuperTerm supports the operating-system OpenSSH layout on GNU/Linux and
  // macOS.  An arbitrary locally compiled sshd can embed a different
  // _PATH_SSH_SYSTEM_RC which cannot be discovered through sshd -T; accepting
  // one would make the isolation claim unverifiable.
  Result := FindTrustedExecutable(
    // Prefer the canonical usrmerge path.  On those GNU/Linux systems
    // /usr/sbin is a symlink to /usr/bin and protected-ancestor validation
    // must not stop us before trying the real inode.  macOS falls through to
    // its native /usr/sbin/sshd.
    ['/usr/bin/sshd', '/usr/sbin/sshd'], 'SUPERTERM_TEST_SSHD');
  if Result = '' then
    raise ESshAdmin.Create('cannot find a trusted OpenSSH sshd executable');
  {$IFDEF SUPERTERM_TEST_BUILD}
  // Observation only: the isolated suite can prove which fixed system path
  // won without replacing or executing a path supplied by the expectation.
  Expected := GetEnvironmentVariable('SUPERTERM_TEST_EXPECT_SSHD');
  if (Expected <> '') and (Result <> Expected) then
    raise ESshAdmin.CreateFmt('selected sshd %s, expected %s',
      [Result, Expected]);
  {$ENDIF}
  CheckProtectedAncestors(Result);
end;

function SshKeygenExecutable: string;
begin
  Result := FindTrustedExecutable(
    ['/usr/bin/ssh-keygen', '/usr/local/bin/ssh-keygen',
     '/opt/homebrew/bin/ssh-keygen'], 'SUPERTERM_TEST_SSH_KEYGEN');
  if Result = '' then
    raise ESshAdmin.Create('cannot find a trusted ssh-keygen executable');
  CheckProtectedAncestors(Result);
end;

function SystemSshRcPath: string;
var
  Override: string;
begin
  // OpenSSH compiles _PATH_SSH_SYSTEM_RC from --sysconfdir.  The supported
  // operating-system binaries use these standard layouts.  The override is
  // compiled only into the isolated test executable so the fail-closed path
  // can be exercised without creating anything below /etc.
  Override := '';
  if TestingMode then
    Override := GetEnvironmentVariable('SUPERTERM_TEST_SYSTEM_SSHRC');
  if Override <> '' then
  begin
    if (Override[1] <> '/') or ContainsControl(Override) then
      raise ESshAdmin.Create(
        'SUPERTERM_TEST_SYSTEM_SSHRC must be an absolute safe path');
    Exit(ExcludeTrailingPathDelimiter(ExpandFileName(Override)));
  end;
  // Both supported system layouts compile OpenSSH with /etc/ssh as SSHDIR.
  Result := '/etc/ssh/sshrc';
end;

procedure RejectSystemSshRc;
var
  Path: string;
  St: Stat;
begin
  Path := SystemSshRcPath;
  // The file is absent by requirement, so protect every directory through
  // which it could be created between validation and an SSH login.  This is
  // the same root-owned/non-writable ancestor rule used for ForceCommand.
  CheckProtectedAncestors(Path);
  if LStatPath(Path, St) then
    raise ESshAdmin.CreateFmt(
      'refusing sshd because OpenSSH would execute the global rc file %s before ForceCommand',
      [Path]);
  if FpGetErrNo <> ESysENOENT then
    raise ESshAdmin.CreateFmt('cannot safely inspect OpenSSH global rc file %s: %s',
      [Path, ErrnoText]);
end;

function SelfExecutable: string;
var
  S, Found: string;
  St: Stat;
begin
  S := ParamStr(0);
  if Pos('/', S) = 0 then
  begin
    Found := FileSearch(S, GetEnvironmentVariable('PATH'), False);
    if Found <> '' then
      S := Found;
  end;
  S := ExpandFileName(S);
  if not IsSafeExecutablePath(S) then
    raise ESshAdmin.Create('SuperTerm executable must have a safe absolute path');
  if not LStatPath(S, St) or not FpS_ISREG(St.st_mode) or
     (FpAccess(RawByteString(S), X_OK) <> 0) then
    raise ESshAdmin.CreateFmt('SuperTerm executable is not a regular executable: %s', [S]);
  // The forced TUI can start local commands with the authenticated account's
  // configuration. It must never be a privilege-bearing executable, even in
  // an isolated/test root where ownership checks are intentionally relaxed.
  if (St.st_mode and (STAT_ISUID or STAT_ISGID)) <> 0 then
    raise ESshAdmin.CreateFmt(
      'SuperTerm executable must not have set-user-ID or set-group-ID bits: %s',
      [S]);
  if ProductionRoot and ((St.st_uid <> 0) or ((St.st_mode and &22) <> 0)) then
    raise ESshAdmin.CreateFmt('SuperTerm executable is not root-owned and protected: %s', [S]);
  if ProductionRoot and ((St.st_mode and &001) = 0) then
    raise ESshAdmin.CreateFmt('SuperTerm executable is not executable by SSH users: %s', [S]);
  CheckProtectedAncestors(S);
  Result := S;
end;

function DupArg(const S: string): PChar;
begin
  GetMem(Result, Length(S) + 1);
  if Length(S) > 0 then
    Move(S[1], Result^, Length(S));
  Result[Length(S)] := #0;
end;

// FPC 3.2.2's TProcess turns StrNew('') into nil, terminating argv at the
// empty argument.  ssh-keygen requires a real empty argv element for `-N ''`,
// so use the RTL's fork/exec/pipe primitives directly and preserve every
// argument byte-for-byte.  No shell is involved.
function RunCaptured(const Exe: string; const Args: array of string;
  out Output: string; out AExitCode: integer): boolean; overload;
const
  CAPTURE_LIMIT = 4 * 1024 * 1024;
  COMMAND_TIMEOUT_MS = 30000;
  COMMAND_POLL_MS = 100;
  COMMAND_POLL_ATTEMPTS = COMMAND_TIMEOUT_MS div COMMAND_POLL_MS;
  COMMAND_READ_BUDGET = 64 * 1024;
  KILL_REAP_POLL_MS = 10;
  KILL_REAP_ATTEMPTS = 2000 div KILL_REAP_POLL_MS;
var
  PipeFd: TFilDes;
  Argv: PPChar;
  Pid, Waited: TPid;
  Status, i, ArgCount, Flags, NullFd: cint;
  Buf: array[0..4095] of byte;
  N, Keep, OldLen: TSSize;
  E: cint;
  PollItem: TPollFD;
  Exited, PipeClosed, TimedOut: boolean;
  PollAttempts, ReadThisRound, TestPolls: integer;
  TestPollText: string;

  function KillAndReapCaptured: boolean;
  var
    ReapAttempt: integer;
  begin
    Result := False;
    if Pid <= 0 then
      Exit;
    // Kill the exact child even if it has not reached setsid yet; then kill
    // its group as well to cover descendants created after exec.
    FpKill(Pid, SIGKILL);
    FpKill(-Pid, SIGKILL);
    for ReapAttempt := 1 to KILL_REAP_ATTEMPTS do
    begin
      Waited := FpWaitPid(Pid, Status, WNOHANG);
      if Waited = Pid then
        Exit(True);
      if (Waited < 0) and (FpGetErrNo <> ESysEINTR) then
        Exit;
      if ReapAttempt < KILL_REAP_ATTEMPTS then
        Sleep(KILL_REAP_POLL_MS);
    end;
  end;
begin
  Output := '';
  AExitCode := -1;
  Status := 0;
  Pid := -1;
  Exited := False;
  PipeClosed := False;
  TimedOut := False;
  PipeFd[0] := -1;
  PipeFd[1] := -1;
  if FpPipe(PipeFd) <> 0 then
    raise ESshAdmin.CreateFmt('cannot create command pipe: %s', [ErrnoText]);
  ArgCount := Length(Args) + 1;
  GetMem(Argv, (ArgCount + 1) * SizeOf(Pointer));
  for i := 0 to ArgCount do
    Argv[i] := nil;
  try
    Argv[0] := DupArg(Exe);
    for i := 0 to High(Args) do
      Argv[i + 1] := DupArg(Args[i]);
    Pid := FpFork;
    if Pid < 0 then
      raise ESshAdmin.CreateFmt('cannot fork command: %s', [ErrnoText]);
    if Pid = 0 then
    begin
      FpClose(PipeFd[0]);
      // A bounded helper owns its own process group. On timeout the parent
      // can terminate only this exact command tree, never unrelated service
      // or test processes. stdin is deterministic and cannot inherit a TTY.
      if FpSetsid < 0 then
        FpExit(127);
      NullFd := FpOpen('/dev/null', O_RDONLY, 0);
      if NullFd < 0 then
        FpExit(127);
      if FpDup2(NullFd, 0) < 0 then
        FpExit(127);
      if NullFd > 2 then
        FpClose(NullFd);
      if (FpDup2(PipeFd[1], 1) < 0) or (FpDup2(PipeFd[1], 2) < 0) then
        FpExit(127);
      FpClose(PipeFd[1]);
      FpExecV(RawByteString(Exe), Argv);
      FpExit(127);
    end;
    FpClose(PipeFd[1]);
    PipeFd[1] := -1;
    if FpFcntl(PipeFd[0], F_SETFD, ST_FD_CLOEXEC) < 0 then
      raise ESshAdmin.CreateFmt('cannot protect command pipe: %s', [ErrnoText]);
    Flags := FpFcntl(PipeFd[0], F_GETFL, 0);
    if Flags < 0 then
      raise ESshAdmin.CreateFmt('cannot inspect command pipe: %s', [ErrnoText]);
    if FpFcntl(PipeFd[0], F_SETFL, Flags or O_NONBLOCK) < 0 then
      raise ESshAdmin.CreateFmt('cannot make command pipe nonblocking: %s',
        [ErrnoText]);
    PollAttempts := COMMAND_POLL_ATTEMPTS;
    TestPollText := GetEnvironmentVariable('SUPERTERM_TEST_COMMAND_POLLS');
    if TestingMode and TryStrToInt(TestPollText, TestPolls) and
       (TestPolls >= 1) and (TestPolls <= PollAttempts) then
      PollAttempts := TestPolls;
    repeat
      ReadThisRound := 0;
      repeat
      begin
        N := FpRead(PipeFd[0], PChar(@Buf[0]), SizeOf(Buf));
        E := FpGetErrNo;
        if N > 0 then
        begin
          Keep := N;
          if Length(Output) + Keep > CAPTURE_LIMIT then
            Keep := CAPTURE_LIMIT - Length(Output);
          if Keep > 0 then
          begin
            OldLen := Length(Output);
            SetLength(Output, OldLen + Keep);
            Move(Buf[0], Output[OldLen + 1], Keep);
          end;
          Inc(ReadThisRound, N);
          if ReadThisRound >= COMMAND_READ_BUDGET then
            Break;
          Continue;
        end;
        if N = 0 then
          PipeClosed := True;
        if (N < 0) and (E = ESysEINTR) then
          Continue;
        Break;
      end;
      until False;
      // Do not reap the process-group leader while a descendant still owns
      // the capture pipe.  Its unreaped PID is what keeps both the positive
      // PID and the private PGID unavailable for reuse; on timeout
      // KillAndReapCaptured may therefore still signal that exact group.
      // Reaping first and retaining only the number would make a later
      // kill(-Pid, ...) unsafe under PID churn.
      if PipeClosed and not Exited then
      begin
        repeat
          Waited := FpWaitPid(Pid, Status, WNOHANG);
        until (Waited >= 0) or (FpGetErrNo <> ESysEINTR);
        Exited := Waited = Pid;
      end;
      if Exited and PipeClosed then
        Break;
      if PollAttempts <= 0 then
      begin
        TimedOut := True;
        Exited := KillAndReapCaptured;
        Break;
      end;
      PollItem := Default(TPollFD);
      PollItem.fd := PipeFd[0];
      PollItem.events := POLLIN;
      Dec(PollAttempts);
      if PipeClosed then
        // poll(2) reports HUP immediately forever after EOF.  Preserve the
        // configured wall-clock bound for a helper which deliberately closes
        // stdout/stderr but continues running.
        Sleep(COMMAND_POLL_MS)
      else
        FpPoll(@PollItem, 1, COMMAND_POLL_MS);
    until False;
    if not Exited and not TimedOut then
    begin
      repeat
        Waited := FpWaitPid(Pid, Status, 0);
      until (Waited >= 0) or (FpGetErrNo <> ESysEINTR);
      Exited := Waited = Pid;
    end;
    FpClose(PipeFd[0]);
    PipeFd[0] := -1;
    if (not TimedOut) and Exited and WIfExited(Status) then
      AExitCode := WExitStatus(Status);
    Result := (not TimedOut) and (AExitCode = 0);
  finally
    if (Pid > 0) and not Exited then
      KillAndReapCaptured;
    if PipeFd[0] >= 0 then
      FpClose(PipeFd[0]);
    if PipeFd[1] >= 0 then
      FpClose(PipeFd[1]);
    for i := 0 to ArgCount - 1 do
      if Argv[i] <> nil then
        FreeMem(Argv[i]);
    FreeMem(Argv);
  end;
end;

function RunCaptured(const Exe: string; const Args: array of string;
  out Output: string): boolean; overload;
var
  IgnoredExitCode: integer;
begin
  Result := RunCaptured(Exe, Args, Output, IgnoredExitCode);
end;

function ParseBoolStrict(const S, Name: string): boolean;
var
  V: string;
begin
  V := LowerCase(Trim(S));
  if (V = '1') or (V = 'true') or (V = 'yes') or (V = 'on') then
    Exit(True);
  if (V = '0') or (V = 'false') or (V = 'no') or (V = 'off') then
    Exit(False);
  raise ESshAdmin.CreateFmt('invalid boolean for %s: %s', [Name, S]);
end;

function ValidPort(const S: string): boolean;
var
  V, i: integer;
begin
  if S = '' then
    Exit(False);
  for i := 1 to Length(S) do
    if not (S[i] in ['0'..'9']) then
      Exit(False);
  Result := TryStrToInt(S, V) and (V >= 1) and (V <= 65535);
end;

function ValidListen(const S: string): boolean;
var
  Host, Port: string;
  P, i: integer;
begin
  Result := False;
  if (S = '') or (Length(S) > 320) or ContainsControl(S) then
    Exit;
  if S[1] = '[' then
  begin
    P := Pos(']:', S);
    if (P <= 2) or (P + 2 > Length(S)) then
      Exit;
    Host := Copy(S, 2, P - 2);
    Port := Copy(S, P + 2, MaxInt);
    if Pos(':', Host) = 0 then
      Exit;
    for i := 1 to Length(Host) do
      if not (Host[i] in ['0'..'9', 'a'..'z', 'A'..'Z', ':', '.', '%',
        '_', '-']) then
        Exit;
  end
  else
  begin
    P := LastDelimiter(':', S);
    if (P <= 1) or (P = Length(S)) then
      Exit;
    Host := Copy(S, 1, P - 1);
    Port := Copy(S, P + 1, MaxInt);
    if Pos(':', Host) <> 0 then
      Exit;
    for i := 1 to Length(Host) do
      if not (Host[i] in ['0'..'9', 'a'..'z', 'A'..'Z', '.', '_', '-']) then
        Exit;
  end;
  Result := ValidPort(Port);
end;

procedure ParseListenList(const S: string; var Values: TListenScratch;
  out Count: integer);
var
  Parts: TStringList;
  i, j: integer;
  V: string;
begin
  Count := 0;
  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := ',';
    Parts.DelimitedText := S;
    if (Parts.Count = 0) or (Parts.Count > Length(Values)) then
      raise ESshAdmin.Create('listen must contain between 1 and 32 addresses');
    for i := 0 to Parts.Count - 1 do
    begin
      V := Trim(Parts[i]);
      if not ValidListen(V) then
        raise ESshAdmin.CreateFmt('invalid listen address (host:port required): %s', [V]);
      for j := 0 to Count - 1 do
        if SameText(Values[j], V) then
          raise ESshAdmin.CreateFmt('duplicate listen address: %s', [V]);
      Values[Count] := V;
      Inc(Count);
    end;
  finally
    Parts.Free;
  end;
end;

procedure LoadServerConfig(out Cfg: TSshServerConfig);
var
  Lines, Entries: TStringList;
  Content, S, NameS, ValueS, RawListen, V: string;
  TempListen: TListenScratch;
  Count, i, P, Version, SectionCount: integer;
  InServer: boolean;
begin
  Cfg := Default(TSshServerConfig);
  // Compatibility for an existing version-1 file which predates the three
  // optional authentication switches: retain its central-key-only policy.
  // Newly created files spell out the more convenient account defaults.
  Cfg.ManagedAuthorizedKeys := True;
  TempListen := Default(TListenScratch);
  CheckSafeRegular(IniPath, ProductionRoot, &22);
  Content := LoadSmallFile(IniPath, MAX_CONFIG_SIZE);
  Lines := TStringList.Create;
  Entries := TStringList.Create;
  try
    Lines.Text := Content;
    Entries.CaseSensitive := False;
    Entries.NameValueSeparator := '=';
    SectionCount := 0;
    InServer := False;
    for i := 0 to Lines.Count - 1 do
    begin
      S := Trim(Lines[i]);
      if (S = '') or (S[1] = '#') or (S[1] = ';') then
        Continue;
      if (S[1] = '[') and (S[Length(S)] = ']') then
      begin
        Inc(SectionCount);
        InServer := SameText(Trim(Copy(S, 2, Length(S) - 2)), 'server');
        if (not InServer) or (SectionCount <> 1) then
          raise ESshAdmin.Create('server.ini must contain exactly one [server] section');
        Continue;
      end;
      if not InServer then
        raise ESshAdmin.CreateFmt('setting outside [server]: %s', [S]);
      P := Pos('=', S);
      if P <= 1 then
        raise ESshAdmin.CreateFmt('invalid server.ini line: %s', [S]);
      NameS := LowerCase(Trim(Copy(S, 1, P - 1)));
      ValueS := Trim(Copy(S, P + 1, MaxInt));
      if (NameS <> 'config_version') and (NameS <> 'listen') and
         (NameS <> 'allow_root') and
         (NameS <> 'password_authentication') and
         (NameS <> 'managed_authorized_keys') and
         (NameS <> 'user_authorized_keys') then
        raise ESshAdmin.CreateFmt('unknown server.ini key: %s', [NameS]);
      if Entries.IndexOfName(NameS) >= 0 then
        raise ESshAdmin.CreateFmt('duplicate server.ini key: %s', [NameS]);
      Entries.Add(NameS + '=' + ValueS);
    end;
    if (SectionCount <> 1) or (Entries.IndexOfName('config_version') < 0) or
       (Entries.IndexOfName('listen') < 0) or
       (Entries.IndexOfName('allow_root') < 0) then
      raise ESshAdmin.Create('server.ini requires config_version, listen and allow_root');
    V := Entries.Values['config_version'];
    if not TryStrToInt(V, Version) or (Version <> 1) then
      raise ESshAdmin.CreateFmt('unsupported config_version: %s', [V]);
    RawListen := Entries.Values['listen'];
    ParseListenList(RawListen, TempListen, Count);
    SetLength(Cfg.Listen, Count);
    for i := 0 to Count - 1 do
      Cfg.Listen[i] := TempListen[i];
    Cfg.AllowRoot := ParseBoolStrict(Entries.Values['allow_root'], 'allow_root');
    if Entries.IndexOfName('password_authentication') >= 0 then
      Cfg.PasswordAuthentication := ParseBoolStrict(
        Entries.Values['password_authentication'], 'password_authentication');
    if Entries.IndexOfName('managed_authorized_keys') >= 0 then
      Cfg.ManagedAuthorizedKeys := ParseBoolStrict(
        Entries.Values['managed_authorized_keys'], 'managed_authorized_keys');
    if Entries.IndexOfName('user_authorized_keys') >= 0 then
      Cfg.UserAuthorizedKeys := ParseBoolStrict(
        Entries.Values['user_authorized_keys'], 'user_authorized_keys');
    if not (Cfg.PasswordAuthentication or Cfg.ManagedAuthorizedKeys or
            Cfg.UserAuthorizedKeys) then
      raise ESshAdmin.Create('at least one SSH authentication method must be enabled');
    if Cfg.AllowRoot and not (Cfg.ManagedAuthorizedKeys or
                              Cfg.UserAuthorizedKeys) then
      raise ESshAdmin.Create(
        'allow_root requires managed_authorized_keys or user_authorized_keys');
  finally
    Entries.Free;
    Lines.Free;
  end;
end;

function BuildGeneratedConfig(const Cfg: TSshServerConfig): string;
var
  i: integer;
  RootPermit, SelfPath, AuthorizedFiles, PubkeyValue, PasswordValue,
    AuthenticationMethods: string;
  HasPublicKeys: boolean;
begin
  if not IsSafeConfigToken(SshdRoot, False) then
    raise ESshAdmin.Create('the SSH state path contains characters unsafe for sshd_config');
  SelfPath := SelfExecutable;
  if Cfg.AllowRoot then
    RootPermit := 'prohibit-password'
  else
    RootPermit := 'no';
  HasPublicKeys := Cfg.ManagedAuthorizedKeys or Cfg.UserAuthorizedKeys;
  if not (HasPublicKeys or Cfg.PasswordAuthentication) then
    raise ESshAdmin.Create('at least one SSH authentication method must be enabled');
  if Cfg.AllowRoot and not HasPublicKeys then
    raise ESshAdmin.Create(
      'allow_root requires managed_authorized_keys or user_authorized_keys');

  AuthorizedFiles := '';
  if Cfg.ManagedAuthorizedKeys then
    AuthorizedFiles := AuthorizedKeysDir + '/%u';
  if Cfg.UserAuthorizedKeys then
  begin
    if AuthorizedFiles <> '' then
      AuthorizedFiles := AuthorizedFiles + ' ';
    AuthorizedFiles := AuthorizedFiles + '.ssh/authorized_keys';
  end;
  if AuthorizedFiles = '' then
    AuthorizedFiles := 'none';
  if HasPublicKeys then
    PubkeyValue := 'yes'
  else
    PubkeyValue := 'no';
  if Cfg.PasswordAuthentication then
    PasswordValue := 'yes'
  else
    PasswordValue := 'no';
  if HasPublicKeys and Cfg.PasswordAuthentication then
    AuthenticationMethods := 'any'
  else if HasPublicKeys then
    AuthenticationMethods := 'publickey'
  else
    AuthenticationMethods := 'password';
  Result :=
    '# Generated by SuperTerm. Edit server.ini, never this file.' + LineEnding +
    'AddressFamily any' + LineEnding;
  for i := 0 to High(Cfg.Listen) do
    Result := Result + 'ListenAddress ' + Cfg.Listen[i] + LineEnding;
  Result := Result +
    'HostKey ' + HostKeyPath + LineEnding +
    'PidFile ' + PidFilePath + LineEnding +
    'AuthorizedKeysFile ' + AuthorizedFiles + LineEnding +
    'StrictModes yes' + LineEnding +
    'PubkeyAuthentication ' + PubkeyValue + LineEnding +
    'AuthenticationMethods ' + AuthenticationMethods + LineEnding +
    'PasswordAuthentication ' + PasswordValue + LineEnding +
    'KbdInteractiveAuthentication no' + LineEnding +
    // PAM supplies the normal account password path when enabled and retains
    // account expiry/lock plus session policy for every accepted key login.
    'UsePAM yes' + LineEnding +
    'GSSAPIAuthentication no' + LineEnding +
    'HostbasedAuthentication no' + LineEnding +
    'PermitEmptyPasswords no' + LineEnding +
    'PermitRootLogin ' + RootPermit + LineEnding +
    'PermitTTY yes' + LineEnding +
    'MaxSessions 1' + LineEnding +
    'MaxAuthTries 3' + LineEnding +
    'LoginGraceTime 30' + LineEnding +
    'MaxStartups 10:30:30' + LineEnding +
    'ClientAliveInterval 30' + LineEnding +
    'ClientAliveCountMax 3' + LineEnding +
    'TCPKeepAlive yes' + LineEnding +
    'DisableForwarding yes' + LineEnding +
    'AllowAgentForwarding no' + LineEnding +
    'AllowTcpForwarding no' + LineEnding +
    'AllowStreamLocalForwarding no' + LineEnding +
    'GatewayPorts no' + LineEnding +
    'X11Forwarding no' + LineEnding +
    'PermitTunnel no' + LineEnding +
    'PermitUserEnvironment no' + LineEnding +
    'PermitUserRC no' + LineEnding +
    'UseDNS no' + LineEnding +
    'PrintMotd no' + LineEnding +
    'LogLevel VERBOSE' + LineEnding +
    'SyslogFacility AUTH' + LineEnding +
    'ForceCommand ' + SelfPath + ' --ssh-entry' + LineEnding;
end;

function EffectiveSetting(const Dump, Key: string; out Value: string): boolean;
var
  Lines: TStringList;
  I, P, Count: integer;
  S, FoundKey: string;
begin
  Result := False;
  Value := '';
  Count := 0;
  Lines := TStringList.Create;
  try
    Lines.Text := Dump;
    for I := 0 to Lines.Count - 1 do
    begin
      S := Trim(Lines[I]);
      P := 1;
      while (P <= Length(S)) and not (S[P] in [' ', #9]) do
        Inc(P);
      FoundKey := Copy(S, 1, P - 1);
      if not SameText(FoundKey, Key) then
        Continue;
      while (P <= Length(S)) and (S[P] in [' ', #9]) do
        Inc(P);
      Inc(Count);
      Value := Trim(Copy(S, P, MaxInt));
    end;
    Result := Count = 1;
  finally
    Lines.Free;
  end;
end;

function EffectiveSettingCount(const Dump, Key: string): integer;
var
  Lines: TStringList;
  I, P: integer;
  S: string;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    Lines.Text := Dump;
    for I := 0 to Lines.Count - 1 do
    begin
      S := Trim(Lines[I]);
      P := 1;
      while (P <= Length(S)) and not (S[P] in [' ', #9]) do
        Inc(P);
      if SameText(Copy(S, 1, P - 1), Key) then
        Inc(Result);
    end;
  finally
    Lines.Free;
  end;
end;

procedure RequireNoEffectiveSetting(const Dump, Key: string);
begin
  if EffectiveSettingCount(Dump, Key) <> 0 then
    raise ESshAdmin.CreateFmt('sshd -T returned a forbidden %s directive',
      [Key]);
end;

procedure RejectConditionalConfig(const Candidate: string);
var
  Data, S, Token: string;
  Lines: TStringList;
  I, P: integer;
begin
  // `sshd -T` without one particular connection context reports only global
  // values.  A Match block is applied later for the real user/address, and an
  // Include can hide such a block in another file.  SuperTerm generates
  // neither, so accepting them in its disposable artefact has no legitimate
  // compatibility purpose.
  Data := LoadSmallFile(Candidate, MAX_CONFIG_SIZE);
  Lines := TStringList.Create;
  try
    Lines.Text := Data;
    for I := 0 to Lines.Count - 1 do
    begin
      S := Trim(Lines[I]);
      if (S = '') or (S[1] = '#') then
        Continue;
      P := 1;
      while (P <= Length(S)) and not (S[P] in [' ', #9]) do
        Inc(P);
      Token := Copy(S, 1, P - 1);
      if SameText(Token, 'match') or SameText(Token, 'include') then
        raise ESshAdmin.CreateFmt(
          'forbidden conditional sshd directive in generated configuration: %s',
          [Token]);
    end;
  finally
    Lines.Free;
  end;
end;

procedure RequireEffectiveSetting(const Dump, Key, Expected: string;
  CaseSensitive: boolean = False);
var
  Actual: string;
  Matches: boolean;
begin
  if not EffectiveSetting(Dump, Key, Actual) then
    raise ESshAdmin.CreateFmt(
      'sshd -T did not return exactly one %s directive', [Key]);
  if CaseSensitive then
    Matches := Actual = Expected
  else
    Matches := SameText(Actual, Expected);
  if not Matches then
    raise ESshAdmin.CreateFmt('sshd -T returned unsafe %s value: %s',
      [Key, Actual]);
end;

procedure ValidateGenerated(const Candidate: string; ExpectedRoot,
  ExpectedPassword, ExpectedManagedKeys, ExpectedUserKeys: integer);
var
  Output, RootValue, Sshd, PasswordValue, PubkeyValue, AuthMethods,
    AuthorizedFiles, ExpectedAuthMethods: string;
  PasswordEnabled, PubkeyEnabled, ManagedKeysEnabled,
    UserKeysEnabled: boolean;
begin
  PasswordValue := '';
  PubkeyValue := '';
  AuthMethods := '';
  AuthorizedFiles := '';
  RejectConditionalConfig(Candidate);
  Sshd := SshdExecutable;
  RejectSystemSshRc;
  if not RunCaptured(Sshd, ['-t', '-f', Candidate], Output) then
    raise ESshAdmin.CreateFmt('sshd rejected generated configuration (-t): %s',
      [Trim(Output)]);
  // OpenSSH may return success for a directive compiled out on this host
  // while printing "Unsupported option".  A dedicated security service must
  // never silently start with a weaker effective configuration.
  if Trim(Output) <> '' then
    raise ESshAdmin.CreateFmt('sshd reported configuration diagnostics (-t): %s',
      [Trim(Output)]);
  if not RunCaptured(Sshd, ['-T', '-f', Candidate], Output) then
    raise ESshAdmin.CreateFmt('sshd rejected generated configuration (-T): %s',
      [Trim(Output)]);
  if not EffectiveSetting(Output, 'passwordauthentication', PasswordValue) or
     (not SameText(PasswordValue, 'yes') and
      not SameText(PasswordValue, 'no')) then
    raise ESshAdmin.Create(
      'sshd -T returned an unsafe PasswordAuthentication value');
  PasswordEnabled := SameText(PasswordValue, 'yes');
  RequireEffectiveSetting(Output, 'kbdinteractiveauthentication', 'no');
  if not EffectiveSetting(Output, 'pubkeyauthentication', PubkeyValue) or
     (not SameText(PubkeyValue, 'yes') and
      not SameText(PubkeyValue, 'no')) then
    raise ESshAdmin.Create(
      'sshd -T returned an unsafe PubkeyAuthentication value');
  PubkeyEnabled := SameText(PubkeyValue, 'yes');
  if not EffectiveSetting(Output, 'authorizedkeysfile', AuthorizedFiles) then
  begin
    // OpenSSH stores `AuthorizedKeysFile none` as an empty path list and
    // consequently omits the directive from `sshd -T`.  That representation
    // is coherent only while public-key authentication itself is disabled.
    if (EffectiveSettingCount(Output, 'authorizedkeysfile') = 0) and
       (not PubkeyEnabled) then
      AuthorizedFiles := 'none'
    else
      raise ESshAdmin.Create(
        'sshd -T did not return exactly one AuthorizedKeysFile directive');
  end;
  ManagedKeysEnabled := False;
  UserKeysEnabled := False;
  if AuthorizedFiles = AuthorizedKeysDir + '/%u' then
    ManagedKeysEnabled := True
  else if AuthorizedFiles = '.ssh/authorized_keys' then
    UserKeysEnabled := True
  else if AuthorizedFiles = AuthorizedKeysDir + '/%u .ssh/authorized_keys' then
  begin
    ManagedKeysEnabled := True;
    UserKeysEnabled := True;
  end
  else if not SameText(AuthorizedFiles, 'none') then
    raise ESshAdmin.CreateFmt(
      'sshd -T returned unsafe AuthorizedKeysFile value: %s',
      [AuthorizedFiles]);
  if PubkeyEnabled <> (ManagedKeysEnabled or UserKeysEnabled) then
    raise ESshAdmin.Create(
      'sshd -T returned an incoherent public-key authentication policy');
  if not (PasswordEnabled or PubkeyEnabled) then
    raise ESshAdmin.Create('accepted SSH configuration has no authentication method');
  if PasswordEnabled and PubkeyEnabled then
    ExpectedAuthMethods := 'any'
  else if PubkeyEnabled then
    ExpectedAuthMethods := 'publickey'
  else
    ExpectedAuthMethods := 'password';
  if not EffectiveSetting(Output, 'authenticationmethods', AuthMethods) or
     not SameText(AuthMethods, ExpectedAuthMethods) then
    raise ESshAdmin.CreateFmt(
      'sshd -T returned unsafe AuthenticationMethods value: %s',
      [AuthMethods]);
  if (ExpectedPassword >= 0) and
     (PasswordEnabled <> (ExpectedPassword > 0)) then
    raise ESshAdmin.Create('sshd -T did not preserve password_authentication');
  if (ExpectedManagedKeys >= 0) and
     (ManagedKeysEnabled <> (ExpectedManagedKeys > 0)) then
    raise ESshAdmin.Create('sshd -T did not preserve managed_authorized_keys');
  if (ExpectedUserKeys >= 0) and
     (UserKeysEnabled <> (ExpectedUserKeys > 0)) then
    raise ESshAdmin.Create('sshd -T did not preserve user_authorized_keys');
  RequireEffectiveSetting(Output, 'strictmodes', 'yes');
  RequireEffectiveSetting(Output, 'usepam', 'yes');
  RequireEffectiveSetting(Output, 'gssapiauthentication', 'no');
  RequireEffectiveSetting(Output, 'hostbasedauthentication', 'no');
  RequireEffectiveSetting(Output, 'permitemptypasswords', 'no');
  RequireEffectiveSetting(Output, 'disableforwarding', 'yes');
  RequireEffectiveSetting(Output, 'allowagentforwarding', 'no');
  RequireEffectiveSetting(Output, 'allowtcpforwarding', 'no');
  RequireEffectiveSetting(Output, 'allowstreamlocalforwarding', 'no');
  RequireEffectiveSetting(Output, 'gatewayports', 'no');
  RequireEffectiveSetting(Output, 'x11forwarding', 'no');
  RequireEffectiveSetting(Output, 'permittunnel', 'no');
  RequireEffectiveSetting(Output, 'permituserenvironment', 'no');
  RequireEffectiveSetting(Output, 'permituserrc', 'no');
  RequireEffectiveSetting(Output, 'permittty', 'yes');
  RequireEffectiveSetting(Output, 'maxsessions', '1');
  RequireEffectiveSetting(Output, 'authorizedkeyscommand', 'none');
  RequireEffectiveSetting(Output, 'authorizedkeyscommanduser', 'none');
  RequireEffectiveSetting(Output, 'trustedusercakeys', 'none');
  RequireEffectiveSetting(Output, 'banner', 'none');
  RequireEffectiveSetting(Output, 'chrootdirectory', 'none');
  RequireNoEffectiveSetting(Output, 'acceptenv');
  RequireNoEffectiveSetting(Output, 'setenv');
  RequireNoEffectiveSetting(Output, 'subsystem');
  RequireEffectiveSetting(Output, 'forcecommand',
    SelfExecutable + ' --ssh-entry', True);
  if not EffectiveSetting(Output, 'permitrootlogin', RootValue) then
    raise ESshAdmin.Create(
      'sshd -T did not return exactly one PermitRootLogin directive');
  if ExpectedRoot > 0 then
  begin
    if (not SameText(RootValue, 'prohibit-password')) and
       (not SameText(RootValue, 'without-password')) then
      raise ESshAdmin.Create('sshd -T did not preserve public-key-only root login');
  end
  else if ExpectedRoot = 0 then
    RequireEffectiveSetting(Output, 'permitrootlogin', 'no');
  if ExpectedRoot < 0 then
    if (not SameText(RootValue, 'no')) and
       (not SameText(RootValue, 'prohibit-password')) and
       (not SameText(RootValue, 'without-password')) then
      raise ESshAdmin.Create('accepted config has an unsafe PermitRootLogin value');
  if (not SameText(RootValue, 'no')) and not PubkeyEnabled then
    raise ESshAdmin.Create(
      'accepted root login requires a public-key authentication source');
end;

procedure VerifyHostKey(FixPublic: boolean);
var
  Output, PublicLine, Existing, TempPath: string;
  St: Stat;
begin
  CheckSafeRegular(HostKeyPath, ProductionRoot, &177);
  if FixPublic and (FpChmod(RawByteString(HostKeyPath), &600) <> 0) then
    raise ESshAdmin.CreateFmt('cannot protect host private key: %s', [ErrnoText]);
  if not RunCaptured(SshKeygenExecutable,
    ['-l', '-E', 'sha256', '-f', HostKeyPath], Output) then
    raise ESshAdmin.CreateFmt('invalid host private key: %s', [Trim(Output)]);
  if not RunCaptured(SshKeygenExecutable, ['-y', '-f', HostKeyPath], PublicLine) then
    raise ESshAdmin.CreateFmt('cannot derive host public key: %s', [Trim(PublicLine)]);
  PublicLine := Trim(PublicLine);
  // ssh-keygen -l also prints the key comment.  A non-Ed25519 key whose
  // comment contains "(ED25519)" must not pass type validation; -y starts
  // with the actual wire key type and produces exactly one public-key line.
  if (Pos(#10, PublicLine) <> 0) or (Pos(#13, PublicLine) <> 0) or
     (Pos('ssh-ed25519 ', PublicLine) <> 1) or
     (Length(PublicLine) <= Length('ssh-ed25519 ')) then
    raise ESshAdmin.Create('the existing host key is not Ed25519');
  PublicLine := PublicLine + LineEnding;
  if LStatPath(HostKeyPath + '.pub', St) then
  begin
    if not FpS_ISREG(St.st_mode) then
      raise ESshAdmin.Create('host public key path is not a regular file');
    Existing := LoadSmallFile(HostKeyPath + '.pub', MAX_KEY_LINE);
  end
  else
    Existing := '';
  if Trim(Existing) <> Trim(PublicLine) then
  begin
    if not FixPublic then
      raise ESshAdmin.Create('host public key does not match the private key');
    TempPath := WriteTemporary(HostKeyPath + '.pub', PublicLine, &644);
    ReplaceWithTemporary(TempPath, HostKeyPath + '.pub');
  end;
  if not LStatPath(HostKeyPath + '.pub', St) then
    raise ESshAdmin.Create('host public key is missing');
  CheckSafeRegular(HostKeyPath + '.pub', ProductionRoot, &22);
end;

procedure EnsureHostKey;
var
  St: Stat;
  TempBase, Output: string;
begin
  if LStatPath(HostKeyPath, St) then
  begin
    if not FpS_ISREG(St.st_mode) then
      raise ESshAdmin.Create('host private key path is not a regular file');
    VerifyHostKey(True);
    Exit;
  end;
  if FpGetErrNo <> ESysENOENT then
    raise ESshAdmin.CreateFmt('cannot inspect host key: %s', [ErrnoText]);
  TempBase := UniqueTempName(HostKeyPath, 'keygen');
  try
    // ssh-keygen may create either half before returning an error or timing
    // out. Own both temporary names before invoking it so every failure path
    // removes private material as well as the public half.
    if not RunCaptured(SshKeygenExecutable,
      ['-q', '-t', 'ed25519', '-N', '', '-f', TempBase], Output) then
      raise ESshAdmin.CreateFmt('cannot generate Ed25519 host key: %s',
        [Trim(Output)]);
    if FpChmod(RawByteString(TempBase), &600) <> 0 then
      raise ESshAdmin.CreateFmt('cannot protect generated host key: %s', [ErrnoText]);
    if FpChmod(RawByteString(TempBase + '.pub'), &644) <> 0 then
      raise ESshAdmin.CreateFmt('cannot protect generated public key: %s', [ErrnoText]);
    if LStatPath(HostKeyPath, St) then
      raise ESshAdmin.Create('host key appeared concurrently; refusing to overwrite it');
    if LStatPath(HostKeyPath + '.pub', St) and not FpS_ISREG(St.st_mode) then
      raise ESshAdmin.Create('host public key path is not a regular file');
    ReplaceWithTemporary(TempBase, HostKeyPath);
    ReplaceWithTemporary(TempBase + '.pub', HostKeyPath + '.pub');
  finally
    FpUnlink(RawByteString(TempBase));
    FpUnlink(RawByteString(TempBase + '.pub'));
  end;
  VerifyHostKey(True);
end;

function AdminLockPollAttempts: integer;
var
  S: string;
  V: integer;
begin
  Result := ADMIN_LOCK_POLL_ATTEMPTS;
  // A short deterministic bound is useful only to fault-inject a held lock.
  // Production always retains the full 30-second administrative deadline.
  if not TestingMode then
    Exit;
  S := GetEnvironmentVariable('SUPERTERM_TEST_ADMIN_LOCK_POLLS');
  if (S <> '') and TryStrToInt(S, V) and (V >= 1) and
     (V <= ADMIN_LOCK_POLL_ATTEMPTS) then
    Result := V;
end;

procedure EnsureDefaultIni;
var
  St: Stat;
begin
  if LStatPath(IniPath, St) then
  begin
    if not FpS_ISREG(St.st_mode) then
      raise ESshAdmin.Create('server.ini is not a regular file');
    CheckSafeRegular(IniPath, ProductionRoot, &22);
    Exit;
  end;
  if FpGetErrNo <> ESysENOENT then
    raise ESshAdmin.CreateFmt('cannot inspect server.ini: %s', [ErrnoText]);
  AtomicWrite(IniPath, DEFAULT_SERVER_INI, &644);
end;

function AcquireAdminLock: cint;
var
  Flags, E, Attempt: cint;
  St: Stat;
begin
  Flags := O_RDWR or O_CREAT;
  {$IF DEFINED(LINUX) OR DEFINED(BSD) OR DEFINED(DARWIN)}
  Flags := Flags or O_NOFOLLOW;
  {$ENDIF}
  Result := FpOpen(RawByteString(RootPath('.admin.lock')), Flags, &600);
  if Result < 0 then
    raise ESshAdmin.CreateFmt('cannot open administration lock: %s', [ErrnoText]);
  St := Default(Stat);
  if (FpFStat(Result, St) <> 0) or not FpS_ISREG(St.st_mode) or
     (St.st_uid <> FpGetEUid) or ((St.st_mode and &22) <> 0) then
  begin
    FpClose(Result);
    raise ESshAdmin.Create('SSH administration lock is not a protected regular file');
  end;
  if FpFcntl(Result, F_SETFD, ST_FD_CLOEXEC) < 0 then
  begin
    E := FpGetErrNo;
    FpClose(Result);
    raise ESshAdmin.CreateFmt('cannot protect SSH administration lock: %s',
      [SysErrorMessage(E)]);
  end;
  E := 0;
  for Attempt := 1 to AdminLockPollAttempts do
  begin
    if FpFlock(Result, LOCK_EX or LOCK_NB) = 0 then
      Exit;
    E := FpGetErrNo;
    if E = ESysEINTR then
      Continue;
    if (E <> ESysEAGAIN) and (E <> ESysEWOULDBLOCK) then
      Break;
    if Attempt < AdminLockPollAttempts then
      Sleep(ADMIN_LOCK_POLL_MS);
  end;
  FpClose(Result);
  if (E = ESysEAGAIN) or (E = ESysEWOULDBLOCK) then
    raise ESshAdmin.Create('timed out waiting for SSH administration lock');
  raise ESshAdmin.CreateFmt('cannot lock SSH administration: %s',
    [SysErrorMessage(E)]);
end;

procedure ReleaseAdminLock(Fd: cint);
begin
  if Fd >= 0 then
  begin
    FpFlock(Fd, LOCK_UN);
    FpClose(Fd);
  end;
end;

procedure UpdateGeneratedConfig;
var
  Cfg: TSshServerConfig;
  Content, Candidate: string;
begin
  LoadServerConfig(Cfg);
  VerifyHostKey(False);
  Content := BuildGeneratedConfig(Cfg);
  Candidate := WriteTemporary(GeneratedConfigPath, Content, &600);
  try
    ValidateGenerated(Candidate, Ord(Cfg.AllowRoot),
      Ord(Cfg.PasswordAuthentication), Ord(Cfg.ManagedAuthorizedKeys),
      Ord(Cfg.UserAuthorizedKeys));
    ReplaceWithTemporary(Candidate, GeneratedConfigPath);
    Candidate := '';
  finally
    if Candidate <> '' then
      FpUnlink(RawByteString(Candidate));
  end;
end;

function SystemdDescriptor(const SuperTerm: string): string;
begin
  Result :=
    '# ' + MANAGED_SERVICE_MARKER + LineEnding +
    '# Generated by SuperTerm; edit server.ini, not this file.' + LineEnding +
    '[Unit]' + LineEnding +
    'Description=SuperTerm dedicated SSH server' + LineEnding +
    'After=network.target' + LineEnding + LineEnding +
    '[Service]' + LineEnding +
    'Type=simple' + LineEnding +
    // The wrapper performs -t and -T with the currently installed OpenSSH,
    // then execs sshd in-place. There is no resident extra supervisor, while
    // an OS/OpenSSH upgrade can never silently weaken an accepted policy.
    'ExecStart=' + SuperTerm + ' ssh-server run' + LineEnding +
    'Restart=on-failure' + LineEnding +
    'RestartSec=2s' + LineEnding +
    // Match OpenSSH's packaged service: restarting the listener must not
    // kill its established clients or SuperTerm's detached session daemons.
    'KillMode=process' + LineEnding + LineEnding +
    '[Install]' + LineEnding +
    'WantedBy=multi-user.target' + LineEnding;
end;

function XmlEscape(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
  Result := StringReplace(Result, '''', '&apos;', [rfReplaceAll]);
end;

function LaunchdDescriptor(const SuperTerm: string): string;
begin
  Result :=
    '<?xml version="1.0" encoding="UTF-8"?>' + LineEnding +
    '<!-- ' + MANAGED_SERVICE_MARKER + ' -->' + LineEnding +
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ' +
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">' + LineEnding +
    '<plist version="1.0">' + LineEnding +
    '<dict>' + LineEnding +
    '  <key>Label</key><string>' + LAUNCHD_LABEL + '</string>' + LineEnding +
    '  <key>ProgramArguments</key>' + LineEnding +
    '  <array>' + LineEnding +
    '    <string>' + XmlEscape(SuperTerm) + '</string>' + LineEnding +
    '    <string>ssh-server</string>' + LineEnding +
    '    <string>run</string>' + LineEnding +
    '  </array>' + LineEnding +
    '  <key>RunAtLoad</key><true/>' + LineEnding +
    '  <key>KeepAlive</key><true/>' + LineEnding +
    // launchd otherwise kills every remaining process in the listener's
    // process group when that listener is restarted.  Preserve established
    // SSH clients just as systemd's KillMode=process does; detached SuperTerm
    // daemons already own separate sessions/process groups.
    '  <key>AbandonProcessGroup</key><true/>' + LineEnding +
    '  <key>ThrottleInterval</key><integer>2</integer>' + LineEnding +
    '</dict>' + LineEnding +
    '</plist>' + LineEnding;
end;

function ExpectedServiceDescriptor: string;
var
  SuperTerm: string;
begin
  // Generation and exact-current verification share one path. Uninstallation
  // also recognises earlier marked SuperTerm descriptors below so a package
  // update cannot strand the service merely because harmless fields evolved.
  SuperTerm := SelfExecutable;
  {$IFDEF DARWIN}
  Result := LaunchdDescriptor(SuperTerm);
  {$ELSE}
  Result := SystemdDescriptor(SuperTerm);
  {$ENDIF}
end;

function DescriptorHasExactLine(const Data, Expected: string): boolean;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := Data;
    Result := Lines.IndexOf(Expected) >= 0;
  finally
    Lines.Free;
  end;
end;

function LiteralCount(const Data, Needle: string): integer;
var
  AtPos, StartPos: SizeInt;
begin
  Result := 0;
  if Needle = '' then
    Exit;
  StartPos := 1;
  repeat
    AtPos := Pos(Needle, Data, StartPos);
    if AtPos = 0 then
      Break;
    Inc(Result);
    StartPos := AtPos + Length(Needle);
  until StartPos > Length(Data);
end;

function IsRecognizedServiceDescriptor(const Data: string): boolean;
var
  SuperTerm: string;
begin
  // The exact current form is the common path. The stable marker plus the
  // invariant service identity/entry command admits a descriptor written by
  // an older SuperTerm release after harmless packaging fields evolve. This
  // deliberately does not accept the filename or a generic "generated by"
  // comment as proof of ownership.
  if Data = ExpectedServiceDescriptor then
    Exit(True);
  SuperTerm := SelfExecutable;
  {$IFDEF DARWIN}
  Result :=
    (LiteralCount(Data, '<!-- ' + MANAGED_SERVICE_MARKER + ' -->') = 1) and
    (LiteralCount(Data, '<key>Label</key><string>' + LAUNCHD_LABEL +
      '</string>') = 1) and
    (LiteralCount(Data, '<string>' + XmlEscape(SuperTerm) + '</string>') = 1) and
    (LiteralCount(Data, '<string>ssh-server</string>') = 1) and
    (LiteralCount(Data, '<string>run</string>') = 1) and
    (LiteralCount(Data, '<key>AbandonProcessGroup</key><true/>') = 1);
  {$ELSE}
  Result :=
    DescriptorHasExactLine(Data, '# ' + MANAGED_SERVICE_MARKER) and
    DescriptorHasExactLine(Data, '[Service]') and
    DescriptorHasExactLine(Data,
      'ExecStart=' + SuperTerm + ' ssh-server run') and
    DescriptorHasExactLine(Data, 'KillMode=process');
  {$ENDIF}
end;

function ServiceDescriptorPath: string;
begin
  if not ProductionRoot then
  begin
    {$IFDEF DARWIN}
    Result := RootPath('service/org.superterm.sshd.plist');
    {$ELSE}
    Result := RootPath('service/superterm-sshd.service');
    {$ENDIF}
    Exit;
  end;
  {$IFDEF DARWIN}
  Result := '/Library/LaunchDaemons/org.superterm.sshd.plist';
  {$ELSE}
  Result := '/etc/systemd/system/' + SERVICE_NAME;
  {$ENDIF}
end;

procedure InstallServiceDescriptor;
var
  Path, Parent, Content: string;
begin
  Path := ServiceDescriptorPath;
  Parent := ExtractFileDir(Path);
  if not ProductionRoot then
  begin
    if not ForceDirectories(Parent) then
      raise ESshAdmin.CreateFmt('cannot create test service directory: %s', [Parent]);
  end
  else
    CheckSafeDirectory(Parent, True);
  Content := ExpectedServiceDescriptor;
  AtomicWrite(Path, Content, &644);
end;

function FindSystemctl: string;
begin
  Result := FindTrustedExecutable(['/usr/bin/systemctl', '/bin/systemctl'],
    'SUPERTERM_TEST_SYSTEMCTL');
end;

function FindLaunchctl: string;
begin
  Result := FindTrustedExecutable(['/bin/launchctl', '/usr/bin/launchctl'],
    'SUPERTERM_TEST_LAUNCHCTL');
end;

{$IFDEF DARWIN}
function QueryLaunchdLoaded(const Tool: string; out Loaded: boolean;
  out Output: string): boolean;
var
  ExitCode: integer;
begin
  Loaded := False;
  if RunCaptured(Tool, ['print', 'system/' + LAUNCHD_LABEL], Output,
    ExitCode) then
  begin
    Loaded := True;
    Exit(True);
  end;
  // `launchctl print` output is diagnostic-only and may change or be
  // localised.  Only its documented/decodeable bootstrap status distinguishes
  // a genuinely absent service; timeout, signal, exec and every other manager
  // failure remain an error so callers can stop before mutating state.
  Result := ExitCode = LAUNCHCTL_SERVICE_NOT_FOUND;
end;
{$ENDIF}

function ServiceManagerEnabled: boolean;
begin
  Result := ProductionRoot or
    (TestingMode and
      (GetEnvironmentVariable('SUPERTERM_TEST_SERVICE_MANAGER') = '1'));
end;

{$IFDEF DARWIN}
function ParseLaunchdEnabled(const Output: string; out Enabled: boolean): boolean;
var
  Lines: TStringList;
  I: integer;
  Line, Marker, Value: string;
  HeaderSeen, Closed, Found: boolean;
begin
  // launchctl has no is-enabled operation. Its own manual does not promise
  // a stable diagnostic format, so accept only the current complete envelope
  // and exact boolean tokens. A future format change then aborts before any
  // managed file or service state is touched instead of guessing a rollback.
  Result := False;
  Enabled := False;
  HeaderSeen := False;
  Closed := False;
  Found := False;
  Marker := '"' + LowerCase(LAUNCHD_LABEL) + '"';
  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := LowerCase(Trim(Lines[I]));
      if not HeaderSeen then
      begin
        if Line = 'disabled services = {' then
          HeaderSeen := True;
        Continue;
      end;
      if Line = '}' then
      begin
        Closed := True;
        Break;
      end;
      if Pos(Marker, Line) <> 1 then
        Continue;
      if Found then
        Exit;
      Found := True;
      Value := Trim(Copy(Line, Length(Marker) + 1, MaxInt));
      if Value = '=> true' then
        Enabled := False
      else if Value = '=> false' then
        Enabled := True
      else
        Exit;
    end;
    if not HeaderSeen or not Closed then
      Exit;
    // launchd omits services which have no persistent disabled override;
    // their descriptor default is enabled.
    if not Found then
      Enabled := True;
    Result := True;
  finally
    Lines.Free;
  end;
end;
{$ENDIF}

procedure CaptureServiceState(out Snapshot: TServiceSnapshot);
var
  Tool, Output: string;
  QueryOK: boolean;
  {$IFNDEF DARWIN}
  StateText: string;
  {$ELSE}
  Loaded: boolean;
  {$ENDIF}
begin
  Snapshot := Default(TServiceSnapshot);
  if not ServiceManagerEnabled then
    Exit;
  {$IFDEF DARWIN}
  Tool := FindLaunchctl;
  if Tool = '' then
    raise ESshAdmin.Create('launchctl was not found');
  QueryOK := RunCaptured(Tool, ['print-disabled', 'system'], Output);
  if not QueryOK or not ParseLaunchdEnabled(Output, Snapshot.Enabled) then
    raise ESshAdmin.Create('cannot determine whether the SSH service is enabled');
  // For a KeepAlive launch daemon, presence in the system domain is the
  // controllable active state: bootout removes it and bootstrap restores it.
  QueryOK := QueryLaunchdLoaded(Tool, Loaded, Output);
  if not QueryOK then
    raise ESshAdmin.CreateFmt(
      'cannot determine whether the SSH service is loaded: %s',
      [Trim(Output)]);
  Snapshot.Active := Loaded;
  {$ELSE}
  Tool := FindSystemctl;
  if Tool = '' then
    raise ESshAdmin.Create('systemd/systemctl was not found');
  QueryOK := RunCaptured(Tool, ['is-enabled', SERVICE_NAME], Output);
  StateText := LowerCase(Trim(Output));
  if QueryOK and (StateText = 'enabled') then
    Snapshot.Enabled := True
  else if (not QueryOK) and (StateText = 'disabled') then
    Snapshot.Enabled := False
  else
    raise ESshAdmin.CreateFmt(
      'cannot determine whether the SSH service is enabled: %s',
      [StateText]);
  QueryOK := RunCaptured(Tool, ['is-active', SERVICE_NAME], Output);
  StateText := LowerCase(Trim(Output));
  if QueryOK and (StateText = 'active') then
    Snapshot.Active := True
  else if (not QueryOK) and
      ((StateText = 'inactive') or (StateText = 'failed')) then
    Snapshot.Active := False
  else
    raise ESshAdmin.CreateFmt(
      'cannot determine whether the SSH service is active: %s', [StateText]);
  {$ENDIF}
  Snapshot.Captured := True;
end;

function RestoreServiceState(const Snapshot: TServiceSnapshot): boolean;
var
  Tool, Output: string;
  StepOK: boolean;
  Verified: TServiceSnapshot;
  {$IFDEF DARWIN}
  Loaded: boolean;
  {$ENDIF}
begin
  if not Snapshot.Captured then
    Exit(True);
  Result := True;
  {$IFDEF DARWIN}
  Tool := FindLaunchctl;
  if Tool = '' then
    Exit(False);
  if not QueryLaunchdLoaded(Tool, Loaded, Output) then
    Exit(False);
  if Loaded then
  begin
    StepOK := RunCaptured(Tool,
      ['bootout', 'system/' + LAUNCHD_LABEL], Output);
    Result := Result and StepOK;
  end;
  if Snapshot.Active then
  begin
    // A persistently disabled launchd service cannot be bootstrapped. Enable
    // it only long enough to restore the loaded state, then restore policy.
    StepOK := RunCaptured(Tool,
      ['enable', 'system/' + LAUNCHD_LABEL], Output);
    Result := Result and StepOK;
    StepOK := RunCaptured(Tool,
      ['bootstrap', 'system', ServiceDescriptorPath], Output);
    Result := Result and StepOK;
  end;
  if Snapshot.Enabled then
    StepOK := RunCaptured(Tool,
      ['enable', 'system/' + LAUNCHD_LABEL], Output)
  else
    StepOK := RunCaptured(Tool,
      ['disable', 'system/' + LAUNCHD_LABEL], Output);
  Result := Result and StepOK;
  {$ELSE}
  Tool := FindSystemctl;
  if Tool = '' then
    Exit(False);
  StepOK := RunCaptured(Tool, ['daemon-reload'], Output);
  Result := Result and StepOK;
  if Snapshot.Enabled then
    StepOK := RunCaptured(Tool, ['enable', SERVICE_NAME], Output)
  else
    StepOK := RunCaptured(Tool, ['disable', SERVICE_NAME], Output);
  Result := Result and StepOK;
  if Snapshot.Active then
    // Restart, rather than start, also replaces a daemon which survived the
    // failed attempt with one using the restored accepted configuration.
    StepOK := RunCaptured(Tool, ['restart', SERVICE_NAME], Output)
  else
    StepOK := RunCaptured(Tool, ['stop', SERVICE_NAME], Output);
  Result := Result and StepOK;
  {$ENDIF}
  if Result then
  begin
    CaptureServiceState(Verified);
    Result := Verified.Captured and
      (Verified.Enabled = Snapshot.Enabled) and
      (Verified.Active = Snapshot.Active);
  end;
end;

function ServiceManager(const Action: string; PrintOutput: boolean): boolean;
var
  Tool, Output: string;
  {$IFDEF DARWIN}
  Loaded, Stopped, QueryOK: boolean;
  {$ENDIF}
begin
  if not ServiceManagerEnabled then
  begin
    if TestingMode then
      WriteLn('test mode: service manager action skipped: ', Action)
    else
      WriteLn('SSH files prepared under override root; service activation skipped');
    Exit(True);
  end;
  {$IFDEF DARWIN}
  Tool := FindLaunchctl;
  if Tool = '' then
    raise ESshAdmin.Create('launchctl was not found');
  if Action = 'enable' then
  begin
    // Query before changing the persistent policy. A transient launchctl
    // failure is not equivalent to an unloaded service.
    QueryOK := QueryLaunchdLoaded(Tool, Loaded, Output);
    Result := QueryOK;
    if QueryOK then
    begin
      Result := RunCaptured(Tool,
        ['enable', 'system/' + LAUNCHD_LABEL], Output);
      if Result then
      begin
        Stopped := True;
        if Loaded then
          Stopped := RunCaptured(Tool,
            ['bootout', 'system/' + LAUNCHD_LABEL], Output);
        Result := Stopped and RunCaptured(Tool,
          ['bootstrap', 'system', ServiceDescriptorPath], Output);
      end;
    end;
  end
  else if Action = 'disable' then
  begin
    QueryOK := QueryLaunchdLoaded(Tool, Loaded, Output);
    Result := QueryOK;
    if QueryOK then
    begin
      Stopped := True;
      if Loaded then
        Stopped := RunCaptured(Tool,
          ['bootout', 'system/' + LAUNCHD_LABEL], Output);
      Result := Stopped and RunCaptured(Tool,
        ['disable', 'system/' + LAUNCHD_LABEL], Output);
    end;
  end
  else if Action = 'restart' then
  begin
    QueryOK := QueryLaunchdLoaded(Tool, Loaded, Output);
    // Restart must not change launchd's persistent enabled/disabled state.
    // A disabled or unloaded service is an error here; `enable` is the
    // explicit operation which changes that policy.
    Result := QueryOK and Loaded and RunCaptured(Tool,
      ['bootout', 'system/' + LAUNCHD_LABEL], Output) and
      RunCaptured(Tool,
        ['bootstrap', 'system', ServiceDescriptorPath], Output);
  end
  else
  begin
    QueryOK := QueryLaunchdLoaded(Tool, Loaded, Output);
    Result := QueryOK and Loaded;
  end;
  {$ELSE}
  Tool := FindSystemctl;
  if Tool = '' then
    raise ESshAdmin.Create('systemd/systemctl was not found');
  if Action = 'enable' then
  begin
    if not RunCaptured(Tool, ['daemon-reload'], Output) then
      Result := False
    else if not RunCaptured(Tool, ['enable', SERVICE_NAME], Output) then
      Result := False
    else
      // `enable --now` leaves an already active daemon on its old accepted
      // config. Restart is idempotent and both starts an inactive unit and
      // applies the newly validated file to an active one.
      Result := RunCaptured(Tool, ['restart', SERVICE_NAME], Output);
  end
  else if Action = 'disable' then
    Result := RunCaptured(Tool, ['disable', '--now', SERVICE_NAME], Output)
  else if Action = 'restart' then
  begin
    if not RunCaptured(Tool, ['daemon-reload'], Output) then
      Result := False
    else
      Result := RunCaptured(Tool, ['restart', SERVICE_NAME], Output);
  end
  else if Action = 'reload' then
    Result := RunCaptured(Tool, ['daemon-reload'], Output)
  else
    Result := RunCaptured(Tool, ['is-active', SERVICE_NAME], Output);
  {$ENDIF}
  if PrintOutput and (Trim(Output) <> '') then
    WriteLn(Trim(Output));
  if not Result and not PrintOutput and (Action <> 'status') and
     (Trim(Output) <> '') then
    WriteLn(StdErr, Trim(Output));
end;

function ValidUserName(const S: string): boolean;
var
  i: integer;
begin
  if (S = '') or (Length(S) > 64) or (S[1] in ['-', '.']) then
    Exit(False);
  for i := 1 to Length(S) do
    if not (S[i] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.']) then
      Exit(False);
  Result := True;
end;

function CanonicalUserName(const UserName: string): string;
var
  Rec: Users.PPasswordRecord;
begin
  if not ValidUserName(UserName) then
    raise ESshAdmin.CreateFmt('invalid system username: %s', [UserName]);
  Rec := Users.GetPwNam(UserName);
  if Rec = nil then
    raise ESshAdmin.CreateFmt('system user does not exist: %s', [UserName]);
  Result := StrPas(Rec^.pw_name);
  if not ValidUserName(Result) then
    raise ESshAdmin.CreateFmt('NSS returned an unsafe canonical username: %s',
      [Result]);
end;

function IsKeyType(const S: string): boolean;
var
  i: integer;
begin
  Result := (Pos('ssh-', S) = 1) or (Pos('ecdsa-', S) = 1) or
    (Pos('sk-', S) = 1);
  if not Result then
    Exit;
  for i := 1 to Length(S) do
    if not (S[i] in ['a'..'z', 'A'..'Z', '0'..'9', '-', '.', '@', '_', '+']) then
      Exit(False);
end;

function IsBase64Blob(const S: string): boolean;
var
  i: integer;
begin
  if (Length(S) < 16) or (Length(S) > MAX_KEY_LINE) then
    Exit(False);
  for i := 1 to Length(S) do
    if not (S[i] in ['a'..'z', 'A'..'Z', '0'..'9', '+', '/', '=']) then
      Exit(False);
  Result := True;
end;

function NormalizeKeyLine(const Line: string): string;
var
  S, KeyType, Blob: string;
  P, i: integer;
begin
  S := Trim(Line);
  P := 1;
  while (P <= Length(S)) and not (S[P] in [' ', #9]) do
    Inc(P);
  KeyType := Copy(S, 1, P - 1);
  while (P <= Length(S)) and (S[P] in [' ', #9]) do
    Inc(P);
  i := P;
  while (i <= Length(S)) and not (S[i] in [' ', #9]) do
    Inc(i);
  Blob := Copy(S, P, i - P);
  if not IsKeyType(KeyType) or not IsBase64Blob(Blob) then
    raise ESshAdmin.Create('public key must start with an unadorned OpenSSH key type and blob');
  // Comments are not authentication material and are later printed by the
  // root administration CLI.  Discard them instead of trying to enumerate
  // every Unicode bidi/C1 terminal-spoofing sequence.
  Result := KeyType + ' ' + Blob;
end;

function ReadOnePublicKey(const Path: string): string;
var
  Lines: TStringList;
  i, Count: integer;
  S: string;
begin
  CheckSafeRegular(Path, False, 0);
  S := LoadSmallFile(Path, MAX_KEY_LINE);
  Lines := TStringList.Create;
  try
    Lines.Text := S;
    Count := 0;
    Result := '';
    for i := 0 to Lines.Count - 1 do
      if (Trim(Lines[i]) <> '') and (Trim(Lines[i])[1] <> '#') then
      begin
        Inc(Count);
        Result := NormalizeKeyLine(Lines[i]);
      end;
    if Count <> 1 then
      raise ESshAdmin.Create('public key file must contain exactly one key');
  finally
    Lines.Free;
  end;
end;

function FingerprintKey(const KeyLine: string): string;
var
  TempPath, Output: string;
  P, Q: integer;
begin
  TempPath := WriteTemporary(RootPath('key-fingerprint'), KeyLine + LineEnding, &600);
  try
    if not RunCaptured(SshKeygenExecutable,
      ['-l', '-E', 'sha256', '-f', TempPath], Output) then
      raise ESshAdmin.CreateFmt('ssh-keygen rejected public key: %s', [Trim(Output)]);
  finally
    FpUnlink(RawByteString(TempPath));
  end;
  P := Pos('SHA256:', Output);
  if P = 0 then
    raise ESshAdmin.Create('ssh-keygen did not return a SHA256 fingerprint');
  Q := P;
  while (Q <= Length(Output)) and not (Output[Q] in [' ', #9, #10, #13]) do
    Inc(Q);
  Result := Copy(Output, P, Q - P);
end;

procedure LoadAuthorized(const UserName: string; Lines: TStringList);
var
  Path, Content: string;
  St: Stat;
  Raw: TStringList;
  i: integer;
begin
  Lines.Clear;
  Path := IncludeTrailingPathDelimiter(AuthorizedKeysDir) + UserName;
  if not LStatPath(Path, St) then
  begin
    if FpGetErrNo = ESysENOENT then
      Exit;
    raise ESshAdmin.CreateFmt('cannot inspect authorized keys: %s', [ErrnoText]);
  end;
  CheckSafeRegular(Path, ProductionRoot, &22);
  Content := LoadSmallFile(Path, MAX_AUTHORIZED_FILE);
  Raw := TStringList.Create;
  try
    Raw.Text := Content;
    for i := 0 to Raw.Count - 1 do
      if (Trim(Raw[i]) <> '') and (Trim(Raw[i])[1] <> '#') then
        Lines.Add(NormalizeKeyLine(Raw[i]));
  finally
    Raw.Free;
  end;
end;

procedure SaveAuthorized(const UserName: string; Lines: TStringList);
var
  Path, Content: string;
  i: integer;
begin
  if Lines.Count > MAX_AUTHORIZED_KEYS then
    raise ESshAdmin.CreateFmt('too many authorized keys for %s', [UserName]);
  Content := '';
  for i := 0 to Lines.Count - 1 do
  begin
    if Length(Content) + Length(Lines[i]) + Length(LineEnding) >
       MAX_AUTHORIZED_FILE then
      raise ESshAdmin.CreateFmt('authorized keys file is too large for %s',
        [UserName]);
    Content := Content + Lines[i] + LineEnding;
  end;
  Path := IncludeTrailingPathDelimiter(AuthorizedKeysDir) + UserName;
  AtomicWrite(Path, Content, &644);
end;

procedure AuthorizeKey(const UserName, PublicKeyPath: string);
var
  Canonical, KeyLine, NewIdentity, ExistingIdentity: string;
  Lines: TStringList;
  i: integer;
begin
  Canonical := CanonicalUserName(UserName);
  KeyLine := ReadOnePublicKey(PublicKeyPath);
  NewIdentity := Copy(KeyLine, 1,
    Pos(' ', KeyLine, Pos(' ', KeyLine) + 1) - 1);
  if NewIdentity = '' then
    NewIdentity := KeyLine;
  FingerprintKey(KeyLine); // authoritative OpenSSH validation before writing
  Lines := TStringList.Create;
  try
    LoadAuthorized(Canonical, Lines);
    for i := 0 to Lines.Count - 1 do
    begin
      ExistingIdentity := Copy(Lines[i], 1,
        Pos(' ', Lines[i], Pos(' ', Lines[i]) + 1) - 1);
      if ExistingIdentity = '' then
        ExistingIdentity := Lines[i];
      if ExistingIdentity = NewIdentity then
      begin
        WriteLn('key already authorized for ', Canonical, ': ',
          FingerprintKey(Lines[i]));
        Exit;
      end;
    end;
    Lines.Add(KeyLine);
    SaveAuthorized(Canonical, Lines);
    WriteLn('authorized ', Canonical, ': ', FingerprintKey(KeyLine));
  finally
    Lines.Free;
  end;
end;

function RevokeSelector(const Selector: string): string;
var
  KeyLine: string;
  i: integer;
begin
  if Pos('SHA256:', Selector) = 1 then
  begin
    if (Length(Selector) < 15) or (Length(Selector) > 128) then
      raise ESshAdmin.Create('invalid SHA256 fingerprint');
    for i := Length('SHA256:') + 1 to Length(Selector) do
      if not (Selector[i] in ['a'..'z', 'A'..'Z', '0'..'9', '+', '/']) then
        raise ESshAdmin.Create('invalid SHA256 fingerprint');
    Exit(Selector);
  end;
  if not FileExists(Selector) then
    raise ESshAdmin.Create('revoke selector must be SHA256:... or a public-key file');
  KeyLine := ReadOnePublicKey(Selector);
  Result := FingerprintKey(KeyLine);
end;

procedure RevokeKey(const UserName, Selector: string);
var
  Canonical, Wanted, Current: string;
  Lines: TStringList;
  i, Removed: integer;
begin
  Canonical := CanonicalUserName(UserName);
  Wanted := RevokeSelector(Selector);
  Lines := TStringList.Create;
  try
    LoadAuthorized(Canonical, Lines);
    Removed := 0;
    for i := Lines.Count - 1 downto 0 do
    begin
      Current := FingerprintKey(Lines[i]);
      if Current = Wanted then
      begin
        Lines.Delete(i);
        Inc(Removed);
      end;
    end;
    if Removed = 0 then
      raise ESshAdmin.CreateFmt('key is not authorized for %s: %s',
        [Canonical, Wanted]);
    SaveAuthorized(Canonical, Lines);
    WriteLn('revoked ', Canonical, ': ', Wanted);
  finally
    Lines.Free;
  end;
end;

procedure ListUserKeys(const UserName: string);
var
  Lines: TStringList;
  i: integer;
begin
  if not ValidUserName(UserName) then
    raise ESshAdmin.CreateFmt('invalid username in authorized_keys: %s', [UserName]);
  Lines := TStringList.Create;
  try
    LoadAuthorized(UserName, Lines);
    for i := 0 to Lines.Count - 1 do
      WriteLn(UserName, #9, FingerprintKey(Lines[i]), #9, Lines[i]);
  finally
    Lines.Free;
  end;
end;

procedure ListKeys(const UserName: string);
var
  SR: TSearchRec;
  Path, Canonical: string;
begin
  if UserName <> '' then
  begin
    Canonical := CanonicalUserName(UserName);
    ListUserKeys(Canonical);
    Exit;
  end;
  Path := IncludeTrailingPathDelimiter(AuthorizedKeysDir);
  if FindFirst(Path + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and
         ValidUserName(SR.Name) then
        ListUserKeys(SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure SnapshotFile(const Path: string; MaxSize: Int64;
  out Snapshot: TFileSnapshot);
var
  St: Stat;
begin
  Snapshot := Default(TFileSnapshot);
  if LStatPath(Path, St) then
  begin
    if not FpS_ISREG(St.st_mode) then
      raise ESshAdmin.CreateFmt('refusing non-regular managed file: %s',
        [Path]);
    Snapshot.Exists := True;
    Snapshot.Mode := St.st_mode and &777;
    Snapshot.Data := LoadSmallFile(Path, MaxSize);
  end
  else if FpGetErrNo <> ESysENOENT then
    raise ESshAdmin.CreateFmt('cannot inspect managed file %s: %s',
      [Path, ErrnoText]);
end;

procedure RestoreFile(const Path: string; const Snapshot: TFileSnapshot);
var
  St: Stat;
begin
  if Snapshot.Exists then
  begin
    AtomicWrite(Path, Snapshot.Data, Snapshot.Mode);
    Exit;
  end;
  if LStatPath(Path, St) then
  begin
    if not FpS_ISREG(St.st_mode) then
      raise ESshAdmin.CreateFmt('refusing to remove non-regular managed file: %s',
        [Path]);
    if FpUnlink(RawByteString(Path)) <> 0 then
      raise ESshAdmin.CreateFmt('cannot remove managed file %s: %s',
        [Path, ErrnoText]);
    SyncParentDirectoryBestEffort(Path);
  end
  else if FpGetErrNo <> ESysENOENT then
    raise ESshAdmin.CreateFmt('cannot inspect managed file %s: %s',
      [Path, ErrnoText]);
end;

function TryServicePid(out Pid: TPid): boolean;
var
  St: Stat;
  S: string;
  V: Int64;
begin
  Result := False;
  Pid := 0;
  if not LStatPath(PidFilePath, St) or not FpS_ISREG(St.st_mode) then
    Exit;
  try
    S := Trim(LoadSmallFile(PidFilePath, 64));
  except
    Exit;
  end;
  if not TryStrToInt64(S, V) or (V <= 1) or (V > High(TPid)) then
    Exit;
  Pid := TPid(V);
  if FpKill(Pid, 0) = 0 then
    Exit(True);
  Result := FpGetErrNo = ESysEPERM;
end;

function WaitServiceHealthy(OldPid: TPid): boolean;
var
  I: integer;
  Pid: TPid;
begin
  if not ProductionRoot then
    Exit(True);
  for I := 1 to 50 do
  begin
    if TryServicePid(Pid) and ((OldPid <= 1) or (Pid <> OldPid)) and
       ServiceManager('status', False) then
      Exit(True);
    Sleep(100);
  end;
  Result := False;
end;

function RollbackPrepared(const OldGenerated, OldDescriptor: TFileSnapshot;
  const OldService: TServiceSnapshot; ServiceTouched: boolean): string;
var
  ManagerOK: boolean;
begin
  Result := '';
  try
    // With no previous complete service, stop the just-attempted unit while
    // its new descriptor still exists. Persistent host keys and server.ini
    // are deliberately never rolled back or deleted.
    if ServiceTouched and
       ((not OldGenerated.Exists) or (not OldDescriptor.Exists)) then
      ManagerOK := ServiceManager('disable', False)
    else
      ManagerOK := True;
    RestoreFile(GeneratedConfigPath, OldGenerated);
    RestoreFile(ServiceDescriptorPath, OldDescriptor);
    if ServiceTouched and OldService.Captured then
    begin
      ManagerOK := RestoreServiceState(OldService);
      if OldService.Active then
        ManagerOK := WaitServiceHealthy(0) and ManagerOK;
    end;
    if not ManagerOK then
      Result := 'previous service state could not be restored';
  except
    on E: Exception do
      Result := E.Message;
  end;
end;

procedure ActivateServer(const Action: string; ApplyPending,
  PrepareDefaults: boolean);
var
  LockFd: cint;
  OldGenerated, OldDescriptor: TFileSnapshot;
  OldService: TServiceSnapshot;
  OldPid: TPid;
  Failure, RollbackFailure: string;
  ServiceTouched, OK: boolean;
begin
  EnsureDirectories;
  LockFd := AcquireAdminLock;
  try
    if PrepareDefaults then
    begin
      EnsureDefaultIni;
      EnsureHostKey;
    end;
    SnapshotFile(GeneratedConfigPath, MAX_CONFIG_SIZE, OldGenerated);
    SnapshotFile(ServiceDescriptorPath, MAX_CONFIG_SIZE, OldDescriptor);
    OldService := Default(TServiceSnapshot);
    // State discovery is read-only. Fail before publishing either managed
    // file if the manager cannot describe the state we would have to undo.
    if OldGenerated.Exists and OldDescriptor.Exists then
      CaptureServiceState(OldService);
    OldPid := 0;
    TryServicePid(OldPid);
    Failure := '';
    ServiceTouched := False;
    try
      if ApplyPending then
        UpdateGeneratedConfig
      else
      begin
        VerifyHostKey(False);
        CheckSafeRegular(GeneratedConfigPath, ProductionRoot, &22);
        ValidateGenerated(GeneratedConfigPath, -1, -1, -1, -1);
      end;
      InstallServiceDescriptor;
      ServiceTouched := True;
      OK := ServiceManager(Action, False);
      if OK then
        OK := WaitServiceHealthy(OldPid);
      if not OK then
        Failure := 'service did not become healthy';
    except
      on E: Exception do
        Failure := E.Message;
    end;
    if Failure <> '' then
    begin
      RollbackFailure := RollbackPrepared(OldGenerated, OldDescriptor,
        OldService, ServiceTouched);
      if RollbackFailure <> '' then
        Failure := Failure + '; rollback failed: ' + RollbackFailure;
      raise ESshAdmin.Create(Failure);
    end;
  finally
    ReleaseAdminLock(LockFd);
  end;
end;

procedure CheckInstallation;
var
  Cfg: TSshServerConfig;
  Candidate: string;
  LockFd: cint;
begin
  CheckSafeDirectory(SshdRoot, ProductionRoot);
  CheckSafeDirectory(AuthorizedKeysDir, ProductionRoot);
  LockFd := AcquireAdminLock;
  try
    LoadServerConfig(Cfg);
    VerifyHostKey(False);
    Candidate := WriteTemporary(GeneratedConfigPath,
      BuildGeneratedConfig(Cfg), &600);
    try
      ValidateGenerated(Candidate, Ord(Cfg.AllowRoot),
        Ord(Cfg.PasswordAuthentication), Ord(Cfg.ManagedAuthorizedKeys),
        Ord(Cfg.UserAuthorizedKeys));
    finally
      FpUnlink(RawByteString(Candidate));
    end;
  finally
    ReleaseAdminLock(LockFd);
  end;
  WriteLn('Pending SuperTerm SSH configuration is valid; no files changed');
end;

procedure SetupServer;
begin
  ActivateServer('enable', True, True);
  WriteLn('SuperTerm SSH server is configured and enabled');
end;

procedure RefreshAndService(const Action: string);
begin
  ActivateServer(Action, True, False);
  WriteLn('SuperTerm SSH server configuration accepted and service restarted');
end;

procedure EnableAcceptedServer;
begin
  ActivateServer('enable', False, False);
  WriteLn('SuperTerm SSH server is enabled with the accepted configuration');
end;

procedure UninstallService;
var
  Path, Failure, RollbackFailure: string;
  St: Stat;
  LockFd: cint;
  OldDescriptor, CurrentDescriptor: TFileSnapshot;
  OldService: TServiceSnapshot;
  ManagerTouched, DescriptorRemoved: boolean;

  procedure AddRollbackFailure(const S: string);
  begin
    if S = '' then
      Exit;
    if RollbackFailure = '' then
      RollbackFailure := S
    else
      RollbackFailure := RollbackFailure + '; ' + S;
  end;

  procedure RollbackRemoval;
  begin
    // Restore the descriptor before restoring service state: both systemd
    // and launchd may need that exact file to re-create the previous runtime
    // state.  Persistent SSH configuration and keys are never candidates.
    if DescriptorRemoved then
      try
        RestoreFile(Path, OldDescriptor);
      except
        on E: Exception do
          AddRollbackFailure('descriptor: ' + E.Message);
      end;
    if ManagerTouched and OldService.Captured then
      try
        if not RestoreServiceState(OldService) then
          AddRollbackFailure('previous service state could not be restored');
      except
        on E: Exception do
          AddRollbackFailure('service state: ' + E.Message);
      end;
  end;

begin
  Path := ServiceDescriptorPath;
  if not LStatPath(Path, St) then
  begin
    if FpGetErrNo <> ESysENOENT then
      raise ESshAdmin.CreateFmt('cannot inspect service descriptor %s: %s',
        [Path, ErrnoText]);
    // In particular, do not call EnsureDirectories or acquire the lock here:
    // repeating an uninstall must not recreate /etc/superterm/sshd.
    WriteLn('SuperTerm SSH service descriptor is already absent; ',
      'persistent SSH configuration was kept');
    Exit;
  end;
  if not FpS_ISREG(St.st_mode) then
    raise ESshAdmin.CreateFmt(
      'refusing to uninstall a non-regular service descriptor: %s', [Path]);

  CheckSafeDirectory(ExtractFileDir(Path), ProductionRoot);
  CheckSafeDirectory(SshdRoot, ProductionRoot);
  LockFd := AcquireAdminLock;
  try
    SnapshotFile(Path, MAX_CONFIG_SIZE, OldDescriptor);
    CheckSafeRegular(Path, ProductionRoot, &22);
    if (not OldDescriptor.Exists) or
       (not IsRecognizedServiceDescriptor(OldDescriptor.Data)) then
      raise ESshAdmin.CreateFmt(
        'refusing to remove an unrecognised service descriptor: %s', [Path]);

    OldService := Default(TServiceSnapshot);
    CaptureServiceState(OldService);
    Failure := '';
    RollbackFailure := '';
    ManagerTouched := False;
    DescriptorRemoved := False;
    try
      ManagerTouched := ServiceManagerEnabled;
      if not ServiceManager('disable', False) then
        raise ESshAdmin.Create('could not stop and disable the SSH service');

      // Recheck after the external manager returns.  The administration lock
      // serialises SuperTerm itself; this second check also refuses a foreign
      // replacement made outside that protocol before unlinking anything.
      SnapshotFile(Path, MAX_CONFIG_SIZE, CurrentDescriptor);
      CheckSafeRegular(Path, ProductionRoot, &22);
      if (not CurrentDescriptor.Exists) or
         (CurrentDescriptor.Data <> OldDescriptor.Data) then
        raise ESshAdmin.Create(
          'service descriptor changed while it was being uninstalled');
      if FpUnlink(RawByteString(Path)) <> 0 then
        raise ESshAdmin.CreateFmt('cannot remove service descriptor %s: %s',
          [Path, ErrnoText]);
      DescriptorRemoved := True;
      SyncParentDirectoryBestEffort(Path);
      {$IFNDEF DARWIN}
      if not ServiceManager('reload', False) then
        raise ESshAdmin.Create('could not reload systemd after removing the service');
      {$ENDIF}
    except
      on E: Exception do
        Failure := E.Message;
    end;
    if Failure <> '' then
    begin
      RollbackRemoval;
      if RollbackFailure <> '' then
        Failure := Failure + '; rollback failed: ' + RollbackFailure;
      raise ESshAdmin.Create(Failure);
    end;
  finally
    ReleaseAdminLock(LockFd);
  end;
  WriteLn('SuperTerm SSH service descriptor was removed; ',
    'persistent SSH configuration and keys were kept');
end;

procedure RunForegroundServer;
type
  TPCharVector = array[0..5] of PChar;
var
  Sshd, Config: string;
  Args: TPCharVector;
begin
  RequireRoot;
  if (GetEnvironmentVariable('SUPERTERM_SSHD_ROOT') <> '') and
     (FpGetEUid = 0) and not TestingMode then
    raise ESshAdmin.Create(
      'refusing SUPERTERM_SSHD_ROOT in the root service without SUPERTERM_TESTING=1');
  CheckSafeDirectory(SshdRoot, ProductionRoot);
  CheckSafeDirectory(AuthorizedKeysDir, ProductionRoot);
  VerifyHostKey(False);
  CheckSafeRegular(GeneratedConfigPath, ProductionRoot, &22);
  ValidateGenerated(GeneratedConfigPath, -1, -1, -1, -1);
  Sshd := SshdExecutable;
  Config := GeneratedConfigPath;
  Args[0] := PChar(Sshd);
  Args[1] := PChar('-D');
  Args[2] := PChar('-e');
  Args[3] := PChar('-f');
  Args[4] := PChar(Config);
  Args[5] := nil;
  FpExecV(RawByteString(Sshd), PPChar(@Args[0]));
  raise ESshAdmin.CreateFmt('cannot exec sshd: %s', [ErrnoText]);
end;

function SshHelpLanguage(const ARootCommand, ACommand: string): TUiLanguage;
begin
  if (ARootCommand = 'servidor-ssh') or (ACommand = 'ayuda') or
     (Copy(LowerCase(GetEnvironmentVariable('LANG')), 1, 2) = 'es') then
    Result := ulSpanish
  else
    Result := ulEnglish;
end;

function IsAdminHelpOption(const S: string): boolean;
begin
  Result := (S = '-h') or (S = '-?') or
    ((Copy(S, 1, 2) = '--') and
     ((NormToken(S) = 'help') or (NormToken(S) = 'ayuda')));
end;

procedure PrintUsage(ALanguage: TUiLanguage);
begin
  PrintSshServerHelp(ALanguage);
end;

function RunSshServerAdmin(out AExitCode: integer): boolean;
var
  RootCommand, Command: string;
  LockFd: cint;
  HelpCommand, NoArgCommand, AuthorizeCommand, RevokeCommand,
    ListCommand, ContextHelp: boolean;
  HelpLanguage: TUiLanguage;
begin
  AExitCode := 0;
  Result := False;
  if ParamCount < 1 then
    Exit;
  RootCommand := NormToken(ParamStr(1));
  if (RootCommand <> 'ssh-server') and (RootCommand <> 'servidor-ssh') then
    Exit;
  Result := True;
  try
    HelpLanguage := SshHelpLanguage(RootCommand, '');
    if ParamCount < 2 then
    begin
      PrintUsage(HelpLanguage);
      AExitCode := 2;
      Exit;
    end;
    Command := NormToken(ParamStr(2));
    HelpLanguage := SshHelpLanguage(RootCommand, Command);
    // The namespace itself accepts the same four help options as a recognized
    // subcommand. Keep this before RequireRoot so contextual help is genuinely
    // usable by an ordinary account.
    HelpCommand := TokenIn(Command, ['help', 'ayuda']) or
      IsAdminHelpOption(ParamStr(2));
    NoArgCommand := TokenIn(Command,
      ['setup', 'init', 'configurar', 'preparar', 'inicializar',
       'check', 'comprobar', 'verificar', 'restart', 'reiniciar',
       'status', 'estado', 'enable', 'habilitar', 'activar',
       'disable', 'deshabilitar', 'desactivar', 'uninstall-service',
       'desinstalar-servicio', 'run', 'ejecutar']);
    AuthorizeCommand := TokenIn(Command, ['authorize', 'autorizar']);
    RevokeCommand := TokenIn(Command, ['revoke', 'revocar']);
    ListCommand := TokenIn(Command, ['list-keys', 'listar-claves']);
    if (not HelpCommand) and (not NoArgCommand) and
       (not AuthorizeCommand) and (not RevokeCommand) and
       (not ListCommand) then
    begin
      PrintUsage(HelpLanguage);
      AExitCode := 2;
      Exit;
    end;
    ContextHelp := (ParamCount = 3) and IsAdminHelpOption(ParamStr(3));
    if ContextHelp then
    begin
      PrintUsage(HelpLanguage);
      Exit;
    end;
    if ((HelpCommand or NoArgCommand) and (ParamCount <> 2)) or
       ((AuthorizeCommand or RevokeCommand) and (ParamCount <> 4)) or
       (ListCommand and ((ParamCount < 2) or (ParamCount > 3))) then
    begin
      PrintUsage(HelpLanguage);
      AExitCode := 2;
      Exit;
    end;
    if HelpCommand then
      PrintUsage(HelpLanguage)
    else
    begin
      RequireRoot;
      if (Command = 'setup') or (Command = 'init') or
         (Command = 'configurar') or (Command = 'preparar') or
         (Command = 'inicializar') then
        SetupServer
      else if (Command = 'check') or (Command = 'comprobar') or
              (Command = 'verificar') then
        CheckInstallation
      else if (Command = 'restart') or (Command = 'reiniciar') then
        RefreshAndService('restart')
      else if (Command = 'status') or (Command = 'estado') then
      begin
        if not ServiceManager('status', True) then
          AExitCode := 3;
      end
      else if (Command = 'enable') or (Command = 'habilitar') or
              (Command = 'activar') then
        EnableAcceptedServer
      else if (Command = 'disable') or (Command = 'deshabilitar') or
              (Command = 'desactivar') then
      begin
        EnsureDirectories;
        LockFd := AcquireAdminLock;
        try
          if not ServiceManager('disable', False) then
            raise ESshAdmin.Create('could not disable the SSH service');
        finally
          ReleaseAdminLock(LockFd);
        end;
      end
      else if (Command = 'uninstall-service') or
              (Command = 'desinstalar-servicio') then
        UninstallService
      else if (Command = 'authorize') or (Command = 'autorizar') then
      begin
        EnsureDirectories;
        LockFd := AcquireAdminLock;
        try
          AuthorizeKey(ParamStr(3), ParamStr(4));
        finally
          ReleaseAdminLock(LockFd);
        end;
      end
      else if (Command = 'revoke') or (Command = 'revocar') then
      begin
        EnsureDirectories;
        LockFd := AcquireAdminLock;
        try
          RevokeKey(ParamStr(3), ParamStr(4));
        finally
          ReleaseAdminLock(LockFd);
        end;
      end
      else if (Command = 'list-keys') or (Command = 'listar-claves') then
      begin
        EnsureDirectories;
        if ParamCount = 3 then
          ListKeys(ParamStr(3))
        else
          ListKeys('');
      end
      else if (Command = 'run') or (Command = 'ejecutar') then
        RunForegroundServer;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'superterm ssh-server: ', E.Message);
      if AExitCode = 0 then
        AExitCode := 1;
    end;
  end;
end;

end.
