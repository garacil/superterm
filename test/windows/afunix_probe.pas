program afunix_probe;

// Checks what the Windows session server depends on: AF_UNIX sockets over
// Winsock (Windows 10 1803+) driven through FPC's Sockets unit, non-blocking
// mode with FIONBIO, WSAPoll as a poll(2) equivalent, and the bind rule that
// the socket file must not exist beforehand.
//
//   fpc -Mobjfpc -Sh -FUbuild/units/win-release -FEbin test/windows/afunix_probe.pas
//   bin\afunix_probe.exe

{$mode objfpc}{$H+}

uses
  SysUtils, ctypes, Windows, Sockets;

const
  AF_UNIX_ = 1;
  FIONBIO_ = $8004667E;
  POLLIN_ = $0300;   // POLLRDNORM or POLLRDBAND
  POLLOUT_ = $0010;  // POLLWRNORM
  WSAEWOULDBLOCK_ = 10035;

type
  TUnixSockAddr = packed record
    sun_family: word;
    sun_path: array[0..107] of AnsiChar;
  end;

  TWSAPollFd = packed record
    fd: PtrUInt;      // SOCKET
    events: SmallInt;
    revents: SmallInt;
  end;

function WSAPoll(fdArray: Pointer; fds: LongWord; timeout: LongInt): LongInt;
  stdcall; external 'ws2_32.dll' name 'WSAPoll';
function ioctlsocket(s: PtrUInt; cmd: LongInt; var argp: LongWord): LongInt;
  stdcall; external 'ws2_32.dll' name 'ioctlsocket';

procedure Check(ACond: boolean; const AWhat: string);
begin
  if ACond then
    WriteLn('ok    ', AWhat)
  else
  begin
    WriteLn('FAIL  ', AWhat, ' (socketerror=', socketerror, ' lasterror=',
      GetLastError, ')');
    Halt(1);
  end;
end;

function MakeAddr(const APath: string; out AAddr: TUnixSockAddr): boolean;
begin
  AAddr := Default(TUnixSockAddr);
  AAddr.sun_family := AF_UNIX_;
  Result := Length(APath) < SizeOf(AAddr.sun_path);
  if Result then
    Move(APath[1], AAddr.sun_path[0], Length(APath));
end;

function SetNonBlocking(S: cint): boolean;
var
  One: LongWord;
begin
  One := 1;
  Result := ioctlsocket(PtrUInt(S), LongInt(FIONBIO_), One) = 0;
end;

function PollOne(S: cint; AEvents: SmallInt; ATimeoutMs: LongInt): SmallInt;
var
  P: TWSAPollFd;
  N: LongInt;
begin
  P.fd := PtrUInt(S);
  P.events := AEvents;
  P.revents := 0;
  N := WSAPoll(@P, 1, ATimeoutMs);
  if N <= 0 then
    Result := 0
  else
    Result := P.revents;
end;

var
  Path: string;
  Addr, Peer: TUnixSockAddr;
  Listener, Client, Server, Extra: cint;
  PeerLen: TSockLen;
  Buf: array[0..63] of AnsiChar;
  N: ssize_t;
  Msg: AnsiString;
  Second: cint;

begin
  Path := IncludeTrailingPathDelimiter(SysUtils.GetEnvironmentVariable('LOCALAPPDATA')) +
    'superterm-afunix-probe.sock';
  WriteLn('socket path: ', Path, ' (', Length(Path), ' chars)');
  if FileExists(Path) then
    SysUtils.DeleteFile(Path);

  Listener := fpsocket(AF_UNIX_, SOCK_STREAM, 0);
  Check(Listener <> -1, 'socket(AF_UNIX, SOCK_STREAM)');
  Check(MakeAddr(Path, Addr), 'path fits sun_path');
  Check(fpbind(Listener, @Addr, SizeOf(Addr)) = 0, 'bind to the socket file');
  Check(FileExists(Path), 'bind created the socket file');
  Check(fplisten(Listener, 4) = 0, 'listen');
  Check(SetNonBlocking(Listener), 'listener non-blocking (FIONBIO)');

  // a second bind on the same live path must fail: that is the liveness rule
  Extra := fpsocket(AF_UNIX_, SOCK_STREAM, 0);
  Check(fpbind(Extra, @Addr, SizeOf(Addr)) <> 0, 'second bind on a live path is refused');
  CloseSocket(Extra);

  Check(PollOne(Listener, POLLIN_, 0) = 0, 'WSAPoll: no pending connection yet');

  Client := fpsocket(AF_UNIX_, SOCK_STREAM, 0);
  Check(Client <> -1, 'client socket');
  Check(fpconnect(Client, @Addr, SizeOf(Addr)) = 0, 'connect');
  Check(SetNonBlocking(Client), 'client non-blocking');

  Check((PollOne(Listener, POLLIN_, 1000) and POLLIN_) <> 0, 'WSAPoll: listener readable after connect');
  PeerLen := SizeOf(Peer);
  Server := fpaccept(Listener, @Peer, @PeerLen);
  Check(Server <> -1, 'accept');
  Check(SetNonBlocking(Server), 'accepted socket non-blocking');

  Buf[0] := #0;
  N := fprecv(Server, @Buf[0], SizeOf(Buf), 0);
  Check((N = -1) and (socketerror = WSAEWOULDBLOCK_), 'recv on empty non-blocking socket -> WSAEWOULDBLOCK');
  Check(PollOne(Server, POLLIN_, 0) = 0, 'WSAPoll: nothing to read yet');
  Check((PollOne(Server, POLLOUT_, 0) and POLLOUT_) <> 0, 'WSAPoll: writable');

  Msg := 'hello over AF_UNIX';
  N := fpsend(Client, @Msg[1], Length(Msg), 0);
  Check(N = Length(Msg), 'send from client');
  Check((PollOne(Server, POLLIN_, 1000) and POLLIN_) <> 0, 'WSAPoll: readable after send');
  N := fprecv(Server, @Buf[0], SizeOf(Buf), 0);
  Check((N = Length(Msg)) and (CompareMem(@Buf[0], @Msg[1], N)), 'recv the same bytes');

  N := fpsend(Server, @Msg[1], Length(Msg), 0);
  Check(N = Length(Msg), 'send from server');
  Check((PollOne(Client, POLLIN_, 1000) and POLLIN_) <> 0, 'WSAPoll: client readable');
  N := fprecv(Client, @Buf[0], SizeOf(Buf), 0);
  Check(N = Length(Msg), 'client recv');

  // a second client, to be sure accept queues work and WSAPoll handles two
  Second := fpsocket(AF_UNIX_, SOCK_STREAM, 0);
  Check(fpconnect(Second, @Addr, SizeOf(Addr)) = 0, 'second client connect');
  Check((PollOne(Listener, POLLIN_, 1000) and POLLIN_) <> 0, 'listener readable again');
  CloseSocket(Second);

  // peer close must show up as readable with recv = 0
  CloseSocket(Client);
  Check((PollOne(Server, POLLIN_, 1000) and (POLLIN_ or $0002 or $0001)) <> 0, 'WSAPoll: peer close reported');
  N := fprecv(Server, @Buf[0], SizeOf(Buf), 0);
  Check(N = 0, 'recv returns 0 after the peer closed');

  CloseSocket(Server);
  CloseSocket(Listener);
  Check(FileExists(Path), 'socket file survives closesocket (must be deleted explicitly)');
  Check(SysUtils.DeleteFile(Path), 'socket file deleted');
  // connecting to a path with no listener: refused (the "dead session" probe)
  Client := fpsocket(AF_UNIX_, SOCK_STREAM, 0);
  Check(fpconnect(Client, @Addr, SizeOf(Addr)) <> 0, 'connect to a deleted path fails');
  CloseSocket(Client);
  WriteLn('all checks passed');
end.
