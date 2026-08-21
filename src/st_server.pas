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
  st_config, st_wclass, st_layout, st_pty, st_screen, st_session;

const
  FRAME_ATTACH = 1;
  FRAME_INPUT = 2;
  FRAME_RESIZE = 3;
  FRAME_DETACH = 4;
  FRAME_CLOSE = 5;
  FRAME_KILLPANE = 6;   // cliente enganchado cierra un panel
  FRAME_LAYOUT = 7;     // cliente enganchado sincroniza arbol/geometria

  // control efimero: una conexion, un frame de peticion, respuesta y cierre;
  // nunca ocupa el slot de cliente interactivo (patron de FRAME_CLOSE)
  FRAME_CTL_LIST = 11;     // detalles de sesion y paneles
  FRAME_CTL_SEND = 12;     // texto crudo a un panel
  FRAME_CTL_CAPTURE = 13;  // captura de pantalla/historial como texto
  FRAME_CTL_WINOP = 14;    // gestion de ventanas (reservado)
  FRAME_CTL_INFO = 15;     // solo cabecera de sesion

  FRAME_SESSION = 20;
  FRAME_SCREEN = 21;
  FRAME_READY = 22;
  FRAME_OUTPUT = 23;
  FRAME_EXIT = 24;
  FRAME_ERROR = 25;

  // respuestas de control
  FRAME_CTL_OK = 40;
  FRAME_CTL_ERR = 41;
  FRAME_CTL_DATA = 42;     // trozo de datos (texto o registros)
  FRAME_CTL_END = 43;      // fin de la respuesta

  // modos de captura (payload de FRAME_CTL_CAPTURE)
  CAPTURE_VISIBLE = 0;
  CAPTURE_ALL = 1;
  CAPTURE_LAST_N = 2;

  // sub-operaciones de FRAME_CTL_WINOP (byte Op al inicio del payload)
  WINOP_NEWPANE = 1;    // byte Dir(0=V,1=H); strings Class,Cmd,Cwd,Title
  WINOP_KILL = 2;       // panel en la cabecera
  WINOP_FOCUS = 3;
  WINOP_MINIMIZE = 4;
  WINOP_RESTORE = 5;    // deshace minimizar y zoom
  WINOP_ZOOM = 6;
  WINOP_ORGANIZE = 8;   // byte How: 0 rejilla, 1 mosaico, 2 cascada
  WINOP_RENAME = 9;     // string NewTitle
  WINOP_RESIZE = 10;    // Longint Cols, Rows (tamano del terminal)

  MAX_FRAME_SIZE = 64 * 1024 * 1024;

type
  TByteArray = array of byte;

  // arrays tipados: los open arrays const disparan un hint espurio de
  // "assigned but never used" cuando -Cr (checks de rango) esta activo
  TPtyArray = array of TPty;
  TScreenArray = array of TScreen;
  TStrArray = array of string;

  // geometria de una ventana del cliente (bounds absolutos del escritorio)
  TPaneGeom = record
    BX, BY, BW, BH: Longint;
    Zoomed: boolean;
    Minimized: boolean;
  end;
  TPaneGeomArray = array of TPaneGeom;

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
    // geometria de ventanas (cola tolerante 2; vacia si el daemon es viejo
    // o nunca recibio un FRAME_LAYOUT); bounds absolutos para DeskW x DeskH
    Geom: TPaneGeomArray;
    DeskW, DeskH: Longint;
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
    // cierre de un panel del daemon (el cliente compacta en espejo)
    function SendKillPane(APane: integer): boolean;
    // sincroniza arbol de splits, foco, titulos y geometria de ventanas
    function SendLayout(const ANodes: string; AFocused: integer;
      const ATitles: TStrArray; const AGeom: TPaneGeomArray;
      ADeskW, ADeskH: integer): boolean;
    property Connected: boolean read FConnected;
  end;

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
// cierre permanente de una sesion separada por su socket (FRAME_CLOSE);
// espera brevemente y solo devuelve True si el daemon murio de verdad
function CloseSessionAt(const APath: string): boolean;

type
  // callback de datos para peticiones de control con respuesta en trozos
  TCtlDataProc = procedure(const AChunk: TByteArray) of object;

// peticion de control simple (OK/ERR): conecta, envia un frame, espera la
// respuesta y cierra; AReply lleva el mensaje de error si lo hay
function CtlSimple(const ASocket: string; AKind: byte; APane: integer;
  const APayload: TByteArray; out AReply: string): boolean;

// peticion de control con datos (LIST/CAPTURE/INFO): igual pero entregando
// cada FRAME_CTL_DATA por el callback hasta FRAME_CTL_END
function CtlStream(const ASocket: string; AKind: byte; APane: integer;
  const APayload: TByteArray; AOnData: TCtlDataProc): boolean;

function StartDetachedServer(const AName, AProfile: string; ALay: TLayout;
  const APanes: TPtyArray; const AScreens: TScreenArray;
  const ATitles: TStrArray; const ATerms: TStrArray;
  AFocused: integer; const AGeom: TPaneGeomArray;
  ADeskW, ADeskH: integer): boolean;

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
    FGeom: array[0..MAX_PANES - 1] of TPaneGeom;
    FGeomValid: boolean;
    FDeskW, FDeskH: Longint;
    FCtlClasses: TWindowClassArray;   // clases resueltas para LIST (lazy)
    FCtlClassesLoaded: boolean;
    FCtlCfg: TConfig;                 // config para spawns daemon-side
    function CreateListener: boolean;
    function SendFrame(AKind: byte; APane: integer;
      const Data: TByteArray): boolean;
    function SendRawFrame(AKind: byte; APane: integer;
      const Buffer; ASize: integer): boolean;
    function ReadFrame(AFd: cint; out AKind: byte; out APane: integer;
      out Data: TByteArray): boolean;
    function SendSnapshot(AFd: cint): boolean;
    function ReadFirstFrame(AFd: cint; out AKind: byte;
      out APane: integer; out AData: TByteArray): boolean;
    procedure HandleControlFrame(AFd: cint; AKind: byte; APane: integer;
      const AData: TByteArray);
    procedure CtlReplyErr(AFd: cint; const AMsg: string);
    procedure CtlReplyOk(AFd: cint; const AMsg: string);
    procedure EnsureCtlConfig;
    procedure HandleWinOp(AFd: cint; APane: integer;
      const AData: TByteArray);
    function SpawnPaneForSpec(const AClass, ACmd, ACwd: string;
      ACols, ARows: integer; out APty: TPty; out ATerm: string): boolean;
    procedure ReapChildren;
    function HandleAttach(AFd: cint; AFirstKind: byte): boolean;
    function HandleClientFrame(var AClient: cint): boolean;
    procedure HandlePaneOutput(APane: integer);
    procedure CloseClient(var AClient: cint);
    procedure SignalReady(AFd: cint; AOk: boolean);
    procedure WriteSidecar;
    procedure DoKillPane(APane: integer);
    procedure ApplyLayoutFrame(const Data: TByteArray);
  public
    constructor Create(const AName, AProfile: string; ALay: TLayout;
      const APanes: TPtyArray; const AScreens: TScreenArray;
      const ATitles: TStrArray; const ATerms: TStrArray;
      AFocused: integer; const AGeom: TPaneGeomArray;
      ADeskW, ADeskH: integer);
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

// escritura completa con plazo total: select de escribibilidad por tramo y
// deadline acumulado; si el receptor no consume a tiempo, se aborta (un
// cliente de control muerto no debe colgar el bucle del daemon)
function WriteFullTimeout(AFd: cint; const Buffer; ASize: integer;
  ATotalMs: integer): boolean;
var
  P: PByte;
  Left, N: integer;
  SetW: TFDSet;
  TV: TTimeVal;
  Deadline: QWord;
  NowMs: QWord;
begin
  Result := False;
  if ASize < 0 then
    Exit;
  if ASize = 0 then
    Exit(True);
  P := @Buffer;
  Left := ASize;
  Deadline := GetTickCount64 + QWord(ATotalMs);
  while Left > 0 do
  begin
    NowMs := GetTickCount64;
    if NowMs >= Deadline then
      Exit;
    fpFD_ZERO(SetW);
    fpFD_SET(AFd, SetW);
    TV.tv_sec := (Deadline - NowMs) div 1000;
    TV.tv_usec := ((Deadline - NowMs) mod 1000) * 1000;
    if fpSelect(AFd + 1, nil, @SetW, nil, @TV) <= 0 then
      Exit;
    N := FileWrite(AFd, P^, Left);
    if N <= 0 then
      Exit;
    Inc(P, N);
    Dec(Left, N);
  end;
  Result := True;
end;

// frame completo (cabecera + payload) con el mismo plazo total
function WriteFrameToTimeout(AFd: cint; AKind: byte; APane: integer;
  const Data: TByteArray; ATotalMs: integer): boolean;
var
  H: TFrameHeader;
begin
  Result := False;
  if Length(Data) > MAX_FRAME_SIZE then
    Exit;
  H := Default(TFrameHeader);
  H.Kind := AKind;
  H.Pane := APane;
  H.Size := Length(Data);
  if not WriteFullTimeout(AFd, H, SizeOf(H), ATotalMs) then
    Exit;
  if Length(Data) > 0 then
    Result := WriteFullTimeout(AFd, Data[0], Length(Data), ATotalMs)
  else
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

// lectura tolerante de la cola del snapshot: valida que el prefijo de
// longitud Y el cuerpo de la cadena quepan en lo que queda del stream;
// ante cualquier violacion deja S en '' y devuelve False sin lanzar
// excepciones (ReadBuffer lanzaria EReadError con una cola truncada)
function ReadTailString(Stream: TStream; out S: string): boolean;
var
  L: Longint;
begin
  Result := False;
  S := '';
  if Stream.Position + SizeOf(Longint) > Stream.Size then
    Exit;
  L := Default(Longint);
  Stream.ReadBuffer(L, SizeOf(L));
  if (L < 0) or (Stream.Position + L > Stream.Size) then
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

type
  // resultado de sondear un socket de sesion: vivo, rechazo duro
  // (candidato a purga) o timeout/saturacion (no vivo, nunca purgable)
  TSocketProbe = (spLive, spDead, spTimeout);

// sonda con connect no bloqueante y espera acotada (~300 ms): un daemon
// colgado o con el backlog lleno no debe congelar la enumeracion
function ProbeSocket(const APath: string): TSocketProbe;
var
  Addr: TUnixSockAddr;
  AddrLen: TSockLen;
  Fd, Flags, Err: cint;
  ErrLen: TSockLen;
  SetWrite: TFDSet;
  TV: TTimeVal;
begin
  Result := spDead;
  if not SocketAddress(APath, Addr, AddrLen) then
    Exit;
  Fd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if Fd < 0 then
    Exit;
  Flags := FpFcntl(Fd, F_GETFL, 0);
  if Flags >= 0 then
    FpFcntl(Fd, F_SETFL, Flags or O_NONBLOCK);
  if fpConnect(Fd, @Addr, AddrLen) = 0 then
    Result := spLive
  else
    case fpgeterrno of
      ESysEINPROGRESS:
        begin
          // conexion en curso: esperar el desenlace con timeout
          fpFD_ZERO(SetWrite);
          fpFD_SET(Fd, SetWrite);
          TV.tv_sec := 0;
          TV.tv_usec := 300000;
          if fpSelect(Fd + 1, nil, @SetWrite, nil, @TV) <= 0 then
            Result := spTimeout
          else
          begin
            Err := 0;
            ErrLen := SizeOf(Err);
            if (fpGetSockOpt(Fd, SOL_SOCKET, SO_ERROR, @Err, @ErrLen) = 0)
               and (Err = 0) then
              Result := spLive;
          end;
        end;
      ESysEAGAIN:
        // backlog lleno en AF_UNIX: el daemon existe pero no atiende
        Result := spTimeout;
    end;
  FpClose(Fd);
end;

// un .sock recien creado puede estar en la ventana bind->listen de un
// daemon arrancando: nunca purgar si su mtime es de hace <= 5 segundos
function SocketIsRecent(const APath: string): boolean;
var
  St: Stat;
begin
  Result := False;
  St := Default(Stat);
  if FpStat(APath, St) = 0 then
    Result := Abs(FpTime - St.st_mtime) <= 5;
end;

function SessionIsLive(const APath: string): boolean;
begin
  Result := ProbeSocket(APath) = spLive;
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

// TIniFile recorta un par de comillas exteriores al leer: si el valor
// empieza y termina con la misma comilla, se envuelve con otra capa igual
// para que la relectura devuelva el valor exacto (misma guarda que en
// st_profiles/st_wclass)
function IniQuoteGuard(const S: string): string;
begin
  Result := S;
  if (Length(S) >= 2) and (S[1] in ['''', '"']) and
     (S[Length(S)] = S[1]) then
    Result := S[1] + S + S[1];
end;

function EnumerateSessions(out Infos: TSessionInfoArray): boolean;
var
  SR: TSearchRec;
  Ini: TIniFile;
  Info: TSessionInfo;
  Probe: TSocketProbe;
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
      Probe := ProbeSocket(Info.SocketPath);
      if Probe <> spLive then
      begin
        // huerfana: purgar socket y sidecar, pero solo ante un rechazo
        // duro y con un socket que no sea reciente (un daemon arrancando
        // esta en la ventana bind->listen); en timeout no purgar nunca;
        // el sidecar solo cae si el socket se borro de verdad
        if (Probe = spDead) and (not SocketIsRecent(Info.SocketPath)) then
          if DeleteFile(Info.SocketPath) and FileExists(MetaPath) then
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
    Probe := ProbeSocket(SessionSocketPath);
    if Probe = spLive then
    begin
      Info := Default(TSessionInfo);
      Info.Name := '(sin nombre)';
      Info.SocketPath := SessionSocketPath;
      Info.Legacy := True;
      SetLength(Infos, Length(Infos) + 1);
      Infos[High(Infos)] := Info;
    end
    else if (Probe = spDead) and (not SocketIsRecent(SessionSocketPath)) then
      DeleteFile(SessionSocketPath);
  end;
  Result := Length(Infos) > 0;
end;

function CloseSessionAt(const APath: string): boolean;
var
  Fd: cint;
  Data: TByteArray;
  I: integer;
begin
  Result := False;
  Fd := ConnectSocket(APath);
  if Fd < 0 then
    Exit;
  Data := nil;
  if not WriteFrameTo(Fd, FRAME_CLOSE, -1, Data) then
  begin
    FpClose(Fd);
    Exit;
  end;
  FpClose(Fd);
  // booleano honesto: True solo cuando el daemon deja de responder de
  // verdad (un daemon antiguo ignora el FRAME_CLOSE y sigue vivo)
  for I := 1 to 20 do
  begin
    if not SessionIsLive(APath) then
      Exit(True);
    Sleep(100);
  end;
end;

function CtlSimple(const ASocket: string; AKind: byte; APane: integer;
  const APayload: TByteArray; out AReply: string): boolean;
var
  Fd: cint;
  RKind: byte;
  RPane: integer;
  RData: TByteArray;
begin
  Result := False;
  AReply := '';
  Fd := ConnectSocket(ASocket);
  if Fd < 0 then
    Exit;
  try
    if not WriteFrameTo(Fd, AKind, APane, APayload) then
      Exit;
    if not ReadFrameFrom(Fd, RKind, RPane, RData) then
      Exit;
    if RKind = FRAME_CTL_OK then
      Result := True
    else if (RKind = FRAME_CTL_ERR) and (Length(RData) > 0) then
      SetString(AReply, PAnsiChar(@RData[0]), Length(RData));
  finally
    FpClose(Fd);
  end;
end;

function CtlStream(const ASocket: string; AKind: byte; APane: integer;
  const APayload: TByteArray; AOnData: TCtlDataProc): boolean;
var
  Fd: cint;
  RKind: byte;
  RPane: integer;
  RData: TByteArray;
begin
  Result := False;
  Fd := ConnectSocket(ASocket);
  if Fd < 0 then
    Exit;
  try
    if not WriteFrameTo(Fd, AKind, APane, APayload) then
      Exit;
    repeat
      if not ReadFrameFrom(Fd, RKind, RPane, RData) then
        Exit;   // daemon viejo cierra sin responder -> False
      case RKind of
        FRAME_CTL_DATA:
          if Assigned(AOnData) then
            AOnData(RData);
        FRAME_CTL_END:
          Exit(True);
        FRAME_CTL_ERR:
          Exit(False);
      else
        Exit(False);
      end;
    until False;
  finally
    FpClose(Fd);
  end;
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

// cola tolerante 2 del snapshot: geometria de ventanas; ante cualquier
// violacion de tamano deja Snapshot.Geom vacia sin lanzar excepciones
procedure ReadSnapshotGeom(Stream: TMemoryStream; var Snapshot: TSessionSnapshot);
var
  Cnt, I: Longint;
  Flag: byte;
begin
  if Stream.Position + 3 * SizeOf(Longint) > Stream.Size then
    Exit;
  Cnt := Default(Longint);
  Stream.ReadBuffer(Cnt, SizeOf(Cnt));
  Stream.ReadBuffer(Snapshot.DeskW, SizeOf(Longint));
  Stream.ReadBuffer(Snapshot.DeskH, SizeOf(Longint));
  if (Cnt <= 0) or (Cnt > MAX_PANES) then
    Exit;
  if Stream.Position + Cnt * (4 * SizeOf(Longint) + 2) > Stream.Size then
    Exit;
  SetLength(Snapshot.Geom, Cnt);
  for I := 0 to Cnt - 1 do
  begin
    Stream.ReadBuffer(Snapshot.Geom[I].BX, SizeOf(Longint));
    Stream.ReadBuffer(Snapshot.Geom[I].BY, SizeOf(Longint));
    Stream.ReadBuffer(Snapshot.Geom[I].BW, SizeOf(Longint));
    Stream.ReadBuffer(Snapshot.Geom[I].BH, SizeOf(Longint));
    Flag := Default(byte);
    Stream.ReadBuffer(Flag, SizeOf(Flag));
    Snapshot.Geom[I].Zoomed := Flag <> 0;
    Stream.ReadBuffer(Flag, SizeOf(Flag));
    Snapshot.Geom[I].Minimized := Flag <> 0;
  end;
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
  Snapshot.Geom := nil;
  Snapshot.DeskW := 0;
  Snapshot.DeskH := 0;
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
    // cola tolerante: un daemon de una version anterior no la envia;
    // ante una cola truncada el campo queda en '' y no se sigue leyendo
    if ReadTailString(Stream, Snapshot.Name) then
      if ReadTailString(Stream, Snapshot.Profile) then
        ReadSnapshotGeom(Stream, Snapshot);
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

function TSessionClient.SendKillPane(APane: integer): boolean;
var
  Data: TByteArray;
begin
  Data := nil;
  Result := SendFrame(FRAME_KILLPANE, APane, Data);
end;

function TSessionClient.SendLayout(const ANodes: string; AFocused: integer;
  const ATitles: TStrArray; const AGeom: TPaneGeomArray;
  ADeskW, ADeskH: integer): boolean;
var
  Stream: TMemoryStream;
  Data: TByteArray;
  Cnt, I, F: Longint;
  Flag: byte;
begin
  Result := False;
  if (Length(ATitles) <> Length(AGeom)) or (Length(AGeom) < 1) then
    Exit;
  Cnt := Length(AGeom);
  Data := Default(TByteArray);
  Stream := TMemoryStream.Create;
  try
    WriteString(Stream, ANodes);
    F := AFocused;
    Stream.WriteBuffer(F, SizeOf(F));
    Stream.WriteBuffer(Cnt, SizeOf(Cnt));
    for I := 0 to Cnt - 1 do
      WriteString(Stream, ATitles[I]);
    F := ADeskW;
    Stream.WriteBuffer(F, SizeOf(F));
    F := ADeskH;
    Stream.WriteBuffer(F, SizeOf(F));
    for I := 0 to Cnt - 1 do
    begin
      Stream.WriteBuffer(AGeom[I].BX, SizeOf(Longint));
      Stream.WriteBuffer(AGeom[I].BY, SizeOf(Longint));
      Stream.WriteBuffer(AGeom[I].BW, SizeOf(Longint));
      Stream.WriteBuffer(AGeom[I].BH, SizeOf(Longint));
      if AGeom[I].Zoomed then
        Flag := 1
      else
        Flag := 0;
      Stream.WriteBuffer(Flag, SizeOf(Flag));
      if AGeom[I].Minimized then
        Flag := 1
      else
        Flag := 0;
      Stream.WriteBuffer(Flag, SizeOf(Flag));
    end;
    SetLength(Data, Stream.Size);
    if Stream.Size > 0 then
    begin
      Stream.Position := 0;
      Stream.ReadBuffer(Data[0], Stream.Size);
    end;
    Result := SendFrame(FRAME_LAYOUT, -1, Data);
  finally
    Stream.Free;
  end;
end;

constructor TDetachedSession.Create(const AName, AProfile: string;
  ALay: TLayout;
  const APanes: TPtyArray; const AScreens: TScreenArray;
  const ATitles: TStrArray; const ATerms: TStrArray;
  AFocused: integer; const AGeom: TPaneGeomArray;
  ADeskW, ADeskH: integer);
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
  // geometria inicial de las ventanas tal como estaban al separar
  FGeomValid := Length(AGeom) = FPaneCount;
  FDeskW := ADeskW;
  FDeskH := ADeskH;
  if FGeomValid then
    for I := 0 to FPaneCount - 1 do
      FGeom[I] := AGeom[I];
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
  GeomCnt: Longint;
  Flag: byte;
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
    // cola tolerante 2: geometria de ventanas (0 paneles = sin datos)
    if FGeomValid then
      GeomCnt := FPaneCount
    else
      GeomCnt := 0;
    Meta.WriteBuffer(GeomCnt, SizeOf(GeomCnt));
    Meta.WriteBuffer(FDeskW, SizeOf(FDeskW));
    Meta.WriteBuffer(FDeskH, SizeOf(FDeskH));
    for I := 0 to GeomCnt - 1 do
    begin
      Meta.WriteBuffer(FGeom[I].BX, SizeOf(Longint));
      Meta.WriteBuffer(FGeom[I].BY, SizeOf(Longint));
      Meta.WriteBuffer(FGeom[I].BW, SizeOf(Longint));
      Meta.WriteBuffer(FGeom[I].BH, SizeOf(Longint));
      if FGeom[I].Zoomed then
        Flag := 1
      else
        Flag := 0;
      Meta.WriteBuffer(Flag, SizeOf(Flag));
      if FGeom[I].Minimized then
        Flag := 1
      else
        Flag := 0;
      Meta.WriteBuffer(Flag, SizeOf(Flag));
    end;
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

// lee el primer frame de una conexion recien aceptada con espera acotada:
// un par que conecta y no escribe nada no debe dejar colgado al daemon
function TDetachedSession.ReadFirstFrame(AFd: cint; out AKind: byte;
  out APane: integer; out AData: TByteArray): boolean;
var
  SetRead: TFDSet;
  TV: TTimeVal;
begin
  Result := False;
  AKind := 0;
  APane := -1;
  AData := nil;
  fpFD_ZERO(SetRead);
  fpFD_SET(AFd, SetRead);
  TV.tv_sec := 1;
  TV.tv_usec := 0;
  if fpSelect(AFd + 1, @SetRead, nil, nil, @TV) <= 0 then
    Exit;
  if fpFD_ISSET(AFd, SetRead) = 0 then
    Exit;
  Result := ReadFrame(AFd, AKind, APane, AData);
end;

// atiende una adhesion cuyo primer frame ya fue leido en Run: solo un
// FRAME_ATTACH legitimo desemboca en el envio del snapshot
function TDetachedSession.HandleAttach(AFd: cint; AFirstKind: byte): boolean;
begin
  Result := False;
  if AFirstKind <> FRAME_ATTACH then
    Exit;
  Result := SendSnapshot(AFd);
end;

procedure TDetachedSession.CloseClient(var AClient: cint);
begin
  if AClient >= 0 then
    FpClose(AClient);
  AClient := -1;
end;

// el cliente cerro un panel: matar el proceso y compactar en espejo del
// cliente (mismos desplazamientos de indices para que INPUT siga alineado)
procedure TDetachedSession.DoKillPane(APane: integer);
var
  I: integer;
begin
  if (APane < 0) or (APane >= FPaneCount) or (FPaneCount <= 1) then
    Exit;
  FLayout.ClosePane(APane);
  if FPanes[APane] <> nil then
  begin
    FPanes[APane].KillPane;
    FPanes[APane].Free;
    FPanes[APane] := nil;
  end;
  FScreens[APane].Free;
  FScreens[APane] := nil;
  for I := APane to FPaneCount - 2 do
  begin
    FPanes[I] := FPanes[I + 1];
    FScreens[I] := FScreens[I + 1];
    FTitles[I] := FTitles[I + 1];
    FTerms[I] := FTerms[I + 1];
    FGeom[I] := FGeom[I + 1];
  end;
  FPanes[FPaneCount - 1] := nil;
  FScreens[FPaneCount - 1] := nil;
  FTitles[FPaneCount - 1] := '';
  FTerms[FPaneCount - 1] := '';
  Dec(FPaneCount);
  if FFocused > APane then
    Dec(FFocused);
  if FFocused >= FPaneCount then
    FFocused := FPaneCount - 1;
  if FFocused < 0 then
    FFocused := 0;
  WriteSidecar; // el numero de paneles del sidecar cambio
end;

// el cliente sincroniza arbol de splits, foco, titulos y geometria; solo se
// acepta si el numero de paneles coincide con el estado vivo del daemon
procedure TDetachedSession.ApplyLayoutFrame(const Data: TByteArray);
var
  Stream: TMemoryStream;
  Nodes: string;
  Focused, Cnt, I: Longint;
  NewLay: TLayout;
  T: string;
  Flag: byte;
begin
  if Length(Data) = 0 then
    Exit;
  Stream := TMemoryStream.Create;
  try
    Stream.WriteBuffer(Data[0], Length(Data));
    Stream.Position := 0;
    if not ReadTailString(Stream, Nodes) then
      Exit;
    Focused := Default(Longint);
    Cnt := Default(Longint);
    if Stream.Position + 2 * SizeOf(Longint) > Stream.Size then
      Exit;
    Stream.ReadBuffer(Focused, SizeOf(Focused));
    Stream.ReadBuffer(Cnt, SizeOf(Cnt));
    if Cnt <> FPaneCount then
      Exit;
    NewLay := nil;
    if LoadLayoutString(Nodes, NewLay) and (NewLay <> nil) then
    begin
      if NewLay.PaneCount = FPaneCount then
      begin
        FLayout.Free;
        FLayout := NewLay;
      end
      else
        NewLay.Free;
    end;
    if (Focused >= 0) and (Focused < FPaneCount) then
      FFocused := Focused;
    for I := 0 to Cnt - 1 do
    begin
      if not ReadTailString(Stream, T) then
        Exit;
      FTitles[I] := T;
    end;
    // geometria: DeskW, DeskH y por panel bounds + flags
    if Stream.Position + 2 * SizeOf(Longint) +
       Cnt * (4 * SizeOf(Longint) + 2) > Stream.Size then
      Exit;
    Stream.ReadBuffer(FDeskW, SizeOf(FDeskW));
    Stream.ReadBuffer(FDeskH, SizeOf(FDeskH));
    for I := 0 to Cnt - 1 do
    begin
      Stream.ReadBuffer(FGeom[I].BX, SizeOf(Longint));
      Stream.ReadBuffer(FGeom[I].BY, SizeOf(Longint));
      Stream.ReadBuffer(FGeom[I].BW, SizeOf(Longint));
      Stream.ReadBuffer(FGeom[I].BH, SizeOf(Longint));
      Flag := Default(byte);
      Stream.ReadBuffer(Flag, SizeOf(Flag));
      FGeom[I].Zoomed := Flag <> 0;
      Stream.ReadBuffer(Flag, SizeOf(Flag));
      FGeom[I].Minimized := Flag <> 0;
    end;
    FGeomValid := True;
  finally
    Stream.Free;
  end;
end;

procedure TDetachedSession.CtlReplyErr(AFd: cint; const AMsg: string);
var
  Data: TByteArray;
begin
  Data := nil;
  SetLength(Data, Length(AMsg));
  if Length(AMsg) > 0 then
    Move(AMsg[1], Data[0], Length(AMsg));
  WriteFrameToTimeout(AFd, FRAME_CTL_ERR, -1, Data, 5000);
end;

// carga perezosa de las clases de ventana para resolver kind/host en LIST
procedure TDetachedSession.EnsureCtlConfig;
var
  SysClasses: TWindowClassArray;
begin
  if FCtlClassesLoaded then
    Exit;
  FCtlClassesLoaded := True;
  LoadConfig(FCtlCfg);
  LoadWindowClasses(ConfigFile, coUser, FCtlClasses);
  LoadWindowClasses(SystemConfigFile, coSystem, SysClasses);
  MergeWindowClasses(FCtlClasses, SysClasses);
end;

procedure TDetachedSession.CtlReplyOk(AFd: cint; const AMsg: string);
var
  Data: TByteArray;
begin
  Data := nil;
  SetLength(Data, Length(AMsg));
  if Length(AMsg) > 0 then
    Move(AMsg[1], Data[0], Length(AMsg));
  WriteFrameToTimeout(AFd, FRAME_CTL_OK, -1, Data, 5000);
end;

// recoge hijos del daemon (paneles creados daemon-side) sin bloquear
procedure TDetachedSession.ReapChildren;
var
  St: cint;
begin
  St := 0;
  while fpWaitPid(-1, St, WNOHANG) > 0 do
    ;
end;

// crea un PTY para una clase de ventana o un comando, como StartPaneEx
// pero sin FreeVision: wcSSH -> argv estructurado; resto -> comando compuesto
function TDetachedSession.SpawnPaneForSpec(const AClass, ACmd, ACwd: string;
  ACols, ARows: integer; out APty: TPty; out ATerm: string): boolean;
var
  CIdx: integer;
  ShellS, CmdS, CwdS: string;
  ExecProgram, ExecSecret: string;
  ExecArgs: TStringList;
begin
  Result := False;
  APty := nil;
  ATerm := '';
  EnsureCtlConfig;
  CIdx := -1;
  if AClass <> '' then
  begin
    CIdx := FindClassByName(FCtlClasses, AClass);
    if CIdx < 0 then
      Exit;
    ATerm := FCtlClasses[CIdx].Name;
  end;
  APty := TPty.Create;
  if (CIdx >= 0) and (FCtlClasses[CIdx].Kind = wcSSH) then
  begin
    ExecArgs := TStringList.Create;
    try
      ExecProgram := '';
      ExecSecret := '';
      BuildWindowClassExec(FCtlClasses[CIdx], ExecProgram, ExecArgs,
        ExecSecret, ACmd);
      Result := APty.SpawnArgv(ExecProgram, ExecArgs.ToStringArray,
        ExpandUserPath(ACwd), ACols, ARows, '', ExecSecret);
    finally
      ExecArgs.Free;
    end;
  end
  else
  begin
    ShellS := FCtlCfg.Shell;
    CwdS := ACwd;
    if CIdx >= 0 then
    begin
      if FCtlClasses[CIdx].Shell <> '' then
        ShellS := FCtlClasses[CIdx].Shell;
      if CwdS = '' then
        CwdS := FCtlClasses[CIdx].Cwd;
      CmdS := ComposePaneCommand(FCtlClasses[CIdx], ACmd, '', '', ShellS,
        FCtlCfg.LoginShell);
    end
    else if ACmd <> '' then
      CmdS := CommandWithInteractiveShell(ACmd, ShellS, FCtlCfg.LoginShell)
    else
      CmdS := '';
    if CwdS = '' then
      CwdS := GetEnvironmentVariable('HOME');
    Result := APty.Spawn(ShellS, ExpandUserPath(CwdS), CmdS, ACols, ARows,
      '', FCtlCfg.LoginShell);
  end;
  if not Result then
    FreeAndNil(APty);
end;

// gestion de ventanas por control; con un cliente enganchado se rechaza
// (hasta la fase multi-cliente, que difunde los cambios en vivo)
procedure TDetachedSession.HandleWinOp(AFd: cint; APane: integer;
  const AData: TByteArray);
var
  Ofs: integer;
  Op, HowB, DirB: byte;
  ClassS, CmdS, CwdS, TitleS: string;
  NewPty: TPty;
  TermS: string;
  NewIdx, OldCount, j, N, i, k: integer;
  Cols, Rows: Longint;
  GC, GR, CW, CH, MaxOff: integer;

  function RdStr: string;
  var
    L: Longint;
  begin
    Result := '';
    L := Default(Longint);
    if Ofs + SizeOf(Longint) > Length(AData) then
      Exit;
    Move(AData[Ofs], L, SizeOf(L));
    Inc(Ofs, SizeOf(L));
    if (L < 0) or (Ofs + L > Length(AData)) then
      Exit;
    SetLength(Result, L);
    if L > 0 then
      Move(AData[Ofs], Result[1], L);
    Inc(Ofs, L);
  end;

begin
  if Length(AData) < 1 then
  begin
    CtlReplyErr(AFd, 'bad request');
    Exit;
  end;
  if FClient >= 0 then
  begin
    CtlReplyErr(AFd, 'session is attached');
    Exit;
  end;
  Op := AData[0];
  Ofs := 1;
  case Op of
    WINOP_NEWPANE:
      begin
        if FPaneCount >= MAX_PANES then
        begin
          CtlReplyErr(AFd, 'max panes');
          Exit;
        end;
        DirB := 0;
        if Ofs < Length(AData) then
        begin
          DirB := AData[Ofs];
          Inc(Ofs);
        end;
        ClassS := RdStr;
        CmdS := RdStr;
        CwdS := RdStr;
        TitleS := RdStr;
        // dividir el panel indicado (o el enfocado)
        if (APane < 0) or (APane >= FPaneCount) then
          APane := FFocused;
        if (APane < 0) or (APane >= FPaneCount) then
          APane := 0;
        Cols := 80;
        Rows := 24;
        if FScreens[APane] <> nil then
        begin
          Cols := FScreens[APane].Width;
          Rows := FScreens[APane].Height;
        end;
        OldCount := FPaneCount;
        if DirB = 1 then
        begin
          if not FLayout.SplitPane(APane, sdH) then
          begin
            CtlReplyErr(AFd, 'split failed');
            Exit;
          end;
        end
        else if not FLayout.SplitPane(APane, sdV) then
        begin
          CtlReplyErr(AFd, 'split failed');
          Exit;
        end;
        NewIdx := FLayout.LastInsertedIndex;
        if not SpawnPaneForSpec(ClassS, CmdS, CwdS, Cols, Rows,
          NewPty, TermS) then
        begin
          FLayout.ClosePane(NewIdx);
          if ClassS <> '' then
            CtlReplyErr(AFd, 'unknown class or spawn failed')
          else
            CtlReplyErr(AFd, 'spawn failed');
          Exit;
        end;
        // desplazar los arrays en espejo del cliente (DoSplit)
        for j := OldCount downto NewIdx + 1 do
        begin
          FPanes[j] := FPanes[j - 1];
          FScreens[j] := FScreens[j - 1];
          FTitles[j] := FTitles[j - 1];
          FTerms[j] := FTerms[j - 1];
          FGeom[j] := FGeom[j - 1];
        end;
        FPanes[NewIdx] := NewPty;
        FScreens[NewIdx] := TScreen.Create(Cols, Rows,
          DEFAULT_SCROLLBACK);
        FTerms[NewIdx] := TermS;
        if TitleS <> '' then
          FTitles[NewIdx] := ' ' + TitleS
        else if TermS <> '' then
          FTitles[NewIdx] := ' ' + TermS
        else if CmdS <> '' then
          FTitles[NewIdx] := ' ' + CmdS
        else
          FTitles[NewIdx] := ' shell';
        FGeom[NewIdx] := Default(TPaneGeom);
        Inc(FPaneCount);
        FFocused := NewIdx;
        WriteSidecar;
        CtlReplyOk(AFd, IntToStr(NewIdx + 1));
      end;
    WINOP_KILL:
      begin
        if (APane < 0) or (APane >= FPaneCount) then
        begin
          CtlReplyErr(AFd, 'no such pane');
          Exit;
        end;
        if FPaneCount <= 1 then
        begin
          CtlReplyErr(AFd, 'last pane; use kill-session');
          Exit;
        end;
        DoKillPane(APane);
        CtlReplyOk(AFd, '');
      end;
    WINOP_FOCUS:
      begin
        if (APane < 0) or (APane >= FPaneCount) then
        begin
          CtlReplyErr(AFd, 'no such pane');
          Exit;
        end;
        FFocused := APane;
        // enfocar restaura si estaba minimizada
        FGeom[APane].Minimized := False;
        FGeomValid := True;
        CtlReplyOk(AFd, '');
      end;
    WINOP_MINIMIZE, WINOP_RESTORE, WINOP_ZOOM:
      begin
        if (APane < 0) or (APane >= FPaneCount) then
        begin
          CtlReplyErr(AFd, 'no such pane');
          Exit;
        end;
        case Op of
          WINOP_MINIMIZE: FGeom[APane].Minimized := True;
          WINOP_RESTORE:
            begin
              FGeom[APane].Minimized := False;
              FGeom[APane].Zoomed := False;
            end;
          WINOP_ZOOM:
            begin
              // solo una maximizada a la vez (espejo de la UI)
              for j := 0 to FPaneCount - 1 do
                FGeom[j].Zoomed := False;
              FGeom[APane].Zoomed := True;
              FGeom[APane].Minimized := False;
            end;
        end;
        FGeomValid := True;
        CtlReplyOk(AFd, '');
      end;
    WINOP_ORGANIZE:
      begin
        if (FDeskW <= 0) or (FDeskH <= 0) then
        begin
          CtlReplyErr(AFd, 'no desk size known yet');
          Exit;
        end;
        HowB := 0;
        if Ofs < Length(AData) then
          HowB := AData[Ofs];
        N := FPaneCount;
        case HowB of
          2:  // cascada
            begin
              CW := FDeskW * 2 div 3;
              CH := FDeskH * 2 div 3;
              if CW < 20 then CW := 20;
              if CH < 6 then CH := 6;
              MaxOff := FDeskH - CH - 1;
              if MaxOff < 1 then MaxOff := 1;
              k := 0;
              for i := 0 to N - 1 do
              begin
                FGeom[i].BX := (k * 3) mod (FDeskW - CW);
                FGeom[i].BY := k mod MaxOff;
                FGeom[i].BW := CW;
                FGeom[i].BH := CH;
                FGeom[i].Zoomed := False;
                FGeom[i].Minimized := False;
                Inc(k);
              end;
            end;
          1:  // mosaico segun el arbol de splits
            begin
              for i := 0 to N - 1 do
              begin
                FGeom[i].BW := 0;  // sin bounds manuales: re-tila al attach
                FGeom[i].BH := 0;
                FGeom[i].Zoomed := False;
                FGeom[i].Minimized := False;
              end;
            end;
        else
          // rejilla NxM lo mas cuadrada posible
          GC := 1;
          while GC * GC < N do
            Inc(GC);
          GR := (N + GC - 1) div GC;
          for i := 0 to N - 1 do
          begin
            FGeom[i].BW := FDeskW div GC;
            FGeom[i].BH := FDeskH div GR;
            FGeom[i].BX := (i mod GC) * (FDeskW div GC);
            FGeom[i].BY := (i div GC) * (FDeskH div GR);
            FGeom[i].Zoomed := False;
            FGeom[i].Minimized := False;
          end;
        end;
        FGeomValid := True;
        CtlReplyOk(AFd, '');
      end;
    WINOP_RENAME:
      begin
        if (APane < 0) or (APane >= FPaneCount) then
        begin
          CtlReplyErr(AFd, 'no such pane');
          Exit;
        end;
        TitleS := RdStr;
        if Trim(TitleS) = '' then
        begin
          CtlReplyErr(AFd, 'empty title');
          Exit;
        end;
        FTitles[APane] := ' ' + Trim(TitleS);
        CtlReplyOk(AFd, '');
      end;
    WINOP_RESIZE:
      begin
        if (APane < 0) or (APane >= FPaneCount) or
           (FScreens[APane] = nil) then
        begin
          CtlReplyErr(AFd, 'no such pane');
          Exit;
        end;
        Cols := 0;
        Rows := 0;
        if Ofs + 2 * SizeOf(Longint) <= Length(AData) then
        begin
          Move(AData[Ofs], Cols, SizeOf(Longint));
          Move(AData[Ofs + SizeOf(Longint)], Rows, SizeOf(Longint));
        end;
        if (Cols < 4) or (Rows < 2) or (Cols > 1000) or (Rows > 500) then
        begin
          CtlReplyErr(AFd, 'bad size');
          Exit;
        end;
        FScreens[APane].Resize(Cols, Rows);
        if FPanes[APane] <> nil then
          FPanes[APane].Resize(Cols, Rows);
        CtlReplyOk(AFd, '');
      end;
  else
    CtlReplyErr(AFd, 'unknown operation');
  end;
end;

// peticion de control efimera: un frame de peticion ya leido, responder por
// el mismo fd y volver (el llamante cierra la conexion)
procedure TDetachedSession.HandleControlFrame(AFd: cint; AKind: byte;
  APane: integer; const AData: TByteArray);
const
  CHUNK = 256 * 1024;
var
  Meta: TMemoryStream;
  Data: TByteArray;
  I, CIdx: integer;
  S: RawByteString;
  Mode, N: Longint;
  Scr: TScreen;
  From, Count, Sent, Take: integer;
  KindB: byte;
  Host, User, LiveCmd, LiveCwd: string;
begin
  case AKind of
    FRAME_CTL_INFO, FRAME_CTL_LIST:
      begin
        EnsureCtlConfig;
        Meta := TMemoryStream.Create;
        try
          // cabecera de sesion
          WriteString(Meta, FName);
          WriteString(Meta, FProfile);
          Meta.WriteBuffer(FPaneCount, SizeOf(FPaneCount));
          Meta.WriteBuffer(FFocused, SizeOf(FFocused));
          I := 0;
          if FClient >= 0 then
            I := 1;
          Meta.WriteBuffer(I, SizeOf(I));   // clientes enganchados
          Meta.WriteBuffer(FDeskW, SizeOf(FDeskW));
          Meta.WriteBuffer(FDeskH, SizeOf(FDeskH));
          if AKind = FRAME_CTL_LIST then
            for I := 0 to FPaneCount - 1 do
            begin
              // tipo y destino resueltos desde la clase por nombre
              KindB := 255;
              Host := '';
              User := '';
              CIdx := FindClassByName(FCtlClasses, FTerms[I]);
              if FTerms[I] = '' then
                KindB := 0    // ad-hoc = local
              else if CIdx >= 0 then
              begin
                KindB := byte(Ord(FCtlClasses[CIdx].Kind));
                Host := FCtlClasses[CIdx].Host;
                User := FCtlClasses[CIdx].User;
              end;
              // comando/cwd vivos desde el proceso real
              LiveCmd := '';
              LiveCwd := '';
              if (FPanes[I] <> nil) and FPanes[I].Alive then
              begin
                FPanes[I].QueryState;
                LiveCmd := FPanes[I].TitleCmd;
                LiveCwd := FPanes[I].TitleCwd;
              end;
              WriteString(Meta, FTitles[I]);
              WriteString(Meta, FTerms[I]);
              Meta.WriteBuffer(KindB, SizeOf(KindB));
              WriteString(Meta, Host);
              WriteString(Meta, User);
              WriteString(Meta, LiveCmd);
              WriteString(Meta, LiveCwd);
              if FScreens[I] <> nil then
              begin
                Meta.WriteBuffer(FScreens[I].Width, SizeOf(integer));
                Meta.WriteBuffer(FScreens[I].Height, SizeOf(integer));
                N := FScreens[I].HistoryRows;
              end
              else
              begin
                N := 0;
                Meta.WriteBuffer(N, SizeOf(N));
                Meta.WriteBuffer(N, SizeOf(N));
              end;
              Meta.WriteBuffer(N, SizeOf(N));   // lineas de historial
              Meta.WriteBuffer(FGeom[I].BX, SizeOf(Longint));
              Meta.WriteBuffer(FGeom[I].BY, SizeOf(Longint));
              Meta.WriteBuffer(FGeom[I].BW, SizeOf(Longint));
              Meta.WriteBuffer(FGeom[I].BH, SizeOf(Longint));
              KindB := 0;
              if FGeom[I].Zoomed then KindB := 1;
              Meta.WriteBuffer(KindB, SizeOf(KindB));
              KindB := 0;
              if FGeom[I].Minimized then KindB := 1;
              Meta.WriteBuffer(KindB, SizeOf(KindB));
              KindB := 0;
              if (FPanes[I] <> nil) and FPanes[I].Alive then KindB := 1;
              Meta.WriteBuffer(KindB, SizeOf(KindB));
            end;
          Data := nil;
          SetLength(Data, Meta.Size);
          if Meta.Size > 0 then
          begin
            Meta.Position := 0;
            Meta.ReadBuffer(Data[0], Meta.Size);
          end;
          if WriteFrameToTimeout(AFd, FRAME_CTL_DATA, -1, Data, 5000) then
          begin
            Data := nil;
            WriteFrameToTimeout(AFd, FRAME_CTL_END, -1, Data, 5000);
          end;
        finally
          Meta.Free;
        end;
      end;
    FRAME_CTL_SEND:
      begin
        if (APane < 0) or (APane >= FPaneCount) or (FPanes[APane] = nil) or
           (not FPanes[APane].Alive) then
        begin
          CtlReplyErr(AFd, 'no such pane');
          Exit;
        end;
        if Length(AData) > 0 then
        begin
          SetString(S, PAnsiChar(@AData[0]), Length(AData));
          FPanes[APane].WriteStr(S);
        end;
        Data := nil;
        WriteFrameToTimeout(AFd, FRAME_CTL_OK, APane, Data, 5000);
      end;
    FRAME_CTL_CAPTURE:
      begin
        if (APane < 0) or (APane >= FPaneCount) or
           (FScreens[APane] = nil) then
        begin
          CtlReplyErr(AFd, 'no such pane');
          Exit;
        end;
        Scr := FScreens[APane];
        Mode := CAPTURE_VISIBLE;
        N := 0;
        if Length(AData) >= SizeOf(Longint) then
          Move(AData[0], Mode, SizeOf(Longint));
        if Length(AData) >= 2 * SizeOf(Longint) then
          Move(AData[SizeOf(Longint)], N, SizeOf(Longint));
        case Mode of
          CAPTURE_ALL:
            begin
              From := 0;
              Count := Scr.HistoryRows + Scr.Height;
            end;
          CAPTURE_LAST_N:
            begin
              if N < 0 then N := 0;
              Count := N;
              From := Scr.HistoryRows + Scr.Height - Count;
              if From < 0 then
              begin
                From := 0;
                Count := Scr.HistoryRows + Scr.Height;
              end;
            end;
        else
          From := Scr.HistoryRows;
          Count := Scr.Height;
        end;
        // render por lotes: un CTL_DATA cada ~256KB, nunca el total en RAM
        Meta := TMemoryStream.Create;
        try
          Sent := 0;
          while Sent < Count do
          begin
            Take := 512;   // filas por lote
            if Sent + Take > Count then
              Take := Count - Sent;
            Meta.Clear;
            Scr.RenderTextRange(From + Sent, Take, Meta);
            Inc(Sent, Take);
            if (Meta.Size >= CHUNK) or (Sent >= Count) then
            begin
              Data := nil;
              SetLength(Data, Meta.Size);
              if Meta.Size > 0 then
              begin
                Meta.Position := 0;
                Meta.ReadBuffer(Data[0], Meta.Size);
              end;
              if not WriteFrameToTimeout(AFd, FRAME_CTL_DATA, APane,
                Data, 5000) then
                Exit;
            end;
          end;
          Data := nil;
          WriteFrameToTimeout(AFd, FRAME_CTL_END, APane, Data, 5000);
        finally
          Meta.Free;
        end;
      end;
    FRAME_CTL_WINOP:
      HandleWinOp(AFd, APane, AData);
  end;
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
    FRAME_KILLPANE:
      DoKillPane(Pane);
    FRAME_LAYOUT:
      ApplyLayoutFrame(Data);
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
    Ini.WriteString('session', 'name', IniQuoteGuard(FName));
    Ini.WriteString('session', 'profile', IniQuoteGuard(FProfile));
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
  Kind: byte;
  Addr: TUnixSockAddr;
  AddrLen: TSockLen;
  FirstPane: integer;
  FirstData: TByteArray;
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
        // el primer frame decide: FRAME_CLOSE apaga el daemon aunque
        // llegue por una conexion nueva (CloseSessionAt); FRAME_ATTACH
        // solo se atiende con el unico slot de cliente libre; cualquier
        // otra cosa (o el slot ocupado) cierra la conexion
        if not ReadFirstFrame(NewClient, Kind, FirstPane, FirstData) then
          FpClose(NewClient)
        else if Kind = FRAME_CLOSE then
        begin
          FpClose(NewClient);
          FStop := True;
        end
        else if (Kind >= FRAME_CTL_LIST) and (Kind <= FRAME_CTL_INFO) then
        begin
          // peticion de control efimera: responder y cerrar; no ocupa slot
          HandleControlFrame(NewClient, Kind, FirstPane, FirstData);
          FpClose(NewClient);
        end
        else if (FClient < 0) and HandleAttach(NewClient, Kind) then
          FClient := NewClient
        else
          FpClose(NewClient);
      end;
    end;
    if (FClient >= 0) and (fpFD_ISSET(FClient, ReadSet) <> 0) then
      HandleClientFrame(FClient);
    ReapChildren;
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
  AFocused: integer; const AGeom: TPaneGeomArray;
  ADeskW, ADeskH: integer): boolean;
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
      AScreens, ATitles, ATerms, AFocused, AGeom, ADeskW, ADeskH);
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
