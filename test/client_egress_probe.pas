program client_egress_probe;

{$mode objfpc}{$H+}

uses
  SysUtils, st_server;

const
  CHUNK_SIZE = 64 * 1024;
  MAX_ATTEMPTS = 1024;

var
  Client: TSessionClient;
  Snapshot: TSessionSnapshot;
  Chunk: RawByteString;
  Accepted, I: integer;
begin
  if ParamCount <> 1 then
    Halt(64);
  Client := TSessionClient.Create;
  try
    Snapshot := Default(TSessionSnapshot);
    if not Client.Connect(ParamStr(1), Snapshot, 80, 24) then
    begin
      WriteLn('CONNECT-FAILED ', Client.AttachError);
      Halt(2);
    end;
    WriteLn('READY');
    Flush(Output);
    ReadLn;
    SetLength(Chunk, CHUNK_SIZE);
    FillChar(Chunk[1], Length(Chunk), Ord('x'));
    Accepted := 0;
    for I := 1 to MAX_ATTEMPTS do
      if Client.SendInput(0, Chunk) then
        Inc(Accepted)
      else
        Break;
    WriteLn('ACCEPTED ', Accepted, ' REJECTED ',
      Ord(Accepted < MAX_ATTEMPTS));
    Flush(Output);
    if Accepted >= MAX_ATTEMPTS then
      Halt(3);
  finally
    Client.Free;
  end;
end.
