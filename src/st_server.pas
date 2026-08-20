(*
  Unidad: st_server - servidor persistente de sesiones desprendibles

  The server owns the PTY masters and terminal parsers.  The FreeVision
  process is only a client, so closing or losing that client cannot close a
  local shell or an SSH connection.
*)

unit st_server;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, BaseUnix, Unix, Sockets,
  st_config, st_layout, st_pty, st_screen, st_session;

const
  FRAME_ATTACH = 1;
  FRAME_INPUT = 2;
  FRAME_RESIZE = 3;
  FRAME_DETACH = 4;
  FRAME_CLOSE = 5;

  FRAME_SESSION = 20;
  FRAME_SCREEN = 21;
  FRAME_READY = 22;
  FRAME_OUTPUT = 23;
  FRAME_EXIT = 24;
  FRAME_ERROR = 25;

  MAX_FRAME_SIZE = 64 * 1024 * 1024;

type
  TByteArray = array of byte;

  TSessionPaneSnapshot = record
    Title: string;
    Term: string;
    ScreenData: TByteArray;
  end;

  TSessionSnapshot = record
    LayoutNodes: string;
    Focused: integer;
    PaneCount: integer;
    Name: string;      // nombre de la sesion (cola tolerante del payload)
    Profile: string;   // perfil de origen ('' = ad-hoc)
    Panes: array[0..MAX_PANES - 1] of TSessionPaneSnapshot;
  end;

  TSessionEventKind = (sekOutput, sekExit, sekError, sekLost);

  TSessionEvent = record
    Kind: TSessionEventKind;
    Pane: integer;
    Data: TByteArray;
    Text: string;
  end;

  TSessionClient = class
  private
    FSocket: cint;
    FConnected: boolean;
    function SendFrame(AKind: byte; APane: integer;
      const Data: TByteArray): boolean;
    function ReadFrame(out AKind: byte; out APane: integer;
      out Data: TByteArray): boolean;
    procedure CloseSocket;
  public
    constructor Create;
    destructor Destroy; override;
    function Connect(const APath: string;
      out Snapshot: TSessionSnapshot): boolean;
    function Poll(out Event: TSessionEvent): boolean;
    function SendInput(APane: integer; const S: RawByteString): boolean;
    function SendResize(APane, ACols, ARows: integer): boolean;
    function Detach: boolean;
    function CloseSession: boolean;
    property Connected: boolean read FConnected;
  end;

type
  // arrays tipados: los open arrays const disparan un hint espurio de
  // "assigned but never used" cuando -Cr (checks de rango) esta activo
  TPtyArray = array of TPty;
  TScreenArray = array of TScreen;
  TStrArray = array of string;

type
  // sesion separada descubierta en disco (socket + sidecar de metadatos)
  TSessionInfo = record
    Name: string;
    Profile: string;
    PaneCount: integer;
    Pid: integer;
    Created: string;
    SocketPath: string;
    Legacy: boolean;   // socket unico antiguo ~/.superterm/session.sock
  end;
  TSessionInfoArray = array of TSessionInfo;

function SessionSocketPath: string;      // ruta legada (un solo socket)
function SessionSocketIsLive: boolean;   // sonda de la ruta legada
function SessionsDir: string;            // ~/.superterm/sessions (0700)
function SanitizeSessionName(const S: string): string;
function SessionSocketPathFor(const AName: string): string;
function SessionIsLive(const APath: string): boolean;
// enumera sesiones vivas (sondea cada socket; purga huerfanos y sidecars;
// incluye el socket legado como '(sin nombre)')
function EnumerateSessions(out Infos: TSessionInfoArray): boolean;
// nombre libre a partir de una base: base, base-2, base-3...
function SuggestSessionName(const ABase: string): string;
// cierre permanente de una sesion separada por su socket (FRAME_CLOSE)
function CloseSessionAt(const APath: string): boolean;
function StartDetachedServer(const AName, AProfile: string; ALay: TLayout;
  const APanes: TPtyArray; const AScreens: TScreenArray;
  const ATitles: TStrArray; const ATerms: TStrArray;
  AFocused: integer): boolean;

var
  AttachRequested: boolean = False;
  AttachSocket: string = '';   // socket resuelto por la CLI ('' = selector)

implementation

type
  TFrameHeader = packed record
    Kind: byte;
    Reserved: byte;
    Pane: SmallInt;
    Size: LongWord;
  end;

  TDetachedSession = class
  private
    FLayout: TLayout;
    FPaneCount: integer;
    FFocused: integer;
    FPanes: array[0..MAX_PANES - 1] of TPty;
    FScreens: array[0..MAX_PANES - 1] of TScreen;
    FTitles: array[0..MAX_PANES - 1] of string;
    FTerms: array[0..MAX_PANES - 1] of string;
    FSocketPath: string;
    FMetaPath: string;
    FName: string;
    FProfile: string;
    FListener: cint;
    FClient: cint;
    FStop: boolean;
    function CreateListener: boolean;
    function SendFrame(AKind: byte; APane: integer;
      const Data: TByteArray): boolean;
    function SendRawFrame(AKind: byte; APane: integer;
      const Buffer; ASize: integer): boolean;
    function ReadFrame(AFd: cint; out AKind: byte; out APane: integer;
      out Data: TByteArray): boolean;
    function SendSnapshot(AFd: cint): boolean;
    function HandleAttach(AFd: cint): boolean;
    function HandleClientFrame(var AClient: cint): boolean;
    procedure HandlePaneOutput(APane: integer);
    procedure CloseClient(var AClient: cint);
    procedure SignalReady(AFd: cint; AOk: boolean);
    procedure WriteSidecar;
  public
    constructor Create(const AName, AProfile: string; ALay: TLayout;
      const APanes: TPtyArray; const AScreens: TScreenArray;
      const ATitles: TStrArray; const ATerms: TStrArray;
      AFocused: integer);
    destructor Destroy; override;
    procedure Run(AReadyFd: cint);
  end;

function WriteFull(AFd: cint; const Buffer; ASize: integer): boolean;
var
  P: PByte;
  Left, N: integer;
begin
  Result := False;
  if ASize < 0 then
    Exit;
  if ASize = 0 then
    Exit(True);
  P := @Buffer;
  Left := ASize;
  while Left > 0 do
  begin
    // FileWrite already retries EINTR internally, so any non-positive
    // result here is a definitive error.
    N := FileWrite(AFd, P^, Left);
    if N <= 0 then
      Exit;
    Inc(P, N);
    Dec(Left, N);
  end;
  Result := True;
end;

function ReadFull(AFd: cint; var Buffer; ASize: integer): boolean;
var
  P: PByte;
  Left, N: integer;
begin
  Result := False;
  if ASize < 0 then
    Exit;
  if ASize = 0 then
    Exit(True);
  P := @Buffer;
  Left := ASize;
  while Left > 0 do
  begin
    // FileRead retries EINTR internally; 0 means end of stream and a
    // negative result is a definitive error.
    N := FileRead(AFd, P^, Left);
    if N <= 0 then
      Exit;
    Inc(P, N);
    Dec(Left, N);
  end;
  Result := True;
end;

procedure WriteString(Stream: TStream; const S: string);
var
  L: Longint;
begin
  L := Length(S);
  Stream.WriteBuffer(L, SizeOf(L));
  if L > 0 then
    Stream.WriteBuffer(S[1], L);
end;

function ReadString(Stream: TStream; out S: string): boolean;
var
  L: Longint;
begin
  Result := False;
  S := '';
  L := Default(Longint);
  Stream.ReadBuffer(L, SizeOf(L));
  if (L < 0) or (L > 1024 * 1024) then
    Exit;
  SetLength(S, L);
  if L > 0 then
    Stream.ReadBuffer(S[1], L);
  Result := True;
end;

function WriteFrameTo(AFd: cint; AKind: byte; APane: integer;
  const Data: TByteArray): boolean;
var
  H: TFrameHeader;
begin
  if Length(Data) > MAX_FRAME_SIZE then
    Exit(False);
  H := Default(TFrameHeader);
  H.Kind := AKind;
  H.Pane := APane;
  H.Size := Length(Data);
  Result := WriteFull(AFd, H, SizeOf(H));
  if Result and (Length(Data) > 0) then
    Result := WriteFull(AFd, Data[0], Length(Data));
end;

function WriteRawFrameTo(AFd: cint; AKind: byte; APane: integer;
  const Buffer; ASize: integer): boolean;
var
  H: TFrameHeader;
begin
  if (ASize < 0) or (ASize > MAX_FRAME_SIZE) then
    Exit(False);
  H := Default(TFrameHeader);
  H.Kind := AKind;
  H.Pane := APane;
  H.Size := ASize;
  Result := WriteFull(AFd, H, SizeOf(H));
  if Result and (ASize > 0) then
    Result := WriteFull(AFd, Buffer, ASize);
end;

function ReadFrameFrom(AFd: cint; out AKind: byte; out APane: integer;
  out Data: TByteArray): boolean;
var
  H: TFrameHeader;
begin
  Result := False;
  AKind := 0;
  APane := -1;
  Data := nil;
  H := Default(TFrameHeader);
  if not ReadFull(AFd, H, SizeOf(H)) then
    Exit;
  if H.Size > MAX_FRAME_SIZE then
    Exit;
  AKind := H.Kind;
  APane := H.Pane;
  SetLength(Data, H.Size);
  if (H.Size > 0) and (not ReadFull(AFd, Data[0], H.Size)) then
  begin
    Data := nil;
    Exit;
  end;
  Result := True;
end;

function SocketAddress(const Path: string; out Addr: TUnixSockAddr;
  out AddrLen: TSockLen): boolean;
begin
  Result := False;
  Addr := Default(TUnixSockAddr);
  if (Path = '') or (Length(Path) >= Length(Addr.path)) then
    Exit;
  Addr.family := AF_UNIX;
  Move(Path[1], Addr.path[0], Length(Path));
  Addr.path[Length(Path)] := #0;
  AddrLen := SizeOf(Addr.family) + Length(Path) + 1;
  Result := True;
end;

function ConnectSocket(const APath: string): cint;
var
  Addr: TUnixSockAddr;
  AddrLen: TSockLen;
begin
  Result := -1;
  if not SocketAddress(APath, Addr, AddrLen) then
    Exit;
  Result := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if Result < 0 then
    Exit;
  if fpConnect(Result, @Addr, AddrLen) <> 0 then
  begin
    FpClose(Result);
    Result := -1;
  end;
end;

function SessionSocketPath: string;
begin
  Result := ConfigDir + '/session.sock';
end;

function SessionIsLive(const APath: string): boolean;
var
  Fd: cint;
begin
  Fd := ConnectSocket(APath);
  Result := Fd >= 0;
  if Fd >= 0 then
    FpClose(Fd);
end;

function SessionSocketIsLive: boolean;
begin
  Result := SessionIsLive(SessionSocketPath);
end;

function SessionsDir: string;
begin
  Result := ConfigDir + '/sessions';
  if not DirectoryExists(Result) then
    ForceDirectories(Result);
  if DirectoryExists(Result) then
    FpChmod(PAnsiChar(Result), &700);
end;

function SanitizeSessionName(const S: string): string;
var
  i: integer;
  c: char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if c in ['A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-'] then
      Result := Result + c
    else
      Result := Result + '-';
  end;
  while (Result <> '') and (Result[1] in ['.', '-']) do
    Delete(Result, 1, 1);
  if Length(Result) > 64 then
    SetLength(Result, 64);
  if Result = '' then
    Result := 'sesion';
end;

function SessionSocketPathFor(const AName: string): string;
begin
  Result := SessionsDir + '/' + SanitizeSessionName(AName) + '.sock';
end;

function SessionMetaPathFor(const AName: string): string;
begin
  Result := SessionsDir + '/' + SanitizeSessionName(AName) + '.ini';
end;

function EnumerateSessions(out Infos: TSessionInfoArray): boolean;
var
  SR: TSearchRec;
  Ini: TIniFile;
  Info: TSessionInfo;
  Dir, MetaPath: string;
begin
  Infos := nil;
  Dir := SessionsDir;
  if FindFirst(Dir + '/*.sock', faAnyFile, SR) = 0 then
  begin
    repeat
      Info := Default(TSessionInfo);
      Info.SocketPath := Dir + '/' + SR.Name;
      Info.Name := ChangeFileExt(SR.Name, '');
      MetaPath := Dir + '/' + Info.Name + '.ini';
      if not SessionIsLive(Info.SocketPath) then
      begin
        // huerfana: purgar socket y sidecar
        DeleteFile(Info.SocketPath);
        if FileExists(MetaPath) then
          DeleteFile(MetaPath);
        continue;
      end;
      if FileExists(MetaPath) then
      begin
        Ini := TIniFile.Create(MetaPath);
        try
          Info.Name := Ini.ReadString('session', 'name', Info.Name);
          Info.Profile := Ini.ReadString('session', 'profile', '');
          Info.PaneCount := Ini.ReadInteger('session', 'panes', 0);
          Info.Pid := Ini.ReadInteger('session', 'pid', 0);
          Info.Created := Ini.ReadString('session', 'created', '');
        finally
          Ini.Free;
        end;
      end;
      SetLength(Infos, Length(Infos) + 1);
      Infos[High(Infos)] := Info;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  // transicion: el socket unico de una version anterior
  if FileExists(SessionSocketPath) then
  begin
    if SessionIsLive(SessionSocketPath) then
    begin
      Info := Default(TSessionInfo);
      Info.Name := '(sin nombre)';
      Info.SocketPath := SessionSocketPath;
      Info.Legacy := True;
      SetLength(Infos, Length(Infos) + 1);
      Infos[High(Infos)] := Info;
    end
    else
      DeleteFile(SessionSocketPath);
  end;
  Result := Length(Infos) > 0;
end;

function CloseSessionAt(const APath: string): boolean;
var
  Fd: cint;
  Data: TByteArray;
begin
  Result := False;
  Fd := ConnectSocket(APath);
  if Fd < 0 then
    Exit;
  Data := nil;
  Result := WriteFrameTo(Fd, FRAME_CLOSE, -1, Data);
  FpClose(Fd);
end;

function SuggestSessionName(const ABase: string): string;
var
  Base: string;
  N: integer;
begin
  Base := SanitizeSessionName(ABase);
  Result := Base;
  N := 1;
  while SessionIsLive(SessionSocketPathFor(Result)) do
  begin
    Inc(N);
    Result := Base + '-' + IntToStr(N);
  end;
end;

constructor TSessionClient.Create;
begin
  inherited Create;
  FSocket := -1;
  FConnected := False;
end;

procedure TSessionClient.CloseSocket;
begin
  if FSocket >= 0 then
    FpClose(FSocket);
  FSocket := -1;
  FConnected := False;
end;

destructor TSessionClient.Destroy;
begin
  CloseSocket;
  inherited Destroy;
end;

function TSessionClient.SendFrame(AKind: byte; APane: integer;
  const Data: TByteArray): boolean;
begin
  Result := FConnected and WriteFrameTo(FSocket, AKind, APane, Data);
end;

function TSessionClient.ReadFrame(out AKind: byte; out APane: integer;
  out Data: TByteArray): boolean;
begin
  Result := FConnected and ReadFrameFrom(FSocket, AKind, APane, Data);
end;

function TSessionClient.Connect(const APath: string;
  out Snapshot: TSessionSnapshot): boolean;
var
  Kind: byte;
  Pane: integer;
  Data: TByteArray;
  Stream: TMemoryStream;
  I: integer;
begin
  Result := False;
  Snapshot.LayoutNodes := '';
  Snapshot.Focused := 0;
  Snapshot.PaneCount := 0;
  Snapshot.Name := '';
  Snapshot.Profile := '';
  for I := 0 to MAX_PANES - 1 do
  begin
    Snapshot.Panes[I].Title := '';
    Snapshot.Panes[I].Term := '';
    Snapshot.Panes[I].ScreenData := nil;
  end;
  FSocket := ConnectSocket(APath);
  if FSocket < 0 then
    Exit;
  FConnected := True;
  Data := nil;
  if not SendFrame(FRAME_ATTACH, -1, Data) then
  begin
    CloseSocket;
    Exit;
  end;
  if not ReadFrame(Kind, Pane, Data) or (Kind <> FRAME_SESSION) then
  begin
    CloseSocket;
    Exit;
  end;
  Stream := TMemoryStream.Create;
  try
    if Length(Data) > 0 then
      Stream.WriteBuffer(Data[0], Length(Data));
    Stream.Position := 0;
    if not ReadString(Stream, Snapshot.LayoutNodes) then
      Exit;
    Stream.ReadBuffer(Snapshot.Focused, SizeOf(Snapshot.Focused));
    Stream.ReadBuffer(Snapshot.PaneCount, SizeOf(Snapshot.PaneCount));
    if (Snapshot.PaneCount < 1) or (Snapshot.PaneCount > MAX_PANES) then
      Exit;
    for I := 0 to Snapshot.PaneCount - 1 do
    begin
      if not ReadString(Stream, Snapshot.Panes[I].Title) then
        Exit;
      if not ReadString(Stream, Snapshot.Panes[I].Term) then
        Exit;
    end;
    // cola tolerante: un daemon de una version anterior no la envia
    if Stream.Position + SizeOf(Longint) <= Stream.Size then
      if not ReadString(Stream, Snapshot.Name) then
        Snapshot.Name := '';
    if Stream.Position + SizeOf(Longint) <= Stream.Size then
      if not ReadString(Stream, Snapshot.Profile) then
        Snapshot.Profile := '';
  finally
    Stream.Free;
  end;
  for I := 0 to Snapshot.PaneCount - 1 do
  begin
    if not ReadFrame(Kind, Pane, Data) or (Kind <> FRAME_SCREEN) or
       (Pane <> I) then
    begin
      CloseSocket;
      Exit;
    end;
    Snapshot.Panes[I].ScreenData := Copy(Data, 0, Length(Data));
  end;
  if not ReadFrame(Kind, Pane, Data) or (Kind <> FRAME_READY) then
  begin
    CloseSocket;
    Exit;
  end;
  Result := Snapshot.LayoutNodes <> '';
  if not Result then
    CloseSocket;
end;

function TSessionClient.Poll(out Event: TSessionEvent): boolean;
var
  SetRead: TFDSet;
  TV: TTimeVal;
  MaxFd: cint;
  Kind: byte;
  Pane: integer;
begin
  Event.Kind := sekLost;
  Event.Pane := -1;
  Event.Data := nil;
  Event.Text := '';
  Result := False;
  if not FConnected then
    Exit;
  fpFD_ZERO(SetRead);
  fpFD_SET(FSocket, SetRead);
  TV.tv_sec := 0;
  TV.tv_usec := 0;
  MaxFd := fpSelect(FSocket + 1, @SetRead, nil, nil, @TV);
  if MaxFd <= 0 then
    Exit;
  if fpFD_ISSET(FSocket, SetRead) = 0 then
    Exit;
  if not ReadFrame(Kind, Pane, Event.Data) then
  begin
    CloseSocket;
    Event.Kind := sekLost;
    Exit(True);
  end;
  Event.Pane := Pane;
  case Kind of
    FRAME_OUTPUT: Event.Kind := sekOutput;
    FRAME_EXIT: Event.Kind := sekExit;
    FRAME_ERROR:
      begin
        Event.Kind := sekError;
        if Length(Event.Data) > 0 then
          SetString(Event.Text, PAnsiChar(@Event.Data[0]), Length(Event.Data));
      end;
  else
    Event.Data := nil;
  end;
  Result := True;
end;

function TSessionClient.SendInput(APane: integer; const S: RawByteString): boolean;
var
  Data: TByteArray;
begin
  Data := Default(TByteArray);
  SetLength(Data, Length(S));
  if Length(Data) > 0 then
    Move(S[1], Data[0], Length(Data));
  Result := SendFrame(FRAME_INPUT, APane, Data);
end;

function TSessionClient.SendResize(APane, ACols, ARows: integer): boolean;
var
  Data: TByteArray;
begin
  Data := Default(TByteArray);
  SetLength(Data, SizeOf(ACols) + SizeOf(ARows));
  Move(ACols, Data[0], SizeOf(ACols));
  Move(ARows, Data[SizeOf(ACols)], SizeOf(ARows));
  Result := SendFrame(FRAME_RESIZE, APane, Data);
end;

function TSessionClient.Detach: boolean;
var
  Data: TByteArray;
begin
  Data := nil;
  Result := SendFrame(FRAME_DETACH, -1, Data);
  CloseSocket;
end;

function TSessionClient.CloseSession: boolean;
var
  Data: TByteArray;
begin
  Data := nil;
  Result := SendFrame(FRAME_CLOSE, -1, Data);
  CloseSocket;
end;

constructor TDetachedSession.Create(const AName, AProfile: string;
  ALay: TLayout;
  const APanes: TPtyArray; const AScreens: TScreenArray;
  const ATitles: TStrArray; const ATerms: TStrArray;
  AFocused: integer);
var
  I: integer;
begin
  inherited Create;
  FLayout := ALay;
  FPaneCount := Length(APanes);
  if FPaneCount > MAX_PANES then
    FPaneCount := MAX_PANES;
  FFocused := AFocused;
  if FFocused < 0 then FFocused := 0;
  if FFocused >= FPaneCount then FFocused := FPaneCount - 1;
  for I := 0 to FPaneCount - 1 do
  begin
    FPanes[I] := APanes[I];
    FScreens[I] := AScreens[I];
    if I <= High(ATitles) then FTitles[I] := ATitles[I];
    if I <= High(ATerms) then FTerms[I] := ATerms[I];
  end;
  FName := SanitizeSessionName(AName);
  FProfile := AProfile;
  FSocketPath := SessionSocketPathFor(FName);
  FMetaPath := SessionMetaPathFor(FName);
  FListener := -1;
  FClient := -1;
  FStop := False;
end;

destructor TDetachedSession.Destroy;
var
  I: integer;
begin
  CloseClient(FClient);
  if FListener >= 0 then
    FpClose(FListener);
  if FileExists(FSocketPath) then
    DeleteFile(FSocketPath);
  if (FMetaPath <> '') and FileExists(FMetaPath) then
    DeleteFile(FMetaPath);
  for I := 0 to FPaneCount - 1 do
  begin
    if FPanes[I] <> nil then
    begin
      FPanes[I].KillPane;
      FPanes[I].Free;
      FPanes[I] := nil;
    end;
    FScreens[I].Free;
    FScreens[I] := nil;
  end;
  FLayout.Free;
  inherited Destroy;
end;

function TDetachedSession.CreateListener: boolean;
var
  Addr: TUnixSockAddr;
  AddrLen: TSockLen;
begin
  Result := False;
  if SessionIsLive(FSocketPath) then
    Exit;
  if FileExists(FSocketPath) then
    DeleteFile(FSocketPath);
  if not SocketAddress(FSocketPath, Addr, AddrLen) then
    Exit;
  FListener := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if FListener < 0 then
    Exit;
  if fpBind(FListener, @Addr, AddrLen) <> 0 then
  begin
    FpClose(FListener);
    FListener := -1;
    Exit;
  end;
  if fpListen(FListener, 4) <> 0 then
  begin
    FpClose(FListener);
    FListener := -1;
    DeleteFile(FSocketPath);
    Exit;
  end;
  FpChmod(PAnsiChar(FSocketPath), &600);
  Result := True;
end;

function TDetachedSession.SendFrame(AKind: byte; APane: integer;
  const Data: TByteArray): boolean;
begin
  Result := (FClient >= 0) and WriteFrameTo(FClient, AKind, APane, Data);
end;

function TDetachedSession.SendRawFrame(AKind: byte; APane: integer;
  const Buffer; ASize: integer): boolean;
begin
  Result := (FClient >= 0) and WriteRawFrameTo(FClient, AKind, APane,
    Buffer, ASize);
end;

function TDetachedSession.ReadFrame(AFd: cint; out AKind: byte;
  out APane: integer; out Data: TByteArray): boolean;
begin
  Result := ReadFrameFrom(AFd, AKind, APane, Data);
end;

function TDetachedSession.SendSnapshot(AFd: cint): boolean;
var
  Meta, ScreenData: TMemoryStream;
  Data: TByteArray;
  I: integer;
  Nodes: string;
begin
  Result := False;
  Data := Default(TByteArray);
  Meta := TMemoryStream.Create;
  try
    Nodes := SaveLayoutString(FLayout);
    WriteString(Meta, Nodes);
    Meta.WriteBuffer(FFocused, SizeOf(FFocused));
    Meta.WriteBuffer(FPaneCount, SizeOf(FPaneCount));
    for I := 0 to FPaneCount - 1 do
    begin
      WriteString(Meta, FTitles[I]);
      WriteString(Meta, FTerms[I]);
    end;
    // cola tolerante (los clientes antiguos la ignoran al no leerla)
    WriteString(Meta, FName);
    WriteString(Meta, FProfile);
    SetLength(Data, Meta.Size);
    if Meta.Size > 0 then
    begin
      Meta.Position := 0;
      Meta.ReadBuffer(Data[0], Meta.Size);
    end;
    if not WriteFrameTo(AFd, FRAME_SESSION, -1, Data) then
      Exit;
  finally
    Meta.Free;
  end;
  for I := 0 to FPaneCount - 1 do
  begin
    ScreenData := TMemoryStream.Create;
    try
      if FScreens[I] <> nil then
        FScreens[I].SaveToStream(ScreenData);
      SetLength(Data, ScreenData.Size);
      if ScreenData.Size > 0 then
      begin
        ScreenData.Position := 0;
        ScreenData.ReadBuffer(Data[0], ScreenData.Size);
      end;
      if not WriteFrameTo(AFd, FRAME_SCREEN, I, Data) then
        Exit;
    finally
      ScreenData.Free;
    end;
  end;
  Data := nil;
  Result := WriteFrameTo(AFd, FRAME_READY, -1, Data);
end;

function TDetachedSession.HandleAttach(AFd: cint): boolean;
var
  Kind: byte;
  Pane: integer;
  Data: TByteArray;
begin
  Result := False;
  if not ReadFrame(AFd, Kind, Pane, Data) or (Kind <> FRAME_ATTACH) then
    Exit;
  Result := SendSnapshot(AFd);
end;

procedure TDetachedSession.CloseClient(var AClient: cint);
begin
  if AClient >= 0 then
    FpClose(AClient);
  AClient := -1;
end;

function TDetachedSession.HandleClientFrame(var AClient: cint): boolean;
var
  Kind: byte;
  Pane: integer;
  Data: TByteArray;
  Cols, Rows: integer;
  S: RawByteString;
begin
  Result := True;
  if not ReadFrame(AClient, Kind, Pane, Data) then
  begin
    CloseClient(AClient);
    Exit;
  end;
  case Kind of
    FRAME_INPUT:
      if (Pane >= 0) and (Pane < FPaneCount) and (FPanes[Pane] <> nil) and
         (Length(Data) > 0) then
      begin
        SetString(S, PAnsiChar(@Data[0]), Length(Data));
        FPanes[Pane].WriteStr(S);
      end;
    FRAME_RESIZE:
      if (Pane >= 0) and (Pane < FPaneCount) and (Length(Data) = 8) then
      begin
        Cols := Default(integer);
        Rows := Default(integer);
        Move(Data[0], Cols, SizeOf(Cols));
        Move(Data[4], Rows, SizeOf(Rows));
        if (Cols > 0) and (Rows > 0) then
        begin
          if FScreens[Pane] <> nil then
            FScreens[Pane].Resize(Cols, Rows);
          if FPanes[Pane] <> nil then
            FPanes[Pane].Resize(Cols, Rows);
        end;
      end;
    FRAME_DETACH:
      CloseClient(AClient);
    FRAME_CLOSE:
      begin
        CloseClient(AClient);
        FStop := True;
      end;
  end;
end;

procedure TDetachedSession.HandlePaneOutput(APane: integer);
var
  Buf: array[0..MAXREAD - 1] of byte;
  N: integer;
begin
  if (APane < 0) or (APane >= FPaneCount) or (FPanes[APane] = nil) or
     (not FPanes[APane].Alive) then
    Exit;
  N := FPanes[APane].ReadBuf(Buf);
  if N > 0 then
  begin
    if FScreens[APane] <> nil then
      FScreens[APane].WriteBytes(Buf, N);
    if FClient >= 0 then
      if not SendRawFrame(FRAME_OUTPUT, APane, Buf, N) then
        CloseClient(FClient);
  end
  else if (N = 0) or (fpgeterrno <> ESysEAGAIN) then
  begin
    FPanes[APane].MarkDead;
    if FClient >= 0 then
      if not SendRawFrame(FRAME_EXIT, APane, Buf, 0) then
        CloseClient(FClient);
  end;
end;

// sidecar de metadatos: permite al selector mostrar nombre/perfil/paneles
// sin consumir el unico slot de cliente del socket
procedure TDetachedSession.WriteSidecar;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(FMetaPath);
  try
    Ini.WriteString('session', 'name', FName);
    Ini.WriteString('session', 'profile', FProfile);
    Ini.WriteInteger('session', 'panes', FPaneCount);
    Ini.WriteInteger('session', 'pid', fpGetPid);
    Ini.WriteString('session', 'created',
      FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
  FpChmod(PAnsiChar(FMetaPath), &600);
end;

procedure TDetachedSession.SignalReady(AFd: cint; AOk: boolean);
var
  B: byte;
begin
  if AFd < 0 then
    Exit;
  if AOk then B := 1 else B := 0;
  WriteFull(AFd, B, SizeOf(B));
  FpClose(AFd);
end;

procedure TDetachedSession.Run(AReadyFd: cint);
var
  ReadSet: TFDSet;
  TV: TTimeVal;
  MaxFd, I, NewClient, N: cint;
  Addr: TUnixSockAddr;
  AddrLen: TSockLen;
begin
  FpSignal(SIGHUP, SignalHandler(SIG_IGN));
  FpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  if not CreateListener then
  begin
    SignalReady(AReadyFd, False);
    Exit;
  end;
  WriteSidecar;
  SignalReady(AReadyFd, True);
  while not FStop do
  begin
    fpFD_ZERO(ReadSet);
    MaxFd := FListener;
    fpFD_SET(FListener, ReadSet);
    if FClient >= 0 then
    begin
      fpFD_SET(FClient, ReadSet);
      if FClient > MaxFd then MaxFd := FClient;
    end;
    for I := 0 to FPaneCount - 1 do
      if (FPanes[I] <> nil) and FPanes[I].Alive and
         (FPanes[I].Master >= 0) then
      begin
        fpFD_SET(FPanes[I].Master, ReadSet);
        if FPanes[I].Master > MaxFd then MaxFd := FPanes[I].Master;
      end;
    TV.tv_sec := 0;
    TV.tv_usec := 100000;
    N := fpSelect(MaxFd + 1, @ReadSet, nil, nil, @TV);
    if N < 0 then
    begin
      if fpgeterrno = ESysEINTR then
        continue;
      Break;
    end;
    if fpFD_ISSET(FListener, ReadSet) <> 0 then
    begin
      Addr := Default(TUnixSockAddr);
      AddrLen := SizeOf(Addr);
      NewClient := fpAccept(FListener, @Addr, @AddrLen);
      if NewClient >= 0 then
      begin
        if FClient < 0 then
        begin
          if HandleAttach(NewClient) then
            FClient := NewClient
          else
            FpClose(NewClient);
        end
        else
          FpClose(NewClient);
      end;
    end;
    if (FClient >= 0) and (fpFD_ISSET(FClient, ReadSet) <> 0) then
      HandleClientFrame(FClient);
    for I := 0 to FPaneCount - 1 do
      if (FPanes[I] <> nil) and FPanes[I].Alive and
         (FPanes[I].Master >= 0) and
         (fpFD_ISSET(FPanes[I].Master, ReadSet) <> 0) then
        HandlePaneOutput(I);
  end;
end;

function StartDetachedServer(const AName, AProfile: string; ALay: TLayout;
  const APanes: TPtyArray; const AScreens: TScreenArray;
  const ATitles: TStrArray; const ATerms: TStrArray;
  AFocused: integer): boolean;
var
  ReadyPipe: TFilDes;
  Pid: TPid;
  B: byte;
  Server: TDetachedSession;
begin
  Result := False;
  if (ALay = nil) or (Length(APanes) < 1) or
     SessionIsLive(SessionSocketPathFor(AName)) then
    Exit;
  ReadyPipe := Default(TFilDes);
  if FpPipe(ReadyPipe) <> 0 then
    Exit;
  Pid := FpFork;
  if Pid = 0 then
  begin
    FpClose(ReadyPipe[0]);
    if FpSetsid < 0 then
    begin
      B := 0;
      WriteFull(ReadyPipe[1], B, SizeOf(B));
      FpClose(ReadyPipe[1]);
      FpExit(1);
    end;
    // The detached server has no terminal UI. Closing the inherited client
    // descriptors lets the launching shell regain the terminal cleanly.
    FpClose(0);
    FpClose(1);
    FpClose(2);
    Server := TDetachedSession.Create(AName, AProfile, ALay, APanes,
      AScreens, ATitles, ATerms, AFocused);
    try
      Server.Run(ReadyPipe[1]);
    finally
      Server.Free;
    end;
    FpExit(0);
  end;
  FpClose(ReadyPipe[1]);
  if Pid < 0 then
  begin
    FpClose(ReadyPipe[0]);
    Exit;
  end;
  B := 0;
  if (FileRead(ReadyPipe[0], B, SizeOf(B)) = SizeOf(B)) and (B <> 0) then
    Result := True;
  FpClose(ReadyPipe[0]);
end;

end.
