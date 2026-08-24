(*
  Project: superterm
  Unit: st_poll - small portable poll(2) registry for the session daemon

  Free Pascal exposes poll through BaseUnix.fpPoll on GNU/Linux and macOS.
  This wrapper deliberately owns no callbacks: the daemon remains the single
  owner of all session state and dispatches the returned source/index pairs.
*)

unit st_poll;

{$mode objfpc}{$H+}

interface

uses
  BaseUnix, ctypes;

type
  TPollSource = (psListener, psPending, psClient, psPane);

  TPollReady = record
    Source: TPollSource;
    Index: integer;
    Readable: boolean;
    Writable: boolean;
    Error: boolean;
    Hangup: boolean;
  end;
  TPollReadyArray = array of TPollReady;

  TSuperPoll = class
  private type
    TRegistration = record
      Source: TPollSource;
      Index: integer;
    end;
  private
    FFds: array of TPollFD;
    FRegs: array of TRegistration;
    FCount: integer;
  public
    procedure Clear;
    procedure Watch(AFd: cint; ASource: TPollSource; AIndex: integer;
      ARead, AWrite: boolean);
    function Wait(ATimeoutMs: integer; out AReady: TPollReadyArray): integer;
  end;

implementation

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
  FFds[N] := Default(TPollFD);
  FFds[N].fd := AFD;
  if ARead then
    FFds[N].events := FFds[N].events or POLLIN;
  if AWrite then
    FFds[N].events := FFds[N].events or POLLOUT;
  FRegs[N].Source := ASource;
  FRegs[N].Index := AIndex;
  Inc(FCount);
end;

function TSuperPoll.Wait(ATimeoutMs: integer;
  out AReady: TPollReadyArray): integer;
var
  N, I, C: integer;
  R: cshort;
begin
  AReady := nil;
  if ATimeoutMs < -1 then
    ATimeoutMs := -1;
  if FCount = 0 then
    N := FpPoll(nil, 0, ATimeoutMs)
  else
    N := FpPoll(@FFds[0], FCount, ATimeoutMs);
  if N <= 0 then
    Exit(N);
  SetLength(AReady, N);
  C := 0;
  for I := 0 to FCount - 1 do
  begin
    R := FFds[I].revents;
    if R = 0 then
      Continue;
    AReady[C] := Default(TPollReady);
    AReady[C].Source := FRegs[I].Source;
    AReady[C].Index := FRegs[I].Index;
    AReady[C].Readable := (R and (POLLIN or POLLPRI)) <> 0;
    AReady[C].Writable := (R and POLLOUT) <> 0;
    AReady[C].Error := (R and (POLLERR or POLLNVAL)) <> 0;
    AReady[C].Hangup := (R and POLLHUP) <> 0;
    Inc(C);
  end;
  SetLength(AReady, C);
  Result := C;
end;

end.
