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
  st_config, st_wclass, st_layout, st_pty, st_screen, st_session, st_debug,
  st_poll, st_cpu;

const
  FRAME_ATTACH = 1;
  FRAME_INPUT = 2;
  FRAME_RESIZE = 3;
  FRAME_DETACH = 4;
  FRAME_CLOSE = 5;
  FRAME_KILLPANE = 6;   // pane >= 0 closes one; pane=-1 closes all atomically
  FRAME_LAYOUT = 7;     // attached client syncs tree/geometry
  FRAME_NEWPANE = 8;    // QWord BaseRevision; byte Dir; Class,Cmd,Cwd,Title
  FRAME_FOCUS = 9;      // changes the focused pane (pane in header)
  FRAME_RENAME = 10;    // string NewTitle (pane in header)
  // frame kind 16 retired: a live session has no save-layout operation
  FRAME_LAYOUT_LOCK = 17; // pane=-1 atomically locks every existing pane
  FRAME_LAYOUT_UNLOCK = 18;
  FRAME_CLIENT_SIZE = 19; // physical host Cols,Rows; never changes layout alone

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
  FRAME_KILLPANE_EV = 27;  // pane >= 0 closed; pane=-1 = whole workspace
  FRAME_NEWPANE_EV = 28;   // At,NewIdx,PaneCount,Dir,Cols,Rows,Title,Term
  FRAME_RESIZE_EV = 29;    // Longint Cols,Rows (pane in header)
  FRAME_TITLE_EV = 30;     // string Title (pane in header)
  FRAME_FOCUS_EV = 31;     // focused pane (pane in header)
  FRAME_SHUTDOWN_EV = 32;  // the session is shutting down
  FRAME_LAYOUT_LOCK_REPLY = 33; // byte granted; reply only to requester
  FRAME_HOST_SUMMARY_EV = 34; // count,min host WxH,all-hosts-match
  FRAME_LAYOUT_PREVIEW = 35; // cosmetic gesture; never changes canonical state
  FRAME_LAYOUT_PREVIEW_EV = 36; // relayed to every other capable viewer
  // Canonical state for a viewer which currently owns another pane. Its
  // FRAME_LAYOUT_EV-shaped payload carries the viewer's own pane mask in
  // Changes, so those panes remain locally interactive while every peer
  // commit and viewer-relative lock bit is applied immediately.
  FRAME_LAYOUT_PEER_EV = 37;

  // FRAME_LAYOUT_PREVIEW operations. Bounds, wireframe and outline show/hide
  // carry a desktop-local X,Y,W,H rectangle. Tail/clear operations are
  // ordering markers and carry a zero rectangle. CLEAR is also gesture END.
  PREVIEW_OP_BOUNDS = 1;
  PREVIEW_OP_WIREFRAME = 2;
  PREVIEW_OP_OUTLINE_SHOW = 3;
  PREVIEW_OP_OUTLINE_HIDE = 4;
  PREVIEW_OP_TAIL_BEGIN = 5;
  PREVIEW_OP_TAIL_END = 6;
  PREVIEW_OP_CLEAR = 7;
  PREVIEW_OP_END = PREVIEW_OP_CLEAR;

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

  // Ceiling for one frame. FRAME_SCREEN carries a pane's whole grid plus its
  // scrollback as raw TCell records, so this limit is really a CELL budget:
  // 64 MB used to allow ~4.8M cells at 14 bytes each. Per-cell truecolor grew
  // TCell to 24 bytes, which silently cut that capacity by 40% -- a pane over
  // roughly 280 columns with a full scrollback stopped being attachable at all
  // (WriteFrameTo refused the frame). Sized back to the same number of cells.
  // A compact wire format would be the better long-term answer; this restores
  // the previous capacity without another format change.
  MAX_FRAME_SIZE = 112 * 1024 * 1024;
  // Length-prefixed command strings are configuration/metadata, never screen
  // dumps.  Keep their allocation bounded independently from the much larger
  // FRAME_SCREEN ceiling.
  MAX_WIRE_STRING_SIZE = 1024 * 1024;
  // Every complete command received by the daemon crosses this one global
  // FIFO before it can mutate session state.  The reactor is its sole
  // producer and consumer; the bounds prevent a burst of local clients from
  // turning framing into unbounded process memory.
  COMMAND_QUEUE_SLOTS = 512;
  COMMAND_QUEUE_BYTE_LIMIT = MAX_FRAME_SIZE;
  INPUT_COMPACT_THRESHOLD = 64 * 1024;

  // versioned attach (tolerant tail of the FRAME_ATTACH payload):
  // ProtoVer, DeskW, DeskH, Caps; no payload = exclusive legacy client
  // 3: TCell gained per-cell truecolor (FgRGB/BgRGB), so SizeOf(TCell) -- which
  //    IS the FRAME_SCREEN element size -- grew from 14 to 24 bytes. A daemon
  //    and a client are separate processes and can be different builds, and a
  //    daemon outlives its clients, so a 24-byte producer feeding a 14-byte
  //    consumer reads every cell at the wrong offset and the pane fills with
  //    garbage. The version must be refused on BOTH sides.
  // 4: historical per-client resize-policy slot (reserved in v5).
  // 5: one daemon-authoritative desktop for every client; geometry includes
  //    fullscreen and canonical PTY dimensions.
  // 6: layout proposals carry a pane-change mask, so concurrent operations
  //    on different windows merge instead of blocking or overwriting.
  // 7: authoritative layout state carries one transient lock bit per pane.
  // 8: FRAME_LAYOUT is the atomic commit and releases the sender's layout
  //    ownership; there is no successful-operation UNLOCK/snapshot pair.
  // 9: every layout LOCK has an explicit grant/deny reply. A client never
  //    starts a local visual mutation before the daemon has granted it.
  // 10: pane creation is a daemon-authoritative one-shot command carrying its
  //     base revision. It acquires the structural lease in the FIFO consumer,
  //     so creating the first pane cannot be lost behind the final zero-pane
  //     layout revision while a stale non-empty pane index is rejected.
  // 11: one KILLPANE_EV with pane=-1 replaces a burst of up to sixteen
  //     individual close events, so every viewer applies Close all inside
  //     one visual transaction even at the socket drain budget boundary.
  // 12: clients publish their physical host dimensions. A deliberate host
  //     resize can atomically replace the canonical desktop; fullscreen may use raw
  //     passthrough for several viewers only when every host has the same
  //     geometry, otherwise it uses the smallest common viewport.
  // 13: host compatibility is an independent event. It reaches every ready
  //     viewer even while that viewer owns a layout lease, so an attaching,
  //     detaching or resizing peer can stop unsafe raw passthrough without
  //     waiting for an unrelated window gesture to finish.
  // 14: the owner of a pane lease can publish transient cosmetic gesture
  //     previews. They are FIFO-ordered with the final FRAME_LAYOUT but never
  //     mutate canonical geometry, revision, PTYs or focus.
  // 15: a canonical commit on one pane also reaches viewers holding another
  //     pane lease. The peer event preserves their local pane and deliberately
  //     leaves its older lease-base revision unchanged.
  ATTACH_PROTO_VER = 15;
  ATTACH_CAP_EVENTS = 1;   // bit0 of Caps: understands events 26+

  // Preview frames remain on the ordered command socket. Callers coalesce
  // pointer motion to this interval; switching only these writes to
  // non-blocking could leave a partial frame ahead of reliable commands.
  LAYOUT_PREVIEW_MIN_INTERVAL_MS = 16;
  LAYOUT_PREVIEW_TAIL_MS = 2000;
  LAYOUT_PREVIEW_PAYLOAD_SIZE = 44;

  LAYOUT_CHANGE_DESKTOP = LongWord($20000000);
  LAYOUT_CHANGE_TREE = LongWord($40000000);
  LAYOUT_CHANGE_PANES = LongWord($0000FFFF);

  MAX_CLIENTS = 8;
  CONTROL_LAYOUT_OWNER = MAX_CLIENTS; // transient owner for one-shot CLI ops
  // accepted sockets which have not become interactive clients: handshakes
  // and one-shot control requests. They never consume an interactive slot.
  MAX_PENDING_CONNECTIONS = 16;
  // Explicit pane closes never wait in the socket reactor. SIGKILLed direct
  // children stay in this small bounded reap set until waitpid(WNOHANG).
  MAX_RETIRED_CHILDREN = 256;
  // hard cap on the per-client output buffer (immediate disconnect)
  MAX_EGRESS = 8 * 1024 * 1024;
  // lagging client: high pending with no progress at all during the
  // grace period -> disconnect so the session stays alive
  LAG_MIN_PENDING = 512 * 1024;
  LAG_GRACE_MS = 10000;
  FIRST_FRAME_TIMEOUT_MS = 1000;
  LAYOUT_LOCK_REPLY_TIMEOUT_MS = 2000;
  LAYOUT_LOCK_REPLY_POLL_MS = 100;
  LAYOUT_LOCK_REPLY_POLLS =
    LAYOUT_LOCK_REPLY_TIMEOUT_MS div LAYOUT_LOCK_REPLY_POLL_MS;
  CONTROL_IDLE_TIMEOUT_MS = 5000;
  // A local listener must not be able to park an attaching UI forever after
  // accept(). Handshake I/O uses non-blocking send/recv under one total
  // deadline. GNU FPC supplies a monotonic tick; Darwin 3.2.2 uses wall time,
  // whose backwards jumps are detected and fail closed by TWaitDeadline.
  ATTACH_IO_POLL_MS = 100;
  ATTACH_IO_WAIT_POLLS = 300;
  CONNECT_WAIT_POLLS = 30;
  IO_BUDGET = 256 * 1024;
  FRAME_BUDGET = 32;
  ACCEPT_BUDGET = 8;
  POLL_TICK_MS = 100;
  // A point-in-time attach snapshot is allowed to be much larger than the
  // normal live egress queue, but it is still bounded so one local peer cannot
  // make the daemon allocate until the process is killed by the OS.
  MAX_SNAPSHOT_EGRESS = 256 * 1024 * 1024;
  // The interactive client must obey the same rule as the daemon: no peer
  // may stop reading and park the UI thread in send(2).  Complete frames are
  // queued atomically up to this bound and drained with MSG_DONTWAIT.
  CLIENT_EGRESS_LIMIT = MAX_EGRESS;
  CLIENT_CLOSE_POLL_MS = 100;
  CLIENT_CLOSE_WAIT_POLLS = 15;

  // Workers feed the socket reactor through a bounded in-process queue. If
  // the main reactor is busy producing a snapshot/capture, a full queue
  // back-pressures only the worker's PTYs instead of growing without limit.
  WORKER_RESULT_SLOTS = 512;
  MAX_WORKER_RESULT_BYTES = 16 * 1024 * 1024;

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

  // geometry of a window in the one daemon-authoritative desktop
  TPaneGeom = record
    BX, BY, BW, BH: Longint;
    Cols, Rows: Longint;
    Zoomed: boolean;
    Minimized: boolean;
    FullScreen: boolean;
  end;
  TPaneGeomArray = array of TPaneGeom;

  // Fixed protocol-v14+ payload (44 bytes). Reserved must be all zero. The
  // daemon also keys it by the connection generation, so a recycled client
  // slot can never continue an old preview with a reused GestureId.
  TLayoutPreview = packed record
    GestureId: QWord;
    BaseRevision: QWord;
    Seq: QWord;
    Op: byte;
    Reserved: array[0..2] of byte;
    X, Y, W, H: Longint;
  end;

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
    Revision: QWord;
    ClientCount: Longint;
    LockedPanes: LongWord;
    MinHostW, MinHostH: Longint;
    HostSizesMatch: boolean;
    HostSummaryValid: boolean;
    Panes: array[0..MAX_PANES - 1] of TSessionPaneSnapshot;
  end;

  TSessionEventKind = (sekOutput, sekExit, sekError, sekLost,
    sekLayoutEv, sekLayoutPeerEv, sekKillPaneEv, sekNewPaneEv, sekResizeEv, sekTitleEv,
    sekFocusEv, sekHostSummaryEv, sekLayoutPreviewEv, sekShutdown, sekIgnore);

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
    FLayoutRevision: QWord;
    FClientCount: Longint;
    FLockedPanes: LongWord;
    FMinHostW, FMinHostH: Longint;
    FHostSizesMatch: boolean;
    FHostSummaryValid: boolean;
    FInBuf: RawByteString;
    FInPos: integer;
    FOutBuf: RawByteString;
    FOutPos: integer;
    FPeerClosed: boolean;
    FNextLayoutLockRequest: QWord;
    FNextPreviewId: QWord;
    FLastPreviewId: QWord;
    FLastPreviewTick: QWord;
    FQueuedEvents: array of TSessionEvent;
    FQueuedEventHead: integer;
    // why the last Connect failed, so the UI can say something useful
    // instead of silently falling back to a fresh local session
    FAttachError: string;
    function SendFrame(AKind: byte; APane: integer;
      const Data: TByteArray): boolean;
    function ReadFrame(out AKind: byte; out APane: integer;
      out Data: TByteArray): boolean;
    function DecodeEvent(AKind: byte; APane: integer;
      const AData: TByteArray; out AEvent: TSessionEvent): boolean;
    procedure QueueEvent(const AEvent: TSessionEvent);
    function PopQueuedEvent(out AEvent: TSessionEvent): boolean;
    function FlushOutgoing: boolean;
    function FlushOutgoingBounded(AWaitPolls: integer): boolean;
    function OutputPending: boolean;
    procedure CloseSocket;
  public
    constructor Create;
    destructor Destroy; override;
    function Connect(const APath: string; out Snapshot: TSessionSnapshot;
      AHostW: integer = 0; AHostH: integer = 0): boolean;
    function Poll(out Event: TSessionEvent): boolean;
    function SendInput(APane: integer; const S: RawByteString): boolean;
    function SendResize(APane, ACols, ARows: integer): boolean;
    function SendClientSize(ACols, ARows: integer): boolean;
    function Detach: boolean;
    // closes this viewer; the daemon stops only for the last viewer
    function CloseSession: boolean;
    // closes a daemon pane (the client compacts in mirror)
    function SendKillPane(APane: integer): boolean;
    // syncs split tree and shared window geometry; focus uses SendFocus
    function SendLayout(const ANodes: string; AFocused: integer;
      const ATitles: TStrArray; const AGeom: TPaneGeomArray;
      ADeskW, ADeskH: integer; AChangeMask: LongWord): boolean;
    function LockLayout(APane: integer): boolean;
    function UnlockLayout(APane: integer): boolean;
    function NewPreviewId: QWord;
    function SendLayoutPreview(APane: integer; AGestureId,
      ABaseRevision, ASeq: QWord; AOp: byte; AX, AY, AW, AH: Longint;
      AForce: boolean = False): boolean;
    // Marks a canonical layout as applied by the UI. Merely reading and
    // queueing its event must not advance the revision used by LOCK.
    procedure AcceptLayoutState(ARevision: QWord; ALockedPanes: LongWord);
    // new pane created by the daemon; the window arrives via NEWPANE_EV
    function SendNewPane(APane: integer; ADir: byte;
      const AClass, ACmd, ACwd, ATitle: string): boolean;
    function SendFocus(APane: integer): boolean;
    function SendRename(APane: integer; const ATitle: string): boolean;
    property Connected: boolean read FConnected;
    property AttachError: string read FAttachError;
    // version of the daemon we are attached to (0 = pre-v2)
    property ServerProto: Longint read FServerProto;
    property LayoutRevision: QWord read FLayoutRevision;
    property ClientCount: Longint read FClientCount;
    property LockedPanes: LongWord read FLockedPanes;
    property MinHostW: Longint read FMinHostW;
    property MinHostH: Longint read FMinHostH;
    property HostSizesMatch: boolean read FHostSizesMatch;
    property HostSummaryValid: boolean read FHostSummaryValid;
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
    Id: string;        // session identity (see st_pty.PaneSessionChain)
    // ids of the sessions inside whose panes this session currently has a
    // client (the union of the attached clients' chains)
    ClientChains: string;
  end;
  TSessionInfoArray = array of TSessionInfo;

// The nesting guard. A superterm started inside a pane must never attach to
// the session that pane belongs to, nor to any session above it: the outer
// session would render the inner, which renders the outer... These answer
// whether the guard applies here, and whether a given session is safe to
// attach to from here. A session whose identity cannot be known -- its
// daemon predates the sidecar id -- is treated as unsafe, exactly as every
// nested start was before; SUPERTERM_ALLOW_NESTED=1 still overrides.
function NestingGuardActive: boolean;
function SessionAllowedFromHere(const AInfo: TSessionInfo;
  const AAll: TSessionInfoArray): boolean;
procedure KeepAllowedSessions(var AInfos: TSessionInfoArray);

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

  // One process-wide namespace protects publication/removal of a named
  // session. Busy is retryable; Error means the lock path itself was not a
  // safe regular file or another non-contention syscall failed.
  TSessionNameLockResult = (snlAcquired, snlBusy, snlError);

  // A fork has four materially different outcomes. A pre-transfer failure
  // leaves the parent in local mode; dssOwnershipLost means the child had
  // already adopted the PTYs and the parent must abandon its duplicates.
  TDetachedServerStartResult = (dssFailed, dssParentStarted,
    dssOwnershipLost, dssChildFinished);
  TDetachedServerChildHook = procedure of object;

// simple control request (OK/ERR): connects, sends one frame, waits for
// the reply and closes; AReply carries the error message if any
function CtlSimple(const ASocket: string; AKind: byte; APane: integer;
  const APayload: TByteArray; out AReply: string): boolean;

// control request with data (LIST/CAPTURE/INFO): same but delivering
// each FRAME_CTL_DATA through the callback until FRAME_CTL_END
function CtlStream(const ASocket: string; AKind: byte; APane: integer;
  const APayload: TByteArray; AOnData: TCtlDataProc): boolean;

// Shared by ordinary startup and the restricted SSH entry. A held lock is
// deliberately process-global so the two paths never open/close independent
// POSIX record-lock descriptors for the same session.
function TryHoldSessionNameLock(const AName: string): TSessionNameLockResult;
procedure ReleaseHeldSessionNameLock;

function StartDetachedServer(const AName, AProfile: string; ALay: TLayout;
  const APanes: TPtyArray; const AScreens: TScreenArray;
  const ATitles: TStrArray; const ATerms: TStrArray;
  AFocused: integer; const AGeom: TPaneGeomArray;
  ADeskW, ADeskH: integer;
  const ATitleFixed: TBoolArray;
  AChildHook: TDetachedServerChildHook): TDetachedServerStartResult;

// decodes the FRAME_LAYOUT / FRAME_LAYOUT_EV payload
function DecodeLayoutBlob(const Data: TByteArray; out ANodes: string;
  out AFocused: Longint; out ATitles: TStrArray; out AGeom: TPaneGeomArray;
  out ADeskW, ADeskH: Longint; out ARevision: QWord;
  out AClientCount: Longint; out AChangeMask, ALockedPanes: LongWord;
  out AMinHostW, AMinHostH: Longint; out AHostSizesMatch: boolean): boolean;

// decodes FRAME_HOST_SUMMARY_EV: viewer count, smallest host and whether all
// physical host geometries are identical
function DecodeHostSummaryBlob(const Data: TByteArray; out AClientCount,
  AMinHostW, AMinHostH: Longint; out AHostSizesMatch: boolean): boolean;

// Structural decoder for the fixed protocol-v14 preview payload. Desktop
// bounds are validated by the daemon because only it owns the canonical size.
function DecodeLayoutPreviewBlob(const Data: TByteArray;
  out APreview: TLayoutPreview): boolean;

// decodes the FRAME_NEWPANE_EV payload
function DecodeNewPaneEv(const Data: TByteArray; out AAt, ANewIdx,
  APaneCount: Longint; out ADir: byte; out ACols, ARows: Longint;
  out ATitle, ATerm: string): boolean;

var
  AttachRequested: boolean = False;
  AttachSocket: string = '';   // socket resolved by the CLI ('' = selector)
  CliSessionName: string = ''; // name requested with --session/--sesion
  // Set only by the restricted OpenSSH ForceCommand entry point.  The UI
  // then bypasses interactive startup selection and always materialises the
  // exact configured default session (which may legitimately have no panes).
  SshEntryMode: boolean = False;
  // Fork gives each process its own copy.  Only the daemon child sets this
  // after Run has returned; the program block then finalizes Pascal units
  // once and leaves through the raw Unix exit instead of inherited atexit
  // handlers.
  DetachedServerChildFinished: boolean = False;

implementation

const
  SESSION_CREATE_WAIT_MS = 30000;
  SESSION_CREATE_RETRY_MS = 25;
  // FPC 3.2.2 exposes struct flock/F_SETLK but not these platform values.
  {$ifdef linux}
  SESSION_F_WRLCK = 1;
  {$else}
  SESSION_F_WRLCK = 3;
  {$endif}

var
  HeldSessionNameLockFD: cint = -1;
  HeldSessionNameLockName: string = '';

function SessionStartupTestStage(const AStage: string): boolean;
begin
  Result := (GetEnvironmentVariable('SUPERTERM_TESTING') = '1') and
    SameText(GetEnvironmentVariable('SUPERTERM_TEST_DAEMON_STAGE'), AStage);
end;

function SessionStartupPollAttempts: integer;
var
  V: integer;
begin
  Result := SESSION_CREATE_WAIT_MS div 100;
  if (GetEnvironmentVariable('SUPERTERM_TESTING') = '1') and
     TryStrToInt(GetEnvironmentVariable('SUPERTERM_TEST_STARTUP_POLLS'), V) and
     (V >= 1) and (V <= Result) then
    Result := V;
end;

type
  // One deadline is shared by every frame in a bounded handshake. GNU FPC
  // obtains GetTickCount64 from CLOCK_MONOTONIC; Darwin FPC 3.2.2 falls back
  // to gettimeofday, so LastTick also makes a wall-clock rollback fail closed.
  TWaitDeadline = record
    ExpiresAt: QWord;
    LastTick: QWord;
    PollMs: integer;
    {$ifdef SUPERTERM_TEST_BUILD}
    ReadyCount: integer;
    Reached: boolean;
    {$endif}
  end;

  TFrameHeader = packed record
    Kind: byte;
    Reserved: byte;
    Pane: SmallInt;
    Size: LongWord;
  end;

  // An attached interactive client owns only transport state. Desktop and
  // PTY geometry live once, in TDetachedSession, and are never copied here.
  TClientConn = record
    Fd: cint;
    Generation: QWord;       // never reused with the same slot
    Ready: boolean;          // snapshot queued; may receive live events
    Caps: Longint;
    HostW, HostH: Longint;  // complete physical terminal, including UI bars
    Legacy: boolean;         // ATTACH without payload: protocol v1, exclusive
    OutBuf: RawByteString;
    OutPos: integer;          // sent prefix retained to avoid memmove per send
    InBuf: RawByteString;
    InPos: integer;           // consumed prefix; compacted only occasionally
    PeerClosed: boolean;      // EOF observed; buffered commands still drain
    CloseQueued: boolean;     // synthetic EOF already ordered in the FIFO
    TerminalQueued: boolean;  // DETACH/CLOSE ordered; stop accepting successors
    // prefix of OutBuf which belongs to the initial snapshot. Normal live
    // output is queued behind it and the regular 8 MB cap resumes once this
    // prefix has drained.
    SnapshotPending: QWord;
    LastProgress: QWord;     // last tick with bytes accepted by its socket
    WriteUsed: integer;      // bytes sent during the current reactor turn
    FramesUsed: integer;     // frames handled during the current reactor turn
    // SUPERTERM_SESSION_CHAIN of the client's own environment: non-empty
    // when the client runs inside a pane of another session. Published in
    // the sidecar so a nested start elsewhere can see that THIS session is
    // being displayed inside that one (see SessionAllowedFromHere).
    Chain: string;
  end;

  TPendingConn = record
    Fd: cint;
    Generation: QWord;
    InBuf: RawByteString;
    InPos: integer;
    OutBuf: RawByteString;
    OutPos: integer;
    Deadline: QWord;
    LastProgress: QWord;
    CloseAfterWrite: boolean;
    PeerClosed: boolean;
    CloseQueued: boolean;
    CommandQueued: boolean;   // pending peers have exactly one request
  end;

  TFramePop = (fpNeedMore, fpReady, fpInvalid);

  TCommandOrigin = (coPending, coClient);

  TQueuedCommand = record
    Sequence: QWord;
    Origin: TCommandOrigin;
    Slot: integer;
    Generation: QWord;
    Kind: byte;
    Pane: integer;
    PeerClose: boolean;
    Data: TByteArray;
  end;

  TLayoutPreviewState = record
    Active: boolean;
    Ended: boolean;
    TailRequested: boolean;
    TailAuthorized: boolean;
    Owner: integer;
    Generation: QWord;
    TailRevision: QWord;
    TailDeadline: QWord;
    Last: TLayoutPreview;
    LastVisual: TLayoutPreview;
    HasVisual: boolean;
  end;

  TDetachedSession = class;

  TWorkerResult = record
    Kind: byte;
    Pane: integer;
    Data: TByteArray;
  end;

  // One pane reactor owns a stable set of pane indexes for its whole
  // lifetime. Pane insertion/removal stops and drains every worker before
  // compacting arrays, then rebuilds the small pool with fresh assignments.
  TPanePollWorker = class(TThread)
  private
    FOwner: TDetachedSession;
    FWorkerIndex: integer;
    FPaneIndexes: array[0..MAX_PANES - 1] of integer;
    FPaneCount: integer;
    FWakePipe: TFilDes;
    procedure Wake;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TDetachedSession; AWorkerIndex: integer;
      const APaneIndexes: array of integer);
    destructor Destroy; override;
    procedure RequestStop;
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
    FPidIdentity: string;
    FName: string;
    FProfile: string;
    FListener: cint;
    // Set only after the listener exists and the child hook has relinquished
    // the inherited UI. Before that edge, destructor must not touch objects
    // which the parent still owns.
    FOwnsPanes: boolean;
    FSocketDev, FSocketIno: QWord;
    FSocketIdentityValid: boolean;
    FClients: array[0..MAX_CLIENTS - 1] of TClientConn;
    FPending: array[0..MAX_PENDING_CONNECTIONS - 1] of TPendingConn;
    FRetiredChildren: array[0..MAX_RETIRED_CHILDREN - 1] of TPid;
    FRetiredChildCount: integer;
    FCommandQueue: array[0..COMMAND_QUEUE_SLOTS - 1] of TQueuedCommand;
    FCommandHead: integer;
    FCommandCount: integer;
    FCommandBytes: QWord;
    FNextCommandSequence: QWord;
    FNextConnectionGeneration: QWord;
    FDispatchCursor: integer;
    FStop: boolean;
    FGeom: array[0..MAX_PANES - 1] of TPaneGeom;
    FGeomValid: boolean;
    FDeskW, FDeskH: Longint;
    FRevision: QWord;
    // Owner of a structural transaction (tree changes, pane creation and
    // removal).  This must be independent of the per-pane owner array: when
    // the desktop has zero panes there are no array slots to lock.
    FLayoutTreeOwner: integer;
    FPaneLayoutOwner: array[0..MAX_PANES - 1] of integer;
    FPaneLeaseGeneration: array[0..MAX_PANES - 1] of QWord;
    FPaneLeaseRevision: array[0..MAX_PANES - 1] of QWord;
    FLayoutPreviews: array[0..MAX_PANES - 1] of TLayoutPreviewState;
    FCtlClasses: TWindowClassArray;   // classes resolved for LIST/spawn
    FCtlClassesLoaded: boolean;
    FCtlCfg: TConfig;                 // config for daemon-side spawns
    FEmptySince: QWord;               // tick with no clients or live panes
    FLastTitleTick: QWord;            // periodic title derivation
    FPaneLocks: array[0..MAX_PANES - 1] of TRTLCriticalSection;
    FPaneLocksInitialized: integer;
    FWorkers: array[0..MAX_PANES - 1] of TPanePollWorker;
    FWorkerCount: integer;
    FAvailableCPUs: integer;
    FConfiguredThreads: integer;      // 0=auto; otherwise total daemon limit
    FThreadLimit: integer;            // effective total, CPU/pane capped
    FWorkerResultPipe: TFilDes;
    FWorkerResultLock: TRTLCriticalSection;
    FWorkerResultLockInitialized: boolean;
    FWorkerResultSpace: PRTLEvent;
    FWorkerResults: array[0..WORKER_RESULT_SLOTS - 1] of TWorkerResult;
    FWorkerResultHead: integer;
    FWorkerResultCount: integer;
    FWorkerResultBytes: integer;
    function CreateListener: boolean;
    function OwnsSocketPath: boolean;
    function AttachedCount: integer;
    function HasLegacyClient: boolean;
    procedure ClientSizeSummary(out AMinW, AMinH: Longint;
      out AAllMatch: boolean);
    procedure SharedZoomedPaneSize(ADeskW, ADeskH: Longint;
      AFullScreen: boolean; out ACols, ARows: Longint);
    procedure BroadcastHostSummaryEv;
    procedure BroadcastLayoutPreview(APane, AExcept: integer;
      const APreview: TLayoutPreview);
    procedure CancelLayoutPreview(APane: integer; ABroadcast: boolean = True);
    procedure CancelAllLayoutPreviews(ABroadcast: boolean = True);
    function ExpireLayoutPreviews: boolean;
    procedure SendActiveLayoutPreviews(AClient: integer);
    procedure AuthorizeLayoutPreviewTails(AOwner: integer;
      ACommitBase: QWord; AChanges: LongWord);
    procedure HandleLayoutPreview(AClient, APane: integer;
      const AData: TByteArray);
    procedure DropClient(AIdx: integer);
    function PendingIndexByFd(AFd: cint): integer;
    procedure DropPending(AIdx: integer; AClose: boolean = True);
    function NewConnectionGeneration: QWord;
    function CanQueueCommand(ASize: integer): boolean;
    function QueueCommand(AOrigin: TCommandOrigin; ASlot: integer;
      AGeneration: QWord; AKind: byte; APane: integer;
      const AData: TByteArray; APeerClose: boolean = False): boolean;
    function PopCommand(out ACommand: TQueuedCommand): boolean;
    procedure DrainCommandQueue;
    function QueueOut(AIdx: integer; const Buffer; ASize: integer;
      ASnapshot: boolean = False): boolean;
    function QueuePending(AIdx: integer; AKind: byte; APane: integer;
      const Data: TByteArray): boolean;
    function SendFrameToIdx(AIdx: integer; AKind: byte; APane: integer;
      const Buffer; ASize: integer): boolean;
    function SendSnapshot(AIdx: integer): boolean;
    procedure Broadcast(AKind: byte; APane: integer; const Buffer;
      ASize: integer; ANeedCaps: boolean; AExcept: integer);
    procedure FlushClient(AIdx: integer);
    procedure FlushPending(AIdx: integer);
    procedure ApplyCanonicalResize(APane, ACols, ARows: integer;
      ANotify: boolean = True; AWorkersStopped: boolean = False);
    procedure NormalizeFocusedPane;
    function TryLockLayout(AOwner, APane: integer;
      ABroadcast: boolean = True): boolean;
    procedure ReleaseLayout(AOwner, APane: integer;
      ABroadcast: boolean = True);
    function ClientOwnsAnyLayout(AOwner: integer): boolean;
    function OwnsAllLayout(AOwner: integer): boolean;
    function BuildLayoutBlob(AViewer: integer; out AData: TByteArray;
      APreservePanes: LongWord = 0): boolean;
    procedure BroadcastLayoutEv(AExcept: integer);
    procedure BroadcastTitle(APane: integer; AExcept: integer = -1);
    function DoNewPane(AOwner, AAt: integer; ADir: byte;
      const AClass, ACmd, ACwd, ATitle: string; out ANewIdx: integer;
      out AErr: string): boolean;
    procedure HandlePendingFrame(AIdx: integer; AKind: byte;
      APane: integer; const AData: TByteArray);
    procedure HandleControlFrame(AFd: cint; AKind: byte; APane: integer;
      const AData: TByteArray);
    procedure CtlReplyErr(AFd: cint; const AMsg: string);
    procedure CtlReplyOk(AFd: cint; const AMsg: string);
    procedure EnsureCtlConfig;
    procedure HandleWinOp(AFd: cint; APane: integer;
      const AData: TByteArray);
    function SpawnPaneForSpec(const AClass, ACmd, ACwd: string;
      var ACols, ARows: integer; out APty: TPty; out ATerm: string;
      out ADefTitle: string): boolean;
    function SpawnInitialPanes: boolean;
    procedure TrackRetiredChild(APid: TPid);
    procedure ReapChildren;
    function HandleAttach(APendingIdx: integer; AFirstKind: byte;
      const AFirstData: TByteArray): boolean;
    procedure HandleClientFrame(AIdx: integer; AKind: byte;
      APane: integer; const AData: TByteArray);
    function ReadPaneEvent(APane: integer; out AKind: byte;
      out AData: TByteArray): boolean;
    procedure HandlePaneOutput(APane: integer);
    function QueueWorkerResult(AKind: byte; APane: integer;
      const AData: TByteArray): boolean;
    procedure DrainWorkerResults;
    function WantedWorkerCount: integer;
    procedure StartPaneWorkers;
    procedure StopPaneWorkers;
    procedure CheckPaneWorkers;
    procedure LockPane(APane: integer);
    procedure UnlockPane(APane: integer);
    procedure SignalReady(var AFd: cint; AOk: boolean);
    procedure WriteSidecar;
    function ClientChainsUnion: string;
    procedure DoKillPane(APane: integer);
    procedure DoKillAllPanes;
    function ApplyLayoutFrame(AClient: integer; const Data: TByteArray;
      AAllowStale: boolean; out ABaseRevision: QWord;
      out AChanges: LongWord): boolean;
  public
    constructor Create(const AName, AProfile: string; ALay: TLayout;
      const APanes: TPtyArray; const AScreens: TScreenArray;
      const ATitles: TStrArray; const ATerms: TStrArray;
      AFocused: integer; const AGeom: TPaneGeomArray;
      ADeskW, ADeskH: integer; const ATitleFixed: TBoolArray);
    destructor Destroy; override;
    function PrepareListener: boolean;
    procedure AdoptPanes;
    procedure Run(var AReadyFd: cint);
  end;

function PollFd(AFd: cint; AEvents: cshort; ATimeoutMs: integer): cint;
var
  P: TPollFD;
begin
  if AFd < 0 then
    Exit(-1);
  P := Default(TPollFD);
  P.fd := AFD;
  P.events := AEvents;
  Result := fpPoll(@P, 1, ATimeoutMs);
  if (Result > 0) and
     ((P.revents and (AEvents or POLLERR or POLLHUP or POLLNVAL)) = 0) then
    Result := 0;
end;

function AttachIoWaitPolls: integer;
var
  S: string;
  V: integer;
begin
  Result := ATTACH_IO_WAIT_POLLS;
  // Fault-injection tests need a short deterministic bound.  The override is
  // inert unless the explicit test guard is present and cannot weaken a real
  // installation accidentally.
  if GetEnvironmentVariable('SUPERTERM_TESTING') <> '1' then
    Exit;
  S := GetEnvironmentVariable('SUPERTERM_TEST_ATTACH_POLLS');
  if TryStrToInt(S, V) and (V >= 1) and (V <= ATTACH_IO_WAIT_POLLS) then
    Result := V;
end;

function AttachIoPollMs: integer;
{$ifdef SUPERTERM_TEST_BUILD}
var
  S: string;
  V: integer;
{$endif}
begin
  Result := ATTACH_IO_POLL_MS;
  {$ifdef SUPERTERM_TEST_BUILD}
  // A wider test quantum makes the progress/deadline integration independent
  // of virtualized-host scheduling resolution. Release binaries do not
  // contain this override; the runtime guard is an additional test boundary.
  if GetEnvironmentVariable('SUPERTERM_TESTING') <> '1' then
    Exit;
  S := GetEnvironmentVariable('SUPERTERM_TEST_ATTACH_POLL_MS');
  if TryStrToInt(S, V) and (V >= 1) and (V <= 1000) then
    Result := V;
  {$endif}
end;

function NewWaitDeadline(APolls, APollMs: integer): TWaitDeadline;
var
  NowTick, Span: QWord;
begin
  Result := Default(TWaitDeadline);
  if (APolls <= 0) or (APollMs <= 0) then
    Exit;
  NowTick := GetTickCount64;
  Span := QWord(APolls) * QWord(APollMs);
  Result.PollMs := APollMs;
  Result.LastTick := NowTick;
  if Span > High(QWord) - NowTick then
    Result.ExpiresAt := High(QWord)
  else
    Result.ExpiresAt := NowTick + Span;
end;

function DeadlinePollMs(var ADeadline: TWaitDeadline): integer;
var
  NowTick, Remaining: QWord;
begin
  Result := 0;
  if (ADeadline.ExpiresAt = 0) or (ADeadline.PollMs <= 0) then
    Exit;
  NowTick := GetTickCount64;
  // A backwards wall-clock jump on Darwin must never extend a security
  // boundary. A forward jump naturally reaches the deadline early.
  if NowTick < ADeadline.LastTick then
  begin
    ADeadline.ExpiresAt := 0;
    Exit;
  end;
  if NowTick >= ADeadline.ExpiresAt then
  begin
    {$ifdef SUPERTERM_TEST_BUILD}
    ADeadline.Reached := True;
    {$endif}
    ADeadline.ExpiresAt := 0;
    Exit;
  end;
  ADeadline.LastTick := NowTick;
  Remaining := ADeadline.ExpiresAt - NowTick;
  if Remaining > QWord(ADeadline.PollMs) then
    Result := ADeadline.PollMs
  else
    Result := integer(Remaining);
end;

function WaitSocketReady(AFd: cint; AEvents: cshort;
  var ADeadline: TWaitDeadline): boolean;
var
  P: TPollFD;
  N, E, PollMs: cint;
begin
  Result := False;
  while True do
  begin
    PollMs := DeadlinePollMs(ADeadline);
    if PollMs <= 0 then
      Exit;
    P := Default(TPollFD);
    P.fd := AFD;
    P.events := AEvents;
    N := fpPoll(@P, 1, PollMs);
    // errno belongs to the failing syscall. Capture it before the clock query
    // below (or any future diagnostic) can execute another libc operation.
    if N < 0 then
      E := FpGetErrNo
    else
      E := 0;
    // The deadline is total, not an inactivity timer. This accepts hundreds
    // of immediate Darwin readiness cycles for a large snapshot, yet a peer
    // dripping one byte per poll can never keep the caller here indefinitely.
    if DeadlinePollMs(ADeadline) <= 0 then
      Exit;
    if N > 0 then
    begin
      {$ifdef SUPERTERM_TEST_BUILD}
      Inc(ADeadline.ReadyCount);
      {$endif}
      if (P.revents and POLLNVAL) <> 0 then
        Exit;
      // POLLHUP/POLLERR are returned as ready deliberately: the following
      // send/recv obtains the definitive EOF or socket error without another
      // wait.  POLLIN/POLLOUT are the ordinary progress path.
      Exit((P.revents and (AEvents or POLLHUP or POLLERR)) <> 0);
    end;
    if N = 0 then
      Continue;
    if E <> ESysEINTR then
      Exit;
  end;
end;

function WriteFullTimed(AFd: cint; const Buffer; ASize: integer;
  var ADeadline: TWaitDeadline): boolean;
var
  P: PByte;
  Left, N, E: integer;
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
    if DeadlinePollMs(ADeadline) <= 0 then
      Exit;
    N := fpSend(AFd, P, Left, ST_MSG_DONTWAIT);
    if N > 0 then
    begin
      Inc(P, N);
      Dec(Left, N);
      Continue;
    end;
    if N = 0 then
      Exit;
    E := FpGetErrNo;
    if E = ESysEINTR then
      Continue;
    if (E <> ESysEAGAIN) and (E <> ESysEWOULDBLOCK) then
      Exit;
    if not WaitSocketReady(AFd, POLLOUT, ADeadline) then
      Exit;
  end;
  Result := True;
end;

function ReadFullTimed(AFd: cint; var Buffer; ASize: integer;
  var ADeadline: TWaitDeadline): boolean;
var
  P: PByte;
  Left, N, E: integer;
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
    if DeadlinePollMs(ADeadline) <= 0 then
      Exit;
    N := fpRecv(AFd, P, Left, ST_MSG_DONTWAIT);
    if N > 0 then
    begin
      Inc(P, N);
      Dec(Left, N);
      Continue;
    end;
    if N = 0 then
      Exit;
    E := FpGetErrNo;
    if E = ESysEINTR then
      Continue;
    if (E <> ESysEAGAIN) and (E <> ESysEWOULDBLOCK) then
      Exit;
    if not WaitSocketReady(AFd, POLLIN, ADeadline) then
      Exit;
  end;
  Result := True;
end;

// close-on-exec on a descriptor the daemon owns. Without it every socket --
// the listener and every attached client -- is inherited by every pane the
// daemon spawns, so killing the daemon leaves its listening socket alive in
// a shell and the session looks live when it is not. F_SETFD/FD_CLOEXEC are
// not exported by the GNU/Linux RTL; the numeric form is what st_pty uses.
procedure SetCloExec(AFd: cint);
begin
  if AFd >= 0 then
    FpFcntl(AFd, 2 {F_SETFD}, 1 {FD_CLOEXEC});
end;

procedure SetNonBlocking(AFd: cint);
var
  Flags: cint;
begin
  if AFD < 0 then
    Exit;
  Flags := FpFcntl(AFd, F_GETFL, 0);
  if Flags >= 0 then
    FpFcntl(AFd, F_SETFL, Flags or O_NONBLOCK);
end;

// FPC declares fpRead/fpWrite with untyped buffers and marks them inline; in
// generic helper call sites 3.2.2 reports a compiler implementation note even
// though there is nothing actionable in the project. Keep that noise inside
// these two small wrappers so normal builds remain warning/note clean.
{$push}{$notes off}{$hints off}
function PipeWriteByte(AFd: cint; AValue: byte): boolean;
begin
  Result := (AFd >= 0) and (FpWrite(AFd, AValue, SizeOf(AValue)) > 0);
end;

procedure DrainPipe(AFd: cint);
var
  Buf: array[0..255] of byte;
begin
  FillChar(Buf, SizeOf(Buf), 0);
  if AFd < 0 then
    Exit;
  while FpRead(AFd, Buf, SizeOf(Buf)) > 0 do ;
end;
{$pop}

// Consume only what is immediately available. A short header or payload is
// retained in ABuffer and completed by a later poll notification; no peer can
// park the daemon by sending the first byte of a frame and then going silent.
procedure CompactInputBuffer(var ABuffer: RawByteString; var AInPos: integer);
begin
  if AInPos <= 0 then
    Exit;
  if AInPos >= Length(ABuffer) then
  begin
    ABuffer := '';
    AInPos := 0;
  end
  else if (AInPos >= INPUT_COMPACT_THRESHOLD) and
          (AInPos >= Length(ABuffer) div 2) then
  begin
    // One occasional move replaces Delete-on-every-frame, which was O(n^2)
    // for a socket read containing a large burst of small input frames.
    Delete(ABuffer, 1, AInPos);
    AInPos := 0;
  end;
end;

function ReadSocketAvailable(AFd: cint; var ABuffer: RawByteString;
  var AInPos: integer; out AClosed: boolean): boolean;
var
  Buf: array[0..65535] of byte;
  N, Total, OldLen, Want: integer;
begin
  Result := True;
  AClosed := False;
  Total := 0;
  CompactInputBuffer(ABuffer, AInPos);
  repeat
    Want := SizeOf(Buf);
    if Total + Want > IO_BUDGET then
      Want := IO_BUDGET - Total;
    if Want <= 0 then
      Exit;
    N := FpRecv(AFd, @Buf[0], Want, ST_MSG_DONTWAIT);
    if N > 0 then
    begin
      OldLen := Length(ABuffer);
      SetLength(ABuffer, OldLen + N);
      Move(Buf[0], ABuffer[OldLen + 1], N);
      Inc(Total, N);
      Continue;
    end;
    if N = 0 then
    begin
      AClosed := True;
      Exit;
    end;
    case fpgeterrno of
      ESysEINTR: Continue;
      ESysEAGAIN: Exit;
    else
      Result := False;
      AClosed := True;
      Exit;
    end;
  until False;
end;

function PeekBufferedFrame(const ABuffer: RawByteString; AInPos: integer;
  out AKind: byte; out APane: integer; out ASize: LongWord): TFramePop;
var
  H: TFrameHeader;
  Available, Need: QWord;
begin
  AKind := 0;
  APane := -1;
  ASize := 0;
  if (AInPos < 0) or (AInPos > Length(ABuffer)) then
    Exit(fpInvalid);
  Available := QWord(Length(ABuffer) - AInPos);
  if Available < SizeOf(H) then
    Exit(fpNeedMore);
  H := Default(TFrameHeader);
  Move(ABuffer[AInPos + 1], H, SizeOf(H));
  if H.Size > MAX_FRAME_SIZE then
    Exit(fpInvalid);
  Need := QWord(SizeOf(H)) + QWord(H.Size);
  if Available < Need then
    Exit(fpNeedMore);
  AKind := H.Kind;
  APane := H.Pane;
  ASize := H.Size;
  Result := fpReady;
end;

function PopBufferedFrame(var ABuffer: RawByteString; var AInPos: integer;
  out AKind: byte; out APane: integer; out AData: TByteArray): TFramePop;
var
  PayloadSize: LongWord;
  Need: integer;
begin
  AData := nil;
  Result := PeekBufferedFrame(ABuffer, AInPos, AKind, APane, PayloadSize);
  if Result <> fpReady then
    Exit;
  Need := SizeOf(TFrameHeader) + integer(PayloadSize);
  SetLength(AData, PayloadSize);
  if PayloadSize > 0 then
    Move(ABuffer[AInPos + 1 + SizeOf(TFrameHeader)], AData[0], PayloadSize);
  Inc(AInPos, Need);
  CompactInputBuffer(ABuffer, AInPos);
  Result := fpReady;
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
  if Stream.Position + SizeOf(L) > Stream.Size then
    Exit;
  L := Default(Longint);
  Stream.ReadBuffer(L, SizeOf(L));
  if (L < 0) or (L > MAX_WIRE_STRING_SIZE) or
     (Stream.Position + L > Stream.Size) then
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

function WriteFrameToTimed(AFd: cint; AKind: byte; APane: integer;
  const Data: TByteArray; var ADeadline: TWaitDeadline): boolean;
var
  H: TFrameHeader;
begin
  if Length(Data) > MAX_FRAME_SIZE then
    Exit(False);
  H := Default(TFrameHeader);
  H.Kind := AKind;
  H.Pane := APane;
  H.Size := Length(Data);
  Result := WriteFullTimed(AFd, H, SizeOf(H), ADeadline);
  if Result and (Length(Data) > 0) then
    Result := WriteFullTimed(AFd, Data[0], Length(Data), ADeadline);
end;

function ReadFrameFromTimed(AFd: cint; out AKind: byte; out APane: integer;
  out Data: TByteArray; var ADeadline: TWaitDeadline): boolean;
var
  H: TFrameHeader;
begin
  Result := False;
  AKind := 0;
  APane := -1;
  Data := nil;
  H := Default(TFrameHeader);
  if not ReadFullTimed(AFd, H, SizeOf(H), ADeadline) then
    Exit;
  if H.Size > MAX_FRAME_SIZE then
    Exit;
  AKind := H.Kind;
  APane := H.Pane;
  SetLength(Data, H.Size);
  if (H.Size > 0) and
     (not ReadFullTimed(AFd, Data[0], H.Size, ADeadline)) then
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
  Flags, N, E, SocketError: cint;
  ErrorLen: TSockLen;
  Deadline: TWaitDeadline;
begin
  Result := -1;
  if not SocketAddress(APath, Addr, AddrLen) then
    Exit;
  Result := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if Result < 0 then
    Exit;
  SetCloExec(Result);
  Flags := FpFcntl(Result, F_GETFL, 0);
  if (Flags < 0) or
     (FpFcntl(Result, F_SETFL, Flags or O_NONBLOCK) < 0) then
  begin
    FpClose(Result);
    Result := -1;
    Exit;
  end;
  N := fpConnect(Result, @Addr, AddrLen);
  if N <> 0 then
  begin
    E := FpGetErrNo;
    if (E <> ESysEINPROGRESS) and (E <> ESysEINTR) then
    begin
      FpClose(Result);
      Result := -1;
      Exit;
    end;
    Deadline := NewWaitDeadline(CONNECT_WAIT_POLLS, AttachIoPollMs);
    if not WaitSocketReady(Result, POLLOUT, Deadline) then
    begin
      FpClose(Result);
      Result := -1;
      Exit;
    end;
    SocketError := 0;
    ErrorLen := SizeOf(SocketError);
    if (fpGetSockOpt(Result, SOL_SOCKET, SO_ERROR, @SocketError,
       @ErrorLen) <> 0) or (SocketError <> 0) then
    begin
      FpClose(Result);
      Result := -1;
      Exit;
    end;
  end;
  if FpFcntl(Result, F_SETFL, Flags) < 0 then
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
          if PollFd(Fd, POLLOUT, 300) <= 0 then
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

// Session names are a process-wide creation namespace. Keep exactly one
// descriptor per process: traditional POSIX record locks are process-owned,
// and closing *any* descriptor for the inode can release every lock that
// process holds on it. The SSH entry may already own this descriptor while
// it constructs the first profile, so StartDetachedServer reuses it.
function TryHoldSessionNameLock(const AName: string): TSessionNameLockResult;
var
  Region: flock;
  LockPath: string;
  St: Stat;
  ErrNo: cint;
begin
  if HeldSessionNameLockFD >= 0 then
  begin
    if HeldSessionNameLockName = SanitizeSessionName(AName) then
      Exit(snlAcquired)
    else
      Exit(snlError);
  end;
  Result := snlError;
  LockPath := SessionsDir + '/.create-' + SanitizeSessionName(AName) + '.lock';
  // Open_NoFollow closes the final-component symlink race. The parent sessions
  // directory is private (0700); fstat still validates an existing inode so
  // a FIFO/device or same-UID group-writable file can never become a lock.
  HeldSessionNameLockFD := FpOpen(PAnsiChar(LockPath),
    O_RDWR or O_CREAT or Open_NoFollow, &600);
  if HeldSessionNameLockFD < 0 then
    Exit;
  St := Default(Stat);
  if (FpFStat(HeldSessionNameLockFD, St) <> 0) or
     (not FpS_ISREG(St.st_mode)) or (St.st_uid <> FpGetEUid) or
     ((St.st_mode and (S_IWGRP or S_IWOTH)) <> 0) or
     (FpFcntl(HeldSessionNameLockFD,
       2 {F_SETFD}, 1 {FD_CLOEXEC}) <> 0) then
  begin
    FpClose(HeldSessionNameLockFD);
    HeldSessionNameLockFD := -1;
    Exit;
  end;
  Region := Default(flock);
  Region.l_type := SESSION_F_WRLCK;
  Region.l_whence := SEEK_SET;
  Region.l_start := 0;
  Region.l_len := 0;
  repeat
    if FpFcntl(HeldSessionNameLockFD, F_SETLK, Region) = 0 then
    begin
      HeldSessionNameLockName := SanitizeSessionName(AName);
      Exit(snlAcquired);
    end;
    ErrNo := FpGetErrNo;
  until ErrNo <> ESysEINTR;
  FpClose(HeldSessionNameLockFD);
  HeldSessionNameLockFD := -1;
  if (ErrNo = ESysEACCES) or (ErrNo = ESysEAGAIN) then
    Result := snlBusy;
end;

procedure ReleaseHeldSessionNameLock;
begin
  if HeldSessionNameLockFD >= 0 then
    FpClose(HeldSessionNameLockFD);
  HeldSessionNameLockFD := -1;
  HeldSessionNameLockName := '';
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

function NestingGuardActive: boolean;
begin
  Result := (GetEnvironmentVariable('SUPERTERM') <> '') and
            (GetEnvironmentVariable('SUPERTERM_ALLOW_NESTED') = '');
end;

function SessionAllowedFromHere(const AInfo: TSessionInfo;
  const AAll: TSessionInfoArray): boolean;
var
  Reach: string;     // ':'-delimited set of session ids
  Grew: boolean;
  i: integer;

  function Has(const ASet, AId: string): boolean;
  begin
    Result := (AId <> '') and (Pos(':' + AId + ':', ASet) > 0);
  end;

  procedure AddAll(var ASet: string; const AList: string);
  var
    Rest, Item: string;
    P: integer;
  begin
    Rest := AList;
    while Rest <> '' do
    begin
      P := Pos(':', Rest);
      if P = 0 then P := Length(Rest) + 1;
      Item := Copy(Rest, 1, P - 1);
      Delete(Rest, 1, P);
      if (Item <> '') and (not Has(ASet, Item)) then
      begin
        ASet := ASet + Item + ':';
        Grew := True;
      end;
    end;
  end;

begin
  if not NestingGuardActive then
    Exit(True);
  if AInfo.Id = '' then
    Exit(False);               // identity unknown: cannot prove it is safe
  // Start from the sessions this pane lives inside of. A session on that
  // set may itself be displayed inside OTHER sessions -- it has a client
  // running in one of their panes -- and those are reachable too: attaching
  // to any of them from here closes a loop. Follow the sidecars until the
  // set stops growing, then refuse the target if it is in it.
  Reach := ':';
  Grew := False;
  AddAll(Reach, GetEnvironmentVariable('SUPERTERM_SESSION_CHAIN'));
  repeat
    Grew := False;
    for i := 0 to High(AAll) do
      if Has(Reach, AAll[i].Id) then
        AddAll(Reach, AAll[i].ClientChains);
  until not Grew;
  Result := not Has(Reach, AInfo.Id);
end;

procedure KeepAllowedSessions(var AInfos: TSessionInfoArray);
var
  i, n: integer;
  All: TSessionInfoArray;
begin
  All := Copy(AInfos);
  n := 0;
  for i := 0 to High(AInfos) do
    if SessionAllowedFromHere(AInfos[i], All) then
    begin
      AInfos[n] := AInfos[i];
      Inc(n);
    end;
  SetLength(AInfos, n);
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
        Ini := nil;
        try
          try
            Ini := TIniFile.Create(MetaPath);
            Info.Name := Ini.ReadString('session', 'name', Info.Name);
            Info.Profile := Ini.ReadString('session', 'profile', '');
            Info.PaneCount := Ini.ReadInteger('session', 'panes', 0);
            Info.Pid := Ini.ReadInteger('session', 'pid', 0);
            Info.Created := Ini.ReadString('session', 'created', '');
            Info.Id := Ini.ReadString('session', 'id', '');
            Info.ClientChains := Ini.ReadString('session', 'client_chains', '');
          except
            on E: Exception do
              // Discovery metadata is optional. The live socket and its
              // basename are enough to resolve the session and query the
              // daemon; a transient filesystem/share error must never crash
              // a CLI command or hide that live session.
              try
                if DebugActive then
                  DebugLog('session sidecar read failed: ' + E.ClassName +
                    ': ' + E.Message);
              except
              end;
          end;
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
  Deadline: TWaitDeadline;
  Probe: TSocketProbe;
  St: Stat;
begin
  Result := False;
  Fd := ConnectSocket(APath);
  if Fd < 0 then
    Exit;
  Data := nil;
  Deadline := NewWaitDeadline(AttachIoWaitPolls, AttachIoPollMs);
  if not WriteFrameToTimed(Fd, FRAME_CLOSE, -1, Data, Deadline) then
  begin
    FpClose(Fd);
    Exit;
  end;
  FpClose(Fd);
  // honest boolean: True only when the daemon really stops responding
  // (an old daemon ignores the FRAME_CLOSE and stays alive)
  for I := 1 to 20 do
  begin
    Probe := ProbeSocket(APath);
    St := Default(Stat);
    if (Probe = spDead) and (FpLStat(RawByteString(APath), St) <> 0) and
       (FpGetErrNo = ESysENOENT) then
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
  Deadline: TWaitDeadline;
begin
  Result := False;
  AReply := '';
  Fd := ConnectSocket(ASocket);
  if Fd < 0 then
    Exit;
  try
    Deadline := NewWaitDeadline(AttachIoWaitPolls, AttachIoPollMs);
    if not WriteFrameToTimed(Fd, AKind, APane, APayload,
       Deadline) then
      Exit;
    if not ReadFrameFromTimed(Fd, RKind, RPane, RData,
       Deadline) then
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
  Deadline: TWaitDeadline;
begin
  Result := False;
  Fd := ConnectSocket(ASocket);
  if Fd < 0 then
    Exit;
  try
    Deadline := NewWaitDeadline(AttachIoWaitPolls, AttachIoPollMs);
    if not WriteFrameToTimed(Fd, AKind, APane, APayload,
       Deadline) then
      Exit;
    repeat
      if not ReadFrameFromTimed(Fd, RKind, RPane, RData,
         Deadline) then
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
  out ADeskW, ADeskH: Longint; out ARevision: QWord;
  out AClientCount: Longint; out AChangeMask, ALockedPanes: LongWord;
  out AMinHostW, AMinHostH: Longint; out AHostSizesMatch: boolean): boolean;
var
  Stream: TMemoryStream;
  Cnt, I, MatchFlag: Longint;
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
  ARevision := 0;
  AClientCount := 0;
  AChangeMask := 0;
  ALockedPanes := 0;
  AMinHostW := 0;
  AMinHostH := 0;
  AHostSizesMatch := False;
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
    if (Cnt < 0) or (Cnt > MAX_PANES) or
       (AFocused < -1) or (AFocused >= Cnt) then
      Exit;
    SetLength(ATitles, Cnt);
    for I := 0 to Cnt - 1 do
    begin
      if not ReadTailString(Stream, T) then
        Exit;
      ATitles[I] := T;
    end;
    if Stream.Position + 2 * SizeOf(Longint) +
       Cnt * (6 * SizeOf(Longint) + 3) + SizeOf(QWord) +
       SizeOf(Longint) > Stream.Size then
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
      Stream.ReadBuffer(AGeom[I].Cols, SizeOf(Longint));
      Stream.ReadBuffer(AGeom[I].Rows, SizeOf(Longint));
      Flag := Default(byte);
      Stream.ReadBuffer(Flag, SizeOf(Flag));
      AGeom[I].Zoomed := Flag <> 0;
      Stream.ReadBuffer(Flag, SizeOf(Flag));
      AGeom[I].Minimized := Flag <> 0;
      Stream.ReadBuffer(Flag, SizeOf(Flag));
      AGeom[I].FullScreen := Flag <> 0;
    end;
    Stream.ReadBuffer(ARevision, SizeOf(ARevision));
    Stream.ReadBuffer(AClientCount, SizeOf(AClientCount));
    if Stream.Position + SizeOf(AChangeMask) <= Stream.Size then
      Stream.ReadBuffer(AChangeMask, SizeOf(AChangeMask));
    if Stream.Position + SizeOf(ALockedPanes) <= Stream.Size then
      Stream.ReadBuffer(ALockedPanes, SizeOf(ALockedPanes));
    if Stream.Position + 3 * SizeOf(Longint) <= Stream.Size then
    begin
      Stream.ReadBuffer(AMinHostW, SizeOf(AMinHostW));
      Stream.ReadBuffer(AMinHostH, SizeOf(AMinHostH));
      MatchFlag := 0;
      Stream.ReadBuffer(MatchFlag, SizeOf(MatchFlag));
      AHostSizesMatch := MatchFlag <> 0;
    end;
    Result := True;
  finally
    Stream.Free;
  end;
end;

function DecodeHostSummaryBlob(const Data: TByteArray; out AClientCount,
  AMinHostW, AMinHostH: Longint; out AHostSizesMatch: boolean): boolean;
var
  Values: array[0..3] of Longint;
begin
  Result := False;
  AClientCount := 0;
  AMinHostW := 0;
  AMinHostH := 0;
  AHostSizesMatch := False;
  if Length(Data) <> SizeOf(Values) then
    Exit;
  Values[0] := 0;
  Values[1] := 0;
  Values[2] := 0;
  Values[3] := 0;
  Move(Data[0], Values, SizeOf(Values));
  if (Values[0] < 1) or (Values[0] > MAX_CLIENTS) or
     (Values[1] < 1) or (Values[1] > MAX_SCREEN_COLS) or
     (Values[2] < 3) or (Values[2] > MAX_SCREEN_ROWS) or
     ((Values[3] <> 0) and (Values[3] <> 1)) then
    Exit;
  AClientCount := Values[0];
  AMinHostW := Values[1];
  AMinHostH := Values[2];
  AHostSizesMatch := Values[3] <> 0;
  Result := True;
end;

function DecodeLayoutPreviewBlob(const Data: TByteArray;
  out APreview: TLayoutPreview): boolean;
begin
  APreview := Default(TLayoutPreview);
  Result := (SizeOf(TLayoutPreview) = LAYOUT_PREVIEW_PAYLOAD_SIZE) and
    (Length(Data) = LAYOUT_PREVIEW_PAYLOAD_SIZE);
  if not Result then
    Exit;
  Move(Data[0], APreview, SizeOf(APreview));
  Result := (APreview.GestureId <> 0) and (APreview.Seq <> 0) and
    (APreview.Reserved[0] = 0) and (APreview.Reserved[1] = 0) and
    (APreview.Reserved[2] = 0) and
    (APreview.Op in [PREVIEW_OP_BOUNDS, PREVIEW_OP_WIREFRAME,
      PREVIEW_OP_OUTLINE_SHOW, PREVIEW_OP_OUTLINE_HIDE,
      PREVIEW_OP_TAIL_BEGIN, PREVIEW_OP_TAIL_END, PREVIEW_OP_CLEAR]);
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
  Base, Suffix: string;
  N: integer;
begin
  Base := SanitizeSessionName(ABase);
  Result := Base;
  N := 1;
  while SessionIsLive(SessionSocketPathFor(Result)) do
  begin
    Inc(N);
    Suffix := '-' + IntToStr(N);
    // SanitizeSessionName truncates at 64. Appending to an already 64-byte
    // base and sanitizing later would therefore probe the same name forever.
    Result := Copy(Base, 1, 64 - Length(Suffix)) + Suffix;
  end;
end;

constructor TSessionClient.Create;
begin
  inherited Create;
  FSocket := -1;
  FConnected := False;
  FLayoutRevision := 0;
  FClientCount := 0;
  FLockedPanes := 0;
  FMinHostW := 0;
  FMinHostH := 0;
  FHostSizesMatch := False;
  FHostSummaryValid := False;
  FInBuf := '';
  FInPos := 0;
  FOutBuf := '';
  FOutPos := 0;
  FPeerClosed := False;
  FNextLayoutLockRequest := 0;
  FNextPreviewId := 0;
  FLastPreviewId := 0;
  FLastPreviewTick := 0;
  FQueuedEvents := nil;
  FQueuedEventHead := 0;
end;

procedure TSessionClient.CloseSocket;
begin
  if FSocket >= 0 then
    FpClose(FSocket);
  FSocket := -1;
  FConnected := False;
  FInBuf := '';
  FInPos := 0;
  FOutBuf := '';
  FOutPos := 0;
  FPeerClosed := False;
  FLastPreviewId := 0;
  FLastPreviewTick := 0;
end;

destructor TSessionClient.Destroy;
begin
  CloseSocket;
  inherited Destroy;
end;

function TSessionClient.SendFrame(AKind: byte; APane: integer;
  const Data: TByteArray): boolean;
var
  H: TFrameHeader;
  AddLen, OldLen, Pending: integer;
begin
  Result := False;
  if (not FConnected) or (Length(Data) > MAX_FRAME_SIZE) then
    Exit;
  // First consume whatever the kernel accepts now. GNU/Linux keeps the
  // historical blocking descriptor and uses MSG_DONTWAIT for this call;
  // Darwin also marks the interactive descriptor O_NONBLOCK after READY.
  if not FlushOutgoing then
    Exit;
  AddLen := SizeOf(H) + Length(Data);
  Pending := Length(FOutBuf) - FOutPos;
  if (AddLen > CLIENT_EGRESS_LIMIT) or
     (Pending > CLIENT_EGRESS_LIMIT - AddLen) then
    Exit;
  // Retain a consumed prefix while capacity remains.  Compact only before an
  // append would take the allocation past its hard cap, keeping a slow-peer
  // stream linear instead of moving the whole queue after every short send.
  if (FOutPos > 0) and
     (Length(FOutBuf) > CLIENT_EGRESS_LIMIT - AddLen) then
  begin
    Delete(FOutBuf, 1, FOutPos);
    FOutPos := 0;
  end;
  H := Default(TFrameHeader);
  H.Kind := AKind;
  H.Pane := SmallInt(APane);
  H.Size := Length(Data);
  OldLen := Length(FOutBuf);
  SetLength(FOutBuf, OldLen + AddLen);
  Move(H, FOutBuf[OldLen + 1], SizeOf(H));
  if Length(Data) > 0 then
    Move(Data[0], FOutBuf[OldLen + 1 + SizeOf(H)], Length(Data));
  // A successful return means the complete frame was accepted into the
  // bounded FIFO; it need not already have reached a deliberately stalled
  // daemon. Fatal socket errors still fail and disconnect immediately.
  Result := FlushOutgoing;
end;

function TSessionClient.OutputPending: boolean;
begin
  Result := FOutPos < Length(FOutBuf);
end;

function TSessionClient.FlushOutgoing: boolean;
var
  N: ssize_t;
  E, Pending, Want, Total: integer;
begin
  Result := False;
  if not FConnected or (FSocket < 0) then
    Exit;
  Total := 0;
  while OutputPending and (Total < IO_BUDGET) do
  begin
    Pending := Length(FOutBuf) - FOutPos;
    Want := Pending;
    if Want > IO_BUDGET - Total then
      Want := IO_BUDGET - Total;
    N := FpSend(FSocket, PAnsiChar(FOutBuf) + FOutPos, Want,
      ST_MSG_DONTWAIT);
    if N > 0 then
    begin
      Inc(FOutPos, integer(N));
      Inc(Total, integer(N));
      Continue;
    end;
    if N = 0 then
    begin
      CloseSocket;
      Exit;
    end;
    E := FpGetErrNo;
    if E = ESysEINTR then
      Continue;
    if (E = ESysEAGAIN) or (E = ESysEWOULDBLOCK) then
      Break;
    CloseSocket;
    Exit;
  end;
  if not OutputPending then
  begin
    FOutBuf := '';
    FOutPos := 0;
  end;
  Result := FConnected;
end;

function TSessionClient.FlushOutgoingBounded(AWaitPolls: integer): boolean;
var
  Deadline: TWaitDeadline;
begin
  Deadline := NewWaitDeadline(AWaitPolls, CLIENT_CLOSE_POLL_MS);
  Result := FlushOutgoing;
  while Result and OutputPending do
  begin
    if not WaitSocketReady(FSocket, POLLOUT, Deadline) then
      Exit(False);
    Result := FlushOutgoing;
  end;
end;

function TSessionClient.ReadFrame(out AKind: byte; out APane: integer;
  out Data: TByteArray): boolean;
begin
  Result := FConnected and ReadFrameFrom(FSocket, AKind, APane, Data);
end;

function TSessionClient.DecodeEvent(AKind: byte; APane: integer;
  const AData: TByteArray; out AEvent: TSessionEvent): boolean;
var
  Preview: TLayoutPreview;
begin
  AEvent := Default(TSessionEvent);
  AEvent.Kind := sekIgnore;
  AEvent.Pane := APane;
  AEvent.Data := Copy(AData, 0, Length(AData));
  case AKind of
    FRAME_OUTPUT: AEvent.Kind := sekOutput;
    FRAME_EXIT: AEvent.Kind := sekExit;
    FRAME_ERROR:
      begin
        AEvent.Kind := sekError;
        if Length(AData) > 0 then
          SetString(AEvent.Text, PAnsiChar(@AData[0]), Length(AData));
      end;
    FRAME_LAYOUT_EV: AEvent.Kind := sekLayoutEv;
    FRAME_LAYOUT_PEER_EV: AEvent.Kind := sekLayoutPeerEv;
    FRAME_KILLPANE_EV: AEvent.Kind := sekKillPaneEv;
    FRAME_NEWPANE_EV: AEvent.Kind := sekNewPaneEv;
    FRAME_RESIZE_EV: AEvent.Kind := sekResizeEv;
    FRAME_TITLE_EV: AEvent.Kind := sekTitleEv;
    FRAME_FOCUS_EV: AEvent.Kind := sekFocusEv;
    FRAME_HOST_SUMMARY_EV:
      if DecodeHostSummaryBlob(AData, FClientCount, FMinHostW, FMinHostH,
        FHostSizesMatch) then
      begin
        FHostSummaryValid := True;
        AEvent.Kind := sekHostSummaryEv;
      end;
    FRAME_LAYOUT_PREVIEW_EV:
      begin
        // Keep the packed payload in Data; the UI can decode/coalesce several
        // previews in one Idle batch without translating managed objects.
        if DecodeLayoutPreviewBlob(AData, Preview) then
          AEvent.Kind := sekLayoutPreviewEv;
      end;
    FRAME_SHUTDOWN_EV: AEvent.Kind := sekShutdown;
  else
    // Lock replies are consumed by LockLayout. A late reply after its bounded
    // timeout, or any future frame, is harmless and deliberately ignored.
    AEvent.Kind := sekIgnore;
    AEvent.Data := nil;
  end;
  Result := True;
end;

procedure TSessionClient.QueueEvent(const AEvent: TSessionEvent);
var
  I, N: integer;
begin
  // Lock acquisition may have to drain already queued PTY output before its
  // reply. Preserve every such event in order for the ordinary Idle loop.
  if (FQueuedEventHead > 0) and
     (FQueuedEventHead >= Length(FQueuedEvents) div 2) then
  begin
    N := Length(FQueuedEvents) - FQueuedEventHead;
    // TSessionEvent contains a string and a dynamic array: copy by managed
    // assignment, never Move raw bytes (which would duplicate references
    // without their reference counts and later double-finalize them).
    for I := 0 to N - 1 do
    begin
      FQueuedEvents[I] := FQueuedEvents[FQueuedEventHead + I];
      FQueuedEvents[FQueuedEventHead + I] := Default(TSessionEvent);
    end;
    SetLength(FQueuedEvents, N);
    FQueuedEventHead := 0;
  end;
  N := Length(FQueuedEvents);
  SetLength(FQueuedEvents, N + 1);
  FQueuedEvents[N] := AEvent;
end;

function TSessionClient.PopQueuedEvent(out AEvent: TSessionEvent): boolean;
begin
  AEvent := Default(TSessionEvent);
  if FQueuedEventHead >= Length(FQueuedEvents) then
    Exit(False);
  AEvent := FQueuedEvents[FQueuedEventHead];
  FQueuedEvents[FQueuedEventHead] := Default(TSessionEvent);
  Inc(FQueuedEventHead);
  if FQueuedEventHead >= Length(FQueuedEvents) then
  begin
    FQueuedEvents := nil;
    FQueuedEventHead := 0;
  end;
  Result := True;
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
  if Stream.Position + Cnt * (6 * SizeOf(Longint) + 3) > Stream.Size then
    Exit;
  SetLength(Snapshot.Geom, Cnt);
  for I := 0 to Cnt - 1 do
  begin
    Stream.ReadBuffer(Snapshot.Geom[I].BX, SizeOf(Longint));
    Stream.ReadBuffer(Snapshot.Geom[I].BY, SizeOf(Longint));
    Stream.ReadBuffer(Snapshot.Geom[I].BW, SizeOf(Longint));
    Stream.ReadBuffer(Snapshot.Geom[I].BH, SizeOf(Longint));
    Stream.ReadBuffer(Snapshot.Geom[I].Cols, SizeOf(Longint));
    Stream.ReadBuffer(Snapshot.Geom[I].Rows, SizeOf(Longint));
    Flag := Default(byte);
    Stream.ReadBuffer(Flag, SizeOf(Flag));
    Snapshot.Geom[I].Zoomed := Flag <> 0;
    Stream.ReadBuffer(Flag, SizeOf(Flag));
    Snapshot.Geom[I].Minimized := Flag <> 0;
    Stream.ReadBuffer(Flag, SizeOf(Flag));
    Snapshot.Geom[I].FullScreen := Flag <> 0;
  end;
end;

function TSessionClient.Connect(const APath: string;
  out Snapshot: TSessionSnapshot; AHostW: integer; AHostH: integer): boolean;
var
  ChainS: string;
  Kind: byte;
  Pane: integer;
  Data: TByteArray;
  Stream: TMemoryStream;
  I: integer;
  Deadline: TWaitDeadline;
  L: Longint;
  SessionParsed: boolean;
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
  Snapshot.Revision := 0;
  Snapshot.ClientCount := 0;
  Snapshot.LockedPanes := 0;
  Snapshot.MinHostW := 0;
  Snapshot.MinHostH := 0;
  Snapshot.HostSizesMatch := False;
  Snapshot.HostSummaryValid := False;
  FServerProto := 0;
  FLayoutRevision := 0;
  FClientCount := 0;
  FLockedPanes := 0;
  FMinHostW := 0;
  FMinHostH := 0;
  FHostSizesMatch := False;
  FHostSummaryValid := False;
  FInBuf := '';
  FInPos := 0;
  FOutBuf := '';
  FOutPos := 0;
  FPeerClosed := False;
  FLastPreviewId := 0;
  FLastPreviewTick := 0;
  FQueuedEvents := nil;
  FQueuedEventHead := 0;
  for I := 0 to MAX_PANES - 1 do
  begin
    Snapshot.Panes[I].Title := '';
    Snapshot.Panes[I].Term := '';
    Snapshot.Panes[I].ScreenData := nil;
  end;
  FSocket := ConnectSocket(APath);
  if FSocket < 0 then
  begin
    FAttachError := 'cannot connect to the session socket';
    Exit;
  end;
  FConnected := True;
  {$IFDEF DARWIN}
  // This descriptor belongs exclusively to the interactive client from this
  // point onward.  Keep the complete timed handshake non-blocking as well as
  // the later event loop: a large SCREEN frame can otherwise expose a short
  // serialization/flush gap on Darwin while the descriptor is still in the
  // blocking mode restored by the shared ConnectSocket helper.
  SetNonBlocking(FSocket);
  {$ENDIF}
  Deadline := NewWaitDeadline(AttachIoWaitPolls, AttachIoPollMs);
  {$ifdef SUPERTERM_TEST_BUILD}
  try
  {$endif}
  // tolerant tail of the ATTACH: version, desktop and capabilities; an
  // old daemon ignores the payload and serves the usual v1 protocol
  Data := nil;
  SetLength(Data, 4 * SizeOf(Longint));
  L := ATTACH_PROTO_VER;
  Move(L, Data[0], SizeOf(L));
  L := AHostW;
  Move(L, Data[SizeOf(Longint)], SizeOf(L));
  L := AHostH;
  Move(L, Data[2 * SizeOf(Longint)], SizeOf(L));
  L := ATTACH_CAP_EVENTS;
  Move(L, Data[3 * SizeOf(Longint)], SizeOf(L));
  // tail 2: the chain of sessions this client runs inside of (empty from a
  // real terminal). An older daemon reads the four numbers and ignores it.
  ChainS := GetEnvironmentVariable('SUPERTERM_SESSION_CHAIN');
  L := Length(ChainS);
  SetLength(Data, 5 * SizeOf(Longint) + L);
  Move(L, Data[4 * SizeOf(Longint)], SizeOf(L));
  if L > 0 then
    Move(ChainS[1], Data[5 * SizeOf(Longint)], L);
  if not WriteFrameToTimed(FSocket, FRAME_ATTACH, -1, Data,
     Deadline) then
  begin
    FAttachError := 'session attach request timed out';
    CloseSocket;
    Exit;
  end;
  if not ReadFrameFromTimed(FSocket, Kind, Pane, Data, Deadline) or
     (Kind <> FRAME_SESSION) then
  begin
    FAttachError := 'session did not return a valid snapshot';
    CloseSocket;
    Exit;
  end;
  SessionParsed := False;
  Stream := TMemoryStream.Create;
  try
    if Length(Data) > 0 then
      Stream.WriteBuffer(Data[0], Length(Data));
    Stream.Position := 0;
    if not ReadString(Stream, Snapshot.LayoutNodes) then
      Exit;
    Stream.ReadBuffer(Snapshot.Focused, SizeOf(Snapshot.Focused));
    Stream.ReadBuffer(Snapshot.PaneCount, SizeOf(Snapshot.PaneCount));
    if (Snapshot.PaneCount < 0) or (Snapshot.PaneCount > MAX_PANES) or
       (Snapshot.Focused < -1) or
       (Snapshot.Focused >= Snapshot.PaneCount) then
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
        begin
          Stream.ReadBuffer(Snapshot.ProtoVer, SizeOf(Longint));
          // tolerant tail 4: reserved protocol-v4 slot. Protocol v5 has
          // exactly one geometry model, so its value has no meaning.
          if Stream.Position + SizeOf(Longint) <= Stream.Size then
          begin
            L := 0;
            Stream.ReadBuffer(L, SizeOf(Longint));
            if Stream.Position + SizeOf(QWord) + SizeOf(Longint) <=
               Stream.Size then
            begin
              Stream.ReadBuffer(Snapshot.Revision,
                SizeOf(Snapshot.Revision));
              Stream.ReadBuffer(Snapshot.ClientCount,
                SizeOf(Snapshot.ClientCount));
              if Stream.Position + SizeOf(Snapshot.LockedPanes) <=
                 Stream.Size then
              begin
                Stream.ReadBuffer(Snapshot.LockedPanes,
                  SizeOf(Snapshot.LockedPanes));
                if Stream.Position + 3 * SizeOf(Longint) <= Stream.Size then
                begin
                  Stream.ReadBuffer(Snapshot.MinHostW,
                    SizeOf(Snapshot.MinHostW));
                  Stream.ReadBuffer(Snapshot.MinHostH,
                    SizeOf(Snapshot.MinHostH));
                  L := 0;
                  Stream.ReadBuffer(L, SizeOf(L));
                  Snapshot.HostSizesMatch := L <> 0;
                  Snapshot.HostSummaryValid :=
                    (Snapshot.ClientCount >= 1) and
                    (Snapshot.ClientCount <= MAX_CLIENTS) and
                    (Snapshot.MinHostW >= 1) and
                    (Snapshot.MinHostW <= MAX_SCREEN_COLS) and
                    (Snapshot.MinHostH >= 3) and
                    (Snapshot.MinHostH <= MAX_SCREEN_ROWS) and
                    ((L = 0) or (L = 1));
                end;
              end;
            end;
          end;
        end;
      end;
    FServerProto := Snapshot.ProtoVer;
    FLayoutRevision := Snapshot.Revision;
    FClientCount := Snapshot.ClientCount;
    FLockedPanes := Snapshot.LockedPanes;
    FMinHostW := Snapshot.MinHostW;
    FMinHostH := Snapshot.MinHostH;
    FHostSizesMatch := Snapshot.HostSizesMatch;
    FHostSummaryValid := Snapshot.HostSummaryValid;
    SessionParsed := True;
  finally
    Stream.Free;
    if not SessionParsed then
    begin
      FAttachError := 'session returned a malformed snapshot';
      CloseSocket;
    end;
  end;
  // The daemon refuses clients older than itself, but an OLDER daemon happily
  // accepts a newer client and then feeds it cells of the wrong size. Refuse
  // that direction here too, instead of rendering garbage.
  if Snapshot.ProtoVer <> ATTACH_PROTO_VER then
  begin
    FAttachError := 'session created by an older superterm (protocol ' +
      IntToStr(Snapshot.ProtoVer) + ', need ' + IntToStr(ATTACH_PROTO_VER) +
      '): close it or run the matching binary';
    CloseSocket;
    Exit;
  end;
  if not Snapshot.HostSummaryValid then
  begin
    FAttachError := 'session returned an invalid host summary';
    CloseSocket;
    Exit;
  end;
  for I := 0 to Snapshot.PaneCount - 1 do
  begin
    if not ReadFrameFromTimed(FSocket, Kind, Pane, Data, Deadline) then
    begin
      FAttachError := 'session screen snapshot timed out';
      CloseSocket;
      Exit;
    end;
    if (Kind <> FRAME_SCREEN) or (Pane <> I) then
    begin
      FAttachError := Format(
        'session returned snapshot frame kind %d pane %d; expected screen %d',
        [Kind, Pane, I]);
      CloseSocket;
      Exit;
    end;
    Snapshot.Panes[I].ScreenData := Copy(Data, 0, Length(Data));
  end;
  if not ReadFrameFromTimed(FSocket, Kind, Pane, Data, Deadline) or
     (Kind <> FRAME_READY) then
  begin
    FAttachError := 'session did not finish its snapshot';
    CloseSocket;
    Exit;
  end;
  // READY completes a valid snapshot even when the canonical desktop has no
  // panes.  In that state LayoutNodes is deliberately empty and no SCREEN
  // frames precede READY.
  Result := True;
  {$ifdef SUPERTERM_TEST_BUILD}
  finally
    if DebugActive and
       (GetEnvironmentVariable('SUPERTERM_TESTING') = '1') then
      DebugLog(Format(
        'test-attach-deadline: ready=%d reached=%d success=%d',
        [Deadline.ReadyCount, Ord(Deadline.Reached), Ord(Result)]));
  end;
  {$endif}
end;

function TSessionClient.Poll(out Event: TSessionEvent): boolean;
var
  Kind: byte;
  Pane: integer;
  Data: TByteArray;
  ClosedNow: boolean;
  PopResult: TFramePop;
begin
  Event := Default(TSessionEvent);
  Event.Kind := sekLost;
  Event.Pane := -1;
  Result := False;
  if PopQueuedEvent(Event) then
    Exit(True);
  if not FConnected then
    Exit;
  // Sending commands is opportunistic: a daemon that temporarily stops
  // reading can never stall the UI's Idle loop.  A fatal error is reported
  // through the same single lost event as a failed read.
  if not FlushOutgoing then
  begin
    Event.Kind := sekLost;
    Exit(True);
  end;
  PopResult := PopBufferedFrame(FInBuf, FInPos, Kind, Pane, Data);
  if PopResult = fpReady then
    Exit(DecodeEvent(Kind, Pane, Data, Event));
  if (PopResult = fpInvalid) or FPeerClosed then
  begin
    CloseSocket;
    Event.Kind := sekLost;
    Exit(True);
  end;
  if PollFd(FSocket, POLLIN, 0) <= 0 then
    Exit;
  ClosedNow := False;
  if not ReadSocketAvailable(FSocket, FInBuf, FInPos, ClosedNow) then
  begin
    CloseSocket;
    Event.Kind := sekLost;
    Exit(True);
  end;
  if ClosedNow then
    FPeerClosed := True;
  PopResult := PopBufferedFrame(FInBuf, FInPos, Kind, Pane, Data);
  if PopResult = fpReady then
    Exit(DecodeEvent(Kind, Pane, Data, Event));
  if (PopResult = fpInvalid) or FPeerClosed then
  begin
    CloseSocket;
    Event.Kind := sekLost;
    Exit(True);
  end;
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

function TSessionClient.SendClientSize(ACols, ARows: integer): boolean;
var
  Data: TByteArray;
  Pair: array[0..1] of Longint;
begin
  Result := False;
  Data := nil;
  if (ACols < 1) or (ACols > MAX_SCREEN_COLS) or
     (ARows < 3) or (ARows > MAX_SCREEN_ROWS) then
    Exit;
  Pair[0] := ACols;
  Pair[1] := ARows;
  SetLength(Data, SizeOf(Pair));
  Move(Pair, Data[0], SizeOf(Pair));
  Result := SendFrame(FRAME_CLIENT_SIZE, -1, Data);
end;

function TSessionClient.Detach: boolean;
var
  Data: TByteArray;
begin
  Data := nil;
  Result := SendFrame(FRAME_DETACH, -1, Data);
  if Result then
    Result := FlushOutgoingBounded(CLIENT_CLOSE_WAIT_POLLS);
  CloseSocket;
end;

function TSessionClient.CloseSession: boolean;
var
  Data: TByteArray;
  Buf: array[0..4095] of byte;
  N: ssize_t;
  I, E: integer;
begin
  Data := nil;
  Result := SendFrame(FRAME_CLOSE, -1, Data);
  if Result then
    Result := FlushOutgoingBounded(CLIENT_CLOSE_WAIT_POLLS);
  if DebugActive then
    DebugLog(Format('client: exit sent=%d', [Ord(Result)]));
  if Result and (FSocket >= 0) then
  begin
    // Keep the read half alive until the daemon has consumed every frame
    // preceding CLOSE. A full close here let an authoritative layout echo hit
    // EPIPE; the daemon then dropped this client before reaching the already
    // buffered CLOSE, leaving a zero-viewer session behind.
    FpShutdown(FSocket, 1); // POSIX SHUT_WR
    for I := 1 to CLIENT_CLOSE_WAIT_POLLS do
    begin
      if PollFd(FSocket, POLLIN or POLLHUP, CLIENT_CLOSE_POLL_MS) > 0 then
      begin
        N := FpRecv(FSocket, @Buf[0], SizeOf(Buf), ST_MSG_DONTWAIT);
        if N = 0 then
          Break;
        if N < 0 then
        begin
          E := FpGetErrNo;
          if (E <> ESysEINTR) and (E <> ESysEAGAIN) and
             (E <> ESysEWOULDBLOCK) then
            Break;
        end;
      end;
    end;
  end;
  CloseSocket;
end;

function TSessionClient.SendKillPane(APane: integer): boolean;
var
  Data: TByteArray;
begin
  Data := nil;
  // Close all is an indivisible FIFO command. The daemon claims its global
  // structural lease inside the command and emits only the final empty event;
  // a separate visible lock snapshot would be a pointless pre-action flash.
  if APane = -1 then
    Exit(SendFrame(FRAME_KILLPANE, APane, Data));
  Result := LockLayout(-1);
  if not Result then
    Exit;
  Result := SendFrame(FRAME_KILLPANE, APane, Data);
  if not Result then
    UnlockLayout(-1);
end;

function TSessionClient.SendLayout(const ANodes: string; AFocused: integer;
  const ATitles: TStrArray; const AGeom: TPaneGeomArray;
  ADeskW, ADeskH: integer; AChangeMask: LongWord): boolean;
var
  Stream: TMemoryStream;
  Data: TByteArray;
  Cnt, I, F: Longint;
  Flag: byte;
begin
  Result := False;
  if (Length(ATitles) <> Length(AGeom)) or
     (Length(AGeom) > MAX_PANES) then
    Exit;
  Cnt := Length(AGeom);
  if ((Cnt = 0) and ((ANodes <> '') or (AFocused <> -1))) or
     ((Cnt > 0) and ((ANodes = '') or (AFocused < -1) or
      (AFocused >= Cnt))) then
    Exit;
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
      Stream.WriteBuffer(AGeom[I].Cols, SizeOf(Longint));
      Stream.WriteBuffer(AGeom[I].Rows, SizeOf(Longint));
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
      if AGeom[I].FullScreen then
        Flag := 1
      else
        Flag := 0;
      Stream.WriteBuffer(Flag, SizeOf(Flag));
    end;
    Stream.WriteBuffer(FLayoutRevision, SizeOf(FLayoutRevision));
    F := FClientCount;
    Stream.WriteBuffer(F, SizeOf(F));
    Stream.WriteBuffer(AChangeMask, SizeOf(AChangeMask));
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

function TSessionClient.LockLayout(APane: integer): boolean;
var
  Kind: byte;
  Pane, K, LastLayoutEvent, WaitAttempt: integer;
  PollEvents: cshort;
  Data: TByteArray;
  Event: TSessionEvent;
  RequestId, ReplyId, ReplyRevision: QWord;
  GotReply, ClosedNow, Granted: boolean;
  PopResult: TFramePop;
begin
  Result := False;
  Data := nil;
  Inc(FNextLayoutLockRequest);
  if FNextLayoutLockRequest = 0 then
    Inc(FNextLayoutLockRequest);
  RequestId := FNextLayoutLockRequest;
  SetLength(Data, 2 * SizeOf(QWord));
  Move(RequestId, Data[0], SizeOf(RequestId));
  Move(FLayoutRevision, Data[SizeOf(RequestId)], SizeOf(FLayoutRevision));
  if not SendFrame(FRAME_LAYOUT_LOCK, APane, Data) then
    Exit;
  // The daemon is a local Unix-socket peer. Wait only for its explicit
  // grant/deny while preserving every PTY/layout event already ahead of the
  // reply for the normal Idle loop. This never blocks the daemon or another
  // client, and prevents the losing client from mutating then rolling back.
  GotReply := False;
  Granted := False;
  WaitAttempt := 0;
  repeat
    Data := nil;
    PopResult := PopBufferedFrame(FInBuf, FInPos, Kind, Pane, Data);
    if PopResult = fpReady then
    begin
      if (Kind = FRAME_LAYOUT_LOCK_REPLY) and
         (Length(Data) = 2 * SizeOf(QWord) + 1) then
      begin
        ReplyId := 0;
        ReplyRevision := 0;
        Move(Data[0], ReplyId, SizeOf(ReplyId));
        Move(Data[SizeOf(ReplyId) + 1], ReplyRevision,
          SizeOf(ReplyRevision));
        if ReplyId = RequestId then
        begin
          GotReply := True;
          Granted := Data[SizeOf(ReplyId)] <> 0;
          Result := Granted and (ReplyRevision = FLayoutRevision) and
            (not FPeerClosed);
          if Result then
          begin
            // TryLockLayout broadcasts one viewer-relative snapshot after a
            // successful grant and immediately before this reply. A grant
            // also proves that no pending snapshot contains a newer revision.
            // Keep only that final grant snapshot for a pane lease and ignore
            // every older layout, including frames left by an earlier wait.
            // Otherwise an Idle batch edge could briefly restore old focus or
            // bounds before the grant snapshot corrects them.
            LastLayoutEvent := -1;
            for K := FQueuedEventHead to High(FQueuedEvents) do
              if FQueuedEvents[K].Kind in [sekLayoutEv,
                sekLayoutPeerEv] then
                LastLayoutEvent := K;
            for K := FQueuedEventHead to High(FQueuedEvents) do
              if FQueuedEvents[K].Kind in [sekLayoutEv,
                sekLayoutPeerEv] then
              begin
                // A structural action mutates the split tree immediately
                // after LockLayout returns. Even the grant snapshot then
                // represents the old tree, so none may be applied later.
                if (APane < 0) or (K <> LastLayoutEvent) then
                  FQueuedEvents[K].Kind := sekIgnore
                else
                begin
                  FQueuedEvents[K].Kind := sekLayoutPeerEv;
                  FQueuedEvents[K].Pane := APane;
                end;
              end;
            // The grant is also an ordering barrier for cosmetic traffic.
            // TryLockLayout cancelled the previous preview on this pane (or
            // every preview for a structural lease) before broadcasting its
            // snapshot. Do not let an already queued BOUNDS/CLEAR from that
            // superseded owner run after the new local gesture has started.
            for K := FQueuedEventHead to High(FQueuedEvents) do
              if (FQueuedEvents[K].Kind = sekLayoutPreviewEv) and
                 ((APane < 0) or (FQueuedEvents[K].Pane = APane)) then
                FQueuedEvents[K].Kind := sekIgnore;
          end;
          if FPeerClosed then
          begin
            CloseSocket;
            Event := Default(TSessionEvent);
            Event.Kind := sekLost;
            Event.Pane := -1;
            QueueEvent(Event);
          end;
          if DebugFull then
            DebugLog(Format(
              'client-layout-lock: request=%d pane=%d granted=%d revision=%d applied=%d',
              [RequestId, APane, Ord(Result), ReplyRevision,
               FLayoutRevision]));
          Break;
        end;
        // A reply for an expired request is correlated and harmless.
        Continue;
      end;
      DecodeEvent(Kind, Pane, Data, Event);
      if Event.Kind <> sekIgnore then
        QueueEvent(Event);
      Continue;
    end;
    if PopResult = fpInvalid then
    begin
      CloseSocket;
      Event := Default(TSessionEvent);
      Event.Kind := sekLost;
      Event.Pane := -1;
      QueueEvent(Event);
      Exit;
    end;
    if FPeerClosed then
    begin
      CloseSocket;
      Event := Default(TSessionEvent);
      Event.Kind := sekLost;
      Event.Pane := -1;
      QueueEvent(Event);
      Exit;
    end;
    if not FlushOutgoing then
    begin
      Event := Default(TSessionEvent);
      Event.Kind := sekLost;
      Event.Pane := -1;
      QueueEvent(Event);
      Exit;
    end;
    Inc(WaitAttempt);
    if WaitAttempt > LAYOUT_LOCK_REPLY_POLLS then
      Break;
    PollEvents := POLLIN or POLLHUP;
    if OutputPending then
      PollEvents := PollEvents or POLLOUT;
    if PollFd(FSocket, PollEvents, LAYOUT_LOCK_REPLY_POLL_MS) <= 0 then
      Continue;
    if OutputPending and (not FlushOutgoing) then
    begin
      Event := Default(TSessionEvent);
      Event.Kind := sekLost;
      Event.Pane := -1;
      QueueEvent(Event);
      Exit;
    end;
    ClosedNow := False;
    if not ReadSocketAvailable(FSocket, FInBuf, FInPos, ClosedNow) then
    begin
      CloseSocket;
      Event := Default(TSessionEvent);
      Event.Kind := sekLost;
      Event.Pane := -1;
      QueueEvent(Event);
      Exit;
    end;
    if ClosedNow then
      FPeerClosed := True;
  until False;
  if (not GotReply) or (Granted and (not Result)) then
  begin
    if DebugActive then
      DebugLog(Format('client-layout-lock: request=%d pane=%d cancelled',
        [RequestId, APane]));
    // Ordered cancellation: if the delayed request is granted later, this
    // immediately releases it; if it was never observed, it is a no-op.
    UnlockLayout(APane);
  end;
end;

procedure TSessionClient.AcceptLayoutState(ARevision: QWord;
  ALockedPanes: LongWord);
begin
  // Socket order guarantees monotonic canonical revisions. Equal revisions
  // are meaningful because acquisition/release changes only the lock mask.
  if ARevision < FLayoutRevision then
    Exit;
  FLayoutRevision := ARevision;
  FLockedPanes := ALockedPanes;
end;

function TSessionClient.UnlockLayout(APane: integer): boolean;
var
  Data: TByteArray;
begin
  Data := nil;
  Result := SendFrame(FRAME_LAYOUT_UNLOCK, APane, Data);
end;

function TSessionClient.NewPreviewId: QWord;
begin
  Inc(FNextPreviewId);
  if FNextPreviewId = 0 then
    Inc(FNextPreviewId);
  Result := FNextPreviewId;
end;

function TSessionClient.SendLayoutPreview(APane: integer; AGestureId,
  ABaseRevision, ASeq: QWord; AOp: byte; AX, AY, AW, AH: Longint;
  AForce: boolean): boolean;
var
  Data: TByteArray;
  Preview: TLayoutPreview;
  NowTick: QWord;
  VisualOp: boolean;
begin
  Result := False;
  Data := nil;
  VisualOp := AOp in [PREVIEW_OP_BOUNDS, PREVIEW_OP_WIREFRAME,
    PREVIEW_OP_OUTLINE_SHOW, PREVIEW_OP_OUTLINE_HIDE];
  if (APane < 0) or (APane >= MAX_PANES) or (AGestureId = 0) or
     (ABaseRevision = 0) or (ASeq = 0) or (ASeq = High(QWord)) or
     (not (AOp in [PREVIEW_OP_BOUNDS, PREVIEW_OP_WIREFRAME,
       PREVIEW_OP_OUTLINE_SHOW, PREVIEW_OP_OUTLINE_HIDE,
       PREVIEW_OP_TAIL_BEGIN, PREVIEW_OP_TAIL_END, PREVIEW_OP_CLEAR])) then
    Exit;
  if VisualOp then
  begin
    if (AW < 1) or (AW > MAX_SCREEN_COLS) or
       (AH < 1) or (AH > MAX_SCREEN_ROWS) then
      Exit;
  end
  else if (AX <> 0) or (AY <> 0) or (AW <> 0) or (AH <> 0) then
    Exit;

  // Motion previews are lossy by design; the final FRAME_LAYOUT is not.
  // A complete asynchronous client egress queue would have to cover every
  // command and LockLayout reply together. Until then, bound the rate here
  // without changing the established reliable socket ordering.
  NowTick := GetTickCount64;
  if (not AForce) and
     (AOp in [PREVIEW_OP_BOUNDS, PREVIEW_OP_WIREFRAME]) and
     (FLastPreviewId = AGestureId) and (FLastPreviewTick <> 0) and
     (NowTick - FLastPreviewTick < LAYOUT_PREVIEW_MIN_INTERVAL_MS) then
    Exit(True);

  Preview := Default(TLayoutPreview);
  Preview.GestureId := AGestureId;
  Preview.BaseRevision := ABaseRevision;
  Preview.Seq := ASeq;
  Preview.Op := AOp;
  Preview.X := AX;
  Preview.Y := AY;
  Preview.W := AW;
  Preview.H := AH;
  SetLength(Data, SizeOf(Preview));
  Move(Preview, Data[0], SizeOf(Preview));
  Result := SendFrame(FRAME_LAYOUT_PREVIEW, APane, Data);
  if Result then
  begin
    FLastPreviewId := AGestureId;
    FLastPreviewTick := NowTick;
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
    Stream.WriteBuffer(FLayoutRevision, SizeOf(FLayoutRevision));
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
  // NEWPANE has no speculative client-side mutation to protect.  The daemon
  // acquires the structural lease when this FIFO command reaches the single
  // consumer, then publishes the authoritative NEWPANE_EV.  Pre-locking here
  // lost the first click on an empty desktop: the preceding zero-pane layout
  // event could still be queued locally, so its revision made LOCK fail and
  // the command was never sent.
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
  Result := LockLayout(APane);
  if not Result then
    Exit;
  Result := SendFrame(FRAME_RENAME, APane, Data);
  if not Result then
    UnlockLayout(APane);
end;

constructor TDetachedSession.Create(const AName, AProfile: string;
  ALay: TLayout;
  const APanes: TPtyArray; const AScreens: TScreenArray;
  const ATitles: TStrArray; const ATerms: TStrArray;
  AFocused: integer; const AGeom: TPaneGeomArray;
  ADeskW, ADeskH: integer; const ATitleFixed: TBoolArray);
var
  I: integer;
  ServerCfg: TConfig;
begin
  inherited Create;
  // TObject.InitInstance zeroes the allocation, but fd 0 is valid and an
  // RTL synchronisation object must be finalized only after its successful
  // initialization.  Establish every destructor invariant before the first
  // operation below which can raise (RTLEventCreate, LoadConfig or pipe).
  FName := SanitizeSessionName(AName);
  FProfile := AProfile;
  FSocketPath := SessionSocketPathFor(FName);
  FMetaPath := SessionMetaPathFor(FName);
  // Cache this while the daemon is unquestionably the current process.  All
  // later sidecar generations must carry the same birth identity even if a
  // transient process-information query would fail during an update.
  FPidIdentity := ProcBirthIdentity(FpGetPid);
  FListener := -1;
  FOwnsPanes := False;
  FWorkerCount := 0;
  FPaneLocksInitialized := 0;
  FWorkerResultLockInitialized := False;
  FWorkerResultPipe[0] := -1;
  FWorkerResultPipe[1] := -1;
  FWorkerResultSpace := nil;
  for I := 0 to MAX_CLIENTS - 1 do
  begin
    FClients[I] := Default(TClientConn);
    FClients[I].Fd := -1;
  end;
  for I := 0 to MAX_PENDING_CONNECTIONS - 1 do
  begin
    FPending[I] := Default(TPendingConn);
    FPending[I].Fd := -1;
  end;
  FRetiredChildCount := 0;
  for I := 0 to MAX_RETIRED_CHILDREN - 1 do
    FRetiredChildren[I] := 0;
  FWorkerResultHead := 0;
  FWorkerResultCount := 0;
  FWorkerResultBytes := 0;
  InitCriticalSection(FWorkerResultLock);
  FWorkerResultLockInitialized := True;
  FWorkerResultSpace := RTLEventCreate;
  if FWorkerResultSpace <> nil then
    RTLEventSetEvent(FWorkerResultSpace);
  for I := 0 to MAX_PANES - 1 do
  begin
    InitCriticalSection(FPaneLocks[I]);
    Inc(FPaneLocksInitialized);
    FWorkers[I] := nil;
    if (I = 2) and SessionStartupTestStage('constructor-partial') then
      raise Exception.Create('injected partial detached-session constructor');
  end;
  LoadConfig(ServerCfg);
  FConfiguredThreads := ServerCfg.MultiThread;
  FAvailableCPUs := AvailableCPUCount;
  if FConfiguredThreads = 0 then
    FThreadLimit := FAvailableCPUs
  else
    FThreadLimit := FConfiguredThreads;
  if FThreadLimit > FAvailableCPUs then
    FThreadLimit := FAvailableCPUs;
  if FThreadLimit > MAX_PANES + 1 then
    FThreadLimit := MAX_PANES + 1;
  if FThreadLimit < 1 then
    FThreadLimit := 1;
  if (FThreadLimit > 1) and (FpPipe(FWorkerResultPipe) = 0) then
  begin
    SetCloExec(FWorkerResultPipe[0]);
    SetCloExec(FWorkerResultPipe[1]);
    SetNonBlocking(FWorkerResultPipe[0]);
    SetNonBlocking(FWorkerResultPipe[1]);
  end
  else if FThreadLimit > 1 then
    FThreadLimit := 1;
  if (FThreadLimit > 1) and (FWorkerResultSpace = nil) then
    FThreadLimit := 1;
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
  FSocketDev := 0;
  FSocketIno := 0;
  FSocketIdentityValid := False;
  FCommandHead := 0;
  FCommandCount := 0;
  FCommandBytes := 0;
  FNextCommandSequence := 0;
  FNextConnectionGeneration := 0;
  FDispatchCursor := 0;
  for I := 0 to COMMAND_QUEUE_SLOTS - 1 do
    FCommandQueue[I].Data := nil;
  FStop := False;
  FRevision := 1;
  FLayoutTreeOwner := -1;
  for I := 0 to MAX_PANES - 1 do
  begin
    FPaneLayoutOwner[I] := -1;
    FPaneLeaseGeneration[I] := 0;
    FPaneLeaseRevision[I] := 0;
    FLayoutPreviews[I] := Default(TLayoutPreviewState);
  end;
  // initial shared window geometry exactly as it was when the daemon started
  FGeomValid := Length(AGeom) = FPaneCount;
  FDeskW := ADeskW;
  FDeskH := ADeskH;
  if FGeomValid then
    for I := 0 to FPaneCount - 1 do
    begin
      FGeom[I] := AGeom[I];
      if FScreens[I] <> nil then
      begin
        FGeom[I].Cols := FScreens[I].Width;
        FGeom[I].Rows := FScreens[I].Height;
      end;
    end;
end;

destructor TDetachedSession.Destroy;
var
  I: integer;
  LockResult: TSessionNameLockResult;
  RemoveOwnedFiles: boolean;
begin
  // Serialize the close/unlink edge with a creator of the same name. If an
  // exceptional startup still owns the parent-side lock, fail safe by
  // leaving a stale path for enumeration instead of blocking or deleting a
  // socket which might already belong to somebody else.
  RemoveOwnedFiles := False;
  if FSocketIdentityValid and (FName <> '') then
  begin
    LockResult := TryHoldSessionNameLock(FName);
    RemoveOwnedFiles := (LockResult = snlAcquired) and OwnsSocketPath;
  end;
  StopPaneWorkers;
  for I := 0 to MAX_CLIENTS - 1 do
    if FClients[I].Fd >= 0 then
    begin
      FpClose(FClients[I].Fd);
      FClients[I].Fd := -1;
    end;
  for I := 0 to MAX_PENDING_CONNECTIONS - 1 do
    if FPending[I].Fd >= 0 then
    begin
      FpClose(FPending[I].Fd);
      FPending[I].Fd := -1;
    end;
  if FListener >= 0 then
  begin
    FpClose(FListener);
    FListener := -1;
  end;
  if RemoveOwnedFiles then
  begin
    FpUnlink(PAnsiChar(FSocketPath));
    if FMetaPath <> '' then
      FpUnlink(PAnsiChar(FMetaPath));
  end;
  ReleaseHeldSessionNameLock;
  for I := 0 to FPaneCount - 1 do
  begin
    if FOwnsPanes and (FPanes[I] <> nil) then
    begin
      // Final daemon teardown must not spend up to two seconds per pane. The
      // process is exiting immediately after signalling; orphan reaping is
      // then owned by the OS subreaper/init.
      FPanes[I].TerminateNoWait;
      FPanes[I].Free;
    end;
    FPanes[I] := nil;
    if FOwnsPanes then
      FScreens[I].Free;
    FScreens[I] := nil;
  end;
  if FOwnsPanes then
    FLayout.Free;
  FLayout := nil;
  if FWorkerResultPipe[0] >= 0 then
    FpClose(FWorkerResultPipe[0]);
  if FWorkerResultPipe[1] >= 0 then
    FpClose(FWorkerResultPipe[1]);
  for I := 0 to WORKER_RESULT_SLOTS - 1 do
    FWorkerResults[I].Data := nil;
  for I := 0 to COMMAND_QUEUE_SLOTS - 1 do
    FCommandQueue[I].Data := nil;
  if FWorkerResultSpace <> nil then
    RTLEventDestroy(FWorkerResultSpace);
  if FWorkerResultLockInitialized then
  begin
    DoneCriticalSection(FWorkerResultLock);
    FWorkerResultLockInitialized := False;
  end;
  for I := 0 to FPaneLocksInitialized - 1 do
    DoneCriticalSection(FPaneLocks[I]);
  FPaneLocksInitialized := 0;
  inherited Destroy;
end;

function TDetachedSession.OwnsSocketPath: boolean;
var
  St: Stat;
begin
  St := Default(Stat);
  Result := FSocketIdentityValid and
    (FpLStat(RawByteString(FSocketPath), St) = 0) and FpS_ISSOCK(St.st_mode) and
    (QWord(St.st_dev) = FSocketDev) and (QWord(St.st_ino) = FSocketIno);
end;

function TDetachedSession.CreateListener: boolean;
var
  Addr: TUnixSockAddr;
  AddrLen: TSockLen;
  Probe: TSocketProbe;
  St: Stat;
begin
  Result := False;
  Probe := ProbeSocket(FSocketPath);
  // A timeout means a saturated/hung but existing listener, never a stale
  // inode. A recent refusal may be another creator between bind and listen.
  if (Probe <> spDead) or SocketIsRecent(FSocketPath) then
    Exit;
  St := Default(Stat);
  if FpLStat(RawByteString(FSocketPath), St) = 0 then
  begin
    if (not FpS_ISSOCK(St.st_mode)) or
       (FpUnlink(PAnsiChar(FSocketPath)) <> 0) then
      Exit;
  end
  else if FpGetErrNo <> ESysENOENT then
    Exit;
  if not SocketAddress(FSocketPath, Addr, AddrLen) then
    Exit;
  FListener := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  SetCloExec(FListener);
  if FListener < 0 then
    Exit;
  if fpBind(FListener, @Addr, AddrLen) <> 0 then
  begin
    FpClose(FListener);
    FListener := -1;
    Exit;
  end;
  St := Default(Stat);
  if (FpLStat(RawByteString(FSocketPath), St) <> 0) or
     (not FpS_ISSOCK(St.st_mode)) then
  begin
    FpClose(FListener);
    FListener := -1;
    Exit;
  end;
  FSocketDev := QWord(St.st_dev);
  FSocketIno := QWord(St.st_ino);
  FSocketIdentityValid := True;
  if fpListen(FListener, MAX_PENDING_CONNECTIONS) <> 0 then
  begin
    FpClose(FListener);
    FListener := -1;
    if OwnsSocketPath then
      FpUnlink(PAnsiChar(FSocketPath));
    FSocketDev := 0;
    FSocketIno := 0;
    FSocketIdentityValid := False;
    Exit;
  end;
  SetNonBlocking(FListener);
  FpChmod(PAnsiChar(FSocketPath), &600);
  Result := True;
end;

function TDetachedSession.PrepareListener: boolean;
begin
  Result := (FListener >= 0) or CreateListener;
end;

procedure TDetachedSession.AdoptPanes;
begin
  FOwnsPanes := True;
end;

function TDetachedSession.SpawnInitialPanes: boolean;
var
  I: integer;
  UsedFallback: boolean;
begin
  Result := False;
  for I := 0 to FPaneCount - 1 do
  begin
    if (FPanes[I] = nil) or (FScreens[I] = nil) then
      Exit;
    if FPanes[I].Alive then
      Continue;  // classic detach: an already-running PTY was inherited
    if (not FPanes[I].LaunchPending) or
       (not FPanes[I].SpawnConfigured(UsedFallback)) then
      Exit;
    if UsedFallback then
    begin
      FTitles[I] := UiText('FAILED ', 'FALLO ') + FTitles[I];
      FTerms[I] := '';
      FTitleFixed[I] := True;
    end;
  end;
  Result := True;
end;

function TDetachedSession.AttachedCount: integer;
var
  I: integer;
begin
  Result := 0;
  for I := 0 to MAX_CLIENTS - 1 do
    if (FClients[I].Fd >= 0) and FClients[I].Ready then
      Inc(Result);
end;

function TDetachedSession.HasLegacyClient: boolean;
var
  I: integer;
begin
  Result := False;
  for I := 0 to MAX_CLIENTS - 1 do
    if (FClients[I].Fd >= 0) and FClients[I].Ready and
       FClients[I].Legacy then
      Exit(True);
end;

procedure TDetachedSession.ClientSizeSummary(out AMinW, AMinH: Longint;
  out AAllMatch: boolean);
var
  I, Count, W, H, FirstW, FirstH: integer;
begin
  AMinW := 0;
  AMinH := 0;
  FirstW := 0;
  FirstH := 0;
  Count := 0;
  AAllMatch := True;
  // Include the attaching slot before it becomes Ready: its own snapshot and
  // the first broadcast to existing viewers must describe the same set.
  for I := 0 to MAX_CLIENTS - 1 do
    if FClients[I].Fd >= 0 then
    begin
      W := FClients[I].HostW;
      H := FClients[I].HostH;
      if (W < 1) or (H < 3) then
      begin
        W := FDeskW;
        H := FDeskH + 2;
        AAllMatch := False;
      end;
      if Count = 0 then
      begin
        FirstW := W;
        FirstH := H;
        AMinW := W;
        AMinH := H;
      end
      else
      begin
        if (W <> FirstW) or (H <> FirstH) then
          AAllMatch := False;
        if W < AMinW then AMinW := W;
        if H < AMinH then AMinH := H;
      end;
      Inc(Count);
    end;
  if Count = 0 then
  begin
    AMinW := FDeskW;
    AMinH := FDeskH + 2;
    AAllMatch := True;
  end;
end;

// Derive the PTY grid from daemon-owned host metadata at the instant a zoom
// is committed. A client may have acquired its pane lease just before another
// viewer attached or resized; normalizing here closes that TOCTOU window and
// keeps a stale proposal from making the shared maximum larger than one host.
procedure TDetachedSession.SharedZoomedPaneSize(ADeskW, ADeskH: Longint;
  AFullScreen: boolean; out ACols, ARows: Longint);
var
  MinHostW, MinHostH, SafeDeskW, SafeDeskH: Longint;
  HostSizesMatch: boolean;
begin
  ClientSizeSummary(MinHostW, MinHostH, HostSizesMatch);
  if DebugFull then
    DebugLog(Format('shared-zoom-size: desk=%dx%d host-min=%dx%d match=%d full=%d',
      [ADeskW, ADeskH, MinHostW, MinHostH, Ord(HostSizesMatch),
       Ord(AFullScreen)]));
  if AFullScreen then
  begin
    ACols := MinHostW;
    ARows := MinHostH;
  end
  else
  begin
    SafeDeskW := ADeskW;
    SafeDeskH := ADeskH;
    // Normal maximize must fit the smallest current viewer even when that is
    // now the sole viewer or all remaining viewers have the same small size.
    // HostSizesMatch is relevant to raw fullscreen passthrough, not to this bound.
    if MinHostW > 0 then
    begin
      if SafeDeskW > MinHostW then
        SafeDeskW := MinHostW;
      if (MinHostH > 2) and (SafeDeskH > MinHostH - 2) then
        SafeDeskH := MinHostH - 2;
    end;
    ACols := SafeDeskW - 2;
    ARows := SafeDeskH - 2;
  end;
  if AFullScreen then
  begin
    if ACols < 4 then ACols := 4;
    if ARows < 2 then ARows := 2;
  end
  else
  begin
    if ACols < MIN_WIN_W - 2 then ACols := MIN_WIN_W - 2;
    if ARows < MIN_WIN_H - 2 then ARows := MIN_WIN_H - 2;
  end;
end;

procedure TDetachedSession.BroadcastHostSummaryEv;
var
  Values: array[0..3] of Longint;
  AllMatch: boolean;
begin
  Values[0] := AttachedCount;
  if Values[0] <= 0 then
    Exit;
  ClientSizeSummary(Values[1], Values[2], AllMatch);
  if AllMatch then Values[3] := 1 else Values[3] := 0;
  if DebugFull then
    DebugLog(Format('host-summary: clients=%d min=%dx%d match=%d',
      [Values[0], Values[1], Values[2], Values[3]]));
  // Deliberately bypass BroadcastLayoutEv: that routine excludes a viewer
  // while it owns any layout lease. Host safety metadata is independent of
  // geometry and must reach every ready event-capable viewer immediately.
  Broadcast(FRAME_HOST_SUMMARY_EV, -1, Values, SizeOf(Values), True, -1);
end;

procedure TDetachedSession.BroadcastLayoutPreview(APane, AExcept: integer;
  const APreview: TLayoutPreview);
begin
  // Unlike canonical layout snapshots, a preview must reach a viewer which
  // owns some other pane: independent gestures may be visible concurrently.
  Broadcast(FRAME_LAYOUT_PREVIEW_EV, APane, APreview, SizeOf(APreview),
    True, AExcept);
end;

procedure TDetachedSession.CancelLayoutPreview(APane: integer;
  ABroadcast: boolean);
var
  Preview: TLayoutPreview;
  ExceptClient: integer;
begin
  if (APane < 0) or (APane >= MAX_PANES) or
     (not FLayoutPreviews[APane].Active) then
    Exit;
  Preview := Default(TLayoutPreview);
  Preview.GestureId := FLayoutPreviews[APane].Last.GestureId;
  if FLayoutPreviews[APane].TailAuthorized then
    Preview.BaseRevision := FLayoutPreviews[APane].TailRevision
  else
    Preview.BaseRevision := FLayoutPreviews[APane].Last.BaseRevision;
  Preview.Seq := FLayoutPreviews[APane].Last.Seq + 1;
  Preview.Op := PREVIEW_OP_CLEAR;
  ExceptClient := FLayoutPreviews[APane].Owner;
  if DebugFull then
    DebugLog(Format('layout-preview: clear pane=%d owner=%d id=%d seq=%d',
      [APane, ExceptClient, Int64(Preview.GestureId), Int64(Preview.Seq)]));
  FLayoutPreviews[APane] := Default(TLayoutPreviewState);
  if ABroadcast then
    BroadcastLayoutPreview(APane, ExceptClient, Preview);
end;

procedure TDetachedSession.CancelAllLayoutPreviews(ABroadcast: boolean);
var
  I: integer;
begin
  for I := 0 to MAX_PANES - 1 do
    CancelLayoutPreview(I, ABroadcast);
end;

function TDetachedSession.ExpireLayoutPreviews: boolean;
var
  I: integer;
  NowTick: QWord;
begin
  Result := False;
  NowTick := GetTickCount64;
  for I := 0 to MAX_PANES - 1 do
    if FLayoutPreviews[I].Active and
       FLayoutPreviews[I].TailAuthorized and
       ((FLayoutPreviews[I].TailRevision <> FRevision) or
        (NowTick >= FLayoutPreviews[I].TailDeadline)) then
    begin
      CancelLayoutPreview(I, True);
      Result := True;
    end;
end;

procedure TDetachedSession.SendActiveLayoutPreviews(AClient: integer);
var
  I: integer;
begin
  if (AClient < 0) or (AClient >= MAX_CLIENTS) or
     (FClients[AClient].Fd < 0) or (not FClients[AClient].Ready) or
     ((FClients[AClient].Caps and ATTACH_CAP_EVENTS) = 0) then
    Exit;
  for I := 0 to FPaneCount - 1 do
    if FLayoutPreviews[I].Active and FLayoutPreviews[I].HasVisual and
       (FLayoutPreviews[I].Owner <> AClient) then
      SendFrameToIdx(AClient, FRAME_LAYOUT_PREVIEW_EV, I,
        FLayoutPreviews[I].LastVisual,
        SizeOf(FLayoutPreviews[I].LastVisual));
end;

procedure TDetachedSession.AuthorizeLayoutPreviewTails(AOwner: integer;
  ACommitBase: QWord; AChanges: LongWord);
var
  I: integer;
begin
  if (AOwner < 0) or (AOwner >= MAX_CLIENTS) or
     (FClients[AOwner].Fd < 0) then
    Exit;
  for I := 0 to FPaneCount - 1 do
    if FLayoutPreviews[I].Active and
       FLayoutPreviews[I].TailRequested and
       (not FLayoutPreviews[I].TailAuthorized) and
       (FLayoutPreviews[I].Owner = AOwner) and
       (FLayoutPreviews[I].Generation = FClients[AOwner].Generation) and
       (FLayoutPreviews[I].Last.BaseRevision = ACommitBase) and
       ((AChanges and (LongWord(1) shl I)) <> 0) then
    begin
      FLayoutPreviews[I].TailAuthorized := True;
      FLayoutPreviews[I].TailRevision := FRevision;
      FLayoutPreviews[I].TailDeadline := GetTickCount64 +
        LAYOUT_PREVIEW_TAIL_MS;
      // A client attaching between the commit and the first tail step sees a
      // preview tied to the canonical revision in its snapshot, not the old
      // pre-commit base used to acquire the lease.
      if FLayoutPreviews[I].HasVisual then
        FLayoutPreviews[I].LastVisual.BaseRevision := FRevision;
      if DebugFull then
        DebugLog(Format(
          'layout-preview: tail authorized pane=%d owner=%d id=%d revision=%d',
          [I, AOwner, Int64(FLayoutPreviews[I].Last.GestureId),
           Int64(FRevision)]));
    end;
end;

procedure TDetachedSession.HandleLayoutPreview(AClient, APane: integer;
  const AData: TByteArray);
var
  Preview: TLayoutPreview;
  State: ^TLayoutPreviewState;
  VisualOp, Valid: boolean;
begin
  if (AClient < 0) or (AClient >= MAX_CLIENTS) or
     (FClients[AClient].Fd < 0) or (APane < 0) or
     (APane >= FPaneCount) or
     (not DecodeLayoutPreviewBlob(AData, Preview)) or
     (Preview.Seq = High(QWord)) then
    Exit;
  VisualOp := Preview.Op in [PREVIEW_OP_BOUNDS, PREVIEW_OP_WIREFRAME,
    PREVIEW_OP_OUTLINE_SHOW, PREVIEW_OP_OUTLINE_HIDE];
  if VisualOp then
    // FreeVision intentionally permits a dragged window to sit partly beyond
    // the desktop. Keep those real edge steps, but require a bounded positive
    // rectangle which still intersects the canonical desktop. Int64 avoids a
    // hostile Longint X/Y overflowing during the intersection calculation.
    Valid := (Preview.W >= 1) and (Preview.W <= FDeskW) and
      (Preview.H >= 1) and (Preview.H <= FDeskH) and
      (Int64(Preview.X) < Int64(FDeskW)) and
      (Int64(Preview.X) + Int64(Preview.W) > 0) and
      (Int64(Preview.Y) < Int64(FDeskH)) and
      (Int64(Preview.Y) + Int64(Preview.H) > 0)
  else
    Valid := (Preview.X = 0) and (Preview.Y = 0) and
      (Preview.W = 0) and (Preview.H = 0);
  if not Valid then
    Exit;

  State := @FLayoutPreviews[APane];
  if State^.Active and State^.TailAuthorized then
  begin
    if (GetTickCount64 >= State^.TailDeadline) or
       (State^.TailRevision <> FRevision) then
    begin
      CancelLayoutPreview(APane, True);
      // CLEAR is presentation-only and clients deliberately keep its last
      // frame until canonical state follows. This on-arrival expiry path is
      // independent of the periodic expiry sweep, so pair it here as well.
      BroadcastLayoutEv(-1);
      Exit;
    end;
    Valid := (State^.Owner = AClient) and
      (State^.Generation = FClients[AClient].Generation) and
      (State^.Last.GestureId = Preview.GestureId) and
      (Preview.BaseRevision = State^.TailRevision) and
      (Preview.BaseRevision = FRevision) and
      (Preview.Seq > State^.Last.Seq) and
      (Preview.Op <> PREVIEW_OP_TAIL_BEGIN);
  end
  else
  begin
    Valid := (FPaneLayoutOwner[APane] = AClient) and
      (FPaneLeaseGeneration[APane] = FClients[AClient].Generation) and
      (Preview.BaseRevision = FPaneLeaseRevision[APane]);
    if Valid and State^.Active then
      Valid := (State^.Owner = AClient) and
        (State^.Generation = FClients[AClient].Generation) and
        (State^.Last.GestureId = Preview.GestureId) and
        (State^.Last.BaseRevision = Preview.BaseRevision) and
        (Preview.Seq > State^.Last.Seq)
    else if Valid and State^.Ended then
      Valid := False
    else if Valid then
    begin
      // END/hide without a preceding preview has nothing to clear and must
      // not create a persistent gesture record.
      Valid := not (Preview.Op in [PREVIEW_OP_OUTLINE_HIDE,
        PREVIEW_OP_TAIL_END, PREVIEW_OP_CLEAR]);
      if Valid then
      begin
        State^ := Default(TLayoutPreviewState);
        State^.Active := True;
        State^.Owner := AClient;
        State^.Generation := FClients[AClient].Generation;
      end;
    end;
    // TAIL_END is valid only after a successful matching commit/ACK.
    if Valid and (Preview.Op = PREVIEW_OP_TAIL_END) then
      Valid := False;
  end;
  if not Valid then
    Exit;

  State^.Last := Preview;
  case Preview.Op of
    PREVIEW_OP_BOUNDS, PREVIEW_OP_WIREFRAME, PREVIEW_OP_OUTLINE_SHOW:
      begin
        State^.LastVisual := Preview;
        State^.HasVisual := True;
      end;
    PREVIEW_OP_OUTLINE_HIDE:
      State^.HasVisual := False;
    PREVIEW_OP_TAIL_BEGIN:
      State^.TailRequested := True;
  end;
  if DebugFull then
    DebugLog(Format(
      'layout-preview: relay pane=%d owner=%d id=%d seq=%d op=%d base=%d',
      [APane, AClient, Int64(Preview.GestureId), Int64(Preview.Seq),
       Preview.Op, Int64(Preview.BaseRevision)]));
  BroadcastLayoutPreview(APane, AClient, Preview);
  if Preview.Op = PREVIEW_OP_TAIL_END then
    State^ := Default(TLayoutPreviewState);
  if Preview.Op = PREVIEW_OP_CLEAR then
  begin
    State^.Active := False;
    State^.Ended := True;
    State^.TailRequested := False;
    State^.TailAuthorized := False;
    State^.HasVisual := False;
  end;
end;

procedure TDetachedSession.DropClient(AIdx: integer);
var
  WasReady: boolean;
  I: integer;
begin
  if (AIdx < 0) or (AIdx >= MAX_CLIENTS) or (FClients[AIdx].Fd < 0) then
    Exit;
  WasReady := FClients[AIdx].Ready;
  if FLayoutTreeOwner = AIdx then
    FLayoutTreeOwner := -1;
  for I := 0 to MAX_PANES - 1 do
  begin
    if (FLayoutPreviews[I].Active or FLayoutPreviews[I].Ended) and
       (FLayoutPreviews[I].Owner = AIdx) then
    begin
      if FLayoutPreviews[I].Active then
        CancelLayoutPreview(I, True)
      else
        FLayoutPreviews[I] := Default(TLayoutPreviewState);
    end;
    if FPaneLayoutOwner[I] = AIdx then
    begin
      FPaneLayoutOwner[I] := -1;
      FPaneLeaseGeneration[I] := 0;
      FPaneLeaseRevision[I] := 0;
    end;
  end;
  FpClose(FClients[AIdx].Fd);
  FClients[AIdx] := Default(TClientConn);
  FClients[AIdx].Fd := -1;
  if WasReady then
  begin
    // Detach changes only the set of viewers. The one canonical desktop stays
    // untouched, including when no interactive client remains attached.
    if AttachedCount > 0 then
    begin
      BroadcastHostSummaryEv;
      // Releasing a disconnected owner's lease still changes the lock mask.
      BroadcastLayoutEv(-1);
    end;
  end;
  WriteSidecar;
end;

function TDetachedSession.PendingIndexByFd(AFd: cint): integer;
var
  I: integer;
begin
  for I := 0 to MAX_PENDING_CONNECTIONS - 1 do
    if FPending[I].Fd = AFD then
      Exit(I);
  Result := -1;
end;

procedure TDetachedSession.DropPending(AIdx: integer; AClose: boolean);
begin
  if (AIdx < 0) or (AIdx >= MAX_PENDING_CONNECTIONS) or
     (FPending[AIdx].Fd < 0) then
    Exit;
  if AClose then
    FpClose(FPending[AIdx].Fd);
  FPending[AIdx] := Default(TPendingConn);
  FPending[AIdx].Fd := -1;
end;

function TDetachedSession.NewConnectionGeneration: QWord;
begin
  Inc(FNextConnectionGeneration);
  // Zero denotes an unused/default record.  This is only relevant after a
  // theoretical 2^64 accepts, but keeping the invariant costs nothing.
  if FNextConnectionGeneration = 0 then
    Inc(FNextConnectionGeneration);
  Result := FNextConnectionGeneration;
end;

function TDetachedSession.CanQueueCommand(ASize: integer): boolean;
begin
  Result := (ASize >= 0) and (ASize <= MAX_FRAME_SIZE) and
    (FCommandCount < COMMAND_QUEUE_SLOTS) and
    (FCommandBytes + QWord(ASize) <= QWord(COMMAND_QUEUE_BYTE_LIMIT));
end;

function TDetachedSession.QueueCommand(AOrigin: TCommandOrigin;
  ASlot: integer; AGeneration: QWord; AKind: byte; APane: integer;
  const AData: TByteArray; APeerClose: boolean): boolean;
var
  Tail: integer;
  OriginName: string;
begin
  Result := False;
  if not CanQueueCommand(Length(AData)) then
    Exit;
  Tail := (FCommandHead + FCommandCount) mod COMMAND_QUEUE_SLOTS;
  Inc(FNextCommandSequence);
  if FNextCommandSequence = 0 then
    Inc(FNextCommandSequence);
  FCommandQueue[Tail] := Default(TQueuedCommand);
  FCommandQueue[Tail].Sequence := FNextCommandSequence;
  FCommandQueue[Tail].Origin := AOrigin;
  FCommandQueue[Tail].Slot := ASlot;
  FCommandQueue[Tail].Generation := AGeneration;
  FCommandQueue[Tail].Kind := AKind;
  FCommandQueue[Tail].Pane := APane;
  FCommandQueue[Tail].PeerClose := APeerClose;
  FCommandQueue[Tail].Data := AData;
  Inc(FCommandCount);
  Inc(FCommandBytes, QWord(Length(AData)));
  if DebugFull then
  begin
    if AOrigin = coClient then OriginName := 'client'
    else OriginName := 'pending';
    DebugLog('command-fifo: enqueue seq=' +
      IntToStr(Int64(FNextCommandSequence)) + ' origin=' + OriginName +
      ' slot=' + IntToStr(ASlot) + ' gen=' +
      IntToStr(Int64(AGeneration)) + ' kind=' + IntToStr(AKind) +
      ' pane=' + IntToStr(APane) + ' bytes=' +
      IntToStr(Length(AData)) + ' count=' + IntToStr(FCommandCount) +
      ' total=' + IntToStr(Int64(FCommandBytes)));
  end;
  Result := True;
end;

function TDetachedSession.PopCommand(out ACommand: TQueuedCommand): boolean;
begin
  ACommand := Default(TQueuedCommand);
  if FCommandCount <= 0 then
    Exit(False);
  ACommand := FCommandQueue[FCommandHead];
  FCommandQueue[FCommandHead] := Default(TQueuedCommand);
  FCommandHead := (FCommandHead + 1) mod COMMAND_QUEUE_SLOTS;
  Dec(FCommandCount);
  if FCommandBytes >= QWord(Length(ACommand.Data)) then
    Dec(FCommandBytes, QWord(Length(ACommand.Data)))
  else
    FCommandBytes := 0;
  Result := True;
end;

procedure TDetachedSession.DrainCommandQueue;
var
  Command: TQueuedCommand;
  Valid: boolean;
  OriginName: string;
begin
  // Deliberately no critical section: Run is the sole producer and consumer.
  // Handlers execute only after the item has left the FIFO, so pane locks or
  // callbacks can never be nested under a queue lock.
  Command := Default(TQueuedCommand);
  while PopCommand(Command) do
  begin
    if Command.Origin = coClient then
    begin
      OriginName := 'client';
      Valid := (Command.Slot >= 0) and (Command.Slot < MAX_CLIENTS) and
        (FClients[Command.Slot].Fd >= 0) and
        (FClients[Command.Slot].Generation = Command.Generation);
    end
    else
    begin
      OriginName := 'pending';
      Valid := (Command.Slot >= 0) and
        (Command.Slot < MAX_PENDING_CONNECTIONS) and
        (FPending[Command.Slot].Fd >= 0) and
        (FPending[Command.Slot].Generation = Command.Generation);
    end;
    if DebugFull then
      DebugLog('command-fifo: dequeue seq=' +
        IntToStr(Int64(Command.Sequence)) + ' origin=' + OriginName +
        ' slot=' + IntToStr(Command.Slot) + ' gen=' +
        IntToStr(Int64(Command.Generation)) + ' kind=' +
        IntToStr(Command.Kind) + ' pane=' + IntToStr(Command.Pane) +
        ' bytes=' + IntToStr(Length(Command.Data)) + ' valid=' +
        IntToStr(Ord(Valid)) + ' count=' + IntToStr(FCommandCount) +
        ' total=' + IntToStr(Int64(FCommandBytes)));
    if not Valid then
    begin
      Command.Data := nil;
      Continue;
    end;
    if Command.Origin = coClient then
    begin
      if Command.PeerClose then
        DropClient(Command.Slot)
      else
        HandleClientFrame(Command.Slot, Command.Kind, Command.Pane,
          Command.Data);
    end
    else
    begin
      FPending[Command.Slot].CommandQueued := False;
      if Command.PeerClose then
      begin
        // A one-shot control peer commonly shutdown(SHUT_WR) and keeps
        // reading its reply.  Its normal CloseAfterWrite path owns closure.
        if not FPending[Command.Slot].CloseAfterWrite then
          DropPending(Command.Slot);
      end
      else
        HandlePendingFrame(Command.Slot, Command.Kind, Command.Pane,
          Command.Data);
    end;
    Command.Data := nil;
  end;
end;

// queues bytes toward a client without ever blocking the daemon: first
// a direct non-blocking send and the rest to the egress buffer; if the
// buffer exceeds the cap the client is dead or stalled and gets dropped
function TDetachedSession.QueueOut(AIdx: integer; const Buffer;
  ASize: integer; ASnapshot: boolean): boolean;
var
  P: PByte;
  Left, Pending, Limit, Want: integer;
  N: ssize_t;
begin
  Result := False;
  if (FClients[AIdx].Fd < 0) or (ASize <= 0) then
    Exit;
  P := @Buffer;
  Left := ASize;
  Pending := Length(FClients[AIdx].OutBuf) - FClients[AIdx].OutPos;
  if Pending = 0 then
    while Left > 0 do
    begin
      Want := IO_BUDGET - FClients[AIdx].WriteUsed;
      if Want <= 0 then
        Break;
      if Want > Left then
        Want := Left;
      N := fpSend(FClients[AIdx].Fd, P, Want, ST_MSG_DONTWAIT);
      if N > 0 then
      begin
        Inc(P, N);
        Dec(Left, integer(N));
        Inc(FClients[AIdx].WriteUsed, integer(N));
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
    Pending := Length(FClients[AIdx].OutBuf) - FClients[AIdx].OutPos;
    if ASnapshot or (FClients[AIdx].SnapshotPending > 0) then
      Limit := MAX_SNAPSHOT_EGRESS
    else
      Limit := MAX_EGRESS;
    if (Left > Limit) or (Pending > Limit - Left) then
    begin
      DropClient(AIdx);
      Exit;
    end;
    // Retain a sent prefix while there is ample capacity; this makes draining
    // a large snapshot linear instead of shifting its whole remainder after
    // every 256 KB send. Compact only when allocation would cross the cap.
    if (FClients[AIdx].OutPos > 0) and
       (Length(FClients[AIdx].OutBuf) > Limit - Left) then
    begin
      Delete(FClients[AIdx].OutBuf, 1, FClients[AIdx].OutPos);
      FClients[AIdx].OutPos := 0;
    end;
    Pending := Length(FClients[AIdx].OutBuf);
    SetLength(FClients[AIdx].OutBuf, Pending + Left);
    Move(P^, FClients[AIdx].OutBuf[Pending + 1], Left);
    if ASnapshot then
      Inc(FClients[AIdx].SnapshotPending, QWord(Left));
  end;
  Result := True;
end;

function TDetachedSession.QueuePending(AIdx: integer; AKind: byte;
  APane: integer; const Data: TByteArray): boolean;
var
  H: TFrameHeader;
  OldLen, AddLen: integer;
begin
  Result := False;
  if (AIdx < 0) or (AIdx >= MAX_PENDING_CONNECTIONS) or
     (FPending[AIdx].Fd < 0) or (Length(Data) > MAX_FRAME_SIZE) then
    Exit;
  AddLen := SizeOf(H) + Length(Data);
  OldLen := Length(FPending[AIdx].OutBuf);
  if (AddLen > MAX_SNAPSHOT_EGRESS) or
     (OldLen > MAX_SNAPSHOT_EGRESS - AddLen) then
    Exit;
  H := Default(TFrameHeader);
  H.Kind := AKind;
  H.Pane := SmallInt(APane);
  H.Size := Length(Data);
  SetLength(FPending[AIdx].OutBuf, OldLen + AddLen);
  Move(H, FPending[AIdx].OutBuf[OldLen + 1], SizeOf(H));
  if Length(Data) > 0 then
    Move(Data[0], FPending[AIdx].OutBuf[OldLen + 1 + SizeOf(H)],
      Length(Data));
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
    if (FClients[I].Fd >= 0) and FClients[I].Ready and
       (I <> AExcept) and
       ((not ANeedCaps) or
        ((FClients[I].Caps and ATTACH_CAP_EVENTS) <> 0)) then
      SendFrameToIdx(I, AKind, APane, Buffer, ASize);
end;

procedure TDetachedSession.FlushClient(AIdx: integer);
var
  Want: integer;
  N: ssize_t;
begin
  if (FClients[AIdx].Fd < 0) or
     (FClients[AIdx].OutPos >= Length(FClients[AIdx].OutBuf)) then
    Exit;
  Want := IO_BUDGET - FClients[AIdx].WriteUsed;
  if Want <= 0 then
    Exit;
  if Want > Length(FClients[AIdx].OutBuf) - FClients[AIdx].OutPos then
    Want := Length(FClients[AIdx].OutBuf) - FClients[AIdx].OutPos;
  N := fpSend(FClients[AIdx].Fd,
    @FClients[AIdx].OutBuf[FClients[AIdx].OutPos + 1], Want,
    ST_MSG_DONTWAIT);
  if N > 0 then
  begin
    Inc(FClients[AIdx].OutPos, integer(N));
    Inc(FClients[AIdx].WriteUsed, integer(N));
    if FClients[AIdx].SnapshotPending > QWord(N) then
      Dec(FClients[AIdx].SnapshotPending, QWord(N))
    else
      FClients[AIdx].SnapshotPending := 0;
    FClients[AIdx].LastProgress := GetTickCount64;
    if FClients[AIdx].OutPos = Length(FClients[AIdx].OutBuf) then
    begin
      FClients[AIdx].OutBuf := '';
      FClients[AIdx].OutPos := 0;
    end
    else if (FClients[AIdx].OutPos >= 1024 * 1024) and
            (FClients[AIdx].OutPos >= Length(FClients[AIdx].OutBuf) div 2) then
    begin
      Delete(FClients[AIdx].OutBuf, 1, FClients[AIdx].OutPos);
      FClients[AIdx].OutPos := 0;
    end;
  end
  else if (N < 0) and ((fpgeterrno = ESysEAGAIN) or
     (fpgeterrno = ESysEINTR)) then
    Exit
  else
    DropClient(AIdx);
end;

procedure TDetachedSession.FlushPending(AIdx: integer);
var
  Want: integer;
  N: ssize_t;
begin
  if (AIdx < 0) or (AIdx >= MAX_PENDING_CONNECTIONS) or
     (FPending[AIdx].Fd < 0) then
    Exit;
  if FPending[AIdx].OutPos >= Length(FPending[AIdx].OutBuf) then
  begin
    if FPending[AIdx].CloseAfterWrite then
      DropPending(AIdx);
    Exit;
  end;
  Want := Length(FPending[AIdx].OutBuf) - FPending[AIdx].OutPos;
  if Want > IO_BUDGET then
    Want := IO_BUDGET;
  N := FpSend(FPending[AIdx].Fd,
    @FPending[AIdx].OutBuf[FPending[AIdx].OutPos + 1], Want,
    ST_MSG_DONTWAIT);
  if N > 0 then
  begin
    Inc(FPending[AIdx].OutPos, integer(N));
    FPending[AIdx].LastProgress := GetTickCount64;
    FPending[AIdx].Deadline := GetTickCount64 + CONTROL_IDLE_TIMEOUT_MS;
    if FPending[AIdx].OutPos = Length(FPending[AIdx].OutBuf) then
    begin
      FPending[AIdx].OutBuf := '';
      FPending[AIdx].OutPos := 0;
      if FPending[AIdx].CloseAfterWrite then
        DropPending(AIdx);
    end
    else if (FPending[AIdx].OutPos >= 1024 * 1024) and
            (FPending[AIdx].OutPos >= Length(FPending[AIdx].OutBuf) div 2) then
    begin
      Delete(FPending[AIdx].OutBuf, 1, FPending[AIdx].OutPos);
      FPending[AIdx].OutPos := 0;
    end;
  end
  else if (N < 0) and ((fpgeterrno = ESysEAGAIN) or
     (fpgeterrno = ESysEINTR)) then
    Exit
  else
    DropPending(AIdx);
end;

// Change the one real PTY geometry and mirror it to every client. Attaching
// clients and their physical terminal resizes never call this routine.
procedure TDetachedSession.ApplyCanonicalResize(APane, ACols, ARows: integer;
  ANotify, AWorkersStopped: boolean);
var
  Pair: array[0..1] of Longint;
  ManageWorkers: boolean;
begin
  if (APane < 0) or (APane >= FPaneCount) then
    Exit;
  if (ACols < 4) or (ARows < 2) then
    Exit;
  // A worker parses bytes into the daemon screen before it queues the same
  // OUTPUT for clients. Quiescing and draining the pool creates one ordering
  // barrier: every result parsed with the old width is queued before the
  // resize/layout event; every later byte is parsed with the new width by
  // both daemon and clients. Callers resizing several panes stop once and
  // pass AWorkersStopped=True.
  ManageWorkers := not AWorkersStopped;
  if ManageWorkers then
    StopPaneWorkers;
  try
    LockPane(APane);
    try
      if FScreens[APane] = nil then
        Exit;
      if DebugActive then
        DebugLog(Format('resize: pane=%d canonical %dx%d (screen %dx%d)',
          [APane, ACols, ARows, FScreens[APane].Width,
           FScreens[APane].Height]));
      if (ACols = FScreens[APane].Width) and
         (ARows = FScreens[APane].Height) then
        Exit;
      FScreens[APane].Resize(ACols, ARows);
      if FPanes[APane] <> nil then
        FPanes[APane].Resize(ACols, ARows);
    finally
      UnlockPane(APane);
    end;
  finally
    if ManageWorkers then
      StartPaneWorkers;
  end;
  Pair[0] := ACols;
  Pair[1] := ARows;
  if ANotify then
    Broadcast(FRAME_RESIZE_EV, APane, Pair, SizeOf(Pair), True, -1);
end;

// A pane lock protects one window operation.  A pane=-1 request protects the
// split tree itself and all existing panes.  The explicit tree owner is
// essential for an empty desktop: an empty per-pane array cannot represent a
// lock, and two clients could otherwise both create pane zero concurrently.
// PTY input/output and focus deliberately never use these locks.
function TDetachedSession.TryLockLayout(AOwner, APane: integer;
  ABroadcast: boolean): boolean;
var
  I: integer;
  OwnerGeneration: QWord;
begin
  Result := False;
  if AOwner < 0 then
    Exit;
  OwnerGeneration := 0;
  if (AOwner < MAX_CLIENTS) and (FClients[AOwner].Fd >= 0) then
    OwnerGeneration := FClients[AOwner].Generation;
  if APane >= 0 then
  begin
    if (APane >= FPaneCount) or
       ((FLayoutTreeOwner >= 0) and (FLayoutTreeOwner <> AOwner)) or
       ((FPaneLayoutOwner[APane] >= 0) and
        (FPaneLayoutOwner[APane] <> AOwner)) then
      Exit;
    // A newly granted lease is an ordering barrier for cosmetic state, even
    // when the same client immediately begins another gesture on this pane.
    CancelLayoutPreview(APane, True);
    if (AOwner < MAX_CLIENTS) and (FClients[AOwner].Fd < 0) then
      Exit;
    FLayoutPreviews[APane] := Default(TLayoutPreviewState);
    FPaneLayoutOwner[APane] := AOwner;
    FPaneLeaseGeneration[APane] := OwnerGeneration;
    FPaneLeaseRevision[APane] := FRevision;
  end
  else
  begin
    if (FLayoutTreeOwner >= 0) and (FLayoutTreeOwner <> AOwner) then
      Exit;
    for I := 0 to FPaneCount - 1 do
      if (FPaneLayoutOwner[I] >= 0) and
         (FPaneLayoutOwner[I] <> AOwner) then
        Exit;
    // Tree mutations compact pane indexes, so no preview may survive a
    // structural lease even when all existing locks belong to this owner.
    CancelAllLayoutPreviews(True);
    if (AOwner < MAX_CLIENTS) and (FClients[AOwner].Fd < 0) then
      Exit;
    for I := 0 to MAX_PANES - 1 do
      FLayoutPreviews[I] := Default(TLayoutPreviewState);
    FLayoutTreeOwner := AOwner;
    for I := 0 to FPaneCount - 1 do
    begin
      FPaneLayoutOwner[I] := AOwner;
      FPaneLeaseGeneration[I] := OwnerGeneration;
      FPaneLeaseRevision[I] := FRevision;
    end;
  end;
  Result := True;
  if DebugFull then
    DebugLog(Format('layout-lock: acquire owner=%d pane=%d ok=1',
      [AOwner, APane]));
  if ABroadcast then
    BroadcastLayoutEv(-1);
end;

procedure TDetachedSession.ReleaseLayout(AOwner, APane: integer;
  ABroadcast: boolean);
var
  I: integer;
  Changed: boolean;
begin
  Changed := False;
  if APane >= 0 then
  begin
    // A structural lease is released atomically with pane=-1; do not allow a
    // mismatched per-pane unlock to tear only part of it down.
    if (FLayoutTreeOwner <> AOwner) and (APane < FPaneCount) and
       (FPaneLayoutOwner[APane] = AOwner) then
    begin
      if FLayoutPreviews[APane].Active and
         (FLayoutPreviews[APane].Owner = AOwner) and
         (not FLayoutPreviews[APane].TailAuthorized) then
        CancelLayoutPreview(APane, True);
      FPaneLayoutOwner[APane] := -1;
      FPaneLeaseGeneration[APane] := 0;
      FPaneLeaseRevision[APane] := 0;
      if not (FLayoutPreviews[APane].Active and
              FLayoutPreviews[APane].TailAuthorized) then
        FLayoutPreviews[APane] := Default(TLayoutPreviewState);
      Changed := True;
    end;
  end
  else
  begin
    if FLayoutTreeOwner = AOwner then
    begin
      FLayoutTreeOwner := -1;
      Changed := True;
    end;
    // Clear the complete fixed array defensively. Pane insertion/removal
    // compacts owners with panes, but a disconnect/cancel must also make an
    // old tail slot impossible to inherit when that index is reused later.
    for I := 0 to MAX_PANES - 1 do
      if FPaneLayoutOwner[I] = AOwner then
      begin
        if FLayoutPreviews[I].Active and
           (FLayoutPreviews[I].Owner = AOwner) and
           (not FLayoutPreviews[I].TailAuthorized) then
          CancelLayoutPreview(I, True);
        FPaneLayoutOwner[I] := -1;
        FPaneLeaseGeneration[I] := 0;
        FPaneLeaseRevision[I] := 0;
        if not (FLayoutPreviews[I].Active and
                FLayoutPreviews[I].TailAuthorized) then
          FLayoutPreviews[I] := Default(TLayoutPreviewState);
        Changed := True;
      end;
  end;
  if Changed then
  begin
    if DebugFull then
      DebugLog(Format('layout-lock: release owner=%d pane=%d',
        [AOwner, APane]));
    if ABroadcast then
      BroadcastLayoutEv(-1);
  end;
end;

function TDetachedSession.ClientOwnsAnyLayout(AOwner: integer): boolean;
var
  I: integer;
begin
  Result := False;
  if (AOwner < 0) or (AOwner >= MAX_CLIENTS) then
    Exit;
  if FLayoutTreeOwner = AOwner then
    Exit(True);
  for I := 0 to FPaneCount - 1 do
    if FPaneLayoutOwner[I] = AOwner then
      Exit(True);
end;

function TDetachedSession.OwnsAllLayout(AOwner: integer): boolean;
begin
  // Structural operations require the explicit global lease.  In particular,
  // zero panes must not make this true vacuously for every client.
  Result := (AOwner >= 0) and (FLayoutTreeOwner = AOwner);
end;

// serializes the layout state with the same format as FRAME_LAYOUT
function TDetachedSession.BuildLayoutBlob(AViewer: integer;
  out AData: TByteArray; APreservePanes: LongWord): boolean;
var
  Meta: TMemoryStream;
  Cnt, I, F, MinHostW, MinHostH, MatchFlag: Longint;
  Changes, LockedPanes: LongWord;
  HostSizesMatch: boolean;
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
      Meta.WriteBuffer(FGeom[I].Cols, SizeOf(Longint));
      Meta.WriteBuffer(FGeom[I].Rows, SizeOf(Longint));
      if FGeom[I].Zoomed then Flag := 1 else Flag := 0;
      Meta.WriteBuffer(Flag, SizeOf(Flag));
      if FGeom[I].Minimized then Flag := 1 else Flag := 0;
      Meta.WriteBuffer(Flag, SizeOf(Flag));
      if FGeom[I].FullScreen then Flag := 1 else Flag := 0;
      Meta.WriteBuffer(Flag, SizeOf(Flag));
    end;
    Meta.WriteBuffer(FRevision, SizeOf(FRevision));
    F := AttachedCount;
    Meta.WriteBuffer(F, SizeOf(F));
    // Ordinary authoritative events carry zero. A protocol-v15 peer event
    // uses this otherwise-idle field for the panes which its viewer currently
    // owns: the client applies every canonical peer change but keeps those
    // local gesture rectangles and its older lease-base revision intact.
    Changes := APreservePanes and LAYOUT_CHANGE_PANES;
    Meta.WriteBuffer(Changes, SizeOf(Changes));
    LockedPanes := 0;
    for I := 0 to Cnt - 1 do
      if (FPaneLayoutOwner[I] >= 0) and
         (FPaneLayoutOwner[I] <> AViewer) then
        LockedPanes := LockedPanes or (LongWord(1) shl I);
    Meta.WriteBuffer(LockedPanes, SizeOf(LockedPanes));
    ClientSizeSummary(MinHostW, MinHostH, HostSizesMatch);
    Meta.WriteBuffer(MinHostW, SizeOf(MinHostW));
    Meta.WriteBuffer(MinHostH, SizeOf(MinHostH));
    if HostSizesMatch then MatchFlag := 1 else MatchFlag := 0;
    Meta.WriteBuffer(MatchFlag, SizeOf(MatchFlag));
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
  I, J: integer;
  PreservePanes: LongWord;
  Kind: byte;
begin
  if AttachedCount = 0 then
    Exit;
  // The geometry is identical, but the lock mask is viewer-relative: owners
  // receive PEER state preserving their panes; everyone else receives the
  // ordinary canonical frame and sees the shaded busy border.
  // A lease owner cannot accept a newer global revision without invalidating
  // the older base recorded for its still-running pane gesture. Protocol v15
  // therefore sends it a peer event: other panes/focus/locks advance visually,
  // while its own pane mask and lease revision are explicitly preserved. This
  // lets several clients animate and commit different panes concurrently.
  for I := 0 to MAX_CLIENTS - 1 do
    if (I <> AExcept) and (FClients[I].Fd >= 0) and FClients[I].Ready and
       ((FClients[I].Caps and ATTACH_CAP_EVENTS) <> 0) then
    begin
      PreservePanes := 0;
      for J := 0 to FPaneCount - 1 do
        if FPaneLayoutOwner[J] = I then
          PreservePanes := PreservePanes or (LongWord(1) shl J);
      if ClientOwnsAnyLayout(I) then
        Kind := FRAME_LAYOUT_PEER_EV
      else
        Kind := FRAME_LAYOUT_EV;
      if not BuildLayoutBlob(I, Data, PreservePanes) then
        Exit;
      if Length(Data) > 0 then
        SendFrameToIdx(I, Kind, -1, Data[0], Length(Data));
    end;
end;

procedure TDetachedSession.BroadcastTitle(APane: integer; AExcept: integer);
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
    Broadcast(FRAME_TITLE_EV, APane, Data[0], Length(Data), True, AExcept);
  finally
    Meta.Free;
  end;
end;

function TDetachedSession.SendSnapshot(AIdx: integer): boolean;
var
  Meta, ScreenData: TMemoryStream;
  Data: TByteArray;
  I: integer;
  Nodes: string;
  GeomCnt, MinHostW, MinHostH, MatchFlag: Longint;
  LockedPanes: LongWord;
  HostSizesMatch: boolean;
  Flag: byte;

  function QueueSnapshotFrame(AKind: byte; APane: integer;
    const AData: TByteArray): boolean;
  var
    H: TFrameHeader;
    Frame: RawByteString;
  begin
    Result := False;
    if Length(AData) > MAX_FRAME_SIZE then
      Exit;
    H := Default(TFrameHeader);
    H.Kind := AKind;
    H.Pane := SmallInt(APane);
    H.Size := Length(AData);
    Frame := '';
    SetLength(Frame, SizeOf(H) + Length(AData));
    Move(H, Frame[1], SizeOf(H));
    if Length(AData) > 0 then
      Move(AData[0], Frame[1 + SizeOf(H)], Length(AData));
    Result := QueueOut(AIdx, Frame[1], Length(Frame), True);
  end;
begin
  Result := False;
  // Drain whatever the panes have already written but the event loop has not
  // picked up yet, so it is IN the snapshot this client is about to receive.
  //
  // Without this a pane's first output could be lost outright. PromoteToServer
  // hands the live masters to the forked daemon and the parent re-attaches at
  // once; a program that writes as it starts (a class with
  // `cmd=echo TOKEN; exec bash`) can have those bytes still sitting in the
  // master's buffer, not yet in FScreens[], when the snapshot is built. The
  // client then rebuilds its screen from a snapshot that never saw them, and
  // they are gone -- silently, with the pane otherwise working. macOS showed
  // it every time (openpty hands the slave over parent-side fds, so the child
  // runs sooner); on GNU/Linux the slower open-slave-by-name path usually let
  // the bytes land first, which is luck, not immunity.
  //
  // Safe on both counts: the master is O_NONBLOCK (st_pty.pas), so an idle
  // pane returns EAGAIN and HandlePaneOutput does nothing -- it only marks a
  // pane dead on a real EOF. The attaching client is present but not Ready,
  // so Broadcast cannot overtake its snapshot. Anything written afterwards
  // arrives normally as FRAME_OUTPUT once HandleAttach marks it Ready.
  for I := 0 to FPaneCount - 1 do
    if (FPanes[I] <> nil) and FPanes[I].Alive then
      HandlePaneOutput(I);
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
      Meta.WriteBuffer(FGeom[I].Cols, SizeOf(Longint));
      Meta.WriteBuffer(FGeom[I].Rows, SizeOf(Longint));
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
      if FGeom[I].FullScreen then
        Flag := 1
      else
        Flag := 0;
      Meta.WriteBuffer(Flag, SizeOf(Flag));
    end;
    // tolerant tail 3: daemon protocol version (a new client uses it
    // to avoid sending v2 frames to an old daemon)
    GeomCnt := ATTACH_PROTO_VER;
    Meta.WriteBuffer(GeomCnt, SizeOf(GeomCnt));
    GeomCnt := 0; // reserved: protocol v5 has one canonical geometry
    Meta.WriteBuffer(GeomCnt, SizeOf(GeomCnt));
    Meta.WriteBuffer(FRevision, SizeOf(FRevision));
    // The attaching socket is not Ready until after this snapshot, so include
    // it explicitly in the count advertised to that client.
    GeomCnt := AttachedCount + 1;
    Meta.WriteBuffer(GeomCnt, SizeOf(GeomCnt));
    LockedPanes := 0;
    for I := 0 to FPaneCount - 1 do
      if FPaneLayoutOwner[I] >= 0 then
        LockedPanes := LockedPanes or (LongWord(1) shl I);
    Meta.WriteBuffer(LockedPanes, SizeOf(LockedPanes));
    ClientSizeSummary(MinHostW, MinHostH, HostSizesMatch);
    Meta.WriteBuffer(MinHostW, SizeOf(MinHostW));
    Meta.WriteBuffer(MinHostH, SizeOf(MinHostH));
    if HostSizesMatch then MatchFlag := 1 else MatchFlag := 0;
    Meta.WriteBuffer(MatchFlag, SizeOf(MatchFlag));
    SetLength(Data, Meta.Size);
    if Meta.Size > 0 then
    begin
      Meta.Position := 0;
      Meta.ReadBuffer(Data[0], Meta.Size);
    end;
    if not QueueSnapshotFrame(FRAME_SESSION, -1, Data) then
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
      if not QueueSnapshotFrame(FRAME_SCREEN, I, Data) then
        Exit;
    finally
      ScreenData.Free;
    end;
  end;
  Data := nil;
  Result := QueueSnapshotFrame(FRAME_READY, -1, Data);
end;

// serves an attach whose first frame was already read in Run; the
// versioned payload decides the slot: empty = legacy client (protocol
// v1), which demands exclusivity as it lacks the session-sharing events
function TDetachedSession.HandleAttach(APendingIdx: integer; AFirstKind: byte;
  const AFirstData: TByteArray): boolean;
var
  ChainLen, HostW, HostH: Longint;
  Slot, I: integer;
  Ver: Longint;
  IsLegacy: boolean;
begin
  Result := False;
  if (APendingIdx < 0) or (APendingIdx >= MAX_PENDING_CONNECTIONS) or
     (FPending[APendingIdx].Fd < 0) or (AFirstKind <> FRAME_ATTACH) then
    Exit;
  ChainLen := 0;
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
    if Ver <> ATTACH_PROTO_VER then
      Exit;
  end;
  FClients[Slot] := Default(TClientConn);
  FClients[Slot].Fd := FPending[APendingIdx].Fd;
  FClients[Slot].Generation := NewConnectionGeneration;
  FClients[Slot].InBuf := FPending[APendingIdx].InBuf;
  FClients[Slot].InPos := FPending[APendingIdx].InPos;
  FClients[Slot].PeerClosed := FPending[APendingIdx].PeerClosed;
  FClients[Slot].Legacy := IsLegacy;
  FClients[Slot].LastProgress := GetTickCount64;
  // Ownership has moved to FClients; clearing the pending record must not
  // close the descriptor. Ready stays false while the point-in-time snapshot
  // is built, so broadcasts produced by draining the PTYs cannot overtake it.
  DropPending(APendingIdx, False);
  if not IsLegacy then
  begin
    HostW := 0;
    HostH := 0;
    Move(AFirstData[SizeOf(Longint)], HostW, SizeOf(HostW));
    Move(AFirstData[2 * SizeOf(Longint)], HostH, SizeOf(HostH));
    if (HostW < 1) or (HostW > MAX_SCREEN_COLS) or
       (HostH < 3) or (HostH > MAX_SCREEN_ROWS) then
    begin
      DropClient(Slot);
      Exit;
    end;
    FClients[Slot].HostW := HostW;
    FClients[Slot].HostH := HostH;
    Move(AFirstData[3 * SizeOf(Longint)], FClients[Slot].Caps,
      SizeOf(Longint));
    // tail 2: the client's own session chain (absent from older clients)
    if Length(AFirstData) >= 5 * SizeOf(Longint) then
    begin
      Move(AFirstData[4 * SizeOf(Longint)], ChainLen, SizeOf(ChainLen));
      if (ChainLen > 0) and (ChainLen <= 4096) and
         (5 * SizeOf(Longint) + ChainLen <= Length(AFirstData)) then
      begin
        SetLength(FClients[Slot].Chain, ChainLen);
        Move(AFirstData[5 * SizeOf(Longint)], FClients[Slot].Chain[1], ChainLen);
      end;
    end;
  end;
  // A worker can update TScreen and queue the same raw bytes concurrently.
  // Quiescing here gives the attaching client a true point-in-time cut: all
  // earlier results are drained before serialization and all later bytes are
  // delivered as live FRAME_OUTPUT after Ready becomes true.
  StopPaneWorkers;
  try
    if not SendSnapshot(Slot) then
    begin
      if FClients[Slot].Fd >= 0 then
        DropClient(Slot);
      Exit;
    end;
    FClients[Slot].Ready := True;
    // The point-in-time snapshot contains canonical geometry only. If an
    // existing owner is mid-gesture, append its latest cosmetic rectangle
    // after READY so the new viewer catches up without altering the snapshot.
    SendActiveLayoutPreviews(Slot);
    if FClients[Slot].Fd < 0 then
      Exit;
  finally
    StartPaneWorkers;
  end;
  // Host compatibility is independent from canonical geometry and reaches
  // existing lease owners too. The new client receives the same summary
  // after its point-in-time snapshot, preserving one ordered event stream.
  BroadcastHostSummaryEv;
  WriteSidecar;
  Result := True;
end;

// the client closed a pane: kill the process and compact mirroring the
// client (same index shifts so that INPUT stays aligned)
procedure TDetachedSession.DoKillPane(APane: integer);
var
  I: integer;
begin
  // the last pane may go too: a session with no panes is a legitimate state,
  // an empty desktop with the window manager still there. Nothing is attached
  // to it and nothing alive in it, the self-cleanup below closes it after the
  // grace period; with a client attached it simply waits for the next pane.
  if (APane < 0) or (APane >= FPaneCount) then
    Exit;
  CancelAllLayoutPreviews(True);
  StopPaneWorkers;
  try
    FLayout.ClosePane(APane);
    if FPanes[APane] <> nil then
    begin
      TrackRetiredChild(FPanes[APane].TerminateNoWait);
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
      FPaneLayoutOwner[I] := FPaneLayoutOwner[I + 1];
      FPaneLeaseGeneration[I] := FPaneLeaseGeneration[I + 1];
      FPaneLeaseRevision[I] := FPaneLeaseRevision[I + 1];
      FLayoutPreviews[I] := FLayoutPreviews[I + 1];
    end;
    FPanes[FPaneCount - 1] := nil;
    FScreens[FPaneCount - 1] := nil;
    FTitles[FPaneCount - 1] := '';
    FTerms[FPaneCount - 1] := '';
    FTitleFixed[FPaneCount - 1] := False;
    FGeom[FPaneCount - 1] := Default(TPaneGeom);
    FPaneLayoutOwner[FPaneCount - 1] := -1;
    FPaneLeaseGeneration[FPaneCount - 1] := 0;
    FPaneLeaseRevision[FPaneCount - 1] := 0;
    FLayoutPreviews[FPaneCount - 1] := Default(TLayoutPreviewState);
    Dec(FPaneCount);
    if FFocused > APane then
      Dec(FFocused);
    NormalizeFocusedPane;
  finally
    StartPaneWorkers;
  end;
  Inc(FRevision);
  WriteSidecar; // the sidecar pane count changed
end;

// Close the complete shared workspace as one structural transaction.  The
// reactor has already granted the global lease; stopping the pane workers
// once avoids sixteen stop/start cycles and no client command can observe a
// half-compacted server array. Clients receive one KILLPANE_EV with pane=-1
// and remove the whole mirror under their own suppressed visual transaction.
procedure TDetachedSession.DoKillAllPanes;
var
  I: integer;
begin
  if FPaneCount <= 0 then
    Exit;
  CancelAllLayoutPreviews(True);
  StopPaneWorkers;
  try
    for I := FPaneCount - 1 downto 0 do
    begin
      if FPanes[I] <> nil then
      begin
        TrackRetiredChild(FPanes[I].TerminateNoWait);
        FPanes[I].Free;
        FPanes[I] := nil;
      end;
      FScreens[I].Free;
      FScreens[I] := nil;
      FTitles[I] := '';
      FTitleFixed[I] := False;
      FTerms[I] := '';
      FGeom[I] := Default(TPaneGeom);
      // Keep the global owner itself until FRAME_KILLPANE's finally block,
      // but stale per-pane slots must never survive index reuse.
      FPaneLayoutOwner[I] := -1;
      FPaneLeaseGeneration[I] := 0;
      FPaneLeaseRevision[I] := 0;
      FLayoutPreviews[I] := Default(TLayoutPreviewState);
    end;
    if FLayout <> nil then
    begin
      FreeAndNil(FLayout.Root);
      FLayout.Focused := -1;
      FLayout.LastInsertedIndex := -1;
    end;
    FPaneCount := 0;
    FFocused := -1;
    FGeomValid := True;
  finally
    StartPaneWorkers;
  end;
  Inc(FRevision);
  WriteSidecar;
end;

// Apply one proposed shared desktop. The reactor serializes frames, while the
// revision prevents a client that rendered an older snapshot from overwriting
// a newer global change.
function TDetachedSession.ApplyLayoutFrame(AClient: integer;
  const Data: TByteArray;
  AAllowStale: boolean; out ABaseRevision: QWord;
  out AChanges: LongWord): boolean;
var
  Nodes: string;
  Focused, DeskW, DeskH, ClientCount, MinHostW, MinHostH: Longint;
  BaseRevision: QWord;
  Changes, AllowedPanes, LockedPanes, AutoRestoreMask: LongWord;
  Titles: TStrArray;
  Geom: TPaneGeomArray;
  NewLay: TLayout;
  I, ZoomedCount, EnteringZoomPane: integer;
  NormalizedCols, NormalizedRows: Longint;
  Changed, DesktopChanged, HostSizesMatch: boolean;
begin
  Result := False;
  ABaseRevision := 0;
  AChanges := 0;
  if not DecodeLayoutBlob(Data, Nodes, Focused, Titles, Geom, DeskW,
    DeskH, BaseRevision, ClientCount, Changes, LockedPanes,
    MinHostW, MinHostH, HostSizesMatch) then
    Exit;
  ABaseRevision := BaseRevision;
  AChanges := Changes;
  if DebugFull then
    DebugLog(Format('layout-proposal: owner=%d desk=%dx%d host-min=%dx%d ' +
      'host-match=%d mask=%x base=%d', [AClient, DeskW, DeskH, MinHostW,
      MinHostH, Ord(HostSizesMatch), Changes, BaseRevision]));
  AllowedPanes := (LongWord(1) shl FPaneCount) - 1;
  DesktopChanged := (Changes and LAYOUT_CHANGE_DESKTOP) <> 0;
  if (AClient < 0) or (AClient >= MAX_CLIENTS) or
     (FClients[AClient].Fd < 0) or
     (Length(Titles) <> FPaneCount) or (Length(Geom) <> FPaneCount) or
     ((Changes and not (LAYOUT_CHANGE_DESKTOP or LAYOUT_CHANGE_TREE or
       AllowedPanes)) <> 0) or
     ((BaseRevision <> FRevision) and (Changes = 0) and (not AAllowStale)) or
     ((not DesktopChanged) and
      ((DeskW <> FDeskW) or (DeskH <> FDeskH))) or
     (Focused < -1) or (Focused >= FPaneCount) or
     (ClientCount < 0) or (ClientCount > MAX_CLIENTS) or
     (LockedPanes <> 0) then
    Exit;
  if DesktopChanged then
  begin
    if (not OwnsAllLayout(AClient)) or (BaseRevision <> FRevision) or
       (DeskW < 8) or (DeskW > MAX_SCREEN_COLS) or
       (DeskH < 5) or (DeskH + 2 > MAX_SCREEN_ROWS) or
       (AClient < 0) or (AClient >= MAX_CLIENTS) or
       ((Changes and AllowedPanes) <> AllowedPanes) then
      Exit;
    if (DeskW <> FClients[AClient].HostW) or
       (DeskH + 2 <> FClients[AClient].HostH) then
      Exit;
  end;
  if (Changes and LAYOUT_CHANGE_TREE) <> 0 then
    if (not OwnsAllLayout(AClient)) or (BaseRevision <> FRevision) then
      Exit;
  for I := 0 to FPaneCount - 1 do
    if (Changes and (LongWord(1) shl I)) <> 0 then
      // Concurrent owners intentionally commit different panes from an older
      // global revision. Bind each changed bit to the exact revision and
      // connection generation recorded when this pane's lease was granted;
      // a malformed local peer can never reuse ownership to replay another
      // stale snapshot.
      if (FPaneLayoutOwner[I] <> AClient) or
         (FPaneLeaseGeneration[I] <> FClients[AClient].Generation) or
         (BaseRevision <> FPaneLeaseRevision[I]) then
        Exit;
  // Validate the whole proposal before changing one pane or the split tree:
  // an invalid tail can never leave a partially applied shared desktop.
  for I := 0 to FPaneCount - 1 do
    if (Changes and (LongWord(1) shl I)) <> 0 then
      if (Geom[I].Cols < 4) or (Geom[I].Cols > MAX_SCREEN_COLS) or
         (Geom[I].Rows < 2) or (Geom[I].Rows > MAX_SCREEN_ROWS) or
         (Geom[I].BW < 0) or (Geom[I].BH < 0) or
         (Geom[I].Zoomed and
          ((Geom[I].BW <= 0) or (Geom[I].BH <= 0))) or
         (Geom[I].FullScreen and (not Geom[I].Zoomed)) then
        Exit;
  // Exactly one window may own normal maximize/fullscreen. Validate the merged
  // canonical result, not merely this frame's changed subset. If two clients
  // acquired different panes from the same base and both enter zoom, their
  // FIFO commits are still meaningful: the later commit atomically restores
  // the earlier winner once its lease has been released.
  EnteringZoomPane := -1;
  for I := 0 to FPaneCount - 1 do
    if ((Changes and (LongWord(1) shl I)) <> 0) and Geom[I].Zoomed and
       (not FGeom[I].Zoomed) then
    begin
      if EnteringZoomPane >= 0 then
        Exit;
      EnteringZoomPane := I;
    end;
  AutoRestoreMask := 0;
  if EnteringZoomPane >= 0 then
    for I := 0 to FPaneCount - 1 do
      if (I <> EnteringZoomPane) and FGeom[I].Zoomed and
         ((Changes and (LongWord(1) shl I)) = 0) then
      begin
        // Never rewrite a pane while another client is still manipulating
        // it. A released earlier FIFO winner has no owner and is safe to
        // restore inside this one worker barrier.
        if (FPaneLayoutOwner[I] >= 0) and
           (FPaneLayoutOwner[I] <> AClient) then
          Exit;
        AutoRestoreMask := AutoRestoreMask or (LongWord(1) shl I);
      end;
  ZoomedCount := 0;
  for I := 0 to FPaneCount - 1 do
    if ((AutoRestoreMask and (LongWord(1) shl I)) = 0) and
       ((((Changes and (LongWord(1) shl I)) <> 0) and Geom[I].Zoomed) or
        (((Changes and (LongWord(1) shl I)) = 0) and FGeom[I].Zoomed)) then
    begin
      Inc(ZoomedCount);
      if ZoomedCount > 1 then
        Exit;
    end;
  NewLay := nil;
  if (Changes and LAYOUT_CHANGE_TREE) <> 0 then
  begin
    if not LoadLayoutString(Nodes, NewLay, True) or (NewLay = nil) then
      Exit;
    if NewLay.PaneCount <> FPaneCount then
    begin
      NewLay.Free;
      Exit;
    end;
  end;
  // Drain every worker result parsed with the old screen width before any
  // resize/layout is queued. This is one barrier for the whole transaction,
  // not one thread restart per changed pane.
  StopPaneWorkers;
  try
    Changed := False;
    if DesktopChanged then
    begin
      FDeskW := DeskW;
      FDeskH := DeskH;
      Changed := True;
    end;
    if NewLay <> nil then
    begin
      FLayout.Free;
      FLayout := NewLay;
      Changed := True;
    end;
    for I := 0 to FPaneCount - 1 do
      if (AutoRestoreMask and (LongWord(1) shl I)) <> 0 then
      begin
        FGeom[I].Zoomed := False;
        FGeom[I].FullScreen := False;
        FGeom[I].Cols := FGeom[I].BW - 2;
        FGeom[I].Rows := FGeom[I].BH - 2;
        if FGeom[I].Cols < 4 then FGeom[I].Cols := 4;
        if FGeom[I].Rows < 2 then FGeom[I].Rows := 2;
        ApplyCanonicalResize(I, FGeom[I].Cols, FGeom[I].Rows, False, True);
        Changed := True;
      end;
    // Focus normally has its own ordered FRAME_FOCUS channel. A geometry
    // proposal never overwrites a still-valid focus with an older rendered
    // snapshot. The sole exception is minimizing the currently focused pane:
    // once this transaction makes that focus invalid, its proposed fallback
    // can be accepted without an extra focus broadcast/paint. A newer valid
    // focus from another client always wins. Titles likewise remain separate
    // live metadata, so a delayed geometry frame cannot roll a rename back.
    for I := 0 to FPaneCount - 1 do
      if (Changes and (LongWord(1) shl I)) <> 0 then
      begin
        FGeom[I] := Geom[I];
        // The daemon, not the actor's possibly stale host summary, owns the
        // definitive grid for both normal maximize and fullscreen.
        if FGeom[I].Zoomed then
        begin
          SharedZoomedPaneSize(FDeskW, FDeskH, FGeom[I].FullScreen,
            NormalizedCols, NormalizedRows);
          FGeom[I].Cols := NormalizedCols;
          FGeom[I].Rows := NormalizedRows;
        end;
        // FRAME_LAYOUT_EV below carries both the terminal dimensions and the
        // final window geometry. A separate RESIZE_EV here made clients paint
        // new content inside the old rectangle before this atomic event.
        ApplyCanonicalResize(I, FGeom[I].Cols, FGeom[I].Rows, False, True);
        Changed := True;
      end;
    // Focus is shared, but it can never designate an icon. If this very
    // transaction invalidated the current focus, honor its valid fallback;
    // otherwise keep the newer ordered focus already stored by the daemon.
    if ((FFocused < 0) or (FFocused >= FPaneCount) or
        FGeom[FFocused].Minimized) and
       (Focused >= 0) and (Focused < FPaneCount) and
       (not FGeom[Focused].Minimized) then
      FFocused := Focused;
    NormalizeFocusedPane;
    if Changed then
    begin
      FGeomValid := True;
      Inc(FRevision);
    end;
  finally
    StartPaneWorkers;
  end;
  Result := True;
end;

procedure TDetachedSession.NormalizeFocusedPane;
var
  I: integer;
begin
  if FPaneCount <= 0 then
    FFocused := -1
  else if (FFocused < 0) or (FFocused >= FPaneCount) or
          FGeom[FFocused].Minimized then
  begin
    FFocused := -1;
    for I := 0 to FPaneCount - 1 do
      if not FGeom[I].Minimized then
      begin
        FFocused := I;
        Break;
      end;
  end;
  if FLayout <> nil then
    FLayout.Focused := FFocused;
end;

procedure TDetachedSession.CtlReplyErr(AFd: cint; const AMsg: string);
var
  Idx: integer;
  Data: TByteArray;
begin
  Data := nil;
  SetLength(Data, Length(AMsg));
  if Length(AMsg) > 0 then
    Move(AMsg[1], Data[0], Length(AMsg));
  Idx := PendingIndexByFd(AFd);
  if Idx >= 0 then
    QueuePending(Idx, FRAME_CTL_ERR, -1, Data);
end;

// lazy load of the window classes to resolve kind/host in LIST
procedure TDetachedSession.EnsureCtlConfig;
var
  SysClasses: TWindowClassArray;
begin
  if FCtlClassesLoaded then
    Exit;
  LoadConfig(FCtlCfg);
  LoadWindowClasses(ConfigFile, coUser, FCtlClasses);
  LoadWindowClasses(SystemConfigFile, coSystem, SysClasses);
  MergeWindowClasses(FCtlClasses, SysClasses);
  // Do not cache a partially loaded configuration if one of the readers
  // raises: a later command must be allowed to retry from a clean load.
  FCtlClassesLoaded := True;
end;

procedure TDetachedSession.CtlReplyOk(AFd: cint; const AMsg: string);
var
  Idx: integer;
  Data: TByteArray;
begin
  Data := nil;
  SetLength(Data, Length(AMsg));
  if Length(AMsg) > 0 then
    Move(AMsg[1], Data[0], Length(AMsg));
  Idx := PendingIndexByFd(AFd);
  if Idx >= 0 then
    QueuePending(Idx, FRAME_CTL_OK, -1, Data);
end;

procedure TDetachedSession.TrackRetiredChild(APid: TPid);
var
  I: integer;
  St: cint;
  Waited: TPid;
begin
  if APid <= 0 then
    Exit;
  St := 0;
  repeat
    Waited := FpWaitPid(APid, St, WNOHANG);
  until (Waited >= 0) or (FpGetErrNo <> ESysEINTR);
  if (Waited = APid) or
     ((Waited < 0) and (FpGetErrNo = ESysECHILD)) then
    Exit;
  for I := 0 to FRetiredChildCount - 1 do
    if FRetiredChildren[I] = APid then
      Exit;
  if FRetiredChildCount >= MAX_RETIRED_CHILDREN then
  begin
    // This requires hundreds of SIGKILLed children to resist scheduling for
    // several reactor passes. Fail the owned daemon closed instead of leaking
    // an unbounded PID list or returning to a potentially unsafe state.
    if DebugActive then
      DebugLog('daemon: retired child reap set exhausted');
    FStop := True;
    Exit;
  end;
  FRetiredChildren[FRetiredChildCount] := APid;
  Inc(FRetiredChildCount);
end;

// Observe each known child without reaping it first.  waitid(WNOWAIT) in
// TPty keeps the leader PID/PGID reserved while descendants are sealed; only
// then may this sole reactor call waitpid. Explicitly closed panes have
// already been removed from FPanes and are collected from the retired set.
procedure TDetachedSession.ReapChildren;
var
  St: cint;
  P, Waited: TPid;
  I, Last: integer;
begin
  St := 0;
  for I := 0 to FPaneCount - 1 do
  begin
    LockPane(I);
    try
      if (FPanes[I] <> nil) and
         FPanes[I].ExitPendingNoReap(P) then
      begin
        repeat
          Waited := FpWaitPid(P, St, WNOHANG);
        until (Waited >= 0) or (FpGetErrNo <> ESysEINTR);
        if (Waited = P) and (FPanes[I] <> nil) and
           (FPanes[I].Pid = P) then
          FPanes[I].MarkReaped;
      end;
    finally
      UnlockPane(I);
    end;
  end;
  I := 0;
  while I < FRetiredChildCount do
  begin
    P := FRetiredChildren[I];
    repeat
      Waited := FpWaitPid(P, St, WNOHANG);
    until (Waited >= 0) or (FpGetErrNo <> ESysEINTR);
    if (Waited = P) or
       ((Waited < 0) and (FpGetErrNo = ESysECHILD)) then
    begin
      Last := FRetiredChildCount - 1;
      FRetiredChildren[I] := FRetiredChildren[Last];
      FRetiredChildren[Last] := 0;
      Dec(FRetiredChildCount);
    end
    else
      Inc(I);
  end;
end;

// creates a PTY for a window class or a command, like StartPaneEx but
// without FreeVision: wcSSH -> structured argv; rest -> composed command
function TDetachedSession.SpawnPaneForSpec(const AClass, ACmd, ACwd: string;
  var ACols, ARows: integer; out APty: TPty; out ATerm: string;
  out ADefTitle: string): boolean;
var
  CIdx, ReqCols, ReqRows, OuterW, OuterH: integer;
  ShellS, CmdS, CwdS: string;
  ExecProgram, ExecSecret: string;
  ExecArgs: TStringList;
begin
  Result := False;
  APty := nil;
  ATerm := '';
  ADefTitle := '';
  // Classes can be created or edited while this daemon remains alive.  A
  // cached definition would spawn the old command/size (or reject a newly
  // added class), so pane creation deliberately reloads this small config
  // before resolving every class.  LIST keeps the ordinary lazy path.
  FCtlClassesLoaded := False;
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
  // Resolve the complete window geometry before fork/pty creation.  This is
  // the daemon equivalent of TSuperApp.NewWindowRect: class dimensions win,
  // then the global defaults, then two thirds of the canonical desktop.  The
  // first pane in an empty desktop keeps the whole desktop when both values
  // are automatic.  ACols/ARows are returned as the exact PTY interior and
  // are carried in NEWPANE_EV, so clients never need a provisional size.
  ReqCols := 0;
  ReqRows := 0;
  if CIdx >= 0 then
  begin
    ReqCols := FCtlClasses[CIdx].Cols;
    ReqRows := FCtlClasses[CIdx].Rows;
  end;
  if ReqCols <= 0 then
    ReqCols := FCtlCfg.NewWinCols;
  if ReqRows <= 0 then
    ReqRows := FCtlCfg.NewWinRows;
  if (FPaneCount = 0) and (ReqCols <= 0) and (ReqRows <= 0) then
  begin
    OuterW := FDeskW;
    OuterH := FDeskH;
  end
  else
    WantedWindowSize(ReqCols, ReqRows, FDeskW, FDeskH, OuterW, OuterH);
  ACols := OuterW - 2;
  ARows := OuterH - 2;
  if ACols < 4 then
    ACols := 4;
  if ARows < 2 then
    ARows := 2;
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
function TDetachedSession.DoNewPane(AOwner, AAt: integer; ADir: byte;
  const AClass, ACmd, ACwd, ATitle: string; out ANewIdx: integer;
  out AErr: string): boolean;
var
  Cols, Rows, L, PC: Longint;
  OldCount, j, RollbackIdx: integer;
  NewPty: TPty;
  NewScreen: TScreen;
  TermS, DefTitle, NewTitle: string;
  NewGeom: TPaneGeom;
  Meta: TMemoryStream;
  Data: TByteArray;
  DirB: byte;
  LayoutInserted, Committed: boolean;
begin
  Result := False;
  ANewIdx := -1;
  AErr := '';
  if FPaneCount >= MAX_PANES then
  begin
    AErr := 'max panes';
    Exit;
  end;
  // TPty.Spawn forks. A daemon must never fork while pane workers exist:
  // only async-signal-safe functions are valid in a multithreaded child
  // before exec, and FPC's allocator/RTL may have locks held by another
  // thread. Quiesce the pool for the complete index mutation and spawn.
  StopPaneWorkers;
  NewPty := nil;
  NewScreen := nil;
  LayoutInserted := False;
  Committed := False;
  try
    if (AAt < 0) or (AAt >= FPaneCount) then
      AAt := FFocused;
    if (AAt < 0) or (AAt >= FPaneCount) then
      AAt := 0;
    Cols := 80;
    Rows := 24;
    // SpawnPaneForSpec replaces these fallbacks with the effective
    // class/global size before the PTY is created.
    OldCount := FPaneCount;
    // An empty session is legitimate: the first pane back is a new root, not
    // a split of something.  From here until commit, every failure rolls this
    // tree mutation and any spawned child back together.
    if FPaneCount = 0 then
    begin
      if not FLayout.AddFirstPane then
      begin
        AErr := 'split failed';
        Exit;
      end;
    end
    else if ADir = 1 then
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
    LayoutInserted := True;
    TermS := '';
    DefTitle := '';
    if not SpawnPaneForSpec(AClass, ACmd, ACwd, Cols, Rows, NewPty,
      TermS, DefTitle) then
    begin
      if AClass <> '' then
        AErr := 'unknown class or spawn failed'
      else
        AErr := 'spawn failed';
      Exit;
    end;
    NewScreen := TScreen.Create(Cols, Rows, DEFAULT_SCROLLBACK);
    if ATitle <> '' then
      NewTitle := ' ' + ATitle
    else if DefTitle <> '' then
      NewTitle := ' ' + DefTitle
    else if ACmd <> '' then
      NewTitle := ' ' + ACmd
    else
      NewTitle := ' shell';
    NewGeom := Default(TPaneGeom);
    NewGeom.Cols := Cols;
    NewGeom.Rows := Rows;
    NewGeom.BW := Cols + 2;
    NewGeom.BH := Rows + 2;
    if NewGeom.BW > FDeskW then NewGeom.BW := FDeskW;
    if NewGeom.BH > FDeskH then NewGeom.BH := FDeskH;
    NewGeom.BX := (FDeskW - NewGeom.BW) div 2;
    NewGeom.BY := (FDeskH - NewGeom.BH) div 2;

    // Allocate and serialize the complete event before exposing the pane in
    // the fixed arrays.  Allocation failures therefore leave no half-pane.
    Meta := TMemoryStream.Create;
    try
      L := AAt;
      Meta.WriteBuffer(L, SizeOf(L));
      L := ANewIdx;
      Meta.WriteBuffer(L, SizeOf(L));
      PC := OldCount + 1;
      Meta.WriteBuffer(PC, SizeOf(PC));
      DirB := ADir;
      Meta.WriteBuffer(DirB, SizeOf(DirB));
      Meta.WriteBuffer(Cols, SizeOf(Cols));
      Meta.WriteBuffer(Rows, SizeOf(Rows));
      WriteString(Meta, NewTitle);
      WriteString(Meta, TermS);
      Data := nil;
      SetLength(Data, Meta.Size);
      Meta.Position := 0;
      if Meta.Size > 0 then
        Meta.ReadBuffer(Data[0], Meta.Size);
    finally
      Meta.Free;
    end;

    // Commit: all potentially allocating construction above has succeeded.
    for j := OldCount downto ANewIdx + 1 do
    begin
      FPanes[j] := FPanes[j - 1];
      FScreens[j] := FScreens[j - 1];
      FTitles[j] := FTitles[j - 1];
      FTitleFixed[j] := FTitleFixed[j - 1];
      FTerms[j] := FTerms[j - 1];
      FGeom[j] := FGeom[j - 1];
      FPaneLayoutOwner[j] := FPaneLayoutOwner[j - 1];
      FPaneLeaseGeneration[j] := FPaneLeaseGeneration[j - 1];
      FPaneLeaseRevision[j] := FPaneLeaseRevision[j - 1];
      FLayoutPreviews[j] := FLayoutPreviews[j - 1];
    end;
    FPanes[ANewIdx] := NewPty;
    NewPty := nil;
    FScreens[ANewIdx] := NewScreen;
    NewScreen := nil;
    FTerms[ANewIdx] := TermS;
    FTitles[ANewIdx] := NewTitle;
    // Match local StartPaneEx: explicit and class titles are fixed metadata,
    // not a shell cwd for the periodic title refresh to replace.
    FTitleFixed[ANewIdx] := (ATitle <> '') or (TermS <> '');
    FGeom[ANewIdx] := NewGeom;
    FPaneLayoutOwner[ANewIdx] := AOwner;
    if (AOwner >= 0) and (AOwner < MAX_CLIENTS) and
       (FClients[AOwner].Fd >= 0) then
      FPaneLeaseGeneration[ANewIdx] := FClients[AOwner].Generation
    else
      FPaneLeaseGeneration[ANewIdx] := 0;
    FPaneLeaseRevision[ANewIdx] := FRevision;
    FLayoutPreviews[ANewIdx] := Default(TLayoutPreviewState);
    Inc(FPaneCount);
    FFocused := ANewIdx;
    FGeomValid := True;
    Inc(FRevision);
    Committed := True;

    WriteSidecar;
    Broadcast(FRAME_NEWPANE_EV, ANewIdx, Data[0], Length(Data), True, -1);
    Result := True;
  finally
    try
      if not Committed then
      begin
        try
          if LayoutInserted then
          begin
            RollbackIdx := ANewIdx;
            ANewIdx := -1;
            FLayout.ClosePane(RollbackIdx);
          end;
        finally
          NewScreen.Free;
          NewPty.Free;       // destroys the newly spawned child, if any
        end;
      end;
    finally
      StartPaneWorkers;
    end;
  end;
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

// window management via control; with attached clients each change is
// broadcast as an event so they apply it live
procedure TDetachedSession.HandleWinOp(AFd: cint; APane: integer;
  const AData: TByteArray);
var
  Ofs: integer;
  Op, HowB, DirB, B0: byte;
  ClassS, CmdS, CwdS, TitleS, ErrS: string;
  NewIdx, j, N, i, k, LockTarget: integer;
  Cols, Rows: Longint;
  GC, GR, CW, CH: integer;
  Slot: st_layout.TRect;
  Rects: array[0..MAX_PANES - 1] of st_layout.TRect;
  HasLayoutLock, WasMinimized, WasZoomed, StringsValid: boolean;

  function RdStr: string;
  var
    L: Longint;
  begin
    Result := '';
    L := Default(Longint);
    if not StringsValid then
      Exit;
    if (Ofs < 0) or (Ofs > Length(AData)) then
    begin
      StringsValid := False;
      Exit;
    end;
    if Length(AData) - Ofs < SizeOf(Longint) then
    begin
      StringsValid := False;
      Exit;
    end;
    Move(AData[Ofs], L, SizeOf(L));
    Inc(Ofs, SizeOf(L));
    if (L < 0) or (L > MAX_WIRE_STRING_SIZE) then
    begin
      StringsValid := False;
      Exit;
    end;
    if L > Length(AData) - Ofs then
    begin
      StringsValid := False;
      Exit;
    end;
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
  StringsValid := True;
  B0 := 0;
  // One-shot control requests use the same per-pane slots and never wait.
  // Focus itself is lock-free; its historical "restore minimized" side
  // effect takes the target pane. Zoom/tree/organize touch every pane.
  LockTarget := -2; // no layout lock
  if Op in [WINOP_MINIMIZE, WINOP_RESTORE, WINOP_RENAME, WINOP_RESIZE] then
  begin
    if (APane >= 0) and (APane < FPaneCount) then
      LockTarget := APane;
  end
  else if (Op = WINOP_FOCUS) and (APane >= 0) and
          (APane < FPaneCount) and FGeom[APane].Minimized then
    LockTarget := APane
  else if Op in [WINOP_ZOOM, WINOP_NEWPANE, WINOP_KILL,
                 WINOP_ORGANIZE] then
    LockTarget := -1;
  HasLayoutLock := False;
  if LockTarget <> -2 then
  begin
    // A one-shot control action has no gesture for another viewer to wait on.
    // Serialize it, but publish only its settled canonical result.
    HasLayoutLock := TryLockLayout(CONTROL_LAYOUT_OWNER, LockTarget, False);
    if not HasLayoutLock then
    begin
      CtlReplyErr(AFd, 'layout busy');
      Exit;
    end;
  end;
  try
  case Op of
    WINOP_NEWPANE:
      begin
        DirB := 0;
        if Ofs < Length(AData) then
        begin
          DirB := AData[Ofs];
          Inc(Ofs);
        end;
        if Ofs = 1 then
          StringsValid := False;
        ClassS := RdStr;
        CmdS := RdStr;
        CwdS := RdStr;
        TitleS := RdStr;
        if (not StringsValid) or (Ofs <> Length(AData)) then
        begin
          CtlReplyErr(AFd, 'bad request');
          Exit;
        end;
        ErrS := '';
        NewIdx := -1;
        if DoNewPane(CONTROL_LAYOUT_OWNER, APane, DirB, ClassS, CmdS,
          CwdS, TitleS, NewIdx, ErrS) then
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
        FLayout.Focused := APane;
        // focusing restores if it was minimized
        WasMinimized := FGeom[APane].Minimized;
        FGeom[APane].Minimized := False;
        FGeomValid := True;
        if WasMinimized then
          Inc(FRevision)
        else
          Broadcast(FRAME_FOCUS_EV, APane, B0, 0, True, -1);
        CtlReplyOk(AFd, '');
      end;
    WINOP_MINIMIZE, WINOP_RESTORE, WINOP_ZOOM:
      begin
        if (APane < 0) or (APane >= FPaneCount) then
        begin
          CtlReplyErr(AFd, 'no such pane');
          Exit;
        end;
        WasZoomed := FGeom[APane].Zoomed or FGeom[APane].FullScreen;
        case Op of
          WINOP_MINIMIZE: FGeom[APane].Minimized := True;
          WINOP_RESTORE:
            begin
              FGeom[APane].Minimized := False;
              FGeom[APane].Zoomed := False;
              FGeom[APane].FullScreen := False;
              if WasZoomed then
              begin
                Cols := FGeom[APane].BW - 2;
                Rows := FGeom[APane].BH - 2;
                if Cols < 4 then Cols := 4;
                if Rows < 2 then Rows := 2;
                FGeom[APane].Cols := Cols;
                FGeom[APane].Rows := Rows;
                ApplyCanonicalResize(APane, Cols, Rows, False);
              end;
            end;
          WINOP_ZOOM:
            begin
              // Only one pane is zoomed at a time. Restore any previous
              // owner's PTY and install the target's safe shared maximum as
              // one worker barrier, matching the interactive UI path.
              StopPaneWorkers;
              try
                for j := 0 to FPaneCount - 1 do
                  if (j <> APane) and
                     (FGeom[j].Zoomed or FGeom[j].FullScreen) then
                  begin
                    FGeom[j].Zoomed := False;
                    FGeom[j].FullScreen := False;
                    Cols := FGeom[j].BW - 2;
                    Rows := FGeom[j].BH - 2;
                    if Cols < 4 then Cols := 4;
                    if Rows < 2 then Rows := 2;
                    FGeom[j].Cols := Cols;
                    FGeom[j].Rows := Rows;
                    ApplyCanonicalResize(j, Cols, Rows, False, True);
                  end;
                FGeom[APane].Zoomed := True;
                FGeom[APane].FullScreen := False;
                FGeom[APane].Minimized := False;
                FFocused := APane;
                SharedZoomedPaneSize(FDeskW, FDeskH, False, Cols, Rows);
                FGeom[APane].Cols := Cols;
                FGeom[APane].Rows := Rows;
                ApplyCanonicalResize(APane, Cols, Rows, False, True);
              finally
                StartPaneWorkers;
              end;
            end;
        end;
        NormalizeFocusedPane;
        FGeomValid := True;
        Inc(FRevision);
        if DebugActive then
          DebugLog(Format('winop: op=%d pane=%d min=%d zoom=%d focus=%d',
            [Op, APane, Ord(FGeom[APane].Minimized),
             Ord(FGeom[APane].Zoomed), FFocused]));
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
                FGeom[i].FullScreen := False;
                Inc(k);
              end;
            end;
          1:  // tile according to the split tree
            begin
              FLayout.ComputeRects(FDeskW, FDeskH, Rects);
              for i := 0 to N - 1 do
              begin
                FGeom[i].BX := Rects[i].X;
                FGeom[i].BY := Rects[i].Y;
                FGeom[i].BW := Rects[i].W - 2;
                FGeom[i].BH := Rects[i].H - 1;
                if FGeom[i].BW < MIN_WIN_W then
                  FGeom[i].BW := MIN_WIN_W;
                if FGeom[i].BH < MIN_WIN_H then
                  FGeom[i].BH := MIN_WIN_H;
                FGeom[i].Zoomed := False;
                FGeom[i].Minimized := False;
                FGeom[i].FullScreen := False;
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
            FGeom[i].FullScreen := False;
          end;
        end;
        // The terminal grid belongs to the same canonical rectangle. Resize
        // screen+PTY before broadcasting the final layout, never on attach.
        StopPaneWorkers;
        try
          for i := 0 to N - 1 do
          begin
            Cols := FGeom[i].BW - 2;
            Rows := FGeom[i].BH - 2;
            if Cols < 4 then Cols := 4;
            if Rows < 2 then Rows := 2;
            FGeom[i].Cols := Cols;
            FGeom[i].Rows := Rows;
            ApplyCanonicalResize(i, Cols, Rows, False, True);
          end;
        finally
          StartPaneWorkers;
        end;
        FGeomValid := True;
        Inc(FRevision);
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
        if (not StringsValid) or (Ofs <> Length(AData)) then
        begin
          CtlReplyErr(AFd, 'bad request');
          Exit;
        end;
        if Trim(TitleS) = '' then
        begin
          CtlReplyErr(AFd, 'empty title');
          Exit;
        end;
        FTitles[APane] := ' ' + Trim(TitleS);
        FTitleFixed[APane] := True;
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
        // A Zoomed pane's Cols/Rows define its canonical outer frame on every
        // viewer. Resizing only the PTY would manufacture a second meaning for
        // those fields and make a later attach draw different bounds. Restore
        // first, then an explicit PTY resize remains unambiguous.
        if FGeom[APane].Zoomed or FGeom[APane].FullScreen then
        begin
          CtlReplyErr(AFd, 'restore pane before resize');
          Exit;
        end;
        ApplyCanonicalResize(APane, Cols, Rows, False);
        FGeom[APane].Cols := Cols;
        FGeom[APane].Rows := Rows;
        Inc(FRevision);
        CtlReplyOk(AFd, '');
      end;
  else
    CtlReplyErr(AFd, 'unknown operation');
  end;
  finally
    if HasLayoutLock then
    begin
      // End a one-shot control action exactly like a UI layout commit: remove
      // ownership silently and publish one settled canonical state. The only
      // earlier layout event was the intentional busy border from TryLock.
      ReleaseLayout(CONTROL_LAYOUT_OWNER, LockTarget, False);
      BroadcastLayoutEv(-1);
    end;
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
  I, CIdx, PIdx: integer;
  S: RawByteString;
  Mode, N: Longint;
  Scr: TScreen;
  From, Count, Sent, Take: integer;
  KindB: byte;
  Host, User, LiveCmd, LiveCwd: string;
begin
  PIdx := PendingIndexByFd(AFd);
  if PIdx < 0 then
    Exit;
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
              LockPane(I);
              try
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
              finally
                UnlockPane(I);
              end;
            end;
          Data := nil;
          SetLength(Data, Meta.Size);
          if Meta.Size > 0 then
          begin
            Meta.Position := 0;
            Meta.ReadBuffer(Data[0], Meta.Size);
          end;
          if QueuePending(PIdx, FRAME_CTL_DATA, -1, Data) then
          begin
            Data := nil;
            QueuePending(PIdx, FRAME_CTL_END, -1, Data);
          end;
        finally
          Meta.Free;
        end;
      end;
    FRAME_CTL_SEND:
      begin
        if (APane < 0) or (APane >= FPaneCount) then
        begin
          CtlReplyErr(AFd, 'no such pane');
          Exit;
        end;
        LockPane(APane);
        try
          if (FPanes[APane] = nil) or (not FPanes[APane].Alive) then
          begin
            CtlReplyErr(AFd, 'no such pane');
            Exit;
          end;
          if Length(AData) > 0 then
          begin
            SetString(S, PAnsiChar(@AData[0]), Length(AData));
            if not FPanes[APane].WriteStr(S) then
            begin
              CtlReplyErr(AFd, 'pane is not reading its input');
              Exit;
            end;
          end;
        finally
          UnlockPane(APane);
        end;
        Data := nil;
        QueuePending(PIdx, FRAME_CTL_OK, APane, Data);
      end;
    FRAME_CTL_CAPTURE:
      begin
        if (APane < 0) or (APane >= FPaneCount) or
           (FScreens[APane] = nil) then
        begin
          CtlReplyErr(AFd, 'no such pane');
          Exit;
        end;
        LockPane(APane);
        try
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
        // Render in bounded working batches. The non-blocking reply queue owns
        // completed chunks and has its own hard cap.
        Meta := TMemoryStream.Create;
        try
          Sent := 0;
          while Sent < Count do
          begin
            Take := 512;   // rows per batch
            if Sent + Take > Count then
              Take := Count - Sent;
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
              if not QueuePending(PIdx, FRAME_CTL_DATA, APane, Data) then
                Exit;
              Meta.Clear;
            end;
          end;
          Data := nil;
          QueuePending(PIdx, FRAME_CTL_END, APane, Data);
        finally
          Meta.Free;
        end;
        finally
          UnlockPane(APane);
        end;
      end;
    FRAME_CTL_WINOP:
      HandleWinOp(AFd, APane, AData);
  end;
end;

procedure TDetachedSession.HandlePendingFrame(AIdx: integer; AKind: byte;
  APane: integer; const AData: TByteArray);
var
  Fd: cint;
begin
  if (AIdx < 0) or (AIdx >= MAX_PENDING_CONNECTIONS) or
     (FPending[AIdx].Fd < 0) then
    Exit;
  Fd := FPending[AIdx].Fd;
  case AKind of
    FRAME_CLOSE:
      begin
        DropPending(AIdx);
        FStop := True;
      end;
    FRAME_ATTACH:
      if not HandleAttach(AIdx, AKind, AData) then
        DropPending(AIdx);
    FRAME_CTL_LIST..FRAME_CTL_INFO:
      begin
        HandleControlFrame(Fd, AKind, APane, AData);
        if (FPending[AIdx].Fd = Fd) then
        begin
          FPending[AIdx].CloseAfterWrite := True;
          FPending[AIdx].Deadline := GetTickCount64 + CONTROL_IDLE_TIMEOUT_MS;
          if FPending[AIdx].OutBuf = '' then
            DropPending(AIdx);
        end;
      end;
  else
    DropPending(AIdx);
  end;
end;

procedure TDetachedSession.HandleClientFrame(AIdx: integer; AKind: byte;
  APane: integer; const AData: TByteArray);
var
  Cols, Rows, ClientCount, I: integer;
  S: RawByteString;
  Ofs, NewIdx: integer;
  DirB, B0, ReplyKind: byte;
  CanLock, Applied, ValidLockRequest, StringsValid, PreviewExpired: boolean;
  RequestId, BaseRevision: QWord;
  ChangeMask, PreserveMask: LongWord;
  ReplyData, CurrentLayout: TByteArray;
  ClassS, CmdS, CwdS, TitleS, ErrS: string;

  function RdStr: string;
  var
    L: Longint;
  begin
    Result := '';
    L := Default(Longint);
    if not StringsValid then
      Exit;
    if (Ofs < 0) or (Ofs > Length(AData)) then
    begin
      StringsValid := False;
      Exit;
    end;
    if Length(AData) - Ofs < SizeOf(Longint) then
    begin
      StringsValid := False;
      Exit;
    end;
    Move(AData[Ofs], L, SizeOf(L));
    Inc(Ofs, SizeOf(L));
    if (L < 0) or (L > MAX_WIRE_STRING_SIZE) then
    begin
      StringsValid := False;
      Exit;
    end;
    if L > Length(AData) - Ofs then
    begin
      StringsValid := False;
      Exit;
    end;
    SetLength(Result, L);
    if L > 0 then
      Move(AData[Ofs], Result[1], L);
    Inc(Ofs, L);
  end;

begin
  B0 := 0;
  StringsValid := True;
  ReplyData := nil;
  CurrentLayout := nil;
  if DebugFull then
    DebugLog(Format('daemon: client frame owner=%d kind=%d pane=%d bytes=%d',
      [AIdx, AKind, APane, Length(AData)]));
  case AKind of
    FRAME_INPUT:
      if (APane >= 0) and (APane < FPaneCount) and
         (Length(AData) > 0) then
      begin
        SetString(S, PAnsiChar(@AData[0]), Length(AData));
        LockPane(APane);
        try
          if FPanes[APane] <> nil then
            FPanes[APane].WriteStr(S);
        finally
          UnlockPane(APane);
        end;
      end;
    FRAME_RESIZE:
      if (APane >= 0) and (APane < FPaneCount) and
         (Length(AData) = 8) and
         (FClients[AIdx].Legacy or
          (FPaneLayoutOwner[APane] = AIdx)) then
      begin
        Cols := Default(integer);
        Rows := Default(integer);
        Move(AData[0], Cols, SizeOf(Cols));
        Move(AData[4], Rows, SizeOf(Rows));
        if (Cols > 0) and (Rows > 0) then
        begin
          if FClients[AIdx].Legacy then
          begin
            // protocol v1: a single client rules, apply directly
            LockPane(APane);
            try
              if FScreens[APane] <> nil then
                FScreens[APane].Resize(Cols, Rows);
              if FPanes[APane] <> nil then
                FPanes[APane].Resize(Cols, Rows);
            finally
              UnlockPane(APane);
            end;
          end
          else if not (FGeom[APane].Zoomed or
                       FGeom[APane].FullScreen) then
          begin
            CancelLayoutPreview(APane, True);
            ApplyCanonicalResize(APane, Cols, Rows);
            FGeom[APane].Cols := Cols;
            FGeom[APane].Rows := Rows;
            Inc(FRevision);
            BroadcastLayoutEv(-1);
          end;
        end;
      end;
    FRAME_CLIENT_SIZE:
      if Length(AData) = 2 * SizeOf(Longint) then
      begin
        Cols := 0;
        Rows := 0;
        Move(AData[0], Cols, SizeOf(Cols));
        Move(AData[SizeOf(Longint)], Rows, SizeOf(Rows));
        if (Cols >= 1) and (Cols <= MAX_SCREEN_COLS) and
           (Rows >= 3) and (Rows <= MAX_SCREEN_ROWS) then
        begin
          // Metadata only: it never changes canonical window geometry. The
          // dedicated event reaches lease owners as well as ordinary viewers.
          FClients[AIdx].HostW := Cols;
          FClients[AIdx].HostH := Rows;
          if DebugFull then
            DebugLog(Format('client-size: owner=%d host=%dx%d',
              [AIdx, Cols, Rows]));
          BroadcastHostSummaryEv;
        end;
      end;
    FRAME_DETACH:
      DropClient(AIdx);
    FRAME_CLOSE:
      begin
        // An interactive close belongs to the client that sent it. Keep the
        // shared session alive while another UI is still attached; when this
        // is the last UI, preserve the traditional permanent-exit behaviour.
        // Frames are handled serially, so two simultaneous closes naturally
        // make the second one the last client.
        ClientCount := AttachedCount;
        if DebugActive then
          DebugLog(Format('daemon: client exit attached=%d last=%d',
            [ClientCount, Ord(ClientCount <= 1)]));
        DropClient(AIdx);
        if ClientCount <= 1 then
          FStop := True;
      end;
    FRAME_LAYOUT_LOCK:
      begin
        RequestId := 0;
        BaseRevision := 0;
        ValidLockRequest := (Length(AData) = 2 * SizeOf(QWord)) and
          ((APane = -1) or ((APane >= 0) and (APane < FPaneCount)));
        if ValidLockRequest then
        begin
          Move(AData[0], RequestId, SizeOf(RequestId));
          Move(AData[SizeOf(RequestId)], BaseRevision,
            SizeOf(BaseRevision));
          ValidLockRequest := RequestId <> 0;
        end;
        CanLock := False;
        if ValidLockRequest then
          if BaseRevision = FRevision then
            CanLock := TryLockLayout(AIdx, APane);
        // Put an authoritative state before every denial. LockLayout queues
        // it while waiting for this reply, so the losing UI can catch up in
        // its next ordinary event batch without ever mutating stale pixels.
        if not CanLock then
        begin
          CurrentLayout := nil;
          PreserveMask := 0;
          for I := 0 to FPaneCount - 1 do
            if FPaneLayoutOwner[I] = AIdx then
              PreserveMask := PreserveMask or (LongWord(1) shl I);
          if ClientOwnsAnyLayout(AIdx) then
            ReplyKind := FRAME_LAYOUT_PEER_EV
          else
            ReplyKind := FRAME_LAYOUT_EV;
          if BuildLayoutBlob(AIdx, CurrentLayout, PreserveMask) and
             (Length(CurrentLayout) > 0) then
            SendFrameToIdx(AIdx, ReplyKind, -1, CurrentLayout[0],
              Length(CurrentLayout));
        end;
        SetLength(ReplyData, 2 * SizeOf(QWord) + 1);
        Move(RequestId, ReplyData[0], SizeOf(RequestId));
        ReplyData[SizeOf(RequestId)] := Ord(CanLock);
        Move(FRevision, ReplyData[SizeOf(RequestId) + 1],
          SizeOf(FRevision));
        SendFrameToIdx(AIdx, FRAME_LAYOUT_LOCK_REPLY, APane, ReplyData[0],
          Length(ReplyData));
        if DebugFull and (not CanLock) then
          DebugLog(Format(
            'layout-lock: acquire owner=%d request=%d pane=%d base=%d current=%d ok=0',
            [AIdx, RequestId, APane, BaseRevision, FRevision]));
      end;
    FRAME_LAYOUT_UNLOCK:
      ReleaseLayout(AIdx, APane);
    FRAME_LAYOUT_PREVIEW:
      HandleLayoutPreview(AIdx, APane, AData);
    FRAME_KILLPANE:
      begin
        if APane = -1 then
          // Close all has no speculative client mutation and is safe at any
          // revision. Claim the global lease here in FIFO order without a
          // transient lock paint; slow interactive gestures still use the
          // ordinary visible FRAME_LAYOUT_LOCK path.
          Applied := TryLockLayout(AIdx, -1, False)
        else
          Applied := OwnsAllLayout(AIdx) and
            (APane >= 0) and (APane < FPaneCount);
        try
          if Applied and (APane = -1) then
          begin
            DoKillAllPanes;
            // Include the actor: unlike a single close, Close all performs no
            // speculative local mutation before the daemon replies. One
            // event also makes it impossible for a client's 32-frame drain
            // budget to expose a half-closed workspace.
            Broadcast(FRAME_KILLPANE_EV, -1, B0, 0, True, -1);
          end
          else if Applied then
          begin
            DoKillPane(APane);
            Broadcast(FRAME_KILLPANE_EV, APane, B0, 0, True, AIdx);
          end;
        finally
          // KILL consumes its global lease. The specialized event and this
          // settled canonical snapshot are adjacent; no successful UNLOCK
          // frame or intermediate locked geometry exists.
          if (APane <> -1) or Applied then
            ReleaseLayout(AIdx, -1, False);
        end;
        if (APane = -1) and (not Applied) then
        begin
          ErrS := 'layout busy';
          SendFrameToIdx(AIdx, FRAME_ERROR, -1, ErrS[1], Length(ErrS));
        end;
        BroadcastLayoutEv(-1);
      end;
    FRAME_LAYOUT:
      begin
        BaseRevision := 0;
        ChangeMask := 0;
        try
          Applied := ApplyLayoutFrame(AIdx, AData, False, BaseRevision,
            ChangeMask);
          if Applied then
            AuthorizeLayoutPreviewTails(AIdx, BaseRevision, ChangeMask);
        finally
          // This is the atomic end of the visual transaction.  Even a parser,
          // allocation or resize exception must not strand the sender's
          // lease and permanently lock the pane for every other client.
          ReleaseLayout(AIdx, -1, False);
        end;
        // A tail is valid only at the exact revision produced by its own
        // commit. Any other canonical commit invalidates and clears it.
        PreviewExpired := ExpireLayoutPreviews;
        if PreviewExpired and DebugFull then
          DebugLog('layout-preview: stale tail cleared by canonical commit');
        if DebugFull then
          DebugLog(Format('layout-commit: owner=%d applied=%d revision=%d',
            [AIdx, Ord(Applied), FRevision]));
        BroadcastLayoutEv(-1);
      end;
    FRAME_NEWPANE:
      begin
        // Creation is entirely daemon-authoritative: claim and release the
        // structural lease inside this one serialized command.  This works
        // identically with 0..15 existing panes and gives a real lock even
        // when there are no per-pane slots yet.
        Applied := False;
        CanLock := False;
        ErrS := '';
        Ofs := 0;
        BaseRevision := 0;
        if Length(AData) < SizeOf(BaseRevision) + SizeOf(DirB) then
          ErrS := 'invalid new pane'
        else
        begin
          Move(AData[Ofs], BaseRevision, SizeOf(BaseRevision));
          Inc(Ofs, SizeOf(BaseRevision));
          DirB := AData[Ofs];
          Inc(Ofs);
          ClassS := RdStr;
          CmdS := RdStr;
          CwdS := RdStr;
          TitleS := RdStr;
          if (not StringsValid) or (Ofs <> Length(AData)) then
            ErrS := 'invalid new pane'
          else if FPaneCount >= MAX_PANES then
            ErrS := 'max panes'
          else if (APane >= 0) and (BaseRevision <> FRevision) then
            ErrS := 'layout changed'
          else if (APane < -1) or (APane >= FPaneCount) then
            ErrS := 'layout changed'
          else
            // Creation is an atomic FIFO command, not a held gesture. Keep
            // its structural lease real but invisible and publish only the
            // NEWPANE_EV plus the settled canonical layout.
            CanLock := TryLockLayout(AIdx, -1, False);
        end;
        if (ErrS = '') and (not CanLock) then
          ErrS := 'layout busy';
        try
          if CanLock then
          begin
            NewIdx := -1;
            Applied := DoNewPane(AIdx, APane, DirB, ClassS, CmdS, CwdS,
              TitleS, NewIdx, ErrS);
          end;
        finally
          if CanLock then
            ReleaseLayout(AIdx, -1, False);
        end;
        if ErrS <> '' then
          SendFrameToIdx(AIdx, FRAME_ERROR, -1, ErrS[1], Length(ErrS));
        BroadcastLayoutEv(-1);
      end;
    FRAME_FOCUS:
      if (APane >= 0) and (APane < FPaneCount) and
         ((not FGeom[APane].Minimized) or
          (FPaneLayoutOwner[APane] = AIdx)) then
      begin
        FFocused := APane;
        FLayout.Focused := APane;
        // A restore owns this pane before its geometry commit. Record its
        // definitive focus now so the final layout snapshot contains it, but
        // do not ask observers to focus an icon. They receive it atomically
        // with the restore. An ordinary visible focus remains its own
        // lock-free event.
        if not FGeom[APane].Minimized then
          Broadcast(FRAME_FOCUS_EV, APane, B0, 0, True, -1);
      end;
    FRAME_RENAME:
      begin
        Applied := (APane >= 0) and (APane < FPaneCount) and
          (FPaneLayoutOwner[APane] = AIdx);
        try
          if Applied then
          begin
            Ofs := 0;
            StringsValid := True;
            TitleS := RdStr;
            if StringsValid and (Ofs = Length(AData)) and
               (Trim(TitleS) <> '') then
            begin
              FTitles[APane] := ' ' + Trim(TitleS);
              FTitleFixed[APane] := True;
            end;
          end;
        finally
          ReleaseLayout(AIdx, -1, False);
        end;
        BroadcastLayoutEv(-1);
      end;
  end;
end;

constructor TPanePollWorker.Create(AOwner: TDetachedSession;
  AWorkerIndex: integer; const APaneIndexes: array of integer);
var
  I: integer;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
  FWorkerIndex := AWorkerIndex;
  FWakePipe[0] := -1;
  FWakePipe[1] := -1;
  FPaneCount := Length(APaneIndexes);
  if FPaneCount > MAX_PANES then
    FPaneCount := MAX_PANES;
  for I := 0 to FPaneCount - 1 do
    FPaneIndexes[I] := APaneIndexes[I];
  if FpPipe(FWakePipe) <> 0 then
    raise Exception.Create('cannot create pane-worker wake pipe');
  SetCloExec(FWakePipe[0]);
  SetCloExec(FWakePipe[1]);
  SetNonBlocking(FWakePipe[0]);
  SetNonBlocking(FWakePipe[1]);
end;

destructor TPanePollWorker.Destroy;
begin
  if FWakePipe[0] >= 0 then
    FpClose(FWakePipe[0]);
  if FWakePipe[1] >= 0 then
    FpClose(FWakePipe[1]);
  inherited Destroy;
end;

procedure TPanePollWorker.Wake;
begin
  PipeWriteByte(FWakePipe[1], 1);
end;

procedure TPanePollWorker.RequestStop;
begin
  Terminate;
  Wake;
end;

procedure TPanePollWorker.Execute;
var
  Poller: TSuperPoll;
  Ready: TPollReadyArray;
  Ev: TPollReady;
  I, J, Pane, Fd, N, Fails: integer;
  WantWrite, Alive: boolean;
  Kind: byte;
  Data: TByteArray;
begin
  TThread.NameThreadForDebugging('st-pane-' + IntToStr(FWorkerIndex));
  Poller := TSuperPoll.Create;
  Fails := 0;
  try
    while not Terminated do
    begin
      try
        Poller.Clear;
        Poller.Watch(FWakePipe[0], psWorker, FWorkerIndex, True, False);
        for I := 0 to FPaneCount - 1 do
        begin
          Pane := FPaneIndexes[I];
          Fd := -1;
          WantWrite := False;
          Alive := False;
          FOwner.LockPane(Pane);
          try
            if (Pane >= 0) and (Pane < FOwner.FPaneCount) and
               (FOwner.FPanes[Pane] <> nil) and
               FOwner.FPanes[Pane].Alive then
            begin
              Alive := True;
              Fd := FOwner.FPanes[Pane].Master;
              WantWrite := FOwner.FPanes[Pane].InputPending;
            end;
          finally
            FOwner.UnlockPane(Pane);
          end;
          if Alive and (Fd >= 0) then
            Poller.Watch(Fd, psPane, Pane, True, WantWrite);
        end;
        N := Poller.Wait(POLL_TICK_MS, Ready);
        if N < 0 then
        begin
          if fpgeterrno = ESysEINTR then
            Continue;
          raise Exception.Create('pane worker poll failed: errno ' +
            IntToStr(fpgeterrno));
        end;
        for J := 0 to High(Ready) do
        begin
          Ev := Ready[J];
          if Ev.Source = psWorker then
          begin
            DrainPipe(FWakePipe[0]);
            if Terminated then
              Break;
          end
          else if Ev.Source = psPane then
          begin
            Pane := Ev.Index;
            if Ev.Writable then
            begin
              FOwner.LockPane(Pane);
              try
                if (Pane >= 0) and (Pane < FOwner.FPaneCount) and
                   (FOwner.FPanes[Pane] <> nil) and
                   FOwner.FPanes[Pane].Alive then
                  FOwner.FPanes[Pane].FlushInput;
              finally
                FOwner.UnlockPane(Pane);
              end;
            end;
            if Ev.Readable or Ev.Error or Ev.Hangup then
              if FOwner.ReadPaneEvent(Pane, Kind, Data) then
                FOwner.QueueWorkerResult(Kind, Pane, Data);
          end;
        end;
        Fails := 0;
      except
        on E: Exception do
        begin
          Inc(Fails);
          if DebugActive then
            DebugLog(Format('daemon: pane reactor %d exception (%d): %s: %s',
              [FWorkerIndex, Fails, E.ClassName, E.Message]));
          if Fails > 50 then
            Break;
        end;
      end;
    end;
  finally
    Poller.Free;
  end;
end;

procedure TDetachedSession.LockPane(APane: integer);
begin
  if (APane >= 0) and (APane < MAX_PANES) then
    EnterCriticalSection(FPaneLocks[APane]);
end;

procedure TDetachedSession.UnlockPane(APane: integer);
begin
  if (APane >= 0) and (APane < MAX_PANES) then
    LeaveCriticalSection(FPaneLocks[APane]);
end;

function TDetachedSession.QueueWorkerResult(AKind: byte; APane: integer;
  const AData: TByteArray): boolean;
var
  Slot, DataSize: integer;
  Queued: boolean;
  DataCopy: TByteArray;
begin
  Result := False;
  if (FWorkerResultPipe[1] < 0) or (FWorkerResultSpace = nil) then
    Exit;
  DataCopy := Copy(AData, 0, Length(AData));
  DataSize := Length(DataCopy);
  repeat
    Queued := False;
    EnterCriticalSection(FWorkerResultLock);
    try
      if (FWorkerResultCount < WORKER_RESULT_SLOTS) and
         (FWorkerResultBytes + DataSize <= MAX_WORKER_RESULT_BYTES) then
      begin
        Slot := (FWorkerResultHead + FWorkerResultCount) mod
          WORKER_RESULT_SLOTS;
        FWorkerResults[Slot].Kind := AKind;
        FWorkerResults[Slot].Pane := APane;
        FWorkerResults[Slot].Data := DataCopy;
        Inc(FWorkerResultCount);
        Inc(FWorkerResultBytes, DataSize);
        Queued := True;
      end
      else
        RTLEventResetEvent(FWorkerResultSpace);
    finally
      LeaveCriticalSection(FWorkerResultLock);
    end;
    if not Queued then
      RTLEventWaitFor(FWorkerResultSpace, POLL_TICK_MS);
  until Queued;
  PipeWriteByte(FWorkerResultPipe[1], 1);
  Result := True;
end;

procedure TDetachedSession.DrainWorkerResults;
var
  R: TWorkerResult;
  B0: byte;
  Have: boolean;
begin
  DrainPipe(FWorkerResultPipe[0]);
  repeat
    R := Default(TWorkerResult);
    Have := False;
    EnterCriticalSection(FWorkerResultLock);
    try
      if FWorkerResultCount > 0 then
      begin
        R := FWorkerResults[FWorkerResultHead];
        FWorkerResults[FWorkerResultHead].Data := nil;
        FWorkerResultHead := (FWorkerResultHead + 1) mod WORKER_RESULT_SLOTS;
        Dec(FWorkerResultCount);
        Dec(FWorkerResultBytes, Length(R.Data));
        Have := True;
        RTLEventSetEvent(FWorkerResultSpace);
      end;
    finally
      LeaveCriticalSection(FWorkerResultLock);
    end;
    if Have then
    begin
      B0 := 0;
      if Length(R.Data) > 0 then
        Broadcast(R.Kind, R.Pane, R.Data[0], Length(R.Data), False, -1)
      else
        Broadcast(R.Kind, R.Pane, B0, 0, False, -1);
      R.Data := nil;
    end;
  until not Have;
end;

function TDetachedSession.WantedWorkerCount: integer;
begin
  if FThreadLimit <= 1 then
    Exit(0);
  Result := FPaneCount;
  if Result > FThreadLimit - 1 then
    Result := FThreadLimit - 1;
  if Result < 0 then
    Result := 0;
end;

procedure TDetachedSession.StartPaneWorkers;
var
  Wanted, W, I, C: integer;
  Assigned: array of integer;
begin
  if FWorkerCount <> 0 then
    Exit;
  Assigned := nil;
  Wanted := WantedWorkerCount;
  if Wanted = 0 then
  begin
    if DebugActive then
      DebugLog(Format('daemon: multithread=%s cpus=%d effective=1',
        [MultiThreadCode(FConfiguredThreads), FAvailableCPUs]));
    Exit;
  end;
  try
    for W := 0 to Wanted - 1 do
    begin
      C := 0;
      SetLength(Assigned, 0);
      for I := 0 to FPaneCount - 1 do
        if (I mod Wanted) = W then
        begin
          SetLength(Assigned, C + 1);
          Assigned[C] := I;
          Inc(C);
        end;
      FWorkers[W] := TPanePollWorker.Create(Self, W, Assigned);
      Inc(FWorkerCount);
      FWorkers[W].Start;
      if DebugActive then
        DebugLog(Format('daemon: pane reactor %d started with %d pane(s)',
          [W, C]));
    end;
  except
    on E: Exception do
    begin
      if DebugActive then
        DebugLog('daemon: cannot start pane reactors; falling back to one ' +
          'thread: ' + E.Message);
      StopPaneWorkers;
      FThreadLimit := 1;
    end;
  end;
  SetLength(Assigned, 0);
  if FListener >= 0 then
    WriteSidecar;
end;

procedure TDetachedSession.StopPaneWorkers;
var
  I: integer;
  AllFinished: boolean;
begin
  if FWorkerCount = 0 then
    Exit;
  for I := 0 to FWorkerCount - 1 do
    if FWorkers[I] <> nil then
      FWorkers[I].RequestStop;
  if FWorkerResultSpace <> nil then
    RTLEventSetEvent(FWorkerResultSpace);
  repeat
    DrainWorkerResults;
    AllFinished := True;
    for I := 0 to FWorkerCount - 1 do
      if (FWorkers[I] <> nil) and (not FWorkers[I].Finished) then
      begin
        AllFinished := False;
        Break;
      end;
    if not AllFinished then
      Sleep(1);
  until AllFinished;
  DrainWorkerResults;
  for I := 0 to FWorkerCount - 1 do
    if FWorkers[I] <> nil then
    begin
      FWorkers[I].WaitFor;
      FreeAndNil(FWorkers[I]);
    end;
  if DebugActive then
    DebugLog('daemon: pane reactors stopped');
  FWorkerCount := 0;
  if FListener >= 0 then
    WriteSidecar;
end;

procedure TDetachedSession.CheckPaneWorkers;
var
  I: integer;
begin
  for I := 0 to FWorkerCount - 1 do
    if (FWorkers[I] = nil) or FWorkers[I].Finished then
    begin
      if DebugActive then
        DebugLog(Format('daemon: pane reactor %d stopped unexpectedly; ' +
          'falling back to the single reactor', [I]));
      StopPaneWorkers;
      FThreadLimit := 1;
      WriteSidecar;
      Exit;
    end;
end;

function TDetachedSession.ReadPaneEvent(APane: integer; out AKind: byte;
  out AData: TByteArray): boolean;
var
  Buf: array[0..MAXREAD - 1] of byte;
  N: integer;
  OscSelection, OscPayload: RawByteString;
begin
  Result := False;
  AKind := 0;
  AData := nil;
  LockPane(APane);
  try
    if (APane < 0) or (APane >= FPaneCount) or (FPanes[APane] = nil) or
       (not FPanes[APane].Alive) then
      Exit;
    N := FPanes[APane].ReadBuf(Buf);
    if N > 0 then
    begin
      if FScreens[APane] <> nil then
      begin
        FScreens[APane].WriteBytes(Buf, N);
        // Clipboard ownership belongs to each attached UI client and its host
        // terminal. The daemon parses the same bytes for snapshots but must
        // not retain client-only OSC 52 events.
        OscSelection := '';
        OscPayload := '';
        while FScreens[APane].TakeOsc52(OscSelection, OscPayload) do ;
      end;
      SetLength(AData, N);
      Move(Buf[0], AData[0], N);
      AKind := FRAME_OUTPUT;
      Result := True;
    end
    else if (N = 0) or (fpgeterrno <> ESysEAGAIN) then
    begin
      FPanes[APane].MarkDead;
      AKind := FRAME_EXIT;
      Result := True;
    end;
  finally
    UnlockPane(APane);
  end;
end;

procedure TDetachedSession.HandlePaneOutput(APane: integer);
var
  Kind: byte;
  Data: TByteArray;
  B0: byte;
begin
  if not ReadPaneEvent(APane, Kind, Data) then
    Exit;
  B0 := 0;
  if Length(Data) > 0 then
    Broadcast(Kind, APane, Data[0], Length(Data), False, -1)
  else
    Broadcast(Kind, APane, B0, 0, False, -1);
end;

// metadata sidecar: lets the selector show name/profile/panes
// without consuming the socket's single client slot
// every session id some attached client runs inside of, ':'-joined
function TDetachedSession.ClientChainsUnion: string;
var
  I, P: integer;
  Rest, Item: string;
begin
  Result := '';
  for I := 0 to MAX_CLIENTS - 1 do
    if (FClients[I].Fd >= 0) and (FClients[I].Chain <> '') then
    begin
      Rest := FClients[I].Chain;
      while Rest <> '' do
      begin
        P := Pos(':', Rest);
        if P = 0 then P := Length(Rest) + 1;
        Item := Copy(Rest, 1, P - 1);
        Delete(Rest, 1, P);
        if (Item <> '') and (Pos(':' + Item + ':', ':' + Result + ':') = 0) then
        begin
          if Result <> '' then Result := Result + ':';
          Result := Result + Item;
        end;
      end;
    end;
end;

procedure TDetachedSession.WriteSidecar;
var
  Ini: TIniFile;
  TempPath: string;
begin
  Ini := nil;
  TempPath := FMetaPath + '.tmp.' + IntToStr(fpGetPid);
  try
    if FileExists(TempPath) then
      DeleteFile(TempPath);
    Ini := TIniFile.Create(TempPath);
    try
      // FPC's TIniFile otherwise calls UpdateFile after every Write*. Cache
      // the fields and materialize one complete private inode instead.
      Ini.CacheUpdates := True;
      Ini.WriteString('session', 'name', IniQuoteGuard(FName));
      Ini.WriteString('session', 'profile', IniQuoteGuard(FProfile));
      Ini.WriteInteger('session', 'panes', FPaneCount);
      Ini.WriteInteger('session', 'attached', AttachedCount);
      Ini.WriteInteger('session', 'pid', fpGetPid);
      Ini.WriteString('session', 'pid_identity', FPidIdentity);
      Ini.WriteInteger('session', 'cpus', FAvailableCPUs);
      Ini.WriteInteger('session', 'thread_limit', FThreadLimit);
      Ini.WriteInteger('session', 'threads', 1 + FWorkerCount);
      Ini.WriteString('session', 'multithread',
        MultiThreadCode(FConfiguredThreads));
      Ini.WriteString('session', 'created',
        FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
      // the identity the panes carry in SUPERTERM_SESSION_CHAIN
      Ini.WriteString('session', 'id', PaneSessionId);
      Ini.WriteString('session', 'client_chains', ClientChainsUnion);
      Ini.UpdateFile;
    finally
      FreeAndNil(Ini);
    end;
    if FpChmod(PAnsiChar(TempPath), &600) <> 0 then
      raise EInOutError.CreateFmt('cannot protect session sidecar: %s',
        [SysErrorMessage(fpGetErrNo)]);
    // POSIX rename replaces the old sidecar atomically. Readers holding the
    // previous inode finish safely; every new reader sees the whole new file.
    if not RenameFile(TempPath, FMetaPath) then
      raise EInOutError.CreateFmt('cannot replace session sidecar: %s',
        [SysErrorMessage(fpGetErrNo)]);
    TempPath := '';
  except
    on E: Exception do
    begin
      FreeAndNil(Ini);
      if (TempPath <> '') and FileExists(TempPath) then
        DeleteFile(TempPath);
      // The sidecar is discovery metadata, never the session transaction.
      // A read-only/full filesystem must not suppress the already committed
      // NEWPANE/KILL/LAYOUT event and desynchronize attached clients.
      try
        if DebugActive then
          DebugLog('daemon: sidecar update failed: ' + E.ClassName + ': ' +
            E.Message);
      except
      end;
    end;
  end;
end;

procedure TDetachedSession.SignalReady(var AFd: cint; AOk: boolean);
var
  B: byte;
begin
  if AFd < 0 then
    Exit;
  if AOk then B := 1 else B := 0;
  WriteFull(AFd, B, SizeOf(B));
  FpClose(AFd);
  AFd := -1;
end;

procedure TDetachedSession.Run(var AReadyFd: cint);
var
  Poller: TSuperPoll;
  Ready: TPollReadyArray;
  Ev: TPollReady;
  I, J, NewClient, N, Slot, TimeoutMs: cint;
  Addr: TUnixSockAddr;
  AddrLen: TSockLen;
  B0: byte;
  Closed, AliveFound: boolean;
  NewTitle: string;
  Fails: integer;
  NowTick: QWord;
  EventFd: cint;

  // Extract complete frames into the one global FIFO.  Nothing below calls a
  // command handler directly: observation order and execution order are now
  // the same explicit sequence.
  procedure DispatchClientBuffer(AIdx: integer);
  var
    FrameKind: byte;
    FramePane: integer;
    FrameSize: LongWord;
    FrameData: TByteArray;
    FramePop: TFramePop;
    Header: TFrameHeader;
  begin
    if (AIdx < 0) or (AIdx >= MAX_CLIENTS) or
       (FClients[AIdx].Fd < 0) or FClients[AIdx].CloseQueued or
       FClients[AIdx].TerminalQueued then
      Exit;
    while FClients[AIdx].FramesUsed < FRAME_BUDGET do
    begin
      // Reject a fixed-size cosmetic frame from its header alone. Otherwise
      // a hostile local peer could make the parser buffer/allocate up to the
      // general 112 MB screen-frame ceiling before validation in the handler.
      if Length(FClients[AIdx].InBuf) - FClients[AIdx].InPos >=
         SizeOf(Header) then
      begin
        Header := Default(TFrameHeader);
        Move(FClients[AIdx].InBuf[FClients[AIdx].InPos + 1], Header,
          SizeOf(Header));
        if (Header.Kind = FRAME_LAYOUT_PREVIEW) and
           (Header.Size <> LAYOUT_PREVIEW_PAYLOAD_SIZE) then
        begin
          if CanQueueCommand(0) and
             QueueCommand(coClient, AIdx, FClients[AIdx].Generation,
               0, -1, nil, True) then
            FClients[AIdx].CloseQueued := True;
          Exit;
        end;
      end;
      FramePop := PeekBufferedFrame(FClients[AIdx].InBuf,
        FClients[AIdx].InPos, FrameKind, FramePane, FrameSize);
      case FramePop of
        fpNeedMore:
          begin
            if FClients[AIdx].PeerClosed and
               CanQueueCommand(0) and
               QueueCommand(coClient, AIdx, FClients[AIdx].Generation,
                 0, -1, nil, True) then
              FClients[AIdx].CloseQueued := True;
            Exit;
          end;
        fpInvalid:
          begin
            if CanQueueCommand(0) and
               QueueCommand(coClient, AIdx, FClients[AIdx].Generation,
                 0, -1, nil, True) then
              FClients[AIdx].CloseQueued := True;
            Exit;
          end;
        fpReady:
          begin
            // Backpressure: do not consume the frame until both queue bounds
            // can accept it. Polling this socket is disabled in the meantime.
            if not CanQueueCommand(FrameSize) then
              Exit;
            if PopBufferedFrame(FClients[AIdx].InBuf,
              FClients[AIdx].InPos, FrameKind, FramePane,
              FrameData) <> fpReady then
              Exit;
            if not QueueCommand(coClient, AIdx,
              FClients[AIdx].Generation, FrameKind, FramePane,
              FrameData) then
              Exit;
            Inc(FClients[AIdx].FramesUsed);
            if FrameKind in [FRAME_DETACH, FRAME_CLOSE] then
            begin
              FClients[AIdx].TerminalQueued := True;
              Exit;
            end;
          end;
      end;
    end;
  end;

  procedure DispatchPendingBuffer(AIdx: integer);
  var
    FrameKind: byte;
    FramePane: integer;
    FrameSize: LongWord;
    FrameData: TByteArray;
    FramePop: TFramePop;
  begin
    if (AIdx < 0) or (AIdx >= MAX_PENDING_CONNECTIONS) or
       (FPending[AIdx].Fd < 0) or FPending[AIdx].CloseAfterWrite or
       FPending[AIdx].CloseQueued or FPending[AIdx].CommandQueued then
      Exit;
    FramePop := PeekBufferedFrame(FPending[AIdx].InBuf,
      FPending[AIdx].InPos, FrameKind, FramePane, FrameSize);
    case FramePop of
      fpNeedMore:
        if FPending[AIdx].PeerClosed and CanQueueCommand(0) and
           QueueCommand(coPending, AIdx, FPending[AIdx].Generation,
             0, -1, nil, True) then
          FPending[AIdx].CloseQueued := True;
      fpInvalid:
        if CanQueueCommand(0) and
           QueueCommand(coPending, AIdx, FPending[AIdx].Generation,
             0, -1, nil, True) then
          FPending[AIdx].CloseQueued := True;
      fpReady:
        if CanQueueCommand(FrameSize) then
        begin
          if PopBufferedFrame(FPending[AIdx].InBuf,
            FPending[AIdx].InPos, FrameKind, FramePane,
            FrameData) <> fpReady then
            Exit;
          if QueueCommand(coPending, AIdx, FPending[AIdx].Generation,
            FrameKind, FramePane, FrameData) then
            FPending[AIdx].CommandQueued := True;
        end;
    end;
  end;

  function ClientFrameBuffered(AIdx: integer): boolean;
  var
    FrameKind: byte;
    FramePane: integer;
    FrameSize: LongWord;
  begin
    Result := False;
    if (AIdx < 0) or (AIdx >= MAX_CLIENTS) or
       (FClients[AIdx].Fd < 0) then
      Exit;
    Result := PeekBufferedFrame(FClients[AIdx].InBuf,
      FClients[AIdx].InPos, FrameKind, FramePane, FrameSize) <> fpNeedMore;
  end;

  function PendingFrameBuffered(AIdx: integer): boolean;
  var
    FrameKind: byte;
    FramePane: integer;
    FrameSize: LongWord;
  begin
    Result := False;
    if (AIdx < 0) or (AIdx >= MAX_PENDING_CONNECTIONS) or
       (FPending[AIdx].Fd < 0) then
      Exit;
    Result := PeekBufferedFrame(FPending[AIdx].InBuf,
      FPending[AIdx].InPos, FrameKind, FramePane, FrameSize) <> fpNeedMore;
  end;

  function BufferedCommandWork: boolean;
  var
    C: integer;
  begin
    Result := FCommandCount > 0;
    if Result then Exit;
    for C := 0 to MAX_PENDING_CONNECTIONS - 1 do
      if (FPending[C].Fd >= 0) and (not FPending[C].CommandQueued) and
         (PendingFrameBuffered(C) or
          (FPending[C].PeerClosed and not FPending[C].CloseQueued)) then
        Exit(True);
    for C := 0 to MAX_CLIENTS - 1 do
      if (FClients[C].Fd >= 0) and
         (ClientFrameBuffered(C) or
          (FClients[C].PeerClosed and not FClients[C].CloseQueued and
           not FClients[C].TerminalQueued)) then
        Exit(True);
  end;
begin
  Fails := 0;
  // StartDetachedServer named this fork before transferring the inherited UI,
  // so even a constructor/hook failure gets a child-PID HeapTrc destination.
  // From here on, trap fatal signals too: if this process dies every pane goes
  // with it and clients otherwise see only "connection lost".
  InstallCrashHandler;
  if DebugActive then
    DebugLog('daemon: session server starting (pid ' + IntToStr(FpGetPid) + ')');
  FpSignal(SIGHUP, SignalHandler(SIG_IGN));
  FpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  if (FListener < 0) or not FOwnsPanes then
    raise EInOutError.Create(
      'detached session run started before listener/ownership commit');
  // For a new persistent workspace the inherited TPty objects contain only
  // resolved launch data. Fork the pane processes here, in the daemon, before
  // READY: this process is then their real parent and ReapChildren is the one
  // and only waitpid owner. Classic detach reaches this point with live PTYs
  // and is deliberately left unchanged.
  if not SpawnInitialPanes then
    raise EInOutError.Create('could not start every initial session pane');
  StartPaneWorkers;
  WriteSidecar;
  SignalReady(AReadyFd, True);
  Poller := TSuperPoll.Create;
  try
    while not FStop do
    begin
      // One bad iteration must not take the session with it. Before this, an
      // exception anywhere under the loop -- a failed ini write, a /proc read
      // of a process that just exited, a socket error -- unwound out of Run,
      // and the finally that follows frees the session, which kills every pane
      // on the way out. Log it, dump the state, and carry on; give up only if
      // it keeps happening, which means the loop itself is broken.
      try
        // Commands queued by the previous readiness batch are always consumed
        // before observing more socket input.
        DrainCommandQueue;
        if FStop then
          Continue;
        NowTick := GetTickCount64;
        if ExpireLayoutPreviews then
          // A timed-out tail has no later commit frame of its own. Pair CLEAR
          // with a canonical event so clients can settle it atomically even
          // when their bounded drain stops between the adjacent frames.
          BroadcastLayoutEv(-1);
        for I := 0 to MAX_CLIENTS - 1 do
        begin
          FClients[I].WriteUsed := 0;
          FClients[I].FramesUsed := 0;
        end;
        // A slow reader loses only its own view. PTYs are always drained and
        // every other client continues independently.
        for I := 0 to MAX_CLIENTS - 1 do
          if (FClients[I].Fd >= 0) and
             (Length(FClients[I].OutBuf) - FClients[I].OutPos >
               LAG_MIN_PENDING) and
             (NowTick - FClients[I].LastProgress > LAG_GRACE_MS) then
            DropClient(I);
        // First-frame slowloris and abandoned one-shot control replies.
        for I := 0 to MAX_PENDING_CONNECTIONS - 1 do
          if (FPending[I].Fd >= 0) and (FPending[I].Deadline <> 0) and
             (NowTick >= FPending[I].Deadline) and
             (not FPending[I].CommandQueued) and
             (not PendingFrameBuffered(I)) then
            DropPending(I);

        CheckPaneWorkers;

        // Buffered commands left by an earlier queue-capacity boundary need
        // no new kernel edge. Pending handshakes get one slot each; attached
        // clients start at a rotating index for bounded round-robin fairness.
        for I := 0 to MAX_PENDING_CONNECTIONS - 1 do
          DispatchPendingBuffer(I);
        for J := 0 to MAX_CLIENTS - 1 do
        begin
          I := (FDispatchCursor + J) mod MAX_CLIENTS;
          DispatchClientBuffer(I);
        end;
        FDispatchCursor := (FDispatchCursor + 1) mod MAX_CLIENTS;
        DrainCommandQueue;
        if FStop then
          Continue;

        Poller.Clear;
        Poller.Watch(FListener, psListener, 0, True, False);
        if FWorkerCount > 0 then
          Poller.Watch(FWorkerResultPipe[0], psWorker, 0, True, False);
        for I := 0 to MAX_PENDING_CONNECTIONS - 1 do
          if FPending[I].Fd >= 0 then
            Poller.Watch(FPending[I].Fd, psPending, I,
              (not FPending[I].CloseAfterWrite) and
                (not FPending[I].PeerClosed) and
                (not FPending[I].CommandQueued) and
                (not PendingFrameBuffered(I)) and
                (FCommandCount < COMMAND_QUEUE_SLOTS) and
                (FCommandBytes < COMMAND_QUEUE_BYTE_LIMIT),
              FPending[I].OutBuf <> '');
        for I := 0 to MAX_CLIENTS - 1 do
          if FClients[I].Fd >= 0 then
            Poller.Watch(FClients[I].Fd, psClient, I,
              (FClients[I].FramesUsed < FRAME_BUDGET) and
                (not FClients[I].PeerClosed) and
                (not FClients[I].CloseQueued) and
                (not FClients[I].TerminalQueued) and
                (not ClientFrameBuffered(I)) and
                (FCommandCount < COMMAND_QUEUE_SLOTS) and
                (FCommandBytes < COMMAND_QUEUE_BYTE_LIMIT),
              FClients[I].OutBuf <> '');
        if FWorkerCount = 0 then
          for I := 0 to FPaneCount - 1 do
            if (FPanes[I] <> nil) and FPanes[I].Alive and
               (FPanes[I].Master >= 0) then
              Poller.Watch(FPanes[I].Master, psPane, I, True,
                FPanes[I].InputPending);
        if BufferedCommandWork then
          TimeoutMs := 0
        else
          TimeoutMs := POLL_TICK_MS;
        N := Poller.Wait(TimeoutMs, Ready);
        if N < 0 then
        begin
          if fpgeterrno = ESysEINTR then
            Continue;
          if DebugActive then
            DebugLog('daemon: poll failed with errno ' +
              IntToStr(fpgeterrno));
          Break;
        end;

        for J := 0 to High(Ready) do
        begin
          Ev := Ready[J];
          case Ev.Source of
            psWorker:
              DrainWorkerResults;
            psListener:
              begin
                if Ev.Error or Ev.Hangup then
                begin
                  if DebugActive then
                    DebugLog('daemon: listener failed');
                  FStop := True;
                  Break;
                end;
                if not Ev.Readable then
                  Continue;
                for I := 1 to ACCEPT_BUDGET do
                begin
                  Addr := Default(TUnixSockAddr);
                  AddrLen := SizeOf(Addr);
                  NewClient := fpAccept(FListener, @Addr, @AddrLen);
                  if NewClient < 0 then
                  begin
                    if fpgeterrno = ESysEINTR then
                      Continue;
                    Break;
                  end;
                  SetCloExec(NewClient);
                  SetNonBlocking(NewClient);
                  Slot := -1;
                  for N := 0 to MAX_PENDING_CONNECTIONS - 1 do
                    if FPending[N].Fd < 0 then
                    begin
                      Slot := N;
                      Break;
                    end;
                  if Slot < 0 then
                    FpClose(NewClient)
                  else
                  begin
                    FPending[Slot] := Default(TPendingConn);
                    FPending[Slot].Fd := NewClient;
                    FPending[Slot].Generation := NewConnectionGeneration;
                    FPending[Slot].LastProgress := GetTickCount64;
                    FPending[Slot].Deadline := GetTickCount64 +
                      FIRST_FRAME_TIMEOUT_MS;
                  end;
                end;
              end;
            psPending:
              if (Ev.Index >= 0) and
                 (Ev.Index < MAX_PENDING_CONNECTIONS) and
                 (FPending[Ev.Index].Fd >= 0) then
              begin
                EventFd := FPending[Ev.Index].Fd;
                Closed := False;
                if Ev.Readable and (not FPending[Ev.Index].CloseAfterWrite) and
                   (FCommandCount < COMMAND_QUEUE_SLOTS) and
                   (FCommandBytes < COMMAND_QUEUE_BYTE_LIMIT) then
                begin
                  if not ReadSocketAvailable(EventFd,
                    FPending[Ev.Index].InBuf,
                    FPending[Ev.Index].InPos, Closed) then
                    FPending[Ev.Index].PeerClosed := True
                  else if Closed then
                    FPending[Ev.Index].PeerClosed := True;
                  if FPending[Ev.Index].Fd = EventFd then
                    DispatchPendingBuffer(Ev.Index);
                end;
                if (FPending[Ev.Index].Fd = EventFd) and Ev.Writable then
                  FlushPending(Ev.Index);
                if (FPending[Ev.Index].Fd = EventFd) and
                   (Ev.Error or (Ev.Hangup and not Ev.Readable)) then
                begin
                  FPending[Ev.Index].PeerClosed := True;
                  DispatchPendingBuffer(Ev.Index);
                end;
              end;
            psClient:
              if (Ev.Index >= 0) and (Ev.Index < MAX_CLIENTS) and
                 (FClients[Ev.Index].Fd >= 0) then
              begin
                EventFd := FClients[Ev.Index].Fd;
                Closed := False;
                if Ev.Readable and
                   (FCommandCount < COMMAND_QUEUE_SLOTS) and
                   (FCommandBytes < COMMAND_QUEUE_BYTE_LIMIT) then
                begin
                  if not ReadSocketAvailable(EventFd,
                    FClients[Ev.Index].InBuf,
                    FClients[Ev.Index].InPos, Closed) then
                    FClients[Ev.Index].PeerClosed := True
                  else if Closed then
                    FClients[Ev.Index].PeerClosed := True;
                  if FClients[Ev.Index].Fd = EventFd then
                    DispatchClientBuffer(Ev.Index);
                end;
                if (FClients[Ev.Index].Fd = EventFd) and Ev.Writable then
                  FlushClient(Ev.Index);
                if (FClients[Ev.Index].Fd = EventFd) and
                   (Ev.Error or (Ev.Hangup and not Ev.Readable)) then
                begin
                  FClients[Ev.Index].PeerClosed := True;
                  DispatchClientBuffer(Ev.Index);
                end;
              end;
            psPane:
              if (Ev.Index >= 0) and (Ev.Index < FPaneCount) and
                 (FPanes[Ev.Index] <> nil) and FPanes[Ev.Index].Alive then
              begin
                if Ev.Writable then
                  FPanes[Ev.Index].FlushInput;
                if Ev.Readable or Ev.Error or Ev.Hangup then
                  HandlePaneOutput(Ev.Index);
              end;
          end;
        end;
        // Execute exactly in the order in which the readiness pass enqueued
        // the commands. Any detach/close resets its generation, so successors
        // already in the FIFO are harmlessly rejected as stale.
        DrainCommandQueue;
        if FStop then
          Continue;
        ReapChildren;
      // live titles: ad-hoc panes without a fixed title show the command
      // or the current directory, just as the UI does locally
        if GetTickCount64 - FLastTitleTick > 1500 then
        begin
          FLastTitleTick := GetTickCount64;
          for I := 0 to FPaneCount - 1 do
          begin
            NewTitle := FTitles[I];
            LockPane(I);
            try
              if (FPanes[I] <> nil) and FPanes[I].Alive and
                 (FTerms[I] = '') and (not FTitleFixed[I]) then
              begin
                FPanes[I].QueryState;
                if FPanes[I].TitleCmd <> '' then
                  NewTitle := ' ' + Copy(ExtractFileName(
                    FirstWordOf(FPanes[I].TitleCmd)), 1, 24)
                else if FPanes[I].TitleCwd <> '' then
                  NewTitle := ' ' + Copy(ExtractFileName(FPanes[I].TitleCwd),
                    1, 24);
              end;
            finally
              UnlockPane(I);
            end;
            if NewTitle <> FTitles[I] then
            begin
              FTitles[I] := NewTitle;
              BroadcastTitle(I);
            end;
          end;
        end;
        // self-cleanup: all panes dead and nobody attached for a minute
        AliveFound := False;
        for I := 0 to FPaneCount - 1 do
        begin
          LockPane(I);
          try
            AliveFound := (FPanes[I] <> nil) and FPanes[I].Alive;
          finally
            UnlockPane(I);
          end;
          if AliveFound then
          begin
            Break;
          end;
        end;
        // Zero panes is a deliberately persistent shared desktop: users can
        // detach from it and later create its first pane again.  The legacy
        // grace reap remains only for sessions whose pane slots exist but all
        // their child programs have died.
        if (FPaneCount = 0) or AliveFound or (AttachedCount > 0) then
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
  finally
    Poller.Free;
  end;
  StopPaneWorkers;
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
  const ATitleFixed: TBoolArray;
  AChildHook: TDetachedServerChildHook): TDetachedServerStartResult;
var
  ReadyPipe: TFilDes;
  Pid, Waited: TPid;
  WaitStatus: cint;
  B: byte;
  Server: TDetachedSession;
  NullFd: cint;
  LockResult: TSessionNameLockResult;
  Attempt, N, Flags: integer;
  Probe: TSocketProbe;
  OwnershipTransferred: boolean;

  procedure SignalChildFailure;
  begin
    if ReadyPipe[1] < 0 then
      Exit;
    if OwnershipTransferred then
      B := 2
    else
      B := 0;
    WriteFull(ReadyPipe[1], B, SizeOf(B));
    FpClose(ReadyPipe[1]);
    ReadyPipe[1] := -1;
  end;

  procedure ReapIntermediate;
  var
    I: integer;
  begin
    if Pid <= 1 then
      Exit;
    // The first child should have raw-exited immediately after the second
    // fork. Never block on it: a stopped or damaged intermediate must not
    // freeze the launching client.
    for I := 1 to 200 do
    begin
      Waited := FpWaitPid(Pid, WaitStatus, WNOHANG);
      if Waited = Pid then
        Exit;
      if (Waited < 0) and (FpGetErrNo <> ESysEINTR) then
        Exit;
      Sleep(1);
    end;
    // Killing the exact intermediate is safe after READY: the daemon is a
    // distinct process. Do not kill its process group on this success path.
    FpKill(Pid, SIGKILL);
    for I := 1 to 2000 do
    begin
      Waited := FpWaitPid(Pid, WaitStatus, WNOHANG);
      if Waited = Pid then
        Exit;
      if (Waited < 0) and (FpGetErrNo <> ESysEINTR) then
        Exit;
      Sleep(1);
    end;
  end;

  function CancelStartupAndConfirmClosed: boolean;
  var
    I, R: integer;
    Scratch: byte;
  begin
    Result := False;
    // The intermediate called setsid before it could fork. Consequently
    // every possible grandchild remains in the one private process group
    // whose id is Pid. Keep Pid unreaped while cancelling so that identifier
    // cannot be recycled underneath a negative-PID kill.
    for I := 1 to 200 do
    begin
      FpKill(Pid, SIGKILL);
      FpKill(-Pid, SIGKILL);
      repeat
        R := FileRead(ReadyPipe[0], Scratch, SizeOf(Scratch));
        if R = 0 then
          Exit(True);
        if R > 0 then
          Continue;
        if FpGetErrNo = ESysEINTR then
          Continue;
        Break;
      until False;
      PollFd(ReadyPipe[0], POLLIN, 10);
    end;
  end;

  procedure RemoveCancelledPublication;
  var
    Path: string;
    St: Stat;
  begin
    // SIGKILL cannot run the daemon destructor. Once the ready-pipe EOF has
    // proved the private process group dead, the still-held per-name lock
    // makes it safe to remove only the exact socket/sidecar types this
    // cancelled creator could have published.
    Path := SessionSocketPathFor(AName);
    St := Default(Stat);
    if (ProbeSocket(Path) = spDead) and
       (FpLStat(RawByteString(Path), St) = 0) and FpS_ISSOCK(St.st_mode) then
      FpUnlink(RawByteString(Path));
    Path := SessionMetaPathFor(AName);
    St := Default(Stat);
    if (FpLStat(RawByteString(Path), St) = 0) and FpS_ISREG(St.st_mode) and
       (St.st_uid = FpGetEUid) then
      FpUnlink(RawByteString(Path));
  end;

begin
  Result := dssFailed;
  DetachedServerChildFinished := False;
  OwnershipTransferred := False;
  if (ALay = nil) or (Length(APanes) > MAX_PANES) or
     (ALay.PaneCount <> Length(APanes)) or
     (not Assigned(AChildHook)) then
    Exit;
  Probe := ProbeSocket(SessionSocketPathFor(AName));
  if Probe <> spDead then
    Exit;
  for Attempt := 1 to
    (SESSION_CREATE_WAIT_MS div SESSION_CREATE_RETRY_MS) do
  begin
    LockResult := TryHoldSessionNameLock(AName);
    if LockResult = snlAcquired then
      Break;
    if LockResult = snlError then
      Exit;
    Probe := ProbeSocket(SessionSocketPathFor(AName));
    if Probe <> spDead then
      Exit;
    Sleep(SESSION_CREATE_RETRY_MS);
  end;
  if LockResult <> snlAcquired then
    Exit;
  try
    // The first probe was only a fast path. This one is protected from every
    // other cooperative creator and closes the validation/publication race.
    if ProbeSocket(SessionSocketPathFor(AName)) <> spDead then
      Exit;
    ReadyPipe := Default(TFilDes);
    if FpPipe(ReadyPipe) <> 0 then
      Exit;
    Pid := FpFork;
    if Pid = 0 then
    begin
      FpClose(ReadyPipe[0]);
      // Become a private session/process-group leader BEFORE the second fork.
      // The grandchild inherits this known group and cannot reacquire a
      // controlling terminal because it is not a session leader. On a hung
      // startup the parent can therefore terminate the complete startup tree
      // using only this first, known PID on both GNU/Linux and Darwin.
      if FpSetsid < 0 then
      begin
        SignalChildFailure;
        FpExit(1);
      end;
      if SessionStartupTestStage('intermediate-hang') then
        while True do
          Sleep(1000);
      Pid := FpFork;
      if Pid < 0 then
      begin
        SignalChildFailure;
        FpExit(1);
      end;
      if Pid > 0 then
        FpExit(0);
      // Classic double-fork: deliberately no second setsid here. The actual
      // daemon stays in the private session/group created above while its
      // intermediate parent is reaped by the launcher.
      // Record locks are not inherited as locks, and the parent intentionally
      // keeps its descriptor until publication. Close the daemon's duplicate
      // immediately so it cannot retain or later interfere with that lock.
      ReleaseHeldSessionNameLock;
      if SessionStartupTestStage('daemon-hang-pre') then
        while True do
          Sleep(1000);
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
      NullFd := FpOpen('/dev/null', O_RDWR, 0);
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
      // Do this before the ownership hook.  Any failure while the inherited UI
      // still owns the objects must take the raw exit path; once the hook has
      // begun, normal unwinding is safe and gives HeapTrc its child-PID file.
      try
        DebugSetRole('daemon');
      except
        SignalChildFailure;
        FpExit(1);
      end;

      Server := nil;
      try
        try
          // The child alone relinquishes the inherited FreeVision references.
          Server := TDetachedSession.Create(AName, AProfile, ALay, APanes,
            AScreens, ATitles, ATerms, AFocused, AGeom, ADeskW, ADeskH,
            ATitleFixed);
          // Listener preparation is the reversible phase: destructor is not
          // yet allowed to touch the parent's panes. Only after it succeeds
          // does the hook relinquish this fork's UI and commit ownership.
          if not Server.PrepareListener then
            SignalChildFailure
          else
          begin
            AChildHook;
            Server.AdoptPanes;
            OwnershipTransferred := True;
            if SessionStartupTestStage('daemon-hang-post') then
              while True do
                Sleep(1000);
            Server.Run(ReadyPipe[1]);
          end;
        finally
          Server.Free;
        end;
      except
        on E: Exception do
        begin
          // SignalReady changes the descriptor to -1.  Therefore this sends a
          // failure only when Run did not already publish success/failure, and
          // can never close a descriptor number recycled later by the daemon.
          SignalChildFailure;
          System.ExitCode := 1;
          try
            if DebugActive then
              DebugLog('daemon: startup/run unwind: ' + E.ClassName + ': ' +
                E.Message);
          except
          end;
        end;
      end;
      // Return through RequestDetach/PromoteToServer, Main and TSuperApp.Done.
      // The program block observes this fork-private flag, finalizes Pascal
      // units exactly once (including HeapTrc), then uses the raw Unix exit.
      DetachedServerChildFinished := True;
      Result := dssChildFinished;
      Exit;
    end;
    FpClose(ReadyPipe[1]);
    if Pid < 0 then
    begin
      FpClose(ReadyPipe[0]);
      Exit;
    end;
    // A nonblocking reader lets cancellation drain any raced status byte and
    // prove EOF without ever waiting on a damaged descendant.
    Flags := FpFcntl(ReadyPipe[0], F_GETFL, 0);
    if Flags >= 0 then
      FpFcntl(ReadyPipe[0], F_SETFL, Flags or O_NONBLOCK);
    B := 0;
    N := -1;
    // Fixed poll quanta provide a hard bound even on Darwin, where FPC
    // 3.2.2 implements GetTickCount64 with wall-clock gettimeofday.
    for Attempt := 1 to SessionStartupPollAttempts do
    begin
      N := PollFd(ReadyPipe[0], POLLIN, 100);
      if N > 0 then
      begin
        N := FileRead(ReadyPipe[0], B, SizeOf(B));
        if (N >= 0) or (FpGetErrNo <> ESysEINTR) then
          Break;
      end
      else if (N < 0) and (FpGetErrNo <> ESysEINTR) then
        Break;
    end;
    if N = SizeOf(B) then
      case B of
        1: Result := dssParentStarted;
        2:
          begin
            // The daemon reports this only after Server.Free closed its
            // listener. Its destructor deliberately cannot unlink while the
            // launcher still owns the name lock, so finish that exact cleanup here
            // before exposing an unattachable ghost session to enumeration.
            RemoveCancelledPublication;
            Result := dssOwnershipLost;
          end;
      end;
    if (Result <> dssParentStarted) and (Result <> dssOwnershipLost) then
    begin
      // Failure/EOF/timeout is safe for local continuation only after every
      // possible fork is dead and the daemon-only writer proves closure.
      if CancelStartupAndConfirmClosed then
      begin
        RemoveCancelledPublication;
        Result := dssFailed
      end
      else
        Result := dssOwnershipLost;
    end;
    ReapIntermediate;
    FpClose(ReadyPipe[0]);
  finally
    ReleaseHeldSessionNameLock;
  end;
end;

end.
