(*
  Unit: st_server - persistent server for detachable sessions

  The server owns the PTY masters and terminal parsers.  The FreeVision
  process is only a client, so closing or losing that client cannot close a
  local shell or an SSH connection.
*)

unit st_server;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, BaseUnix, Unix, Sockets,
  st_config, st_wclass, st_layout, st_pty, st_screen, st_session, st_debug;

const
  FRAME_ATTACH = 1;
  FRAME_INPUT = 2;
  FRAME_RESIZE = 3;
  FRAME_DETACH = 4;
  FRAME_CLOSE = 5;
  FRAME_KILLPANE = 6;   // attached client closes a pane
  FRAME_LAYOUT = 7;     // attached client syncs tree/geometry
  FRAME_NEWPANE = 8;    // new daemon-side pane: byte Dir; Class,Cmd,Cwd,Title
  FRAME_FOCUS = 9;      // changes the focused pane (pane in header)
  FRAME_RENAME = 10;    // string NewTitle (pane in header)

  // ephemeral control: one connection, one request frame, reply and close;
  // never occupies an interactive client slot (FRAME_CLOSE pattern)
  FRAME_CTL_LIST = 11;     // session and pane details
  FRAME_CTL_SEND = 12;     // raw text to a pane
  FRAME_CTL_CAPTURE = 13;  // screen/history capture as text
  FRAME_CTL_WINOP = 14;    // window management (reserved)
  FRAME_CTL_INFO = 15;     // session header only

  FRAME_SESSION = 20;
  FRAME_SCREEN = 21;
  FRAME_READY = 22;
  FRAME_OUTPUT = 23;
  FRAME_EXIT = 24;
  FRAME_ERROR = 25;

  // server->client events (only to clients that declare the capability;
  // an old client treats any unknown frame as a lost connection,
  // so they are never sent to it)
  FRAME_LAYOUT_EV = 26;    // same payload as FRAME_LAYOUT
  FRAME_KILLPANE_EV = 27;  // pane closed (pane in header)
  FRAME_NEWPANE_EV = 28;   // At,NewIdx,PaneCount,Dir,Cols,Rows,Title,Term
  FRAME_RESIZE_EV = 29;    // Longint Cols,Rows (pane in header)
  FRAME_TITLE_EV = 30;     // string Title (pane in header)
  FRAME_FOCUS_EV = 31;     // focused pane (pane in header)
  FRAME_SHUTDOWN_EV = 32;  // the session is shutting down

  // control replies
  FRAME_CTL_OK = 40;
  FRAME_CTL_ERR = 41;
  FRAME_CTL_DATA = 42;     // data chunk (text or records)
  FRAME_CTL_END = 43;      // end of the reply

  // capture modes (FRAME_CTL_CAPTURE payload)
  CAPTURE_VISIBLE = 0;
  CAPTURE_ALL = 1;
  CAPTURE_LAST_N = 2;

  // FRAME_CTL_WINOP sub-operations (byte Op at start of payload)
  WINOP_NEWPANE = 1;    // byte Dir(0=V,1=H); strings Class,Cmd,Cwd,Title
  WINOP_KILL = 2;       // pane in the header
  WINOP_FOCUS = 3;
  WINOP_MINIMIZE = 4;
  WINOP_RESTORE = 5;    // undoes minimize and zoom
  WINOP_ZOOM = 6;
  WINOP_ORGANIZE = 8;   // byte How: 0 grid, 1 tile, 2 cascade
  WINOP_RENAME = 9;     // string NewTitle
  WINOP_RESIZE = 10;    // Longint Cols, Rows (terminal size)
  WINOP_SAVE = 11;      // saves session.ini with the daemon state

  // Ceiling for one frame. FRAME_SCREEN carries a pane's whole grid plus its
  // scrollback as raw TCell records, so this limit is really a CELL budget:
  // 64 MB used to allow ~4.8M cells at 14 bytes each. Per-cell truecolor grew
  // TCell to 24 bytes, which silently cut that capacity by 40% -- a pane over
  // roughly 280 columns with a full scrollback stopped being attachable at all
  // (WriteFrameTo refused the frame). Sized back to the same number of cells.
  // A compact wire format would be the better long-term answer; this restores
  // the previous capacity without another format change.
  MAX_FRAME_SIZE = 112 * 1024 * 1024;

  // versioned attach (tolerant tail of the FRAME_ATTACH payload):
  // ProtoVer, DeskW, DeskH, Caps; no payload = exclusive legacy client
  // 3: TCell gained per-cell truecolor (FgRGB/BgRGB), so SizeOf(TCell) -- which
  //    IS the FRAME_SCREEN element size -- grew from 14 to 24 bytes. A daemon
  //    and a client are separate processes and can be different builds, and a
  //    daemon outlives its clients, so a 24-byte producer feeding a 14-byte
  //    consumer reads every cell at the wrong offset and the pane fills with
  //    garbage. The version must be refused on BOTH sides.
  ATTACH_PROTO_VER = 3;
  ATTACH_CAP_EVENTS = 1;   // bit0 of Caps: understands events 26+

  MAX_CLIENTS = 8;
  // hard cap on the per-client output buffer (immediate disconnect)
  MAX_EGRESS = 8 * 1024 * 1024;
  // flow control: with this much pending toward some client we stop
  // reading from the PTYs (the producer throttles itself in its buffer);
  // thus a slow reader pauses the session instead of losing output
  FLOW_STOP = 2 * 1024 * 1024;
  // lagging client: high pending with no progress at all during the
  // grace period -> disconnect so the session stays alive
  LAG_MIN_PENDING = 512 * 1024;
  LAG_GRACE_MS = 10000;

  {$ifdef darwin}
  ST_MSG_DONTWAIT = $80;
  {$else}
  ST_MSG_DONTWAIT = $40;
  {$endif}

type
  TByteArray = array of byte;

  // typed arrays: const open arrays trigger a spurious hint of
  // "assigned but never used" when -Cr (range checks) is active
  TPtyArray = array of TPty;
  TScreenArray = array of TScreen;
  TStrArray = array of string;
  TBoolArray = array of boolean;

  // geometry of a client window (absolute desktop bounds)
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
    Name: string;      // session name (tolerant tail of the payload)
    Profile: string;   // source profile ('' = ad-hoc)
    // window geometry (tolerant tail 2; empty if the daemon is old or
    // never received a FRAME_LAYOUT); absolute bounds for DeskW x DeskH
    Geom: TPaneGeomArray;
    DeskW, DeskH: Longint;
    // daemon version (tolerant tail 3; 0 = daemon predating the
    // events: do not send it new frames)
    ProtoVer: Longint;
    Panes: array[0..MAX_PANES - 1] of TSessionPaneSnapshot;
  end;

  TSessionEventKind = (sekOutput, sekExit, sekError, sekLost,
    sekLayoutEv, sekKillPaneEv, sekNewPaneEv, sekResizeEv, sekTitleEv,
    sekFocusEv, sekShutdown, sekIgnore);

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
    FServerProto: Longint;
    // why the last Connect failed, so the UI can say something useful
    // instead of silently falling back to a fresh local session
    FAttachError: string;
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
    // closes the session; with ASave the daemon saves session.ini first
    function CloseSession(ASave: boolean = False): boolean;
    // closes a daemon pane (the client compacts in mirror)
    function SendKillPane(APane: integer): boolean;
    // syncs split tree, focus, titles and window geometry
    function SendLayout(const ANodes: string; AFocused: integer;
      const ATitles: TStrArray; const AGeom: TPaneGeomArray;
      ADeskW, ADeskH: integer): boolean;
    // new pane created by the daemon; the window arrives via NEWPANE_EV
    function SendNewPane(APane: integer; ADir: byte;
      const AClass, ACmd, ACwd, ATitle: string): boolean;
    function SendFocus(APane: integer): boolean;
    function SendRename(APane: integer; const ATitle: string): boolean;
    property Connected: boolean read FConnected;
    property AttachError: string read FAttachError;
    // version of the daemon we are attached to (0 = pre-v2)
    property ServerProto: Longint read FServerProto;
  end;

type
  // detached session discovered on disk (socket + metadata sidecar)
  TSessionInfo = record
    Name: string;
    Profile: string;
    PaneCount: integer;
    Pid: integer;
    Created: string;
    SocketPath: string;
    Legacy: boolean;   // old single socket ~/.superterm/session.sock
  end;
  TSessionInfoArray = array of TSessionInfo;

function SessionSocketPath: string;      // legacy path (single socket)
function SessionSocketIsLive: boolean;   // probe of the legacy path
function SessionsDir: string;            // ~/.superterm/sessions (0700)
function SanitizeSessionName(const S: string): string;
function SessionSocketPathFor(const AName: string): string;
function SessionIsLive(const APath: string): boolean;
// enumerates live sessions (probes each socket; purges orphans and
// sidecars; includes the legacy socket as '(sin nombre)')
function EnumerateSessions(out Infos: TSessionInfoArray): boolean;
// free name derived from a base: base, base-2, base-3...
function SuggestSessionName(const ABase: string): string;
// permanent close of a detached session via its socket (FRAME_CLOSE);
// waits briefly and returns True only if the daemon really died
function CloseSessionAt(const APath: string): boolean;

type
  // data callback for control requests with chunked replies
  TCtlDataProc = procedure(const AChunk: TByteArray) of object;

// simple control request (OK/ERR): connects, sends one frame, waits for
// the reply and closes; AReply carries the error message if any
function CtlSimple(const ASocket: string; AKind: byte; APane: integer;
  const APayload: TByteArray; out AReply: string): boolean;

// control request with data (LIST/CAPTURE/INFO): same but delivering
// each FRAME_CTL_DATA through the callback until FRAME_CTL_END
function CtlStream(const ASocket: string; AKind: byte; APane: integer;
  const APayload: TByteArray; AOnData: TCtlDataProc): boolean;

function StartDetachedServer(const AName, AProfile: string; ALay: TLayout;
  const APanes: TPtyArray; const AScreens: TScreenArray;
  const ATitles: TStrArray; const ATerms: TStrArray;
  AFocused: integer; const AGeom: TPaneGeomArray;
  ADeskW, ADeskH: integer;
  const ATitleFixed: TBoolArray = nil): boolean;

// decodes the FRAME_LAYOUT / FRAME_LAYOUT_EV payload
function DecodeLayoutBlob(const Data: TByteArray; out ANodes: string;
  out AFocused: Longint; out ATitles: TStrArray; out AGeom: TPaneGeomArray;
  out ADeskW, ADeskH: Longint): boolean;

// decodes the FRAME_NEWPANE_EV payload
function DecodeNewPaneEv(const Data: TByteArray; out AAt, ANewIdx,
  APaneCount: Longint; out ADir: byte; out ACols, ARows: Longint;
  out ATitle, ATerm: string): boolean;

var
  AttachRequested: boolean = False;
  AttachSocket: string = '';   // socket resolved by the CLI ('' = selector)
  CliSessionName: string = ''; // name requested with --session/--sesion

implementation

type
  TFrameHeader = packed record
    Kind: byte;
    Reserved: byte;
    Pane: SmallInt;
    Size: LongWord;
  end;

  // an attached interactive client: fd, capabilities, egress buffer and
  // last size request per pane (for the common minimum)
  TClientConn = record
    Fd: cint;
    Caps: Longint;
    Legacy: boolean;         // ATTACH without payload: protocol v1, exclusive
    DeskW, DeskH: Longint;
    OutBuf: RawByteString;
    LastProgress: QWord;     // last tick with bytes accepted by its socket
    ReqCols: array[0..MAX_PANES - 1] of Longint;
    ReqRows: array[0..MAX_PANES - 1] of Longint;
  end;

  TDetachedSession = class
  private
    FLayout: TLayout;
    FPaneCount: integer;
    FFocused: integer;
    FPanes: array[0..MAX_PANES - 1] of TPty;
    FScreens: array[0..MAX_PANES - 1] of TScreen;
    FTitles: array[0..MAX_PANES - 1] of string;
    FTitleFixed: array[0..MAX_PANES - 1] of boolean;  // renamed by hand
    FTerms: array[0..MAX_PANES - 1] of string;
    FSocketPath: string;
    FMetaPath: string;
    FName: string;
    FProfile: string;
    FListener: cint;
    FClients: array[0..MAX_CLIENTS - 1] of TClientConn;
    FStop: boolean;
    FGeom: array[0..MAX_PANES - 1] of TPaneGeom;
    FGeomValid: boolean;
    FDeskW, FDeskH: Longint;
    FCtlClasses: TWindowClassArray;   // classes resolved for LIST (lazy)
    FCtlClassesLoaded: boolean;
    FCtlCfg: TConfig;                 // config for daemon-side spawns
    FEmptySince: QWord;               // tick with no clients or live panes
    FLastTitleTick: QWord;            // periodic title derivation
    function CreateListener: boolean;
    function AttachedCount: integer;
    function HasLegacyClient: boolean;
    procedure DropClient(AIdx: integer);
    function QueueOut(AIdx: integer; const Buffer; ASize: integer): boolean;
    function SendFrameToIdx(AIdx: integer; AKind: byte; APane: integer;
      const Buffer; ASize: integer): boolean;
    procedure Broadcast(AKind: byte; APane: integer; const Buffer;
      ASize: integer; ANeedCaps: boolean; AExcept: integer);
    procedure FlushClient(AIdx: integer);
    procedure NegotiateResize(APane: integer);
    function BuildLayoutBlob(out AData: TByteArray): boolean;
    procedure BroadcastLayoutEv(AExcept: integer);
    procedure BroadcastTitle(APane: integer);
    procedure DaemonSaveSession;
    function DoNewPane(AAt: integer; ADir: byte; const AClass, ACmd,
      ACwd, ATitle: string; out ANewIdx: integer; out AErr: string): boolean;
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
      ACols, ARows: integer; out APty: TPty; out ATerm: string;
      out ADefTitle: string): boolean;
    procedure ReapChildren;
    function HandleAttach(AFd: cint; AFirstKind: byte;
      const AFirstData: TByteArray): boolean;
    procedure HandleClientFrame(AIdx: integer);
    procedure HandlePaneOutput(APane: integer);
    procedure SignalReady(AFd: cint; AOk: boolean);
    procedure WriteSidecar;
    procedure DoKillPane(APane: integer);
    procedure ApplyLayoutFrame(const Data: TByteArray);
  public
    constructor Create(const AName, AProfile: string; ALay: TLayout;
      const APanes: TPtyArray; const AScreens: TScreenArray;
      const ATitles: TStrArray; const ATerms: TStrArray;
      AFocused: integer; const AGeom: TPaneGeomArray;
      ADeskW, ADeskH: integer; const ATitleFixed: TBoolArray);
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

// full write with a total deadline: writability select per segment and
// a cumulative deadline; if the receiver does not consume in time, abort
// (a dead control client must not hang the daemon loop)
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

// full frame (header + payload) with the same total deadline
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

// tolerant read of the snapshot tail: validates that the length prefix
// AND the string body fit in what remains of the stream; on any
// violation it leaves S as '' and returns False without raising
// exceptions (ReadBuffer would raise EReadError on a truncated tail)
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
  // result of probing a session socket: live, hard refusal (purge
  // candidate) or timeout/saturation (not live, never purgeable)
  TSocketProbe = (spLive, spDead, spTimeout);

// probe with non-blocking connect and bounded wait (~300 ms): a hung
// daemon or one with a full backlog must not freeze the enumeration
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
          // connection in progress: await the outcome with a timeout
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
        // AF_UNIX backlog full: the daemon exists but is not serving
        Result := spTimeout;
    end;
  FpClose(Fd);
end;

// a freshly created .sock may be in the bind->listen window of a
// starting daemon: never purge if its mtime is <= 5 seconds old
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

// TIniFile strips one pair of outer quotes when reading: if the value
// starts and ends with the same quote, wrap it in one more equal layer
// so that re-reading returns the exact value (same guard as in
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
        // orphan: purge socket and sidecar, but only on a hard refusal
        // and with a socket that is not recent (a starting daemon is
        // in the bind->listen window); on timeout never purge; the
        // sidecar only falls if the socket was really deleted
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
  // transition: the single socket of a previous version
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
  // honest boolean: True only when the daemon really stops responding
  // (an old daemon ignores the FRAME_CLOSE and stays alive)
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
        Exit;   // old daemon closes without replying -> False
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

function DecodeLayoutBlob(const Data: TByteArray; out ANodes: string;
  out AFocused: Longint; out ATitles: TStrArray; out AGeom: TPaneGeomArray;
  out ADeskW, ADeskH: Longint): boolean;
var
  Stream: TMemoryStream;
  Cnt, I: Longint;
  T: string;
  Flag: byte;
begin
  Result := False;
  ANodes := '';
  AFocused := 0;
  ATitles := nil;
  AGeom := nil;
  ADeskW := 0;
  ADeskH := 0;
  if Length(Data) = 0 then
    Exit;
  Stream := TMemoryStream.Create;
  try
    Stream.WriteBuffer(Data[0], Length(Data));
    Stream.Position := 0;
    if not ReadTailString(Stream, ANodes) then
      Exit;
    Cnt := Default(Longint);
    if Stream.Position + 2 * SizeOf(Longint) > Stream.Size then
      Exit;
    Stream.ReadBuffer(AFocused, SizeOf(AFocused));
    Stream.ReadBuffer(Cnt, SizeOf(Cnt));
    if (Cnt < 1) or (Cnt > MAX_PANES) then
      Exit;
    SetLength(ATitles, Cnt);
    for I := 0 to Cnt - 1 do
    begin
      if not ReadTailString(Stream, T) then
        Exit;
      ATitles[I] := T;
    end;
    if Stream.Position + 2 * SizeOf(Longint) +
       Cnt * (4 * SizeOf(Longint) + 2) > Stream.Size then
      Exit;
    Stream.ReadBuffer(ADeskW, SizeOf(ADeskW));
    Stream.ReadBuffer(ADeskH, SizeOf(ADeskH));
    SetLength(AGeom, Cnt);
    for I := 0 to Cnt - 1 do
    begin
      Stream.ReadBuffer(AGeom[I].BX, SizeOf(Longint));
      Stream.ReadBuffer(AGeom[I].BY, SizeOf(Longint));
      Stream.ReadBuffer(AGeom[I].BW, SizeOf(Longint));
      Stream.ReadBuffer(AGeom[I].BH, SizeOf(Longint));
      Flag := Default(byte);
      Stream.ReadBuffer(Flag, SizeOf(Flag));
      AGeom[I].Zoomed := Flag <> 0;
      Stream.ReadBuffer(Flag, SizeOf(Flag));
      AGeom[I].Minimized := Flag <> 0;
    end;
    Result := True;
  finally
    Stream.Free;
  end;
end;

function DecodeNewPaneEv(const Data: TByteArray; out AAt, ANewIdx,
  APaneCount: Longint; out ADir: byte; out ACols, ARows: Longint;
  out ATitle, ATerm: string): boolean;
var
  Stream: TMemoryStream;
begin
  Result := False;
  AAt := 0;
  ANewIdx := 0;
  APaneCount := 0;
  ADir := 0;
  ACols := 0;
  ARows := 0;
  ATitle := '';
  ATerm := '';
  if Length(Data) < 3 * SizeOf(Longint) + 1 + 2 * SizeOf(Longint) then
    Exit;
  Stream := TMemoryStream.Create;
  try
    Stream.WriteBuffer(Data[0], Length(Data));
    Stream.Position := 0;
    Stream.ReadBuffer(AAt, SizeOf(AAt));
    Stream.ReadBuffer(ANewIdx, SizeOf(ANewIdx));
    Stream.ReadBuffer(APaneCount, SizeOf(APaneCount));
    Stream.ReadBuffer(ADir, SizeOf(ADir));
    Stream.ReadBuffer(ACols, SizeOf(ACols));
    Stream.ReadBuffer(ARows, SizeOf(ARows));
    if not ReadTailString(Stream, ATitle) then
      Exit;
    if not ReadTailString(Stream, ATerm) then
      Exit;
    Result := True;
  finally
    Stream.Free;
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

// snapshot tolerant tail 2: window geometry; on any size violation
// it leaves Snapshot.Geom empty without raising exceptions
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
  L: Longint;
begin
  Result := False;
  FAttachError := '';
  Snapshot.LayoutNodes := '';
  Snapshot.Focused := 0;
  Snapshot.PaneCount := 0;
  Snapshot.Name := '';
  Snapshot.Profile := '';
  Snapshot.Geom := nil;
  Snapshot.DeskW := 0;
  Snapshot.DeskH := 0;
  Snapshot.ProtoVer := 0;
  FServerProto := 0;
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
  // tolerant tail of the ATTACH: version, desktop and capabilities; an
  // old daemon ignores the payload and serves the usual v1 protocol
  Data := nil;
  SetLength(Data, 4 * SizeOf(Longint));
  L := ATTACH_PROTO_VER;
  Move(L, Data[0], SizeOf(L));
  L := 0;   // DeskW/DeskH: no desktop yet at startup
  Move(L, Data[SizeOf(Longint)], SizeOf(L));
  Move(L, Data[2 * SizeOf(Longint)], SizeOf(L));
  L := ATTACH_CAP_EVENTS;
  Move(L, Data[3 * SizeOf(Longint)], SizeOf(L));
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
    // tolerant tail: a daemon from a previous version does not send it;
    // on a truncated tail the field stays '' and reading stops there
    if ReadTailString(Stream, Snapshot.Name) then
      if ReadTailString(Stream, Snapshot.Profile) then
      begin
        ReadSnapshotGeom(Stream, Snapshot);
        // tolerant tail 3: daemon version (absent in old daemons)
        if Stream.Position + SizeOf(Longint) <= Stream.Size then
          Stream.ReadBuffer(Snapshot.ProtoVer, SizeOf(Longint));
      end;
    FServerProto := Snapshot.ProtoVer;
  finally
    Stream.Free;
  end;
  // The daemon refuses clients older than itself, but an OLDER daemon happily
  // accepts a newer client and then feeds it cells of the wrong size. Refuse
  // that direction here too, instead of rendering garbage.
  if Snapshot.ProtoVer < ATTACH_PROTO_VER then
  begin
    FAttachError := 'session created by an older superterm (protocol ' +
      IntToStr(Snapshot.ProtoVer) + ', need ' + IntToStr(ATTACH_PROTO_VER) +
      '): close it or run the matching binary';
    CloseSocket;
    Exit;
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
    FRAME_LAYOUT_EV: Event.Kind := sekLayoutEv;
    FRAME_KILLPANE_EV: Event.Kind := sekKillPaneEv;
    FRAME_NEWPANE_EV: Event.Kind := sekNewPaneEv;
    FRAME_RESIZE_EV: Event.Kind := sekResizeEv;
    FRAME_TITLE_EV: Event.Kind := sekTitleEv;
    FRAME_FOCUS_EV: Event.Kind := sekFocusEv;
    FRAME_SHUTDOWN_EV: Event.Kind := sekShutdown;
  else
    // future frame: ignore instead of treating it as a lost connection
    Event.Kind := sekIgnore;
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

function TSessionClient.CloseSession(ASave: boolean): boolean;
var
  Data: TByteArray;
begin
  // tolerant byte: an old daemon ignores it (closes without saving)
  Data := nil;
  SetLength(Data, 1);
  if ASave then
    Data[0] := 1
  else
    Data[0] := 0;
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

function TSessionClient.SendNewPane(APane: integer; ADir: byte;
  const AClass, ACmd, ACwd, ATitle: string): boolean;
var
  Stream: TMemoryStream;
  Data: TByteArray;
begin
  Data := Default(TByteArray);
  Stream := TMemoryStream.Create;
  try
    Stream.WriteBuffer(ADir, SizeOf(ADir));
    WriteString(Stream, AClass);
    WriteString(Stream, ACmd);
    WriteString(Stream, ACwd);
    WriteString(Stream, ATitle);
    SetLength(Data, Stream.Size);
    Stream.Position := 0;
    Stream.ReadBuffer(Data[0], Stream.Size);
  finally
    Stream.Free;
  end;
  Result := SendFrame(FRAME_NEWPANE, APane, Data);
end;

function TSessionClient.SendFocus(APane: integer): boolean;
var
  Data: TByteArray;
begin
  Data := nil;
  Result := SendFrame(FRAME_FOCUS, APane, Data);
end;

function TSessionClient.SendRename(APane: integer;
  const ATitle: string): boolean;
var
  Stream: TMemoryStream;
  Data: TByteArray;
begin
  Data := Default(TByteArray);
  Stream := TMemoryStream.Create;
  try
    WriteString(Stream, ATitle);
    SetLength(Data, Stream.Size);
    Stream.Position := 0;
    Stream.ReadBuffer(Data[0], Stream.Size);
  finally
    Stream.Free;
  end;
  Result := SendFrame(FRAME_RENAME, APane, Data);
end;

constructor TDetachedSession.Create(const AName, AProfile: string;
  ALay: TLayout;
  const APanes: TPtyArray; const AScreens: TScreenArray;
  const ATitles: TStrArray; const ATerms: TStrArray;
  AFocused: integer; const AGeom: TPaneGeomArray;
  ADeskW, ADeskH: integer; const ATitleFixed: TBoolArray);
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
    if I <= High(ATitleFixed) then FTitleFixed[I] := ATitleFixed[I];
  end;
  FName := SanitizeSessionName(AName);
  FProfile := AProfile;
  FSocketPath := SessionSocketPathFor(FName);
  FMetaPath := SessionMetaPathFor(FName);
  FListener := -1;
  for I := 0 to MAX_CLIENTS - 1 do
  begin
    FClients[I] := Default(TClientConn);
    FClients[I].Fd := -1;
  end;
  FStop := False;
  // initial window geometry exactly as it was when detaching
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
  for I := 0 to MAX_CLIENTS - 1 do
    if FClients[I].Fd >= 0 then
    begin
      FpClose(FClients[I].Fd);
      FClients[I].Fd := -1;
    end;
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

function TDetachedSession.AttachedCount: integer;
var
  I: integer;
begin
  Result := 0;
  for I := 0 to MAX_CLIENTS - 1 do
    if FClients[I].Fd >= 0 then
      Inc(Result);
end;

function TDetachedSession.HasLegacyClient: boolean;
var
  I: integer;
begin
  Result := False;
  for I := 0 to MAX_CLIENTS - 1 do
    if (FClients[I].Fd >= 0) and FClients[I].Legacy then
      Exit(True);
end;

procedure TDetachedSession.DropClient(AIdx: integer);
var
  P: integer;
begin
  if (AIdx < 0) or (AIdx >= MAX_CLIENTS) or (FClients[AIdx].Fd < 0) then
    Exit;
  FpClose(FClients[AIdx].Fd);
  FClients[AIdx] := Default(TClientConn);
  FClients[AIdx].Fd := -1;
  // dropping a client may let the common minimum of sizes grow
  for P := 0 to FPaneCount - 1 do
    NegotiateResize(P);
  WriteSidecar;
end;

// queues bytes toward a client without ever blocking the daemon: first
// a direct non-blocking send and the rest to the egress buffer; if the
// buffer exceeds the cap the client is dead or stalled and gets dropped
function TDetachedSession.QueueOut(AIdx: integer; const Buffer;
  ASize: integer): boolean;
var
  P: PByte;
  Left, Pending: integer;
  N: ssize_t;
begin
  Result := False;
  if (FClients[AIdx].Fd < 0) or (ASize <= 0) then
    Exit;
  P := @Buffer;
  Left := ASize;
  if FClients[AIdx].OutBuf = '' then
    while Left > 0 do
    begin
      N := fpSend(FClients[AIdx].Fd, P, Left, ST_MSG_DONTWAIT);
      if N > 0 then
      begin
        Inc(P, N);
        Dec(Left, integer(N));
        FClients[AIdx].LastProgress := GetTickCount64;
      end
      else if (N < 0) and (fpgeterrno = ESysEINTR) then
        continue
      else if (N < 0) and (fpgeterrno = ESysEAGAIN) then
        Break
      else
      begin
        DropClient(AIdx);
        Exit;
      end;
    end;
  if Left > 0 then
  begin
    Pending := Length(FClients[AIdx].OutBuf);
    if Pending + Left > MAX_EGRESS then
    begin
      DropClient(AIdx);
      Exit;
    end;
    SetLength(FClients[AIdx].OutBuf, Pending + Left);
    Move(P^, FClients[AIdx].OutBuf[Pending + 1], Left);
  end;
  Result := True;
end;

function TDetachedSession.SendFrameToIdx(AIdx: integer; AKind: byte;
  APane: integer; const Buffer; ASize: integer): boolean;
var
  Hdr: TFrameHeader;
  Frame: RawByteString;
begin
  Result := False;
  if (AIdx < 0) or (AIdx >= MAX_CLIENTS) or (FClients[AIdx].Fd < 0) or
     (ASize < 0) then
    Exit;
  Hdr.Kind := AKind;
  Hdr.Reserved := 0;
  Hdr.Pane := SmallInt(APane);
  Hdr.Size := LongWord(ASize);
  Frame := '';
  SetLength(Frame, SizeOf(Hdr) + ASize);
  Move(Hdr, Frame[1], SizeOf(Hdr));
  if ASize > 0 then
    Move(Buffer, Frame[1 + SizeOf(Hdr)], ASize);
  Result := QueueOut(AIdx, Frame[1], Length(Frame));
end;

procedure TDetachedSession.Broadcast(AKind: byte; APane: integer;
  const Buffer; ASize: integer; ANeedCaps: boolean; AExcept: integer);
var
  I: integer;
begin
  for I := 0 to MAX_CLIENTS - 1 do
    if (FClients[I].Fd >= 0) and (I <> AExcept) and
       ((not ANeedCaps) or
        ((FClients[I].Caps and ATTACH_CAP_EVENTS) <> 0)) then
      SendFrameToIdx(I, AKind, APane, Buffer, ASize);
end;

procedure TDetachedSession.FlushClient(AIdx: integer);
var
  N: ssize_t;
begin
  if (FClients[AIdx].Fd < 0) or (FClients[AIdx].OutBuf = '') then
    Exit;
  N := fpSend(FClients[AIdx].Fd, @FClients[AIdx].OutBuf[1],
    Length(FClients[AIdx].OutBuf), ST_MSG_DONTWAIT);
  if N > 0 then
  begin
    Delete(FClients[AIdx].OutBuf, 1, integer(N));
    FClients[AIdx].LastProgress := GetTickCount64;
  end
  else if (N < 0) and ((fpgeterrno = ESysEAGAIN) or
     (fpgeterrno = ESysEINTR)) then
    Exit
  else
    DropClient(AIdx);
end;

// effective pane size = common minimum of what the clients requested
// (so all parse the same bytes); the result is broadcast and each
// client adjusts its TScreen upon receiving it
procedure TDetachedSession.NegotiateResize(APane: integer);
var
  I: integer;
  MinC, MinR: Longint;
  Pair: array[0..1] of Longint;
begin
  if (APane < 0) or (APane >= FPaneCount) or (FScreens[APane] = nil) then
    Exit;
  MinC := 0;
  MinR := 0;
  for I := 0 to MAX_CLIENTS - 1 do
    if (FClients[I].Fd >= 0) and (FClients[I].ReqCols[APane] > 0) and
       (FClients[I].ReqRows[APane] > 0) then
    begin
      if (MinC = 0) or (FClients[I].ReqCols[APane] < MinC) then
        MinC := FClients[I].ReqCols[APane];
      if (MinR = 0) or (FClients[I].ReqRows[APane] < MinR) then
        MinR := FClients[I].ReqRows[APane];
    end;
  if (MinC < 4) or (MinR < 2) then
    Exit;
  if (MinC = FScreens[APane].Width) and (MinR = FScreens[APane].Height) then
    Exit;
  FScreens[APane].Resize(MinC, MinR);
  if FPanes[APane] <> nil then
    FPanes[APane].Resize(MinC, MinR);
  Pair[0] := MinC;
  Pair[1] := MinR;
  Broadcast(FRAME_RESIZE_EV, APane, Pair, SizeOf(Pair), True, -1);
end;

// serializes the layout state with the same format as FRAME_LAYOUT
function TDetachedSession.BuildLayoutBlob(out AData: TByteArray): boolean;
var
  Meta: TMemoryStream;
  Cnt, I, F: Longint;
  Flag: byte;
begin
  Result := False;
  AData := nil;
  if not FGeomValid then
    Exit;
  Meta := TMemoryStream.Create;
  try
    WriteString(Meta, SaveLayoutString(FLayout));
    F := FFocused;
    Meta.WriteBuffer(F, SizeOf(F));
    Cnt := FPaneCount;
    Meta.WriteBuffer(Cnt, SizeOf(Cnt));
    for I := 0 to Cnt - 1 do
      WriteString(Meta, FTitles[I]);
    Meta.WriteBuffer(FDeskW, SizeOf(FDeskW));
    Meta.WriteBuffer(FDeskH, SizeOf(FDeskH));
    for I := 0 to Cnt - 1 do
    begin
      Meta.WriteBuffer(FGeom[I].BX, SizeOf(Longint));
      Meta.WriteBuffer(FGeom[I].BY, SizeOf(Longint));
      Meta.WriteBuffer(FGeom[I].BW, SizeOf(Longint));
      Meta.WriteBuffer(FGeom[I].BH, SizeOf(Longint));
      if FGeom[I].Zoomed then Flag := 1 else Flag := 0;
      Meta.WriteBuffer(Flag, SizeOf(Flag));
      if FGeom[I].Minimized then Flag := 1 else Flag := 0;
      Meta.WriteBuffer(Flag, SizeOf(Flag));
    end;
    SetLength(AData, Meta.Size);
    if Meta.Size > 0 then
    begin
      Meta.Position := 0;
      Meta.ReadBuffer(AData[0], Meta.Size);
    end;
    Result := True;
  finally
    Meta.Free;
  end;
end;

procedure TDetachedSession.BroadcastLayoutEv(AExcept: integer);
var
  Data: TByteArray;
begin
  if AttachedCount = 0 then
    Exit;
  if not BuildLayoutBlob(Data) then
    Exit;
  if Length(Data) > 0 then
    Broadcast(FRAME_LAYOUT_EV, -1, Data[0], Length(Data), True, AExcept);
end;

procedure TDetachedSession.BroadcastTitle(APane: integer);
var
  Meta: TMemoryStream;
  Data: TByteArray;
begin
  if (APane < 0) or (APane >= FPaneCount) or (AttachedCount = 0) then
    Exit;
  Meta := TMemoryStream.Create;
  try
    WriteString(Meta, FTitles[APane]);
    Data := nil;
    SetLength(Data, Meta.Size);
    Meta.Position := 0;
    Meta.ReadBuffer(Data[0], Meta.Size);
    Broadcast(FRAME_TITLE_EV, APane, Data[0], Length(Data), True, -1);
  finally
    Meta.Free;
  end;
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
    // tolerant tail (old clients ignore it by not reading it)
    WriteString(Meta, FName);
    WriteString(Meta, FProfile);
    // tolerant tail 2: window geometry (0 panes = no data)
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
    // tolerant tail 3: daemon protocol version (a new client uses it
    // to avoid sending v2 frames to an old daemon)
    GeomCnt := ATTACH_PROTO_VER;
    Meta.WriteBuffer(GeomCnt, SizeOf(GeomCnt));
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

// reads the first frame of a freshly accepted connection with bounded
// wait: a peer that connects and writes nothing must not hang the daemon
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

// serves an attach whose first frame was already read in Run; the
// versioned payload decides the slot: empty = legacy client (protocol
// v1), which demands exclusivity as it lacks the session-sharing events
function TDetachedSession.HandleAttach(AFd: cint; AFirstKind: byte;
  const AFirstData: TByteArray): boolean;
var
  Slot, I: integer;
  Ver: Longint;
  IsLegacy: boolean;
begin
  Result := False;
  if AFirstKind <> FRAME_ATTACH then
    Exit;
  IsLegacy := Length(AFirstData) < 4 * SizeOf(Longint);
  if HasLegacyClient then
    Exit;
  if IsLegacy and (AttachedCount > 0) then
    Exit;
  Slot := -1;
  for I := 0 to MAX_CLIENTS - 1 do
    if FClients[I].Fd < 0 then
    begin
      Slot := I;
      Break;
    end;
  if Slot < 0 then
    Exit;
  Ver := 0;
  if not IsLegacy then
  begin
    Move(AFirstData[0], Ver, SizeOf(Ver));
    if Ver < ATTACH_PROTO_VER then
      Exit;
  end;
  if not SendSnapshot(AFd) then
    Exit;
  FClients[Slot] := Default(TClientConn);
  FClients[Slot].Fd := AFd;
  FClients[Slot].Legacy := IsLegacy;
  FClients[Slot].LastProgress := GetTickCount64;
  if not IsLegacy then
  begin
    Move(AFirstData[SizeOf(Longint)], FClients[Slot].DeskW, SizeOf(Longint));
    Move(AFirstData[2 * SizeOf(Longint)], FClients[Slot].DeskH,
      SizeOf(Longint));
    Move(AFirstData[3 * SizeOf(Longint)], FClients[Slot].Caps,
      SizeOf(Longint));
  end;
  WriteSidecar;
  Result := True;
end;

// the client closed a pane: kill the process and compact mirroring the
// client (same index shifts so that INPUT stays aligned)
procedure TDetachedSession.DoKillPane(APane: integer);
var
  I, C: integer;
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
    FTitleFixed[I] := FTitleFixed[I + 1];
    FTerms[I] := FTerms[I + 1];
    FGeom[I] := FGeom[I + 1];
    for C := 0 to MAX_CLIENTS - 1 do
    begin
      FClients[C].ReqCols[I] := FClients[C].ReqCols[I + 1];
      FClients[C].ReqRows[I] := FClients[C].ReqRows[I + 1];
    end;
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
  WriteSidecar; // the sidecar pane count changed
end;

// the client syncs split tree, focus, titles and geometry; accepted
// only if the pane count matches the daemon's live state
procedure TDetachedSession.ApplyLayoutFrame(const Data: TByteArray);
var
  Nodes: string;
  Focused, DeskW, DeskH: Longint;
  Titles: TStrArray;
  Geom: TPaneGeomArray;
  NewLay: TLayout;
  I: integer;
begin
  if not DecodeLayoutBlob(Data, Nodes, Focused, Titles, Geom, DeskW,
    DeskH) then
    Exit;
  if Length(Titles) <> FPaneCount then
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
  for I := 0 to FPaneCount - 1 do
    FTitles[I] := Titles[I];
  FDeskW := DeskW;
  FDeskH := DeskH;
  for I := 0 to FPaneCount - 1 do
    FGeom[I] := Geom[I];
  FGeomValid := True;
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

// lazy load of the window classes to resolve kind/host in LIST
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

// reaps daemon children (panes created daemon-side) without blocking
procedure TDetachedSession.ReapChildren;
var
  St: cint;
begin
  St := 0;
  while fpWaitPid(-1, St, WNOHANG) > 0 do
    ;
end;

// creates a PTY for a window class or a command, like StartPaneEx but
// without FreeVision: wcSSH -> structured argv; rest -> composed command
function TDetachedSession.SpawnPaneForSpec(const AClass, ACmd, ACwd: string;
  ACols, ARows: integer; out APty: TPty; out ATerm: string;
  out ADefTitle: string): boolean;
var
  CIdx: integer;
  ShellS, CmdS, CwdS: string;
  ExecProgram, ExecSecret: string;
  ExecArgs: TStringList;
begin
  Result := False;
  APty := nil;
  ATerm := '';
  ADefTitle := '';
  EnsureCtlConfig;
  CIdx := -1;
  if AClass <> '' then
  begin
    CIdx := FindClassByName(FCtlClasses, AClass);
    if CIdx < 0 then
      Exit;
    ATerm := FCtlClasses[CIdx].Name;
    // default title of the class (mirror of StartPaneEx in the UI)
    if FCtlClasses[CIdx].Title <> '' then
      ADefTitle := FCtlClasses[CIdx].Title
    else
      ADefTitle := FCtlClasses[CIdx].Name;
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

// creates a new pane in the daemon (tree split + spawn + arrays in
// client mirror) and broadcasts NEWPANE_EV to all capable clients:
// the daemon's result is authoritative and each window is born there
function TDetachedSession.DoNewPane(AAt: integer; ADir: byte;
  const AClass, ACmd, ACwd, ATitle: string; out ANewIdx: integer;
  out AErr: string): boolean;
var
  Cols, Rows, L, PC: Longint;
  OldCount, j, C: integer;
  NewPty: TPty;
  TermS, DefTitle: string;
  Meta: TMemoryStream;
  Data: TByteArray;
  DirB: byte;
begin
  Result := False;
  ANewIdx := -1;
  AErr := '';
  if FPaneCount >= MAX_PANES then
  begin
    AErr := 'max panes';
    Exit;
  end;
  if (AAt < 0) or (AAt >= FPaneCount) then
    AAt := FFocused;
  if (AAt < 0) or (AAt >= FPaneCount) then
    AAt := 0;
  Cols := 80;
  Rows := 24;
  if FScreens[AAt] <> nil then
  begin
    Cols := FScreens[AAt].Width;
    Rows := FScreens[AAt].Height;
  end;
  OldCount := FPaneCount;
  if ADir = 1 then
  begin
    if not FLayout.SplitPane(AAt, sdH) then
    begin
      AErr := 'split failed';
      Exit;
    end;
  end
  else if not FLayout.SplitPane(AAt, sdV) then
  begin
    AErr := 'split failed';
    Exit;
  end;
  ANewIdx := FLayout.LastInsertedIndex;
  NewPty := nil;
  TermS := '';
  DefTitle := '';
  if not SpawnPaneForSpec(AClass, ACmd, ACwd, Cols, Rows, NewPty,
    TermS, DefTitle) then
  begin
    FLayout.ClosePane(ANewIdx);
    ANewIdx := -1;
    if AClass <> '' then
      AErr := 'unknown class or spawn failed'
    else
      AErr := 'spawn failed';
    Exit;
  end;
  // shift the arrays mirroring the client (DoSplit)
  for j := OldCount downto ANewIdx + 1 do
  begin
    FPanes[j] := FPanes[j - 1];
    FScreens[j] := FScreens[j - 1];
    FTitles[j] := FTitles[j - 1];
    FTitleFixed[j] := FTitleFixed[j - 1];
    FTerms[j] := FTerms[j - 1];
    FGeom[j] := FGeom[j - 1];
    for C := 0 to MAX_CLIENTS - 1 do
    begin
      FClients[C].ReqCols[j] := FClients[C].ReqCols[j - 1];
      FClients[C].ReqRows[j] := FClients[C].ReqRows[j - 1];
    end;
  end;
  FPanes[ANewIdx] := NewPty;
  FScreens[ANewIdx] := TScreen.Create(Cols, Rows, DEFAULT_SCROLLBACK);
  FTerms[ANewIdx] := TermS;
  FTitleFixed[ANewIdx] := ATitle <> '';
  if ATitle <> '' then
    FTitles[ANewIdx] := ' ' + ATitle
  else if DefTitle <> '' then
    FTitles[ANewIdx] := ' ' + DefTitle
  else if ACmd <> '' then
    FTitles[ANewIdx] := ' ' + ACmd
  else
    FTitles[ANewIdx] := ' shell';
  FGeom[ANewIdx] := Default(TPaneGeom);
  for C := 0 to MAX_CLIENTS - 1 do
  begin
    FClients[C].ReqCols[ANewIdx] := 0;
    FClients[C].ReqRows[ANewIdx] := 0;
  end;
  Inc(FPaneCount);
  FFocused := ANewIdx;
  WriteSidecar;
  Meta := TMemoryStream.Create;
  try
    L := AAt;
    Meta.WriteBuffer(L, SizeOf(L));
    L := ANewIdx;
    Meta.WriteBuffer(L, SizeOf(L));
    PC := FPaneCount;
    Meta.WriteBuffer(PC, SizeOf(PC));
    DirB := ADir;
    Meta.WriteBuffer(DirB, SizeOf(DirB));
    Meta.WriteBuffer(Cols, SizeOf(Cols));
    Meta.WriteBuffer(Rows, SizeOf(Rows));
    WriteString(Meta, FTitles[ANewIdx]);
    WriteString(Meta, FTerms[ANewIdx]);
    Data := nil;
    SetLength(Data, Meta.Size);
    Meta.Position := 0;
    Meta.ReadBuffer(Data[0], Meta.Size);
    Broadcast(FRAME_NEWPANE_EV, ANewIdx, Data[0], Length(Data), True, -1);
  finally
    Meta.Free;
  end;
  Result := True;
end;

// self-cleanup deadline; SUPERTERM_REAP_MS only exists so the tests
// do not have to wait out the production minute
function ReapGraceMs: QWord;
var
  S: string;
  V: integer;
begin
  Result := 60000;
  S := GetEnvironmentVariable('SUPERTERM_REAP_MS');
  if S <> '' then
  begin
    V := StrToIntDef(S, 0);
    if V > 0 then
      Result := QWord(V);
  end;
end;

// daemon-side save of session.ini: mirror of SaveSessionNow with the
// daemon's live state (remote Alt-X and Ctrl-S save here)
procedure TDetachedSession.DaemonSaveSession;
var
  Pin: TPaneArray;
  i: integer;
begin
  if FPaneCount < 1 then
    Exit;
  Pin := Default(TPaneArray);
  SetLength(Pin, FPaneCount);
  for i := 0 to FPaneCount - 1 do
  begin
    Pin[i].Term := FTerms[i];
    if (FTerms[i] = '') and (FPanes[i] <> nil) and FPanes[i].Alive then
    begin
      FPanes[i].QueryState;
      Pin[i].Cmd := FPanes[i].TitleCmd;
      Pin[i].Cwd := FPanes[i].TitleCwd;
      Pin[i].Args := FPanes[i].TitleArgs;
    end;
    if FTitleFixed[i] then
      Pin[i].Title := Trim(FTitles[i])
    else
      Pin[i].Title := '';
    if FGeomValid then
    begin
      Pin[i].BX := FGeom[i].BX;
      Pin[i].BY := FGeom[i].BY;
      Pin[i].BW := FGeom[i].BW;
      Pin[i].BH := FGeom[i].BH;
      Pin[i].Zoomed := FGeom[i].Zoomed;
      Pin[i].Minimized := FGeom[i].Minimized;
    end;
  end;
  SaveSession(SessionFile, FLayout, Pin, FDeskW, FDeskH);
end;

// window management via control; with attached clients each change is
// broadcast as an event so they apply it live
procedure TDetachedSession.HandleWinOp(AFd: cint; APane: integer;
  const AData: TByteArray);
var
  Ofs: integer;
  Op, HowB, DirB, B0: byte;
  ClassS, CmdS, CwdS, TitleS, ErrS: string;
  NewIdx, j, N, i, k: integer;
  Cols, Rows: Longint;
  Pair: array[0..1] of Longint;
  GC, GR, CW, CH: integer;
  Slot: st_layout.TRect;

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
  Op := AData[0];
  Ofs := 1;
  B0 := 0;
  case Op of
    WINOP_NEWPANE:
      begin
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
        ErrS := '';
        NewIdx := -1;
        if DoNewPane(APane, DirB, ClassS, CmdS, CwdS, TitleS, NewIdx,
          ErrS) then
          CtlReplyOk(AFd, IntToStr(NewIdx + 1))
        else
          CtlReplyErr(AFd, ErrS);
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
        Broadcast(FRAME_KILLPANE_EV, APane, B0, 0, True, -1);
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
        // focusing restores if it was minimized
        FGeom[APane].Minimized := False;
        FGeomValid := True;
        Broadcast(FRAME_FOCUS_EV, APane, B0, 0, True, -1);
        BroadcastLayoutEv(-1);
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
              // only one zoomed at a time (mirror of the UI)
              for j := 0 to FPaneCount - 1 do
                FGeom[j].Zoomed := False;
              FGeom[APane].Zoomed := True;
              FGeom[APane].Minimized := False;
            end;
        end;
        FGeomValid := True;
        BroadcastLayoutEv(-1);
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
          2:  // cascade
            begin
              CW := FDeskW * 2 div 3;
              CH := FDeskH * 2 div 3;
              if CW < 20 then CW := 20;
              if CH < 6 then CH := 6;
              k := 0;
              for i := 0 to N - 1 do
              begin
                Slot := CascadeRect(k, CW, CH, FDeskW, FDeskH);
                FGeom[i].BX := Slot.X;
                FGeom[i].BY := Slot.Y;
                FGeom[i].BW := Slot.W;
                FGeom[i].BH := Slot.H;
                FGeom[i].Zoomed := False;
                FGeom[i].Minimized := False;
                Inc(k);
              end;
            end;
          1:  // tile according to the split tree
            begin
              for i := 0 to N - 1 do
              begin
                FGeom[i].BW := 0;  // no manual bounds: re-tiles on attach
                FGeom[i].BH := 0;
                FGeom[i].Zoomed := False;
                FGeom[i].Minimized := False;
              end;
            end;
        else
          // NxM grid as square as possible
          GC := 1;
          while GC * GC < N do
            Inc(GC);
          GR := (N + GC - 1) div GC;
          for i := 0 to N - 1 do
          begin
            FGeom[i].BW := FDeskW div GC;
            FGeom[i].BH := FDeskH div GR;
            // BW = 0 means "no manual bounds" everywhere else, so a desktop
            // too narrow for the grid must not silently produce one
            if FGeom[i].BW < MIN_WIN_W then FGeom[i].BW := MIN_WIN_W;
            if FGeom[i].BH < MIN_WIN_H then FGeom[i].BH := MIN_WIN_H;
            FGeom[i].BX := (i mod GC) * (FDeskW div GC);
            FGeom[i].BY := (i div GC) * (FDeskH div GR);
            FGeom[i].Zoomed := False;
            FGeom[i].Minimized := False;
          end;
        end;
        FGeomValid := True;
        BroadcastLayoutEv(-1);
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
        FTitleFixed[APane] := True;
        BroadcastTitle(APane);
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
        // void the clients' requests so the common-minimum negotiation
        // does not undo the size requested via control
        for j := 0 to MAX_CLIENTS - 1 do
        begin
          FClients[j].ReqCols[APane] := 0;
          FClients[j].ReqRows[APane] := 0;
        end;
        Pair[0] := Cols;
        Pair[1] := Rows;
        Broadcast(FRAME_RESIZE_EV, APane, Pair, SizeOf(Pair), True, -1);
        CtlReplyOk(AFd, '');
      end;
    WINOP_SAVE:
      begin
        DaemonSaveSession;
        CtlReplyOk(AFd, '');
      end;
  else
    CtlReplyErr(AFd, 'unknown operation');
  end;
end;

// ephemeral control request: one request frame already read, reply on
// the same fd and return (the caller closes the connection)
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
          // session header
          WriteString(Meta, FName);
          WriteString(Meta, FProfile);
          Meta.WriteBuffer(FPaneCount, SizeOf(FPaneCount));
          Meta.WriteBuffer(FFocused, SizeOf(FFocused));
          I := AttachedCount;
          Meta.WriteBuffer(I, SizeOf(I));   // attached clients
          Meta.WriteBuffer(FDeskW, SizeOf(FDeskW));
          Meta.WriteBuffer(FDeskH, SizeOf(FDeskH));
          if AKind = FRAME_CTL_LIST then
            for I := 0 to FPaneCount - 1 do
            begin
              // kind and target resolved from the class by name
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
              // live command/cwd from the real process
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
              Meta.WriteBuffer(N, SizeOf(N));   // history lines
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
        // batched render: one CTL_DATA per ~256KB, never all of it in RAM
        Meta := TMemoryStream.Create;
        try
          Sent := 0;
          while Sent < Count do
          begin
            Take := 512;   // rows per batch
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

procedure TDetachedSession.HandleClientFrame(AIdx: integer);
var
  Kind: byte;
  Pane: integer;
  Data: TByteArray;
  Cols, Rows: integer;
  S: RawByteString;
  Ofs, NewIdx: integer;
  DirB, B0: byte;
  ClassS, CmdS, CwdS, TitleS, ErrS: string;

  function RdStr: string;
  var
    L: Longint;
  begin
    Result := '';
    L := Default(Longint);
    if Ofs + SizeOf(Longint) > Length(Data) then
      Exit;
    Move(Data[Ofs], L, SizeOf(L));
    Inc(Ofs, SizeOf(L));
    if (L < 0) or (Ofs + L > Length(Data)) then
      Exit;
    SetLength(Result, L);
    if L > 0 then
      Move(Data[Ofs], Result[1], L);
    Inc(Ofs, L);
  end;

begin
  if not ReadFrame(FClients[AIdx].Fd, Kind, Pane, Data) then
  begin
    DropClient(AIdx);
    Exit;
  end;
  B0 := 0;
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
          if FClients[AIdx].Legacy then
          begin
            // protocol v1: a single client rules, apply directly
            if FScreens[Pane] <> nil then
              FScreens[Pane].Resize(Cols, Rows);
            if FPanes[Pane] <> nil then
              FPanes[Pane].Resize(Cols, Rows);
          end
          else
          begin
            FClients[AIdx].ReqCols[Pane] := Cols;
            FClients[AIdx].ReqRows[Pane] := Rows;
            NegotiateResize(Pane);
          end;
        end;
      end;
    FRAME_DETACH:
      DropClient(AIdx);
    FRAME_CLOSE:
      begin
        // tolerant byte: 1 = save session.ini before dying
        if (Length(Data) > 0) and (Data[0] = 1) then
          DaemonSaveSession;
        DropClient(AIdx);
        FStop := True;
      end;
    FRAME_KILLPANE:
      if (Pane >= 0) and (Pane < FPaneCount) and (FPaneCount > 1) then
      begin
        DoKillPane(Pane);
        Broadcast(FRAME_KILLPANE_EV, Pane, B0, 0, True, AIdx);
      end;
    FRAME_LAYOUT:
      begin
        ApplyLayoutFrame(Data);
        if Length(Data) > 0 then
          Broadcast(FRAME_LAYOUT_EV, -1, Data[0], Length(Data), True, AIdx);
      end;
    FRAME_NEWPANE:
      begin
        DirB := 0;
        Ofs := 0;
        if Length(Data) > 0 then
        begin
          DirB := Data[0];
          Ofs := 1;
        end;
        ClassS := RdStr;
        CmdS := RdStr;
        CwdS := RdStr;
        TitleS := RdStr;
        ErrS := '';
        NewIdx := -1;
        if not DoNewPane(Pane, DirB, ClassS, CmdS, CwdS, TitleS,
          NewIdx, ErrS) then
          if ErrS <> '' then
            SendFrameToIdx(AIdx, FRAME_ERROR, -1, ErrS[1], Length(ErrS));
      end;
    FRAME_FOCUS:
      if (Pane >= 0) and (Pane < FPaneCount) then
      begin
        FFocused := Pane;
        Broadcast(FRAME_FOCUS_EV, Pane, B0, 0, True, AIdx);
      end;
    FRAME_RENAME:
      if (Pane >= 0) and (Pane < FPaneCount) then
      begin
        Ofs := 0;
        TitleS := RdStr;
        if Trim(TitleS) <> '' then
        begin
          FTitles[Pane] := ' ' + Trim(TitleS);
          FTitleFixed[Pane] := True;
          if Length(Data) > 0 then
            Broadcast(FRAME_TITLE_EV, Pane, Data[0], Length(Data), True,
              AIdx);
        end;
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
    Broadcast(FRAME_OUTPUT, APane, Buf, N, False, -1);
  end
  else if (N = 0) or (fpgeterrno <> ESysEAGAIN) then
  begin
    FPanes[APane].MarkDead;
    Broadcast(FRAME_EXIT, APane, Buf, 0, False, -1);
  end;
end;

// metadata sidecar: lets the selector show name/profile/panes
// without consuming the socket's single client slot
procedure TDetachedSession.WriteSidecar;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(FMetaPath);
  try
    Ini.WriteString('session', 'name', IniQuoteGuard(FName));
    Ini.WriteString('session', 'profile', IniQuoteGuard(FProfile));
    Ini.WriteInteger('session', 'panes', FPaneCount);
    Ini.WriteInteger('session', 'attached', AttachedCount);
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
  ReadSet, WriteSet: TFDSet;
  TV: TTimeVal;
  MaxFd, I, NewClient, N: cint;
  Kind: byte;
  Addr: TUnixSockAddr;
  AddrLen: TSockLen;
  FirstPane: integer;
  FirstData: TByteArray;
  B0: byte;
  FlowBlocked: boolean;
  NewTitle: string;
  Fails: integer;
begin
  Fails := 0;
  // From here on this process IS the session: if it dies every pane goes with
  // it and the clients only see 'connection lost'. Name it in the log and trap
  // the fatal signals so it leaves a report behind instead of vanishing.
  DebugSetRole('daemon');
  InstallCrashHandler;
  if DebugActive then
    DebugLog('daemon: session server starting (pid ' + IntToStr(FpGetPid) + ')');
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
    // One bad iteration must not take the session with it. Before this, an
    // exception anywhere under the loop -- a failed ini write, a /proc read
    // of a process that just exited, a socket error -- unwound out of Run,
    // and the finally that follows frees the session, which kills every pane
    // on the way out: the user loses every shell and every SSH connection
    // because of one recoverable error. Log it, dump the state, and carry on;
    // give up only if it keeps happening, which means the loop itself is
    // broken and spinning is worse than stopping.
    try
      // laggards: lots pending and no progress at all during the grace
      // period -> disconnect BEFORE building the fd_sets (a closed fd
      // inside the set would make select fail with EBADF)
      for I := 0 to MAX_CLIENTS - 1 do
        if (FClients[I].Fd >= 0) and
           (Length(FClients[I].OutBuf) > LAG_MIN_PENDING) and
           (GetTickCount64 - FClients[I].LastProgress > LAG_GRACE_MS) then
          DropClient(I);
      fpFD_ZERO(ReadSet);
      fpFD_ZERO(WriteSet);
      MaxFd := FListener;
      fpFD_SET(FListener, ReadSet);
      for I := 0 to MAX_CLIENTS - 1 do
        if FClients[I].Fd >= 0 then
        begin
          fpFD_SET(FClients[I].Fd, ReadSet);
          if FClients[I].OutBuf <> '' then
            fpFD_SET(FClients[I].Fd, WriteSet);
          if FClients[I].Fd > MaxFd then MaxFd := FClients[I].Fd;
        end;
      // flow control: with too much pending toward some client we do not
      // read from the PTYs; the producer throttles in the terminal buffer
      FlowBlocked := False;
      for I := 0 to MAX_CLIENTS - 1 do
        if (FClients[I].Fd >= 0) and
           (Length(FClients[I].OutBuf) > FLOW_STOP) then
        begin
          FlowBlocked := True;
          Break;
        end;
      if not FlowBlocked then
        for I := 0 to FPaneCount - 1 do
          if (FPanes[I] <> nil) and FPanes[I].Alive and
             (FPanes[I].Master >= 0) then
          begin
            fpFD_SET(FPanes[I].Master, ReadSet);
            if FPanes[I].Master > MaxFd then MaxFd := FPanes[I].Master;
          end;
      TV.tv_sec := 0;
      TV.tv_usec := 100000;
      N := fpSelect(MaxFd + 1, @ReadSet, @WriteSet, nil, @TV);
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
          // the first frame decides: FRAME_CLOSE shuts the daemon down
          // even on a brand-new connection (CloseSessionAt); FRAME_ATTACH
          // takes a slot if the versioned payload allows it; anything
          // else closes the connection
          if not ReadFirstFrame(NewClient, Kind, FirstPane, FirstData) then
            FpClose(NewClient)
          else if Kind = FRAME_CLOSE then
          begin
            if (Length(FirstData) > 0) and (FirstData[0] = 1) then
              DaemonSaveSession;
            FpClose(NewClient);
            FStop := True;
          end
          else if (Kind >= FRAME_CTL_LIST) and (Kind <= FRAME_CTL_INFO) then
          begin
            // ephemeral control request: reply and close; takes no slot
            HandleControlFrame(NewClient, Kind, FirstPane, FirstData);
            FpClose(NewClient);
          end
          else if not HandleAttach(NewClient, Kind, FirstData) then
            FpClose(NewClient);
        end;
      end;
      for I := 0 to MAX_CLIENTS - 1 do
        if (FClients[I].Fd >= 0) and
           (fpFD_ISSET(FClients[I].Fd, WriteSet) <> 0) then
          FlushClient(I);
      for I := 0 to MAX_CLIENTS - 1 do
        if (FClients[I].Fd >= 0) and
           (fpFD_ISSET(FClients[I].Fd, ReadSet) <> 0) then
          HandleClientFrame(I);
      ReapChildren;
      if not FlowBlocked then
        for I := 0 to FPaneCount - 1 do
          if (FPanes[I] <> nil) and FPanes[I].Alive and
             (FPanes[I].Master >= 0) and
             (fpFD_ISSET(FPanes[I].Master, ReadSet) <> 0) then
            HandlePaneOutput(I);
      // live titles: ad-hoc panes without a fixed title show the command
      // or the current directory, just as the UI does locally
      if GetTickCount64 - FLastTitleTick > 1500 then
      begin
        FLastTitleTick := GetTickCount64;
        for I := 0 to FPaneCount - 1 do
          if (FPanes[I] <> nil) and FPanes[I].Alive and
             (FTerms[I] = '') and (not FTitleFixed[I]) then
          begin
            FPanes[I].QueryState;
            if FPanes[I].TitleCmd <> '' then
              NewTitle := ' ' + Copy(FirstWordOf(FPanes[I].TitleCmd), 1, 24)
            else if FPanes[I].TitleCwd <> '' then
              NewTitle := ' ' + Copy(ExtractFileName(FPanes[I].TitleCwd),
                1, 24)
            else
              NewTitle := FTitles[I];
            if NewTitle <> FTitles[I] then
            begin
              FTitles[I] := NewTitle;
              BroadcastTitle(I);
            end;
          end;
      end;
      // self-cleanup: all panes dead and nobody attached for a minute
      // -> the session no longer serves anyone, close it on its own
      FlowBlocked := False;
      for I := 0 to FPaneCount - 1 do
        if (FPanes[I] <> nil) and FPanes[I].Alive then
        begin
          FlowBlocked := True;
          Break;
        end;
      if FlowBlocked or (AttachedCount > 0) then
        FEmptySince := 0
      else if FEmptySince = 0 then
        FEmptySince := GetTickCount64
      else if GetTickCount64 - FEmptySince > ReapGraceMs then
        FStop := True;
      Fails := 0;
    except
      on E: Exception do
      begin
        Inc(Fails);
        if DebugActive then
          DebugLog(Format('daemon: exception in main loop (%d): %s: %s',
            [Fails, E.ClassName, E.Message]));
        DumpNow('unhandled ' + E.ClassName + ': ' + E.Message);
        if Fails > 50 then
        begin
          if DebugActive then
            DebugLog('daemon: too many consecutive failures, shutting down');
          FStop := True;
        end;
      end;
    end;
  end;
  // orderly shutdown notice to capable clients; legacy ones see the
  // EOF and react as they do today (lost connection)
  B0 := 0;
  Broadcast(FRAME_SHUTDOWN_EV, -1, B0, 0, True, -1);
end;

function StartDetachedServer(const AName, AProfile: string; ALay: TLayout;
  const APanes: TPtyArray; const AScreens: TScreenArray;
  const ATitles: TStrArray; const ATerms: TStrArray;
  AFocused: integer; const AGeom: TPaneGeomArray;
  ADeskW, ADeskH: integer;
  const ATitleFixed: TBoolArray): boolean;
var
  ReadyPipe: TFilDes;
  Pid: TPid;
  B: byte;
  Server: TDetachedSession;
  NullFd: cint;
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
    // The detached server has no terminal UI, so the inherited client
    // descriptors must go for the launching shell to regain the terminal.
    // But they must NOT be left FREE. Descriptors are handed out lowest-first,
    // so the next socket the daemon opens -- the listener, or an accepted
    // client -- lands on fd 1 or 2. From then on the RTL's unhandled-exception
    // reporter, which unconditionally writes the message to stderr, is writing
    // into a client's frame stream; and when that write fails (EPIPE once the
    // client is gone), the compiler-emitted I/O check promotes the failure to
    // an EInOutError, which is itself unhandled, which reports to stderr
    // again, which fails again: an infinite recursion that eats the stack and
    // kills the daemon with SIGSEGV. That is precisely the crash captured on
    // 2026-08-23, whose backtrace was TObject.NewInstance / Exception.CreateRes
    // / SDiskFull with CatchUnhandledException repeating -- SDiskFull being
    // FPC's message for run-time error 101, which on GNU/Linux means EPIPE,
    // not a full disk.
    //
    // Reopening them on /dev/null costs nothing and makes that write a no-op,
    // so the reporter can finish and the process dies cleanly instead of
    // recursing. dup2 closes the old descriptor atomically, so there is no
    // window in which they are free.
    NullFd := FpOpen('/dev/null', O_RDWR);
    if NullFd >= 0 then
    begin
      FpDup2(NullFd, 0);
      FpDup2(NullFd, 1);
      FpDup2(NullFd, 2);
      if NullFd > 2 then
        FpClose(NullFd);
    end
    else
    begin
      FpClose(0);
      FpClose(1);
      FpClose(2);
    end;
    Server := TDetachedSession.Create(AName, AProfile, ALay, APanes,
      AScreens, ATitles, ATerms, AFocused, AGeom, ADeskW, ADeskH,
      ATitleFixed);
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
