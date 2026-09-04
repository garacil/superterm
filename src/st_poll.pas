(*
  Project: superterm
  Unit: st_poll - small portable poll(2) registry for the session daemon

  Free Pascal exposes poll through BaseUnix.fpPoll on GNU/Linux and macOS.
  Windows has WSAPoll, the same call for sockets only, which is all the
  session daemon watches there: its listener, its clients and the socket pair
  that stands in for the worker result pipe. Pane output on Windows never
  enters this set -- a ConPTY pipe is not a socket -- so the pane workers
  read it on their own.

  This wrapper deliberately owns no callbacks: the daemon remains the single
  owner of all session state and dispatches the returned source/index pairs.
*)

unit st_poll;

{$mode objfpc}{$H+}

interface

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF WINDOWS}
  SysUtils,
  {$ENDIF}
  ctypes;

type
  TPollSource = (psListener, psPending, psClient, psPane, psWorker);

  TPollReady = record
    Source: TPollSource;
    Index: integer;
    Readable: boolean;
    Writable: boolean;
    Error: boolean;
    Hangup: boolean;
  end;
  TPollReadyArray = array of TPollReady;

  {$IFDEF WINDOWS}
  // WSAPOLLFD: a SOCKET (pointer-sized) and two 16-bit event masks. The C
  // struct is padded to 16 bytes on x64; an array element must be too, or
  // every entry after the first is read misaligned (WSAEINVAL).
  TWSAPollFd = packed record
    fd: PtrUInt;
    events: SmallInt;
    revents: SmallInt;
    Padding: LongInt;
  end;
  {$ENDIF}

  TSuperPoll = class
  private type
    TRegistration = record
      Source: TPollSource;
      Index: integer;
    end;
  private
    {$IFDEF WINDOWS}
    FFds: array of TWSAPollFd;
    {$ELSE}
    FFds: array of TPollFD;
    {$ENDIF}
    FRegs: array of TRegistration;
    FCount: integer;
  public
    procedure Clear;
    procedure Watch(AFd: cint; ASource: TPollSource; AIndex: integer;
      ARead, AWrite: boolean);
    function Wait(ATimeoutMs: integer; out AReady: TPollReadyArray): integer;
  end;

implementation

{$IFDEF WINDOWS}
const
  // WSAPoll accepts only these in events; POLLIN/POLLOUT are the same
  // combinations Winsock defines for them.
  WSA_POLLRDNORM = $0100;
  WSA_POLLRDBAND = $0200;
  WSA_POLLWRNORM = $0010;
  WSA_POLLIN = WSA_POLLRDNORM or WSA_POLLRDBAND;
  WSA_POLLOUT = WSA_POLLWRNORM;
  WSA_POLLPRI = $0400;
  WSA_POLLERR = $0001;
  WSA_POLLHUP = $0002;
  WSA_POLLNVAL = $0004;

function WSAPoll(fdArray: Pointer; fds: LongWord; timeout: LongInt): LongInt;
  stdcall; external 'ws2_32.dll' name 'WSAPoll';
{$ENDIF}

procedure TSuperPoll.Clear;
begin
  FCount := 0;
end;

procedure TSuperPoll.Watch(AFd: cint; ASource: TPollSource; AIndex: integer;
  ARead, AWrite: boolean);
var
  N: integer;
begin
  if AFD < 0 then
    Exit;
  N := FCount;
  if N >= Length(FFds) then
  begin
    if N = 0 then
      SetLength(FFds, 16)
    else
      SetLength(FFds, N * 2);
    SetLength(FRegs, Length(FFds));
  end;
  {$IFDEF WINDOWS}
  FFds[N] := Default(TWSAPollFd);
  FFds[N].fd := PtrUInt(AFD);
  if ARead then
    FFds[N].events := FFds[N].events or WSA_POLLIN;
  if AWrite then
    FFds[N].events := FFds[N].events or WSA_POLLOUT;
  {$ELSE}
  FFds[N] := Default(TPollFD);
  FFds[N].fd := AFD;
  if ARead then
    FFds[N].events := FFds[N].events or POLLIN;
  if AWrite then
    FFds[N].events := FFds[N].events or POLLOUT;
  {$ENDIF}
  FRegs[N].Source := ASource;
  FRegs[N].Index := AIndex;
  Inc(FCount);
end;

function TSuperPoll.Wait(ATimeoutMs: integer;
  out AReady: TPollReadyArray): integer;
var
  N, I, C: integer;
  {$IFDEF WINDOWS}
  R: SmallInt;
  {$ELSE}
  R: cshort;
  {$ENDIF}
begin
  AReady := nil;
  if ATimeoutMs < -1 then
    ATimeoutMs := -1;
  {$IFDEF WINDOWS}
  if FCount = 0 then
  begin
    // WSAPoll refuses an empty set; the caller only wants the pause.
    if ATimeoutMs > 0 then
      Sleep(ATimeoutMs);
    Exit(0);
  end;
  N := WSAPoll(@FFds[0], LongWord(FCount), ATimeoutMs);
  {$ELSE}
  if FCount = 0 then
    N := FpPoll(nil, 0, ATimeoutMs)
  else
    N := FpPoll(@FFds[0], FCount, ATimeoutMs);
  {$ENDIF}
  if N <= 0 then
    Exit(N);
  SetLength(AReady, N);
  C := 0;
  for I := 0 to FCount - 1 do
  begin
    R := FFds[I].revents;
    if R = 0 then
      Continue;
    if C >= Length(AReady) then
      SetLength(AReady, C + 1);
    AReady[C] := Default(TPollReady);
    AReady[C].Source := FRegs[I].Source;
    AReady[C].Index := FRegs[I].Index;
    {$IFDEF WINDOWS}
    AReady[C].Readable := (R and (WSA_POLLIN or WSA_POLLPRI)) <> 0;
    AReady[C].Writable := (R and WSA_POLLOUT) <> 0;
    AReady[C].Error := (R and (WSA_POLLERR or WSA_POLLNVAL)) <> 0;
    AReady[C].Hangup := (R and WSA_POLLHUP) <> 0;
    {$ELSE}
    AReady[C].Readable := (R and (POLLIN or POLLPRI)) <> 0;
    AReady[C].Writable := (R and POLLOUT) <> 0;
    AReady[C].Error := (R and (POLLERR or POLLNVAL)) <> 0;
    AReady[C].Hangup := (R and POLLHUP) <> 0;
    {$ENDIF}
    Inc(C);
  end;
  SetLength(AReady, C);
  Result := C;
end;

end.
