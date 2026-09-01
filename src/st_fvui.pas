(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_fvui - FreeVision interface (Turbo Pascal style)
*)

unit st_fvui;

{$mode objfpc}{$H+}

interface

uses
  Objects, Drivers, Views, Menus, Dialogs, App, FVConsts, MsgBox,
  SysUtils, Classes, baseunix, unix, termio, Video,
  st_config, st_wclass, st_profiles, st_dialogs, st_pty, st_screen,
  st_layout, st_session, st_debug, st_server, st_video, st_cli, st_artbg,
  st_mouse, st_clipboard;

const
  // Command range INVARIANT: each dynamic base (cmOpenClass,
  // cmProfileBase, cmSessionBase, cmWindowBase, cmWindowRestoreBase,
  // cmLanguageBase) owns a reserved range and NO direct case may fall
  // inside a dynamic range. Before, cmOpenClass=2111 collided with
  // cmSessionWizard=2112 and cmDetach=2113: pressing the 2nd terminal
  // in the menu launched the wizard and the 3rd one detached.
  // Ranges: 2100-2199 panes/app - 2200-2259 profiles (40 menu slots) -
  // 2320-2349 classes (20 menu slots) - 2400-2439 windows - 2500-2539 minimized
  // - 2550-2569 session (detach/wizard) - 2600 help - 2700 language.
  WHEEL_LINES = 3;   // history lines per wheel notch
  // FreeVision does not wrap or compact TMenuBar entries: each one consumes
  // its visible length plus two cells.  These are the exact widths of the
  // complete English and Spanish top-level bars.
  FULL_TOP_MENU_EN = 80;
  FULL_TOP_MENU_ES = 89;
  MAX_PROFILE_MENU_ITEMS = 40;
  MAX_CLASS_MENU_ITEMS = 20;
  cmSplitV     = 2100;
  cmSplitH     = 2101;
  cmPaneClose  = 2102;
  cmPaneNext   = 2103;
  cmPanePrev   = 2104;
  cmSaveSess   = 2105;
  cmGrowV      = 2106;
  cmShrinkV    = 2107;
  cmGrowH      = 2108;
  cmShrinkH    = 2109;
  // 2110 retired: a live session has one Exit path and no save variant.
  cmPaneTile    = 2111;    // retile as a mosaic (classic Window|Tile)
  cmPaneCascade = 2112;
  cmPaneList    = 2113;    // pane list (Alt+0)
  cmRedrawAll   = 2114;    // refresh the screen
  cmPaneOrganize = 2115;   // vendor NxM grid (TDeskTop.Tile)
  cmRenameWindow = 2116;   // custom title of the focused window
  cmClipboardCopy = 2117;
  cmClipboardPaste = 2118;
  cmClipboardHistory = 2119;
  cmClipboardClear = 2120;
  cmInfoRow    = 2199;     // informational menu rows, always disabled
  cmProfileBase = 2200;   // + stable menu slot (0..39)
  cmProfileSaveAs = 2250;  // save the workspace as a profile
  cmProfileManage = 2251;  // profile manager
  cmProfileNewEmpty = 2252; // persist a profile with zero windows
  cmOpenClass   = 2320;     // + stable menu slot (0..19)
  cmWindowNext   = 2400;
  cmWindowPrev   = 2401;
  cmWindowBase   = 2410;   // + window index (0..15)
  cmClassPick    = 2340;   // class picker for a new pane
  cmClassManage  = 2341;   // class manager
  cmWindowMinimize = 2500;
  cmWindowMinimizeAll = 2501;
  cmWindowRestoreAll = 2502;
  cmWindowCloseAll = 2503;
  cmWindowRestoreBase = 2520;  // + pane index (0..15)
  cmDetach        = 2550;
  cmSessionPick   = 2551;   // picker/manager of detached sessions
  cmSessionNew    = 2552;   // create another named session from a profile
  cmSessionWizard = 2560;
  cmShowMaxPanes  = 2561;   // deferred daemon rejection dialog
  cmHelp        = 2600;
  cmAbout       = 2601;
  cmLanguageBase = 2700;
  cmPaletteBase  = 2750;   // +apColor/apBlackWhite/apMonochrome
  cmToggleAutoSave    = 2760;
  cmToggleAutoRestore = 2761;
  cmToggleDragContent = 2762;
  cmToggleZoomAnim    = 2763;
  cmBackgroundBase    = 2800;   // + index into the pictures found on disk
  cmBackgroundModeBase = 2830;  // + Ord(TArtMode)
  cmDesktopColor      = 2764;   // visual picker for the desktop colour
  cmToggleSolidBg     = 2765;   // paint our own ground, or let the host's show
  cmFullScreen        = 2766;   // prefix+f: hand the terminal to the pane
  cmFitSessionSize    = 2767;   // explicit PTY resize from this client's pane
  cmDesktopFitTerminal = 2768;  // explicit shared logical desktop resize
  cmDesktopModify      = 2769;
  cmDesktopShowSize    = 2770;
  cmToggleDesktopNotifications = 2771;

  // Membership changes are serialized by the daemon but can arrive faster
  // than a human-readable toast expires. Preserve each event in FIFO order;
  // a user explicitly asked never to collapse desktop notices.
  MEMBER_NOTICE_MS = 2000;

{$if cmProfileBase + MAX_PROFILE_MENU_ITEMS > cmProfileSaveAs}
  {$fatal Profile command range overlaps a direct command}
{$endif}
{$if cmOpenClass + MAX_CLASS_MENU_ITEMS > cmClassPick}
  {$fatal Window-class command range overlaps a direct command}
{$endif}

type
  TPassFilterState = (pfsGround, pfsEsc, pfsOsc, pfsOscEsc,
    pfsDropOsc, pfsDropOscEsc);
  TIconSlotUsed = array[0..MAX_PANES - 1] of boolean;
  TMemberNoticeKind = (mnConnected, mnDisconnected);
  TMemberNotice = record
    Kind: TMemberNoticeKind;
    ClientCount: integer;
  end;

  PSuperApp = ^TSuperApp;

  PTermView = ^TTermView;
  TTermView = object(TView)
    PaneIdx: integer;
    constructor Init(var Bounds: Objects.TRect; APane: integer);
    procedure Draw; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  PTermFrame = ^TTermFrame;
  TTermFrame = object(TFrame)
    procedure Draw; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  PTermWindow = ^TTermWindow;
  // The window's history scrollbar. The vendor funnels arrows, trough and
  // thumb drag through ScrollDraw, called only when Value really changed, so
  // this one override is the whole integration. Syncing breaks the echo when
  // the model is being pushed INTO the bar.
  PTermScrollBar = ^TTermScrollBar;
  TTermScrollBar = object(TScrollBar)
    PaneIdx: integer;
    Syncing: boolean;
    constructor Init(var Bounds: Objects.TRect; APane: integer);
    procedure ScrollDraw; virtual;
  end;

  TTermWindow = object(TWindow)
    Term: PTermView;
    SB: PTermScrollBar;        // right-edge history scrollbar
    SBShown: boolean;
    PaneIdx: integer;
    Minimized: boolean;
    IconSlot: integer;          // stable while minimized; -1 otherwise
    Zoomed: boolean;
    // Zoomed means "filling the desktop, frame and all"; FullScreen means
    // "owning the terminal", which is what passthrough is for. They used to
    // be the same thing, so maximising a window with its own icon threw the
    // IDE away. Only the fullscreen command sets this one.
    FullScreen: boolean;
    TitleFixed: boolean;       // custom title: cwd refresh must not touch it
    SavedRect: Objects.TRect;  // bounds before the minimized icon
    // FreeVision timestamps the first mouse-down. A remote title click then
    // runs a complete lock/drag/unlock path before the second mouse-down is
    // read, so an ordinary human double-click can miss its 8-tick deadline
    // and require a third click. Remember completion of an active, unmoved
    // title click; it is the only click eligible to begin our fallback pair.
    TitleClickTick: QWord;
    TitleClickX: integer;
    TitleClickArmed: boolean;
    PreviewGestureId, PreviewSeq: QWord;
    constructor Init(var Bounds: Objects.TRect; const ATitle: string; APane: integer);
    procedure InitFrame; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    procedure SizeLimits(var Min, Max: Objects.TPoint); virtual;
    procedure ChangeBounds(var Bounds: Objects.TRect); virtual;
    procedure Zoom; virtual;
    procedure Close; virtual;
    procedure Minimize;
    procedure Restore;
    procedure SetTitle(const S: string);
    // Resolve the same active-frame attribute that FreeVision's TFrame.Draw
    // uses, through the complete frame -> window -> application palette.
    function ActiveFrameAttr: byte;
    // show/hide and position the scrollbar from the pane's history state.
    // AValueOnly skips Show/Hide, which redraw the owner and must not be
    // called from inside a Draw.
    procedure SyncScrollBar(AValueOnly: boolean);
    // A window points at its pane from three places: itself, the terminal
    // view and the scrollbar. Panes are renumbered whenever one is inserted
    // or closed, and a scrollbar left on the old index drives ANOTHER
    // pane's viewport: the thumb moves, snaps back on the next sync, and
    // the text of this window never scrolls.
    procedure SetPaneIdx(APane: integer);
    procedure SendGesturePreview(AForce: boolean);
  end;

  // Desktop background that paints an ASCII art picture behind the windows.
  // The picture's cells go through the rich renderer, so they keep their real
  // RGB colours; the CP437 grid gets a 16-colour approximation so the chrome
  // path still shows something sensible.
  PArtBackground = ^TArtBackground;
  TArtBackground = object(TBackground)
    procedure Draw; virtual;
    // paint the whole desktop black; see the comment on Draw
    function DeskAttr: byte;
    procedure FillDesk(AStartX, AStartY, AWidth, AHeight: integer);
  end;

  PArtDesktop = ^TArtDesktop;
  TArtDesktop = object(TDeskTop)
    procedure InitBackground; virtual;
    function ExecView(P: PView): word; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  // A local, non-selectable toast over canonical desktop coordinate (0,0).
  // It is deliberately not a TWindow: it must not enter snapshots, profiles,
  // focus selection, icon arrangement or the shared desktop layout.
  PDesktopNotification = ^TDesktopNotification;
  TDesktopNotification = object(TView)
    Text: string;
    constructor Init(var Bounds: Objects.TRect);
    procedure Draw; virtual;
  end;

  // Root-level, client-local status chrome. It is deliberately outside the
  // shared desktop and sits only in the unused tail of the status line.
  PMemberStatusOverlay = ^TMemberStatusOverlay;
  TMemberStatusOverlay = object(TView)
    Text: string;
    constructor Init(var Bounds: Objects.TRect);
    procedure Draw; virtual;
  end;

  // Physical, client-local viewport chrome.  These views are siblings of the
  // logical Desktop: they never enter snapshots, profiles or daemon state.
  PDesktopScrollBar = ^TDesktopScrollBar;
  TDesktopScrollBar = object(TScrollBar)
    Axis: byte;                 // 0 = horizontal, 1 = vertical
    constructor Init(var Bounds: Objects.TRect; AAxis: byte);
    procedure ScrollDraw; virtual;
  end;

  PDesktopBackdrop = ^TDesktopBackdrop;
  TDesktopBackdrop = object(TView)
    procedure Draw; virtual;
  end;

  PGeometryStatusLine = ^TGeometryStatusLine;
  TGeometryStatusLine = object(TStatusLine)
    procedure Draw; virtual;
  end;

  TSuperApp = object(TApplication)
    Cfg: TConfig;
    Lay: TLayout;
    Panes: array[0..MAX_PANES - 1] of TPty;
    Scr: array[0..MAX_PANES - 1] of TScreen;
    Win: array[0..MAX_PANES - 1] of PTermWindow;
    PaneTerm: array[0..MAX_PANES - 1] of integer;  // index in WClasses or -1
    PaneConnect: array[0..MAX_PANES - 1] of string; // ad-hoc free connection
    // New persistent workspaces are launched by their daemon, not by this UI.
    // The TPty objects hold resolved launch data until the grandchild owns
    // them, making it the real parent and only reaper of every initial pane.
    DeferPaneSpawn: boolean;
    WClasses: TWindowClassArray;
    Profiles: TProfileArray;
    // Dynamic menu commands address one reserved slot, never an unbounded
    // catalogue index. Names remain stable if another client rewrites the
    // shared catalogue while this client's menu is open.
    ProfileMenuNames: array[0..MAX_PROFILE_MENU_ITEMS - 1] of string;
    ProfileMenuCount: integer;
    ClassMenuNames: array[0..MAX_CLASS_MENU_ITEMS - 1] of string;
    ClassMenuCount: integer;
    MenuCompact: boolean;       // only changes when a width threshold crosses
    ActiveProfile: integer;
    ActiveWindow: integer;
    ProfileMode: boolean;
    SkipSave: boolean;
    AbortRun: boolean;
    RemoteMode: boolean;
    RemoteLost: boolean;
    CurrentSessionName: string;
    DetachRequested: boolean;
    PrefixPending: boolean;
    Remote: TSessionClient;
    RemoteLayoutHash: string;   // last geometry pushed/applied
    RemoteGeom: TPaneGeomArray; // the one canonical geometry from the daemon
    RemoteDeskW, RemoteDeskH: integer;
    RemoteClientCount: integer;
    RemoteMinHostW, RemoteMinHostH: integer;
    RemoteHostSizesMatch: boolean;
    RemoteHostSummaryValid: boolean;
    // The shared Desktop keeps canonical coordinates.  Only these offsets and
    // root-level scrollbars are private to this viewer.
    ViewportX, ViewportY, ViewportW, ViewportH: integer;
    ViewportHVisible, ViewportVVisible: boolean;
    ViewportSyncing: boolean;
    DesktopHBar, DesktopVBar: PDesktopScrollBar;
    DesktopCorner, DesktopBackdrop: PDesktopBackdrop;
    DesktopNotification: PDesktopNotification;
    MemberStatusOverlay: PMemberStatusOverlay;
    MemberNotices: array of TMemberNotice;
    MemberNoticeHead: integer;
    MemberNoticeActive: boolean;
    MemberNoticeUntil, MemberNoticePauseTick: QWord;
    MemberNoticePaused: boolean;
    RemoteMembershipReady: boolean;
    GeometryStatusActive: boolean;
    GeometryStatusX, GeometryStatusY: integer;
    GeometryStatusW, GeometryStatusH: integer;
    // Remote zoom/fullscreen is proposed first and becomes visible only when the
    // daemon echoes its authoritative LAYOUT_EV. Output already queued before
    // that event must still be parsed using the old TScreen width.
    RemoteZoomPending: boolean;
    RemoteZoomPane: integer;
    RemoteZoomTarget: TPaneGeom;
    RemoteZoomContractPending: boolean;
    RemoteZoomContractPane: integer;
    RemoteZoomOldX1, RemoteZoomOldY1: integer;
    RemoteZoomOldX2, RemoteZoomOldY2: integer;
    RemoteZoomBaseRevision, RemoteZoomSentTick: QWord;
    RemoteZoomPreviewId, RemoteZoomPreviewSeq: QWord;
    // Cosmetic shared gesture state. Bounds and rings are presentations only:
    // RemoteGeom/Scr remain daemon-canonical until the final LAYOUT_EV.
    RemotePreviewMode: array[0..MAX_PANES - 1] of byte;
    RemotePreviewGesture: array[0..MAX_PANES - 1] of QWord;
    RemotePreviewRect: array[0..MAX_PANES - 1] of Objects.TRect;
    RemotePreviewOverlayOn: array[0..MAX_PANES - 1] of boolean;
    RemotePreviewOverlayGesture: array[0..MAX_PANES - 1] of QWord;
    RemotePreviewOverlayRect: array[0..MAX_PANES - 1] of Objects.TRect;
    RemotePreviewOverlayAttr: array[0..MAX_PANES - 1] of byte;
    // A restore/fullscreen contraction tail starts before its canonical commit and
    // draws only after it. Keep that ordering barrier across Idle batches so
    // an observer physically publishes the settled IDE before its first ring.
    RemotePreviewTailGesture: array[0..MAX_PANES - 1] of QWord;
    RemotePreviewTailBase: array[0..MAX_PANES - 1] of QWord;
    // CLEAR and its canonical layout are adjacent on the socket, but Idle may
    // stop at its frame/time budget between them. Keep the last preview on
    // screen until that canonical transaction arrives; otherwise the old
    // RemoteGeom would be exposed for one physical frame.
    RemotePreviewClearPending: array[0..MAX_PANES - 1] of boolean;
    // Armed only after attach has consumed its startup TIOCGWINSZ. Physical
    // size is always client metadata; it never mutates the shared desktop.
    RemoteHostSizeArmed: boolean;
    RemoteLockedPanes: LongWord; // one daemon-authoritative bit per pane
    RemoteSharedFocus: integer;
    SharedFullScreenRendered: boolean;
    RemoteGeometryDirty: boolean;
    RemoteTreeDirty: boolean;
    RemoteGeomDirtyPanes: array[0..MAX_PANES - 1] of boolean;
    CurrentSessionSocket: string;  // socket of the attached session
    // True once a successful fork transferred this process's PTYs, even if
    // adopting the newborn transport subsequently failed.
    PromotionConsumedWorkspace: boolean;
    // attach under construction: windows pass through intermediate
    // bounds (tile -> final geometry) and must NOT request transient
    // sizes from the daemon nor resize the snapshot screen every step
    RemoteAttachSettling: boolean;
    // passthrough: when a pane is maximized it owns the whole host
    // terminal and its raw PTY bytes are written straight through, so a
    // truecolor/emoji TUI renders untouched. PassPane = that pane (-1 off).
    PassPane: integer;
    // size last REQUESTED from the daemon per pane. In remote mode the
    // mirror is only resized when the daemon answers, so the request gate
    // cannot use the mirror's size: a daemon that keeps a pane smaller than
    // this client's window would otherwise be asked again on every drag step.
    ReqCols, ReqRows: array[0..MAX_PANES - 1] of integer;
    // Kept at zero: protocol v5 crops the whole canonical desktop at the host
    // edge and never creates a private per-pane viewport.
    PaneViewX, PaneViewY: array[0..MAX_PANES - 1] of integer;
    // rectangle for the next window StartPaneEx creates, when the caller has
    // already decided where it goes (a split); consumed by NewWindowRect
    NextRect: Objects.TRect;
    NextRectSet: boolean;
    // Profile construction creates every window off-desktop.  Only after all
    // panes have their definitive layout/state are they inserted as one
    // complete workspace; no provisional one-pane desktop ever exists.
    DeferWindowInsert: boolean;
    // mouse forwarding: the pane a button went down in (-1 none) and which
    // button, so the release and the drag reach the same application even
    // if the pointer wanders; the host's any-motion tracking (?1003) is
    // switched on only while the focused pane asks for it
    MouseGrabPane: integer;
    MouseGrabButton: integer;
    HostAnyMotion: boolean;
    PassReqW, PassReqH: integer;  // full size requested on enter
    PassFilterState: TPassFilterState;
    PassFilterBuf: RawByteString;
    PassFilterLen: integer;
    ClipHistory: TClipboardHistory;
    CopyMode: boolean;
    CopySelecting: boolean;
    CopyMouseSelecting: boolean;
    CopyPane: integer;
    CopyAnchorRow, CopyAnchorCol: integer;
    CopyCursorRow, CopyCursorCol: integer;
    // startup: hold one LockScreenUpdate across the whole build+promote+
    // attach so the screen is flushed ONCE at the end, not several times
    FBootLocked: boolean;
    constructor Init;
    destructor Done; virtual;
    procedure Idle; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    procedure InitMenuBar; virtual;
    procedure InitDeskTop; virtual;
    procedure InitStatusLine; virtual;
    function PaneCount: integer;
    procedure StartPane(i: integer; const ACwd, ACmd: string);
    procedure StartPaneEx(i: integer; const ACwd, ACmd: string;
      ASysIdx: integer; const AShellOv, AExtraEnv, ATitle: string;
      AMaxSB: integer; const ACommandOverride: string = '');
    procedure KillPane(i: integer);
    procedure FallbackPane(i: integer);
    procedure DoSplit(ADir: TSplitDir; ASysIdx: integer);
    procedure DoClosePane(i: integer);
    procedure DoCloseAllPanes;
    procedure DoOpenClassPane(ASysIdx: integer);
    procedure RelayoutAll;
    procedure FocusPane(i: integer);
    procedure CyclePane(ADelta: integer);
    function FirstVisiblePane: integer;
    function FindVisiblePane(AStart, ADelta: integer): integer;
    procedure MinimizeWindow(i: integer);
    procedure RestoreWindow(i: integer);
    procedure MinimizeAllWindows;
    procedure RestoreAllWindows;
    procedure SaveSessionNow;
    procedure ShowAbout;
    procedure RenameFocusedWindow;
    procedure ArrangeIcons;
    function FirstFreeIconSlot: integer;
    procedure DoTilePanes;
    procedure DoCascadePanes;
    procedure DoOrganizePanes;
    procedure DoPaneList;
    procedure ApplyPalette(AKind: integer);
    procedure InitViewportViews;
    procedure UpdateDesktopViewport(AReset: boolean);
    procedure SetDesktopViewport(AX, AY: integer; ARedraw: boolean = True);
    procedure CanonicalDesktopSize(out AWidth, AHeight: integer);
    procedure SetCanonicalDesktop(AWidth, AHeight: integer;
      AResetViewport, AKeepWindowsReachable: boolean);
    procedure RequestDesktopSize(AWidth, AHeight: integer);
    procedure AdjustDesktopToTerminal;
    procedure ModifyDesktopDimensions;
    procedure ShowDesktopDimensions;
    procedure QueueMemberNotice(AKind: TMemberNoticeKind; AClientCount: integer);
    procedure UpdateMemberNotices(ANow: QWord);
    procedure RefreshMemberNoticeViews;
    function MemberNoticeStatusText(AAvailable: integer): string;
    function MemberNoticeDesktopText: string;
    procedure SetGeometryStatus(const R: Objects.TRect; AActive: boolean);
    procedure CollectPaneGeom(out AGeom: TPaneGeomArray;
      out ADeskW, ADeskH: integer);
    // -2 acquires the required lock here; -1 is a preheld global lock;
    // non-negative values name the one preheld pane lock.
    procedure SyncRemoteLayout(APrelockedPane: integer = -2);
    // incremental repaint: redraw the view tree into the buffer but push
    // ONLY the changed cells (the FreeVision diff), instead of the
    // ResetVideoSurface+ReDraw sledgehammer that re-sends every cell
    procedure RepaintChanges;
    // release the startup screen lock and paint the final workspace once
    // (or go straight into passthrough if a pane is maximized)
    procedure FinishBoot;
    // passthrough of a maximized pane straight to the host terminal
    procedure EnterPassthrough(i: integer);
    procedure ExitPassthrough;
    procedure UpdatePassthrough;
    procedure SharedFullScreenSize(out ADeskW, ADeskH, ACols, ARows: integer);
    procedure SharedMaximizedSize(ACanonicalDeskW, ACanonicalDeskH: integer;
      out ADeskW, ADeskH, ACols, ARows: integer);
    procedure ResetRemotePreviewState;
    procedure ShowRemotePreviewWindow(APane: integer);
    procedure ClearRemotePreview(APane: integer; ARestoreWindow: boolean);
    procedure SettleRemotePreviewsForOwnedAction(APane: integer);
    function LockRemoteLayout(APane: integer): boolean;
    function ApplyRemoteLayoutPreviewEv(APane: integer;
      const AData: TByteArray; var AFullRedraw: boolean): boolean;
    procedure PrepareRemotePreviewsForLayout(ALockedPanes: LongWord);
    procedure ReapplyRemotePreviewsAfterLayout(ALockedPanes: LongWord);
    procedure ResetRemoteZoomState;
    procedure BeginRemoteZoom(ACommand: word; AInfoPtr: Pointer);
    procedure FinishRemoteZoomAnimation;
    procedure ZoomAnimate(AWindow: PTermWindow;
      AX1, AY1, AX2, AY2, BX1, BY1, BX2, BY2: integer);
    function ComputeLayoutHash: string;
    procedure ApplyRemoteLayoutEv(const AData: TByteArray;
      APeer: boolean = False; ALocalPreservePane: integer = -1);
    procedure ApplyRemoteHostSummaryEv(const AData: TByteArray);
    procedure ApplyRemoteKillPane(APane: integer);
    procedure ApplyRemoteNewPane(const AData: TByteArray);
    procedure ApplyRemoteResize(APane: integer; const AData: TByteArray);
    procedure ApplyRemoteTitle(APane: integer; const AData: TByteArray);
    function FindWindowClass(const AName: string): integer;
    function FindProfile(const AName: string): integer;
    procedure ReloadWindowClassCatalog;
    procedure ReloadProfileCatalog;
    function ActivateProfile(AProfile, AWindow: integer): boolean;
    procedure ApplyWindowGeometry(const WS: TProfileWindowSpec);
    function CaptureCurrentAsWindow(const AName: string): TProfileWindowSpec;
    function SaveWorkspaceAsProfile(const AName: string): boolean;
    procedure RunProfileSaveAs;
    procedure DoProfileManage;
    procedure StopRuntime;
    procedure ReleaseRuntime;
    procedure PrepareDetachedServerChild;
    function NewWindowRect(ASysIdx: integer): Objects.TRect;
    procedure CreateWindowForPane(i: integer; const ATitle: string;
      const ARect: Objects.TRect);
    procedure SyncPaneToWindow(i: integer);
    // repaint one pane and bring its scrollbar up to date
    procedure RepaintPane(i: integer);
    // DECCKM state of a pane, nil-safe
    function PaneWantsAppCursor(i: integer): boolean;
    // mouse forwarding to the application inside pane i. Returns True when
    // the event was the application's and has been sent; False when the
    // window manager keeps it (the pane asked for no mouse, or the kind of
    // event is not one it asked for)
    function ForwardMouse(i: integer; const Event: TEvent;
      const ALocal: Objects.TPoint): boolean;
    // keep the host terminal's ?1003 in step with the focused pane
    procedure SyncHostMouse;
    // ask the daemon for a pane size (remote) or apply it (local). The
    // remote mirror is left alone: it follows FRAME_RESIZE_EV, the
    // authoritative answer, so it never grows on a request the daemon then
    // trims -- which pushed the top rows of the mirror into its history.
    procedure RequestPaneSize(i, ACols, ARows: integer);
    procedure FitSessionToWindow;
    procedure ResetSizeRequests;
    procedure WritePaneInput(i: integer; const S: RawByteString);
    procedure PassthroughFiltered(const Data; ALen: integer);
    function PaneClipboardTitle(i: integer): string;
    procedure AddClipboard(const AText: RawByteString;
      AOrigin: TClipboardOrigin; i: integer; AExportHost: boolean);
    procedure PasteClipboardText(const AText: RawByteString);
    procedure PasteLatestClipboard;
    procedure ShowClipboardHistory;
    procedure BeginCopyMode;
    procedure EndCopyMode(ACommit: boolean);
    procedure MoveCopyCursor(ADX, ADY: integer);
    procedure UpdateCopyCursorFromView(APane, ACol, AViewRow: integer;
      AStart, ACommit: boolean);
    function ClipboardCellMarked(APane, AAbsRow, ACol: integer): boolean;
    function HandleCopyKey(var Event: TEvent): boolean;
    procedure DrainPaneOsc52(i: integer; AAlreadyPassed: boolean);
    function AttachRemoteSession(const APath: string): boolean;
    // server-always promotion keeps the already final local windows/screens;
    // it only adopts the newborn daemon transport and its latest snapshots.
    function AttachPromotedSession(const APath: string): boolean;
    // why the last attach attempt failed (empty = generic/none)
    // server-always: converts the freshly built local workspace into a
    // daemon session and attaches to it as a client
    procedure PromoteToServer;
    function PromoteWorkspace(const ARequestedName: string;
      AForce: boolean; AFailClosed: boolean = False): boolean;
    // drops the current remote session by killing its daemon (profile swap)
    procedure LeaveRemoteSession;
    function PickSessionSocketUI(AForAttach: boolean): string;
    function PromptAttachOnStart: boolean;
    procedure DoSessionPick;
    function DoNewSession(APreserveCurrent: boolean = True): boolean;
    function DetachRemoteForSwitch: boolean;
    procedure BuildEmptyWorkspace(AProfile: integer);
    function ProfileStartWindow(AProfile: integer;
      AUseConfiguredWindow: boolean): integer;
    procedure RequestDetach;
    procedure DoSwitchProfile(AIndex: integer);
    procedure DoSwitchWindow(AIndex: integer);
    procedure DoCycleWindow(ADelta: integer);
    procedure RunSessionWizard;
    procedure ShowHelp;
    procedure RebuildMenu;
    procedure RebuildStatusLine;
    function RememberProfileSelection: boolean;
    procedure ApplyTerminalSize(ACols, ARows: integer);
    procedure SyncTerminalSize;
  end;

implementation

uses
  st_keys, st_kbd, st_ssh_entry;

var
  CursorPhase: boolean = False;

function FirstWord(const S: string): string;
var
  i: integer;
begin
  Result := Trim(S);
  i := Pos(' ', Result);
  if i > 0 then
    Result := Copy(Result, 1, i - 1);
end;

// quote only when needed: INI values that start with a quote lose
// their outer quotes when read back (TIniFile trims them)
function NeedsShellQuote(const S: string): boolean;
var
  i: integer;
begin
  Result := S = '';
  for i := 1 to Length(S) do
    if not (S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '.', '/', ':', '=',
      '@', '%', '^', ',', '+', '-']) then
      Exit(True);
end;

function ArgsAsShell(const Args: TStringArray): string;
var
  i: integer;
begin
  Result := '';
  for i := 0 to High(Args) do
  begin
    if i > 0 then
      Result := Result + ' ';
    if NeedsShellQuote(Args[i]) then
      Result := Result + ShellQuote(Args[i])
    else
      Result := Result + Args[i];
  end;
end;

// True if the observed process is just an interactive/login shell:
// capturing it as a command would be redundant (and fragile); empty cmd
function IsPlainShell(const Args: TStringArray; const ACmd: string): boolean;
var
  Base: string;
  i: integer;
begin
  Result := False;
  if Length(Args) > 0 then
    Base := ExtractFileName(Args[0])
  else
    Base := ExtractFileName(ACmd);
  // '-bash' (login shell) and variants
  if (Base <> '') and (Base[1] = '-') then
    Delete(Base, 1, 1);
  if (Base <> 'bash') and (Base <> 'sh') and (Base <> 'zsh') and
     (Base <> 'dash') and (Base <> 'fish') and (Base <> 'ksh') then
    Exit;
  for i := 1 to High(Args) do
    if (Args[i] <> '-i') and (Args[i] <> '-l') and
       (Args[i] <> '--login') and (Args[i] <> '') then
      Exit;
  Result := True;
end;

// CommandWithInteractiveShell and WizardCommand now live in st_wclass,
// shared with the command composition of the window classes.

function ReadTerminalSize(out ACols, ARows: integer): boolean;
var
  Fd: cint;
  WS: TWinSize;
begin
  Result := False;
  ACols := 0;
  ARows := 0;
  for Fd := 0 to 2 do
  begin
    WS := Default(TWinSize);
    if (FpIOCtl(Fd, TIOCGWINSZ, @WS) = 0) and
       (WS.ws_col > 0) and (WS.ws_row > 0) then
    begin
      ACols := WS.ws_col;
      ARows := WS.ws_row;
      Exit(True);
    end;
  end;
end;

var
  // Wireframe drag. The window must stay VISIBLE while the mouse-down is
  // dispatched, otherwise the event never reaches the frame and the vendor's
  // DragView never starts (that mistake made windows undraggable). So we arm
  // it here and hide the window LAZILY, on the first ChangeBounds once
  // DragView has set sfDragging -- its loop pulls mouse events from the
  // application queue, not through view dispatch, so hiding then is safe.
  OutlineArmed: integer = -1;    // pane whose drag should go wireframe
  OutlineOn: boolean = False;    // window hidden and an outline is painted
  OutlineX1, OutlineY1, OutlineX2, OutlineY2: integer;
  // reason the last attach was refused (shown to the user instead of silently
  // starting a fresh local session)
  AttachFailReason: string = '';

function CompactTopMenuFor(AWidth: integer): boolean;
begin
  if CurrentLanguage = ulSpanish then
    Result := AWidth < FULL_TOP_MENU_ES
  else
    Result := AWidth < FULL_TOP_MENU_EN;
end;

procedure ResetVideoSurface;
begin
  if DebugActive then
    DebugLog('fvui: ResetVideoSurface (FORCED full repaint follows)');
  if (VideoBuf <> nil) and (VideoBufSize > 0) then
    FillWord(VideoBuf^, VideoBufSize div SizeOf(Word), $0720);
  // the terminal contents are no longer what we last tracked, so the delta
  // must not be trusted for the next frame (WideUpdateScreen ignores the
  // vendor's own "forced" flag; this is the explicit way to ask for a repaint)
  InvalidateFrame;
  // and the rich overlay describes the PREVIOUS layout: after a resize its
  // entries name cells that no longer belong to whoever registered them, and
  // an oracle can match by coincidence and resurrect a stale glyph. Drop it;
  // every view repopulates it as it draws.
  RichInvalidate;
  // ClearScreen belongs to FPC's console driver, not our renderer. On Unix it
  // writes ESC[H ESC[J immediately, bypassing SuppressFlush and DECSET 2026.
  // During the atomic fullscreen return that exposed a physically blank terminal
  // between the restored IDE and its final repaint. The poisoned old frame is
  // already sufficient to overwrite every cell once flushing resumes.
  if not SuppressFlush then
    ClearScreen;
end;

// Incremental full-tree repaint. TView.DrawView redraws every subview
// (menu, desktop + windows, status) into VideoBuf and then calls
// DrawScreenBuf(false) -> UpdateScreen(false) -> WideUpdateScreen diffs
// against OldVideoBuf and emits ONLY the cells that actually changed.
// The desktop background repaints over any area a closed/shrunk window
// vacated, so no stale cells survive -- without re-sending the whole
// screen the way ResetVideoSurface (blanks OldVideoBuf) + ReDraw
// (drawscreenbuf TRUE, forced) does. Reserve the sledgehammer for real
// video-mode/size changes and coming back from raw passthrough.
procedure TSuperApp.RepaintPane(i: integer);
begin
  if (i < 0) or (i >= MAX_PANES) or (Win[i] = nil) then
    Exit;
  Win[i]^.SyncScrollBar(False);
  if Win[i]^.Term <> nil then
    Win[i]^.Term^.DrawView;
end;

procedure TSuperApp.RepaintChanges;
var
  i: integer;
begin
  if DebugActive then
    DebugLog('fvui: RepaintChanges (incremental DrawView -> diff)');
  for i := 0 to MAX_PANES - 1 do
    if Win[i] <> nil then
      Win[i]^.SyncScrollBar(False);
  DrawView;
end;

// End of startup: release the single boot lock and paint ONCE. If the
// focused pane is maximized we go straight into passthrough (the pane owns
// the terminal and paints itself), so we never even flush the grid version.
procedure TSuperApp.FinishBoot;
begin
  if FBootLocked then
  begin
    SuppressFlush := False;
    FBootLocked := False;
  end;
  // From this point onward one dedicated client reactor owns physical output.
  // Startup CPR/encoding probes deliberately stayed on the old synchronous
  // path; interactive Free Vision, keyboard and mouse must never wait for a
  // slow terminal write.
  StartAsyncVideoOutput;
  HostPasteOn;
  UpdatePassthrough;   // maximized pane -> passthrough, no grid flash
  if not PassthroughActive then
  begin
    if DebugActive then DebugLog('== BOOT: single final paint (forced) ==');
    // OldVideoBuf never tracked the buffered build, so force a full paint
    // of the settled workspace -- this is the ONE unavoidable initial paint
    ReDraw;
  end;
end;


// Return the cell's glyph ONLY when it is a valid, printable, single-codepoint
// UTF-8 sequence; otherwise '?'. The CP437 path was immune to junk because
// TranslitByte collapsed every cell to one byte, but the rich renderer writes
// the bytes straight to the terminal: one stray $E2 makes a UTF-8 decoder
// swallow the two bytes that follow -- which are our next SGR's ESC [ -- and
// the rest of that sequence is printed as text. DEL is a control, not a glyph:
// terminals drop it without advancing, breaking the one-column assumption.
function SafeGlyph(const C: TCell): RawByteString;
var
  i, k, need: integer;
  b0: byte;
  cp: cardinal;
  first: boolean;
begin
  Result := ' ';
  if C.Len = 0 then
    Exit;
  // A cell may hold a BASE codepoint followed by zero-width marks (combining
  // accents, or the U+FE0F selector that turns a symbol into an emoji), so
  // validate the whole sequence, not just one codepoint. Everything must be
  // well-formed UTF-8, and the first codepoint must be printable.
  i := 0;
  first := True;
  while i < C.Len do
  begin
    b0 := byte(C.Txt[i]);
    if b0 < $80 then
    begin
      if (b0 < $20) or (b0 = $7F) then
        Exit('?');            // controls and DEL are not glyphs
      need := 1;
      cp := b0;
    end
    else if (b0 >= $C2) and (b0 <= $DF) then need := 2
    else if (b0 >= $E0) and (b0 <= $EF) then need := 3
    else if (b0 >= $F0) and (b0 <= $F4) then need := 4
    else
      Exit('?');              // $C0, $C1, $F5..$FF are never legal leads
    if i + need > C.Len then
      Exit('?');
    if need > 1 then
    begin
      for k := 1 to need - 1 do
        if (byte(C.Txt[i + k]) and $C0) <> $80 then
          Exit('?');
      case need of
        2: cp := ((b0 and $1F) shl 6) or (byte(C.Txt[i + 1]) and $3F);
        3: cp := ((b0 and $0F) shl 12) or ((byte(C.Txt[i + 1]) and $3F) shl 6) or
                 (byte(C.Txt[i + 2]) and $3F);
      else
        cp := ((b0 and $07) shl 18) or ((byte(C.Txt[i + 1]) and $3F) shl 12) or
              ((byte(C.Txt[i + 2]) and $3F) shl 6) or (byte(C.Txt[i + 3]) and $3F);
      end;
      if ((need = 2) and (cp < $80)) or
         ((need = 3) and (cp < $800)) or
         ((need = 4) and ((cp < $10000) or (cp > $10FFFF))) or
         ((cp >= $D800) and (cp <= $DFFF)) then
        Exit('?');            // overlong, surrogate or out of range
    end;
    first := False;
    Inc(i, need);
  end;
  if first then
    Exit;
  SetLength(Result, C.Len);
  for k := 1 to C.Len do
    Result[k] := C.Txt[k - 1];
end;

function TranslitByte(const C: TCell): AnsiChar;
var
  cp: cardinal;
  b: byte;
begin
  Result := ' ';
  if C.Len = 0 then
    Exit;
  if (C.Attr and A_CONCEAL) <> 0 then
    Exit;                 // SGR 8: concealed, render as a blank
  b := byte(C.Txt[0]);
  if (C.Len = 1) and (b < $80) then
    Exit(AnsiChar(b));
  // decode UTF-8
  case C.Len of
    2: cp := ((b and $1F) shl 6) or (byte(C.Txt[1]) and $3F);
    3: cp := ((b and $0F) shl 12) or ((byte(C.Txt[1]) and $3F) shl 6) or
             (byte(C.Txt[2]) and $3F);
    4: cp := ((b and $07) shl 18) or ((byte(C.Txt[1]) and $3F) shl 12) or
             ((byte(C.Txt[2]) and $3F) shl 6) or (byte(C.Txt[3]) and $3F);
  else
    Exit('?');
  end;
  case cp of
    $00E1, $00E0, $00E2, $00E3, $00E5, $0103: Result := 'a';
    $00E4: Result := 'a';
    $00E9, $00E8, $00EA, $00EB: Result := 'e';
    $00ED, $00EC, $00EE, $00EF: Result := 'i';
    $00F3, $00F2, $00F4, $00F5: Result := 'o';
    $00F6: Result := 'o';
    $00FA, $00F9, $00FB: Result := 'u';
    $00FC: Result := 'u';
    $00F1: Result := 'n';
    $00E7: Result := 'c';
    $00FD, $00FF: Result := 'y';
    $00C1, $00C0, $00C2, $00C3, $00C5, $00C4: Result := 'A';
    $00C9, $00C8, $00CA, $00CB: Result := 'E';
    $00CD, $00CC, $00CE, $00CF: Result := 'I';
    $00D3, $00D2, $00D4, $00D5, $00D6: Result := 'O';
    $00DA, $00D9, $00DB, $00DC: Result := 'U';
    $00D1: Result := 'N';
    $00C7: Result := 'C';
    $00DD: Result := 'Y';
    $00A1: Result := '!';
    $00BF: Result := '?';
    $00BA: Result := 'o';
    $00AA: Result := 'a';
    $20AC: Result := 'E';
    $00B0: Result := 'o';
    $00B7: Result := '.';
    $00A0: Result := ' ';
    $00AB, $00BB: Result := '"';
    $00D7: Result := 'x';
    $00F7: Result := '/';
    $2018, $2019, $201A: Result := '''';
    $201C, $201D: Result := '"';
    $2010, $2011, $2012, $2013, $2014, $2212: Result := '-';
    $2026: Result := '.';
    // box drawing and blocks: CP437 bytes, the driver draws real glyphs
    $2022: Result := #7;                       // bullet
    $2800..$28FF: Result := #250;              // braille (CLI spinners)
    $2500, $2501: Result := #196;              // horizontal line
    $2502, $2503: Result := #179;              // vertical line
    $250C, $250F, $256D: Result := #218;       // corners
    $2510, $2513, $256E: Result := #191;
    $2514, $2517, $2570: Result := #192;
    $2518, $251B, $256F: Result := #217;
    $251C, $2523: Result := #195;              // T junctions
    $2524, $252B: Result := #180;
    $252C, $2533: Result := #194;
    $2534, $253B: Result := #193;
    $253C, $254B: Result := #197;              // full cross
    $2550: Result := #205;                     // double lines
    $2551: Result := #186;
    $2554: Result := #201;
    $2557: Result := #187;
    $255A: Result := #200;
    $255D: Result := #188;
    $2560: Result := #204;                     // double junctions
    $2563: Result := #185;
    $2566: Result := #203;
    $2569: Result := #202;
    $256C, $256A, $256B: Result := #206;
    $2564: Result := #209;
    $2567: Result := #207;
    $2580: Result := #223;                     // half blocks and shades
    $2584: Result := #220;
    $2588: Result := #219;
    $2591: Result := #176;
    $2592: Result := #177;
    $2593: Result := #178;
    $25A0, $25AA, $25FC, $25FE: Result := #254;
    $2190: Result := #27;                      // arrows
    $2191: Result := #24;
    $2192: Result := #26;
    $2193: Result := #25;
    $2194: Result := #29;
    $2195: Result := #18;
    $25B2, $25B4: Result := #30;
    $25BA, $25B6: Result := #16;
    $25BC, $25BE: Result := #31;
    $25C4, $25C0: Result := #17;
    $2713, $2714: Result := 'v';               // check
    $2717, $2718: Result := 'x';
    $E0B0, $E0B1: Result := '>';               // powerline
    $E0B2, $E0B3: Result := '<';
    // circles and dots (bullets from modern CLIs and TUIs) that used
    // to fall back to '?'
    $25CF, $25CB, $25C9, $25CE, $2B24, $23FA, $26AB, $26AA: Result := #7;
    $25E6, $2218, $2219, $2027, $30FB: Result := #250;
    $25AB, $25FB, $25FD, $25A1, $2610: Result := #254;
    // playback and navigation triangles/arrows
    $23F5, $25B7, $2023: Result := #16;        // play / right triangle
    $23F4, $25C1: Result := #17;
    $23F6: Result := #30;
    $23F7: Result := #31;
    // tree continuation (tree branches, return arrows)
    $23BF, $2937, $21B3: Result := #192;
    // decorative asterisks and stars (spinners) -> '*'
    $2733, $2734, $273B, $273C, $273D, $2739, $2735,
    $2724, $2725, $2726, $2727, $272F, $2730: Result := '*';
    $2605, $2606, $2B50: Result := '*';        // stars
    // misc symbols frequent in TUIs
    $2699: Result := '*';                      // gear
    $26A0: Result := '!';                      // warning
    $2764, $2665: Result := #3;                // heart
    $221A: Result := 'v';                      // square root -> visual check
    $2261, $2263: Result := '=';
    $2248: Result := '~';
    $2260: Result := '#';
  else
    Result := '?';
  end;
end;

{ ---------------- TTermView ---------------- }

constructor TTermView.Init(var Bounds: Objects.TRect; APane: integer);
begin
  inherited Init(Bounds);
  PaneIdx := APane;
  Options := Options or ofSelectable or ofTileable;
  // releases and motion too: an application that asked for the mouse gets
  // drags and hover, not just presses
  EventMask := EventMask or evKeyDown or evCommand or evMouseUp or evMouseMove;
end;

procedure TTermView.Draw;
var
  B: TDrawBuffer;
  x, y, w, h: integer;
  ViewX, ViewY, SourceX, SourceY: integer;
  cell: TCell;
  fg, bg: byte;
  App: PSuperApp;
  cx, cy: integer;
  NonBlank: integer;
  Row: TRow;
  RowLen: integer;
  Scrolled: boolean;
  ShowBlk: boolean;
  BlankWord: word;
  GOrig: Objects.TPoint;   // this view's global (screen) origin, computed once
  // rectangles of the windows stacked IN FRONT of this one, in global screen
  // coordinates: cells they cover are theirs, not ours
  FrontR: array[0..MAX_PANES - 1] of Objects.TRect;
  FrontN: integer;
  MyWin, PW: PView;
  PadCell: TCell;    // synthetic blank for padding cells (pane default color)
  DefCell: TCell;    // a true default blank, for trimmed history rows
  DefWord: word;
  AbsY: integer;
  Marked, InvertCell: boolean;

  // Register one cell in the rich overlay at its global screen position, with
  // B[x] (the word just written to VideoBuf) as the oracle. The full UTF-8
  // glyph and exact color (truecolor when the cell carries RGB, else the
  // 16-color fallback) let WideUpdateScreen present the pane area faithfully
  // instead of the CP437/16-color grid. cursor=True inverts (block cursor).
  // True when this global cell is covered by a window stacked in front, so the
  // rich entry there belongs to that window and must not be overwritten.
  // FreeVision clips VideoBuf correctly, but it draws front-to-back, so
  // without this test the BACK pane registers last and wins -- and the oracle
  // cannot catch it, because two blank cells quantise to the same word.
  function Occluded(gx, gy: integer): boolean;
  var
    q: integer;
  begin
    Occluded := False;
    for q := 0 to FrontN - 1 do
      if (gx >= FrontR[q].A.X) and (gx < FrontR[q].B.X) and
         (gy >= FrontR[q].A.Y) and (gy < FrontR[q].B.Y) then
        Exit(True);
  end;

  procedure RichReg(lx, ly: integer; const c: TCell; oracle: word;
    cursor: boolean; nextCont: boolean);
  var
    g: RawByteString;
    ffg, fbg: LongWord;
    fl, k: integer;
    isSkip, isWide: boolean;
  begin
    isSkip := c.Cont;
    if isSkip then
      g := ''
    else if (c.Attr and A_CONCEAL) <> 0 then
      g := ' '            // SGR 8: the application hid this; do not reveal it
    else
      g := SafeGlyph(c);
    fl := 0;
    // Truecolor keeps bold as a weight bit; the 16-color fallback folds bold
    // into a BRIGHT foreground exactly like the old CP437 path (RenderAttr),
    // so bash's "1;32" prompt stays bright green (92) instead of turning into
    // a garish bold+green. Same for a bold default fg -> bright white.
    if c.FgRGB <> 0 then
    begin
      ffg := c.FgRGB;
      if (c.Attr and A_BOLD) <> 0 then fl := fl or 1;
    end
    else if (c.Attr and A_FGDEF) <> 0 then
    begin
      // Bold + DEFAULT fg: keep the default color and carry bold as a weight
      // (";1"), like a real terminal. Do NOT force bright white -- that turned
      // the shell text a different color after Claude (which exits leaving bold
      // set) even though the foreground is the terminal default.
      ffg := 0;
      if (c.Attr and A_BOLD) <> 0 then fl := fl or 1;
    end
    else
    begin
      k := c.Attr and $07;
      // an explicitly bright color (SGR 90-97) or a bold weight both render
      // as the bright half here, which is what the CP437 path always did
      if (c.Attr and (A_BOLD or A_FGBRIGHT)) <> 0 then k := k or 8;
      ffg := $02000000 or LongWord(k);
    end;
    if c.BgRGB <> 0 then
      fbg := c.BgRGB
    else if (c.Attr and A_BGDEF) <> 0 then
      fbg := 0
    else
      fbg := $02000000 or LongWord((c.Attr shr 4) and $0F);
    if (c.Attr and A_UNDER) <> 0 then fl := fl or 2;
    if (c.Attr and A_FAINT) <> 0 then fl := fl or 8;   // SGR 2
    if ((c.Attr and A_REVERSE) <> 0) <> cursor then fl := fl or 4;
    if Occluded(GOrig.X + lx, GOrig.Y + ly) then
      Exit;   // that cell belongs to the window in front; leave its entry alone
    // lead of a two-column glyph: the caller knows whether the next cell of
    // the SAME source row is its continuation (the live grid and a scrollback
    // row are different sources). The emitter needs it to refuse a pair split
    // by a pane edge.
    isWide := (not isSkip) and nextCont;
    RichSetCell(GOrig.X + lx, GOrig.Y + ly, g, ffg, fbg, byte(fl),
      oracle, isSkip, isWide, False);
  end;

  function VideoColor(AAnsiColor: byte): byte;
  begin
    case AAnsiColor and $07 of
      0: Result := 0; // black
      1: Result := 4; // red
      2: Result := 2; // green
      3: Result := 6; // yellow
      4: Result := 1; // blue
      5: Result := 5; // magenta
      6: Result := 3; // cyan
    else
      Result := 7;   // white
    end;
  end;

  function RenderAttr(AAttr: word): word;
  var
    LocalFg, LocalBg, SwapColor: byte;
  begin
    if (AAttr and A_FGDEF) <> 0 then
      LocalFg := 7
    else
      LocalFg := VideoColor(AAttr and $0F);
    if (AAttr and A_BGDEF) <> 0 then
      LocalBg := 0
    else
      LocalBg := VideoColor((AAttr shr 4) and $0F);
    if (AAttr and $0080) <> 0 then
      LocalBg := LocalBg or 8;
    // both the weight bit and the dedicated bright bit map to the same
    // bright half of the 16-color VGA palette on this CP437 path
    if (AAttr and (A_BOLD or A_FGBRIGHT)) <> 0 then
      LocalFg := LocalFg or 8;
    if (AAttr and A_REVERSE) <> 0 then
    begin
      SwapColor := LocalFg;
      LocalFg := LocalBg;
      LocalBg := SwapColor;
    end;
    Result := (word(LocalBg) shl 12) or (word(LocalFg) shl 8);
  end;
begin
  B := Default(TDrawBuffer);
  App := PSuperApp(Application);
  w := Size.X;
  if w > MaxViewWidth then
    w := MaxViewWidth;
  if w < 0 then
    w := 0;
  h := Size.Y;
  if (App = nil) or (App^.Scr[PaneIdx] = nil) then
  begin
    for y := 0 to h - 1 do
    begin
      MoveChar(B, ' ', $07, w);
      WriteBuf(0, y, w, 1, B);
    end;
    Exit;
  end;
  BlankWord := RenderAttr(App^.Scr[PaneIdx].Attr);
  Scrolled := App^.Scr[PaneIdx].ViewOffset > 0;
  // There is no client-local pane viewport. A smaller host clips the common
  // desktop at its outer edge; it never pans an individual pane to its cursor.
  ViewX := 0;
  ViewY := 0;
  cx := App^.Scr[PaneIdx].CursorX - ViewX;
  cy := App^.Scr[PaneIdx].CursorY - ViewY;
  // DECSCUSR 2/4/6 = steady style (no blink); 0/1/3/5 blinks
  ShowBlk := GetState(sfSelected) and (not Scrolled) and
    (not (App^.CopyMode and (App^.CopyPane = PaneIdx))) and
    App^.Scr[PaneIdx].CursorVisible and
    (CursorPhase or (App^.Scr[PaneIdx].CursorStyle in [2, 4, 6]));
  NonBlank := 0;
  // global origin of the view and a blank cell carrying the pane's current
  // color, so padding/empty cells register richly too (a truecolor background
  // Claude painted with spaces still shows)
  GOrig.X := 0;
  GOrig.Y := 0;
  MakeGlobal(GOrig, GOrig);
  // walk the desktop's Z-order from the topmost view up to our own window and
  // remember every visible window in front of it
  FrontN := 0;
  MyWin := nil;
  if (App^.Win[PaneIdx] <> nil) then
    MyWin := PView(App^.Win[PaneIdx]);
  if (Desktop <> nil) and (MyWin <> nil) then
  begin
    PW := Desktop^.First;
    while (PW <> nil) and (PW <> MyWin) and (FrontN < MAX_PANES) do
    begin
      if (PW^.GetState(sfVisible)) then
      begin
        FrontR[FrontN].A := PW^.Origin;
        FrontR[FrontN].B.X := PW^.Origin.X + PW^.Size.X;
        FrontR[FrontN].B.Y := PW^.Origin.Y + PW^.Size.Y;
        // Origin is relative to the desktop; shift to screen coordinates
        Inc(FrontR[FrontN].A.X, Desktop^.Origin.X);
        Inc(FrontR[FrontN].A.Y, Desktop^.Origin.Y);
        Inc(FrontR[FrontN].B.X, Desktop^.Origin.X);
        Inc(FrontR[FrontN].B.Y, Desktop^.Origin.Y);
        Inc(FrontN);
      end;
      PW := PW^.NextView;
    end;
  end;
  DefCell := Default(TCell);
  DefCell.Attr := A_FGDEF or A_BGDEF;
  DefWord := RenderAttr(A_FGDEF or A_BGDEF);
  PadCell := Default(TCell);
  PadCell.Attr := App^.Scr[PaneIdx].Attr;
  PadCell.FgRGB := App^.Scr[PaneIdx].AttrFgRGB;
  PadCell.BgRGB := App^.Scr[PaneIdx].AttrBgRGB;
  for y := 0 to h - 1 do
  begin
    SourceY := y + ViewY;
    if Scrolled then
      AbsY := App^.Scr[PaneIdx].HistoryRows -
        App^.Scr[PaneIdx].ViewOffset + SourceY
    else
      AbsY := App^.Scr[PaneIdx].HistoryRows + SourceY;
    RowLen := 0;
    if (not Scrolled) and (SourceY < App^.Scr[PaneIdx].Height) then
    begin
      for x := 0 to w - 1 do
      begin
         SourceX := x + ViewX;
         if SourceX < App^.Scr[PaneIdx].Width then
         begin
           cell := App^.Scr[PaneIdx].Grid[SourceY][SourceX];
           if (cell.Len > 0) or (cell.Cont) then
             Inc(NonBlank);
           B[x] := RenderAttr(cell.Attr) or word(TranslitByte(cell));
           Marked := App^.ClipboardCellMarked(PaneIdx, AbsY, SourceX);
           InvertCell := Marked or (ShowBlk and (x = cx) and (y = cy));
           if InvertCell then
           begin
             fg := (B[x] shr 8) and $0F;
             bg := (B[x] shr 12) and $0F;
             B[x] := (word(fg) shl 12) or (word(bg) shl 8) or
               word(TranslitByte(cell));
           end;
           RichReg(x, y, cell, B[x], InvertCell,
             (SourceX + 1 < App^.Scr[PaneIdx].Width) and
             App^.Scr[PaneIdx].Grid[SourceY][SourceX + 1].Cont);
         end
         else
         begin
           B[x] := BlankWord or word(' ');
           Marked := App^.ClipboardCellMarked(PaneIdx, AbsY, SourceX);
           if Marked then
           begin
             fg := (B[x] shr 8) and $0F;
             bg := (B[x] shr 12) and $0F;
             B[x] := (word(fg) shl 12) or (word(bg) shl 8) or word(' ');
           end;
           RichReg(x, y, PadCell, B[x], Marked, false);
         end;
      end;
    end
    else if Scrolled then
    begin
      Row := App^.Scr[PaneIdx].DisplayRow(SourceY);
      RowLen := Length(Row);
      for x := 0 to w - 1 do
      begin
        SourceX := x + ViewX;
        if SourceX < RowLen then
         begin
           cell := Row[SourceX];
           if (cell.Len > 0) or (cell.Cont) then
             Inc(NonBlank);
           B[x] := RenderAttr(cell.Attr) or word(TranslitByte(cell));
           Marked := App^.ClipboardCellMarked(PaneIdx, AbsY, SourceX);
           if Marked then
           begin
             fg := (B[x] shr 8) and $0F;
             bg := (B[x] shr 12) and $0F;
             B[x] := (word(fg) shl 12) or (word(bg) shl 8) or
               word(TranslitByte(cell));
           end;
           RichReg(x, y, cell, B[x], Marked,
             (SourceX + 1 < RowLen) and Row[SourceX + 1].Cont);
         end
         else
         begin
           // history rows are stored trimmed: what follows is a true
           // default blank, not the pane's CURRENT attribute -- that would
           // bleed a coloured background over the trimmed tail
           B[x] := DefWord or word(' ');
           Marked := App^.ClipboardCellMarked(PaneIdx, AbsY, SourceX);
           if Marked then
           begin
             fg := (B[x] shr 8) and $0F;
             bg := (B[x] shr 12) and $0F;
             B[x] := (word(fg) shl 12) or (word(bg) shl 8) or word(' ');
           end;
           RichReg(x, y, DefCell, B[x], Marked, false);
         end;
       end;
    end
    else
      for x := 0 to w - 1 do
      begin
        SourceX := x + ViewX;
        B[x] := BlankWord or word(' ');
        Marked := App^.ClipboardCellMarked(PaneIdx, AbsY, SourceX);
        if Marked then
        begin
          fg := (B[x] shr 8) and $0F;
          bg := (B[x] shr 12) and $0F;
          B[x] := (word(fg) shl 12) or (word(bg) shl 8) or word(' ');
        end;
        RichReg(x, y, PadCell, B[x], Marked, false);
      end;
    WriteLine(0, y, w, 1, B);
  end;
  // per-draw detail is FULL-mode only, for the same reason
  if not DebugFull then
  else if Scrolled then
    DebugLog(Format('draw pane=%d scrolled=%d', [PaneIdx, App^.Scr[PaneIdx].ViewOffset]))
  else if NonBlank > 0 then
    DebugLog(Format('draw pane=%d %dx%d nonblank=%d cur=(%d,%d) selected=%d ' +
      'scr=%dx%d view=(%d,%d)',
      [PaneIdx, w, h, NonBlank, App^.Scr[PaneIdx].CursorX, App^.Scr[PaneIdx].CursorY,
       Ord(GetState(sfSelected)), App^.Scr[PaneIdx].Width, App^.Scr[PaneIdx].Height,
       ViewX, ViewY]))
  else
    DebugLog(Format('draw pane=%d %dx%d EMPTY scr=%dx%d hist=%d off=%d alt=%d cur=%d,%d',
      [PaneIdx, w, h, App^.Scr[PaneIdx].Width, App^.Scr[PaneIdx].Height,
       App^.Scr[PaneIdx].HistoryRows, App^.Scr[PaneIdx].ViewOffset,
       Ord(App^.Scr[PaneIdx].UsingAlt), App^.Scr[PaneIdx].CursorX,
       App^.Scr[PaneIdx].CursorY]));
  // terminal cursor in the focused pane
  if Scrolled or (App^.CopyMode and (App^.CopyPane = PaneIdx)) then
  begin
    SetCursor(0, 0);
    HideCursor;
  end
  else
  begin
    if (cx >= 0) and (cx < w) and (cy >= 0) and (cy < h) then
      SetCursor(cx, cy)
    else
      SetCursor(0, 0);
    if (cx >= 0) and (cx < w) and (cy >= 0) and (cy < h) and
       GetState(sfSelected) and App^.Scr[PaneIdx].CursorVisible then
      ShowCursor
    else
      HideCursor;
  end;
end;

procedure TTermView.HandleEvent(var Event: TEvent);
var
  App: PSuperApp;
  seq: RawByteString;
  Local: Objects.TPoint;
begin
  App := PSuperApp(Application);
  if (App = nil) then
  begin
    inherited HandleEvent(Event);
    Exit;
  end;
  if App^.CopyMode and (App^.CopyPane = PaneIdx) and
     ((Event.What and (evMouseDown or evMouseUp or evMouseMove)) <> 0) then
  begin
    if (Event.What = evMouseDown) and ((Event.Buttons and (8 or 16)) <> 0) then
    begin
      if (Event.Buttons and 8) <> 0 then
        App^.MoveCopyCursor(0, -WHEEL_LINES)
      else
        App^.MoveCopyCursor(0, +WHEEL_LINES);
      ClearEvent(Event);
      Exit;
    end;
    Local := Default(Objects.TPoint);
    MakeLocal(Event.Where, Local);
    if (Event.What = evMouseDown) and ((Event.Buttons and 1) <> 0) then
      App^.UpdateCopyCursorFromView(PaneIdx, Local.X, Local.Y, True, False)
    else if (Event.What = evMouseMove) and App^.CopyMouseSelecting then
      App^.UpdateCopyCursorFromView(PaneIdx, Local.X, Local.Y, False, False)
    else if (Event.What = evMouseUp) and App^.CopyMouseSelecting then
      App^.UpdateCopyCursorFromView(PaneIdx, Local.X, Local.Y, False, True);
    ClearEvent(Event);
    Exit;
  end;
  // The application's mouse. This view is strictly the interior of the
  // window, and FreeVision routes positional events to the innermost view
  // under the pointer, so the frame, the title, the menu and the status
  // line never get here: those stay the window manager's with no code at
  // all. Inside, if the application asked for the mouse, it is its --
  // presses, releases, drags, the wheel -- after the click has focused us.
  if ((Event.What and (evMouseDown or evMouseUp or evMouseMove)) <> 0) and
     (App^.Scr[PaneIdx] <> nil) and (App^.Scr[PaneIdx].MouseTrack <> mtOff) then
  begin
    if Event.What = evMouseDown then
      App^.FocusPane(PaneIdx);
    Local := Default(Objects.TPoint);
    MakeLocal(Event.Where, Local);
    if App^.ForwardMouse(PaneIdx, Event, Local) then
    begin
      ClearEvent(Event);
      Exit;
    end;
  end;
  // The wheel. st_kbd maps SGR button 64 (up) to 8 and 65 (down) to 16 --
  // the RTL's numbering; the vendor's mbScrollWheel* names are the other way
  // round, so the literals are used on purpose. It scrolls without taking
  // the focus, like any terminal.
  if (Event.What = evMouseDown) and ((Event.Buttons and (8 or 16)) <> 0) and
     (App^.Scr[PaneIdx] <> nil) then
  begin
    if App^.Scr[PaneIdx].UsingAlt then
    begin
      // no history on the alternate screen: send arrows instead, which is
      // what xterm's alternateScroll does and what makes the wheel work in
      // less, man and vim
      if (Event.Buttons and 8) <> 0 then
        seq := TranslateKey(kbUp, App^.Scr[PaneIdx].AppCursorKeys)
      else
        seq := TranslateKey(kbDown, App^.Scr[PaneIdx].AppCursorKeys);
      App^.WritePaneInput(PaneIdx, seq + seq + seq);
    end
    else
    begin
      if (Event.Buttons and 8) <> 0 then
        App^.Scr[PaneIdx].ScrollViewport(+WHEEL_LINES)
      else
        App^.Scr[PaneIdx].ScrollViewport(-WHEEL_LINES);
      App^.RepaintPane(PaneIdx);
    end;
    ClearEvent(Event);
    Exit;
  end;
  if Event.What = evMouseDown then
  begin
    App^.FocusPane(PaneIdx);
    ClearEvent(Event);
    Exit;
  end;
  if (Event.What = evKeyDown) and (App^.Scr[PaneIdx] <> nil) then
  begin
    // Plain PgUp/PgDn scroll the history too, but only where nothing else
    // wants them: on the normal screen, and only once there is history to
    // move through. An application on the alternate screen (less, vim, a
    // pager) keeps them, and so does a shell before anything has scrolled
    // off. Shift- is the conventional binding where the host terminal lets
    // it through -- most keep it for their own history; Alt- and Ctrl-
    // always work and are the ones to document.
    if ((Event.KeyCode = kbPgUp) or (Event.KeyCode = kbPgDn)) and
       (((Event.KeyShift and kbBothShifts) <> 0) or
        ((not App^.Scr[PaneIdx].UsingAlt) and
         (App^.Scr[PaneIdx].HistoryRows > 0))) then
    begin
      if Event.KeyCode = kbPgUp then
        App^.Scr[PaneIdx].ScrollViewport(+Size.Y)
      else
        App^.Scr[PaneIdx].ScrollViewport(-Size.Y);
      App^.RepaintPane(PaneIdx);
      ClearEvent(Event);
      Exit;
    end;
    case Event.KeyCode of
      kbAltPgUp, kbCtrlPgUp:
        begin
          App^.Scr[PaneIdx].ScrollViewport(+Size.Y);
          App^.RepaintPane(PaneIdx);
          ClearEvent(Event);
          Exit;
        end;
      kbAltPgDn, kbCtrlPgDn:
        begin
          App^.Scr[PaneIdx].ScrollViewport(-Size.Y);
          App^.RepaintPane(PaneIdx);
          ClearEvent(Event);
          Exit;
        end;
      kbAltHome:
        begin
          App^.Scr[PaneIdx].ScrollViewport(MaxInt);
          App^.RepaintPane(PaneIdx);
          ClearEvent(Event);
          Exit;
        end;
      kbAltEnd:
        begin
          App^.Scr[PaneIdx].ScrollViewport(-MaxInt);
          App^.RepaintPane(PaneIdx);
          ClearEvent(Event);
          Exit;
        end;
    end;
  end;
  if (Event.What = evKeyDown) then
  begin
    seq := TranslateKey(Event.KeyCode,
      (App^.Scr[PaneIdx] <> nil) and App^.Scr[PaneIdx].AppCursorKeys);
    if seq <> '' then
    begin
      // a key for the application means "I am done reading": back to live
      if (App^.Scr[PaneIdx] <> nil) and (App^.Scr[PaneIdx].ViewOffset > 0) then
      begin
        App^.Scr[PaneIdx].SetViewOffset(0);
        App^.RepaintPane(PaneIdx);
      end;
      if (App^.Panes[PaneIdx] <> nil) and App^.Panes[PaneIdx].Alive then
      begin
        DebugLog(Format('key pane=%d code=$%.4x len=%d', [PaneIdx, Event.KeyCode, Length(seq)]));
        App^.WritePaneInput(PaneIdx, seq);
      end
      else if App^.RemoteMode then
        App^.WritePaneInput(PaneIdx, seq)
      else if App^.Panes[PaneIdx] = nil then
        DebugLog(Format('key LOST pane=%d pty=nil', [PaneIdx]))
      else
        DebugLog(Format('key LOST pane=%d pty dead', [PaneIdx]));
      ClearEvent(Event);
      Exit;
    end;
  end;
  inherited HandleEvent(Event);
end;

{ ---------------- TTermFrame ---------------- }

procedure TTermFrame.Draw;
var
  B: TDrawBuffer;
  Color: byte;
  W, i, xo, WindowNumber, SavedNumber: integer;
  T: string;
  App: PSuperApp;
  Locked: boolean;
begin
  B := Default(TDrawBuffer);
  App := PSuperApp(Application);
  Locked := (App <> nil) and App^.RemoteMode and (Owner <> nil) and
    (PTermWindow(Owner)^.PaneIdx >= 0) and
    ((App^.RemoteLockedPanes and
      (LongWord(1) shl PTermWindow(Owner)^.PaneIdx)) <> 0);
  // Minimized icon: resolve its frame and title through the same palette
  // chain as a normal window. A literal VGA attribute here would keep the
  // icon blue even when the application palette is monochrome.
  if (Owner <> nil) and PTermWindow(Owner)^.Minimized then
  begin
    W := Size.X;
    if W > MaxViewWidth then
      W := MaxViewWidth;
    if (W < 4) or (Size.Y < 2) then
      Exit;
    T := '';
    if PTermWindow(Owner)^.Title <> nil then
      T := PTermWindow(Owner)^.Title^;
    if Locked then
      T := ' LOCK ' + T;
    if Length(T) > W - 6 then
      T := Copy(T, 1, W - 6);
    T := ' ' + T + ' ';
    if State and sfActive = 0 then
      Color := byte(GetColor($0101))
    else
      Color := byte(GetColor($0503));
    if Locked then
      MoveChar(B, #176, Color, W)
    else
      MoveChar(B, #196, Color, W);
    if Locked then
    begin
      B[0] := (B[0] and $FF00) or word(byte(#177));
      B[W - 1] := (B[W - 1] and $FF00) or word(byte(#177));
    end
    else
    begin
      B[0] := (B[0] and $FF00) or word(byte(#218));
      B[W - 1] := (B[W - 1] and $FF00) or word(byte(#191));
    end;
    xo := (W - Length(T)) div 2;
    for i := 1 to Length(T) do
      B[xo + i - 1] := (B[xo + i - 1] and $FF00) or word(byte(T[i]));
    WriteLine(0, 0, W, 1, B);
    if Locked then
      MoveChar(B, #176, Color, W)
    else
      MoveChar(B, #196, Color, W);
    if Locked then
    begin
      B[0] := (B[0] and $FF00) or word(byte(#177));
      B[W - 1] := (B[W - 1] and $FF00) or word(byte(#177));
    end
    else
    begin
      B[0] := (B[0] and $FF00) or word(byte(#192));
      B[W - 1] := (B[W - 1] and $FF00) or word(byte(#217));
    end;
    WriteLine(0, 1, W, 1, B);
    Exit;
  end;
  WindowNumber := wnNoNumber;
  if Owner <> nil then
    WindowNumber := PTermWindow(Owner)^.Number;
  // FreeVision 3.2.2 intentionally draws a window number only when it is
  // below 10 (vendor/fv322/views.pas:TFrame.Draw).  Let it reserve exactly
  // the normal number/title space for panes 10..16 by drawing a temporary
  // one-digit placeholder, then replace that cell plus its right separator
  // with the real two digits below.  The native close/zoom frame code remains
  // the single source of truth.
  if (WindowNumber >= 10) and (WindowNumber <= MAX_PANES) and
     (Size.X >= 14) then
  begin
    SavedNumber := PTermWindow(Owner)^.Number;
    PTermWindow(Owner)^.Number := 1;
    try
      inherited Draw;
    finally
      PTermWindow(Owner)^.Number := SavedNumber;
    end;
  end
  else
    inherited Draw;
  if (WindowNumber >= 10) and (WindowNumber <= MAX_PANES) and
     (Size.X >= 14) then
  begin
    if State and sfDragging <> 0 then
      Color := byte(GetColor($0505))
    else if State and sfActive = 0 then
      Color := byte(GetColor($0101))
    else
      Color := byte(GetColor($0503));
    T := IntToStr(WindowNumber);
    MoveChar(B, ' ', Color, 2);
    B[0] := (B[0] and $FF00) or word(byte(T[1]));
    B[1] := (B[1] and $FF00) or word(byte(T[2]));
    WriteLine(Size.X - 7, 0, 2, 1, B);
  end;
  // FreeVision has close and zoom buttons but no minimize button. Restore the
  // original SuperTerm control in its traditional slot, immediately before
  // the window number/zoom controls on the right.
  if (Owner <> nil) and (State and sfActive <> 0) and (Size.X >= 14) then
  begin
    Color := byte(GetColor($0503));
    MoveChar(B, ' ', Color, 3);
    B[0] := (B[0] and $FF00) or word('[');
    B[1] := (B[1] and $FF00) or word('-');
    B[2] := (B[2] and $FF00) or word(']');
    WriteLine(Size.X - 10, 0, 3, 1, B);
  end;
  // A lock owned by another client is visible in the border itself. Preserve
  // the title/buttons on the top row; shade both sides, corners and the base.
  if Locked and (Size.X >= 2) and (Size.Y >= 2) then
  begin
    W := Size.X;
    if W > MaxViewWidth then
      W := MaxViewWidth;
    Color := byte(GetColor($0503));
    MoveChar(B, #176, Color, W);
    WriteLine(0, Size.Y - 1, W, 1, B);
    MoveChar(B, #177, Color, 1);
    WriteLine(0, 0, 1, 1, B);
    WriteLine(W - 1, 0, 1, 1, B);
    for i := 1 to Size.Y - 2 do
    begin
      WriteLine(0, i, 1, 1, B);
      WriteLine(W - 1, i, 1, 1, B);
    end;
    if Size.Y >= 6 then
    begin
      T := 'LOCK';
      xo := (Size.Y - Length(T)) div 2;
      if xo < 1 then xo := 1;
      for i := 1 to Length(T) do
      begin
        MoveChar(B, T[i], Color, 1);
        WriteLine(0, xo + i - 1, 1, 1, B);
      end;
    end;
  end;
end;

procedure TTermFrame.HandleEvent(var Event: TEvent);
var
  Mouse: Objects.TPoint;
  App: PSuperApp;
begin
  if Event.What = evMouseDown then
  begin
    App := PSuperApp(Application);
    if (App <> nil) and (Owner <> nil) and
       PTermWindow(Owner)^.Minimized then
    begin
      App^.RestoreWindow(PTermWindow(Owner)^.PaneIdx);
      ClearEvent(Event);
      Exit;
    end;
    if (App <> nil) and (Owner <> nil) then
    begin
      Mouse := Default(Objects.TPoint);
      MakeLocal(Event.Where, Mouse);
      if (State and sfActive <> 0) and (Size.X >= 14) and
         (Mouse.Y = 0) and (Mouse.X >= Size.X - 10) and
         (Mouse.X <= Size.X - 8) then
      begin
        App^.MinimizeWindow(PTermWindow(Owner)^.PaneIdx);
        ClearEvent(Event);
        Exit;
      end;
      App^.FocusPane(PTermWindow(Owner)^.PaneIdx);
    end;
  end;
  inherited HandleEvent(Event);
end;

{ ---------------- TTermWindow ---------------- }

constructor TTermScrollBar.Init(var Bounds: Objects.TRect; APane: integer);
begin
  inherited Init(Bounds);
  PaneIdx := APane;
  Syncing := False;
  // never focused: its key handler would eat the arrows the pane needs
  Options := Options and (not ofSelectable);
end;

procedure TTermScrollBar.ScrollDraw;
var
  App: PSuperApp;
  W: PTermWindow;
begin
  // the vendor's ScrollDraw only broadcasts cmScrollBarChanged; nobody here
  // listens, and the window it would reach is the one we update directly
  if DebugActive then
    DebugLog(Format('scrollbar: ScrollDraw pane=%d value=%d min=%d max=%d syncing=%d',
      [PaneIdx, Value, Min, Max, Ord(Syncing)]));
  if Syncing then
    Exit;
  App := PSuperApp(Application);
  if (App = nil) or (PaneIdx < 0) or (PaneIdx >= MAX_PANES) or
     (App^.Scr[PaneIdx] = nil) then
    Exit;
  // Value counts from the oldest line (0) to live (Max); the model counts
  // lines back from live, so the two are mirror images of each other
  App^.Scr[PaneIdx].SetViewOffset(Max - Value);
  W := PTermWindow(Owner);
  if (W <> nil) and (W^.Term <> nil) then
    W^.Term^.DrawView;
end;

constructor TTermWindow.Init(var Bounds: Objects.TRect; const ATitle: string; APane: integer);
var
  R: Objects.TRect;
begin
  inherited Init(Bounds, ATitle, APane + 1);
  PaneIdx := APane;
  Minimized := False;
  IconSlot := -1;
  Zoomed := False;
  FullScreen := False;
  TitleClickTick := 0;
  TitleClickX := 0;
  TitleClickArmed := False;
  PreviewGestureId := 0;
  PreviewSeq := 0;
  State := State and (not sfShadow);     // no shadow: exact tiling
  R.Assign(1, 1, Bounds.B.X - Bounds.A.X - 1, Bounds.B.Y - Bounds.A.Y - 1);
  Term := New(PTermView, Init(R, APane));
  Insert(Term);
  // the right frame column, rows 1..Size.Y-2: the same rectangle the vendor's
  // StandardScrollBar uses. It paints over the border, costs the pane no
  // column (Term keeps its rectangle, so no PTY resize), leaves the title
  // row and the resize grip alone, and TScrollBar.Init's grow mode keeps it
  // glued to the right edge on every resize. Hidden until there is history.
  R.Assign(Bounds.B.X - Bounds.A.X - 1, 1,
           Bounds.B.X - Bounds.A.X, Bounds.B.Y - Bounds.A.Y - 1);
  SB := New(PTermScrollBar, Init(R, APane));
  Insert(SB);
  SB^.Hide;
  SBShown := False;
end;

function TTermWindow.ActiveFrameAttr: byte;
begin
  // Keep this in lockstep with vendor/fv322/views.pas:TFrame.Draw. Calling
  // GetColor on the window would skip CFrame and therefore address a
  // different palette entry. Frame is installed by TWindow.Init/InitFrame;
  // the neutral fallback only covers a partially constructed window.
  if Frame <> nil then
    Result := byte(Frame^.GetColor($0503))
  else
    Result := $07;
end;

procedure TTermWindow.SetPaneIdx(APane: integer);
begin
  PaneIdx := APane;
  Number := APane + 1;
  if Term <> nil then
    Term^.PaneIdx := APane;
  if SB <> nil then
    SB^.PaneIdx := APane;
end;

procedure TTermWindow.SendGesturePreview(AForce: boolean);
var
  App: PSuperApp;
  R: Objects.TRect;
  Op: byte;
begin
  App := PSuperApp(Application);
  if (PreviewGestureId = 0) or (App = nil) or (not App^.RemoteMode) or
     (App^.Remote = nil) or (not App^.Remote.Connected) or
     ((not AForce) and (not GetState(sfDragging))) then
    Exit;
  R := Default(Objects.TRect);
  GetBounds(R);
  Inc(PreviewSeq);
  if App^.Cfg.DragContent then
    Op := PREVIEW_OP_BOUNDS
  else
    Op := PREVIEW_OP_WIREFRAME;
  // SendLayoutPreview owns the one 16 ms rate limiter. Keeping a second
  // timestamp here caused starvation with a steady 100 Hz mouse: every
  // locally coalesced call moved this deadline although no frame was sent,
  // so observers saw only the first point and the final commit.
  App^.Remote.SendLayoutPreview(PaneIdx, PreviewGestureId,
    App^.Remote.LayoutRevision, PreviewSeq, Op, R.A.X, R.A.Y,
    R.B.X - R.A.X, R.B.Y - R.A.Y, AForce);
end;

procedure TTermWindow.SyncScrollBar(AValueOnly: boolean);
var
  App: PSuperApp;
  Want: boolean;
  Hist, Page: integer;
begin
  if SB = nil then
    Exit;
  App := PSuperApp(Application);
  if (App = nil) or (PaneIdx < 0) or (PaneIdx >= MAX_PANES) or
     (App^.Scr[PaneIdx] = nil) then
    Exit;
  Hist := App^.Scr[PaneIdx].HistoryRows;
  // The bar is shown whenever the pane can have history, even while there is
  // none: hiding it until the first line scrolls off makes a window with a
  // fresh shell look like a build where the feature is missing. With no
  // history the thumb simply fills the trough, which is what every terminal
  // does. It goes away on an icon, on a window too short to hold it, and
  // while the app owns the alternate screen (vim, less, Claude Code): there
  // is no history there and the column is theirs.
  Want := (not Minimized) and (Size.Y > 3) and
          (not App^.Scr[PaneIdx].UsingAlt);
  if (not AValueOnly) and (Want <> SBShown) then
  begin
    if Want then SB^.Show else SB^.Hide;
    SBShown := Want;
  end;
  if not SBShown then
    Exit;
  Page := Size.Y - 2;
  if Page < 1 then Page := 1;
  SB^.Syncing := True;
  SB^.SetParams(Hist - App^.Scr[PaneIdx].ViewOffset, 0, Hist, Page, 1);
  SB^.Syncing := False;
end;

// Restore FreeVision's current view without changing Z order. TView.Select
// normally routes a top-selectable window through MakeFirst; temporarily
// removing that flag exercises TGroup.SetCurrent instead, preserving all of
// its selected/focused broadcasts and invariants through the public API.
procedure RestoreDesktopCurrent(AView: PView);
var
  SavedOptions: Word;
begin
  if (Desktop = nil) or (AView = nil) or
     (Desktop^.Current = AView) then
    Exit;
  SavedOptions := AView^.Options;
  AView^.Options := SavedOptions and (not ofTopSelect);
  try
    AView^.Select;
  finally
    AView^.Options := SavedOptions;
  end;
end;

procedure TTermWindow.HandleEvent(var Event: TEvent);
const
  // KDE's normal physical double-click is commonly around half a second.
  // Measure from completion of click one, not its pre-lock mouse-down.
  TITLE_DOUBLE_CLICK_MS = 650;
var
  App: PSuperApp;
  Dragging, MinimizeHit, ZoomHit, CloseHit, FrameControlHit: boolean;
  TitlePress, TitleWasActive, TitleDouble, BoundsChanged: boolean;
  LayoutLocked, WireframeRelease, SavedSuppress: boolean;
  SavedCurrent: PView;
  Mouse: Objects.TPoint;
  BeforeBounds, AfterBounds: Objects.TRect;
  NowTick: QWord;
begin
  // a click on the minimized icon restores it, before the vendor
  // window selection swallows the event
  if Minimized and (Event.What = evMouseDown) then
  begin
    App := PSuperApp(Application);
    if App <> nil then
    begin
      App^.RestoreWindow(PaneIdx);
      ClearEvent(Event);
      Exit;
    end;
  end;
  // A drag/resize runs a MODAL loop inside the vendor (TView.DragView), so
  // flagging it around the inherited call covers the whole gesture. Only a
  // press on the FRAME drags -- a click inside the pane must not blank it.
  App := PSuperApp(Application);
  MinimizeHit := False;
  ZoomHit := False;
  CloseHit := False;
  TitlePress := False;
  TitleWasActive := False;
  TitleDouble := False;
  LayoutLocked := False;
  Mouse := Default(Objects.TPoint);
  if Event.What = evMouseDown then
  begin
    MakeLocal(Event.Where, Mouse);
    MinimizeHit := (Size.X >= 14) and (Mouse.Y = 0) and
      (Mouse.X >= Size.X - 10) and (Mouse.X <= Size.X - 8);
    CloseHit := (Mouse.Y = 0) and (Mouse.X >= 2) and (Mouse.X <= 4);
    TitlePress := (Mouse.Y = 0) and (not MinimizeHit) and
      (not CloseHit) and
      (not ((Mouse.X >= Size.X - 5) and (Mouse.X <= Size.X - 3)));
    TitleWasActive := State and sfActive <> 0;
    if TitlePress then
    begin
      NowTick := GetTickCount64;
      if TitleWasActive and TitleClickArmed and
         (NowTick >= TitleClickTick) and
         (NowTick - TitleClickTick <= TITLE_DOUBLE_CLICK_MS) and
         (Abs(Mouse.X - TitleClickX) <= 1) then
      begin
        // Preserve a native Event.Double, or supply the one FreeVision lost
        // while the first remote click was completing. Consume the pair so a
        // third click starts a new gesture instead of zooming a second time.
        Event.Double := True;
        TitleClickArmed := False;
      end
      else
      begin
        if not TitleWasActive then
          TitleClickArmed := False;
        if TitleClickArmed and
           ((NowTick < TitleClickTick) or
            (NowTick - TitleClickTick > TITLE_DOUBLE_CLICK_MS) or
            (Abs(Mouse.X - TitleClickX) > 1)) then
          TitleClickArmed := False;
        // A native double whose first click merely focused an inactive pane
        // is not a title double-click. That second click becomes click one;
        // the following click may then zoom, exactly like a desktop WM.
        if Event.Double and (not TitleClickArmed) then
          Event.Double := False;
      end;
      TitleDouble := Event.Double;
    end
    else
      // A click on pane contents or a title control breaks a pending pair.
      // In particular, returning to this title after focusing another view
      // must never turn one new click into a stale double-click.
      TitleClickArmed := False;
    // These are FreeVision's native title controls (see
    // vendor/fv322/views.pas, TFrame.HandleEvent).  A double-click on the
    // active title is zoom too.  None of them is a move gesture.
    ZoomHit := (Mouse.Y = 0) and
      (((Mouse.X >= Size.X - 5) and (Mouse.X <= Size.X - 3)) or
       Event.Double);
  end;
  FrameControlHit := MinimizeHit or ZoomHit or CloseHit;
  Dragging := (App <> nil) and (not Minimized) and
    (((Event.What = evMouseDown) and (not FrameControlHit) and
      (Term <> nil) and
      MouseInView(Event.Where) and (not Term^.MouseInView(Event.Where)) and
      ((SB = nil) or (not SBShown) or (not SB^.MouseInView(Event.Where)))) or
     ((Event.What = evCommand) and (Event.Command = cmResize)));
  if Dragging then
  begin
    // Preview identifiers belong to exactly one acquired pane lease. Never
    // let an identifier from a completed/cancelled modal loop leak into the
    // next physical gesture.
    PreviewGestureId := 0;
    PreviewSeq := 0;
    if DebugActive then DebugLog(Format('drag: ARMED pane=%d',[PaneIdx]));
    // A title drag focuses its window at mouse-down. Focus is deliberately
    // lock-free and shared, so keep it independent from whether geometry
    // ownership is granted below.
    if App <> nil then
      App^.FocusPane(PaneIdx);
    if (App <> nil) and App^.RemoteMode and (App^.Remote <> nil) and
       App^.Remote.Connected then
      // Acquire before the vendor enters its modal move/resize loop. The
      // daemon remains fully event-driven; only this pane's geometry is owned.
      if not App^.LockRemoteLayout(PaneIdx) then
      begin
        ClearEvent(Event);
        Exit;
      end
      else
      begin
        LayoutLocked := True;
        PreviewGestureId := App^.Remote.NewPreviewId;
      end;
    // LockRemoteLayout first restores any preview already rendered by the
    // pane's previous owner. Capture the real canonical starting rectangle,
    // never that superseded cosmetic position.
    BeforeBounds := Default(Objects.TRect);
    GetBounds(BeforeBounds);
    App^.SetGeometryStatus(BeforeBounds, True);
    if not App^.Cfg.DragContent then
      OutlineArmed := PaneIdx; // armed only; hidden later, see ChangeBounds
  end;
  inherited HandleEvent(Event);
  if Dragging then
  begin
    AfterBounds := Default(Objects.TRect);
    GetBounds(AfterBounds);
    BoundsChanged :=
      (BeforeBounds.A.X <> AfterBounds.A.X) or
      (BeforeBounds.A.Y <> AfterBounds.A.Y) or
      (BeforeBounds.B.X <> AfterBounds.B.X) or
      (BeforeBounds.B.Y <> AfterBounds.B.Y);
    WireframeRelease := (App <> nil) and (not App^.Cfg.DragContent) and
      OutlineOn;
    SavedCurrent := nil;
    if WireframeRelease and (Desktop <> nil) then
      SavedCurrent := Desktop^.Current;
    SavedSuppress := SuppressFlush;
    if WireframeRelease then
      SuppressFlush := True;
    try
      if (App <> nil) and (not App^.Cfg.DragContent) then
      begin
        OutlineArmed := -1;
        if OutlineOn then
        begin
          // Clear the ring and restore the real window inside the same
          // suppressed transaction.  Otherwise Show publishes the moved
          // window while ResetCurrent still has the fallback pane selected.
          TransientOutlineClear(PaneIdx);
          OutlineOn := False;
          Show;
          // Show calls ResetCurrent after drawing. Put back the exact local
          // current view which existed at mouse-up: DragView pumps Idle, so a
          // different client may legitimately have focused another pane
          // since this actor started the gesture.
          RestoreDesktopCurrent(SavedCurrent);
        end;
      end;
    finally
      SuppressFlush := SavedSuppress;
    end;
    if WireframeRelease and (not SavedSuppress) then
      UpdateScreen(False);
    if TitlePress and TitleWasActive and (not TitleDouble) and
       (not BoundsChanged) then
    begin
      TitleClickTick := GetTickCount64;
      TitleClickX := Mouse.X;
      TitleClickArmed := True;
    end
    else if BoundsChanged or (not TitlePress) or (not TitleWasActive) then
      TitleClickArmed := False;
    if (App <> nil) and App^.RemoteMode then
    begin
      if BoundsChanged then
      begin
        // The modal DragView loop has consumed mouse-up by now. Publish its
        // exact last visual rectangle before the reliable canonical commit;
        // socket FIFO order makes observers move preview -> final without a
        // jump through the old geometry.
        if LayoutLocked then
          SendGesturePreview(True);
        App^.RemoteGeometryDirty := True;
        App^.RemoteGeomDirtyPanes[PaneIdx] := True;
        // SyncRemoteLayout repeats the idempotent lock and sends the final
        // bounds.  That commit releases ownership in the daemon, so socket
        // ordering keeps it continuous throughout the modal gesture.
        App^.SyncRemoteLayout(PaneIdx);
      end
      else if LayoutLocked and (App^.Remote <> nil) and
              App^.Remote.Connected then
        // A click without movement is focus/double-click input, not a layout
        // revision. Release its gesture lease without resending unchanged
        // geometry; this also lets click two reach the detector promptly.
        App^.Remote.UnlockLayout(PaneIdx);
    end;
    PreviewGestureId := 0;
    PreviewSeq := 0;
    App^.SetGeometryStatus(AfterBounds, False);
  end;
end;

procedure TTermWindow.SizeLimits(var Min, Max: Objects.TPoint);
var
  App: PSuperApp;
begin
  inherited SizeLimits(Min, Max);
  App := PSuperApp(Application);
  if (App <> nil) and App^.RemoteMode and
     (App^.RemoteDeskW > 0) and (App^.RemoteDeskH > 0) then
  begin
    // Every viewer uses the daemon desktop as its sizing limit. A physically
    // smaller terminal clips these bounds; it never substitutes its own.
    Max.X := App^.RemoteDeskW;
    Max.Y := App^.RemoteDeskH;
  end;
  if Minimized then
  begin
    // the minimized icon is a small 2-row bar
    Min.X := 10;
    Min.Y := 2;
  end;
end;

procedure TTermWindow.InitFrame;
var
  R: Objects.TRect;
begin
  R := Default(Objects.TRect);
  GetExtent(R);
  Frame := New(PTermFrame, Init(R));
end;

procedure TTermWindow.ChangeBounds(var Bounds: Objects.TRect);
var
  R: Objects.TRect;
  App: PSuperApp;
  SavedCurrent: PView;
  pw, ph: integer;
  gx1, gy1, gx2, gy2: integer;
  FrameAttr: byte;
  PreviewVisualChanged, FirstWireStep, SavedSuppress: boolean;
begin
  PreviewVisualChanged := False;
  SavedCurrent := nil;
  FirstWireStep := (OutlineArmed = PaneIdx) and (Desktop <> nil) and
    GetState(sfDragging) and (not OutlineOn);
  SavedSuppress := SuppressFlush;
  if FirstWireStep then
    SuppressFlush := True;
  try
    if FirstWireStep then
    begin
      // DragView has already taken ownership of the modal mouse gesture
      // before calling ChangeBounds (vendor/fv322/views.pas). Hide the old
      // rectangle before applying the first proposed one. TGroup.Lock alone
      // is not a physical-output barrier, hence the enclosing SuppressFlush.
      SavedCurrent := Desktop^.Current;
      Desktop^.Lock;
      try
        Hide;
        // DragView pumps Idle while its mouse loop is active, so another
        // client may have supplied a newer shared focus. Preserve exactly the
        // Current that existed at this step; never hard-code the actor pane.
        RestoreDesktopCurrent(SavedCurrent);
      finally
        Desktop^.Unlock;
      end;
    end;
    inherited ChangeBounds(Bounds);
    App := PSuperApp(Application);
    if (App <> nil) and GetState(sfDragging) then
      App^.SetGeometryStatus(Bounds, True);
    // Wireframe drag, step by step. The real window stays hidden: VideoBuf
    // therefore contains the actual uncovered desktop and the renderer owns
    // the transient ring above it.
    if (OutlineArmed = PaneIdx) and (Desktop <> nil) and
       GetState(sfDragging) then
    begin
      FrameAttr := ActiveFrameAttr;
      gx1 := Desktop^.Origin.X + Bounds.A.X;
      gy1 := Desktop^.Origin.Y + Bounds.A.Y;
      gx2 := Desktop^.Origin.X + Bounds.B.X - 1;
      gy2 := Desktop^.Origin.Y + Bounds.B.Y - 1;
      if DebugActive then
        DebugLog(Format('drag: step pane=%d rect=%d,%d..%d,%d on=%d',
          [PaneIdx, gx1, gy1, gx2, gy2, Ord(OutlineOn)]));
      if FirstWireStep or
         (((gx1 <> OutlineX1) or (gy1 <> OutlineY1) or
           (gx2 <> OutlineX2) or (gy2 <> OutlineY2)) and
          (not InputPending)) then
      begin
        // The compositor invalidates only the old/new rings plus wide-glyph
        // partners, so a one-cell step is a small delta rather than two full
        // perimeters.
        TransientOutlineSet(PaneIdx, gx1, gy1, gx2, gy2, FrameAttr);
        if FirstWireStep then
          OutlineOn := True;
        OutlineX1 := gx1; OutlineY1 := gy1;
        OutlineX2 := gx2; OutlineY2 := gy2;
        PreviewVisualChanged := True;
      end;
    end;
    if Term <> nil then
    begin
      R.Assign(1, 1, Bounds.B.X - Bounds.A.X - 1,
        Bounds.B.Y - Bounds.A.Y - 1);
      if (R.B.X > R.A.X) and (R.B.Y > R.A.Y) then
        Term^.Locate(R);
    end;
  finally
    if FirstWireStep then
    begin
      try
        // If FreeVision rejected the proposed bounds or a drawing operation
        // raised before the compositor accepted its ring, do not strand a
        // hidden window behind a logically inactive gesture.
        if not OutlineOn then
        begin
          TransientOutlineClear(PaneIdx);
          Show;
          RestoreDesktopCurrent(SavedCurrent);
        end;
      finally
        SuppressFlush := SavedSuppress;
        if not SavedSuppress then
          UpdateScreen(False);
      end;
    end;
  end;
  // Never hold a visual transaction across socket I/O or PTY bookkeeping.
  // A slow peer may delay its preview, but cannot freeze an already-built
  // local frame behind SuppressFlush.
  if PreviewVisualChanged and (not FirstWireStep) then
    UpdateScreen(False);
  App := PSuperApp(Application);
  if (App <> nil) and App^.RemoteMode and
     (App^.Cfg.DragContent or PreviewVisualChanged) then
    SendGesturePreview(False);
  if (App <> nil) and App^.RemoteMode and App^.RemoteAttachSettling then
    Exit;   // attach does ONE final pass with the definitive geometry
  if (App <> nil) and (App^.PassPane = PaneIdx) then
    Exit;   // passthrough owns the full terminal; keep the pane at that size
  if (App <> nil) and (not Minimized) and (App^.Scr[PaneIdx] <> nil) then
  begin
    pw := Size.X - 2;
    ph := Size.Y - 2;
    if pw < 4 then pw := 4;
    if ph < 2 then ph := 2;
    if DebugActive and
       ((pw <> App^.Scr[PaneIdx].Width) or (ph <> App^.Scr[PaneIdx].Height)) then
      DebugLog(Format('resize: pane=%d window %dx%d -> request %dx%d (mirror %dx%d)',
        [PaneIdx, Size.X, Size.Y, pw, ph, App^.Scr[PaneIdx].Width,
         App^.Scr[PaneIdx].Height]));
    App^.RequestPaneSize(PaneIdx, pw, ph);
  end;
end;

procedure TTermWindow.Zoom;
var
  App: PSuperApp;
  i: integer;
  WasZoomed: boolean;
  R: Objects.TRect;
begin
  App := PSuperApp(Application);
  WasZoomed := Zoomed;
  if (App <> nil) and (not WasZoomed) then
    for i := 0 to MAX_PANES - 1 do
      if (i <> PaneIdx) and (App^.Win[i] <> nil) and
         App^.Win[i]^.Zoomed then
        App^.Win[i]^.Zoom;
  if (App <> nil) and App^.RemoteMode then
  begin
    // FreeVision's TWindow.Zoom infers enter/leave by comparing Size with
    // SizeLimits.Max. A shared maximum may deliberately be smaller than the
    // canonical desktop, so that inference would treat an unzoom as another
    // zoom and overwrite ZoomRect. The explicit state is authoritative here.
    if WasZoomed then
    begin
      R := ZoomRect;
      Locate(R);
    end
    else
    begin
      GetBounds(ZoomRect);
      // Authoritative layout application immediately places this view at the
      // daemon's canonical Cols/Rows.  Do not derive a different rectangle
      // from this viewer's current membership summary here: an attach must
      // never make two clients draw two versions of the same shared window.
      R.Assign(0, 0, App^.RemoteDeskW, App^.RemoteDeskH);
      Locate(R);
    end;
  end
  else
    inherited Zoom;
  Zoomed := not WasZoomed;
  if WasZoomed then
    FullScreen := False;   // back to a window: nothing owns the terminal
  if (App <> nil) and App^.RemoteMode and (not App^.RemoteAttachSettling) then
  begin
    App^.RemoteGeometryDirty := True;
    for i := 0 to MAX_PANES - 1 do
      if (App^.Win[i] <> nil) and (i < Length(App^.RemoteGeom)) and
         ((App^.RemoteGeom[i].Zoomed <> App^.Win[i]^.Zoomed) or
          (App^.RemoteGeom[i].FullScreen <> App^.Win[i]^.FullScreen)) then
        App^.RemoteGeomDirtyPanes[i] := True;
  end;
end;

procedure TTermWindow.Close;
var
  App: PSuperApp;
begin
  App := PSuperApp(Application);
  if App <> nil then
    App^.DoClosePane(PaneIdx)
  else
    inherited Close;
end;

procedure TTermWindow.Minimize;
begin
  if not Minimized then
  begin
    // Turbo Vision style icon: the window stays visible as a small bar;
    // the application places it at the bottom with ArrangeIcons
    GetBounds(SavedRect);
    Minimized := True;
    Options := Options and (not ofTileable); // out of the vendor Tile
    if Term <> nil then
      Term^.Hide; // the icon is only frame and title
    if (SB <> nil) and SBShown then
    begin
      SB^.Hide;
      SBShown := False;   // the next sync decides again once restored
    end;
  end;
end;

procedure TTermWindow.Restore;
begin
  if Minimized then
  begin
    Minimized := False; // the caller relocates via RelayoutAll
    Options := Options or ofTileable;
    if Term <> nil then
      Term^.Show;
  end;
end;

procedure TTermWindow.SetTitle(const S: string);
begin
  if Title <> nil then
    DisposeStr(Title);
  Title := Objects.NewStr(S);
  if Frame <> nil then
    Frame^.DrawView;
end;

{ ---------------- TSuperApp ---------------- }

constructor TDesktopScrollBar.Init(var Bounds: Objects.TRect; AAxis: byte);
var
  OrientedBounds: Objects.TRect;
begin
  // TScrollBar chooses its private arrow glyph table only in Init, from the
  // initial shape (width=1 means vertical). ChangeBounds does not revisit it,
  // so a shared 1x1 placeholder made the horizontal bar draw ^/V forever.
  OrientedBounds := Bounds;
  if AAxis = 0 then
    OrientedBounds.Assign(Bounds.A.X, Bounds.A.Y,
      Bounds.A.X + 2, Bounds.A.Y + 1)
  else
    OrientedBounds.Assign(Bounds.A.X, Bounds.A.Y,
      Bounds.A.X + 1, Bounds.A.Y + 2);
  inherited Init(OrientedBounds);
  Axis := AAxis;
  Options := Options and not ofSelectable;
end;

procedure TDesktopScrollBar.ScrollDraw;
var
  App: PSuperApp;
begin
  App := PSuperApp(Application);
  if (App = nil) or App^.ViewportSyncing then
    Exit;
  if Axis = 0 then
    App^.SetDesktopViewport(Value, App^.ViewportY)
  else
    App^.SetDesktopViewport(App^.ViewportX, Value);
end;

procedure TDesktopBackdrop.Draw;
var
  App: PSuperApp;
  B: TDrawBuffer;
  Attr: byte;
  W: integer;
begin
  App := PSuperApp(Application);
  Attr := 0;
  if App <> nil then
    Attr := byte((App^.Cfg.DesktopColor and $0F) shl 4);
  W := Size.X;
  if W > MaxViewWidth then W := MaxViewWidth;
  if W < 0 then W := 0;
  B := Default(TDrawBuffer);
  MoveChar(B, ' ', Attr, W);
  WriteLine(0, 0, W, Size.Y, B);
end;

constructor TDesktopNotification.Init(var Bounds: Objects.TRect);
begin
  inherited Init(Bounds);
  // FreeVision dispatches a positional event to the first visible view under
  // the pointer even when that view has no event mask. TArtDesktop temporarily
  // takes this cosmetic view out of that hit-test, so it can never eat a pane
  // click; keeping it non-selectable also makes Show/Hide focus-neutral.
  Options := Options and not ofSelectable;
  EventMask := 0;
  GrowMode := 0;
  Text := '';
end;

procedure TDesktopNotification.Draw;
var
  B: TDrawBuffer;
  W: integer;
  FrameAttr, TextAttr: byte;
  S: string;
begin
  W := Size.X;
  if W < 1 then
    Exit;
  FrameAttr := byte(GetColor($0503));
  TextAttr := byte(GetColor($0604));
  S := Copy(Text, 1, W - 2);

  B := Default(TDrawBuffer);
  MoveChar(B, ' ', TextAttr, W);
  if W >= 2 then
  begin
    B[0] := (word(FrameAttr) shl 8) or word(#218);
    B[W - 1] := (word(FrameAttr) shl 8) or word(#191);
    if W > 2 then
      MoveChar(B[1], #196, FrameAttr, W - 2);
  end;
  WriteLine(0, 0, W, 1, B);

  if Size.Y >= 2 then
  begin
    B := Default(TDrawBuffer);
    MoveChar(B, ' ', TextAttr, W);
    if W >= 2 then
    begin
      B[0] := (word(FrameAttr) shl 8) or word(#179);
      B[W - 1] := (word(FrameAttr) shl 8) or word(#179);
    end;
    if W > 2 then
      MoveStr(B[1], S, TextAttr);
    WriteLine(0, 1, W, 1, B);
  end;

  if Size.Y >= 3 then
  begin
    B := Default(TDrawBuffer);
    MoveChar(B, ' ', TextAttr, W);
    if W >= 2 then
    begin
      B[0] := (word(FrameAttr) shl 8) or word(#192);
      B[W - 1] := (word(FrameAttr) shl 8) or word(#217);
      if W > 2 then
        MoveChar(B[1], #196, FrameAttr, W - 2);
    end;
    WriteLine(0, 2, W, 1, B);
  end;
end;

constructor TMemberStatusOverlay.Init(var Bounds: Objects.TRect);
begin
  inherited Init(Bounds);
  Options := Options and not ofSelectable;
  EventMask := 0;
  // Its left edge is anchored after the fixed shortcuts while its right edge
  // follows the terminal. Repositioning on a notification covers shrink too.
  GrowMode := gfGrowLoY + gfGrowHiX + gfGrowHiY;
  Text := '';
end;

procedure TMemberStatusOverlay.Draw;
var
  B: TDrawBuffer;
  W: integer;
  NormalAttr, TextAttr: byte;
begin
  W := Size.X;
  if W < 1 then
    Exit;
  NormalAttr := byte(GetColor($0301));
  TextAttr := byte(GetColor($0604));
  B := Default(TDrawBuffer);
  MoveChar(B, ' ', NormalAttr, W);
  if W > 0 then
    B[0] := (word(NormalAttr) shl 8) or word(#179);
  if W > 2 then
    MoveStr(B[2], Copy(Text, 1, W - 2), TextAttr);
  WriteLine(0, 0, W, 1, B);
end;

// The visible status shortcuts are the fixed left boundary of the client
// activity overlay. Keeping that arithmetic in one helper makes language and
// prefix changes update the boundary together with InitStatusLine.
function StatusQuickItemsEnd(const Cfg: TConfig): integer;
  function ItemWidth(const S: string): integer;
  begin
    Result := CStrLen(' ' + S + ' ');
  end;
var
  Prefix: string;
begin
  Prefix := PrefixKeyLabel(Cfg.PrefixKey);
  Result := ItemWidth(UiText('~F2~ Split', '~F2~ Dividir')) +
    ItemWidth(UiText('~F6~ Pane', '~F6~ Panel')) +
    ItemWidth(UiText('~F8~ Window', '~F8~ Ventana')) +
    ItemWidth(UiText('~' + Prefix + ' f~ Full screen',
      '~' + Prefix + ' f~ Pantalla')) +
    ItemWidth(UiText('~' + Prefix + ' d~ Detach',
      '~' + Prefix + ' d~ Separar'));
end;

procedure TGeometryStatusLine.Draw;
var
  App: PSuperApp;
  B: TDrawBuffer;
  S: string;
  X, L: integer;
begin
  inherited Draw;
  App := PSuperApp(Application);
  if App = nil then
    Exit;
  S := '';
  if App^.GeometryStatusActive then
  begin
    S := Format(UiText(' Window %d,%d  %dx%d ',
                       ' Ventana %d,%d  %dx%d '),
      [App^.GeometryStatusX, App^.GeometryStatusY,
       App^.GeometryStatusW, App^.GeometryStatusH]);
    if Length(S) > Size.X then
      S := Copy(S, Length(S) - Size.X + 1, Size.X);
  end;
  L := Length(S);
  if S <> '' then
  begin
    X := Size.X - L;
    if X < 0 then X := 0;
    B := Default(TDrawBuffer);
    // Use the status/menu selected pair, never a literal colour. This makes
    // the live geometry a clearly delimited status block in color, light/BW
    // and monochrome palettes alike.
    MoveStr(B, S, byte(GetColor($0604)));
    WriteLine(X, 0, L, 1, B);
  end;
end;

procedure TArtDesktop.HandleEvent(var Event: TEvent);
var
  App: PSuperApp;
  Toast: PDesktopNotification;
begin
  App := PSuperApp(Application);
  Toast := nil;
  if App <> nil then
    Toast := App^.DesktopNotification;
  if (Toast <> nil) and Toast^.GetState(sfVisible) and
     ((Event.What and PositionalEvents) <> 0) and
     Toast^.MouseInView(Event.Where) then
  begin
    // TGroup selects the first visible view under a mouse event before it
    // inspects EventMask. Remove this purely visual overlay from that one
    // hit-test without emitting a hide/show frame, then restore and redraw it.
    Toast^.State := Toast^.State and not sfVisible;
    try
      inherited HandleEvent(Event);
    finally
      Toast^.State := Toast^.State or sfVisible;
    end;
    Toast^.DrawView;
  end
  else
    inherited HandleEvent(Event);
end;

procedure TSuperApp.SetGeometryStatus(const R: Objects.TRect;
  AActive: boolean);
begin
  GeometryStatusActive := AActive;
  if AActive then
  begin
    GeometryStatusX := R.A.X;
    GeometryStatusY := R.A.Y;
    GeometryStatusW := R.B.X - R.A.X;
    GeometryStatusH := R.B.Y - R.A.Y;
  end;
  if StatusLine <> nil then
    StatusLine^.DrawView;
end;

function TSuperApp.MemberNoticeStatusText(AAvailable: integer): string;
var
  Notice: TMemberNotice;
  FullText: string;
begin
  Result := '';
  if (not MemberNoticeActive) or (MemberNoticeHead < 0) or
     (MemberNoticeHead >= Length(MemberNotices)) then
    Exit;
  Notice := MemberNotices[MemberNoticeHead];
  if Notice.Kind = mnConnected then
    FullText := UiText('Client connected: ', 'Cliente conectado: ')
  else
    FullText := UiText('Client disconnected: ', 'Cliente desconectado: ');
  FullText := FullText + IntToStr(Notice.ClientCount) +
    UiText(' clients', ' clientes');
  if Length(FullText) > AAvailable then
  begin
    if Notice.Kind = mnConnected then
      Result := '+' + IntToStr(Notice.ClientCount)
    else
      Result := '-' + IntToStr(Notice.ClientCount);
  end
  else
    Result := FullText;
end;

function TSuperApp.MemberNoticeDesktopText: string;
var
  Notice: TMemberNotice;
begin
  Result := '';
  if (not MemberNoticeActive) or (MemberNoticeHead < 0) or
     (MemberNoticeHead >= Length(MemberNotices)) then
    Exit;
  Notice := MemberNotices[MemberNoticeHead];
  case Notice.Kind of
    mnConnected: Result := UiText(' User connected ', ' Usuario conectado ');
    mnDisconnected: Result := UiText(' User disconnected ',
      ' Usuario desconectado ');
  end;
end;

procedure TSuperApp.RefreshMemberNoticeViews;
var
  R, StatusR: Objects.TRect;
  S, GeometryText: string;
  ToastW, StatusW, StatusStart, StatusRight, GeometryLen: integer;
  ShowDesktopToast, ShowStatus, SavedSuppress: boolean;
begin
  ShowDesktopToast := MemberNoticeActive and Cfg.DesktopNotifications and
    (not PassthroughActive) and (Desktop <> nil) and
    (DesktopNotification <> nil);
  GeometryLen := 0;
  if GeometryStatusActive then
  begin
    GeometryText := Format(UiText(' Window %d,%d  %dx%d ',
      ' Ventana %d,%d  %dx%d '), [GeometryStatusX, GeometryStatusY,
      GeometryStatusW, GeometryStatusH]);
    GeometryLen := Length(GeometryText);
    if GeometryLen > Size.X then
      GeometryLen := Size.X;
  end;
  StatusStart := StatusQuickItemsEnd(Cfg);
  StatusRight := Size.X - GeometryLen;
  StatusW := StatusRight - StatusStart;
  ShowStatus := MemberNoticeActive and (not PassthroughActive) and
    (StatusW > 2);
  SavedSuppress := SuppressFlush;
  SuppressFlush := True;
  try
    if DesktopNotification <> nil then
    begin
      if ShowDesktopToast then
      begin
        S := MemberNoticeDesktopText;
        ToastW := Length(S) + 2;
        if ToastW < 20 then ToastW := 20;
        if (Desktop <> nil) and (ToastW > Desktop^.Size.X) then
          ToastW := Desktop^.Size.X;
        if ToastW < 3 then ToastW := 3;
        R.Assign(0, 0, ToastW, 3);
        DesktopNotification^.Text := S;
        if (DesktopNotification^.Origin.X <> R.A.X) or
           (DesktopNotification^.Origin.Y <> R.A.Y) or
           (DesktopNotification^.Size.X <> ToastW) or
           (DesktopNotification^.Size.Y <> 3) then
          DesktopNotification^.ChangeBounds(R);
        // Inserted window panes naturally become first. Raise this local
        // cosmetic view only while it is active; it is non-selectable, so
        // this cannot change the shared focus.
        DesktopNotification^.MakeFirst;
        DesktopNotification^.Show;
      end
      else
        DesktopNotification^.Hide;
    end;

    // The stock FreeVision status line redraws itself from private state when
    // its help context changes. A small root-level view is therefore the
    // reliable client-local tail: it is painted after that stock row, never
    // changes shared desktop state, and leaves geometry text at the right.
    if ShowStatus and (MemberStatusOverlay = nil) then
    begin
      StatusR.Assign(0, 0, 1, 1);
      MemberStatusOverlay := New(PMemberStatusOverlay, Init(StatusR));
      if MemberStatusOverlay <> nil then
      begin
        MemberStatusOverlay^.Hide;
        Insert(PView(MemberStatusOverlay));
      end;
    end;
    if MemberStatusOverlay <> nil then
    begin
      if ShowStatus then
      begin
        StatusR.Assign(StatusStart, Size.Y - 1, StatusRight, Size.Y);
        MemberStatusOverlay^.Text := MemberNoticeStatusText(StatusW - 2);
        if (MemberStatusOverlay^.Origin.X <> StatusR.A.X) or
           (MemberStatusOverlay^.Origin.Y <> StatusR.A.Y) or
           (MemberStatusOverlay^.Size.X <> StatusW) or
           (MemberStatusOverlay^.Size.Y <> 1) then
          MemberStatusOverlay^.ChangeBounds(StatusR);
        MemberStatusOverlay^.MakeFirst;
        MemberStatusOverlay^.Show;
      end
      else
        MemberStatusOverlay^.Hide;
    end;
  finally
    SuppressFlush := SavedSuppress;
  end;
  // One full-tree buffer build makes the status and the toast appear/vanish
  // atomically. The renderer emits only changed cells, so it does not resend
  // pane content or make a transition flash.
  if (not SavedSuppress) and (not PassthroughActive) then
  begin
    RepaintChanges;
    // A changed Text field does not itself invalidate a bare TView. Draw the
    // already-topmost local tail explicitly after the shared tree has settled
    // so each FIFO event replaces its count without waiting for another UI
    // action or re-sending pane contents.
    if ShowStatus and (MemberStatusOverlay <> nil) then
      MemberStatusOverlay^.DrawView;
  end;
end;

procedure TSuperApp.QueueMemberNotice(AKind: TMemberNoticeKind;
  AClientCount: integer);
var
  N: integer;
begin
  if AClientCount < 0 then
    Exit;
  N := Length(MemberNotices);
  SetLength(MemberNotices, N + 1);
  MemberNotices[N].Kind := AKind;
  MemberNotices[N].ClientCount := AClientCount;
  // This is deliberately a host-terminal byte, never pane input/output.
  // Each daemon-ordered membership event calls it exactly once.
  HostBell;
  if DebugFull then
    DebugLog(Format('member-notice: queued kind=%d clients=%d pending=%d',
      [Ord(AKind), AClientCount, Length(MemberNotices) - MemberNoticeHead]));
end;

procedure TSuperApp.UpdateMemberNotices(ANow: QWord);
var
  Remaining, I: integer;
  Changed: boolean;
begin
  Changed := False;
  // The raw fullscreen pane owns physical output. Preserve the visual timer
  // exactly where it is, while QueueMemberNotice has already sounded every
  // independent bell at event arrival.
  if PassthroughActive then
  begin
    if MemberNoticeActive and (not MemberNoticePaused) then
    begin
      MemberNoticePaused := True;
      MemberNoticePauseTick := ANow;
    end;
    Exit;
  end;
  if MemberNoticePaused then
  begin
    if ANow > MemberNoticePauseTick then
      Inc(MemberNoticeUntil, ANow - MemberNoticePauseTick);
    MemberNoticePaused := False;
  end;
  if MemberNoticeActive and (ANow >= MemberNoticeUntil) then
  begin
    Inc(MemberNoticeHead);
    MemberNoticeActive := False;
    Changed := True;
    // Compact only consumed records. No live membership event is merged or
    // discarded: every queued desktop toast remains an individual event.
    if (MemberNoticeHead >= 32) and
       (MemberNoticeHead * 2 >= Length(MemberNotices)) then
    begin
      Remaining := Length(MemberNotices) - MemberNoticeHead;
      for I := 0 to Remaining - 1 do
        MemberNotices[I] := MemberNotices[MemberNoticeHead + I];
      SetLength(MemberNotices, Remaining);
      MemberNoticeHead := 0;
    end;
  end;
  if (not MemberNoticeActive) and
     (MemberNoticeHead < Length(MemberNotices)) then
  begin
    MemberNoticeActive := True;
    MemberNoticeUntil := ANow + MEMBER_NOTICE_MS;
    Changed := True;
  end;
  if Changed then
    RefreshMemberNoticeViews;
end;

procedure TSuperApp.InitViewportViews;
var
  R: Objects.TRect;
begin
  ViewportX := 0;
  ViewportY := 0;
  ViewportW := 0;
  ViewportH := 0;
  ViewportHVisible := False;
  ViewportVVisible := False;
  ViewportSyncing := False;
  DesktopHBar := nil;
  DesktopVBar := nil;
  DesktopCorner := nil;
  DesktopBackdrop := nil;
  DesktopNotification := nil;
  if Desktop = nil then
    Exit;

  R.Assign(0, 0, 1, 1);
  DesktopBackdrop := New(PDesktopBackdrop, Init(R));
  DesktopHBar := New(PDesktopScrollBar, Init(R, 0));
  DesktopVBar := New(PDesktopScrollBar, Init(R, 1));
  DesktopCorner := New(PDesktopBackdrop, Init(R));
  DesktopNotification := New(PDesktopNotification, Init(R));
  DesktopHBar^.Hide;
  DesktopVBar^.Hide;
  DesktopCorner^.Hide;
  DesktopNotification^.Hide;

  // First is frontmost in this FreeVision view ring.  The filler is behind
  // the logical desktop; bars/corner sit immediately in front of it while the
  // menu and status line, already inserted by TProgram, stay in front of all.
  InsertBefore(PView(DesktopBackdrop), nil);
  InsertBefore(PView(DesktopHBar), PView(Desktop));
  InsertBefore(PView(DesktopVBar), PView(Desktop));
  InsertBefore(PView(DesktopCorner), PView(Desktop));
  Desktop^.Insert(PView(DesktopNotification));
  PArtDesktop(Desktop)^.GrowMode := 0;
  UpdateDesktopViewport(True);
end;

procedure TSuperApp.CanonicalDesktopSize(out AWidth, AHeight: integer);
begin
  AWidth := 0;
  AHeight := 0;
  if Desktop <> nil then
  begin
    AWidth := Desktop^.Size.X;
    AHeight := Desktop^.Size.Y;
  end;
end;

procedure TSuperApp.UpdateDesktopViewport(AReset: boolean);
var
  DeskW, DeskH, TopY, BottomY, AvailW, AvailH: integer;
  NewViewW, NewViewH, MaxX, MaxY, PageX, PageY: integer;
  NeedH, NeedV, OldH, OldV: boolean;
  R: Objects.TRect;
begin
  if (Desktop = nil) or (DesktopHBar = nil) or (DesktopVBar = nil) or
     (DesktopCorner = nil) or (DesktopBackdrop = nil) then
    Exit;
  CanonicalDesktopSize(DeskW, DeskH);
  if (DeskW < 1) or (DeskH < 1) then
    Exit;
  TopY := 0;
  BottomY := Size.Y;
  if MenuBar <> nil then Inc(TopY);
  if StatusLine <> nil then Dec(BottomY);
  AvailW := Size.X;
  AvailH := BottomY - TopY;
  if AvailW < 1 then AvailW := 1;
  if AvailH < 1 then AvailH := 1;

  // Point-fixed visibility: either scrollbar consumes the last row/column
  // and can therefore make its perpendicular peer necessary.
  NeedH := False;
  NeedV := False;
  repeat
    OldH := NeedH;
    OldV := NeedV;
    NewViewW := AvailW - Ord(NeedV);
    NewViewH := AvailH - Ord(NeedH);
    if NewViewW < 1 then NewViewW := 1;
    if NewViewH < 1 then NewViewH := 1;
    NeedH := DeskW > NewViewW;
    NeedV := DeskH > NewViewH;
  until (NeedH = OldH) and (NeedV = OldV);
  NewViewW := AvailW - Ord(NeedV);
  NewViewH := AvailH - Ord(NeedH);
  if NewViewW < 1 then NewViewW := 1;
  if NewViewH < 1 then NewViewH := 1;
  ViewportW := NewViewW;
  ViewportH := NewViewH;
  ViewportHVisible := NeedH;
  ViewportVVisible := NeedV;
  if AReset then
  begin
    ViewportX := 0;
    ViewportY := 0;
  end;
  MaxX := DeskW - ViewportW;
  MaxY := DeskH - ViewportH;
  if MaxX < 0 then MaxX := 0;
  if MaxY < 0 then MaxY := 0;
  if ViewportX < 0 then ViewportX := 0;
  if ViewportY < 0 then ViewportY := 0;
  if ViewportX > MaxX then ViewportX := MaxX;
  if ViewportY > MaxY then ViewportY := MaxY;

  R.Assign(-ViewportX, TopY - ViewportY,
    -ViewportX + DeskW, TopY - ViewportY + DeskH);
  Desktop^.ChangeBounds(R);
  R.Assign(0, TopY, AvailW, TopY + AvailH);
  DesktopBackdrop^.ChangeBounds(R);

  ViewportSyncing := True;
  try
    PageX := ViewportW - 1;
    PageY := ViewportH - 1;
    if PageX < 1 then PageX := 1;
    if PageY < 1 then PageY := 1;
    R.Assign(0, TopY + ViewportH, ViewportW, TopY + ViewportH + 1);
    DesktopHBar^.ChangeBounds(R);
    DesktopHBar^.SetParams(ViewportX, 0, MaxX, PageX, 1);
    R.Assign(ViewportW, TopY, ViewportW + 1, TopY + ViewportH);
    DesktopVBar^.ChangeBounds(R);
    DesktopVBar^.SetParams(ViewportY, 0, MaxY, PageY, 1);
    R.Assign(ViewportW, TopY + ViewportH,
      ViewportW + 1, TopY + ViewportH + 1);
    DesktopCorner^.ChangeBounds(R);
    if NeedH then DesktopHBar^.Show else DesktopHBar^.Hide;
    if NeedV then DesktopVBar^.Show else DesktopVBar^.Hide;
    if NeedH and NeedV then DesktopCorner^.Show else DesktopCorner^.Hide;
  finally
    ViewportSyncing := False;
  end;
end;

procedure TSuperApp.SetDesktopViewport(AX, AY: integer; ARedraw: boolean);
var
  DeskW, DeskH, MaxX, MaxY: integer;
  SavedSuppress: boolean;
begin
  CanonicalDesktopSize(DeskW, DeskH);
  MaxX := DeskW - ViewportW;
  MaxY := DeskH - ViewportH;
  if MaxX < 0 then MaxX := 0;
  if MaxY < 0 then MaxY := 0;
  if AX < 0 then AX := 0;
  if AY < 0 then AY := 0;
  if AX > MaxX then AX := MaxX;
  if AY > MaxY then AY := MaxY;
  if (AX = ViewportX) and (AY = ViewportY) then
    Exit;
  SavedSuppress := SuppressFlush;
  SuppressFlush := True;
  try
    ViewportX := AX;
    ViewportY := AY;
    UpdateDesktopViewport(False);
  finally
    SuppressFlush := SavedSuppress;
  end;
  if ARedraw and (not SavedSuppress) then
    RepaintChanges;
end;

procedure TSuperApp.SetCanonicalDesktop(AWidth, AHeight: integer;
  AResetViewport, AKeepWindowsReachable: boolean);
var
  W, H, I, X, Y: Longint;
  R: Objects.TRect;
  SavedGrowMode: array[0..MAX_PANES - 1] of Byte;
  SavedSettling: boolean;
begin
  W := AWidth;
  H := AHeight;
  NormalizeDesktopSize(W, H);
  if Desktop = nil then
    Exit;
  SavedSettling := RemoteAttachSettling;
  RemoteAttachSettling := True;
  Desktop^.Lock;
  try
    // TWindow defaults to gfGrowAll+gfGrowRel.  A logical desktop resize is
    // not a host resize and must not proportionally scale normal windows (or
    // resize their PTYs through TTermWindow.ChangeBounds).  Freeze only the
    // desktop's direct window children while TGroup applies its new bounds;
    // with an unchanged window rectangle its frame/terminal children receive
    // a zero delta and need no separate GrowMode override.
    for I := 0 to MAX_PANES - 1 do
      if Win[I] <> nil then
      begin
        SavedGrowMode[I] := Win[I]^.GrowMode;
        Win[I]^.GrowMode := 0;
      end;
    R.Assign(Desktop^.Origin.X, Desktop^.Origin.Y,
      Desktop^.Origin.X + W, Desktop^.Origin.Y + H);
    try
      Desktop^.ChangeBounds(R);
    finally
      for I := 0 to MAX_PANES - 1 do
        if Win[I] <> nil then
          Win[I]^.GrowMode := SavedGrowMode[I];
    end;
    if AKeepWindowsReachable then
      for I := 0 to MAX_PANES - 1 do
        if Win[I] <> nil then
        begin
          if Win[I]^.Zoomed then
            R := Win[I]^.ZoomRect
          else if Win[I]^.Minimized then
            R := Win[I]^.SavedRect
          else
          begin
            R := Default(Objects.TRect);
            Win[I]^.GetBounds(R);
          end;
          X := R.A.X;
          Y := R.A.Y;
          if KeepWindowTitleReachable(X, Y, R.B.X - R.A.X, W, H) then
          begin
            R.Move(X - R.A.X, Y - R.A.Y);
            if Win[I]^.Zoomed then
              Win[I]^.ZoomRect := R
            else if Win[I]^.Minimized then
              Win[I]^.SavedRect := R
            else
              Win[I]^.ChangeBounds(R);
          end;
          if Win[I]^.Zoomed then
          begin
            R.Assign(0, 0, W, H);
            Win[I]^.ChangeBounds(R);
            if Win[I]^.FullScreen then
              RequestPaneSize(I, W, H + 2);
          end;
        end;
    ArrangeIcons;
    UpdateDesktopViewport(AResetViewport);
  finally
    Desktop^.Unlock;
    RemoteAttachSettling := SavedSettling;
  end;
end;

procedure TSuperApp.RequestDesktopSize(AWidth, AHeight: integer);
var
  CurrentW, CurrentH: integer;
begin
  if not IsDesktopSizeValid(AWidth, AHeight) then
  begin
    MessageBox(Format(UiText(
      'Desktop dimensions must be between %dx%d and %dx%d cells.',
      'Las dimensiones deben estar entre %dx%d y %dx%d caracteres.'),
      [DESKTOP_MIN_W, DESKTOP_MIN_H, DESKTOP_MAX_W, DESKTOP_MAX_H]), nil,
      mfError or mfOKButton);
    Exit;
  end;
  CanonicalDesktopSize(CurrentW, CurrentH);
  if (CurrentW = AWidth) and (CurrentH = AHeight) then
  begin
    SetDesktopViewport(0, 0);
    Exit;
  end;
  if RemoteMode then
  begin
    if (Remote = nil) or (not Remote.Connected) or
       (not Remote.SendDesktopResize(AWidth, AHeight)) then
      MessageBox(UiText(
        'The shared desktop is busy. Try again when its current action finishes.',
        'El escritorio compartido esta ocupado. Intentalo al terminar la accion actual.'),
        nil, mfError or mfOKButton);
    Exit;
  end;
  SetCanonicalDesktop(AWidth, AHeight, True, True);
  RepaintChanges;
  RebuildMenu;
end;

procedure TSuperApp.AdjustDesktopToTerminal;
var
  W, H: integer;
begin
  W := Size.X;
  H := Size.Y;
  if MenuBar <> nil then Dec(H);
  if StatusLine <> nil then Dec(H);
  RequestDesktopSize(W, H);
end;

procedure TSuperApp.ModifyDesktopDimensions;
var
  W, H: integer;
begin
  CanonicalDesktopSize(W, H);
  if RunDesktopSizeDialog(W, H, DESKTOP_MIN_W, DESKTOP_MIN_H,
    DESKTOP_MAX_W, DESKTOP_MAX_H) then
    RequestDesktopSize(W, H);
end;

procedure TSuperApp.ShowDesktopDimensions;
var
  W, H: integer;
  S: string;
begin
  CanonicalDesktopSize(W, H);
  S := Format(UiText(
    'Logical desktop: %dx%d'#10'Complete IDE: %dx%d'#10 +
    'This terminal: %dx%d'#10'Visible viewport: %dx%d at (%d,%d)',
    'Escritorio logico: %dx%d'#10'IDE completo: %dx%d'#10 +
    'Este terminal: %dx%d'#10'Area visible: %dx%d en (%d,%d)'),
    [W, H, W, H + Ord(MenuBar <> nil) + Ord(StatusLine <> nil),
     Size.X, Size.Y, ViewportW, ViewportH, ViewportX, ViewportY]);
  MessageBox(S, nil, mfInformation or mfOKButton);
end;

constructor TSuperApp.Init;
var
  Pin: TPaneArray;
  i, n, k, SysIdx: integer;
  SavedX, SavedY: Longint;
  Ok: boolean;
  FreshInstall, FreshDefaultWorkspace: boolean;
  Dir: TSplitDir;
  DeskW, DeskH: integer;
  DefaultOuterW, DefaultOuterH: integer;
  DefaultSlot: st_layout.TRect;
  WR: Objects.TRect;
  SysClassesTmp: TWindowClassArray;
begin
  InstallWideVideoOutput;
  if DebugActive then DebugLog('== BOOT: TSuperApp.Init begin (build local workspace) ==');
  // suppress terminal flushes for the WHOLE startup: FreeVision draws the
  // local build, the promote and the re-attach into the buffer normally but
  // nothing reaches the terminal; FinishBoot flushes exactly once.
  // SuppressFlush is a unit global (survives inherited Init's FillChar of
  // Self); FBootLocked is a field, so set it AFTER inherited Init or the
  // zero-fill would wipe it and the flush would never be released.
  SuppressFlush := True;
  inherited Init;
  FBootLocked := True;
  MemberStatusOverlay := nil;
  ClipHistory := TClipboardHistory.Create;
  CopyMode := False;
  CopySelecting := False;
  CopyMouseSelecting := False;
  CopyPane := -1;
  // A first-run workspace is seeded only when the user has no configuration
  // yet.  An explicit configuration with autorestore=0 keeps its established
  // blank-workspace behaviour instead of being mistaken for a new install.
  FreshInstall := not FileExists(ConfigFile);
  FreshDefaultWorkspace := False;
  LoadConfig(Cfg);
  // The restricted OpenSSH entry is always a client of a persistent daemon;
  // the on-disk preference remains untouched.
  if SshEntryMode then
    Cfg.ServerMode := 'always';
  DeferPaneSpawn := SshEntryMode or SameText(Cfg.ServerMode, 'always');
  if Cfg.Palette = 'bw' then
    AppPalette := apBlackWhite
  else if Cfg.Palette = 'mono' then
    AppPalette := apMonochrome
  else
    AppPalette := apColor;
  // the renderer paints our own ground unless the user wants the host
  // terminal's -- see SolidBackground in st_video
  st_video.SolidBackground := Cfg.SolidBg;
  CurrentLanguage := Cfg.Language;
  SetMessageBoxLanguage(CurrentLanguage = ulSpanish);
  InitViewportViews;
  // window classes: user file + system file (user wins); if
  // SUPERTERM_INI points to the user file, the merge deduplicates
  LoadWindowClasses(ConfigFile, coUser, WClasses);
  LoadWindowClasses(SystemConfigFile, coSystem, SysClassesTmp);
  MergeWindowClasses(WClasses, SysClassesTmp);
  // profiles: user+system [profile.*] plus flattened legacy templates
  LoadProfiles(ConfigFile, SystemConfigFile, Profiles);
  DebugLog(Format('init: sysini=%s shell=%s classes=%d profiles=%d',
    [SystemConfigFile, Cfg.Shell, Length(WClasses), Length(Profiles)]));
  // inherited Init called InitMenuBar with empty WClasses: rebuild
  if MenuBar <> nil then
  begin
    Dispose(MenuBar, Done);
    MenuBar := nil;
  end;
  InitMenuBar;
  if MenuBar <> nil then
    Insert(MenuBar);
  RebuildStatusLine;
  Lay := TLayout.Create;
  for i := 0 to MAX_PANES - 1 do
  begin
    Panes[i] := nil;
    Scr[i] := nil;
    Win[i] := nil;
    PaneTerm[i] := -1;
    ReqCols[i] := 0;
    ReqRows[i] := 0;
    PaneViewX[i] := 0;
    PaneViewY[i] := 0;
    RemoteGeomDirtyPanes[i] := False;
  end;
  SyncTerminalSize;
  for i := 0 to MAX_PANES - 1 do
    PaneConnect[i] := '';
  ActiveProfile := -1;
  ActiveWindow := -1;
  ProfileMode := Length(Profiles) > 0;
  SkipSave := False;
  AbortRun := False;
  RemoteMode := False;
  RemoteLost := False;
  DetachRequested := False;
  PrefixPending := False;
  Remote := nil;
  RemoteLayoutHash := '';
  RemoteGeom := nil;
  RemoteDeskW := 0;
  RemoteDeskH := 0;
  RemoteClientCount := 0;
  RemoteMinHostW := 0;
  RemoteMinHostH := 0;
  RemoteHostSizesMatch := False;
  RemoteHostSummaryValid := False;
  RemoteMembershipReady := False;
  MemberNotices := nil;
  MemberNoticeHead := 0;
  MemberNoticeActive := False;
  MemberNoticeUntil := 0;
  MemberNoticePauseTick := 0;
  MemberNoticePaused := False;
  ResetRemotePreviewState;
  ResetRemoteZoomState;
  RemoteHostSizeArmed := False;
  RemoteLockedPanes := 0;
  RemoteSharedFocus := -1;
  SharedFullScreenRendered := False;
  RemoteGeometryDirty := False;
  RemoteTreeDirty := False;
  CurrentSessionSocket := '';
  PromotionConsumedWorkspace := False;
  RemoteAttachSettling := False;
  DeferWindowInsert := False;
  PassPane := -1;
  MouseGrabPane := -1;
  MouseGrabButton := MB_NONE;
  HostAnyMotion := False;
  PassReqW := 0;
  PassReqH := 0;
  PassFilterState := pfsGround;
  PassFilterBuf := '';
  PassFilterLen := 0;

  // A newly created/legacy workspace starts from this terminal once. From
  // this point onward the logical desktop is independent of host SIGWINCH.
  CanonicalDesktopSize(DeskW, DeskH);
  NormalizeDesktopSize(DeskW, DeskH);
  SetCanonicalDesktop(DeskW, DeskH, True, False);

  CurrentSessionName := '';
  if AttachRequested then
  begin
    if AttachSocket = '' then
    begin
      AttachSocket := PickSessionSocketUI(True);
      RepaintChanges;
    end;
    if (AttachSocket <> '') and AttachRemoteSession(AttachSocket) then
      Exit;
    // selection cancelled or attach failed: exit cleanly without saving.
    // A cmQuit posted here would be lost (TGroup.Execute sets EndState
    // to 0 when entering Run), so AbortRun is flagged and the main
    // program skips Run; no workspace is built
    if AttachFailReason <> '' then
      WriteLn(StdErr, 'superterm: ', AttachFailReason);
    SkipSave := True;
    AbortRun := True;
    Exit;
  end
  else if (not SshEntryMode) and PromptAttachOnStart then
    Exit;

  if ProfileMode then
  begin
    // The SSH entry consumes only the explicit default_profile.  Ordinary
    // interactive startup retains compatibility with the old template keys
    // and the first-enabled fallback.
    ActiveProfile := FindProfile(Cfg.DefaultProfile);
    if (not SshEntryMode) and (ActiveProfile < 0) then
      ActiveProfile := FindProfile(Cfg.DefaultTemplate);
    if (not SshEntryMode) and (ActiveProfile < 0) and
       (Cfg.DefaultSession <> '') then
      ActiveProfile := FindProfile(Cfg.DefaultTemplate + '/' +
        Cfg.DefaultSession);
    if (not SshEntryMode) and
       ((ActiveProfile < 0) or (not Profiles[ActiveProfile].Enabled)) then
      for i := 0 to Length(Profiles) - 1 do
        if Profiles[i].Enabled then
        begin
          ActiveProfile := i;
          Break;
        end;
    if ActiveProfile < 0 then
      ProfileMode := False
    else
    begin
      ActiveWindow := ProfileStartWindow(ActiveProfile, not SshEntryMode);
      if ((Length(Profiles[ActiveProfile].Windows) > 0) and
          (ActiveWindow < 0)) or
         (not ActivateProfile(ActiveProfile, ActiveWindow)) then
        ProfileMode := False;
    end;
    if ProfileMode then
      Exit;
  end;
  // No configured/default profile is not an error for SSH: the first client
  // establishes an intentionally empty canonical desktop at its PTY size.
  if SshEntryMode then
  begin
    BuildEmptyWorkspace(-1);
    Exit;
  end;
  Pin := nil;
  Ok := False;
  DeskW := 0;
  DeskH := 0;
  if Cfg.AutoRestore then
    Ok := LoadSession(SessionFile, Lay, Pin, DeskW, DeskH);
  if Ok and (DeskW > 0) and (DeskH > 0) then
  begin
    NormalizeDesktopSize(DeskW, DeskH);
    SetCanonicalDesktop(DeskW, DeskH, True, False);
  end;
  if Ok then
  begin
    // Sessions written before the fixed logical desktop have no DeskW/H.
    // Use this startup terminal's canonical desktop, preserving every saved
    // size and every already-accessible position. Repair only a rectangle
    // whose draggable title is wholly outside, before any window is created
    // and therefore before an unreachable intermediate frame can be shown.
    CanonicalDesktopSize(DeskW, DeskH);
    for i := 0 to High(Pin) do
      if (Pin[i].BW > 0) and (Pin[i].BH > 0) then
      begin
        SavedX := Pin[i].BX;
        SavedY := Pin[i].BY;
        if KeepWindowTitleReachable(SavedX, SavedY, Pin[i].BW,
             DeskW, DeskH) then
        begin
          Pin[i].BX := SavedX;
          Pin[i].BY := SavedY;
        end;
      end;
  end;
  if not Ok then
  begin
    Lay.Free;
    Lay := TLayout.Create;
    Pin := nil;
    // terminals defined in /etc/superterm/superterm.ini
    n := 0;
    for i := 0 to Length(WClasses) - 1 do
      if WClasses[i].Enabled then
        Inc(n);
    if n > MAX_PANES then
      n := MAX_PANES;
    if n > 0 then
    begin
      k := 0;
      for i := 0 to Length(WClasses) - 1 do
      begin
        if (not WClasses[i].Enabled) or (k >= MAX_PANES) then
          continue;
        if k > 0 then
        begin
          if Odd(k) then Dir := sdV else Dir := sdH;
          Lay.SplitPane(Lay.PaneCount - 1, Dir);
        end;
        StartPaneEx(k, WClasses[i].Cwd, '', i, '', '', WClasses[i].Name,
          WClasses[i].ScrollBack);
        Inc(k);
      end;
      Lay.Focused := 0;
      RelayoutAll;
      RepaintChanges;
      FocusPane(0);
      Exit;
    end;
    SetLength(Pin, 1);
    if FreshInstall then
    begin
      // Installation default: one 80x25 PTY, centred before it becomes the
      // stable first icon, on a 120x50 logical desktop.  The frame consumes
      // two cells on each axis; saving SavedRect before Minimize preserves
      // the exact 80x25 terminal when the user restores it.
      FreshDefaultWorkspace := True;
      DeskW := DEFAULT_DESKTOP_W;
      DeskH := DEFAULT_DESKTOP_H;
      SetCanonicalDesktop(DeskW, DeskH, True, False);
      WantedWindowSize(DEFAULT_INITIAL_PANE_COLS,
        DEFAULT_INITIAL_PANE_ROWS, DeskW, DeskH,
        DefaultOuterW, DefaultOuterH);
      DefaultSlot := CentredRect(DefaultOuterW, DefaultOuterH, DeskW, DeskH);
      Pin[0].BX := DefaultSlot.X;
      Pin[0].BY := DefaultSlot.Y;
      Pin[0].BW := DefaultSlot.W;
      Pin[0].BH := DefaultSlot.H;
      Pin[0].Minimized := True;
      Pin[0].IconSlot := 0;
    end;
  end;
  n := Lay.PaneCount;
  if (n < 1) or (n > MAX_PANES) then
    n := 1;
  for i := 0 to n - 1 do
  begin
    SysIdx := -1;
    if i <= High(Pin) then
      SysIdx := FindWindowClass(Pin[i].Term);
    if SysIdx >= 0 then
      StartPaneEx(i, '', '', SysIdx, '', '', WClasses[SysIdx].Name,
        WClasses[SysIdx].ScrollBack)
    else if (i <= High(Pin)) and (Length(Pin[i].Args) > 0) then
      StartPane(i, Pin[i].Cwd,
        CommandWithInteractiveShell(ArgsAsShell(Pin[i].Args), Cfg.Shell,
          Cfg.LoginShell))
    else if (i <= High(Pin)) and (Pin[i].Cmd <> '') then
      StartPane(i, Pin[i].Cwd,
        CommandWithInteractiveShell(Pin[i].Cmd, Cfg.Shell, Cfg.LoginShell))
    else if i <= High(Pin) then
      StartPane(i, Pin[i].Cwd, '')
    else
      StartPane(i, '', '');
  end;
  // reapply custom titles (renamed by hand) exactly as they were saved
  for i := 0 to n - 1 do
    if (i <= High(Pin)) and (Pin[i].Title <> '') and (i < MAX_PANES) and
       (Win[i] <> nil) then
    begin
      Win[i]^.SetTitle(' ' + Pin[i].Title);
      Win[i]^.TitleFixed := True;
    end;
  if Lay.Focused >= n then
    Lay.Focused := 0;
  RelayoutAll;
  // Reapply absolute bounds after restoring the saved canonical desktop.
  // A client's physical size is only a viewport and never gates restoration.
  if Ok or FreshDefaultWorkspace then
  begin
    for i := 0 to n - 1 do
      if (i <= High(Pin)) and (i < MAX_PANES) and (Win[i] <> nil) then
      begin
        if (Pin[i].BW > 0) and (Pin[i].BH > 0) then
        begin
          WR := Default(Objects.TRect);
          WR.Assign(Pin[i].BX, Pin[i].BY,
            Pin[i].BX + Pin[i].BW, Pin[i].BY + Pin[i].BH);
          Win[i]^.Locate(WR);
        end;
        if Pin[i].Zoomed and (not Win[i]^.Zoomed) then
          Win[i]^.Zoom;
        Win[i]^.FullScreen := Pin[i].FullScreen;
      end;
    // minimized ones last: MinimizeWindow manages the focus
    for i := 0 to n - 1 do
      if (i <= High(Pin)) and (i < MAX_PANES) and (Win[i] <> nil) and
         Pin[i].Minimized then
      begin
        Win[i]^.IconSlot := Pin[i].IconSlot;
        MinimizeWindow(i);
      end;
  end;
  RepaintChanges;
  FocusPane(Lay.Focused);
end;

destructor TSuperApp.Done;
begin
  // must clear passthrough before teardown: while it is active every
  // FreeVision screen write (incl. Drivers.DoneVideo's ClearScreen) is
  // suppressed, which would leave the alternate screen unblanked on exit
  PassthroughActive := False;
  PassPane := -1;
  // a suppressed flush left on (aborted attach) would likewise swallow the
  // teardown's ClearScreen -> release it so the shell is left clean
  if FBootLocked then
  begin
    SuppressFlush := False;
    FBootLocked := False;
  end;
  try
  if DetachRequested then
  begin
    // The server owns the PTYs after detach. Do not run TPty.Destroy here.
    ReleaseRuntime;
  end
  else if RemoteMode then
  begin
    if DebugActive then
      DebugLog(Format('done: remote autosave=%d skip=%d connected=%d',
        [Ord(Cfg.AutoSave), Ord(SkipSave),
         Ord((Remote <> nil) and Remote.Connected)]));
    if (Remote <> nil) and Remote.Connected then
    begin
      // The daemon already owns the one live canonical desktop. Exit closes
      // this viewer; the daemon closes too iff this was the last viewer.
      SyncRemoteLayout;
      Remote.CloseSession;
    end;
    ReleaseRuntime;
  end
  else if ProfileMode then
  begin
    if not SkipSave then
      try
        RememberProfileSelection;
      except
        on E: Exception do
          if DebugActive then
            DebugLog('done: default window not saved: ' + E.Message);
      end;
  end
  // SkipSave also guards this branch: after an aborted attach or a
  // lost remote connection, Lay may be the remote layout (Panes=nil)
  // and saving it would clobber the local session.ini with empty panes
  else if Cfg.AutoSave and (not SkipSave) then
    SaveSessionNow;
  finally
  if not DetachRequested and not RemoteMode then
    StopRuntime;
  Lay.Free;
  ClipHistory.Free;
  ClipHistory := nil;
  if Remote <> nil then
    Remote.Free;
  inherited Done;
  end;
end;

procedure TSuperApp.ApplyTerminalSize(ACols, ARows: integer);
{ logs a forced full repaint when the terminal actually changed size }
var
  Mode: TVideoMode;
  R: Objects.TRect;
  SavedPalette: integer;
  NeedVideo, NeedBounds, SavedSuppress, SavedSettling: boolean;
begin
  if (ACols < 1) or (ARows < 1) then
    Exit;
  if ACols > MaxViewWidth then
    ACols := MaxViewWidth;
  NeedVideo := (ScreenWidth <> ACols) or (ScreenHeight <> ARows);
  NeedBounds := (Size.X <> ACols) or (Size.Y <> ARows);
  if (not NeedVideo) and (not NeedBounds) then
    Exit;
  // A physical TIOCGWINSZ is client metadata only.  It changes this viewer's
  // surface/viewport and can never propose a canonical desktop mutation.
  if NeedVideo and RemoteMode and RemoteHostSizeArmed and
     (Remote <> nil) and Remote.Connected and (Lay <> nil) and
     (Length(RemoteGeom) = Lay.PaneCount) then
    if Remote.SendClientSize(ACols, ARows) then
      // Until FRAME_HOST_SUMMARY_EV returns in socket order, the previous
      // comparison does not describe this physical surface any more.
      RemoteHostSummaryValid := False;
  // SetScreenVideoMode itself calls ChangeBounds, and every Locate below can
  // draw. Keep the whole host-resize as one buffered visual transaction; the
  // user must never see the temporary apColor selected by InitScreen or two
  // successive layouts. ResetVideoSurface also avoids its direct ClearScreen
  // while SuppressFlush is set.
  SavedSuppress := SuppressFlush;
  SavedSettling := RemoteAttachSettling;
  SuppressFlush := True;
  RemoteAttachSettling := True;
  try
    if NeedVideo then
    begin
      SavedPalette := AppPalette;
      Mode.Col := ACols;
      Mode.Row := ARows;
      Mode.Color := True;
      // FreeVision's SetScreenVideoMode calls TProgram.InitScreen, which
      // detects the terminal as colour-capable and resets AppPalette to
      // apColor. Capability and the user's selected palette are different
      // things: restore the logical choice before the final resized draw.
      try
        SetScreenVideoMode(Mode);
      finally
        AppPalette := SavedPalette;
      end;
    end;

    // SetScreenVideoMode already applies these bounds. Re-evaluate instead of
    // replaying ChangeBounds a second time (the old duplicate resize pass).
    NeedBounds := (Size.X <> ACols) or (Size.Y <> ARows);
    if NeedBounds then
    begin
      R.Assign(0, 0, ACols, ARows);
      ChangeBounds(R);
    end;
    // Rebuild the dynamic tree only when crossing the exact compact/full
    // threshold.  Repeated resize events inside one mode do no allocation;
    // the one necessary rebuild remains inside this synchronized paint.
    if MenuCompact <> CompactTopMenuFor(Size.X) then
      RebuildMenu;
    // A new physical size always starts at the canonical upper-left corner.
    // Existing window bounds and PTY grids remain byte-for-byte untouched.
    UpdateDesktopViewport(True);
    if MemberNoticeActive then
      RefreshMemberNoticeViews;
    ResetVideoSurface;
    // Build the final frame while writes are held. EffOld remains invalid,
    // so the post-transaction ReDraw below emits every settled cell once.
    ReDraw;
  finally
    RemoteAttachSettling := SavedSettling;
    SuppressFlush := SavedSuppress;
  end;
  if not SavedSuppress then
    ReDraw;
end;

procedure TSuperApp.SyncTerminalSize;
var
  Cols, Rows: integer;
begin
  if ReadTerminalSize(Cols, Rows) then
    ApplyTerminalSize(Cols, Rows);
end;

function TSuperApp.PaneCount: integer;
var
  i: integer;
begin
  Result := 0;
  for i := 0 to MAX_PANES - 1 do
    if Win[i] <> nil then
      Inc(Result);
end;

procedure TSuperApp.StartPane(i: integer; const ACwd, ACmd: string);
begin
  StartPaneEx(i, ACwd, ACmd, -1, '', '', '', DEFAULT_SCROLLBACK);
end;

procedure TSuperApp.StartPaneEx(i: integer; const ACwd, ACmd: string;
  ASysIdx: integer; const AShellOv, AExtraEnv, ATitle: string;
  AMaxSB: integer; const ACommandOverride: string);
var
  R: Objects.TRect;
  pw, ph: integer;
  TitleS, CmdS, CwdS, ShellS, ExtraS: string;
  ExecProgram, ExecSecret: string;
  ExecArgs: TStringList;
  FallbackCmd, FallbackShell, FallbackCwd: string;
  SpawnOK: boolean;
  UsedFallback: boolean;
begin
  if Win[i] <> nil then
    Exit;
  // one rect decides both the window and the PTY, so they agree from the
  // start and nothing has to resize the pane afterwards
  R := NewWindowRect(ASysIdx);
  pw := R.B.X - R.A.X - 2;
  ph := R.B.Y - R.A.Y - 2;
  if pw < 4 then pw := 4;
  if ph < 2 then ph := 2;
  if ASysIdx >= 0 then
  begin
    if WClasses[ASysIdx].Shell <> '' then
      ShellS := WClasses[ASysIdx].Shell
    else
      ShellS := Cfg.Shell;
    // wcLocal/wcCommand: command composed with the unified semantics
    // (for wcSSH the path is the structured argv further below)
    CmdS := ComposePaneCommand(WClasses[ASysIdx], ACmd, '', '', ShellS,
      Cfg.LoginShell);
    if WClasses[ASysIdx].Kind <> wcSSH then
      CwdS := WClasses[ASysIdx].Cwd
    else
      CwdS := '';
    if ACwd <> '' then
      CwdS := ACwd;
    ExtraS := '';
    // default title of the class (or its name if it has no title)
    if WClasses[ASysIdx].Title <> '' then
      TitleS := WClasses[ASysIdx].Title
    else
      TitleS := WClasses[ASysIdx].Name;
    if AMaxSB <= 0 then
      AMaxSB := WClasses[ASysIdx].ScrollBack;
  end
  else
  begin
    CmdS := ACmd;
    CwdS := ACwd;
    ShellS := Cfg.Shell;
    if AShellOv <> '' then
      ShellS := AShellOv;
    ExtraS := AExtraEnv;
    if ATitle <> '' then
      TitleS := ATitle
    else if ACmd <> '' then
      TitleS := ExtractFileName(FirstWord(ACmd))
    else if ACwd <> '' then
      TitleS := ExtractFileName(ACwd)
    else
      TitleS := 'shell';
  end;
  if ACommandOverride <> '' then
    CmdS := ACommandOverride;
  CwdS := ExpandUserPath(CwdS);
  // last resort: a pane with no scrollback keeps no history at all, and
  // nothing in the interface would say why. Only an explicit setting can
  // ask for that, and none of the callers can express it as zero.
  if AMaxSB <= 0 then
    AMaxSB := DEFAULT_SCROLLBACK;
  PaneTerm[i] := ASysIdx;
  PaneConnect[i] := ''; // callers with a free connection set it afterwards
  Scr[i] := TScreen.Create(pw, ph, AMaxSB);
  Panes[i] := TPty.Create;
  FallbackCmd := '';
  FallbackShell := '';
  FallbackCwd := '';
  if ASysIdx >= 0 then
  begin
    FallbackShell := Cfg.Shell;
    FallbackCwd := GetEnvironmentVariable('HOME');
    FallbackCmd := 'printf ' +
      ShellQuote(UiText('superterm: terminal unavailable: ',
        'superterm: terminal no disponible: ') +
        UiText('FAILED ', 'FALLO ') + TitleS + #10) +
      '; exec ' + ShellQuote(Cfg.Shell);
  end;
  ExecArgs := TStringList.Create;
  try
    ExecProgram := '';
    ExecSecret := '';
    if (ASysIdx >= 0) and (WClasses[ASysIdx].Kind = wcSSH) then
    begin
      BuildWindowClassExec(WClasses[ASysIdx], ExecProgram, ExecArgs,
        ExecSecret, ACommandOverride);
      Panes[i].ConfigureArgv(ExecProgram, ExecArgs.ToStringArray,
        CwdS, pw, ph, ExtraS, ExecSecret, FallbackShell,
        FallbackCwd, FallbackCmd, Cfg.LoginShell);
    end
    else
      Panes[i].ConfigureShell(ShellS, CwdS, CmdS, pw, ph, ExtraS,
        Cfg.LoginShell, FallbackShell, FallbackCwd,
        FallbackCmd, Cfg.LoginShell);
    UsedFallback := False;
    if DeferPaneSpawn then
      SpawnOK := True
    else
      SpawnOK := Panes[i].SpawnConfigured(UsedFallback);
  finally
    ExecArgs.Free;
  end;
  if UsedFallback then
  begin
    TitleS := UiText('FAILED ', 'FALLO ') + TitleS;
    PaneTerm[i] := -2;
  end;
  if not SpawnOK then
  begin
    DebugLog(Format('spawn failed pane=%d sysidx=%d shell=%s cwd=%s cmd=%s',
      [i, ASysIdx, ShellS, CwdS, CmdS]));
    FreeAndNil(Panes[i]);
    FreeAndNil(Scr[i]);
    PaneTerm[i] := -1;
    FreeAndNil(Panes[i]);
    FreeAndNil(Scr[i]);
    Exit;
  end;
  CreateWindowForPane(i, TitleS, R);
  // a class pane keeps its title (class name/title); the periodic
  // cwd refresh must not overwrite it
  if (ASysIdx >= 0) and (Win[i] <> nil) then
    Win[i]^.TitleFixed := True;
  DebugLog(Format('startpane i=%d sysidx=%d win=%p term=%p termidx=%d scr=%dx%d',
    [i, ASysIdx, Win[i], Win[i]^.Term, Win[i]^.Term^.PaneIdx, pw, ph]));
end;

// Where a NEW window goes, without moving a single existing one: at the size
// its class asks for (or the configured default, or two thirds of the
// desktop), centred. It lands in front of whatever is already there, which is
// what Insert + Select do on their own.
function TSuperApp.NewWindowRect(ASysIdx: integer): Objects.TRect;
var
  RD: Objects.TRect;
  Slot: st_layout.TRect;
  DW, DH, WantW, WantH, i, Placed, Cols, Rows: integer;
begin
  Result := Default(Objects.TRect);
  if NextRectSet then
  begin
    NextRectSet := False;
    Result := NextRect;
    Exit;
  end;
  if Desktop = nil then
  begin
    Result.Assign(0, 0, 40, 15);
    Exit;
  end;
  RD := Default(Objects.TRect);
  Desktop^.GetExtent(RD);
  DW := RD.B.X - RD.A.X;
  DH := RD.B.Y - RD.A.Y;
  if RemoteMode and (RemoteDeskW > 0) and (RemoteDeskH > 0) then
  begin
    DW := RemoteDeskW;
    DH := RemoteDeskH;
    RD.Assign(0, 0, DW, DH);
  end;
  Cols := 0;
  Rows := 0;
  if (ASysIdx >= 0) and (ASysIdx <= High(WClasses)) then
  begin
    Cols := WClasses[ASysIdx].Cols;
    Rows := WClasses[ASysIdx].Rows;
  end;
  if Cols <= 0 then
    Cols := Cfg.NewWinCols;
  if Rows <= 0 then
    Rows := Cfg.NewWinRows;
  Placed := 0;
  for i := 0 to MAX_PANES - 1 do
    if Win[i] <> nil then
      Inc(Placed);
  // The first window of a session that asks for no particular size keeps the
  // whole desktop, exactly as every session has always looked.
  if (Placed = 0) and (Cols <= 0) and (Rows <= 0) then
  begin
    Result := RD;
    Exit;
  end;
  WantedWindowSize(Cols, Rows, DW, DH, WantW, WantH);
  Slot := CentredRect(WantW, WantH, DW, DH);
  Result.Assign(RD.A.X + Slot.X, RD.A.Y + Slot.Y,
    RD.A.X + Slot.X + Slot.W, RD.A.Y + Slot.Y + Slot.H);
end;

procedure TSuperApp.CreateWindowForPane(i: integer; const ATitle: string;
  const ARect: Objects.TRect);
var
  R: Objects.TRect;
begin
  if (i < 0) or (i >= MAX_PANES) or (Win[i] <> nil) then
    Exit;
  R := ARect;
  Win[i] := New(PTermWindow, Init(R, ' ' + ATitle, i));
  // FPC's FreeVision TView.Init initializes neither Owner nor Next
  // (vendor/fv322/views.pas). Normally InsertView overwrites both
  // immediately; deferred profile windows live long enough for their old
  // heap bytes to be observed, so make the detached state explicit.
  Win[i]^.Owner := nil;
  Win[i]^.Next := nil;
  // A profile is assembled away from Desktop.  Its windows can be sized,
  // zoomed and minimized without ever becoming a half-built workspace in
  // FreeVision's view tree or VideoBuf.  ActivateProfile inserts the complete
  // set after every pane succeeded.
  if not DeferWindowInsert then
    Desktop^.Insert(Win[i]);
end;

function TSuperApp.PaneWantsAppCursor(i: integer): boolean;
begin
  Result := (i >= 0) and (i < MAX_PANES) and (Scr[i] <> nil) and
    Scr[i].AppCursorKeys;
end;

procedure TSuperApp.ResetSizeRequests;
var
  i: integer;
begin
  for i := 0 to MAX_PANES - 1 do
  begin
    ReqCols[i] := 0;
    ReqRows[i] := 0;
    PaneViewX[i] := 0;
    PaneViewY[i] := 0;
  end;
  // same reason: a grab held across a renumbering would write the drag
  // into another application's pty
  MouseGrabPane := -1;
  MouseGrabButton := MB_NONE;
end;

function TSuperApp.ForwardMouse(i: integer; const Event: TEvent;
  const ALocal: Objects.TPoint): boolean;
var
  Track: TMouseTrack;
  Btn, Col, Row: integer;
  Seq: RawByteString;
begin
  Result := False;
  if (i < 0) or (i >= MAX_PANES) or (Scr[i] = nil) then
    Exit;
  Track := Scr[i].MouseTrack;
  if Track = mtOff then
    Exit;
  Col := ALocal.X + PaneViewX[i] + 1;
  Row := ALocal.Y + PaneViewY[i] + 1;
  // Padding outside the canonical grid is not part of the application. A
  // drag which began inside still needs a release, clamped to the PTY edge;
  // an unrelated click in padding is consumed locally and never fabricated.
  if (Col < 1) or (Col > Scr[i].Width) or
     (Row < 1) or (Row > Scr[i].Height) then
  begin
    if MouseGrabPane <> i then
      Exit(True);
    if Col < 1 then Col := 1;
    if Col > Scr[i].Width then Col := Scr[i].Width;
    if Row < 1 then Row := 1;
    if Row > Scr[i].Height then Row := Scr[i].Height;
  end;
  case Event.What of
    evMouseDown:
      begin
        if (Event.Buttons and (8 or 16)) <> 0 then
        begin
          // the wheel: a press with no release, as xterm sends it
          if Track = mtX10 then
            Exit;
          if (Event.Buttons and 8) <> 0 then Btn := MB_WHEEL_UP
          else Btn := MB_WHEEL_DOWN;
          Seq := EncodeMouseReport(Scr[i].MouseProto, Btn, Col, Row, True);
          if Seq <> '' then WritePaneInput(i, Seq);
          Exit(True);
        end;
        if (Event.Buttons and 1) <> 0 then Btn := MB_LEFT
        else if (Event.Buttons and 4) <> 0 then Btn := MB_MIDDLE
        else if (Event.Buttons and 2) <> 0 then Btn := MB_RIGHT
        else Exit;
        MouseGrabPane := i;
        MouseGrabButton := Btn;
        Seq := EncodeMouseReport(Scr[i].MouseProto, Btn, Col, Row, True);
        if Seq <> '' then WritePaneInput(i, Seq);
        Exit(True);
      end;
    evMouseUp:
      begin
        // the fabricated release after a wheel notch has no grab: drop it
        if (MouseGrabPane <> i) or (Track = mtX10) then
        begin
          MouseGrabPane := -1;
          Exit(MouseGrabPane = i);
        end;
        Seq := EncodeMouseReport(Scr[i].MouseProto, MouseGrabButton, Col, Row, False);
        MouseGrabPane := -1;
        MouseGrabButton := MB_NONE;
        if Seq <> '' then WritePaneInput(i, Seq);
        Exit(True);
      end;
    evMouseMove:
      begin
        if (MouseGrabPane = i) and (Track >= mtButton) then
          Btn := MouseGrabButton + MB_MOTION
        else if (MouseGrabPane < 0) and (Track = mtAny) then
          Btn := MB_NONE + MB_MOTION
        else
          Exit(Track <> mtOff);   // a motion the app did not ask for: ours to drop
        Seq := EncodeMouseReport(Scr[i].MouseProto, Btn, Col, Row, True);
        if Seq <> '' then WritePaneInput(i, Seq);
        Exit(True);
      end;
  end;
end;

procedure TSuperApp.SyncHostMouse;
var
  Want: boolean;
begin
  Want := (not PassthroughActive) and (Lay.Focused >= 0) and
    (Lay.Focused < MAX_PANES) and (Scr[Lay.Focused] <> nil) and
    (Scr[Lay.Focused].MouseTrack = mtAny);
  if Want = HostAnyMotion then
    Exit;
  HostAnyMotion := Want;
  // the RTL queue holds 16 events and FreeVision drains one per loop, so
  // every-motion reporting is asked for only while an application wants it
  if Want then
    WriteRaw(#27'[?1003h')
  else
  begin
    // "?1003l" does not mean "fall back to ?1002" everywhere. xterm keeps the
    // three tracking modes as independent flags, so turning the highest off
    // leaves the lower ones standing; Konsole -- and it is not alone -- holds
    // ONE mouse mode, so the same sequence leaves it reporting nothing at all.
    // What that looks like: run any full-screen program that asks for
    // every-motion tracking (Claude Code, Codex) in a pane, click on another
    // window and the pointer turns from an arrow back into an I-beam and not
    // one click reaches the window manager again until superterm is
    // restarted. So the base modes are re-asserted immediately after, which
    // costs three sequences and is a no-op on a terminal that kept them.
    WriteRaw(#27'[?1003l');
    HostMouseOn;
  end;
end;

procedure TSuperApp.RequestPaneSize(i, ACols, ARows: integer);
begin
  if (i < 0) or (i >= MAX_PANES) or (Scr[i] = nil) then
    Exit;
  if RemoteMode then
  begin
    if (ACols = ReqCols[i]) and (ARows = ReqRows[i]) then
      Exit;
    ReqCols[i] := ACols;
    ReqRows[i] := ARows;
    // Physical bounds are presentation-only. They never resize the shared
    // desktop or its PTY.
    Exit;
  end;
  if (ACols = Scr[i].Width) and (ARows = Scr[i].Height) then
    Exit;
  Scr[i].Resize(ACols, ARows);
  if Panes[i] <> nil then
    Panes[i].Resize(ACols, ARows);
end;

// Match a pane to the window it was just given. TTermWindow.Init does not go
// through ChangeBounds, so a pane the daemon created at its own size would
// otherwise sit inside a frame of a different one -- a class asking for
// 100x30 got a 100x30 frame around an 80x24 terminal. Only for a pane born
// remotely: a local one is spawned at the window's size to begin with, and
// the attach path must NOT do this -- it creates every window at the full
// desktop and then settles them in one pass, and a request here would be
// exactly the transient that bounces everyone else's screens.
procedure TSuperApp.SyncPaneToWindow(i: integer);
var
  pw, ph: integer;
begin
  if (i < 0) or (i >= MAX_PANES) or (Win[i] = nil) or (Scr[i] = nil) or
     (PassPane = i) or Win[i]^.Minimized then
    Exit;
  pw := Win[i]^.Size.X - 2;
  ph := Win[i]^.Size.Y - 2;
  if pw < 4 then pw := 4;
  if ph < 2 then ph := 2;
  if DebugActive then
    DebugLog(Format('resize: pane=%d sync to window -> %dx%d (mirror %dx%d)',
      [i, pw, ph, Scr[i].Width, Scr[i].Height]));
  RequestPaneSize(i, pw, ph);
end;

// Explicit escape hatch: resize the focused pane's real PTY globally.
procedure TSuperApp.FitSessionToWindow;
var
  i, PW, PH: integer;
begin
  i := Lay.Focused;
  if (i < 0) or (i >= MAX_PANES) or (Win[i] = nil) or
     Win[i]^.Minimized or (Scr[i] = nil) then
    Exit;
  PW := Win[i]^.Size.X - 2;
  PH := Win[i]^.Size.Y - 2;
  if PW < 4 then PW := 4;
  if PH < 2 then PH := 2;
  if RemoteMode then
  begin
    if (Remote <> nil) and Remote.Connected then
      Remote.SendResize(i, PW, PH);
  end
  else
    RequestPaneSize(i, PW, PH);
end;

procedure TSuperApp.KillPane(i: integer);
begin
  if CopyMode and (CopyPane = i) then
    EndCopyMode(False);
  if Win[i] <> nil then
  begin
    // A deferred profile window has deliberately never entered Desktop.
    // Disposing it through TGroup.Delete would pretend it was linked into the
    // view ring and can disturb an unrelated current view.
    if (Desktop <> nil) and (Win[i]^.Owner = PGroup(Desktop)) then
      Desktop^.Delete(Win[i]);
    Dispose(Win[i], Done);
    Win[i] := nil;
  end;
  if Panes[i] <> nil then
  begin
    Panes[i].KillPane;
    FreeAndNil(Panes[i]);
  end;
  if Scr[i] <> nil then
    FreeAndNil(Scr[i]);
end;

procedure TSuperApp.FallbackPane(i: integer);
var
  Cmd, TitleS: string;
  P: TPty;
begin
  if (i < 0) or (i >= MAX_PANES) or (Win[i] = nil) or
     (Scr[i] = nil) then
    Exit;
  // PaneTerm is -1 for a pane with no class and -2 for one whose class
  // failed to start -- and this routine runs exactly when a class pane could
  // not be brought up, so both are the normal case here, not the exception.
  // Reading WClasses at a negative index is a segfault, and it was the one
  // reported: open an ssh class that does not come up, and the client dies.
  // The bound matters too: a class deleted while its pane lives leaves the
  // index past the end of the array.
  if (PaneTerm[i] >= 0) and (PaneTerm[i] < Length(WClasses)) then
    TitleS := WClasses[PaneTerm[i]].Name
  else
    TitleS := Trim(Win[i]^.GetTitle(80));
  if TitleS = '' then
    TitleS := UiText('terminal', 'terminal');
  Cmd := 'printf ' + ShellQuote(
    UiText('superterm: remote terminal unavailable: ',
      'superterm: terminal remoto no disponible: ') + TitleS + #10) +
    '; exec ' + ShellQuote(Cfg.Shell);
  if Panes[i] <> nil then
    FreeAndNil(Panes[i]);
  P := TPty.Create;
  if P.Spawn(Cfg.Shell, GetEnvironmentVariable('HOME'), Cmd,
    Scr[i].Width, Scr[i].Height, '', Cfg.LoginShell) then
  begin
    Panes[i] := P;
    PaneTerm[i] := -2;
    Win[i]^.SetTitle(' ' + UiText('FAILED ', 'FALLO ') + TitleS);
  end
  else
    P.Free;
end;

procedure TSuperApp.RelayoutAll;
var
  Rects: array[0..MAX_PANES - 1] of st_layout.TRect;
  LR, TileR: Objects.TRect;
  i, TileH, DeskW, DeskH: integer;
  MaxDeskW, MaxDeskH, MaxCols, MaxRows: integer;
  R: Objects.TRect;
  HasIcons: boolean;
begin
  R := Default(Objects.TRect);
  Desktop^.GetExtent(R);
  DeskW := R.B.X - R.A.X;
  DeskH := R.B.Y - R.A.Y;
  if RemoteMode and (RemoteDeskW > 0) and (RemoteDeskH > 0) then
  begin
    DeskW := RemoteDeskW;
    DeskH := RemoteDeskH;
  end;
  // with minimized windows, the tile reserves the bottom icon strip
  HasIcons := False;
  for i := 0 to MAX_PANES - 1 do
    if (Win[i] <> nil) and Win[i]^.Minimized then
      HasIcons := True;
  TileH := DeskH;
  if HasIcons then
    Dec(TileH, 2);
  Lay.ComputeRects(DeskW, TileH, Rects);
  for i := 0 to MAX_PANES - 1 do
    if (Win[i] <> nil) and (not Win[i]^.Minimized) then
    begin
      Rects[i].W := Rects[i].W - 2;  // gap between frames
      Rects[i].H := Rects[i].H - 1;
      if Rects[i].W < 8 then Rects[i].W := 8;
      if Rects[i].H < 5 then Rects[i].H := 5;
      TileR.Assign(Rects[i].X, Rects[i].Y,
        Rects[i].X + Rects[i].W, Rects[i].Y + Rects[i].H);
      // Keep the tile as the restore target while a window is maximized.
      Win[i]^.ZoomRect := TileR;
      if Win[i]^.Zoomed then
      begin
        if Win[i]^.FullScreen then
          SharedFullScreenSize(MaxDeskW, MaxDeskH, MaxCols, MaxRows)
        else if RemoteMode and (i < Length(RemoteGeom)) and
                RemoteGeom[i].Zoomed then
        begin
          MaxDeskW := RemoteGeom[i].Cols + 2;
          MaxDeskH := RemoteGeom[i].Rows + 2;
        end
        else
        begin
          MaxDeskW := DeskW;
          MaxDeskH := DeskH;
        end;
        LR.Assign(0, 0, MaxDeskW, MaxDeskH);
      end
      else
        LR := TileR;
      Win[i]^.Locate(LR);
    end;
end;

procedure TSuperApp.FocusPane(i: integer);
var
  SavedOptions: word;
begin
  if (i >= 0) and (i < MAX_PANES) and (Win[i] <> nil) then
  begin
    if DebugFull then
      DebugLog(Format('focus: pane=%d remote=%d settling=%d shared=%d',
        [i, Ord(RemoteMode), Ord(RemoteAttachSettling),
         RemoteSharedFocus]));
    Lay.Focused := i;
    Win[i]^.Select;
    // TView.Select delegates top-selectable windows to MakeFirst.  In the
    // FreeVision implementation MakeFirst is intentionally a no-op when the
    // view is already first.  A minimized icon is kept first in Z order, so
    // after Restore it can already be first while Desktop.Current still names
    // the fallback window selected by Minimize.  Exercise Select again without
    // ofTopSelect so FreeVision's own TGroup.SetCurrent establishes the exact
    // selected/focused view; do not assign Current or state bits by hand.
    if (Desktop <> nil) and
       (Pointer(Desktop^.Current) <> Pointer(Win[i])) then
    begin
      SavedOptions := Win[i]^.Options;
      Win[i]^.Options := SavedOptions and (not ofTopSelect);
      try
        Win[i]^.Select;
      finally
        Win[i]^.Options := SavedOptions;
      end;
    end;
    // A minimized pane may intentionally retain shared focus. Its icon stays
    // selected, but its hidden terminal child must not become current.
    if (not Win[i]^.Minimized) and (Win[i]^.Term <> nil) then
      Win[i]^.Term^.Select;
    // TWindow.Select is allowed to raise the focused normal window. Minimized
    // icons are desktop controls and must remain above it, without becoming
    // the current/focused view themselves.
    ArrangeIcons;
    // Focus is the only shared window state that is deliberately lock-free.
    // Each click/key selection is an ordered frame; the daemon echoes the
    // winner to every viewer. Input itself remains independently writable.
    if RemoteMode and (not RemoteAttachSettling) and (Remote <> nil) and
       Remote.Connected and (not Win[i]^.Minimized) and
       (RemoteSharedFocus <> i) then
    begin
      if Remote.SendFocus(i) then
        RemoteSharedFocus := i;
    end;
  end;
end;

function TSuperApp.FirstVisiblePane: integer;
var
  i: integer;
begin
  Result := -1;
  for i := 0 to MAX_PANES - 1 do
    if (Win[i] <> nil) and (not Win[i]^.Minimized) then
      Exit(i);
end;

function TSuperApp.FindVisiblePane(AStart, ADelta: integer): integer;
var
  Candidate, Step: integer;
begin
  Result := -1;
  if ADelta = 0 then
    ADelta := 1;
  if (AStart < 0) or (AStart >= MAX_PANES) then
    AStart := 0;
  Candidate := AStart;
  for Step := 1 to MAX_PANES do
  begin
    Candidate := (Candidate + ADelta) mod MAX_PANES;
    if Candidate < 0 then
      Inc(Candidate, MAX_PANES);
    if (Win[Candidate] <> nil) and (not Win[Candidate]^.Minimized) then
      Exit(Candidate);
  end;
end;

procedure TSuperApp.CyclePane(ADelta: integer);
var
  Candidate: integer;
begin
  Candidate := FindVisiblePane(Lay.Focused, ADelta);
  if Candidate >= 0 then
  begin
    Lay.Focused := Candidate;
    FocusPane(Candidate);
  end;
end;

function TSuperApp.FirstFreeIconSlot: integer;
var
  Used: TIconSlotUsed;
  I, Slot: integer;
begin
  Used := Default(TIconSlotUsed);
  for I := 0 to MAX_PANES - 1 do
    if (Win[I] <> nil) and Win[I]^.Minimized then
    begin
      Slot := Win[I]^.IconSlot;
      if (Slot >= 0) and (Slot < MAX_PANES) then
        Used[Slot] := True;
    end;
  for Slot := 0 to MAX_PANES - 1 do
    if not Used[Slot] then
      Exit(Slot);
  Result := MAX_PANES - 1;
end;

// Keep each minimized icon in the slot it obtained on entry.  Restoring one
// leaves a hole; a later minimize reuses the first free hole.  This routine
// maps stable slot numbers to coordinates and raises icons above normal panes,
// but never compacts or renumbers them.
procedure TSuperApp.ArrangeIcons;
const
  DEFAULT_ICON_W = 26;
  MIN_ICON_W = 10;
  ICON_H = 2;
var
  RD, R: Objects.TRect;
  Used: TIconSlotUsed;
  i, Slot, PerRow, DeskW, DeskH, IconW, RowsAvail, ColsNeeded: integer;
  SavedOptions: word;
begin
  if Desktop = nil then
    Exit;
  RD := Default(Objects.TRect);
  Desktop^.GetExtent(RD);
  if RemoteMode and (RemoteDeskW > 0) and (RemoteDeskH > 0) then
    RD.Assign(0, 0, RemoteDeskW, RemoteDeskH);
  DeskW := RD.B.X - RD.A.X;
  DeskH := RD.B.Y - RD.A.Y;
  IconW := DEFAULT_ICON_W;
  RowsAvail := DeskH div ICON_H;
  if RowsAvail < 1 then RowsAvail := 1;
  ColsNeeded := (MAX_PANES + RowsAvail - 1) div RowsAvail;
  if ColsNeeded < 1 then ColsNeeded := 1;
  if (DeskW div IconW) < ColsNeeded then
    IconW := DeskW div ColsNeeded;
  if IconW < MIN_ICON_W then IconW := MIN_ICON_W;
  if IconW > DeskW then IconW := DeskW;
  PerRow := DeskW div IconW;
  if PerRow < 1 then
    PerRow := 1;
  Used := Default(TIconSlotUsed);
  // Repair only malformed/duplicate legacy state. Valid occupied slots never
  // move, regardless of pane index or holes before them.
  for i := 0 to MAX_PANES - 1 do
    if (Win[i] <> nil) and Win[i]^.Minimized then
    begin
      Slot := Win[i]^.IconSlot;
      if (Slot < 0) or (Slot >= MAX_PANES) or Used[Slot] then
        Win[i]^.IconSlot := -1
      else
        Used[Slot] := True;
    end;
  for i := 0 to MAX_PANES - 1 do
    if (Win[i] <> nil) and Win[i]^.Minimized then
    begin
      if Win[i]^.IconSlot < 0 then
      begin
        for Slot := 0 to MAX_PANES - 1 do
          if not Used[Slot] then
            Break;
        if Slot >= MAX_PANES then Slot := MAX_PANES - 1;
        Win[i]^.IconSlot := Slot;
        Used[Slot] := True;
      end;
      Slot := Win[i]^.IconSlot;
      R.Assign((Slot mod PerRow) * IconW,
        RD.B.Y - ICON_H * (1 + Slot div PerRow),
        (Slot mod PerRow) * IconW + IconW,
        RD.B.Y - ICON_H * (Slot div PerRow));
      Win[i]^.Locate(R);
      // Icons are desktop controls, not ordinary windows occupying their old
      // Z slot. Keep every icon above every non-minimized pane; otherwise a
      // large visible pane hides the first slots and only the last icon moved
      // to the front appears to exist. The icons do not overlap each other,
      // so their relative front-to-back order is irrelevant.
      // MakeFirst normally calls ResetCurrent for a selectable view. An icon
      // must move in Z without stealing selection from the shared focused
      // pane, so make it non-selectable only for the relink operation. Its
      // own mouse handler still receives clicks after the option is restored.
      SavedOptions := Win[i]^.Options;
      Win[i]^.Options := SavedOptions and (not ofSelectable);
      Win[i]^.MakeFirst;
      Win[i]^.Options := SavedOptions;
      if DebugFull then
        DebugLog(Format('icon: pane=%d slot=%d rect=%d,%d %dx%d',
          [i, Slot, R.A.X, R.A.Y, R.B.X - R.A.X, R.B.Y - R.A.Y]));
    end;
end;

procedure TSuperApp.MinimizeWindow(i: integer);
var
  SavedSuppress: boolean;
begin
  if (i < 0) or (i >= MAX_PANES) or (Win[i] = nil) or
     Win[i]^.Minimized then
    Exit;
  // Own the pane before changing even the author's local view.  The final
  // FRAME_LAYOUT is the commit (and releases this lock in the daemon), so no
  // authoritative snapshot can roll the icon back between click and commit.
  if RemoteMode and (not RemoteAttachSettling) and (Remote <> nil) and
     Remote.Connected then
    if not LockRemoteLayout(i) then
      Exit;
  if RemoteMode and (i < Length(RemoteGeom)) then
  begin
    RemoteGeom[i].Minimized := True;
    if not RemoteAttachSettling then
      RemoteGeomDirtyPanes[i] := True;
  end;
  SavedSuppress := SuppressFlush;
  SuppressFlush := True;
  try
    if (Win[i]^.IconSlot < 0) or (Win[i]^.IconSlot >= MAX_PANES) then
      Win[i]^.IconSlot := FirstFreeIconSlot;
    if RemoteMode and (i < Length(RemoteGeom)) then
      RemoteGeom[i].IconSlot := Win[i]^.IconSlot;
    Win[i]^.Minimize;
    // Do not re-tile, compact icons or choose another focus. A minimized pane
    // remains the shared logical focus until a user explicitly selects one.
    ArrangeIcons;
    if RemoteMode and (not RemoteAttachSettling) then
      SyncRemoteLayout(i);
    RebuildMenu;
  finally
    SuppressFlush := SavedSuppress;
  end;
  if DebugActive then
    DebugLog(Format('minimize: pane=%d focus=%d', [i, Lay.Focused]));
  if (not SavedSuppress) and (not PassthroughActive) then
    RepaintChanges;
end;

procedure TSuperApp.RestoreWindow(i: integer);
var
  SavedSuppress, SavedSettling: boolean;
begin
  if (i < 0) or (i >= MAX_PANES) or (Win[i] = nil) or
     (not Win[i]^.Minimized) then
    Exit;
  if RemoteMode and (not RemoteAttachSettling) and (Remote <> nil) and
     Remote.Connected then
    if not LockRemoteLayout(i) then
      Exit;
  if RemoteMode and (i < Length(RemoteGeom)) then
  begin
    RemoteGeom[i].Minimized := False;
    RemoteGeom[i].IconSlot := -1;
    if not RemoteAttachSettling then
      RemoteGeomDirtyPanes[i] := True;
  end;
  SavedSuppress := SuppressFlush;
  SuppressFlush := True;
  try
    Win[i]^.Restore;
    // go back EXACTLY to where it was before minimizing, without
    // re-tiling or touching other windows (the user rules positions)
    if (Win[i]^.SavedRect.B.X > Win[i]^.SavedRect.A.X) and
       (Win[i]^.SavedRect.B.Y > Win[i]^.SavedRect.A.Y) then
      Win[i]^.Locate(Win[i]^.SavedRect);
    Win[i]^.IconSlot := -1;
    Lay.Focused := i;
    ArrangeIcons;   // only raises remaining icons; their slots do not move
    if RemoteMode then
    begin
      // Select immediately in this client, but do not emit FRAME_FOCUS while
      // the daemon still considers the pane minimized. The leased layout
      // commit carries this pane as both restored and focused, which the
      // daemon accepts atomically and publishes in one settled snapshot.
      SavedSettling := RemoteAttachSettling;
      RemoteAttachSettling := True;
      try
        FocusPane(i);
      finally
        RemoteAttachSettling := SavedSettling;
      end;
    end
    else
      FocusPane(i);
    if RemoteMode and (not RemoteAttachSettling) then
      SyncRemoteLayout(i);
    RebuildMenu;
  finally
    SuppressFlush := SavedSuppress;
  end;
  if DebugActive then
    DebugLog(Format('restore: pane=%d focus=%d', [i, Lay.Focused]));
  if (not SavedSuppress) and (not PassthroughActive) then
    RepaintChanges;
end;

procedure TSuperApp.MinimizeAllWindows;
var
  i: integer;
  SavedSuppress: boolean;
begin
  if RemoteMode and (not RemoteAttachSettling) and (Remote <> nil) and
     Remote.Connected then
    if not LockRemoteLayout(-1) then
      Exit;
  if RemoteMode then
    for i := 0 to High(RemoteGeom) do
    begin
      RemoteGeom[i].Minimized := True;
      if not RemoteAttachSettling then
        RemoteGeomDirtyPanes[i] := True;
    end;
  SavedSuppress := SuppressFlush;
  SuppressFlush := True;
  try
    for i := 0 to MAX_PANES - 1 do
      if Win[i] <> nil then
        Win[i]^.Minimize;
    ArrangeIcons;   // place all icons at the bottom, without re-tiling
    if RemoteMode then
      for i := 0 to High(RemoteGeom) do
        if (i < MAX_PANES) and (Win[i] <> nil) then
          RemoteGeom[i].IconSlot := Win[i]^.IconSlot;
    if RemoteMode and (not RemoteAttachSettling) then
      SyncRemoteLayout(-1);
    RebuildMenu;
  finally
    SuppressFlush := SavedSuppress;
  end;
  if (not SavedSuppress) and (not PassthroughActive) then
    RepaintChanges;
end;

procedure TSuperApp.RestoreAllWindows;
var
  i: integer;
  SavedSuppress: boolean;
begin
  if RemoteMode and (not RemoteAttachSettling) and (Remote <> nil) and
     Remote.Connected then
    if not LockRemoteLayout(-1) then
      Exit;
  if RemoteMode then
    for i := 0 to High(RemoteGeom) do
    begin
      RemoteGeom[i].Minimized := False;
      RemoteGeom[i].IconSlot := -1;
      if not RemoteAttachSettling then
        RemoteGeomDirtyPanes[i] := True;
    end;
  // Each window returns to its pre-minimize position; nothing re-tiles and
  // this bulk operation never invents a new focus.
  SavedSuppress := SuppressFlush;
  SuppressFlush := True;
  try
    for i := 0 to MAX_PANES - 1 do
      if (Win[i] <> nil) and Win[i]^.Minimized then
      begin
        Win[i]^.Restore;
        if (Win[i]^.SavedRect.B.X > Win[i]^.SavedRect.A.X) and
           (Win[i]^.SavedRect.B.Y > Win[i]^.SavedRect.A.Y) then
          Win[i]^.Locate(Win[i]^.SavedRect);
        Win[i]^.IconSlot := -1;
        Win[i]^.MakeFirst;
      end;
    if (Lay.Focused < 0) or (Lay.Focused >= MAX_PANES) or
       (Win[Lay.Focused] = nil) then
      Lay.Focused := FirstVisiblePane;
    FocusPane(Lay.Focused);
    if RemoteMode and (not RemoteAttachSettling) then
      SyncRemoteLayout(-1);
    RebuildMenu;
  finally
    SuppressFlush := SavedSuppress;
  end;
  if (not SavedSuppress) and (not PassthroughActive) then
    RepaintChanges;
end;

procedure TSuperApp.DoSplit(ADir: TSplitDir; ASysIdx: integer);
var
  OldCount, NewIdx, j: integer;
  DirB: byte;
  ClassS: string;
  SavedSuppress: boolean;
begin
  if CopyMode then
    EndCopyMode(False);
  // Every pane-creation entry point converges here: Classes -> Local shell,
  // configured classes, F2/F3 and the class picker.  Check the one hard
  // limit before the remote branch as well; previously Local shell sent a
  // request that the daemon rejected silently while configured classes used
  // DoOpenClassPane's separate check and showed the dialog.
  if PaneCount >= MAX_PANES then
  begin
    MessageBox(UiText('Maximum 16 panes', 'Maximo 16 paneles'), nil,
      mfInformation or mfOKButton);
    Exit;
  end;
  if Lay.Focused < 0 then
    Lay.Focused := FirstVisiblePane;
  // With no panes at all there is nothing to focus and nothing to split, and
  // that is exactly when a pane is most wanted: the desktop was emptied by
  // closing the last window. Fall through with Focused = -1; both the local
  // path and the daemon read an empty layout as "give me the first pane".
  if (Lay.Focused < 0) and (Lay.PaneCount > 0) then
    Exit;
  if RemoteMode then
  begin
    // the pane lives in the daemon: request it there; the window
    // arrives for all clients with the NEWPANE_EV event
    if (Remote <> nil) and Remote.Connected and
       (Remote.ServerProto >= 2) then
    begin
      if ADir = sdH then DirB := 1 else DirB := 0;
      ClassS := '';
      if (ASysIdx >= 0) and (ASysIdx < Length(WClasses)) then
        ClassS := WClasses[ASysIdx].Name;
      Remote.SendNewPane(Lay.Focused, DirB, ClassS, '', '', '');
    end
    else
      MessageBox(UiText(
        'The session server is too old to open panes remotely.',
        'El servidor de sesion es demasiado antiguo para abrir paneles.'),
        nil, mfError or mfOKButton);
    Exit;
  end;
  // TGroup.InsertBefore deliberately hides, links and shows a view, and each
  // state change draws (vendor/fv322/views.pas).  Keep that supported
  // sequence off the physical terminal until the class-sized window and its
  // focus are both final, then publish one diff.
  SavedSuppress := SuppressFlush;
  SuppressFlush := True;
  try
  OldCount := Lay.PaneCount;
  if (Lay.PaneCount = 0) and Lay.AddFirstPane then
  begin
    // the desktop was left empty: this is the first pane again, not a split
    OldCount := 0;
    NewIdx := 0;
  end
  else if not Lay.SplitPane(Lay.Focused, ADir) then
  begin
    MessageBox(UiText('Maximum 16 panes', 'Maximo 16 paneles'), nil,
      mfInformation or mfOKButton);
    Exit;
  end;
  NewIdx := Lay.LastInsertedIndex;
  // SplitPane reindexes leaves in preorder. Keep the runtime arrays in the
  // same order instead of assuming that the new pane is always last.
  for j := OldCount downto NewIdx + 1 do
  begin
    Panes[j] := Panes[j - 1];
    Scr[j] := Scr[j - 1];
    Win[j] := Win[j - 1];
    PaneTerm[j] := PaneTerm[j - 1];
    PaneConnect[j] := PaneConnect[j - 1];
    if Win[j] <> nil then
    begin
      Win[j]^.SetPaneIdx(j);
    end;
  end;
  Panes[NewIdx] := nil;
  Scr[NewIdx] := nil;
  Win[NewIdx] := nil;
  PaneTerm[NewIdx] := -1;
  PaneConnect[NewIdx] := '';
  // one rule for every way of creating a window: centred, at the size its
  // class asks for, and nothing already open is touched
  NextRect := NewWindowRect(ASysIdx);
  NextRectSet := True;
  if ASysIdx >= 0 then
    StartPaneEx(NewIdx, '', '', ASysIdx, '', '', '', 0)
  else
    StartPane(NewIdx, GetEnvironmentVariable('HOME'), '');
  NextRectSet := False;
  if Win[NewIdx] = nil then
  begin
    // Roll the layout and runtime arrays back together when the new PTY
    // cannot be created.
    Lay.ClosePane(NewIdx);
    for j := NewIdx to OldCount - 1 do
    begin
      Panes[j] := Panes[j + 1];
      Scr[j] := Scr[j + 1];
      Win[j] := Win[j + 1];
      PaneTerm[j] := PaneTerm[j + 1];
      PaneConnect[j] := PaneConnect[j + 1];
      if Win[j] <> nil then
      begin
        Win[j]^.SetPaneIdx(j);
      end;
    end;
    Panes[OldCount] := nil;
    Scr[OldCount] := nil;
    Win[OldCount] := nil;
    PaneTerm[OldCount] := -1;
    PaneConnect[OldCount] := '';
    if Lay.Focused >= OldCount then
      Lay.Focused := OldCount - 1;
    // nothing was added, so no window moved: nothing to re-tile
    FocusPane(Lay.Focused);
    Exit;
  end;
  // do NOT re-tile, and do not touch the window this was opened from: the
  // windows already open keep the size and position the user gave them.
  // Window|Tile (prefix + t) is how you ask for a re-tile.
  Lay.Focused := NewIdx;
  FocusPane(Lay.Focused);
  finally
    SuppressFlush := SavedSuppress;
  end;
  if not SavedSuppress then
    RepaintChanges;
end;

procedure TSuperApp.DoOpenClassPane(ASysIdx: integer);
var
  Dir: TSplitDir;
begin
  if PaneCount = 1 then Dir := sdV else Dir := sdH;
  DoSplit(Dir, ASysIdx);
end;

function TSuperApp.FindWindowClass(const AName: string): integer;
var
  i: integer;
begin
  Result := -1;
  if AName = '' then
    Exit;
  for i := 0 to Length(WClasses) - 1 do
    if SameText(WClasses[i].Name, AName) then
      Exit(i);
end;

function TSuperApp.FindProfile(const AName: string): integer;
var
  i: integer;
begin
  Result := -1;
  if AName = '' then
    Exit;
  for i := 0 to Length(Profiles) - 1 do
    if Profiles[i].Enabled and SameText(Profiles[i].Name, AName) then
      Exit(i);
end;

procedure TSuperApp.ReloadWindowClassCatalog;
var
  I: integer;
  PaneClassNames: array[0..MAX_PANES - 1] of string;
  Fresh, SystemClasses: TWindowClassArray;
begin
  // Configuration is shared by every attached client.  Preserve live pane
  // references by stable class name while replacing a possibly stale local
  // catalogue with an authoritative disk snapshot.
  for I := 0 to MAX_PANES - 1 do
  begin
    PaneClassNames[I] := '';
    if (PaneTerm[I] >= 0) and (PaneTerm[I] < Length(WClasses)) then
      PaneClassNames[I] := WClasses[PaneTerm[I]].Name;
  end;
  LoadWindowClasses(ConfigFile, coUser, Fresh);
  LoadWindowClasses(SystemConfigFile, coSystem, SystemClasses);
  MergeWindowClasses(Fresh, SystemClasses);
  WClasses := Fresh;
  for I := 0 to MAX_PANES - 1 do
    PaneTerm[I] := FindClassByName(WClasses, PaneClassNames[I]);
end;

procedure TSuperApp.ReloadProfileCatalog;
var
  ActiveName: string;
  Fresh: TProfileArray;
  FreshCfg: TConfig;
begin
  ActiveName := '';
  if (ActiveProfile >= 0) and (ActiveProfile < Length(Profiles)) then
    ActiveName := Profiles[ActiveProfile].Name;
  LoadProfiles(ConfigFile, SystemConfigFile, Fresh);
  Profiles := Fresh;
  ActiveProfile := FindProfileByName(Profiles, ActiveName);
  // Profiles and their configured default share one INI generation. Refresh
  // the pair together so an older attached client cannot later write back
  // the default it happened to load at startup.
  LoadConfig(FreshCfg);
  Cfg.DefaultProfile := FreshCfg.DefaultProfile;
  Cfg.DefaultWindow := FreshCfg.DefaultWindow;
end;

function TSuperApp.ProfileStartWindow(AProfile: integer;
  AUseConfiguredWindow: boolean): integer;
var
  I: integer;
begin
  Result := -1;
  if (AProfile < 0) or (AProfile >= Length(Profiles)) or
     (not Profiles[AProfile].Enabled) then
    Exit;
  if AUseConfiguredWindow and (Cfg.DefaultWindow <> '') then
    for I := 0 to High(Profiles[AProfile].Windows) do
      if Profiles[AProfile].Windows[I].Enabled and
         SameText(Profiles[AProfile].Windows[I].Name,
           Cfg.DefaultWindow) then
        Exit(I);
  I := Profiles[AProfile].FocusedWindow;
  if (I >= 0) and (I < Length(Profiles[AProfile].Windows)) and
     Profiles[AProfile].Windows[I].Enabled then
    Exit(I);
  for I := 0 to High(Profiles[AProfile].Windows) do
    if Profiles[AProfile].Windows[I].Enabled then
      Exit(I);
end;

procedure TSuperApp.StopRuntime;
var
  i: integer;
begin
  // Close every view through FreeVision's supported Delete path.  The group
  // lock defers drawing until the old workspace has been removed completely.
  if Desktop <> nil then
    Desktop^.Lock;
  try
    for i := 0 to MAX_PANES - 1 do
      KillPane(i);
  finally
    if Desktop <> nil then
      Desktop^.Unlock;
  end;
  for i := 0 to MAX_PANES - 1 do
  begin
    Panes[i] := nil;
    Scr[i] := nil;
    Win[i] := nil;
    PaneTerm[i] := -1;
    PaneConnect[i] := '';
  end;
end;

procedure TSuperApp.BuildEmptyWorkspace(AProfile: integer);
var
  W, H: Longint;
begin
  StopRuntime;
  FreeAndNil(Lay);
  Lay := TLayout.Create;
  FreeAndNil(Lay.Root);
  Lay.Focused := -1;
  Lay.LastInsertedIndex := -1;
  ActiveProfile := AProfile;
  ActiveWindow := -1;
  ProfileMode := (AProfile >= 0) and (AProfile < Length(Profiles));
  W := Size.X;
  H := Size.Y - Ord(MenuBar <> nil) - Ord(StatusLine <> nil);
  NormalizeDesktopSize(W, H);
  SetCanonicalDesktop(W, H, True, False);
  ResetSizeRequests;
  RepaintChanges;
  RebuildMenu;
end;

procedure TSuperApp.ReleaseRuntime;
var
  i: integer;
begin
  RemoteMembershipReady := False;
  ResetRemotePreviewState;
  ResetRemoteZoomState;
  ResetSizeRequests;
  // Release only this process's client-side objects.  After local detach the
  // forked daemon owns the live child and its duplicate master descriptor;
  // Abandon closes the parent's descriptor and clears the pid before Free,
  // so the destructor cannot signal the daemon-owned PTY process.
  if Desktop <> nil then
    Desktop^.Lock;
  try
    for i := 0 to MAX_PANES - 1 do
    begin
      if Win[i] <> nil then
      begin
        if (Desktop <> nil) and (Win[i]^.Owner = PGroup(Desktop)) then
          Desktop^.Delete(Win[i]);
        Dispose(Win[i], Done);
        Win[i] := nil;
      end;
      if Scr[i] <> nil then
        FreeAndNil(Scr[i]);
      if Panes[i] <> nil then
      begin
        Panes[i].Abandon;
        FreeAndNil(Panes[i]);
      end;
      PaneTerm[i] := -1;
      PaneConnect[i] := '';
    end;
  finally
    if Desktop <> nil then
      Desktop^.Unlock;
  end;
end;

procedure TSuperApp.PrepareDetachedServerChild;
var
  i: integer;
begin
  // A first-SSH-login lock belongs only to the interactive parent.  The
  // forked long-lived daemon must not retain its descriptor and postpone the
  // next creator indefinitely.
  ReleaseSshEntryCreationLock;
  // This hook runs only in the forked child, after setsid and stdio
  // redirection.  Mark the inherited application for the detach-only Done
  // path before touching a view, so even an exceptional cleanup cannot run
  // the local StopRuntime ownership path afterwards.
  DetachRequested := True;
  AbortRun := True;
  SkipSave := True;
  PassthroughActive := False;
  PassPane := -1;

  // FreeVision views remain client-side objects and must be disposed before
  // the long-lived daemon starts.  PTYs, parsers and layout are deliberately
  // NOT freed: StartDetachedServer retained independent parameter references
  // and TDetachedSession becomes their sole owner in this process.
  if Desktop <> nil then
    Desktop^.Lock;
  try
    for i := 0 to MAX_PANES - 1 do
      if Win[i] <> nil then
      begin
        if (Desktop <> nil) and (Win[i]^.Owner = PGroup(Desktop)) then
          Desktop^.Delete(Win[i]);
        Dispose(Win[i], Done);
        Win[i] := nil;
      end;
  finally
    // Clear every transferred reference even if disposing a view raises.
    // Done may now unwind normally without touching daemon-owned objects.
    for i := 0 to MAX_PANES - 1 do
    begin
      Win[i] := nil;
      Panes[i] := nil;
      Scr[i] := nil;
      PaneTerm[i] := -1;
      PaneConnect[i] := '';
    end;
    // Unlock may repaint the now-empty desktop. Keep the layout alive for
    // that last FreeVision operation, but guarantee it is relinquished even
    // if the video driver raises while completing the unlock.
    try
      if Desktop <> nil then
        Desktop^.Unlock;
    finally
      Lay := nil;
    end;
  end;
end;

procedure TSuperApp.WritePaneInput(i: integer; const S: RawByteString);
begin
  if (i < 0) or (i >= MAX_PANES) or (S = '') then
    Exit;
  if RemoteMode then
  begin
    if (Remote <> nil) and Remote.Connected then
    begin
      if DebugFull then
        DebugLog(Format('input-send: pane=%d bytes=%d', [i, Length(S)]));
      Remote.SendInput(i, S);
    end;
  end
  else if (Panes[i] <> nil) and Panes[i].Alive then
    Panes[i].WriteStr(S);
end;

// Raw passthrough keeps terminal output except host-read queries which cannot
// have one coherent answer in a shared session. OSC 52 could expose an outer
// clipboard; OSC 10..19 would make every attached terminal answer separately
// and those replies would become pane input. Pure setters remain byte-for-byte
// raw; a mixed setter/query is blocked as one indivisible OSC transaction.
procedure TSuperApp.PassthroughFiltered(const Data; ALen: integer);
const
  MAX_PASS_OSC = 2 * 1024 * 1024;
var
  P: PByte;
  B: byte;
  OutBuf: RawByteString;
  OutLen, OutCap, NewCap: integer;

  procedure EnsureOut(ANeed: integer);
  begin
    if OutLen + ANeed <= OutCap then
      Exit;
    NewCap := OutCap;
    if NewCap = 0 then NewCap := 4096;
    while NewCap < OutLen + ANeed do
      NewCap := NewCap * 2;
    SetLength(OutBuf, NewCap);
    OutCap := NewCap;
  end;

  procedure EmitByte(AB: byte);
  begin
    EnsureOut(1);
    Inc(OutLen);
    OutBuf[OutLen] := AnsiChar(AB);
  end;

  procedure EmitString(const S: RawByteString);
  begin
    if S = '' then Exit;
    EnsureOut(Length(S));
    Move(S[1], OutBuf[OutLen + 1], Length(S));
    Inc(OutLen, Length(S));
  end;

  procedure ResetPassBuffer;
  begin
    PassFilterBuf := '';
    PassFilterLen := 0;
  end;

  function BufferByte(AB: byte): boolean;
  begin
    Result := PassFilterLen < MAX_PASS_OSC;
    if not Result then Exit;
    if PassFilterLen = Length(PassFilterBuf) then
    begin
      NewCap := Length(PassFilterBuf);
      if NewCap = 0 then NewCap := 1024 else NewCap := NewCap * 2;
      if NewCap > MAX_PASS_OSC then NewCap := MAX_PASS_OSC;
      SetLength(PassFilterBuf, NewCap);
    end;
    Inc(PassFilterLen);
    PassFilterBuf[PassFilterLen] := AnsiChar(AB);
  end;

  function IsClipboardQuery: boolean;
  var
    Body, Rest: RawByteString;
    BodyLen, Sep: integer;
  begin
    Result := False;
    if PassFilterLen < 6 then Exit;
    if byte(PassFilterBuf[PassFilterLen]) = 7 then
      BodyLen := PassFilterLen - 3
    else
      BodyLen := PassFilterLen - 4; // ESC ] body ESC \
    if BodyLen < 3 then Exit;
    Body := Copy(PassFilterBuf, 3, BodyLen);
    if Copy(Body, 1, 3) <> '52;' then Exit;
    Rest := Copy(Body, 4, MaxInt);
    Sep := Pos(';', Rest);
    Result := (Sep > 0) and (Copy(Rest, Sep + 1, MaxInt) = '?');
  end;

  function IsDynamicColorQuery: boolean;
  var
    Body: RawByteString;
    BodyLen, Command, I, Sep, Start, Stop: integer;
  begin
    Result := False;
    if PassFilterLen < 6 then Exit;
    if byte(PassFilterBuf[PassFilterLen]) = 7 then
      BodyLen := PassFilterLen - 3
    else
      BodyLen := PassFilterLen - 4; // ESC ] body ESC \
    if BodyLen < 4 then Exit;
    Body := Copy(PassFilterBuf, 3, BodyLen);
    Sep := Pos(';', Body);
    if Sep <= 1 then Exit;
    Command := 0;
    for I := 1 to Sep - 1 do
    begin
      if (Body[I] < '0') or (Body[I] > '9') then Exit;
      Command := Command * 10 + Ord(Body[I]) - Ord('0');
      if Command > 19 then Exit;
    end;
    if (Command < 10) or (Command > 19) then Exit;
    // PassFilterBuf can hold 2 MiB: scan by index so a hostile OSC with many
    // separators stays O(n), rather than deleting/copying its suffix per field.
    Start := Sep + 1;
    while Start <= Length(Body) do
    begin
      Stop := Start;
      while (Stop <= Length(Body)) and (Body[Stop] <> ';') do
        Inc(Stop);
      if (Stop = Start + 1) and (Body[Start] = '?') then
        Exit(True);
      Start := Stop + 1;
    end;
  end;

  procedure FinishPassOsc;
  begin
    SetLength(PassFilterBuf, PassFilterLen);
    if (not IsClipboardQuery) and (not IsDynamicColorQuery) then
      EmitString(PassFilterBuf);
    ResetPassBuffer;
    PassFilterState := pfsGround;
  end;

begin
  if ALen <= 0 then Exit;
  P := @Data;
  OutBuf := '';
  OutLen := 0;
  OutCap := 0;
  while ALen > 0 do
  begin
    B := P^;
    Inc(P);
    Dec(ALen);
    case PassFilterState of
      pfsGround:
        if B = 27 then
        begin
          ResetPassBuffer;
          BufferByte(B);
          PassFilterState := pfsEsc;
        end
        else
          EmitByte(B);
      pfsEsc:
        if B = Ord(']') then
        begin
          BufferByte(B);
          PassFilterState := pfsOsc;
        end
        else if B = 27 then
        begin
          SetLength(PassFilterBuf, PassFilterLen);
          EmitString(PassFilterBuf);
          ResetPassBuffer;
          BufferByte(B);
        end
        else
        begin
          SetLength(PassFilterBuf, PassFilterLen);
          EmitString(PassFilterBuf);
          EmitByte(B);
          ResetPassBuffer;
          PassFilterState := pfsGround;
        end;
      pfsOsc:
        begin
          if not BufferByte(B) then
          begin
            ResetPassBuffer;
            PassFilterState := pfsDropOsc;
          end
          else if B = 7 then
            FinishPassOsc
          else if B = 27 then
            PassFilterState := pfsOscEsc;
        end;
      pfsOscEsc:
        begin
          if not BufferByte(B) then
          begin
            ResetPassBuffer;
            PassFilterState := pfsDropOsc;
          end
          else if B = Ord('\') then
            FinishPassOsc
          else if B <> 27 then
            PassFilterState := pfsOsc;
        end;
      pfsDropOsc:
        if B = 7 then PassFilterState := pfsGround
        else if B = 27 then PassFilterState := pfsDropOscEsc;
      pfsDropOscEsc:
        if B = Ord('\') then PassFilterState := pfsGround
        else if B <> 27 then PassFilterState := pfsDropOsc;
    end;
  end;
  if OutLen > 0 then
    PassthroughRaw(OutBuf[1], OutLen);
end;

function TSuperApp.PaneClipboardTitle(i: integer): string;
begin
  Result := '';
  if (i >= 0) and (i < MAX_PANES) and (Win[i] <> nil) then
    Result := Trim(Win[i]^.GetTitle(48));
end;

procedure TSuperApp.AddClipboard(const AText: RawByteString;
  AOrigin: TClipboardOrigin; i: integer; AExportHost: boolean);
var
  Seq: RawByteString;
begin
  if (ClipHistory = nil) or
     (not ClipHistory.Add(AText, AOrigin, PaneClipboardTitle(i))) then
    Exit;
  if AExportHost then
  begin
    Seq := EncodeOsc52(AText);
    if Seq <> '' then
      WriteRaw(Seq);
  end;
end;

procedure TSuperApp.PasteClipboardText(const AText: RawByteString);
var
  i: integer;
  S: RawByteString;
begin
  if AText = '' then
    Exit;
  i := Lay.Focused;
  if (i < 0) or (i >= MAX_PANES) or (Scr[i] = nil) then
    Exit;
  if CopyMode then
    EndCopyMode(False);
  if Scr[i].ViewOffset > 0 then
  begin
    Scr[i].SetViewOffset(0);
    RepaintPane(i);
  end;
  if Scr[i].BracketedPaste then
    S := #27'[200~' + AText + #27'[201~'
  else
    S := AText;
  WritePaneInput(i, S);
end;

procedure TSuperApp.PasteLatestClipboard;
begin
  if (ClipHistory = nil) or (ClipHistory.Count = 0) then
  begin
    MessageBox(UiText('Clipboard history is empty.',
      'El historial del portapapeles esta vacio.'), nil,
      mfInformation or mfOKButton);
    Exit;
  end;
  PasteClipboardText(ClipHistory.Latest);
end;

procedure TSuperApp.ShowClipboardHistory;
var
  Sel: integer;
begin
  if (ClipHistory = nil) or (ClipHistory.Count = 0) then
  begin
    MessageBox(UiText('Clipboard history is empty.',
      'El historial del portapapeles esta vacio.'), nil,
      mfInformation or mfOKButton);
    Exit;
  end;
  Sel := 0;
  if RunClipboardHistory(ClipHistory, Sel) then
    PasteClipboardText(ClipHistory.Item(Sel).Text);
end;

procedure TSuperApp.BeginCopyMode;
var
  i, FirstRow: integer;
begin
  i := Lay.Focused;
  if (i < 0) or (i >= MAX_PANES) or (Scr[i] = nil) or (Win[i] = nil) then
    Exit;
  // The passthrough path now keeps the screen mirror current. Reclaim the
  // window manager before showing a selection over that mirror.
  if PassthroughActive then
  begin
    Win[i]^.FullScreen := False;
    if Win[i]^.Zoomed then
      Win[i]^.Zoom;
    UpdatePassthrough;
  end;
  CopyMode := True;
  CopySelecting := False;
  CopyMouseSelecting := False;
  CopyPane := i;
  if Scr[i].ViewOffset = 0 then
  begin
    CopyCursorRow := Scr[i].HistoryRows + Scr[i].CursorY;
    CopyCursorCol := Scr[i].CursorX;
  end
  else
  begin
    FirstRow := Scr[i].HistoryRows - Scr[i].ViewOffset;
    CopyCursorRow := FirstRow + Scr[i].Height - 1;
    CopyCursorCol := 0;
  end;
  if CopyCursorRow >= Scr[i].HistoryRows + Scr[i].Height then
    CopyCursorRow := Scr[i].HistoryRows + Scr[i].Height - 1;
  if CopyCursorCol >= Scr[i].Width then
    CopyCursorCol := Scr[i].Width - 1;
  RepaintPane(i);
end;

procedure TSuperApp.EndCopyMode(ACommit: boolean);
var
  i, R1, C1, R2, C2: integer;
  Text: RawByteString;
begin
  if not CopyMode then
    Exit;
  i := CopyPane;
  Text := '';
  if ACommit and (i >= 0) and (i < MAX_PANES) and (Scr[i] <> nil) then
  begin
    if CopySelecting then
    begin
      R1 := CopyAnchorRow; C1 := CopyAnchorCol;
      R2 := CopyCursorRow; C2 := CopyCursorCol;
    end
    else
    begin
      R1 := CopyCursorRow; C1 := 0;
      R2 := CopyCursorRow; C2 := Scr[i].Width - 1;
    end;
    Text := Scr[i].RenderSelection(R1, C1, R2, C2);
  end;
  CopyMode := False;
  CopySelecting := False;
  CopyMouseSelecting := False;
  CopyPane := -1;
  if (i >= 0) and (i < MAX_PANES) and (Scr[i] <> nil) then
  begin
    Scr[i].SetViewOffset(0);
    RepaintPane(i);
  end;
  if Text <> '' then
    AddClipboard(Text, coPaneSelection, i, True);
end;

procedure TSuperApp.MoveCopyCursor(ADX, ADY: integer);
var
  S: TScreen;
  Total, FirstRow, NewOffset: integer;
  NewRow, NewCol: Int64;
begin
  if (not CopyMode) or (CopyPane < 0) or (CopyPane >= MAX_PANES) then
    Exit;
  S := Scr[CopyPane];
  if S = nil then
  begin
    EndCopyMode(False);
    Exit;
  end;
  Total := S.HistoryRows + S.Height;
  NewRow := Int64(CopyCursorRow) + ADY;
  NewCol := Int64(CopyCursorCol) + ADX;
  if NewRow < 0 then NewRow := 0;
  if NewRow >= Total then NewRow := Total - 1;
  if NewCol < 0 then NewCol := 0;
  if NewCol >= S.Width then NewCol := S.Width - 1;
  CopyCursorRow := NewRow;
  CopyCursorCol := NewCol;

  FirstRow := S.HistoryRows - S.ViewOffset;
  if CopyCursorRow < FirstRow then
    NewOffset := S.HistoryRows - CopyCursorRow
  else if CopyCursorRow >= FirstRow + S.Height then
    NewOffset := S.HistoryRows - (CopyCursorRow - S.Height + 1)
  else
    NewOffset := S.ViewOffset;
  S.SetViewOffset(NewOffset);
  RepaintPane(CopyPane);
end;

procedure TSuperApp.UpdateCopyCursorFromView(APane, ACol, AViewRow: integer;
  AStart, ACommit: boolean);
var
  S: TScreen;
begin
  if (not CopyMode) or (APane <> CopyPane) or
     (APane < 0) or (APane >= MAX_PANES) then
    Exit;
  S := Scr[APane];
  if S = nil then
    Exit;
  Inc(ACol, PaneViewX[APane]);
  Inc(AViewRow, PaneViewY[APane]);
  if ACol < 0 then ACol := 0;
  if ACol >= S.Width then ACol := S.Width - 1;
  if AViewRow < 0 then AViewRow := 0;
  if AViewRow >= S.Height then AViewRow := S.Height - 1;
  CopyCursorCol := ACol;
  CopyCursorRow := S.HistoryRows - S.ViewOffset + AViewRow;
  if AStart then
  begin
    CopyAnchorCol := CopyCursorCol;
    CopyAnchorRow := CopyCursorRow;
    CopySelecting := True;
    CopyMouseSelecting := True;
  end;
  if ACommit then
  begin
    CopyMouseSelecting := False;
    EndCopyMode(True);
  end
  else
    RepaintPane(APane);
end;

function TSuperApp.ClipboardCellMarked(APane, AAbsRow,
  ACol: integer): boolean;
var
  R1, C1, R2, C2, T: integer;
begin
  Result := False;
  if (not CopyMode) or (APane <> CopyPane) then
    Exit;
  if not CopySelecting then
    Exit((AAbsRow = CopyCursorRow) and (ACol = CopyCursorCol));
  R1 := CopyAnchorRow; C1 := CopyAnchorCol;
  R2 := CopyCursorRow; C2 := CopyCursorCol;
  if (R2 < R1) or ((R2 = R1) and (C2 < C1)) then
  begin
    T := R1; R1 := R2; R2 := T;
    T := C1; C1 := C2; C2 := T;
  end;
  if (AAbsRow < R1) or (AAbsRow > R2) then
    Exit;
  if R1 = R2 then
    Result := (ACol >= C1) and (ACol <= C2)
  else if AAbsRow = R1 then
    Result := ACol >= C1
  else if AAbsRow = R2 then
    Result := ACol <= C2
  else
    Result := True;
end;

function TSuperApp.HandleCopyKey(var Event: TEvent): boolean;
var
  S: TScreen;
  PageRows: integer;
begin
  Result := CopyMode and (Event.What = evKeyDown);
  if not Result then
    Exit;
  S := nil;
  if (CopyPane >= 0) and (CopyPane < MAX_PANES) then
    S := Scr[CopyPane];
  if S = nil then
  begin
    EndCopyMode(False);
    ClearEvent(Event);
    Exit;
  end;
  PageRows := S.Height;
  if (CopyPane >= 0) and (CopyPane < MAX_PANES) and
     (Win[CopyPane] <> nil) and (Win[CopyPane]^.Term <> nil) then
    PageRows := Win[CopyPane]^.Term^.Size.Y;
  if PageRows < 1 then PageRows := 1;
  case Event.KeyCode of
    kbEsc: EndCopyMode(False);
    kbEnter: EndCopyMode(True);
    kbSpaceBar:
      begin
        CopyAnchorRow := CopyCursorRow;
        CopyAnchorCol := CopyCursorCol;
        CopySelecting := True;
        RepaintPane(CopyPane);
      end;
    kbLeft: MoveCopyCursor(-1, 0);
    kbRight: MoveCopyCursor(+1, 0);
    kbUp: MoveCopyCursor(0, -1);
    kbDown: MoveCopyCursor(0, +1);
    kbPgUp: MoveCopyCursor(0, -PageRows);
    kbPgDn: MoveCopyCursor(0, +PageRows);
    kbHome: MoveCopyCursor(-MaxInt, 0);
    kbEnd: MoveCopyCursor(+MaxInt, 0);
    kbCtrlHome: MoveCopyCursor(0, -MaxInt);
    kbCtrlEnd: MoveCopyCursor(0, +MaxInt);
  end;
  ClearEvent(Event);
end;

procedure TSuperApp.DrainPaneOsc52(i: integer; AAlreadyPassed: boolean);
var
  Selection, Payload, Text: RawByteString;
begin
  if (i < 0) or (i >= MAX_PANES) or (Scr[i] = nil) then
    Exit;
  Selection := '';
  Payload := '';
  Text := '';
  while Scr[i].TakeOsc52(Selection, Payload) do
  begin
    // A pane may set the clipboard, but it may not query and read the host's
    // clipboard through us. Host clipboard import happens only when the user
    // pastes into the outer terminal.
    if (Payload <> '?') and DecodeOsc52(Payload, Text) then
      AddClipboard(Text, coRemoteOsc52, i, not AAlreadyPassed);
  end;
end;

function TSuperApp.AttachRemoteSession(const APath: string): boolean;
var
  Snapshot: TSessionSnapshot;
  NewLay, OldLay: TLayout;
  Stream: TMemoryStream;
  I, N, SysIdx, FullDeskW, FullDeskH, FullCols, FullRows: integer;
  OldDeskW, OldDeskH: integer;
  MaxDeskW, MaxDeskH: integer;
  OldActiveProfile, OldActiveWindow: integer;
  OldProfileMode: boolean;
  OldSessionName: string;
  TitleS: string;
  Loaded: boolean;
  GR: Objects.TRect;
begin
  if DebugActive then DebugLog('attach: AttachRemoteSession begin (build remote workspace)');
  Result := False;
  RemoteHostSizeArmed := False;
  RemoteHostSummaryValid := False;
  RemoteMembershipReady := False;
  ResetRemotePreviewState;
  ResetRemoteZoomState;
  Remote := TSessionClient.Create;
  if not Remote.Connect(APath, Snapshot, ScreenWidth, ScreenHeight) then
  begin
    // a version mismatch is worth explaining: otherwise the user just gets a
    // fresh local session and no idea why the attach did not happen
    AttachFailReason := Remote.AttachError;
    if DebugActive and (AttachFailReason <> '') then
      DebugLog('attach: refused -- ' + AttachFailReason);
    Remote.Free;
    Remote := nil;
    Exit;
  end;
  RemoteDeskW := Snapshot.DeskW;
  RemoteDeskH := Snapshot.DeskH;
  RemoteClientCount := Snapshot.ClientCount;
  RemoteMinHostW := Snapshot.MinHostW;
  RemoteMinHostH := Snapshot.MinHostH;
  RemoteHostSizesMatch := Snapshot.HostSizesMatch;
  RemoteHostSummaryValid := Snapshot.HostSummaryValid;
  RemoteLockedPanes := Snapshot.LockedPanes;
  RemoteSharedFocus := Snapshot.Focused;
  RemoteGeom := Copy(Snapshot.Geom, 0, Length(Snapshot.Geom));
  RemoteGeometryDirty := False;
  RemoteTreeDirty := False;
  for I := 0 to MAX_PANES - 1 do
    RemoteGeomDirtyPanes[I] := False;
  SharedFullScreenRendered := False;
  if not LoadLayoutString(Snapshot.LayoutNodes, NewLay, True) then
  begin
    Remote.Free;
    Remote := nil;
    Exit;
  end;
  N := Snapshot.PaneCount;
  if (N < 0) or (N > MAX_PANES) or (NewLay.PaneCount <> N) then
  begin
    NewLay.Free;
    Remote.Free;
    Remote := nil;
    Exit;
  end;
  CanonicalDesktopSize(OldDeskW, OldDeskH);
  SetCanonicalDesktop(RemoteDeskW, RemoteDeskH, True, False);
  // save the previous state: per-pane loading can still fail (corrupt
  // screen blob or window not created) and it must be restorable
  OldLay := Lay;
  OldProfileMode := ProfileMode;
  OldActiveProfile := ActiveProfile;
  OldActiveWindow := ActiveWindow;
  OldSessionName := CurrentSessionName;
  Lay := NewLay;
  Lay.Focused := Snapshot.Focused;
  if N = 0 then
    Lay.Focused := -1
  else if (Lay.Focused < 0) or (Lay.Focused >= N) then
    Lay.Focused := 0;
  ProfileMode := False;
  ActiveProfile := -1;
  ActiveWindow := -1;
  RemoteMode := True;
  RemoteAttachSettling := True;
  CurrentSessionName := Snapshot.Name;
  Loaded := True;
  for I := 0 to N - 1 do
  begin
    PaneTerm[I] := -1;
    SysIdx := FindWindowClass(Snapshot.Panes[I].Term);
    if SysIdx >= 0 then
      PaneTerm[I] := SysIdx;
    Stream := TMemoryStream.Create;
    try
      if Length(Snapshot.Panes[I].ScreenData) > 0 then
        Stream.WriteBuffer(Snapshot.Panes[I].ScreenData[0],
          Length(Snapshot.Panes[I].ScreenData));
      Stream.Position := 0;
      Scr[I] := TScreen.Create(1, 1);
      Loaded := Scr[I].LoadFromStream(Stream);
    finally
      Stream.Free;
    end;
    if not Loaded then
      Break;
    TitleS := Trim(Snapshot.Panes[I].Title);
    if TitleS = '' then
      TitleS := UiText('session pane', 'panel de sesion');
    GR := Default(Objects.TRect);
    Desktop^.GetExtent(GR);
    CreateWindowForPane(I, TitleS, GR);
    if Win[I] = nil then
    begin
      Loaded := False;
      Break;
    end;
  end;
  if not Loaded then
  begin
    // undo the whole mutation: startup must continue as if the attach
    // had never been attempted (profile included)
    RemoteMode := False;
    RemoteAttachSettling := False;
    ReleaseRuntime;
    Lay := OldLay;
    ProfileMode := OldProfileMode;
    ActiveProfile := OldActiveProfile;
    ActiveWindow := OldActiveWindow;
    CurrentSessionName := OldSessionName;
    SetCanonicalDesktop(OldDeskW, OldDeskH, True, False);
    NewLay.Free;
    Remote.Free;
    Remote := nil;
    Exit;
  end;
  OldLay.Free;
  RelayoutAll;
  // The daemon's geometry is absolute and canonical. A differently sized host
  // clips it or leaves outer margin; it never substitutes its own desktop.
  if DebugActive then
  begin
    GR := Default(Objects.TRect);
    Desktop^.GetExtent(GR);
    DebugLog(Format('attach: panes=%d geom=%d desk=%dx%d snapshot desk=%dx%d focused=%d',
      [Lay.PaneCount, Length(Snapshot.Geom), GR.B.X - GR.A.X, GR.B.Y - GR.A.Y,
       Snapshot.DeskW, Snapshot.DeskH, Lay.Focused]));
    for I := 0 to High(Snapshot.Geom) do
      DebugLog(Format('attach: geom[%d]=%d,%d %dx%d zoom=%d min=%d',
        [I, Snapshot.Geom[I].BX, Snapshot.Geom[I].BY, Snapshot.Geom[I].BW,
         Snapshot.Geom[I].BH, Ord(Snapshot.Geom[I].Zoomed),
         Ord(Snapshot.Geom[I].Minimized)]));
  end;
  if Length(Snapshot.Geom) = Lay.PaneCount then
  begin
    for I := 0 to Lay.PaneCount - 1 do
      if (I < MAX_PANES) and (Win[I] <> nil) then
      begin
        if (Snapshot.Geom[I].BW > 0) and (Snapshot.Geom[I].BH > 0) then
        begin
          GR.Assign(Snapshot.Geom[I].BX, Snapshot.Geom[I].BY,
            Snapshot.Geom[I].BX + Snapshot.Geom[I].BW,
            Snapshot.Geom[I].BY + Snapshot.Geom[I].BH);
          Win[I]^.Locate(GR);
        end;
        if Snapshot.Geom[I].Zoomed and (not Win[I]^.Zoomed) then
          Win[I]^.Zoom;
        if Snapshot.Geom[I].Zoomed then
        begin
          if Snapshot.Geom[I].FullScreen then
          begin
            SharedFullScreenSize(FullDeskW, FullDeskH, FullCols, FullRows);
            GR.Assign(0, 0, FullDeskW, FullDeskH);
          end
          else
          begin
            // Snapshot Cols/Rows are the daemon-owned shared maximum.  Host
            // membership is metadata, not a reason to invent local bounds.
            MaxDeskW := Snapshot.Geom[I].Cols + 2;
            MaxDeskH := Snapshot.Geom[I].Rows + 2;
            GR.Assign(0, 0, MaxDeskW, MaxDeskH);
          end;
          Win[I]^.Locate(GR);
        end;
        Win[I]^.FullScreen := Snapshot.Geom[I].FullScreen;
        if Snapshot.Geom[I].FullScreen and
           ((Snapshot.ClientCount > 1) or
            (not Snapshot.HostSizesMatch)) then
          SharedFullScreenRendered := True;
      end;
    for I := 0 to Lay.PaneCount - 1 do
      if (I < MAX_PANES) and (Win[I] <> nil) and
         Snapshot.Geom[I].Minimized then
      begin
        Win[I]^.IconSlot := Snapshot.Geom[I].IconSlot;
        MinimizeWindow(I);
      end;
  end;
  // Attaching never sends the host's size to the daemon.
  RemoteAttachSettling := False;
  RepaintChanges;
  if Lay.Focused >= 0 then
    FocusPane(Lay.Focused);
  RebuildMenu;
  CurrentSessionSocket := APath;
  RemoteLayoutHash := ComputeLayoutHash;
  RemoteHostSizeArmed := True;
  RemoteMembershipReady := True;
  RememberSshEntrySession(CurrentSessionName);
  Result := True;
end;

// The daemon created by this very client is a fork of the already settled
// local runtime.  Releasing every Win/Scr and feeding the same snapshot back
// through AttachRemoteSession rebuilt an identical desktop a second time.
// Adopt only the transport/canonical metadata and refresh the existing screen
// models with the daemon snapshot; window objects and their final bounds stay
// in place throughout.
function TSuperApp.AttachPromotedSession(const APath: string): boolean;
var
  Candidate: TSessionClient;
  Snapshot: TSessionSnapshot;
  CheckLay: TLayout;
  Stream: TMemoryStream;
  I, N: integer;
  Loaded: boolean;
begin
  Result := False;
  RemoteHostSizeArmed := False;
  RemoteHostSummaryValid := False;
  RemoteMembershipReady := False;
  ResetRemotePreviewState;
  ResetRemoteZoomState;
  Candidate := TSessionClient.Create;
  CheckLay := nil;
  try
    if not Candidate.Connect(APath, Snapshot, ScreenWidth, ScreenHeight) then
    begin
      AttachFailReason := Candidate.AttachError;
      Exit;
    end;
    N := Snapshot.PaneCount;
    if (Lay = nil) or (N <> Lay.PaneCount) or
       (N < 0) or (N > MAX_PANES) or
       (Length(Snapshot.Geom) <> N) or
       (Snapshot.DeskW <= 0) or (Snapshot.DeskH <= 0) or
       (Snapshot.LayoutNodes <> SaveLayoutString(Lay)) then
    begin
      if DebugActive then
        DebugLog('promote-adopt: newborn snapshot does not match local workspace');
      Exit;
    end;
    if not LoadLayoutString(Snapshot.LayoutNodes, CheckLay, True) or
       (CheckLay.PaneCount <> N) then
      Exit;

    // Output can arrive in the child between fork and ATTACH.  Loading the
    // daemon's current screens into the existing models closes that tiny gap
    // without creating or relocating a single FreeVision view.
    Loaded := True;
    for I := 0 to N - 1 do
    begin
      if (Scr[I] = nil) or (Win[I] = nil) or
         (Length(Snapshot.Panes[I].ScreenData) = 0) then
      begin
        Loaded := False;
        Break;
      end;
      Stream := TMemoryStream.Create;
      try
        Stream.WriteBuffer(Snapshot.Panes[I].ScreenData[0],
          Length(Snapshot.Panes[I].ScreenData));
        Stream.Position := 0;
        Loaded := Scr[I].LoadFromStream(Stream);
      finally
        Stream.Free;
      end;
      if not Loaded then
        Break;
    end;
    if not Loaded then
    begin
      if DebugActive then
        DebugLog('promote-adopt: invalid newborn screen snapshot');
      Exit;
    end;

    Remote := Candidate;
    Candidate := nil;
    RemoteMode := True;
    RemoteLost := False;
    RemoteAttachSettling := False;
    RemoteDeskW := Snapshot.DeskW;
    RemoteDeskH := Snapshot.DeskH;
    RemoteClientCount := Snapshot.ClientCount;
    RemoteMinHostW := Snapshot.MinHostW;
    RemoteMinHostH := Snapshot.MinHostH;
    RemoteHostSizesMatch := Snapshot.HostSizesMatch;
    RemoteHostSummaryValid := Snapshot.HostSummaryValid;
    RemoteLockedPanes := Snapshot.LockedPanes;
    RemoteSharedFocus := Snapshot.Focused;
    RemoteGeom := Copy(Snapshot.Geom, 0, Length(Snapshot.Geom));
    for I := 0 to N - 1 do
      if (I < MAX_PANES) and (Win[I] <> nil) then
        if Snapshot.Geom[I].Minimized then
          Win[I]^.IconSlot := Snapshot.Geom[I].IconSlot
        else
          Win[I]^.IconSlot := -1;
    ArrangeIcons;
    RemoteGeometryDirty := False;
    RemoteTreeDirty := False;
    for I := 0 to MAX_PANES - 1 do
      RemoteGeomDirtyPanes[I] := False;
    SharedFullScreenRendered := False;
    Lay.Focused := Snapshot.Focused;
    CurrentSessionName := Snapshot.Name;
    CurrentSessionSocket := APath;
    ResetSizeRequests;
    RemoteLayoutHash := ComputeLayoutHash;
    RemoteHostSizeArmed := True;
    RemoteMembershipReady := True;
    RememberSshEntrySession(CurrentSessionName);
    if DebugActive then
      DebugLog(Format('promote-adopt: panes=%d desk=%dx%d focused=%d revision=%d',
        [N, Snapshot.DeskW, Snapshot.DeskH, Snapshot.Focused,
         Snapshot.Revision]));
    Result := True;
  finally
    CheckLay.Free;
    Candidate.Free;
  end;
end;

// Move the complete local workspace to a child daemon and attach this UI to
// it. Explicit new-session creation supplies an exact validated name and can
// force promotion even when the ordinary startup preference is not "always".
function TSuperApp.PromoteWorkspace(const ARequestedName: string;
  AForce: boolean; AFailClosed: boolean): boolean;
var
  N, I: integer;
  PtyRefs: TPtyArray;
  ScreenRefs: TScreenArray;
  Titles, Terms: TStrArray;
  Fixed: TBoolArray;
  DGeom: TPaneGeomArray;
  DW, DH: integer;
  SessName, ProfName, Sock: string;
  StartResult: TDetachedServerStartResult;
  Closed: boolean;

  function MaterializeDeferredPanes: boolean;
  var
    P: integer;
    UsedFallback: boolean;
    LocalTitle: string;
  begin
    Result := False;
    for P := 0 to N - 1 do
    begin
      if (Panes[P] = nil) or (Scr[P] = nil) then
        Exit;
      if Panes[P].Alive then
        Continue;
      if (not Panes[P].LaunchPending) or
         (not Panes[P].SpawnConfigured(UsedFallback)) then
        Exit;
      if UsedFallback and (Win[P] <> nil) then
      begin
        LocalTitle := Trim(Win[P]^.GetTitle(80));
        Win[P]^.SetTitle(' ' + UiText('FAILED ', 'FALLO ') + LocalTitle);
        Win[P]^.TitleFixed := True;
        PaneTerm[P] := -2;
      end;
    end;
    Result := True;
  end;
begin
  Result := False;
  PromotionConsumedWorkspace := False;
  if RemoteMode or AbortRun or DetachRequested then
    Exit;
  if DebugActive then DebugLog('promote: PromoteToServer begin (fork daemon, hand off PTYs, re-attach)');
  N := Lay.PaneCount;
  if (N < 0) or (N > MAX_PANES) then
    Exit;
  if (not AForce) and (Cfg.ServerMode <> 'always') then
  begin
    // An attached session may have been opened by a configuration whose own
    // policy is `detach`. Profile/wizard replacement still prepared launches
    // daemon-first because the old UI was remote; if policy declines the new
    // daemon, materialize those exact launches locally before returning.
    MaterializeDeferredPanes;
    Exit;
  end;
  // automatic name, no dialogs: --session > active profile > session
  ProfName := '';
  if ProfileMode and (ActiveProfile >= 0) and
     (ActiveProfile < Length(Profiles)) then
    ProfName := Profiles[ActiveProfile].Name;
  if ARequestedName <> '' then
    SessName := SanitizeSessionName(ARequestedName)
  else if CliSessionName <> '' then
  begin
    if SshEntryMode then
      SessName := SanitizeSessionName(CliSessionName)
    else
      SessName := SuggestSessionName(SanitizeSessionName(CliSessionName));
  end
  else if ProfName <> '' then
    SessName := SuggestSessionName(SanitizeSessionName(ProfName))
  else
    SessName := SuggestSessionName('session');
  PtyRefs := nil;
  ScreenRefs := nil;
  Titles := nil;
  Terms := nil;
  Fixed := nil;
  SetLength(PtyRefs, N);
  SetLength(ScreenRefs, N);
  SetLength(Titles, N);
  SetLength(Terms, N);
  SetLength(Fixed, N);
  for I := 0 to N - 1 do
  begin
    PtyRefs[I] := Panes[I];
    ScreenRefs[I] := Scr[I];
    if Win[I] <> nil then
    begin
      Titles[I] := Trim(Win[I]^.GetTitle(80));
      Fixed[I] := Win[I]^.TitleFixed;
    end;
    if (PaneTerm[I] >= 0) and (PaneTerm[I] < Length(WClasses)) then
      Terms[I] := WClasses[PaneTerm[I]].Name;
    if (PtyRefs[I] = nil) or (ScreenRefs[I] = nil) then
      Exit;   // pane without a live terminal: stay in local mode
  end;
  CollectPaneGeom(DGeom, DW, DH);
  StartResult := StartDetachedServer(SessName, ProfName, Lay, PtyRefs,
    ScreenRefs, Titles, Terms, Lay.Focused, DGeom, DW, DH, Fixed,
    @PrepareDetachedServerChild);
  case StartResult of
    dssFailed:
      begin
        // A restricted SSH entry may never fall back to a private local TUI:
        // every connection must resolve to the canonical daemon.
        if AFailClosed then
        begin
          SkipSave := True;
          AbortRun := True;
          System.ExitCode := 1;
        end;
        // Ordinary server=always startup/profile replacement can still
        // remain a usable local workspace when daemon publication failed
        // before ownership crossed the fork boundary.
        if (not AFailClosed) and (not AForce) then
          MaterializeDeferredPanes;
        Exit;
      end;
    dssOwnershipLost:
      begin
        // Listener creation succeeded and the child adopted the PTYs, but it
        // failed before publication. Abandon the parent's duplicates; using
        // them as a local workspace could signal or corrupt dead/transferred
        // processes. Callers may now restore a previous independent daemon.
        PromotionConsumedWorkspace := True;
        ReleaseRuntime;
        if AFailClosed then
        begin
          SkipSave := True;
          AbortRun := True;
          System.ExitCode := 1;
        end;
        Exit;
      end;
    dssChildFinished:
      begin
        // PromoteToServer is also called from profile/window activation and
        // the wizard, while TApplication.Execute is already running.  Merely
        // returning is sufficient during startup because Main observes
        // AbortRun, but here it would resume the inherited FreeVision loop
        // after the child hook has deliberately disposed every pane window.
        // End that current modal loop synchronously, exactly as detach does.
        DetachRequested := True;
        AbortRun := True;
        Message(@Self, evCommand, cmQuit, nil);
        Result := True;
        Exit;
      end;
  end;
  PromotionConsumedWorkspace := True;
  Sock := SessionSocketPathFor(SessName);
  // This is our own fork: connect its transport and keep the final Win/Scr
  // objects that are already on Desktop. Releasing and calling the generic
  // attach path here used to destroy and reconstruct the same profile.
  if not AttachPromotedSession(Sock) then
  begin
    // The fork already owns the live PTYs. Drop every duplicate descriptor
    // before trying the generic snapshot builder; that slower path can still
    // recover a valid newborn whose exact in-place adoption was rejected.
    ReleaseRuntime;
    BuildEmptyWorkspace(-1);
    if AttachRemoteSession(Sock) then
      Exit(True);
    Closed := CloseSessionAt(Sock);
    if DebugActive and not Closed then
      DebugLog('promote-adopt: fallback attach and daemon close were not acknowledged');
    if not AForce then
    begin
      SkipSave := True;
      AbortRun := True;
      Message(@Self, evCommand, cmQuit, nil);
    end;
    Exit;
  end;

  // The child daemon now owns the PTYs.  Abandon only the parent's duplicate
  // descriptors; the screen/window models remain the attached client view.
  for I := 0 to MAX_PANES - 1 do
    if Panes[I] <> nil then
    begin
      Panes[I].Abandon;
      Panes[I].Free;
      Panes[I] := nil;
    end;
  if ProfileMode then
    RebuildMenu;
  Result := True;
end;

// Ordinary server-always entry point retained for the program block and all
// existing profile/wizard call sites.
procedure TSuperApp.PromoteToServer;
begin
  // Only the initial restricted SSH entry has no independent workspace to
  // recover.  Later New-session transactions, even in an SSH UI, can restore
  // their old daemon and must not poison the application with AbortRun.
  PromoteWorkspace('', False, SshEntryMode);
end;

// leaves the current remote session closing its daemon: the profile
// switch or the wizard rebuild the workspace locally and re-promote
procedure TSuperApp.LeaveRemoteSession;
begin
  if not RemoteMode then
    Exit;
  if (Remote <> nil) and Remote.Connected then
    Remote.CloseSession;
  if Remote <> nil then
  begin
    Remote.Free;
    Remote := nil;
  end;
  RemoteHostSizeArmed := False;
  RemoteHostSummaryValid := False;
  ResetRemotePreviewState;
  ResetRemoteZoomState;
  RemoteMode := False;
  CurrentSessionSocket := '';
  CurrentSessionName := '';
  ReleaseRuntime;
end;

// Detach only this viewer while keeping the daemon and its exact workspace
// alive. Unlike LeaveRemoteSession this is the transaction used before
// creating another session and is therefore safe to roll back by attaching
// OldSocket again.
function TSuperApp.DetachRemoteForSwitch: boolean;
var
  Sent: boolean;
begin
  Result := False;
  if (not RemoteMode) or (Remote = nil) or (not Remote.Connected) then
    Exit;
  SyncRemoteLayout;
  // Detach closes the transport even if its final frame cannot be written.
  // EOF has the same detach semantics in the daemon, so local state must be
  // cleared in both cases instead of retaining a dead TSessionClient.
  Sent := Remote.Detach;
  if DebugActive and not Sent then
    DebugLog('session-switch: detach frame failed; transport close detaches client');
  Remote.Free;
  Remote := nil;
  RemoteHostSizeArmed := False;
  RemoteHostSummaryValid := False;
  ResetRemotePreviewState;
  ResetRemoteZoomState;
  RemoteMode := False;
  CurrentSessionSocket := '';
  CurrentSessionName := '';
  RemoteGeom := nil;
  ReleaseRuntime;
  Result := True;
end;

// session picker for --attach (or startup with live sessions)
function TSuperApp.PickSessionSocketUI(AForAttach: boolean): string;
var
  Act: TSessionPickAction;
  Path: string;
  SavedSF: boolean;
begin
  Result := '';
  Path := '';
  // the picker is an interactive modal: it must render even during the
  // suppressed startup, or it shows up blank until a key is pressed
  SavedSF := SuppressFlush;
  SuppressFlush := False;
  Act := RunSessionPicker(not AForAttach, Path);
  SuppressFlush := SavedSF;
  if Act = spAttach then
    Result := Path;
end;

// normal startup with live sessions: offer attaching before creating
// a new workspace; Esc or "New session" continue the normal startup
function TSuperApp.PromptAttachOnStart: boolean;
var
  Infos: TSessionInfoArray;
  Act: TSessionPickAction;
  Path: string;
  SavedSF: boolean;
begin
  Result := False;
  if not EnumerateSessions(Infos) then
    Exit;
  Path := '';
  // the startup picker is interactive: render it live (the suppressed
  // startup flush would otherwise leave it blank until a key is pressed)
  SavedSF := SuppressFlush;
  SuppressFlush := False;
  Act := RunSessionPicker(True, Path);
  SuppressFlush := SavedSF;
  if (Act = spAttach) and (Path <> '') then
    Result := AttachRemoteSession(Path)
  else if Act = spStartNew then
    Result := DoNewSession(False);
end;

// Session manager inside the app. A remote viewer can switch directly: the
// old daemon is detached, never closed, and is reattached if the target
// cannot be loaded. This is also how a restricted SSH user reaches another
// live session without needing a remote command or a shell.
procedure TSuperApp.DoSessionPick;
var
  Act: TSessionPickAction;
  Path, OldPath: string;
  SavedSuppress: boolean;
begin
  Path := '';
  Act := RunSessionPicker(False, Path);
  if (Act <> spAttach) or (Path = '') then
    Exit;
  if RemoteMode then
  begin
    if Path = CurrentSessionSocket then
      Exit;
    OldPath := CurrentSessionSocket;
    SavedSuppress := SuppressFlush;
    SuppressFlush := True;
    try
      if not DetachRemoteForSwitch then
      begin
        MessageBox(UiText('The current session could not be detached.',
          'No se pudo separar la sesion actual.'), nil,
          mfError or mfOKButton);
        Exit;
      end;
      BuildEmptyWorkspace(-1);
      if AttachRemoteSession(Path) then
        Exit;
      BuildEmptyWorkspace(-1);
      if (OldPath <> '') and AttachRemoteSession(OldPath) then
        MessageBox(UiText(
          'The selected session could not be opened; the previous session was restored.',
          'No se pudo abrir la sesion elegida; se restauro la sesion anterior.'),
          nil, mfError or mfOKButton)
      else
        MessageBox(UiText(
          'The selected session failed and the previous session could not be restored.',
          'Fallo la sesion elegida y no se pudo restaurar la anterior.'),
          nil, mfError or mfOKButton);
    finally
      SuppressFlush := SavedSuppress;
      RepaintChanges;
    end;
    Exit;
  end;
  if Act = spAttach then
    MessageBox(UiText(
      'Detach first (' + PrefixKeyLabel(Cfg.PrefixKey) +
      ' d) and run superterm --attach to connect.',
      'Separa primero (' + PrefixKeyLabel(Cfg.PrefixKey) +
      ' d) y usa superterm --attach para conectar.'),
      nil, mfInformation or mfOKButton);
end;

function TSuperApp.DoNewSession(APreserveCurrent: boolean): boolean;
var
  DefIdx, ProfileIdx, WindowIdx: integer;
  SessionName, OldSocket, OldBase, OldName, SelectedProfileName: string;
  HadOldRemote, Built, OldDefer: boolean;
  SavedSF: boolean;
begin
  Result := False;
  // Another viewer may have created the desired starting profile after this
  // process opened.  The selector must always show the shared current set.
  ReloadProfileCatalog;
  DefIdx := FindProfile(Cfg.DefaultProfile);
  SavedSF := SuppressFlush;
  SuppressFlush := False;
  try
    if not RunNewSessionDialog(Profiles, DefIdx, SessionName,
      ProfileIdx) then
      Exit;
  finally
    SuppressFlush := SavedSF;
  end;

  SelectedProfileName := '';
  if ProfileIdx >= 0 then
  begin
    if (ProfileIdx >= Length(Profiles)) or
       (not Profiles[ProfileIdx].Enabled) then
      Exit;
    SelectedProfileName := Profiles[ProfileIdx].Name;
  end;
  // The dialog may remain open while another client edits the shared file.
  // Its index is only presentation state: linearize the accepted choice by
  // stable name against a new generation before touching the current session.
  ReloadProfileCatalog;
  if SelectedProfileName <> '' then
  begin
    ProfileIdx := FindProfileByName(Profiles, SelectedProfileName);
    if (ProfileIdx < 0) or (not Profiles[ProfileIdx].Enabled) then
    begin
      MessageBox(UiText(
        'The selected profile changed in another client; the current session was not changed.',
        'El perfil seleccionado cambio en otro cliente; no se modifico la sesion actual.'),
        nil, mfError or mfOKButton);
      Exit;
    end;
  end
  else
    ProfileIdx := -1;

  // A local workspace has no independent lifetime yet. Promote it first so
  // "New session" never destroys it. If its natural name is exactly the new
  // requested one, use an explicit previous suffix and reserve the requested
  // name for the workspace the user just confirmed.
  if APreserveCurrent and (not RemoteMode) then
  begin
    OldBase := 'session';
    if ProfileMode and (ActiveProfile >= 0) and
       (ActiveProfile < Length(Profiles)) then
      OldBase := Profiles[ActiveProfile].Name;
    OldName := SuggestSessionName(OldBase);
    if SameText(OldName, SessionName) then
      OldName := SuggestSessionName(OldBase + '-previous');
    if not PromoteWorkspace(OldName, True) then
    begin
      if PromotionConsumedWorkspace then
      begin
        // Ownership crossed the fork boundary but publication failed.  The
        // old local workspace cannot safely resume and there is no older
        // daemon to reattach; leave the UI instead of continuing with dead
        // pane references.
        SkipSave := True;
        AbortRun := True;
        Message(@Self, evCommand, cmQuit, nil);
        Exit(True);
      end;
      MessageBox(UiText(
        'The current workspace could not be preserved as a session.',
        'No se pudo conservar el area actual como sesion.'), nil,
        mfError or mfOKButton);
      Exit;
    end;
    // In the forked daemon this call returns only after the preserved
    // session itself has finished.  Its inherited application is already on
    // the one-way shutdown path; never continue by constructing the newly
    // requested workspace inside that child.
    if DetachedServerChildFinished or AbortRun then
      Exit(True);
  end;

  HadOldRemote := APreserveCurrent and RemoteMode;
  OldSocket := '';
  if HadOldRemote then
  begin
    OldSocket := CurrentSessionSocket;
    if not DetachRemoteForSwitch then
    begin
      MessageBox(UiText('The current session could not be detached.',
        'No se pudo separar la sesion actual.'), nil,
        mfError or mfOKButton);
      Exit;
    end;
  end
  else
  begin
    // Startup has no workspace to preserve. Clear the constructor's empty
    // placeholder before building the selected source.
    StopRuntime;
  end;

  OldDefer := DeferPaneSpawn;
  DeferPaneSpawn := True;
  try
    Built := False;
    if (ProfileIdx >= 0) and (ProfileIdx < Length(Profiles)) and
       Profiles[ProfileIdx].Enabled then
    begin
      WindowIdx := ProfileStartWindow(ProfileIdx, False);
      if (Length(Profiles[ProfileIdx].Windows) = 0) or (WindowIdx >= 0) then
      begin
        Built := ActivateProfile(ProfileIdx, WindowIdx);
        if Built then
          ProfileMode := True;
      end;
    end
    else if ProfileIdx < 0 then
    begin
      BuildEmptyWorkspace(-1);
      Built := True;
    end;

    if Built and PromoteWorkspace(SessionName, True) then
      Exit(True);
  finally
    DeferPaneSpawn := OldDefer;
  end;

  // Only the incomplete new workspace is discarded. The previous daemon was
  // detached, never closed, so attaching its socket restores the exact old
  // state even when profile construction, fork or newborn attach failed.
  BuildEmptyWorkspace(-1);
  if HadOldRemote and (OldSocket <> '') then
  begin
    if AttachRemoteSession(OldSocket) then
      MessageBox(UiText(
        'The new session could not be created; the previous session was restored.',
        'No se pudo crear la nueva sesion; se restauro la sesion anterior.'),
        nil, mfError or mfOKButton)
    else
      MessageBox(UiText(
        'The new session failed and the previous session could not be reattached.',
        'Fallo la nueva sesion y no se pudo reconectar la anterior.'), nil,
        mfError or mfOKButton);
  end
  else
    MessageBox(UiText('The new session could not be created.',
      'No se pudo crear la nueva sesion.'), nil,
      mfError or mfOKButton);
end;

procedure TSuperApp.RequestDetach;
var
  N, I: integer;
  PtyRefs: TPtyArray;
  ScreenRefs: TScreenArray;
  Titles, Terms: TStrArray;
  Fixed: TBoolArray;
  DGeom: TPaneGeomArray;
  DW, DH: integer;
  NameBuf: ShortString;
  SessName, ProfName: string;
  StartResult: TDetachedServerStartResult;
begin
  if DetachRequested then
    Exit;
  if RemoteMode then
  begin
    // Push the current live shared state before detaching. The daemon keeps
    // that exact object alive; no save/reload cycle is involved.
    SyncRemoteLayout;
    if (Remote = nil) or (not Remote.Connected) or (not Remote.Detach) then
    begin
      MessageBox(UiText('The session server is unavailable.',
        'El servidor de sesiones no esta disponible.'), nil,
        mfError or mfOKButton);
      Exit;
    end;
    DetachRequested := True;
    Message(@Self, evCommand, cmQuit, nil);
    Exit;
  end;
  N := Lay.PaneCount;
  if (N < 0) or (N > MAX_PANES) then
    Exit;
  // session name: defaults to the active profile (or a free sesion-N);
  // collision with a live session -> suggest name-2 and ask again
  ProfName := '';
  if ProfileMode and (ActiveProfile >= 0) and
     (ActiveProfile < Length(Profiles)) then
    ProfName := Profiles[ActiveProfile].Name;
  if ProfName <> '' then
    SessName := SuggestSessionName(ProfName)
  else
    SessName := SuggestSessionName(UiText('session', 'sesion'));
  repeat
    NameBuf := Copy(SessName, 1, 32);
    if InputBox(UiText('Detach session', 'Separar sesion'),
      UiText('Session name:', 'Nombre de la sesion:'), NameBuf, 32) <> cmOK then
      Exit;
    SessName := SanitizeSessionName(Trim(NameBuf));
    if SessionIsLive(SessionSocketPathFor(SessName)) then
    begin
      MessageBox(UiText('A session with that name already exists.',
        'Ya existe una sesion con ese nombre.'), nil,
        mfError or mfOKButton);
      SessName := SuggestSessionName(SessName);
    end
    else
      Break;
  until False;
  PtyRefs := nil;
  ScreenRefs := nil;
  Titles := nil;
  Terms := nil;
  Fixed := nil;
  SetLength(PtyRefs, N);
  SetLength(ScreenRefs, N);
  SetLength(Titles, N);
  SetLength(Terms, N);
  SetLength(Fixed, N);
  for I := 0 to N - 1 do
  begin
    PtyRefs[I] := Panes[I];
    ScreenRefs[I] := Scr[I];
    if Win[I] <> nil then
    begin
      Titles[I] := Trim(Win[I]^.GetTitle(80));
      Fixed[I] := Win[I]^.TitleFixed;
    end;
    if PaneTerm[I] >= 0 then
      if PaneTerm[I] < Length(WClasses) then
        Terms[I] := WClasses[PaneTerm[I]].Name;
    if (PtyRefs[I] = nil) or (ScreenRefs[I] = nil) then
    begin
      // warn instead of silently aborting: the user already confirmed a
      // name and must know that the session has NOT been detached
      MessageBox(UiText(
        'Cannot detach: a pane has no live terminal.',
        'No se puede separar: un panel no tiene terminal vivo.'), nil,
        mfError or mfOKButton);
      Exit;
    end;
  end;
  // the daemon is born knowing the current window geometry
  CollectPaneGeom(DGeom, DW, DH);
  StartResult := StartDetachedServer(SessName, ProfName, Lay, PtyRefs,
    ScreenRefs, Titles, Terms, Lay.Focused, DGeom, DW, DH, Fixed,
    @PrepareDetachedServerChild);
  if StartResult = dssFailed then
  begin
    MessageBox(UiText('Could not create the detached session server.',
      'No se pudo crear el servidor de la sesion separada.'), nil,
      mfError or mfOKButton);
    Exit;
  end;
  if StartResult = dssOwnershipLost then
    MessageBox(UiText(
      'The session server failed after taking ownership; this client will close safely.',
      'El servidor fallo tras tomar posesion; este cliente se cerrara de forma segura.'),
      nil, mfError or mfOKButton);
  // Both processes leave this event loop through the same path.  In the
  // parent the daemon is now ready; in the child its Run has just finished.
  DetachRequested := True;
  Message(@Self, evCommand, cmQuit, nil);
end;

function TSuperApp.ActivateProfile(AProfile, AWindow: integer): boolean;
var
  WasRemote: boolean;
  NewLay: TLayout;
  WS: TProfileWindowSpec;
  PS: TProfilePaneSpec;
  AdHoc: TWindowClass;
  i, n, SysIdx: integer;
  DeskW, DeskH: Longint;
  Started, OldDefer: boolean;
  CommandOverride, LocalCmd, ShellFor, TitleS: string;
begin
  Result := False;
  if (AProfile < 0) or (AProfile >= Length(Profiles)) or
     (not Profiles[AProfile].Enabled) then
    Exit;
  // A profile with no windows is an explicit empty starting point, not an
  // invalid profile. It remains active so it can be selected as the source
  // of a named session and later receive its first pane.
  if Length(Profiles[AProfile].Windows) = 0 then
  begin
    OldDefer := DeferPaneSpawn;
    WasRemote := RemoteMode;
    if WasRemote then
      DeferPaneSpawn := True;
    if RemoteMode then
      LeaveRemoteSession;
    BuildEmptyWorkspace(AProfile);
    Result := True;
    if WasRemote then
      PromoteToServer;
    DeferPaneSpawn := OldDefer;
    Exit;
  end;
  if (AWindow < 0) or (AWindow >= Length(Profiles[AProfile].Windows)) or
     (not Profiles[AProfile].Windows[AWindow].Enabled) then
    Exit;
  // switching profiles while attached: the remote session is closed
  // and the new workspace is built locally (re-promoted at the end)
  WasRemote := RemoteMode;
  OldDefer := DeferPaneSpawn;
  if WasRemote then
    DeferPaneSpawn := True;
  if RemoteMode then
    LeaveRemoteSession;

  WS := Profiles[AProfile].Windows[AWindow];
  if not LoadLayoutString(WS.Layout, NewLay, True) then
    NewLay := TLayout.Create;
  n := NewLay.PaneCount;
  DebugLog(Format('profile activate p=%d w=%d layout=%s leaves=%d specs=%d',
    [AProfile, AWindow, WS.Layout, n, Length(WS.Panes)]));
  if (Length(WS.Panes) > n) or (n < 0) or (n > MAX_PANES) then
  begin
    NewLay.Free;
    DeferPaneSpawn := OldDefer;
    Exit;
  end;

  StopRuntime;
  if Lay <> nil then
    Lay.Free;
  Lay := NewLay;
  ActiveProfile := AProfile;
  ActiveWindow := AWindow;
  if IsDesktopSizeValid(WS.DeskW, WS.DeskH) then
  begin
    DeskW := WS.DeskW;
    DeskH := WS.DeskH;
  end
  else
  begin
    // Legacy profile: the creator establishes its canonical size exactly
    // once; promotion then stores it in the live daemon snapshot.
    DeskW := Size.X;
    DeskH := Size.Y - Ord(MenuBar <> nil) - Ord(StatusLine <> nil);
    NormalizeDesktopSize(DeskW, DeskH);
  end;
  SetCanonicalDesktop(DeskW, DeskH, True, False);

  // Build the profile as data and detached view objects.  CreateWindowForPane
  // deliberately does not insert them into Desktop in this scope, so the
  // only application states are the closed old workspace and the complete
  // new one -- never one provisional window followed by two.
  Started := True;
  DeferWindowInsert := True;
  try
    for i := 0 to n - 1 do
    begin
      PS := Default(TProfilePaneSpec);
      PS.IconSlot := -1;
      PS.Name := 'pane' + IntToStr(i);
      PS.Enabled := True;
      if i <= High(WS.Panes) then
        PS := WS.Panes[i];
      SysIdx := FindWindowClass(PS.WClass);
      TitleS := Profiles[AProfile].Name + '/' + WS.Name;
      DebugLog(Format('profile pane=%d enabled=%d class=%s cmd=%s post=%s sysidx=%d',
        [i, Ord(PS.Enabled), PS.WClass, PS.Cmd, PS.PostConnect, SysIdx]));
      if not PS.Enabled then
        StartPane(i, '', '')
      else if (SysIdx >= 0) and (WClasses[SysIdx].Kind = wcSSH) then
      begin
        // ssh: the pane.post > class.post > pane.cmd > class.cmd precedence
        // is resolved between the override and BuildWindowClassExec
        CommandOverride := PS.PostConnect;
        if CommandOverride = '' then
          CommandOverride := PS.Cmd;
        StartPaneEx(i, PS.Cwd, '', SysIdx, '', '', TitleS, PS.ScrollBack,
          CommandOverride);
      end
      else if SysIdx >= 0 then
      begin
        // local or free-command class with pane overrides
        if WClasses[SysIdx].Shell <> '' then
          ShellFor := WClasses[SysIdx].Shell
        else
          ShellFor := Cfg.Shell;
        LocalCmd := ComposePaneCommand(WClasses[SysIdx], PS.Cmd, PS.PostConnect,
          PS.Connect, ShellFor, Cfg.LoginShell);
        StartPaneEx(i, PS.Cwd, '', SysIdx, '', '', TitleS, PS.ScrollBack,
          LocalCmd);
      end
      else
      begin
        // ad-hoc pane without a class (includes persisted wizard ones)
        AdHoc := DefaultWindowClass;
        LocalCmd := ComposePaneCommand(AdHoc, PS.Cmd, PS.PostConnect,
          PS.Connect, Cfg.Shell, Cfg.LoginShell);
        StartPaneEx(i, PS.Cwd, LocalCmd, -1, '', '', TitleS, PS.ScrollBack);
        PaneConnect[i] := PS.Connect;
      end;
      // custom title saved in the profile: wins over class/cwd
      if (PS.Title <> '') and (Win[i] <> nil) then
      begin
        Win[i]^.SetTitle(' ' + PS.Title);
        Win[i]^.TitleFixed := True;
      end;
      if Win[i] = nil then
        Started := False;
    end;
  finally
    DeferWindowInsert := False;
  end;
  if not Started then
  begin
    StopRuntime;
    DeferPaneSpawn := OldDefer;
    Exit;
  end;
  Lay.Focused := WS.FocusedPane;
  if n = 0 then
    Lay.Focused := -1
  else if (Lay.Focused < 0) or (Lay.Focused >= n) or
          (Win[Lay.Focused] = nil) then
    Lay.Focused := 0;
  RelayoutAll;
  ApplyWindowGeometry(WS);
  // Insert the complete, already-sized set only after every pane succeeded.
  // Use FreeVision's supported insertion path; it establishes the view ring,
  // activation and current-view invariants that raw linking cannot reproduce.
  if Desktop <> nil then
    Desktop^.Lock;
  try
    for i := 0 to n - 1 do
      if (Win[i] <> nil) and (Win[i]^.Owner = nil) then
        Desktop^.Insert(Win[i]);
    FocusPane(Lay.Focused);
    ArrangeIcons;
  finally
    if Desktop <> nil then
      Desktop^.Unlock;
  end;
  RebuildMenu;
  Result := True;
  if WasRemote then
    PromoteToServer;   // the new session is also born with a server
  DeferPaneSpawn := OldDefer;
end;

// Reapply the exact geometry after ActivateProfile has installed that
// workspace's canonical desktop. Physical terminal size is irrelevant.
procedure TSuperApp.ApplyWindowGeometry(const WS: TProfileWindowSpec);
var
  RD, WR: Objects.TRect;
  i, n: integer;
begin
  if (Desktop = nil) or (WS.DeskW <= 0) or (WS.DeskH <= 0) then
    Exit;
  RD := Default(Objects.TRect);
  Desktop^.GetExtent(RD);
  if (WS.DeskW <> RD.B.X - RD.A.X) or (WS.DeskH <> RD.B.Y - RD.A.Y) then
    Exit;
  n := Lay.PaneCount;
  for i := 0 to n - 1 do
    if (i <= High(WS.Panes)) and (i < MAX_PANES) and (Win[i] <> nil) then
    begin
      if (WS.Panes[i].BW > 0) and (WS.Panes[i].BH > 0) then
      begin
        WR := Default(Objects.TRect);
        WR.Assign(WS.Panes[i].BX, WS.Panes[i].BY,
          WS.Panes[i].BX + WS.Panes[i].BW, WS.Panes[i].BY + WS.Panes[i].BH);
        Win[i]^.Locate(WR);
      end;
      if WS.Panes[i].Zoomed then
      begin
        // The window is still outside Desktop while a profile is built.
        // TWindow.Zoom cannot be used there: without an owner its SizeLimits
        // maximum is High(Sw_Integer).  Install the same final state directly
        // from the already definitive restore rectangle.
        Win[i]^.GetBounds(Win[i]^.ZoomRect);
        WR.Assign(0, 0, RD.B.X - RD.A.X, RD.B.Y - RD.A.Y);
        Win[i]^.Locate(WR);
        Win[i]^.Zoomed := True;
        Win[i]^.FullScreen := False;
      end;
    end;
  // Minimized windows are also prepared off-desktop.  Calling the interactive
  // MinimizeWindow path here would rebuild menus, focus and repaint after
  // each pane, creating states that are not part of the saved profile.
  for i := 0 to n - 1 do
    if (i <= High(WS.Panes)) and (i < MAX_PANES) and (Win[i] <> nil) and
       WS.Panes[i].Minimized then
    begin
      Win[i]^.IconSlot := WS.Panes[i].IconSlot;
      Win[i]^.Minimize;
    end;
  ArrangeIcons;
  if (Lay.Focused < 0) or (Lay.Focused >= n) or
     (Win[Lay.Focused] = nil) then
    Lay.Focused := FirstVisiblePane;
end;

function TSuperApp.CaptureCurrentAsWindow(const AName: string): TProfileWindowSpec;
var
  i, n: integer;
  WR, RD: Objects.TRect;
  RL: TListInfo;
  HaveRL: boolean;
  NoArgs: TStringArray;
begin
  // in server mode the PTYs live in the daemon: ask it for live cmd/cwd
  RL := Default(TListInfo);
  HaveRL := RemoteMode and (CurrentSessionSocket <> '') and
    FetchList(CurrentSessionSocket, True, RL);
  NoArgs := nil;
  Result := Default(TProfileWindowSpec);
  Result.Name := AName;
  Result.Enabled := True;
  Result.Layout := SaveLayoutString(Lay);
  Result.FocusedPane := Lay.Focused;
  // Persist the one canonical desktop together with its absolute bounds.
  RD := Default(Objects.TRect);
  if Desktop <> nil then
  begin
    Desktop^.GetExtent(RD);
    Result.DeskW := RD.B.X - RD.A.X;
    Result.DeskH := RD.B.Y - RD.A.Y;
  end;
  n := Lay.PaneCount;
  if n > MAX_PANES then
    n := MAX_PANES;
  SetLength(Result.Panes, n);
  for i := 0 to n - 1 do
  begin
    Result.Panes[i] := Default(TProfilePaneSpec);
    Result.Panes[i].IconSlot := -1;
    Result.Panes[i].Name := 'pane' + IntToStr(i + 1);
    Result.Panes[i].Enabled := True;
    // A saved profile is a snapshot of the workspace, not merely a recipe
    // for approximating it. Keep the title that is visible now even when it
    // was derived from the foreground command/cwd rather than renamed by
    // hand. On restore it is deliberately fixed, so a pane called "Codex"
    // or "Claude" does not fall back to "shell" a moment later.
    if (Win[i] <> nil) and (Win[i]^.Title <> nil) then
      Result.Panes[i].Title := Trim(Win[i]^.Title^);
    // Preserve the actual per-pane history capacity as well. Leaving this at
    // the record default (zero) made a profile silently return to the global
    // default instead of the value the workspace was using.
    if Scr[i] <> nil then
      Result.Panes[i].ScrollBack := Scr[i].MaxScrollBack;
    // EXACT window geometry: a maximized one contributes its ZoomRect,
    // a minimized one its SavedRect, the rest their current bounds
    if (Win[i] <> nil) then
    begin
      if Win[i]^.Zoomed then
        WR := Win[i]^.ZoomRect
      else if Win[i]^.Minimized then
        WR := Win[i]^.SavedRect
      else
      begin
        WR := Default(Objects.TRect);
        Win[i]^.GetBounds(WR);
      end;
      Result.Panes[i].BX := WR.A.X;
      Result.Panes[i].BY := WR.A.Y;
      Result.Panes[i].BW := WR.B.X - WR.A.X;
      Result.Panes[i].BH := WR.B.Y - WR.A.Y;
      Result.Panes[i].Minimized := Win[i]^.Minimized;
      if Win[i]^.Minimized then
        Result.Panes[i].IconSlot := Win[i]^.IconSlot;
      Result.Panes[i].Zoomed := Win[i]^.Zoomed;
    end;
    if (PaneTerm[i] >= 0) and (PaneTerm[i] < Length(WClasses)) then
      Result.Panes[i].WClass := WClasses[PaneTerm[i]].Name
    else if Panes[i] <> nil then
    begin
      if PaneConnect[i] <> '' then
        Result.Panes[i].Connect := PaneConnect[i]
      else
      begin
        Panes[i].QueryState;
        // an interactive shell is captured as an empty cmd (= plain shell)
        if not IsPlainShell(Panes[i].TitleArgs, Panes[i].TitleCmd) then
        begin
          if Length(Panes[i].TitleArgs) > 0 then
            Result.Panes[i].Cmd := ArgsAsShell(Panes[i].TitleArgs)
          else
            Result.Panes[i].Cmd := Panes[i].TitleCmd;
        end;
        Result.Panes[i].Cwd := Panes[i].TitleCwd;
      end;
    end
    else if HaveRL and (i < Length(RL.Panes)) then
    begin
      if not IsPlainShell(NoArgs, RL.Panes[i].Cmd) then
        Result.Panes[i].Cmd := RL.Panes[i].Cmd;
      Result.Panes[i].Cwd := RL.Panes[i].Cwd;
    end;
  end;
end;

function TSuperApp.SaveWorkspaceAsProfile(const AName: string): boolean;
var
  P: TProfileSpec;
  ActiveName: string;
begin
  Result := False;
  if not ValidProfileName(AName) then
    Exit;
  ActiveName := '';
  if (ActiveProfile >= 0) and (ActiveProfile < Length(Profiles)) then
    ActiveName := Profiles[ActiveProfile].Name;
  P := Default(TProfileSpec);
  P.Name := AName;
  P.Enabled := True;
  P.Origin := coUser;
  P.FocusedWindow := 0;
  SetLength(P.Windows, 1);
  P.Windows[0] := CaptureCurrentAsWindow(UiText('main', 'principal'));
  try
    Result := UpsertUserProfileAtomic(ConfigFile, SystemConfigFile, P,
      Profiles);
    // The atomic operation refreshes Profiles on both success and conflict.
    // Rebind the live selection by stable name before returning to the menu.
    ActiveProfile := FindProfileByName(Profiles, ActiveName);
    RebuildMenu;
    if not Result then
      MessageBox(UiText(
        'That profile changed in another client; it was reloaded. Try again.',
        'Ese perfil cambio en otro cliente; se ha recargado. Intentalo otra vez.'),
        nil, mfError or mfOKButton);
  except
    on E: Exception do
    begin
      MessageBox(StringReplace(Format(UiText(
        'The profile could not be saved: %s',
        'No se pudo guardar el perfil: %s'), [E.Message]), '%', '%%',
        [rfReplaceAll]), nil,
        mfError or mfOKButton);
      Result := False;
    end;
  end;
end;

procedure TSuperApp.RunProfileSaveAs;
var
  NameS: string;
  Buf: ShortString;
begin
  ReloadProfileCatalog;
  Buf := '';
  if ProfileMode and (ActiveProfile >= 0) and
     (ActiveProfile < Length(Profiles)) then
    Buf := Copy(Profiles[ActiveProfile].Name, 1, 32);
  if InputBox(UiText('Save profile', 'Guardar perfil'),
    UiText('Profile name:', 'Nombre del perfil:'), Buf, 32) <> cmOK then
    Exit;
  NameS := Trim(Buf);
  if NameS = '' then
    Exit;
  if not ValidProfileName(NameS) then
  begin
    MessageBox(UiText(
      'The name cannot contain dots, brackets or control characters.',
      'El nombre no puede contener puntos, corchetes ni caracteres de control.'),
      nil, mfError or mfOKButton);
    Exit;
  end;
  if not SaveWorkspaceAsProfile(NameS) then
    Exit;
  // no FormatStr: the name could contain '%'
  MessageBox(UiText('Profile saved: ', 'Perfil guardado: ') + NameS, nil,
    mfInformation or mfOKButton);
end;

procedure TSuperApp.DoProfileManage;
var
  Act: TProfileAction;
  Tgt, DefIdx: integer;
  DefWin: integer;
  P: TProfileSpec;
  FreshCfg: TConfig;
  ActiveName, TargetName, PreferredWindow, SelectedWindow: string;
begin
  ReloadProfileCatalog;
  DefIdx := FindProfileByName(Profiles, Cfg.DefaultProfile);
  if not RunProfileManager(Profiles, ActiveProfile, DefIdx, Act, Tgt) then
    Exit;
  // Rename/delete already remapped a matching default inside the same atomic
  // profile-file generation. A manager which merely edited another profile
  // must never write its startup-era default back over a newer client's one.
  LoadConfig(FreshCfg);
  Cfg.DefaultProfile := FreshCfg.DefaultProfile;
  Cfg.DefaultWindow := FreshCfg.DefaultWindow;
  case Act of
    paActivate:
      DoSwitchProfile(Tgt);
    paSaveCurrent:
      if (Tgt >= 0) and (Tgt < Length(Profiles)) then
      begin
        ActiveName := '';
        if (ActiveProfile >= 0) and (ActiveProfile < Length(Profiles)) then
          ActiveName := Profiles[ActiveProfile].Name;
        P := Profiles[Tgt];
        // Record assignment shares nested dynamic arrays. Copy the window
        // vector before replacing one entry so a failed commit cannot mutate
        // the live profile array in memory.
        P.Windows := Copy(Profiles[Tgt].Windows, 0,
          Length(Profiles[Tgt].Windows));
        if ProfileMode and (Tgt = ActiveProfile) and (ActiveWindow >= 0) and
           (ActiveWindow < Length(P.Windows)) then
        begin
          // save the current workspace ONLY into the active window of the
          // profile, preserving its other windows
          P.Windows[ActiveWindow] :=
            CaptureCurrentAsWindow(P.Windows[ActiveWindow].Name);
          P.FocusedWindow := ActiveWindow;
        end
        else
        begin
          SetLength(P.Windows, 1);
          P.Windows[0] :=
            CaptureCurrentAsWindow(UiText('main', 'principal'));
          P.FocusedWindow := 0;
        end;
        P.Origin := coUser;
        try
          if not UpsertUserProfileAtomic(ConfigFile, SystemConfigFile, P,
            Profiles) then
            MessageBox(UiText(
              'The profile changed in another client; it was reloaded. Try again.',
              'El perfil cambio en otro cliente; se ha recargado. ' +
              'Intentalo otra vez.'), nil,
              mfError or mfOKButton);
          ActiveProfile := FindProfileByName(Profiles, ActiveName);
        except
          on E: Exception do
            MessageBox(StringReplace(Format(UiText(
              'The profile could not be saved: %s',
              'No se pudo guardar el perfil: %s'), [E.Message]), '%', '%%',
              [rfReplaceAll]), nil,
              mfError or mfOKButton);
        end;
      end;
    paSetDefault:
      if (Tgt >= 0) and (Tgt < Length(Profiles)) then
      begin
        TargetName := Profiles[Tgt].Name;
        PreferredWindow := '';
        if (Tgt = ActiveProfile) and (ActiveWindow >= 0) and
           (ActiveWindow < Length(Profiles[Tgt].Windows)) then
          PreferredWindow := Profiles[Tgt].Windows[ActiveWindow].Name
        else
        begin
          DefWin := Profiles[Tgt].FocusedWindow;
          if (DefWin >= 0) and (DefWin < Length(Profiles[Tgt].Windows)) then
            PreferredWindow := Profiles[Tgt].Windows[DefWin].Name;
        end;
        ActiveName := '';
        if (ActiveProfile >= 0) and (ActiveProfile < Length(Profiles)) then
          ActiveName := Profiles[ActiveProfile].Name;
        try
          if SetDefaultProfileAtomic(ConfigFile, SystemConfigFile,
            TargetName, PreferredWindow, Profiles, SelectedWindow) then
          begin
            Cfg.DefaultProfile := TargetName;
            Cfg.DefaultWindow := SelectedWindow;
          end
          else
            MessageBox(UiText(
              'The selected profile changed in another client; the default was not changed.',
              'El perfil seleccionado cambio en otro cliente; no se cambio el predeterminado.'),
              nil, mfError or mfOKButton);
          ActiveProfile := FindProfileByName(Profiles, ActiveName);
        except
          on E: Exception do
            MessageBox(StringReplace(Format(UiText(
              'The default profile could not be saved: %s',
              'No se pudo guardar el perfil predeterminado: %s'),
              [E.Message]), '%', '%%', [rfReplaceAll]), nil,
              mfError or mfOKButton);
        end;
      end;
    paNone: ;
  end;
  RebuildMenu;
end;

procedure TSuperApp.RunSessionWizard;
var
  ConnectCmd, PostConnectCmd: array[0..3] of ShortString;
  WindowCountText: ShortString;
  WindowCount, Code, I: integer;
  Choice: Word;
  NewLay: TLayout;
  Dir: TSplitDir;
  Started, WasRemote, OldDefer: boolean;
begin
  for I := 0 to 3 do
  begin
    ConnectCmd[I] := '';
    PostConnectCmd[I] := '';
  end;
  WindowCountText := '1';
  repeat
    Choice := InputBox(UiText('Session wizard', 'Asistente de sesion'),
      UiText('Number of panes (1-4):', 'Numero de paneles (1-4):'),
      WindowCountText, 1);
    if Choice = cmCancel then
      Exit;
    Val(Trim(WindowCountText), WindowCount, Code);
    if (Code <> 0) or (WindowCount < 1) or (WindowCount > 4) then
    begin
      MessageBox(UiText('Enter a number from 1 to 4.',
        'Escribe un numero entre 1 y 4.'), nil,
        mfError or mfOKButton);
      WindowCountText := '1';
    end;
  until (Code = 0) and (WindowCount >= 1) and (WindowCount <= 4);

  // Collect every command before stopping the current session. Cancelling at
  // any point therefore leaves the existing panes untouched.
  for I := 0 to WindowCount - 1 do
  begin
    ConnectCmd[I] := '';
    Choice := InputBox(
      Format(UiText('Wizard: pane %d/%d', 'Asistente: panel %d/%d'),
        [I + 1, WindowCount]),
      UiText('Connection command:', 'Comando de conexion:'), ConnectCmd[I], 240);
    if Choice = cmCancel then
      Exit;
    if Trim(ConnectCmd[I]) = '' then
    begin
      MessageBox(UiText('The connection command cannot be empty.',
        'El comando de conexion no puede estar vacio.'), nil,
        mfError or mfOKButton);
      Exit;
    end;

    PostConnectCmd[I] := '';
    Choice := InputBox(
      Format(UiText('Wizard: pane %d/%d', 'Asistente: panel %d/%d'),
        [I + 1, WindowCount]),
      UiText('After connecting (optional):',
        'Despues de conectar (opcional):'), PostConnectCmd[I], 240);
    if Choice = cmCancel then
      Exit;
  end;
  // everything confirmed: if we were attached to a session (server-
  // always mode), close it; the new workspace is born locally and
  // re-promoted at the end
  WasRemote := RemoteMode;
  OldDefer := DeferPaneSpawn;
  if RemoteMode then
    LeaveRemoteSession;

  NewLay := TLayout.Create;
  for I := 1 to WindowCount - 1 do
  begin
    if (WindowCount = 2) or Odd(I) then
      Dir := sdV
    else
      Dir := sdH;
    if not NewLay.SplitPane(I - 1, Dir) then
    begin
      NewLay.Free;
      MessageBox(UiText('The session layout could not be created.',
        'No se pudo crear el layout de la sesion.'), nil,
        mfError or mfOKButton);
      Exit;
    end;
  end;

  if WasRemote then
    DeferPaneSpawn := True;
  StopRuntime;
  if Lay <> nil then
    Lay.Free;
  Lay := NewLay;
  ActiveProfile := -1;
  ActiveWindow := -1;
  ProfileMode := False;
  Started := True;
  for I := 0 to WindowCount - 1 do
  begin
    StartPaneEx(I, GetEnvironmentVariable('HOME'),
      WizardCommand(ConnectCmd[I], PostConnectCmd[I]), -1, '', '',
      UiText('wizard ', 'asistente ') + IntToStr(I + 1), DEFAULT_SCROLLBACK);
    // remember the free-form connection to save this as a profile
    PaneConnect[I] := Trim(ConnectCmd[I]);
    if Win[I] = nil then
      Started := False;
  end;
  if not Started then
  begin
    StopRuntime;
    if Lay <> nil then
      Lay.Free;
    Lay := TLayout.Create;
    StartPane(0, GetEnvironmentVariable('HOME'), '');
    Lay.Focused := 0;
    MessageBox(UiText('The wizard could not start a pane.',
      'No se pudo iniciar un panel del asistente.'), nil,
      mfError or mfOKButton);
  end
  else
  begin
    Lay.Focused := 0;
    RelayoutAll;
    RepaintChanges;
    FocusPane(Lay.Focused);
    PromoteToServer;   // the wizard session is also born with a server
  end;
  DeferPaneSpawn := OldDefer;
  RebuildMenu;
end;

procedure TSuperApp.ShowHelp;
var
  R: Objects.TRect;
  D: PDialog;
  Lines: array[0..7] of string;
  I: integer;
begin
  // standard dialog: dialog palette with proper contrast (the old
  // THelpDialog painted with GetColor(1), the passive frame color)
  Lines[0] := UiText(
    'F2/F3 split panes; F6/F7 next/prev pane; Alt-1..9 go to pane N',
    'F2/F3 dividen paneles; F6/F7 panel sig./ant.; Alt-1..9 ir al panel N');
  Lines[1] := UiText(
    PrefixKeyLabel(Cfg.PrefixKey) +
    ' f fullscreen; Alt-F9 min; Ctrl-F5 move/resize; Alt-F3 close',
    PrefixKeyLabel(Cfg.PrefixKey) +
    ' f pantalla; Alt-F9 min.; Ctrl-F5 mover/tamano; Alt-F3 cierra');
  Lines[2] := UiText(
    'F8/F9 next/prev window; ' + PrefixKeyLabel(Cfg.PrefixKey) +
    ' 1..9 go to window N',
    'F8/F9 ventana sig./ant.; ' + PrefixKeyLabel(Cfg.PrefixKey) +
    ' 1..9 ir a la ventana N');
  Lines[3] := UiText(
    PrefixKeyLabel(Cfg.PrefixKey) + ' c open a class in a new pane; ' +
    PrefixKeyLabel(Cfg.PrefixKey) + ' arrows resize the pane',
    PrefixKeyLabel(Cfg.PrefixKey) + ' c abre una clase en panel nuevo; ' +
    PrefixKeyLabel(Cfg.PrefixKey) + ' flechas dan tamano');
  if RemoteMode then
    Lines[4] := UiText(
      PrefixKeyLabel(Cfg.PrefixKey) +
      ' d detach; --attach returns exactly where you left it',
      PrefixKeyLabel(Cfg.PrefixKey) +
      ' d separa; --attach vuelve exactamente a como estaba')
  else
    Lines[4] := UiText(
      PrefixKeyLabel(Cfg.PrefixKey) +
      ' d detach; superterm --attach returns; Ctrl-S save',
      PrefixKeyLabel(Cfg.PrefixKey) +
      ' d separa; superterm --attach vuelve; Ctrl-S guarda');
  Lines[5] := UiText(
    PrefixKeyLabel(Cfg.PrefixKey) + ' [ copy; ' +
    PrefixKeyLabel(Cfg.PrefixKey) + ' ] paste; ' +
    PrefixKeyLabel(Cfg.PrefixKey) + ' h clipboard history',
    PrefixKeyLabel(Cfg.PrefixKey) + ' [ copia; ' +
    PrefixKeyLabel(Cfg.PrefixKey) + ' ] pega; ' +
    PrefixKeyLabel(Cfg.PrefixKey) + ' h historial portapapeles');
  Lines[6] := UiText(
    'Profiles menu saves and restores named workspaces',
    'El menu Perfiles guarda y restaura areas de trabajo con nombre');
  Lines[7] := UiText(
    'Alt-X exits; the last viewer closes the live session',
    'Alt-X sale; el ultimo cliente cierra la sesion viva');
  R.Assign(0, 0, 74, 14);
  D := New(PDialog, Init(R, UiText('Help and shortcuts', 'Ayuda y atajos')));
  D^.Options := D^.Options or ofCentered;
  for I := 0 to High(Lines) do
  begin
    R.Assign(3, 2 + I, 71, 3 + I);
    D^.Insert(New(PStaticText, Init(R, Lines[I])));
  end;
  D^.NewButton(31, 11, 12, 2, UiText('~O~K', '~A~ceptar'), cmOK,
    hcNoContext, bfDefault);
  Desktop^.ExecView(D);
  Dispose(D, Done);
end;

procedure TSuperApp.ShowAbout;
var
  R: Objects.TRect;
  D: PDialog;
begin
  R.Assign(0, 0, 54, 17);
  D := New(PDialog, Init(R, UiText('About', 'Acerca de')));
  D^.Options := D^.Options or ofCentered;
  R.Assign(2, 2, 52, 3);
  D^.Insert(New(PStaticText, Init(R,
    #3'superterm ' + SUPERTERM_VERSION)));
  R.Assign(2, 3, 52, 4);
  D^.Insert(New(PStaticText, Init(R,
    #3 + UiText('The productive terminal manager',
      'El gestor de terminales productivo'))));
  R.Assign(2, 5, 52, 6);
  D^.Insert(New(PStaticText, Init(R,
    #3'Germ'#160'n Luis Aracil Boned')));
  R.Assign(2, 6, 52, 7);
  D^.Insert(New(PStaticText, Init(R,
    #3 + UiText('August 2026 - License: GNU GPL v3',
      'Agosto 2026 - Licencia: GNU GPL v3'))));
  R.Assign(2, 8, 52, 11);
  D^.Insert(New(PStaticText, Init(R,
    #3 + UiText('Dedicated to Richard Stallman and his GNU',
      'Dedicado a Richard Stallman y a su proyecto') + #13 +
    #3 + UiText('project, with thanks for his drive to make',
      'GNU, con las gracias por su af'#160'n en conseguir') + #13 +
    #3 + UiText('software free for everyone.',
      'un software libre para todos.'))));
  R.Assign(2, 12, 52, 13);
  D^.Insert(New(PStaticText, Init(R,
    #3'https://www.gnu.org')));
  D^.NewButton(21, 14, 12, 2, UiText('~O~K', '~A~ceptar'), cmOK,
    hcNoContext, bfDefault);
  Desktop^.ExecView(D);
  Dispose(D, Done);
end;

// renames the focused window's title; it stays fixed (TitleFixed) so
// the periodic refresh cannot overwrite it; persists in session/profile
procedure TSuperApp.RenameFocusedWindow;
var
  i: integer;
  Buf: ShortString;
  Cur: string;
begin
  i := Lay.Focused;
  if (i < 0) or (i >= MAX_PANES) or (Win[i] = nil) then
    Exit;
  Cur := '';
  if Win[i]^.Title <> nil then
    Cur := Trim(Win[i]^.Title^);
  Buf := Copy(Cur, 1, 40);
  if InputBox(UiText('Rename window', 'Renombrar ventana'),
    UiText('Window title:', 'Titulo de la ventana:'), Buf, 40) <> cmOK then
    Exit;
  Cur := Trim(Buf);
  if Cur = '' then
    Cur := UiText('shell', 'shell');
  // The daemon must grant ownership before the actor changes its own title;
  // otherwise a denied concurrent rename visibly diverges until a snapshot.
  if RemoteMode and (Remote <> nil) and Remote.Connected then
    if not Remote.SendRename(i, Cur) then
      Exit;
  Win[i]^.SetTitle(' ' + Cur);
  Win[i]^.TitleFixed := True;
end;

procedure TSuperApp.RebuildMenu;
begin
  if MenuBar <> nil then
  begin
    Dispose(MenuBar, Done);
    MenuBar := nil;
  end;
  InitMenuBar;
  if MenuBar <> nil then
    Insert(MenuBar);
end;

procedure TSuperApp.RebuildStatusLine;
begin
  if StatusLine <> nil then
  begin
    Dispose(StatusLine, Done);
    StatusLine := nil;
  end;
  InitStatusLine;
  if StatusLine <> nil then
    Insert(StatusLine);
end;

function TSuperApp.RememberProfileSelection: boolean;
var
  ProfileName, WindowName: string;
begin
  Result := False;
  if (ActiveProfile < 0) or (ActiveProfile >= Length(Profiles)) or
     (ActiveWindow < 0) or
     (ActiveWindow >= Length(Profiles[ActiveProfile].Windows)) then
    Exit;
  ProfileName := Profiles[ActiveProfile].Name;
  WindowName := Profiles[ActiveProfile].Windows[ActiveWindow].Name;
  // Compare and update under the shared INI lock. Cfg may be older than a
  // default selected by another client and is never authority for this pair.
  Result := SaveDefaultWindowIfProfile(ProfileName, WindowName);
  if Result then
  begin
    Cfg.DefaultProfile := ProfileName;
    Cfg.DefaultWindow := WindowName;
  end;
end;

procedure TSuperApp.DoSwitchProfile(AIndex: integer);
var
  W, OldP, OldW: integer;
begin
  if (AIndex < 0) or (AIndex >= Length(Profiles)) or
     (not Profiles[AIndex].Enabled) then
    Exit;
  OldP := ActiveProfile;
  OldW := ActiveWindow;
  W := ProfileStartWindow(AIndex, False);
  if ((Length(Profiles[AIndex].Windows) > 0) and (W < 0)) or
     not ActivateProfile(AIndex, W) then
  begin
    if OldP >= 0 then
      ActivateProfile(OldP, OldW);
    MessageBox(UiText('The profile could not be started.',
      'No se pudo iniciar el perfil.'), nil,
      mfError or mfOKButton);
  end
  else
    ProfileMode := True;
end;

procedure TSuperApp.DoSwitchWindow(AIndex: integer);
var
  OldWindow: integer;
begin
  if (ActiveProfile < 0) or (ActiveProfile >= Length(Profiles)) then
    Exit;
  if (AIndex < 0) or
     (AIndex >= Length(Profiles[ActiveProfile].Windows)) or
     (not Profiles[ActiveProfile].Windows[AIndex].Enabled) then
    Exit;
  OldWindow := ActiveWindow;
  if not ActivateProfile(ActiveProfile, AIndex) then
  begin
    if OldWindow >= 0 then
      ActivateProfile(ActiveProfile, OldWindow);
    MessageBox(UiText('The window could not be started.',
      'No se pudo iniciar la ventana'), nil,
      mfError or mfOKButton);
  end;
end;

procedure TSuperApp.DoCycleWindow(ADelta: integer);
var
  N, Step, Candidate: integer;
begin
  if (ActiveProfile < 0) or (ActiveProfile >= Length(Profiles)) then
    Exit;
  N := Length(Profiles[ActiveProfile].Windows);
  if N = 0 then
    Exit;
  Candidate := ActiveWindow;
  for Step := 1 to N do
  begin
    Candidate := (Candidate + ADelta) mod N;
    if Candidate < 0 then
      Inc(Candidate, N);
    if Profiles[ActiveProfile].Windows[Candidate].Enabled then
    begin
      DoSwitchWindow(Candidate);
      Exit;
    end;
  end;
end;

procedure TSuperApp.DoClosePane(i: integer);
var
  j, OldFocused: integer;
begin
  if (i < 0) or (i >= MAX_PANES) or (Win[i] = nil) then
    Exit;
  // Closing the last window used to end the program. It leaves an empty
  // desktop instead: the menu, the status line and the picture stay, and
  // Classes or Panes > Split open a pane again. Leaving is what Alt-X and
  // Panes > Exit are for, said on purpose.
  OldFocused := Lay.Focused;
  // in remote mode the pane lives in the daemon: kill it there and
  // compact mirroring it (same indexes); locally KillPane does the job
  if RemoteMode and (Remote <> nil) and Remote.Connected then
    if not Remote.SendKillPane(i) then
      Exit;
  Lay.ClosePane(i);
  KillPane(i);
  for j := i to MAX_PANES - 2 do
  begin
    Panes[j] := Panes[j + 1];
    Scr[j] := Scr[j + 1];
    Win[j] := Win[j + 1];
    PaneTerm[j] := PaneTerm[j + 1];
    PaneConnect[j] := PaneConnect[j + 1];
    if Win[j] <> nil then
    begin
      Win[j]^.SetPaneIdx(j);
    end;
  end;
  Panes[MAX_PANES - 1] := nil;
  Scr[MAX_PANES - 1] := nil;
  Win[MAX_PANES - 1] := nil;
  PaneTerm[MAX_PANES - 1] := -1;
  PaneConnect[MAX_PANES - 1] := '';
  // The local resize cache and zero-only crop offsets use the same pane
  // indexes as the arrays above. The server excludes the requester from the
  // kill event, so this local close must invalidate them itself.
  ResetSizeRequests;
  if OldFocused > i then
    Lay.Focused := OldFocused - 1
  else
    Lay.Focused := OldFocused;
  if Lay.Focused >= PaneCount then
    Lay.Focused := PaneCount - 1;
  if (Lay.Focused < 0) or (Lay.Focused >= MAX_PANES) or
     (Win[Lay.Focused] = nil) then
    Lay.Focused := FirstVisiblePane;
  // do NOT re-tile: remaining windows keep their size and position.
  // KillPane already removed the closed one from the desktop; repaint.
  RepaintChanges;
  FocusPane(Lay.Focused);
  // The daemon already changed and broadcast the authoritative tree. The
  // requester mirrors it locally because KILLPANE_EV excludes the actor.
end;

procedure TSuperApp.DoCloseAllPanes;
var
  I: integer;
  SavedSuppress: boolean;
begin
  if PaneCount = 0 then
    Exit;
  if RemoteMode and (Remote <> nil) and Remote.Connected then
  begin
    // Pane=-1 means one daemon-authoritative structural transaction. The
    // actor does not pre-delete anything; descending KILLPANE_EV frames bring
    // every client, including this one, to the same empty desktop.
    Remote.SendKillPane(-1);
    Exit;
  end;
  if PassthroughActive then
    ExitPassthrough;
  SavedSuppress := SuppressFlush;
  SuppressFlush := True;
  try
    // Descending order never shifts a surviving slot. Reuse the exact mirror
    // deletion path employed by remote events, but publish only the settled
    // empty desktop after the complete batch.
    for I := PaneCount - 1 downto 0 do
      ApplyRemoteKillPane(I);
    ResetSizeRequests;
    RebuildMenu;
  finally
    SuppressFlush := SavedSuppress;
  end;
  if not SavedSuppress then
    RepaintChanges;
end;

// current geometry of all windows (same rules as the local save: a
// maximized one contributes its ZoomRect, a minimized one its bounds)
procedure TSuperApp.CollectPaneGeom(out AGeom: TPaneGeomArray;
  out ADeskW, ADeskH: integer);
var
  n, i: integer;
  WR, RD: Objects.TRect;
  CanonicalBase: boolean;
  FullDeskW, FullDeskH, FullCols, FullRows: integer;
  MaxDeskW, MaxDeskH, MaxCols, MaxRows: integer;
begin
  AGeom := Default(TPaneGeomArray);
  ADeskW := 0;
  ADeskH := 0;
  n := Lay.PaneCount;
  if Desktop = nil then
    Exit;
  CanonicalBase := RemoteMode and (Length(RemoteGeom) = n) and
    (RemoteDeskW > 0) and (RemoteDeskH > 0);
  if CanonicalBase then
  begin
    AGeom := Copy(RemoteGeom, 0, Length(RemoteGeom));
    ADeskW := RemoteDeskW;
    ADeskH := RemoteDeskH;
    if not RemoteGeometryDirty then
      Exit;
  end;
  RD := Default(Objects.TRect);
  Desktop^.GetExtent(RD);
  if RemoteMode and (RemoteDeskW > 0) and (RemoteDeskH > 0) then
  begin
    ADeskW := RemoteDeskW;
    ADeskH := RemoteDeskH;
  end
  else
  begin
    ADeskW := RD.B.X - RD.A.X;
    ADeskH := RD.B.Y - RD.A.Y;
  end;
  // An empty session still owns one canonical desktop geometry.  Its first
  // later pane uses these dimensions and every attaching client sees the
  // same workspace rather than replacing it with its own terminal size.
  if n < 1 then
    Exit;
  if not CanonicalBase then
    SetLength(AGeom, n);
  for i := 0 to n - 1 do
    if (i < MAX_PANES) and (Win[i] <> nil) and
       ((not CanonicalBase) or RemoteGeomDirtyPanes[i]) then
    begin
      if Win[i]^.Zoomed then
        WR := Win[i]^.ZoomRect
      else if Win[i]^.Minimized then
        WR := Win[i]^.SavedRect
      else
      begin
        WR := Default(Objects.TRect);
        Win[i]^.GetBounds(WR);
      end;
      AGeom[i].BX := WR.A.X;
      AGeom[i].BY := WR.A.Y;
      AGeom[i].BW := WR.B.X - WR.A.X;
      AGeom[i].BH := WR.B.Y - WR.A.Y;
      AGeom[i].Zoomed := Win[i]^.Zoomed;
      AGeom[i].Minimized := Win[i]^.Minimized;
      if Win[i]^.Minimized then
        AGeom[i].IconSlot := Win[i]^.IconSlot
      else
        AGeom[i].IconSlot := -1;
      AGeom[i].FullScreen := Win[i]^.FullScreen;
      if Win[i]^.Minimized and (Scr[i] <> nil) then
      begin
        AGeom[i].Cols := Scr[i].Width;
        AGeom[i].Rows := Scr[i].Height;
      end
      else if Win[i]^.FullScreen then
      begin
        if RemoteMode then
        begin
          SharedFullScreenSize(FullDeskW, FullDeskH, FullCols, FullRows);
          AGeom[i].Cols := FullCols;
          AGeom[i].Rows := FullRows;
        end
        else
        begin
          AGeom[i].Cols := ADeskW;
          AGeom[i].Rows := ADeskH + 2;
        end;
      end
      else if Win[i]^.Zoomed then
      begin
        // Preserve an existing canonical maximum during unrelated local
        // bookkeeping.  Only a new zoom or host-resize proposal derives a
        // fresh maximum from the current host summary.
        if CanonicalBase and RemoteGeom[i].Zoomed then
        begin
          AGeom[i].Cols := RemoteGeom[i].Cols;
          AGeom[i].Rows := RemoteGeom[i].Rows;
        end
        else
        begin
          SharedMaximizedSize(ADeskW, ADeskH, MaxDeskW, MaxDeskH,
            MaxCols, MaxRows);
          AGeom[i].Cols := MaxCols;
          AGeom[i].Rows := MaxRows;
        end;
      end
      else
      begin
        AGeom[i].Cols := AGeom[i].BW - 2;
        AGeom[i].Rows := AGeom[i].BH - 2;
      end;
      if AGeom[i].Cols < 4 then AGeom[i].Cols := 4;
      if AGeom[i].Rows < 2 then AGeom[i].Rows := 2;
    end;
end;

// while attached, pushes the client state to the daemon so the next
// attach restores exactly what is on screen now
procedure TSuperApp.SyncRemoteLayout(APrelockedPane: integer);
var
  Geom: TPaneGeomArray;
  Titles: TStrArray;
  DeskW, DeskH: integer;
  n, i, LockPane, ChangedPane: integer;
  ChangeMask: LongWord;
  Locked, Sent: boolean;
begin
  if (not RemoteMode) or (Remote = nil) or (not Remote.Connected) then
    Exit;
  n := Lay.PaneCount;
  if n < 1 then
  begin
    if APrelockedPane <> -2 then
      Remote.UnlockLayout(-1);
    Exit;
  end;
  CollectPaneGeom(Geom, DeskW, DeskH);
  if Length(Geom) <> n then
  begin
    if APrelockedPane <> -2 then
      Remote.UnlockLayout(-1);
    Exit;
  end;
  Titles := Default(TStrArray);
  SetLength(Titles, n);
  for i := 0 to n - 1 do
    if (i < MAX_PANES) and (Win[i] <> nil) then
      Titles[i] := Win[i]^.GetTitle(80);
  ChangeMask := 0;
  for i := 0 to n - 1 do
    if RemoteGeomDirtyPanes[i] then
      ChangeMask := ChangeMask or (LongWord(1) shl i);
  if RemoteTreeDirty then
    ChangeMask := ChangeMask or LAYOUT_CHANGE_TREE;
  LockPane := -1;
  ChangedPane := -1;
  if (ChangeMask and LAYOUT_CHANGE_TREE) = 0 then
    for i := 0 to n - 1 do
      if (ChangeMask and (LongWord(1) shl i)) <> 0 then
        if ChangedPane = -1 then
          ChangedPane := i
        else if ChangedPane >= 0 then
          ChangedPane := -2;
  if ChangedPane >= 0 then
    LockPane := ChangedPane;
  // LOCK and the final proposal are ordered on the same non-blocking socket.
  // FRAME_LAYOUT is a commit: the daemon applies/rejects it, releases every
  // pane owned by this client, then emits exactly one canonical snapshot.
  // Sending a separate successful UNLOCK here used to insert an old snapshot
  // between the user's click and that commit (the visible minimize/zoom
  // flash).  UNLOCK is now only cancellation if the proposal cannot be sent.
  if APrelockedPane = -2 then
    Locked := LockRemoteLayout(LockPane)
  else
  begin
    // A pane lease covers only that pane. A tree/multi-pane proposal needs
    // the global lease, while a global lease safely covers one pane too.
    Locked := (APrelockedPane = -1) or
      ((LockPane >= 0) and (APrelockedPane = LockPane));
    if not Locked then
      Remote.UnlockLayout(-1);
  end;
  if not Locked then
    Exit;
  Sent := Remote.SendLayout(SaveLayoutString(Lay), Lay.Focused, Titles, Geom,
    DeskW, DeskH, ChangeMask);
  if not Sent then
  begin
    // A global cancellation releases whichever pane this client prelocked;
    // it is also safe for a lock acquired internally above.
    Remote.UnlockLayout(-1);
    Exit;
  end;
  RemoteGeom := Copy(Geom, 0, Length(Geom));
  RemoteDeskW := DeskW;
  RemoteDeskH := DeskH;
  RemoteGeometryDirty := False;
  RemoteTreeDirty := False;
  for I := 0 to MAX_PANES - 1 do
    RemoteGeomDirtyPanes[I] := False;
  RemoteLayoutHash := ComputeLayoutHash;
end;

// give a pane the WHOLE host terminal and start writing its raw PTY bytes
// straight through; the SIGWINCH from the resize makes the app repaint at
// full fidelity (truecolor, emoji, wide glyphs) with no CP437 grid in the
// way. Only valid while the pane is maximized and owns the screen alone.
procedure TSuperApp.EnterPassthrough(i: integer);
begin
  if PassthroughActive or (i < 0) or (i >= MAX_PANES) or (Win[i] = nil) then
    Exit;
  if DebugActive then DebugLog(Format('pass: ENTER pane=%d full=%dx%d', [i, ScreenWidth, ScreenHeight]));
  PassPane := i;
  PassReqW := ScreenWidth;
  PassReqH := ScreenHeight;
  PassFilterState := pfsGround;
  PassFilterBuf := '';
  PassFilterLen := 0;
  PassthroughActive := True;   // silences all FreeVision screen writes
  // hand a clean surface to the app: show cursor, reset attrs, clear.
  // Also RELEASE the mouse: turn superterm's own tracking off so, in
  // fullscreen, a drag selects text normally and clicks are NOT reported to
  // FreeVision (a click on the hidden-but-logical menu row would otherwise pop
  // the menu and drop out of zoom). The app (Claude) re-asserts whatever mouse
  // modes it wants through its raw output; ExitPassthrough re-enables ours.
  WriteRaw(#27'[?25h'#27'[0m'#27'[2J'#27'[H' +
    #27'[?1000l'#27'[?1002l'#27'[?1003l'#27'[?1006l');
  // that line turned any-motion reporting off at the terminal, so say so:
  // SyncHostMouse only writes when its idea of the mode changes, and leaving
  // it believing ?1003 was still on meant a pane that had asked for
  // every-motion tracking never got it back after a maximise and restore --
  // silently, because both sides thought it was already there.
  HostAnyMotion := False;
  // In remote mode the daemon already applied the canonical fullscreen size
  // before broadcasting this state. Never substitute the host geometry.
  if not RemoteMode then
  begin
    if Scr[i] <> nil then
      Scr[i].Resize(ScreenWidth, ScreenHeight);
    if Panes[i] <> nil then
      Panes[i].Resize(ScreenWidth, ScreenHeight);
  end;
end;

// reclaim the terminal for the window manager: reset the modes the app may
// have set, restore the pane's windowed size, and force one clean full
// repaint so menus, status line and window frames come back.
// Cosmetic zoom transition: a handful of outline frames interpolating between
// the window's rectangle and the full desktop. It reuses the wireframe-drag
// primitives, so each frame costs only its ring. Opt-in (Options > zoom
// transition); fullscreen stays instant by default.
procedure TSuperApp.ZoomAnimate(AWindow: PTermWindow;
  AX1, AY1, AX2, AY2, BX1, BY1, BX2, BY2: integer);
const
  STEPS = 8;
  FRAME_MS = 45;
var
  k, x1, y1, x2, y2, P: integer;
  FrameAttr: byte;
  SharePreview: boolean;

  procedure SendOutlineStep(AOp: byte);
  begin
    if not SharePreview then
      Exit;
    Inc(RemoteZoomPreviewSeq);
    if not Remote.SendLayoutPreview(P, RemoteZoomPreviewId,
      Remote.LayoutRevision, RemoteZoomPreviewSeq, AOp,
      x1 - Desktop^.Origin.X, y1 - Desktop^.Origin.Y,
      x2 - x1 + 1, y2 - y1 + 1) then
    begin
      // Cosmetic relay failure must never leave the local renderer dirty or
      // prevent the reliable canonical layout from being proposed. Stop
      // adding preview frames; the daemon's lease cleanup supplies CLEAR.
      SharePreview := False;
      if DebugActive then
        DebugLog(Format('remote-zoom: preview send failed pane=%d op=%d',
          [P, AOp]));
    end;
  end;
begin
  if PassthroughActive or (Desktop = nil) then
    Exit;
  P := 0;
  if AWindow <> nil then
  begin
    FrameAttr := AWindow^.ActiveFrameAttr;
    P := AWindow^.PaneIdx;
  end
  else
    FrameAttr := $07;
  SharePreview := RemoteMode and (Remote <> nil) and Remote.Connected and
    (RemoteZoomPreviewId <> 0) and (AWindow <> nil) and
    (P >= 0) and (P < MAX_PANES);
  for k := 1 to STEPS do
  begin
    x1 := AX1 + ((BX1 - AX1) * k) div STEPS;
    y1 := AY1 + ((BY1 - AY1) * k) div STEPS;
    x2 := AX2 + ((BX2 - AX2) * k) div STEPS;
    y2 := AY2 + ((BY2 - AY2) * k) div STEPS;
    TransientOutlineSet(P, x1, y1, x2, y2, FrameAttr);
    SendOutlineStep(PREVIEW_OP_OUTLINE_SHOW);
    UpdateScreen(False);
    Sleep(FRAME_MS);
    TransientOutlineClear(P);
    SendOutlineStep(PREVIEW_OP_OUTLINE_HIDE);
    UpdateScreen(False);
  end;
end;

procedure TSuperApp.ExitPassthrough;
var
  P, pw, ph: integer;
begin
  if not PassthroughActive then
    Exit;
  if DebugActive then DebugLog('pass: EXIT (reclaim screen, full repaint)');
  P := PassPane;                // remember which pane owned the screen
  PassthroughActive := False;   // must precede any repaint
  PassPane := -1;
  PassReqW := 0;
  PassReqH := 0;
  PassFilterState := pfsGround;
  PassFilterBuf := '';
  PassFilterLen := 0;
  // undo modes a full-screen app commonly leaves set, and make sure we are
  // on superterm's (alternate) screen with sane defaults before repainting.
  // The mouse must be RE-ENABLED, not disabled: FreeVision turned it on once
  // at startup (vendor/fv322/drivers.pas, ?1000/1002/1003/1006h) and guards
  // that with a sticky TmuxMouseEnabled flag, so it never re-emits the enable.
  // The maximized app left its own tracking modes set (or cleared); if we exit
  // with the mouse OFF, FreeVision still thinks it is ON and the pointer goes
  // dead -- no clicks reach the menu, status line or frames. Re-assert exactly
  // FreeVision's enable set so reporting is live again for the window manager.
  // The terminal draws an I-beam pointer while mouse tracking is off (and a
  // full-screen app may also have pinned the pointer shape via OSC 22); the
  // mouse re-enable above brings the arrow back, and OSC 22 with the default
  // shape undoes any explicit override. Terminals without OSC 22 ignore it.
  // Only re-assert tracking when FreeVision actually has a mouse. Where the
  // RTL did not recognise the terminal, ButtonCount is 0, Mouse.InitMouse was
  // never called and the RTL's event queue is a pair of nil pointers: asking
  // for reports there is asking for a SIGSEGV on the first one.
  if ButtonCount <> 0 then
    WriteRaw(#27'[?1049h'#27'[0m'#27'[?7l'#27'[?25h' +
      #27']22;default'#27'\');
  // and re-assert exactly what the mouse driver wants. The pane that owned
  // the screen wrote straight to the host terminal while it did, and a pane
  // running its own superterm resets every mouse mode when it exits -- which
  // left this terminal reporting nothing at all, with no way to notice.
  if ButtonCount <> 0 then
    HostMouseOn;
  HostPasteOn;
  // HostMouseOn restores normal and button tracking; any-motion belongs to
  // whatever the focused pane asks for, so let the one place that knows decide
  SyncHostMouse;
  // Resize ONLY the pane that owned the screen, to the bounds its window
  // already has. Leaving fullscreen restored those bounds itself, but the
  // ChangeBounds guard suppressed the PTY resize while passthrough was active,
  // so the PTY is still full-screen and must be synced here. Do NOT call
  // RelayoutAll: that re-tiles every window and overwrites the size the user's
  // window had (an 80x20 pane came back filling the whole screen).
  if (not RemoteMode) and
     (P >= 0) and (P < MAX_PANES) and (Win[P] <> nil) and
     (not Win[P]^.Minimized) and (Scr[P] <> nil) then
  begin
    pw := Win[P]^.Size.X - 2;
    ph := Win[P]^.Size.Y - 2;
    if pw < 4 then pw := 4;
    if ph < 2 then ph := 2;
    if (pw <> Scr[P].Width) or (ph <> Scr[P].Height) then
    begin
      Scr[P].Resize(pw, ph);
      if Panes[P] <> nil then
        Panes[P].Resize(pw, ph);
    end;
  end;
  ResetVideoSurface;   // invalidate both buffers; never blank mid-transaction
  ReDraw;              // full repaint of menu, desktop, windows and status
  if (Lay.Focused >= 0) and (Lay.Focused < MAX_PANES) then
    FocusPane(Lay.Focused);
end;

procedure TSuperApp.SharedFullScreenSize(out ADeskW, ADeskH, ACols,
  ARows: integer);
begin
  ADeskW := RemoteDeskW;
  ADeskH := RemoteDeskH;
  ACols := RemoteDeskW;
  ARows := RemoteDeskH + 2;
  if ADeskW < 1 then ADeskW := 1;
  if ADeskH < 1 then ADeskH := 1;
  if ACols < 4 then ACols := 4;
  if ARows < 2 then ARows := 2;
end;

// A normal maximized window keeps the IDE menu/status and its own frame. Its
// one shared maximum always derives from the canonical desktop, independent
// of physical viewers; a smaller viewer scrolls or clips its local viewport.
// Fullscreen uses the same canonical desktop without the 2x2 window frame.
procedure TSuperApp.SharedMaximizedSize(ACanonicalDeskW,
  ACanonicalDeskH: integer; out ADeskW, ADeskH, ACols, ARows: integer);
begin
  ADeskW := ACanonicalDeskW;
  ADeskH := ACanonicalDeskH;
  // Match TWindow.SizeLimits/FreeVision's MinWinSize exactly. Otherwise the
  // daemon could install a 4-column PTY while Locate silently paints a
  // 16-column frame on a malformed/tiny host.
  if ADeskW < MIN_WIN_W then ADeskW := MIN_WIN_W;
  if ADeskH < MIN_WIN_H then ADeskH := MIN_WIN_H;
  ACols := ADeskW - 2;
  ARows := ADeskH - 2;
end;

procedure TSuperApp.ResetRemotePreviewState;
var
  I: integer;
begin
  TransientOutlineClearAll;
  for I := 0 to MAX_PANES - 1 do
  begin
    RemotePreviewMode[I] := 0;
    RemotePreviewGesture[I] := 0;
    RemotePreviewRect[I] := Default(Objects.TRect);
    RemotePreviewOverlayOn[I] := False;
    RemotePreviewOverlayGesture[I] := 0;
    RemotePreviewOverlayRect[I] := Default(Objects.TRect);
    RemotePreviewOverlayAttr[I] := 0;
    RemotePreviewTailGesture[I] := 0;
    RemotePreviewTailBase[I] := 0;
    RemotePreviewClearPending[I] := False;
  end;
end;

procedure TSuperApp.ShowRemotePreviewWindow(APane: integer);
var
  SavedCurrent: PView;
begin
  if (APane < 0) or (APane >= MAX_PANES) or (Win[APane] = nil) or
     Win[APane]^.GetState(sfVisible) then
    Exit;
  if Desktop = nil then
  begin
    Win[APane]^.Show;
    Exit;
  end;
  SavedCurrent := Desktop^.Current;
  Desktop^.Lock;
  try
    Win[APane]^.Show;
    // TView.SetState(sfVisible) calls TGroup.ResetCurrent. Cosmetic
    // wireframe cleanup must not steal a newer shared focus from another
    // client, so restore the precise current view inside the same transaction.
    if (SavedCurrent <> nil) and (Desktop^.Current <> SavedCurrent) then
    begin
      if Desktop^.Current <> nil then
      begin
        Desktop^.Current^.SetState(sfFocused, False);
        Desktop^.Current^.SetState(sfSelected, False);
      end;
      SavedCurrent^.SetState(sfSelected, True);
      if (Desktop^.State and sfFocused) <> 0 then
        SavedCurrent^.SetState(sfFocused, True);
      Desktop^.Current := SavedCurrent;
    end;
  finally
    Desktop^.Unlock;
  end;
end;

procedure TSuperApp.ClearRemotePreview(APane: integer;
  ARestoreWindow: boolean);
var
  R: Objects.TRect;
begin
  if (APane < 0) or (APane >= MAX_PANES) then
    Exit;
  TransientOutlineClear(APane);
  RemotePreviewOverlayOn[APane] := False;
  RemotePreviewOverlayGesture[APane] := 0;
  RemotePreviewOverlayRect[APane] := Default(Objects.TRect);
  RemotePreviewOverlayAttr[APane] := 0;
  if (Win[APane] <> nil) and (RemotePreviewMode[APane] = 2) and
     (not Win[APane]^.GetState(sfVisible)) then
    ShowRemotePreviewWindow(APane);
  if ARestoreWindow and (Win[APane] <> nil) and
     (APane < Length(RemoteGeom)) and (not RemoteGeom[APane].Minimized) and
     (not RemoteGeom[APane].Zoomed) and (RemoteGeom[APane].BW > 0) and
     (RemoteGeom[APane].BH > 0) then
  begin
    R.Assign(RemoteGeom[APane].BX, RemoteGeom[APane].BY,
      RemoteGeom[APane].BX + RemoteGeom[APane].BW,
      RemoteGeom[APane].BY + RemoteGeom[APane].BH);
    Win[APane]^.Locate(R);
  end;
  RemotePreviewMode[APane] := 0;
  RemotePreviewGesture[APane] := 0;
  RemotePreviewRect[APane] := Default(Objects.TRect);
  RemotePreviewTailGesture[APane] := 0;
  RemotePreviewTailBase[APane] := 0;
  RemotePreviewClearPending[APane] := False;
end;

// A successful daemon lease is the ordering barrier between an old remote
// gesture and a new local action. Some of the old preview may already have
// been rendered while its CLEAR/canonical pair is still queued. Restore the
// daemon's canonical mirror before the new owner reads bounds or SavedRect;
// the transport discards the matching queued cosmetic frames after the grant.
procedure TSuperApp.SettleRemotePreviewsForOwnedAction(APane: integer);
var
  I, FirstPane, LastPane: integer;
  SavedSuppress, SavedSettling, HadPreview: boolean;
begin
  if APane < 0 then
  begin
    FirstPane := 0;
    LastPane := MAX_PANES - 1;
  end
  else
  begin
    if APane >= MAX_PANES then
      Exit;
    FirstPane := APane;
    LastPane := APane;
  end;
  SavedSuppress := SuppressFlush;
  SavedSettling := RemoteAttachSettling;
  SuppressFlush := True;
  RemoteAttachSettling := True;
  try
    for I := FirstPane to LastPane do
    begin
      HadPreview := (RemotePreviewMode[I] <> 0) or
        RemotePreviewOverlayOn[I] or RemotePreviewClearPending[I] or
        (RemotePreviewTailGesture[I] <> 0) or
        TransientOutlineActive(I);
      if HadPreview then
      begin
        if DebugFull then
          DebugLog(Format('preview-settle: owned action pane=%d lease=%d',
            [I, APane]));
        ClearRemotePreview(I, True);
      end;
    end;
  finally
    RemoteAttachSettling := SavedSettling;
    SuppressFlush := SavedSuppress;
  end;
end;

function TSuperApp.LockRemoteLayout(APane: integer): boolean;
begin
  Result := (Remote <> nil) and Remote.Connected and
    Remote.LockLayout(APane);
  if Result then
    SettleRemotePreviewsForOwnedAction(APane);
end;

function TSuperApp.ApplyRemoteLayoutPreviewEv(APane: integer;
  const AData: TByteArray; var AFullRedraw: boolean): boolean;
var
  Preview: TLayoutPreview;
  R: Objects.TRect;
  SavedSuppress, SavedSettling: boolean;
  FrameAttr: byte;
  SavedCurrent: PView;
begin
  Result := False;
  if (APane < 0) or (APane >= MAX_PANES) or (Win[APane] = nil) or
     (Desktop = nil) or
     (not DecodeLayoutPreviewBlob(AData, Preview)) then
    Exit;
  if DebugFull then
    DebugLog(Format('preview-event: pane=%d id=%d base=%d seq=%d ' +
      'op=%d rect=%d,%d %dx%d', [APane, Preview.GestureId,
      Preview.BaseRevision, Preview.Seq, Preview.Op, Preview.X, Preview.Y,
      Preview.W, Preview.H]));

  if Preview.Op = PREVIEW_OP_TAIL_BEGIN then
  begin
    RemotePreviewTailGesture[APane] := Preview.GestureId;
    RemotePreviewTailBase[APane] := Preview.BaseRevision;
    Exit;
  end;
  if Preview.Op = PREVIEW_OP_TAIL_END then
  begin
    if RemotePreviewTailGesture[APane] = Preview.GestureId then
    begin
      RemotePreviewTailGesture[APane] := 0;
      RemotePreviewTailBase[APane] := 0;
    end;
    Exit;
  end;
  if Preview.Op = PREVIEW_OP_CLEAR then
  begin
    if RemotePreviewTailGesture[APane] = Preview.GestureId then
    begin
      RemotePreviewTailGesture[APane] := 0;
      RemotePreviewTailBase[APane] := 0;
    end;
    if ((RemotePreviewMode[APane] <> 0) and
        (RemotePreviewGesture[APane] <> Preview.GestureId)) or
       (RemotePreviewOverlayOn[APane] and
        (RemotePreviewOverlayGesture[APane] <> Preview.GestureId)) then
      Exit;
    // Keep the last BOUNDS/ring physically intact. CLEAR is followed by the
    // authoritative LAYOUT/PEER event, but the 32-frame/20-ms Idle budget can
    // split those adjacent frames across ticks. Restoring RemoteGeom here
    // exposed the old rectangle for one frame at exactly that boundary.
    RemotePreviewClearPending[APane] := True;
    Exit;
  end;
  if (Preview.W <= 0) or (Preview.H <= 0) then
    Exit;
  R.Assign(Preview.X, Preview.Y, Preview.X + Preview.W,
    Preview.Y + Preview.H);

  case Preview.Op of
    PREVIEW_OP_BOUNDS, PREVIEW_OP_WIREFRAME:
      begin
        RemotePreviewClearPending[APane] := False;
        SavedSuppress := SuppressFlush;
        SavedSettling := RemoteAttachSettling;
        SuppressFlush := True;
        RemoteAttachSettling := True;
        try
          if (RemotePreviewGesture[APane] <> 0) and
             (RemotePreviewGesture[APane] <> Preview.GestureId) then
            ClearRemotePreview(APane, True);
          RemotePreviewGesture[APane] := Preview.GestureId;
          RemotePreviewRect[APane] := R;
          if Preview.Op = PREVIEW_OP_BOUNDS then
          begin
            if RemotePreviewOverlayOn[APane] then
            begin
              TransientOutlineClear(APane);
              RemotePreviewOverlayOn[APane] := False;
            end;
            if not Win[APane]^.GetState(sfVisible) then
              ShowRemotePreviewWindow(APane);
            Win[APane]^.Locate(R);
            RemotePreviewMode[APane] := 1;
          end
          else
          begin
            FrameAttr := Win[APane]^.ActiveFrameAttr;
            if Win[APane]^.GetState(sfVisible) then
            begin
              SavedCurrent := Desktop^.Current;
              Desktop^.Lock;
              try
                Win[APane]^.Hide;
                // Hide must not select an arbitrary uncovered pane. Preserve
                // exactly the shared focus which was current when this FIFO
                // preview arrived: it may be this hidden dragged pane, or a
                // different pane focused later by another client.
                if (SavedCurrent <> nil) and
                   (Desktop^.Current <> SavedCurrent) then
                begin
                  if Desktop^.Current <> nil then
                  begin
                    Desktop^.Current^.SetState(sfFocused, False);
                    Desktop^.Current^.SetState(sfSelected, False);
                  end;
                  SavedCurrent^.SetState(sfSelected, True);
                  if (Desktop^.State and sfFocused) <> 0 then
                    SavedCurrent^.SetState(sfFocused, True);
                  Desktop^.Current := SavedCurrent;
                end;
              finally
                Desktop^.Unlock;
              end;
            end;
            RemotePreviewMode[APane] := 2;
            RemotePreviewOverlayOn[APane] := True;
            RemotePreviewOverlayGesture[APane] := Preview.GestureId;
            RemotePreviewOverlayRect[APane] := R;
            RemotePreviewOverlayAttr[APane] := FrameAttr;
            TransientOutlineSet(APane, Desktop^.Origin.X + R.A.X,
              Desktop^.Origin.Y + R.A.Y, Desktop^.Origin.X + R.B.X - 1,
              Desktop^.Origin.Y + R.B.Y - 1, FrameAttr, True);
          end;
        finally
          RemoteAttachSettling := SavedSettling;
          SuppressFlush := SavedSuppress;
        end;
        if not SavedSuppress then
          // Locate/Hide/Show have already rebuilt the affected FreeVision
          // regions while flushing was suppressed. Publish that settled
          // buffer directly; redrawing all sixteen possible windows for
          // every 60 Hz pointer sample wastes CPU without changing a cell.
          UpdateScreen(False);
      end;
    PREVIEW_OP_OUTLINE_SHOW:
      begin
        if RemotePreviewTailGesture[APane] <> 0 then
        begin
          if (RemotePreviewTailGesture[APane] <> Preview.GestureId) or
             (Preview.BaseRevision <= RemotePreviewTailBase[APane]) then
            Exit;
          // Socket FIFO already put the authoritative LAYOUT_EV before this
          // first contraction ring. If both arrived in one drain batch, its
          // repaint is still deferred in AFullRedraw; publish it now so the
          // following UpdateScreen contains only the cosmetic ring.
          if AFullRedraw then
          begin
            RepaintChanges;
            AFullRedraw := False;
            Result := True;
          end;
          RemotePreviewTailGesture[APane] := 0;
          RemotePreviewTailBase[APane] := 0;
        end;
        RemotePreviewClearPending[APane] := False;
        FrameAttr := Win[APane]^.ActiveFrameAttr;
        RemotePreviewOverlayOn[APane] := True;
        RemotePreviewOverlayGesture[APane] := Preview.GestureId;
        RemotePreviewOverlayRect[APane] := R;
        RemotePreviewOverlayAttr[APane] := FrameAttr;
        TransientOutlineSet(APane, Desktop^.Origin.X + R.A.X,
          Desktop^.Origin.Y + R.A.Y, Desktop^.Origin.X + R.B.X - 1,
          Desktop^.Origin.Y + R.B.Y - 1, FrameAttr);
        UpdateScreen(False);
      end;
    PREVIEW_OP_OUTLINE_HIDE:
      if RemotePreviewOverlayGesture[APane] = Preview.GestureId then
      begin
        TransientOutlineClear(APane);
        RemotePreviewOverlayOn[APane] := False;
        RemotePreviewOverlayGesture[APane] := 0;
        UpdateScreen(False);
      end;
  end;
end;

procedure TSuperApp.PrepareRemotePreviewsForLayout(ALockedPanes: LongWord);
var
  I: integer;
begin
  for I := 0 to MAX_PANES - 1 do
  begin
    if RemotePreviewClearPending[I] then
    begin
      // The enclosing layout transaction already suppresses physical output.
      // Drop the held last preview now, without restoring the old RemoteGeom;
      // the canonical loop which follows places the real final/cancel bounds.
      ClearRemotePreview(I, False);
      RemotePreviewClearPending[I] := False;
      Continue;
    end;
    if RemotePreviewOverlayOn[I] then
      TransientOutlineClear(I);
    if (RemotePreviewMode[I] = 2) and (Win[I] <> nil) and
       (not Win[I]^.GetState(sfVisible)) then
      ShowRemotePreviewWindow(I);
    if (ALockedPanes and (LongWord(1) shl I)) = 0 then
    begin
      RemotePreviewMode[I] := 0;
      RemotePreviewGesture[I] := 0;
      RemotePreviewOverlayOn[I] := False;
      RemotePreviewOverlayGesture[I] := 0;
    end;
  end;
end;

procedure TSuperApp.ReapplyRemotePreviewsAfterLayout(
  ALockedPanes: LongWord);
var
  I: integer;
  R: Objects.TRect;
begin
  if Desktop = nil then
    Exit;
  for I := 0 to MAX_PANES - 1 do
    if ((ALockedPanes and (LongWord(1) shl I)) <> 0) and
       (Win[I] <> nil) then
    begin
      R := RemotePreviewRect[I];
      case RemotePreviewMode[I] of
        1:
          if (R.B.X > R.A.X) and (R.B.Y > R.A.Y) then
            Win[I]^.Locate(R);
        2:
          if (R.B.X > R.A.X) and (R.B.Y > R.A.Y) then
          begin
            if Win[I]^.GetState(sfVisible) then
              Win[I]^.Hide;
            RemotePreviewOverlayOn[I] := True;
            TransientOutlineSet(I, Desktop^.Origin.X + R.A.X,
              Desktop^.Origin.Y + R.A.Y, Desktop^.Origin.X + R.B.X - 1,
              Desktop^.Origin.Y + R.B.Y - 1,
              RemotePreviewOverlayAttr[I], True);
          end;
      end;
      if RemotePreviewOverlayOn[I] and (RemotePreviewMode[I] <> 2) then
      begin
        R := RemotePreviewOverlayRect[I];
        if (R.B.X > R.A.X) and (R.B.Y > R.A.Y) then
          TransientOutlineSet(I, Desktop^.Origin.X + R.A.X,
            Desktop^.Origin.Y + R.A.Y, Desktop^.Origin.X + R.B.X - 1,
            Desktop^.Origin.Y + R.B.Y - 1,
            RemotePreviewOverlayAttr[I]);
      end;
    end;
end;

procedure TSuperApp.ResetRemoteZoomState;
begin
  RemoteZoomPending := False;
  RemoteZoomPane := -1;
  RemoteZoomTarget := Default(TPaneGeom);
  RemoteZoomContractPending := False;
  RemoteZoomContractPane := -1;
  RemoteZoomOldX1 := 0;
  RemoteZoomOldY1 := 0;
  RemoteZoomOldX2 := 0;
  RemoteZoomOldY2 := 0;
  RemoteZoomBaseRevision := 0;
  RemoteZoomSentTick := 0;
  RemoteZoomPreviewId := 0;
  RemoteZoomPreviewSeq := 0;
end;

procedure TSuperApp.BeginRemoteZoom(ACommand: word; AInfoPtr: Pointer);
var
  Candidate: TPaneGeomArray;
  Titles: TStrArray;
  P, I, FullDeskW, FullDeskH, FullCols, FullRows: integer;
  MaxDeskW, MaxDeskH, MaxCols, MaxRows: integer;
  ChangeMask: LongWord;
  Target: TPaneGeom;
  WR: Objects.TRect;
  EntersZoom, LeavesZoom: boolean;
begin
  if (not RemoteMode) or (Remote = nil) or (not Remote.Connected) or
     RemoteZoomPending or (Lay = nil) or (Desktop = nil) or
     ((ACommand <> cmZoom) and (ACommand <> cmFullScreen)) then
    Exit;

  // A frame command names its window through InfoPtr. Menu/key commands use
  // nil and act on the shared focus. Never let a delayed mouse command zoom a
  // different window merely because another client changed focus meanwhile.
  P := -1;
  if AInfoPtr <> nil then
    for I := 0 to Lay.PaneCount - 1 do
      if Pointer(Win[I]) = AInfoPtr then
      begin
        P := I;
        Break;
      end;
  if P < 0 then
    P := Lay.Focused;
  if (P < 0) or (P >= Lay.PaneCount) or (P >= Length(RemoteGeom)) or
     (Win[P] = nil) or Win[P]^.Minimized then
    Exit;

  // LockLayout may have decoded a newer host-summary frame while waiting for
  // its reply. Use that transport metadata for this proposal even though the
  // normal Idle loop has not consumed the queued UI event yet.
  if Remote.HostSummaryValid then
  begin
    RemoteMinHostW := Remote.MinHostW;
    RemoteMinHostH := Remote.MinHostH;
    RemoteHostSizesMatch := Remote.HostSizesMatch;
    RemoteHostSummaryValid := True;
  end;
  // Start with the pane named by the command. If entering zoom also restores
  // an existing zoom owner, that pane is acquired below as part of the same
  // compound commit. This preserves the per-pane lock display while the
  // daemon's merged-state validation prevents concurrent dual maxima.
  if not LockRemoteLayout(P) then
    Exit;
  // LockLayout drains frames which precede its reply. A host resize/attach
  // summary can therefore become available while this call waits; adopt it
  // before deriving either kind of maximum.
  if Remote.HostSummaryValid then
  begin
    RemoteMinHostW := Remote.MinHostW;
    RemoteMinHostH := Remote.MinHostH;
    RemoteHostSizesMatch := Remote.HostSizesMatch;
    RemoteHostSummaryValid := True;
  end;
  if not RemoteHostSummaryValid then
  begin
    Remote.UnlockLayout(-1);
    Exit;
  end;

  Candidate := Copy(RemoteGeom, 0, Length(RemoteGeom));
  Target := Candidate[P];
  if ACommand = cmFullScreen then
  begin
    if Target.FullScreen then
    begin
      Target.FullScreen := False;
      Target.Zoomed := False;
    end
    else
    begin
      Target.FullScreen := True;
      Target.Zoomed := True;
    end;
  end
  else
  begin
    Target.FullScreen := False;
    Target.Zoomed := not Target.Zoomed;
  end;
  if Target.Zoomed then
    for I := 0 to High(Candidate) do
      if (I <> P) and (Candidate[I].Zoomed or Candidate[I].FullScreen) then
        if not LockRemoteLayout(I) then
        begin
          Remote.UnlockLayout(-1);
          Exit;
        end;
  // A second pane grant may have drained a newer host summary. Its revision
  // cannot have changed (that would deny the grant), but physical host
  // metadata is deliberately independent of layout revision.
  if Remote.HostSummaryValid then
  begin
    RemoteMinHostW := Remote.MinHostW;
    RemoteMinHostH := Remote.MinHostH;
    RemoteHostSizesMatch := Remote.HostSizesMatch;
    RemoteHostSummaryValid := True;
  end;
  Target.Minimized := False;
  Target.IconSlot := -1;
  if Target.FullScreen then
  begin
    SharedFullScreenSize(FullDeskW, FullDeskH, FullCols, FullRows);
    Target.Cols := FullCols;
    Target.Rows := FullRows;
  end
  else if Target.Zoomed then
  begin
    SharedMaximizedSize(RemoteDeskW, RemoteDeskH, MaxDeskW, MaxDeskH,
      MaxCols, MaxRows);
    Target.Cols := MaxCols;
    Target.Rows := MaxRows;
  end
  else
  begin
    Target.Cols := Target.BW - 2;
    Target.Rows := Target.BH - 2;
  end;
  if Target.Cols < 4 then Target.Cols := 4;
  if Target.Rows < 2 then Target.Rows := 2;
  Candidate[P] := Target;
  ChangeMask := LongWord(1) shl P;
  if Target.Zoomed then
    for I := 0 to High(Candidate) do
      if (I <> P) and (Candidate[I].Zoomed or Candidate[I].FullScreen) then
      begin
        Candidate[I].Zoomed := False;
        Candidate[I].FullScreen := False;
        Candidate[I].Cols := Candidate[I].BW - 2;
        Candidate[I].Rows := Candidate[I].BH - 2;
        if Candidate[I].Cols < 4 then Candidate[I].Cols := 4;
        if Candidate[I].Rows < 2 then Candidate[I].Rows := 2;
        ChangeMask := ChangeMask or (LongWord(1) shl I);
      end;

  WR := Default(Objects.TRect);
  Win[P]^.GetBounds(WR);
  RemoteZoomOldX1 := Desktop^.Origin.X + WR.A.X;
  RemoteZoomOldY1 := Desktop^.Origin.Y + WR.A.Y;
  RemoteZoomOldX2 := Desktop^.Origin.X + WR.B.X - 1;
  RemoteZoomOldY2 := Desktop^.Origin.Y + WR.B.Y - 1;
  EntersZoom := (not RemoteGeom[P].Zoomed) and Target.Zoomed;
  LeavesZoom := RemoteGeom[P].Zoomed and (not Target.Zoomed);
  RemoteZoomPreviewId := 0;
  RemoteZoomPreviewSeq := 0;
  if Cfg.ZoomAnim and (EntersZoom or LeavesZoom) then
    RemoteZoomPreviewId := Remote.NewPreviewId;

  // Expansion belongs before the proposal: output produced during these
  // eight frames is still old-geometry output and must be parsed by the old
  // mirror. The authoritative LAYOUT_EV performs the only structural paint.
  if Cfg.ZoomAnim and EntersZoom then
  begin
    if Target.FullScreen then
      SharedFullScreenSize(FullDeskW, FullDeskH, FullCols, FullRows)
    else
    begin
      SharedMaximizedSize(RemoteDeskW, RemoteDeskH, FullDeskW, FullDeskH,
        MaxCols, MaxRows);
    end;
    ZoomAnimate(Win[P], RemoteZoomOldX1, RemoteZoomOldY1,
      RemoteZoomOldX2, RemoteZoomOldY2, Desktop^.Origin.X,
      Desktop^.Origin.Y, Desktop^.Origin.X + FullDeskW - 1,
      Desktop^.Origin.Y + FullDeskH - 1);
  end;

  Titles := Default(TStrArray);
  SetLength(Titles, Lay.PaneCount);
  for I := 0 to Lay.PaneCount - 1 do
    if Win[I] <> nil then
      Titles[I] := Win[I]^.GetTitle(80);
  // Restore/contraction frames belong after the authoritative ACK. Reserve
  // that short cosmetic tail while this client still owns the pane; the
  // daemon releases the structural lease immediately on commit but keeps the
  // same generation/id authorized for at most two seconds.
  if Cfg.ZoomAnim and LeavesZoom then
  begin
    Inc(RemoteZoomPreviewSeq);
    if not Remote.SendLayoutPreview(P, RemoteZoomPreviewId,
      Remote.LayoutRevision, RemoteZoomPreviewSeq, PREVIEW_OP_TAIL_BEGIN,
      0, 0, 0, 0) then
    begin
      Remote.UnlockLayout(-1);
      ResetRemoteZoomState;
      Exit;
    end;
  end;
  if not Remote.SendLayout(SaveLayoutString(Lay), Lay.Focused, Titles,
    Candidate, RemoteDeskW, RemoteDeskH, ChangeMask) then
  begin
    Remote.UnlockLayout(-1);
    ResetRemoteZoomState;
    Exit;
  end;

  RemoteZoomPending := True;
  RemoteZoomPane := P;
  RemoteZoomTarget := Target;
  RemoteZoomBaseRevision := Remote.LayoutRevision;
  RemoteZoomSentTick := GetTickCount64;
  RemoteZoomContractPending := False;
  RemoteZoomContractPane := P;
  // Contraction is delayed until the ACK has restored and physically painted
  // the IDE. Running it here would either parse old output at the new width or
  // draw its rings over the raw application's stale surface.
  if not (Cfg.ZoomAnim and LeavesZoom) then
    RemoteZoomContractPane := -1;
  if DebugActive then
    DebugLog(Format('remote-zoom: proposed pane=%d zoom=%d full=%d pty=%dx%d',
      [P, Ord(Target.Zoomed), Ord(Target.FullScreen),
       Target.Cols, Target.Rows]));
end;

procedure TSuperApp.FinishRemoteZoomAnimation;
var
  P: integer;
  WR: Objects.TRect;
  NewX1, NewY1, NewX2, NewY2: integer;
  CanAnimate: boolean;
begin
  if not RemoteZoomContractPending then
    Exit;
  RemoteZoomContractPending := False;
  P := RemoteZoomContractPane;
  CanAnimate := (P >= 0) and (P < MAX_PANES) and (Win[P] <> nil) and
    (not PassthroughActive) and (Desktop <> nil);
  if CanAnimate then
  begin
    WR := Default(Objects.TRect);
    Win[P]^.GetBounds(WR);
    NewX1 := Desktop^.Origin.X + WR.A.X;
    NewY1 := Desktop^.Origin.Y + WR.A.Y;
    NewX2 := Desktop^.Origin.X + WR.B.X - 1;
    NewY2 := Desktop^.Origin.Y + WR.B.Y - 1;
    ZoomAnimate(Win[P], RemoteZoomOldX1, RemoteZoomOldY1,
      RemoteZoomOldX2, RemoteZoomOldY2, NewX1, NewY1, NewX2, NewY2);
  end;
  // End the authorized post-commit tail even if the local renderer could no
  // longer animate (for example, its terminal disappeared during the ACK).
  // That makes observers clear any last ring immediately instead of waiting
  // for the daemon's defensive timeout.
  if (P >= 0) and (P < MAX_PANES) and (Remote <> nil) and
     Remote.Connected and (RemoteZoomPreviewId <> 0) then
  begin
    Inc(RemoteZoomPreviewSeq);
    Remote.SendLayoutPreview(P, RemoteZoomPreviewId,
      Remote.LayoutRevision, RemoteZoomPreviewSeq, PREVIEW_OP_TAIL_END,
      0, 0, 0, 0);
  end;
  ResetRemoteZoomState;
end;

// derive passthrough purely from the maximized state, once per Idle tick,
// so any window-management action (restore, minimize, switch, close, split)
// leaves it automatically without wiring every command.
procedure TSuperApp.UpdatePassthrough;
var
  f, DeskW, DeskH: integer;
  want: boolean;
begin
  f := Lay.Focused;
  CanonicalDesktopSize(DeskW, DeskH);
  // Raw pane bytes cannot be width-preserving on a host which failed the
  // UTF-8 rendering probe. Keep that one client on the cell renderer; other
  // UTF-8 clients attached to the same canonical session may still use raw.
  want := HostUtf8Output and
    (f >= 0) and (f < MAX_PANES) and (Win[f] <> nil) and
    Win[f]^.Zoomed and Win[f]^.FullScreen and (Current = PView(Desktop)) and
    (((not RemoteMode) and (ScreenWidth = DeskW) and
      (ScreenHeight = DeskH + 2) and (Scr[f] <> nil) and
      (Scr[f].Width = ScreenWidth) and (Scr[f].Height = ScreenHeight)) or
     (RemoteMode and RemoteHostSummaryValid and RemoteHostSizesMatch and
      (ScreenWidth = RemoteMinHostW) and
      (ScreenHeight = RemoteMinHostH) and
      (ScreenWidth = RemoteDeskW) and
      (ScreenHeight = RemoteDeskH + 2) and
      (not SharedFullScreenRendered) and
      (Scr[f] <> nil) and (Scr[f].Width = ScreenWidth) and
      (Scr[f].Height = ScreenHeight)));
  if want and (not PassthroughActive) then
    EnterPassthrough(f)
  else if PassthroughActive and (not want) then
    ExitPassthrough
  else if PassthroughActive and
    ((ScreenWidth <> PassReqW) or (ScreenHeight <> PassReqH)) then
  begin
    if RemoteMode then
    begin
      if RemoteHostSummaryValid and RemoteHostSizesMatch and
         (ScreenWidth = RemoteMinHostW) and
         (ScreenHeight = RemoteMinHostH) and (PassPane >= 0) and
         (PassPane < MAX_PANES) and (Scr[PassPane] <> nil) and
         (Scr[PassPane].Width = ScreenWidth) and
         (Scr[PassPane].Height = ScreenHeight) then
      begin
        PassReqW := ScreenWidth;
        PassReqH := ScreenHeight;
      end
      else
      begin
        // Until the serialized desktop transaction is acknowledged, raw
        // bytes cannot map one-to-one on every physical viewer.
        SharedFullScreenRendered := True;
        ExitPassthrough;
      end;
    end
    else
    begin
      PassReqW := ScreenWidth;
      PassReqH := ScreenHeight;
      if Scr[PassPane] <> nil then
        Scr[PassPane].Resize(ScreenWidth, ScreenHeight);
      if Panes[PassPane] <> nil then
        Panes[PassPane].Resize(ScreenWidth, ScreenHeight);
    end;
  end;
end;

// Fingerprint of shared visible geometry+titles. Focus and the lock mask use
// their own ordered server events and must not trigger a geometry proposal.
function TSuperApp.ComputeLayoutHash: string;
var
  Geom: TPaneGeomArray;
  DeskW, DeskH: integer;
  i: integer;
begin
  Result := '';
  if Lay = nil then
    Exit;
  CollectPaneGeom(Geom, DeskW, DeskH);
  Result := IntToStr(Lay.PaneCount) + ':' +
    IntToStr(DeskW) + 'x' + IntToStr(DeskH);
  for i := 0 to Length(Geom) - 1 do
  begin
    Result := Result + Format('|%d,%d,%d,%d,%d,%d,%d,%d,%d,%d',
      [Geom[i].BX, Geom[i].BY, Geom[i].BW, Geom[i].BH,
       Geom[i].Cols, Geom[i].Rows, Ord(Geom[i].Zoomed),
       Ord(Geom[i].Minimized), Geom[i].IconSlot,
       Ord(Geom[i].FullScreen)]);
    if (i < MAX_PANES) and (Win[i] <> nil) then
      Result := Result + ',' + Win[i]^.GetTitle(80);
  end;
end;

// Host membership and physical sizes are transport safety metadata, not
// canonical desktop geometry. Apply them even while this client owns a pane
// lease; never Locate a window or resize a mirror from this event.
procedure TSuperApp.ApplyRemoteHostSummaryEv(const AData: TByteArray);
var
  Clients, MinHostW, MinHostH, OldClientCount, I, NoticeCount: Longint;
  HostSizesMatch, AnyFull: boolean;
begin
  if not DecodeHostSummaryBlob(AData, Clients, MinHostW, MinHostH,
    HostSizesMatch) then
    Exit;
  OldClientCount := RemoteClientCount;
  RemoteClientCount := Clients;
  RemoteMinHostW := MinHostW;
  RemoteMinHostH := MinHostH;
  RemoteHostSizesMatch := HostSizesMatch;
  RemoteHostSummaryValid := True;
  // The daemon serializes membership changes and emits this frame to every
  // remaining client. Reuse that exact order; no new per-client protocol or
  // shared desktop state is needed. A snapshot establishes the baseline for
  // the attaching client, so it never announces its own attachment.
  if RemoteMembershipReady and (Clients >= 0) then
  begin
    if Clients > OldClientCount then
      for NoticeCount := OldClientCount + 1 to Clients do
        QueueMemberNotice(mnConnected, NoticeCount)
    else if Clients < OldClientCount then
      for NoticeCount := OldClientCount - 1 downto Clients do
        QueueMemberNotice(mnDisconnected, NoticeCount);
  end;
  if DebugFull then
    DebugLog(Format('host-summary-event: clients=%d min=%dx%d match=%d',
      [Clients, MinHostW, MinHostH, Ord(HostSizesMatch)]));

  AnyFull := False;
  if Lay <> nil then
    for I := 0 to Lay.PaneCount - 1 do
      if (I < MAX_PANES) and (Win[I] <> nil) and Win[I]^.FullScreen then
      begin
        AnyFull := True;
        Break;
      end;
  if not AnyFull then
    SharedFullScreenRendered := False
  else if (not HostSizesMatch) or (Clients <> OldClientCount) then
    // Once membership changes, keep the currently visible fullscreen mode
    // rendered until an explicit fullscreen-out/fullscreen-in hand-off. This avoids an
    // attach/detach silently clearing a viewer and switching it back to raw.
    SharedFullScreenRendered := True;

  // UpdatePassthrough reclaims raw output immediately when the summary is
  // incompatible, invalid for this surface, or the membership latch above
  // was set. ExitPassthrough performs one settled renderer redraw and, in
  // remote mode, does not change any canonical/mirror geometry.
  UpdatePassthrough;
end;

// Apply the daemon's one canonical desktop. Geometry, fullscreen, focus and
// lock flags are shared; the physical host may only clip the result.
procedure TSuperApp.ApplyRemoteLayoutEv(const AData: TByteArray;
  APeer: boolean; ALocalPreservePane: integer);
var
  Nodes: string;
  Focused, DeskW, DeskH, WireClients, WireMinHostW,
    WireMinHostH: Longint;
  Revision: QWord;
  Changes, LockedPanes, OldLockedPanes, PreservePanes,
    AllowedPanes: LongWord;
  Titles: TStrArray;
  Geom, CanonicalGeom: TPaneGeomArray;
  NewLay: TLayout;
  I: integer;
  GR: Objects.TRect;
  AnyFull, WireHostSizesMatch, ZoomAck, ZoomReply, DesktopChanged: boolean;
  SavedSuppress: boolean;
  FullDeskW, FullDeskH, FullCols, FullRows: integer;
  MaxDeskW, MaxDeskH: integer;

  procedure PreserveLocalPane(APane: integer);
  var
    R: Objects.TRect;
  begin
    if (APane < 0) or (APane >= Length(Geom)) or
       (APane >= MAX_PANES) or (Win[APane] = nil) then
      Exit;
    R := Default(Objects.TRect);
    if Win[APane]^.Zoomed then
      R := Win[APane]^.ZoomRect
    else if Win[APane]^.Minimized then
      R := Win[APane]^.SavedRect
    else
      Win[APane]^.GetBounds(R);
    Geom[APane].BX := R.A.X;
    Geom[APane].BY := R.A.Y;
    Geom[APane].BW := R.B.X - R.A.X;
    Geom[APane].BH := R.B.Y - R.A.Y;
    Geom[APane].Zoomed := Win[APane]^.Zoomed;
    Geom[APane].Minimized := Win[APane]^.Minimized;
    if Win[APane]^.Minimized then
      Geom[APane].IconSlot := Win[APane]^.IconSlot
    else
      Geom[APane].IconSlot := -1;
    Geom[APane].FullScreen := Win[APane]^.FullScreen;
    // A live drag changes only presentation until its reliable commit. Keep
    // parsing/drawing this actor pane at the mirror size which was actually
    // in force when the peer event arrived.
    if Scr[APane] <> nil then
    begin
      Geom[APane].Cols := Scr[APane].Width;
      Geom[APane].Rows := Scr[APane].Height;
    end;
  end;
begin
  if not DecodeLayoutBlob(AData, Nodes, Focused, Titles, Geom, DeskW,
    DeskH, Revision, WireClients, Changes, LockedPanes, WireMinHostW,
    WireMinHostH, WireHostSizesMatch) then
    Exit;
  if (Revision = 0) or
     (Length(Titles) <> Lay.PaneCount) or
     (Length(Geom) <> Lay.PaneCount) or
     (WireClients < 0) or (WireClients > MAX_CLIENTS) or
     (WireMinHostW < 0) or (WireMinHostH < 0) then
    Exit;   // out of sync: another event will arrive after convergence
  AllowedPanes := (LongWord(1) shl Lay.PaneCount) - 1;
  if APeer then
  begin
    if (Changes and not AllowedPanes) <> 0 then
      Exit;
    PreservePanes := Changes;
    // LockLayout may already have queued a same-revision ordinary layout just
    // before this pane's grant. It reclassifies that frame as peer state and
    // names the newly leased pane here, avoiding both a stale relocation and
    // a dropped first gesture under simultaneous acquisition.
    if (ALocalPreservePane >= 0) and
       (ALocalPreservePane < Lay.PaneCount) then
      PreservePanes := PreservePanes or
        (LongWord(1) shl ALocalPreservePane);
  end
  else
  begin
    if Changes <> 0 then
      Exit;
    PreservePanes := 0;
  end;
  CanonicalGeom := Copy(Geom, 0, Length(Geom));
  for I := 0 to Lay.PaneCount - 1 do
    if (PreservePanes and (LongWord(1) shl I)) <> 0 then
      PreserveLocalPane(I);
  // Every zoom/fullscreen request changes Zoomed or FullScreen. Combined with the
  // advanced revision and exact restore rectangle, those flags correlate the
  // ordinary reply without trusting the actor's proposed grid. Cols/Rows are
  // daemon authority: it may normalize them for an attach/resize just before
  // commit, and an egress-time client drop may change the summary embedded in
  // the reply without changing the already committed safe geometry.
  ZoomAck := (not APeer) and RemoteZoomPending and (RemoteZoomPane >= 0) and
    (RemoteZoomPane < Length(Geom)) and
    (Revision > RemoteZoomBaseRevision) and
    (Geom[RemoteZoomPane].BX = RemoteZoomTarget.BX) and
    (Geom[RemoteZoomPane].BY = RemoteZoomTarget.BY) and
    (Geom[RemoteZoomPane].BW = RemoteZoomTarget.BW) and
    (Geom[RemoteZoomPane].BH = RemoteZoomTarget.BH) and
    (Geom[RemoteZoomPane].Zoomed = RemoteZoomTarget.Zoomed) and
    (Geom[RemoteZoomPane].Minimized = RemoteZoomTarget.Minimized) and
    (Geom[RemoteZoomPane].FullScreen = RemoteZoomTarget.FullScreen);
  // A successful geometry mutation always advances the canonical revision.
  // If another pane committed while this proposal was in flight, the daemon
  // rejects our stale base and returns that newer state after releasing the
  // lease. Treat that state as a negative ACK instead of leaving every later
  // fullscreen/double-click blocked behind a proposal which can no longer complete.
  // While this client owns the pane, unrelated canonical commits arrive as
  // peer events. The first ordinary snapshot after FRAME_LAYOUT is therefore
  // its correlated success/rejection reply even when validation rejected the
  // proposal without advancing the revision.
  ZoomReply := (not APeer) and RemoteZoomPending;
  NewLay := nil;
  if (not LoadLayoutString(Nodes, NewLay, True)) or (NewLay = nil) then
    Exit;
  if NewLay.PaneCount <> Lay.PaneCount then
  begin
    NewLay.Free;
    Exit;
  end;
  NewLay.Focused := Focused;
  if DebugFull then
    DebugLog(Format('layout-event: revision=%d peer=%d preserve=%x ' +
      'wire-clients=%d wire-host=%dx%d/%d locks=%x focus=%d',
      [Revision, Ord(APeer), PreservePanes, WireClients, WireMinHostW,
       WireMinHostH, Ord(WireHostSizesMatch), LockedPanes, Focused]));
  // Set the transient flag before SetTitle: SetTitle redraws the frame.
  // Updating it later painted one final stale shaded border on unlock.
  OldLockedPanes := RemoteLockedPanes;
  RemoteLockedPanes := LockedPanes;
  // Every SizeLimits/Zoom/ArrangeIcons call below must see the incoming desk,
  // never the one from the preceding revision.
  DesktopChanged := (RemoteDeskW <> DeskW) or (RemoteDeskH <> DeskH);
  RemoteDeskW := DeskW;
  RemoteDeskH := DeskH;
  // A canonical event is one visual transaction. Locate/Hide/Show/Select all
  // redraw views internally; keep those intermediate buffers off the host and
  // emit one settled diff after every pane and icon has reached its final slot.
  SavedSuppress := SuppressFlush;
  SuppressFlush := True;
  try
  if DesktopChanged then
    SetCanonicalDesktop(DeskW, DeskH, True, False);
  PrepareRemotePreviewsForLayout(LockedPanes);
  Lay.Free;
  Lay := NewLay;
  for I := 0 to Lay.PaneCount - 1 do
    if (I < MAX_PANES) and (Win[I] <> nil) and (Trim(Titles[I]) <> '') and
       (Trim(Win[I]^.GetTitle(80)) <> Trim(Titles[I])) then
      Win[I]^.SetTitle(' ' + Trim(Titles[I]));
  RemoteAttachSettling := True;
  try
    for I := 0 to Lay.PaneCount - 1 do
      if (I < MAX_PANES) and (Win[I] <> nil) then
      begin
        if Geom[I].Minimized then
          Win[I]^.IconSlot := Geom[I].IconSlot
        else
          Win[I]^.IconSlot := -1;
        // A layout commit owns PTY dimensions as well as the window bounds.
        // Apply the mirror resize under the same suppressed transaction; the
        // daemon deliberately sends no earlier RESIZE_EV for this commit.
        if (Scr[I] <> nil) and (Geom[I].Cols >= 4) and
           (Geom[I].Rows >= 2) and
           ((Scr[I].Width <> Geom[I].Cols) or
            (Scr[I].Height <> Geom[I].Rows)) then
          Scr[I].Resize(Geom[I].Cols, Geom[I].Rows);
        if Win[I]^.Minimized and (not Geom[I].Minimized) then
          RestoreWindow(I);
        if (Geom[I].BW > 0) and (Geom[I].BH > 0) and
           (not Geom[I].Minimized) then
        begin
          GR.Assign(Geom[I].BX, Geom[I].BY, Geom[I].BX + Geom[I].BW,
            Geom[I].BY + Geom[I].BH);
          if Geom[I].Zoomed and Win[I]^.Zoomed then
            Win[I]^.ZoomRect := GR
          else
          begin
            if Win[I]^.Zoomed then
              Win[I]^.Zoom;
            Win[I]^.Locate(GR);
            if Geom[I].Zoomed then
              Win[I]^.Zoom;
          end;
          if Geom[I].Zoomed then
          begin
            if Geom[I].FullScreen then
            begin
              SharedFullScreenSize(FullDeskW, FullDeskH, FullCols, FullRows);
              GR.Assign(0, 0, FullDeskW, FullDeskH);
            end
            else
            begin
              // Geom is the just-committed canonical state.  Re-deriving it
              // from a later host-summary would split the shared view.
              MaxDeskW := Geom[I].Cols + 2;
              MaxDeskH := Geom[I].Rows + 2;
              GR.Assign(0, 0, MaxDeskW, MaxDeskH);
            end;
            Win[I]^.Locate(GR);
          end;
        end
        else if Geom[I].Zoomed <> Win[I]^.Zoomed then
          Win[I]^.Zoom;
        Win[I]^.FullScreen := Geom[I].FullScreen;
      end;
    for I := 0 to Lay.PaneCount - 1 do
      if (I < MAX_PANES) and (Win[I] <> nil) and Geom[I].Minimized and
         (not Win[I]^.Minimized) then
        MinimizeWindow(I);
    for I := 0 to Lay.PaneCount - 1 do
      if (I < MAX_PANES) and (Win[I] <> nil) and Geom[I].Minimized and
         (Geom[I].BW > 0) and (Geom[I].BH > 0) then
      begin
        GR.Assign(Geom[I].BX, Geom[I].BY,
          Geom[I].BX + Geom[I].BW, Geom[I].BY + Geom[I].BH);
        Win[I]^.SavedRect := GR;
      end;
    // Always normalize the complete icon strip. If all incoming minimized
    // flags already matched locally, no MinimizeWindow call above would have
    // arranged it, which previously allowed two stale icons to overlap.
    ArrangeIcons;
    // A commit on another pane may arrive while this viewer is watching a
    // still-locked live gesture. Reapply that cosmetic position/ring over the
    // newer canonical base; never let an unrelated revision make it jump
    // backwards until its own owner commits.
    ReapplyRemotePreviewsAfterLayout(LockedPanes);
  finally
    RemoteAttachSettling := False;
  end;
  // Geom may contain the actor's live visual rectangle for panes named by a
  // peer event. RemoteGeom remains the daemon's canonical base so the actor's
  // later stale-by-design per-pane proposal merges only its owned pane.
  RemoteGeom := Copy(CanonicalGeom, 0, Length(CanonicalGeom));
  if ZoomAck then
  begin
    if DebugActive then
      DebugLog(Format('remote-zoom: acknowledged pane=%d revision=%d',
        [RemoteZoomPane, Revision]));
    RemoteZoomPending := False;
    RemoteZoomPane := -1;
    RemoteZoomTarget := Default(TPaneGeom);
    RemoteZoomBaseRevision := 0;
    RemoteZoomSentTick := 0;
    RemoteZoomContractPending := RemoteZoomContractPane >= 0;
    if not RemoteZoomContractPending then
    begin
      RemoteZoomContractPane := -1;
      RemoteZoomPreviewId := 0;
      RemoteZoomPreviewSeq := 0;
    end;
  end
  else if ZoomReply then
  begin
    if DebugActive then
      DebugLog(Format('remote-zoom: rejected base=%d revision=%d',
        [RemoteZoomBaseRevision, Revision]));
    ResetRemoteZoomState;
  end;
  RemoteSharedFocus := Focused;
  if not APeer then
  begin
    RemoteGeometryDirty := False;
    RemoteTreeDirty := False;
    for I := 0 to MAX_PANES - 1 do
      RemoteGeomDirtyPanes[I] := False;
  end
  else
  begin
    // A peer event settles every pane except the locally leased ones. Preserve
    // any dirty bit already produced by that in-flight gesture; clearing it
    // here could turn its final FRAME_LAYOUT into a zero-change proposal.
    RemoteGeometryDirty := False;
    for I := 0 to MAX_PANES - 1 do
    begin
      if (PreservePanes and (LongWord(1) shl I)) = 0 then
        RemoteGeomDirtyPanes[I] := False;
      if RemoteGeomDirtyPanes[I] then
        RemoteGeometryDirty := True;
    end;
  end;
  AnyFull := False;
  for I := 0 to Lay.PaneCount - 1 do
    if (I < MAX_PANES) and (Win[I] <> nil) and Win[I]^.FullScreen then
      AnyFull := True;
  if not AnyFull then
    SharedFullScreenRendered := False
  else if not RemoteHostSizesMatch then
    // The dedicated host-summary event owns membership metadata. A layout
    // event may enter fullscreen while the latest summary is incompatible.
    SharedFullScreenRendered := True;
  if (Focused >= 0) and (Focused < Lay.PaneCount) and
     (Win[Focused] <> nil) then
    Lay.Focused := Focused
  else
    Lay.Focused := FirstVisiblePane;
  RemoteAttachSettling := True;
  try
    FocusPane(Lay.Focused);
  finally
    RemoteAttachSettling := False;
  end;
  if OldLockedPanes <> RemoteLockedPanes then
    for I := 0 to Lay.PaneCount - 1 do
      if (I < MAX_PANES) and (Win[I] <> nil) and (Win[I]^.Frame <> nil) and
         (((OldLockedPanes xor RemoteLockedPanes) and
           (LongWord(1) shl I)) <> 0) then
        Win[I]^.Frame^.DrawView;
  finally
    SuppressFlush := SavedSuppress;
  end;
  UpdatePassthrough;
  if (not APeer) and (Remote <> nil) then
    Remote.AcceptLayoutState(Revision, LockedPanes);
  // The remote loop batches all canonical events and repaints once after the
  // queue has drained.  Painting here as well exposed intermediate icon and
  // zoom states and doubled the physical terminal update.
  // what was applied is the canonical state: do not re-push (no bounces)
  RemoteLayoutHash := ComputeLayoutHash;
end;

// another client (or the CLI) closed a pane: compact in daemon mirror
procedure TSuperApp.ApplyRemoteKillPane(APane: integer);
var
  j, OldFocused: integer;
  SavedSuppress: boolean;
begin
  if (APane < 0) or (APane >= MAX_PANES) or (Win[APane] = nil) then
    Exit;
  // Structural events are serialized against pane leases by the daemon.
  // Clear cosmetic arrays before local indexes are compacted.
  ResetRemotePreviewState;
  // TGroup.Delete hides and redraws the uncovered area immediately. Keep
  // that internal FreeVision work off the physical terminal; Idle (or the
  // local Close-all caller) publishes the one settled frame afterwards.
  SavedSuppress := SuppressFlush;
  SuppressFlush := True;
  try
  OldFocused := Lay.Focused;
  Lay.ClosePane(APane);
  KillPane(APane);
  for j := APane to MAX_PANES - 2 do
  begin
    Panes[j] := Panes[j + 1];
    Scr[j] := Scr[j + 1];
    Win[j] := Win[j + 1];
    PaneTerm[j] := PaneTerm[j + 1];
    PaneConnect[j] := PaneConnect[j + 1];
    if Win[j] <> nil then
    begin
      Win[j]^.SetPaneIdx(j);
    end;
  end;
  Panes[MAX_PANES - 1] := nil;
  Scr[MAX_PANES - 1] := nil;
  Win[MAX_PANES - 1] := nil;
  PaneTerm[MAX_PANES - 1] := -1;
  PaneConnect[MAX_PANES - 1] := '';
  if OldFocused > APane then
    Lay.Focused := OldFocused - 1
  else
    Lay.Focused := OldFocused;
  if Lay.Focused >= PaneCount then
    Lay.Focused := PaneCount - 1;
  if (Lay.Focused < 0) or (Lay.Focused >= MAX_PANES) or
     (Win[Lay.Focused] = nil) then
    Lay.Focused := FirstVisiblePane;
  finally
    SuppressFlush := SavedSuppress;
  end;
  // The adjacent canonical layout event applies definitive focus/geometry;
  // Idle performs the one physical repaint after both events are drained.
end;

// the daemon created a pane (requested by this client, another one
// or the CLI): repeat the split locally and give it a window
procedure TSuperApp.ApplyRemoteNewPane(const AData: TByteArray);
var
  At, NewIdx, PC, Cols, Rows: Longint;
  Dir: byte;
  TitleS, TermS: string;
  OldCount, j, OuterW, OuterH: integer;
  SDir: TSplitDir;
  FinalRect: Objects.TRect;
  Slot: st_layout.TRect;
begin
  if CopyMode then
    EndCopyMode(False);
  if not DecodeNewPaneEv(AData, At, NewIdx, PC, Dir, Cols, Rows,
    TitleS, TermS) then
    Exit;
  if (Lay.PaneCount + 1 <> PC) or (PC > MAX_PANES) or
     ((Lay.PaneCount > 0) and ((At < 0) or (At >= Lay.PaneCount))) then
    Exit;   // out of sync: better not to touch anything
  ResetRemotePreviewState;
  OldCount := Lay.PaneCount;
  if Dir = 1 then
    SDir := sdH
  else
    SDir := sdV;
  // the desktop was left empty: the daemon is giving us the first pane back
  if Lay.PaneCount = 0 then
  begin
    if not Lay.AddFirstPane then
      Exit;
  end
  else if not Lay.SplitPane(At, SDir) then
    Exit;
  if Lay.LastInsertedIndex <> NewIdx then
  begin
    // the local tree does not match the daemon's: undo
    Lay.ClosePane(Lay.LastInsertedIndex);
    Exit;
  end;
  for j := OldCount downto NewIdx + 1 do
  begin
    Panes[j] := Panes[j - 1];
    Scr[j] := Scr[j - 1];
    Win[j] := Win[j - 1];
    PaneTerm[j] := PaneTerm[j - 1];
    PaneConnect[j] := PaneConnect[j - 1];
    if Win[j] <> nil then
    begin
      Win[j]^.SetPaneIdx(j);
    end;
  end;
  // Clear the slot the shift vacated, all four of it. Panes and Scr are
  // overwritten just below and PaneTerm too, but Win was left holding the
  // pointer the shift had just copied UP -- so the window now sat in the
  // array twice, and CreateWindowForPane refuses to build one where Win is
  // not nil. The new pane therefore got no window of its own, the focus
  // landed on its neighbour's, and closing either index freed the shared
  // window through one slot and left the other dangling: the next repaint
  // walked into it through SyncScrollBar and died. The local path already
  // did this (see the split above); only the remote one did not, which is
  // why it needed a daemon to show itself.
  Panes[NewIdx] := nil;
  Win[NewIdx] := nil;
  PaneTerm[NewIdx] := FindWindowClass(TermS);
  PaneConnect[NewIdx] := '';
  Scr[NewIdx] := TScreen.Create(Cols, Rows, DEFAULT_SCROLLBACK);
  if Trim(TitleS) = '' then
    TitleS := UiText('session pane', 'panel de sesion');
  // Cols/Rows are already the daemon-resolved class/global properties.  Build
  // the exact canonical rectangle before the detached TWindow is inserted;
  // consulting this client's class cache here used to show one centred size
  // and then jump to the daemon's size on the adjacent LAYOUT event.
  if (RemoteDeskW > 0) and (RemoteDeskH > 0) then
  begin
    OuterW := Cols + 2;
    OuterH := Rows + 2;
    if OuterW > RemoteDeskW then OuterW := RemoteDeskW;
    if OuterH > RemoteDeskH then OuterH := RemoteDeskH;
    Slot := CentredRect(OuterW, OuterH, RemoteDeskW, RemoteDeskH);
    FinalRect.Assign(Slot.X, Slot.Y, Slot.X + Slot.W, Slot.Y + Slot.H);
  end
  else
    FinalRect := NewWindowRect(PaneTerm[NewIdx]);
  CreateWindowForPane(NewIdx, Trim(TitleS), FinalRect);
  if (PaneTerm[NewIdx] >= 0) and (Win[NewIdx] <> nil) then
    Win[NewIdx]^.TitleFixed := True;
  SyncPaneToWindow(NewIdx);
  if Win[NewIdx] = nil then
  begin
    FreeAndNil(Scr[NewIdx]);
    Lay.ClosePane(NewIdx);
    for j := NewIdx to OldCount - 1 do
    begin
      Panes[j] := Panes[j + 1];
      Scr[j] := Scr[j + 1];
      Win[j] := Win[j + 1];
      PaneTerm[j] := PaneTerm[j + 1];
      PaneConnect[j] := PaneConnect[j + 1];
      if Win[j] <> nil then
      begin
        Win[j]^.SetPaneIdx(j);
      end;
    end;
    Panes[OldCount] := nil;
    Scr[OldCount] := nil;
    Win[OldCount] := nil;
    PaneTerm[OldCount] := -1;
    PaneConnect[OldCount] := '';
    Exit;
  end;
  // same rule as the local path: a new pane does not disturb the others
  Lay.Focused := NewIdx;
  // FRAME_NEWPANE_EV and its adjacent canonical layout are one ordered
  // daemon transaction.  Desktop.Insert has already selected this window;
  // record the same authoritative focus now so TSuperApp.HandleEvent cannot
  // mistake that selection for an unsent user action while the following
  // layout frame is still queued behind the bounded socket drain.
  RemoteSharedFocus := NewIdx;
  // The adjacent canonical layout event applies definitive focus/geometry;
  // Idle performs the one physical repaint after both events are drained.
end;

// Authoritative daemon PTY size. It is identical in every client and is never
// negotiated from a host terminal's physical dimensions.
procedure TSuperApp.ApplyRemoteResize(APane: integer;
  const AData: TByteArray);
var
  C, R: Longint;
begin
  if (APane < 0) or (APane >= MAX_PANES) or (Scr[APane] = nil) or
     (Length(AData) < 2 * SizeOf(Longint)) then
    Exit;
  C := 0;
  R := 0;
  Move(AData[0], C, SizeOf(C));
  Move(AData[SizeOf(C)], R, SizeOf(R));
  if DebugActive then
    DebugLog(Format('resize: pane=%d daemon says %dx%d (mirror was %dx%d)',
      [APane, C, R, Scr[APane].Width, Scr[APane].Height]));
  if (C < 4) or (R < 2) then
    Exit;
  if (C <> Scr[APane].Width) or (R <> Scr[APane].Height) then
  begin
    Scr[APane].Resize(C, R);
    if (Win[APane] <> nil) and (Win[APane]^.Term <> nil) then
      RepaintPane(APane);
  end;
  UpdatePassthrough;
end;

procedure TSuperApp.ApplyRemoteTitle(APane: integer;
  const AData: TByteArray);
var
  L: Longint;
  S: string;
begin
  if (APane < 0) or (APane >= MAX_PANES) or (Win[APane] = nil) or
     (Length(AData) < SizeOf(Longint)) then
    Exit;
  L := 0;
  Move(AData[0], L, SizeOf(L));
  if (L <= 0) or (SizeOf(Longint) + L > Length(AData)) then
    Exit;
  S := '';
  SetLength(S, L);
  Move(AData[SizeOf(Longint)], S[1], L);
  if Trim(S) = '' then
    Exit;
  Win[APane]^.SetTitle(' ' + Trim(S));
  RepaintChanges;
  RemoteLayoutHash := ComputeLayoutHash;
end;

// classic Window|Tile: recompute the mosaic, drop manual geometry
procedure TSuperApp.DoTilePanes;
var
  i: integer;
  LayoutLocked, SavedSuppress, SavedSettling: boolean;
begin
  LayoutLocked := False;
  if RemoteMode and (not RemoteAttachSettling) and (Remote <> nil) and
     Remote.Connected then
  begin
    if not LockRemoteLayout(-1) then
      Exit;
    LayoutLocked := True;
  end;
  if RemoteMode then
  begin
    RemoteGeometryDirty := True;
    for i := 0 to MAX_PANES - 1 do
      RemoteGeomDirtyPanes[i] := True;
  end;
  SavedSuppress := SuppressFlush;
  SavedSettling := RemoteAttachSettling;
  SuppressFlush := True;
  RemoteAttachSettling := True;
  try
    for i := 0 to MAX_PANES - 1 do
      if Win[i] <> nil then
      begin
        if Win[i]^.Minimized then
          RestoreWindow(i);
        // Organize means leave every transient one-window view first. Without
        // this, RelayoutAll deliberately preserved Zoomed and three "tiled"
        // panes remained full-desktop windows on top of one another.
        Win[i]^.FullScreen := False;
        if Win[i]^.Zoomed then
          Win[i]^.Zoom;
      end;
    SharedFullScreenRendered := False;
    UpdatePassthrough;
    RelayoutAll;
    RemoteAttachSettling := SavedSettling;
    FocusPane(Lay.Focused);
    if LayoutLocked then
    begin
      SyncRemoteLayout(-1);
      LayoutLocked := False;
    end
    else
      SyncRemoteLayout;
  finally
    RemoteAttachSettling := SavedSettling;
    if LayoutLocked and (Remote <> nil) and Remote.Connected then
      Remote.UnlockLayout(-1);
    SuppressFlush := SavedSuppress;
  end;
  if (not SavedSuppress) and (not PassthroughActive) then
    RepaintChanges;
end;

// classic Window|Cascade: staggered windows at 2/3 of the desktop
procedure TSuperApp.DoCascadePanes;
var
  RD, R: Objects.TRect;
  i, k, w, h: integer;
  Slot: st_layout.TRect;
  LayoutLocked, SavedSuppress, SavedSettling: boolean;
begin
  LayoutLocked := False;
  if RemoteMode and (not RemoteAttachSettling) and (Remote <> nil) and
     Remote.Connected then
  begin
    if not LockRemoteLayout(-1) then
      Exit;
    LayoutLocked := True;
  end;
  if RemoteMode then
  begin
    RemoteGeometryDirty := True;
    for i := 0 to MAX_PANES - 1 do
      RemoteGeomDirtyPanes[i] := True;
  end;
  if Desktop = nil then
  begin
    if LayoutLocked then
      Remote.UnlockLayout(-1);
    Exit;
  end;
  RD := Default(Objects.TRect);
  Desktop^.GetExtent(RD);
  if RemoteMode and (RemoteDeskW > 0) and (RemoteDeskH > 0) then
    RD.Assign(0, 0, RemoteDeskW, RemoteDeskH);
  w := (RD.B.X - RD.A.X) * 2 div 3;
  h := (RD.B.Y - RD.A.Y) * 2 div 3;
  if w < 20 then w := 20;
  if h < 6 then h := 6;
  SavedSuppress := SuppressFlush;
  SavedSettling := RemoteAttachSettling;
  SuppressFlush := True;
  RemoteAttachSettling := True;
  try
    k := 0;
    for i := 0 to MAX_PANES - 1 do
      if Win[i] <> nil then
      begin
        if Win[i]^.Minimized then
          RestoreWindow(i);
        Win[i]^.FullScreen := False;
        if Win[i]^.Zoomed then
          Win[i]^.Zoom;
        Slot := CascadeRect(k, w, h, RD.B.X - RD.A.X, RD.B.Y - RD.A.Y);
        R.Assign(RD.A.X + Slot.X, RD.A.Y + Slot.Y,
          RD.A.X + Slot.X + Slot.W, RD.A.Y + Slot.Y + Slot.H);
        Win[i]^.Locate(R);
        Inc(k);
      end;
    SharedFullScreenRendered := False;
    UpdatePassthrough;
    RemoteAttachSettling := SavedSettling;
    FocusPane(Lay.Focused);
    if LayoutLocked then
    begin
      SyncRemoteLayout(-1);
      LayoutLocked := False;
    end
    else
      SyncRemoteLayout;
  finally
    RemoteAttachSettling := SavedSettling;
    if LayoutLocked and (Remote <> nil) and Remote.Connected then
      Remote.UnlockLayout(-1);
    SuppressFlush := SavedSuppress;
  end;
  if (not SavedSuppress) and (not PassthroughActive) then
    RepaintChanges;
end;

// vendor grid: spreads all visible windows into rows and columns
// that fit the screen (TDeskTop.Tile over the ofTileable views)
procedure TSuperApp.DoOrganizePanes;
var
  R: Objects.TRect;
  i: integer;
  LayoutLocked, SavedSuppress, SavedSettling: boolean;
begin
  LayoutLocked := False;
  if RemoteMode and (not RemoteAttachSettling) and (Remote <> nil) and
     Remote.Connected then
  begin
    if not LockRemoteLayout(-1) then
      Exit;
    LayoutLocked := True;
  end;
  if RemoteMode then
  begin
    RemoteGeometryDirty := True;
    for i := 0 to MAX_PANES - 1 do
      RemoteGeomDirtyPanes[i] := True;
  end;
  if Desktop = nil then
  begin
    if LayoutLocked then
      Remote.UnlockLayout(-1);
    Exit;
  end;
  R := Default(Objects.TRect);
  Desktop^.GetExtent(R);
  if RemoteMode and (RemoteDeskW > 0) and (RemoteDeskH > 0) then
    R.Assign(0, 0, RemoteDeskW, RemoteDeskH);
  SavedSuppress := SuppressFlush;
  SavedSettling := RemoteAttachSettling;
  SuppressFlush := True;
  RemoteAttachSettling := True;
  try
    for i := 0 to MAX_PANES - 1 do
      if Win[i] <> nil then
      begin
        if Win[i]^.Minimized then
          RestoreWindow(i);
        Win[i]^.FullScreen := False;
        if Win[i]^.Zoomed then
          Win[i]^.Zoom;
      end;
    SharedFullScreenRendered := False;
    UpdatePassthrough;
    Desktop^.Tile(R);
    RemoteAttachSettling := SavedSettling;
    FocusPane(Lay.Focused);
    if LayoutLocked then
    begin
      SyncRemoteLayout(-1);
      LayoutLocked := False;
    end
    else
      SyncRemoteLayout;
  finally
    RemoteAttachSettling := SavedSettling;
    if LayoutLocked and (Remote <> nil) and Remote.Connected then
      Remote.UnlockLayout(-1);
    SuppressFlush := SavedSuppress;
  end;
  if (not SavedSuppress) and (not PassthroughActive) then
    RepaintChanges;
end;

// classic Window|List (Alt+0): pick a pane, restoring if minimized
procedure TSuperApp.DoPaneList;
var
  Titles: TStrArray;
  n, i, Sel: integer;
  T: string;
begin
  n := Lay.PaneCount;
  if n < 1 then
    Exit;
  Titles := Default(TStrArray);
  SetLength(Titles, n);
  for i := 0 to n - 1 do
  begin
    T := '';
    if (i < MAX_PANES) and (Win[i] <> nil) then
    begin
      T := Win[i]^.GetTitle(60);
      if Win[i]^.Minimized then
        T := T + UiText(' (minimized)', ' (minimizada)');
      if Win[i]^.Zoomed then
        T := T + UiText(' (zoom)', ' (zoom)');
    end;
    Titles[i] := Format('%d  %s', [i + 1, T]);
  end;
  Sel := -1;
  if RunPaneList(Titles, Lay.Focused, Sel) then
    if (Sel >= 0) and (Sel < MAX_PANES) and (Win[Sel] <> nil) then
    begin
      if Win[Sel]^.Minimized then
        RestoreWindow(Sel);
      FocusPane(Sel);
    end;
end;

// live palette switch + persistence in superterm.ini
procedure TSuperApp.ApplyPalette(AKind: integer);
var
  SavedSuppress: boolean;
begin
  if (AKind < apColor) or (AKind > apMonochrome) then
    Exit;
  AppPalette := AKind;
  case AKind of
    apBlackWhite: Cfg.Palette := 'bw';
    apMonochrome: Cfg.Palette := 'mono';
  else
    Cfg.Palette := 'color';
  end;
  SaveConfigFields(Cfg, [cfPalette]);
  // Rebuilding the two bars can draw them immediately. Hold physical output
  // until both exist under the new palette, then invalidate the renderer's
  // effective-cell cache and publish one complete frame. RepaintChanges alone
  // left much of the old palette on screen until the next focus click.
  SavedSuppress := SuppressFlush;
  SuppressFlush := True;
  try
    RebuildMenu;
    RebuildStatusLine;
  finally
    SuppressFlush := SavedSuppress;
  end;
  InvalidateFrame;
  RichInvalidate;
  ReDraw;
end;

procedure TSuperApp.SaveSessionNow;
var
  Pin: TPaneArray;
  n, i: integer;
  RD, WR: Objects.TRect;
begin
  n := Lay.PaneCount;
  if n < 1 then
    Exit;
  Pin := Default(TPaneArray);
  SetLength(Pin, n);
  for i := 0 to n - 1 do
  begin
    Pin[i].Term := '';
    Pin[i].Args := nil;
    Pin[i].Title := '';
    if Panes[i] <> nil then
    begin
      // the upper bound matters: deleting a class leaves the panes that used
      // it, and the ones after it, pointing past the end of the array
      if (PaneTerm[i] >= 0) and (PaneTerm[i] < Length(WClasses)) then
        Pin[i].Term := WClasses[PaneTerm[i]].Name
      else
      begin
        Panes[i].QueryState;
        Pin[i].Cmd := Panes[i].TitleCmd;
        Pin[i].Cwd := Panes[i].TitleCwd;
        Pin[i].Args := Panes[i].TitleArgs;
      end;
    end;
    // custom title (renamed by hand): save it to restore it verbatim
    if (i < MAX_PANES) and (Win[i] <> nil) and Win[i]^.TitleFixed and
       (Win[i]^.Title <> nil) then
      Pin[i].Title := Trim(Win[i]^.Title^);
    // window geometry and state: for a maximized one the real rect is
    // ZoomRect (the restore one); Minimize only hides, keeps bounds
    if (i < MAX_PANES) and (Win[i] <> nil) then
    begin
      if Win[i]^.Zoomed then
        WR := Win[i]^.ZoomRect
      else if Win[i]^.Minimized then
        WR := Win[i]^.SavedRect
      else
      begin
        WR := Default(Objects.TRect);
        Win[i]^.GetBounds(WR);
      end;
      Pin[i].BX := WR.A.X;
      Pin[i].BY := WR.A.Y;
      Pin[i].BW := WR.B.X - WR.A.X;
      Pin[i].BH := WR.B.Y - WR.A.Y;
      Pin[i].Minimized := Win[i]^.Minimized;
      if Win[i]^.Minimized then
        Pin[i].IconSlot := Win[i]^.IconSlot
      else
        Pin[i].IconSlot := -1;
      Pin[i].Zoomed := Win[i]^.Zoomed;
      Pin[i].FullScreen := Win[i]^.FullScreen;
    end;
  end;
  RD := Default(Objects.TRect);
  Desktop^.GetExtent(RD);
  SaveSession(SessionFile, Lay, Pin, RD.B.X - RD.A.X, RD.B.Y - RD.A.Y);
end;

procedure TSuperApp.HandleEvent(var Event: TEvent);
var
  i: integer;
  ResizeEvent: boolean;
  ResizeWidth, ResizeHeight: integer;
  PrefixByte: byte;
  PrefixSeq: RawByteString;
  ZoomSaveFlush: boolean;
  ZoomAnimOn, ZoomWasZoomed, ZoomLocked: boolean;
  ZoomF: integer;
  ZoomWX1, ZoomWY1, ZoomWX2, ZoomWY2: integer;
  ZoomDX1, ZoomDY1, ZoomDX2, ZoomDY2: integer;
  SharedR: Objects.TRect;
  DeskCol, FullDeskW, FullDeskH, FullCols, FullRows: integer;
  MaxDeskW, MaxDeskH, MaxCols, MaxRows: integer;
  CreatedProfileName, ActiveProfileName, MenuTargetName: string;
  PaneClassNames: array[0..MAX_PANES - 1] of string;
begin
  ResizeEvent := (Event.What = evCommand) and (Event.Command = cmResizeApp);
  ResizeWidth := Event.Id;
  ResizeHeight := Event.InfoWord;
  // In passthrough the maximized pane owns the whole terminal, so FreeVision
  // must NOT act on the mouse: a click on the hidden-but-still-logical menu
  // row would pop the menu and drop out of zoom. The mouse was released to the
  // app/terminal on EnterPassthrough (tracking off), so normal text selection
  // works; only prefix+f (handled below) leaves passthrough. Swallow every
  // mouse event here before the inherited handler can dispatch it.
  if PassthroughActive and ((Event.What and evMouse) <> 0) then
  begin
    ClearEvent(Event);
    Exit;
  end;
  // Fullscreen used to be visible in TWO steps: the window first maximized inside the
  // IDE (one painted frame, menu and status still there) and only on the next
  // Idle tick did passthrough take the screen -- which reads as a little
  // zoom animation. Same on the way back. Do the whole transition with the
  // flush held, then decide passthrough, then paint ONCE: straight to
  // fullscreen, and straight back to the IDE exactly as it was.
  if (Event.What = evCommand) and
     ((Event.Command = cmZoom) or (Event.Command = cmFullScreen)) then
  begin
    if RemoteMode then
    begin
      BeginRemoteZoom(Event.Command, Event.InfoPtr);
      ClearEvent(Event);
      Exit;
    end;
    // optional transition: expand the outline out to full screen before
    // zooming in, and contract it back after restoring
    ZoomF := Lay.Focused;
    ZoomLocked := False;
    ZoomAnimOn := Cfg.ZoomAnim and (Desktop <> nil) and
      (ZoomF >= 0) and (ZoomF < MAX_PANES) and (Win[ZoomF] <> nil) and
      (not Win[ZoomF]^.Minimized);
    // Acquire before the first animation frame (or before the instant
    // mutation when animation is disabled).  Other viewers can paint the
    // busy frame while the actor completes the whole visual gesture.
    if RemoteMode and (Remote <> nil) and Remote.Connected and
       (ZoomF >= 0) and (ZoomF < MAX_PANES) and (Win[ZoomF] <> nil) and
       (not Win[ZoomF]^.Minimized) then
    begin
      if not LockRemoteLayout(ZoomF) then
      begin
        ClearEvent(Event);
        Exit;
      end;
      ZoomLocked := True;
    end;
    if ZoomAnimOn then
    begin
      ZoomWasZoomed := Win[ZoomF]^.Zoomed;
      ZoomWX1 := Desktop^.Origin.X + Win[ZoomF]^.Origin.X;
      ZoomWY1 := Desktop^.Origin.Y + Win[ZoomF]^.Origin.Y;
      ZoomWX2 := ZoomWX1 + Win[ZoomF]^.Size.X - 1;
      ZoomWY2 := ZoomWY1 + Win[ZoomF]^.Size.Y - 1;
      ZoomDX1 := Desktop^.Origin.X;
      ZoomDY1 := Desktop^.Origin.Y;
      if RemoteMode then
      begin
        if Event.Command = cmFullScreen then
        begin
          SharedFullScreenSize(FullDeskW, FullDeskH, FullCols, FullRows);
          ZoomDX2 := ZoomDX1 + FullDeskW - 1;
          ZoomDY2 := ZoomDY1 + FullDeskH - 1;
        end
        else
        begin
          SharedMaximizedSize(RemoteDeskW, RemoteDeskH,
            MaxDeskW, MaxDeskH, MaxCols, MaxRows);
          ZoomDX2 := ZoomDX1 + MaxDeskW - 1;
          ZoomDY2 := ZoomDY1 + MaxDeskH - 1;
        end;
      end
      else
      begin
        ZoomDX2 := ZoomDX1 + Desktop^.Size.X - 1;
        ZoomDY2 := ZoomDY1 + Desktop^.Size.Y - 1;
      end;
      // growing: animate BEFORE the zoom, while the IDE is still on screen
      if not ZoomWasZoomed then
        ZoomAnimate(Win[ZoomF], ZoomWX1, ZoomWY1, ZoomWX2, ZoomWY2,
                    ZoomDX1, ZoomDY1, ZoomDX2, ZoomDY2);
    end;
    ZoomSaveFlush := SuppressFlush;
    SuppressFlush := True;
    try
      if Event.Command = cmFullScreen then
      begin
        // Fullscreen is the only way to the whole terminal. It fills the desktop
        // first if the window was not already filling it, so leaving full
        // screen puts the window back exactly where it was.
        if (ZoomF >= 0) and (ZoomF < MAX_PANES) and (Win[ZoomF] <> nil) and
           (not Win[ZoomF]^.Minimized) then
        begin
          if Win[ZoomF]^.FullScreen then
          begin
            Win[ZoomF]^.FullScreen := False;
            SharedFullScreenRendered := False;
            if Win[ZoomF]^.Zoomed then
            begin
              // Rendered fullscreen still uses the canonical rectangle. Put
              // the hidden logical window there first so FV's TWindow.Zoom
              // takes its restore branch and keeps the original ZoomRect.
              if RemoteMode then
              begin
                SharedR.Assign(0, 0, RemoteDeskW, RemoteDeskH);
                Win[ZoomF]^.Locate(SharedR);
              end;
              Win[ZoomF]^.Zoom;
            end;
          end
          else
          begin
            if not Win[ZoomF]^.Zoomed then
              Win[ZoomF]^.Zoom;
            Win[ZoomF]^.FullScreen := True;
            SharedFullScreenRendered := RemoteMode and
              (not RemoteHostSizesMatch);
          end;
        end;
        ClearEvent(Event);
      end
      else
        inherited HandleEvent(Event);   // plain maximise, inside the IDE
      for i := 0 to MAX_PANES - 1 do
        if (Win[i] <> nil) and Win[i]^.GetState(sfSelected) then
          FocusPane(i);
      if RemoteMode and (ZoomF >= 0) and (ZoomF < Length(RemoteGeom)) and
         (Win[ZoomF] <> nil) then
      begin
        RemoteGeomDirtyPanes[ZoomF] := True;
        RemoteGeom[ZoomF].Zoomed := Win[ZoomF]^.Zoomed;
        RemoteGeom[ZoomF].FullScreen := Win[ZoomF]^.FullScreen;
        RemoteGeom[ZoomF].Minimized := Win[ZoomF]^.Minimized;
        if Win[ZoomF]^.Minimized then
          RemoteGeom[ZoomF].IconSlot := Win[ZoomF]^.IconSlot
        else
          RemoteGeom[ZoomF].IconSlot := -1;
        if Win[ZoomF]^.FullScreen then
        begin
          SharedFullScreenSize(FullDeskW, FullDeskH, FullCols, FullRows);
          RemoteGeom[ZoomF].Cols := FullCols;
          RemoteGeom[ZoomF].Rows := FullRows;
        end
        else if Win[ZoomF]^.Zoomed then
        begin
          SharedMaximizedSize(RemoteDeskW, RemoteDeskH,
            MaxDeskW, MaxDeskH, MaxCols, MaxRows);
          RemoteGeom[ZoomF].Cols := MaxCols;
          RemoteGeom[ZoomF].Rows := MaxRows;
        end
        else
        begin
          RemoteGeom[ZoomF].Cols := RemoteGeom[ZoomF].BW - 2;
          RemoteGeom[ZoomF].Rows := RemoteGeom[ZoomF].BH - 2;
        end;
        if Win[ZoomF]^.Zoomed then
        begin
          Win[ZoomF]^.ZoomRect.Assign(RemoteGeom[ZoomF].BX,
            RemoteGeom[ZoomF].BY,
            RemoteGeom[ZoomF].BX + RemoteGeom[ZoomF].BW,
            RemoteGeom[ZoomF].BY + RemoteGeom[ZoomF].BH);
          if Win[ZoomF]^.FullScreen then
          begin
            SharedFullScreenSize(FullDeskW, FullDeskH, FullCols, FullRows);
            SharedR.Assign(0, 0, FullDeskW, FullDeskH);
          end
          else
          begin
            SharedMaximizedSize(RemoteDeskW, RemoteDeskH,
              MaxDeskW, MaxDeskH, MaxCols, MaxRows);
            SharedR.Assign(0, 0, MaxDeskW, MaxDeskH);
          end;
          Win[ZoomF]^.Locate(SharedR);
        end;
        // Resize the actor's screen mirror inside this same suppressed
        // transaction. The daemon/PTY is resized by the layout commit below;
        // without this local mirror step, restore first painted a fullscreen
        // grid in the old rectangle and the canonical echo reflowed/repainted
        // it a second time -- the final visible flash.
        if (Scr[ZoomF] <> nil) and (RemoteGeom[ZoomF].Cols >= 4) and
           (RemoteGeom[ZoomF].Rows >= 2) and
           ((Scr[ZoomF].Width <> RemoteGeom[ZoomF].Cols) or
            (Scr[ZoomF].Height <> RemoteGeom[ZoomF].Rows)) then
          Scr[ZoomF].Resize(RemoteGeom[ZoomF].Cols,
            RemoteGeom[ZoomF].Rows);
      end;
      UpdatePassthrough;
    finally
      SuppressFlush := ZoomSaveFlush;
    end;
    if not PassthroughActive then
      RepaintChanges;
    // shrinking: animate AFTER the IDE is back, so the ring is erased against
    // the real screen instead of the application's leftovers
    if ZoomAnimOn and ZoomWasZoomed and (not PassthroughActive) and
       (Win[ZoomF] <> nil) then
      ZoomAnimate(Win[ZoomF], ZoomDX1, ZoomDY1, ZoomDX2, ZoomDY2,
                  Desktop^.Origin.X + Win[ZoomF]^.Origin.X,
                  Desktop^.Origin.Y + Win[ZoomF]^.Origin.Y,
                  Desktop^.Origin.X + Win[ZoomF]^.Origin.X + Win[ZoomF]^.Size.X - 1,
                  Desktop^.Origin.Y + Win[ZoomF]^.Origin.Y + Win[ZoomF]^.Size.Y - 1);
    // Commit only after the optional contraction too: the pane remains owned
    // for the complete gesture, not merely for its state mutation.
    if RemoteMode and ZoomLocked then
      SyncRemoteLayout(ZoomF);
    Exit;
  end;
  if Event.What = evKeyDown then
  begin
    if HandleCopyKey(Event) then
      Exit;
    PrefixByte := Event.KeyCode and $00FF;
    if PrefixPending then
    begin
      PrefixPending := False;
      // prefix chords (tmux style): d=detach, c=class, s=session,
      // f=fullscreen, n/p=window +-, t=tile, 1..9=window N,
      // arrows=pane size, double prefix=literal
      if (PrefixByte = Ord('d')) or (PrefixByte = Ord('D')) then
      begin
        RequestDetach;
        ClearEvent(Event);
        Exit;
      end;
      if (PrefixByte = Ord('c')) or (PrefixByte = Ord('C')) then
      begin
        Message(@Self, evCommand, cmClassPick, nil);
        ClearEvent(Event);
        Exit;
      end;
      if (PrefixByte = Ord('s')) or (PrefixByte = Ord('S')) then
      begin
        Message(@Self, evCommand, cmSessionPick, nil);
        ClearEvent(Event);
        Exit;
      end;
      if (PrefixByte = Ord('f')) or (PrefixByte = Ord('F')) then
      begin
        Message(@Self, evCommand, cmFullScreen, nil);
        ClearEvent(Event);
        Exit;
      end;
      if (PrefixByte = Ord('n')) or (PrefixByte = Ord('N')) then
      begin
        Message(@Self, evCommand, cmWindowNext, nil);
        ClearEvent(Event);
        Exit;
      end;
      if (PrefixByte = Ord('p')) or (PrefixByte = Ord('P')) then
      begin
        Message(@Self, evCommand, cmWindowPrev, nil);
        ClearEvent(Event);
        Exit;
      end;
      // t=tile: creating a window no longer re-tiles, so there has to be a
      // quick way to ask for it
      if (PrefixByte = Ord('t')) or (PrefixByte = Ord('T')) then
      begin
        Message(@Self, evCommand, cmPaneTile, nil);
        ClearEvent(Event);
        Exit;
      end;
      if PrefixByte = Ord('[') then
      begin
        BeginCopyMode;
        ClearEvent(Event);
        Exit;
      end;
      if PrefixByte = Ord(']') then
      begin
        PasteLatestClipboard;
        ClearEvent(Event);
        Exit;
      end;
      if (PrefixByte = Ord('h')) or (PrefixByte = Ord('H')) then
      begin
        Message(@Self, evCommand, cmClipboardHistory, nil);
        ClearEvent(Event);
        Exit;
      end;
      if (PrefixByte >= Ord('1')) and (PrefixByte <= Ord('9')) then
      begin
        Message(@Self, evCommand, cmWindowBase + PrefixByte - Ord('1'), nil);
        ClearEvent(Event);
        Exit;
      end;
      if Event.KeyCode = kbRight then
      begin
        Message(@Self, evCommand, cmGrowV, nil);
        ClearEvent(Event);
        Exit;
      end;
      if Event.KeyCode = kbLeft then
      begin
        Message(@Self, evCommand, cmShrinkV, nil);
        ClearEvent(Event);
        Exit;
      end;
      if Event.KeyCode = kbDown then
      begin
        Message(@Self, evCommand, cmGrowH, nil);
        ClearEvent(Event);
        Exit;
      end;
      if Event.KeyCode = kbUp then
      begin
        Message(@Self, evCommand, cmShrinkH, nil);
        ClearEvent(Event);
        Exit;
      end;
      if PrefixByte = byte(Cfg.PrefixKey) then
      begin
        // double prefix: send ONE literal prefix to the pane (like tmux)
        WritePaneInput(Lay.Focused, AnsiChar(Chr(Cfg.PrefixKey)));
        ClearEvent(Event);
        Exit;
      end;
      // Preserve the normal terminal meaning when the prefix is followed by
      // an unbound key.
      PrefixSeq := AnsiChar(Chr(Cfg.PrefixKey)) +
        TranslateKey(Event.KeyCode, PaneWantsAppCursor(Lay.Focused));
      WritePaneInput(Lay.Focused, PrefixSeq);
      ClearEvent(Event);
      Exit;
    end;
    if PrefixByte = byte(Cfg.PrefixKey) then
    begin
      PrefixPending := True;
      ClearEvent(Event);
      Exit;
    end;
    // passthrough: the fullscreen pane owns the screen, so every ordinary key
    // goes to it -- including physical F5. The configurable prefix is handled
    // above; prefix+f is the only chord retained for leaving fullscreen.
    if PassthroughActive then
    begin
      PrefixSeq := TranslateKey(Event.KeyCode, PaneWantsAppCursor(Lay.Focused));
      if PrefixSeq <> '' then
        WritePaneInput(Lay.Focused, PrefixSeq);
      ClearEvent(Event);
      Exit;
    end;
  end;
  // Alt-1..9 NO longer intercepted: falls through to native TProgram,
  // which selects pane N (cmSelectWindowNum); open class = Classes menu
  // sync the layout focus with the selected window
  for i := 0 to MAX_PANES - 1 do
    if (Win[i] <> nil) and Win[i]^.GetState(sfSelected) and
       ((i <> Lay.Focused) or
        (RemoteMode and (i <> RemoteSharedFocus))) then
      FocusPane(i);
  inherited HandleEvent(Event);
  // TGroup/TWindow selects a mouse/Alt-N target inside the inherited call.
  // Publish that result now too; otherwise it stayed private until another
  // event happened to pass through this handler.
  for i := 0 to MAX_PANES - 1 do
    if (Win[i] <> nil) and Win[i]^.GetState(sfSelected) and
       (i <> Lay.Focused) then
      FocusPane(i);
  if ResizeEvent then
  begin
    if (ResizeWidth > 0) and (ResizeHeight > 0) then
      ApplyTerminalSize(ResizeWidth, ResizeHeight)
    else
      SyncTerminalSize;
    ClearEvent(Event);
    Exit;
  end;
  if Event.What = evCommand then
  begin
    case Event.Command of
      cmSplitV: DoSplit(sdV, -1);
      cmSplitH: DoSplit(sdH, -1);
      cmPaneClose: DoClosePane(Lay.Focused);
      cmPaneNext: CyclePane(1);
      cmPanePrev: CyclePane(-1);
      cmWindowMinimize:
        MinimizeWindow(Lay.Focused);
      cmAbout: ShowAbout;
      cmRenameWindow: RenameFocusedWindow;
      cmFitSessionSize: FitSessionToWindow;
      cmDesktopFitTerminal: AdjustDesktopToTerminal;
      cmDesktopModify: ModifyDesktopDimensions;
      cmDesktopShowSize: ShowDesktopDimensions;
      cmToggleDesktopNotifications:
        begin
          Cfg.DesktopNotifications := not Cfg.DesktopNotifications;
          SaveConfigFields(Cfg, [cfDesktopNotifications]);
          RebuildMenu;
          RefreshMemberNoticeViews;
        end;
      cmPaneTile: DoTilePanes;
      cmPaneCascade: DoCascadePanes;
      cmPaneOrganize: DoOrganizePanes;
      cmPaneList: DoPaneList;
      cmClipboardCopy: BeginCopyMode;
      cmClipboardPaste: PasteLatestClipboard;
      cmClipboardHistory: ShowClipboardHistory;
      cmClipboardClear:
        if (ClipHistory <> nil) and (ClipHistory.Count > 0) and
           (MessageBox(UiText('Clear clipboard history?',
             'Borrar el historial del portapapeles?'), nil,
             mfConfirmation or mfYesButton or mfNoButton) = cmYes) then
          ClipHistory.Clear;
      cmRedrawAll:
        begin
          ResetVideoSurface;
          ReDraw;
        end;
      cmToggleAutoSave:
        begin
          Cfg.AutoSave := not Cfg.AutoSave;
          SaveConfigFields(Cfg, [cfAutoSave]);
          RebuildMenu;
        end;
      cmToggleDragContent:
        begin
          Cfg.DragContent := not Cfg.DragContent;
          SaveConfigFields(Cfg, [cfDragContent]);
          RebuildMenu;
        end;
      cmToggleSolidBg:
        begin
          Cfg.SolidBg := not Cfg.SolidBg;
          st_video.SolidBackground := Cfg.SolidBg;
          SaveConfigFields(Cfg, [cfSolidBg]);
          RebuildMenu;
          ResetVideoSurface;   // every cell's colour changes
          ReDraw;
        end;
      cmDesktopColor:
        begin
          DeskCol := Cfg.DesktopColor;
          if RunDesktopColorPick(DeskCol) then
          begin
            Cfg.DesktopColor := DeskCol;
            SaveConfigFields(Cfg, [cfDesktopColor]);
            ResetVideoSurface;   // the whole desktop changes colour
            ReDraw;
          end;
        end;
      cmToggleZoomAnim:
        begin
          Cfg.ZoomAnim := not Cfg.ZoomAnim;
          SaveConfigFields(Cfg, [cfZoomAnim]);
          RebuildMenu;
        end;
      cmBackgroundBase..cmBackgroundBase + 29:
        begin
          Cfg.Background := ArtName(Event.Command - cmBackgroundBase);
          // a picture may ask for the layout it was designed for: a seamless
          // pattern ships with 'tile', a scene leaves the choice alone
          if ArtSuggestedMode(Event.Command - cmBackgroundBase) <> '' then
            Cfg.BackgroundMode :=
              ArtSuggestedMode(Event.Command - cmBackgroundBase);
          SaveConfigFields(Cfg, [cfBackground, cfBackgroundMode]);
          RebuildMenu;
          ResetVideoSurface;   // the whole desktop changes
          ReDraw;
        end;
      cmBackgroundModeBase..cmBackgroundModeBase + 9:
        begin
          Cfg.BackgroundMode :=
            ArtModeName(TArtMode(Event.Command - cmBackgroundModeBase));
          SaveConfigFields(Cfg, [cfBackgroundMode]);
          RebuildMenu;
          ResetVideoSurface;
          ReDraw;
        end;
      cmToggleAutoRestore:
        begin
          Cfg.AutoRestore := not Cfg.AutoRestore;
          SaveConfigFields(Cfg, [cfAutoRestore]);
          RebuildMenu;
        end;
      cmWindowMinimizeAll:
        MinimizeAllWindows;
      cmWindowRestoreAll:
        RestoreAllWindows;
      cmWindowCloseAll:
        DoCloseAllPanes;
      cmShowMaxPanes:
        MessageBox(UiText('Maximum 16 panes', 'Maximo 16 paneles'), nil,
          mfInformation or mfOKButton);
      cmSaveSess:
        begin
          // contextual toast: each mode states exactly what was saved
          if ProfileMode then
          begin
            if RememberProfileSelection then
              MessageBox(UiText('Profile selection saved.',
                'Seleccion del perfil guardada.'), nil,
                mfInformation or mfOKButton)
            else
              MessageBox(UiText(
                'The default profile changed in another client; this window selection was not saved.',
                'El perfil por defecto cambio en otro cliente; no se guardo esta seleccion de ventana.'),
                nil, mfInformation or mfOKButton);
          end
          else if RemoteMode then
            // A live session is already its own continuously updated state.
            // Ctrl-S is intentionally a no-op here and is absent from the UI.
            ClearEvent(Event)
          else
          begin
            SaveSessionNow;
            MessageBox(UiText('Session layout saved.',
              'Layout de la sesion guardado.'), nil,
              mfInformation or mfOKButton);
          end;
        end;
      cmSessionWizard: RunSessionWizard;
      cmSessionNew: DoNewSession;
      cmDetach: RequestDetach;
      cmSessionPick: DoSessionPick;
      cmClassPick:
        begin
          ReloadWindowClassCatalog;
          if RunClassPicker(WClasses, i) then
          begin
            if i < 0 then
              DoSplit(sdV, -1)
            else
              DoOpenClassPane(i);
          end;
        end;
      cmClassManage:
        begin
          ReloadWindowClassCatalog;
          for i := 0 to MAX_PANES - 1 do
            if (PaneTerm[i] >= 0) and (PaneTerm[i] < Length(WClasses)) then
              PaneClassNames[i] := WClasses[PaneTerm[i]].Name
            else
              PaneClassNames[i] := '';
          RunClassManager(WClasses);
          for i := 0 to MAX_PANES - 1 do
            PaneTerm[i] := FindClassByName(WClasses, PaneClassNames[i]);
          RebuildMenu;
        end;
      cmProfileNewEmpty:
        begin
          ReloadProfileCatalog;
          ActiveProfileName := '';
          if (ActiveProfile >= 0) and (ActiveProfile < Length(Profiles)) then
            ActiveProfileName := Profiles[ActiveProfile].Name;
          RunNewEmptyProfile(Profiles, CreatedProfileName);
          // Even a duplicate followed by Cancel performs an authoritative
          // reload. Rebind after every return, not only a successful create.
          ActiveProfile := FindProfileByName(Profiles, ActiveProfileName);
          ProfileMode := ProfileMode or (ActiveProfile >= 0);
          RebuildMenu;
        end;
      cmHelp: ShowHelp;
      cmGrowV: begin
        if RemoteMode and (Remote <> nil) and Remote.Connected then
          if not LockRemoteLayout(-1) then
          begin
            ClearEvent(Event);
            Exit;
          end;
        RemoteGeometryDirty := RemoteMode;
        RemoteTreeDirty := RemoteMode;
        if RemoteMode then for i := 0 to MAX_PANES - 1 do
          RemoteGeomDirtyPanes[i] := True;
        Lay.ResizeFocused(sdV, +1); RelayoutAll; SyncRemoteLayout(-1); end;
      cmShrinkV: begin
        if RemoteMode and (Remote <> nil) and Remote.Connected then
          if not LockRemoteLayout(-1) then
          begin
            ClearEvent(Event);
            Exit;
          end;
        RemoteGeometryDirty := RemoteMode;
        RemoteTreeDirty := RemoteMode;
        if RemoteMode then for i := 0 to MAX_PANES - 1 do
          RemoteGeomDirtyPanes[i] := True;
        Lay.ResizeFocused(sdV, -1); RelayoutAll; SyncRemoteLayout(-1); end;
      cmGrowH: begin
        if RemoteMode and (Remote <> nil) and Remote.Connected then
          if not LockRemoteLayout(-1) then
          begin
            ClearEvent(Event);
            Exit;
          end;
        RemoteGeometryDirty := RemoteMode;
        RemoteTreeDirty := RemoteMode;
        if RemoteMode then for i := 0 to MAX_PANES - 1 do
          RemoteGeomDirtyPanes[i] := True;
        Lay.ResizeFocused(sdH, +1); RelayoutAll; SyncRemoteLayout(-1); end;
      cmShrinkH: begin
        if RemoteMode and (Remote <> nil) and Remote.Connected then
          if not LockRemoteLayout(-1) then
          begin
            ClearEvent(Event);
            Exit;
          end;
        RemoteGeometryDirty := RemoteMode;
        RemoteTreeDirty := RemoteMode;
        if RemoteMode then for i := 0 to MAX_PANES - 1 do
          RemoteGeomDirtyPanes[i] := True;
        Lay.ResizeFocused(sdH, -1); RelayoutAll; SyncRemoteLayout(-1); end;
    else
      if (Event.Command >= cmLanguageBase) and
         (Event.Command < cmLanguageBase + 2) then
      begin
        CurrentLanguage := TUiLanguage(Event.Command - cmLanguageBase);
        Cfg.Language := CurrentLanguage;
        SetMessageBoxLanguage(CurrentLanguage = ulSpanish);
        SaveConfigFields(Cfg, [cfLanguage]);
        RebuildMenu;
        RebuildStatusLine;
      end
      else if (Event.Command >= cmProfileBase) and
         (Event.Command < cmProfileBase + ProfileMenuCount) then
      begin
        MenuTargetName := ProfileMenuNames[Event.Command - cmProfileBase];
        ReloadProfileCatalog;
        i := FindProfileByName(Profiles, MenuTargetName);
        if i >= 0 then
          DoSwitchProfile(i);
      end
      else if Event.Command = cmProfileSaveAs then
        RunProfileSaveAs
      else if Event.Command = cmProfileManage then
        DoProfileManage
      else if ProfileMode and (ActiveProfile >= 0) and
         (ActiveProfile < Length(Profiles)) and
         (Length(Profiles[ActiveProfile].Windows) > 0) and
         (Event.Command = cmWindowNext) then
        DoCycleWindow(+1)
      else if ProfileMode and (ActiveProfile >= 0) and
         (ActiveProfile < Length(Profiles)) and
         (Length(Profiles[ActiveProfile].Windows) > 0) and
         (Event.Command = cmWindowPrev) then
        DoCycleWindow(-1)
       else if ProfileMode and (ActiveProfile >= 0) and
          (ActiveProfile < Length(Profiles)) and
          (Event.Command >= cmWindowBase) and
          (Event.Command < cmWindowBase +
           Length(Profiles[ActiveProfile].Windows)) then
         DoSwitchWindow(Event.Command - cmWindowBase)
       else if (Event.Command >= cmWindowRestoreBase) and
          (Event.Command < cmWindowRestoreBase + MAX_PANES) then
         RestoreWindow(Event.Command - cmWindowRestoreBase)
       else if (Event.Command >= cmPaletteBase) and
          (Event.Command <= cmPaletteBase + apMonochrome) then
         ApplyPalette(Event.Command - cmPaletteBase)
       else if (Event.Command >= cmOpenClass) and
         (Event.Command < cmOpenClass + ClassMenuCount) then
       begin
         MenuTargetName := ClassMenuNames[Event.Command - cmOpenClass];
         ReloadWindowClassCatalog;
         i := FindClassByName(WClasses, MenuTargetName);
         if i >= 0 then
           DoOpenClassPane(i);
       end
      else
        Exit;
    end;
    ClearEvent(Event);
  end;
end;

procedure TSuperApp.Idle;
type
  // named so the marks can be cleared with Default(): FillChar takes an
  // untyped var parameter, which the compiler cannot see as initialisation
  TTouchedPanes = array[0..MAX_PANES - 1] of boolean;
var
  fdset: TFDSet;
  tv: TTimeVal;
  maxfd: cint;
  i, n: integer;
  Buf: array[0..MAXREAD - 1] of byte;
  st2: cint;
  p: TPid;
  Tick: cardinal;
  RemoteEvent: TSessionEvent;
  PendingEvent: TEvent;
  SavedSuppress, SavedSettling: boolean;
  // bounded drain of the session socket, so a flooding pane cannot starve
  // the keyboard, plus the marks for the single repaint that follows it
  Drained: integer;
  Deadline: QWord;
  Touched: TTouchedPanes;
  FullRedraw, LocalGestureActive: boolean;
  HostPaste: RawByteString;
  const
    LastTitle: cardinal = 0;
    LastBlink: cardinal = 0;
    LastSizeCheck: cardinal = 0;
    LastLayoutSync: cardinal = 0;

  procedure WaitForActivity(AMaxMs: LongInt);
  var
    PollFds: array[0..MAX_PANES + 2] of TPollFD;
    Count, J, Fd: integer;

    procedure AddFd(AFd: cint; AEvents: cshort);
    var
      K: integer;
    begin
      if (AFd < 0) or (Count > High(PollFds)) then
        Exit;
      for K := 0 to Count - 1 do
        if PollFds[K].fd = AFD then
        begin
          PollFds[K].events := PollFds[K].events or AEvents;
          Exit;
        end;
      PollFds[Count] := Default(TPollFD);
      PollFds[Count].fd := AFD;
      PollFds[Count].events := AEvents;
      Inc(Count);
    end;

  begin
    Count := 0;
    AddFd(StdInputHandle, POLLIN);
    Fd := VideoOutputWaitHandle;
    AddFd(Fd, POLLIN);
    if RemoteMode and (Remote <> nil) then
    begin
      Fd := Remote.WaitHandle;
      if Remote.WantsWrite then
        AddFd(Fd, POLLIN or POLLOUT)
      else
        AddFd(Fd, POLLIN);
    end
    else
      for J := 0 to MAX_PANES - 1 do
        if (Panes[J] <> nil) and Panes[J].Alive then
        begin
          if Panes[J].InputPending then
            AddFd(Panes[J].Master, POLLIN or POLLOUT)
          else
            AddFd(Panes[J].Master, POLLIN);
        end;
    if Count > 0 then
      repeat
        J := fpPoll(@PollFds[0], Count, AMaxMs);
      until (J >= 0) or (fpGetErrNo <> ESysEINTR);
  end;
begin
  HostPaste := '';
  // TProgram.Idle performs these two useful Free Vision duties and then a
  // blind 10 ms nanosleep. Preserve the duties, replace the sleep below with
  // a descriptor-driven wait that wakes immediately for real work.
  if StatusLine <> nil then
    StatusLine^.Update;
  if CommandSetChanged then
  begin
    Message(@Self, evBroadcast, cmCommandSetChanged, nil);
    CommandSetChanged := False;
  end;
  if PumpVideoOutput then
    Video.UpdateScreen(False);
  if VideoOutputHasFailed then
  begin
    DebugLog('video: output reactor failed; closing client cleanly');
    Message(@Self, evCommand, cmQuit, nil);
    Exit;
  end;
  if Current = PView(Desktop) then
    while TakeHostPaste(HostPaste) do
    begin
      if CopyMode then
        EndCopyMode(False);
      AddClipboard(HostPaste, coHostPaste, Lay.Focused, False);
      PasteClipboardText(HostPaste);
    end;
  Tick := GetTickCount64;
  RemoteEvent.Data := nil;
  RemoteEvent.Text := '';
  if Tick - LastSizeCheck >= 250 then
  begin
    LastSizeCheck := Tick;
    SyncTerminalSize;
  end;
  // enter/leave passthrough purely from the focused pane's maximized state
  UpdatePassthrough;
  SyncHostMouse;
  // a local pane's master is non-blocking, so a program that was not reading
  // when input arrived left some of it queued; push it now
  for i := 0 to MAX_PANES - 1 do
    if (Panes[i] <> nil) and Panes[i].Alive and Panes[i].InputPending then
      Panes[i].FlushInput;
  // Never use waitpid(-1) here: this process can have created panes now owned
  // by an older detached daemon. Only the daemon's reap-safe event retires
  // that numeric group identity before its real parent collects the child.
  if RemoteMode then
  begin
    // with a modal open the socket is not drained: events (closing or
    // creating panes, output) wait in order for the modal to finish,
    // so pane indexes never desync in the middle of a dialog
    // BOUND THIS LOOP. A pane under a flood (think 'ls -R /') keeps the
    // socket readable on every single poll, and each turn of the body parses
    // 64 KB and repaints, which is slower than the daemon produces -- so the
    // loop never ran dry and never returned. FreeVision only reads the
    // keyboard AFTER Idle returns, so the whole interface went dead: no keys,
    // no mouse, no menu, and Ctrl-C never even reached the pane. Take a
    // bounded batch and come back next tick; the daemon queues the rest and
    // throttles the pane if we genuinely fall behind.
    if Current = PView(Desktop) then
    begin
      Drained := 0;
      Deadline := GetTickCount64 + 20;
      Touched := Default(TTouchedPanes);
      FullRedraw := False;
      while (Remote <> nil) and (Drained < 32) and
            (GetTickCount64 < Deadline) and Remote.Poll(RemoteEvent) do
      begin
        Inc(Drained);
      case RemoteEvent.Kind of
        sekOutput:
          if (RemoteEvent.Pane >= 0) and (RemoteEvent.Pane < MAX_PANES) and
             (Length(RemoteEvent.Data) > 0) then
          begin
            if PassthroughActive and (RemoteEvent.Pane = PassPane) then
            begin
              // Keep a mirror for copy mode while preserving raw passthrough.
              if Scr[RemoteEvent.Pane] <> nil then
              begin
                Scr[RemoteEvent.Pane].WriteBytes(RemoteEvent.Data[0],
                  Length(RemoteEvent.Data));
                DrainPaneOsc52(RemoteEvent.Pane, True);
              end;
              PassthroughFiltered(RemoteEvent.Data[0], Length(RemoteEvent.Data));
            end
            else if Scr[RemoteEvent.Pane] <> nil then
            begin
              Scr[RemoteEvent.Pane].WriteBytes(RemoteEvent.Data[0],
                Length(RemoteEvent.Data));
              DrainPaneOsc52(RemoteEvent.Pane, False);
              // mark, do not draw: one repaint after the batch instead of one
              // per 64 KB frame, each of which is a blocking write to the tty
              Touched[RemoteEvent.Pane] := True;
            end;
          end;
        sekExit:
          begin
            if PassthroughActive and (RemoteEvent.Pane = PassPane) then
              ExitPassthrough;   // the app died: reclaim the screen
            if (RemoteEvent.Pane >= 0) and (RemoteEvent.Pane < MAX_PANES) and
               (Win[RemoteEvent.Pane] <> nil) then
              Win[RemoteEvent.Pane]^.SetTitle(UiText(' EXITED', ' TERMINO'));
          end;
        sekError:
          begin
            DebugLog('remote session error: ' + RemoteEvent.Text);
            // The local 16-pane preflight gives immediate feedback in the
            // usual case.  The daemon remains authoritative: two clients can
            // both observe 15 and enqueue creation together, so the loser
            // must also surface the serialized server rejection instead of
            // dropping it into the debug log.
            if SameText(Trim(RemoteEvent.Text), 'max panes') then
            begin
              // MessageBox is modal and cannot safely run inside Idle's
              // socket-drain loop. FreeVision's PutEvent stores one pending
              // event which the next ordinary HandleEvent dispatches after
              // Idle returns; duplicate max errors in this batch coalesce.
              PendingEvent := Default(TEvent);
              PendingEvent.What := evCommand;
              PendingEvent.Command := cmShowMaxPanes;
              PutEvent(PendingEvent);
            end;
          end;
        sekHostSummaryEv:
          ApplyRemoteHostSummaryEv(RemoteEvent.Data);
        sekLayoutPreviewEv:
          begin
            if ApplyRemoteLayoutPreviewEv(RemoteEvent.Pane,
                 RemoteEvent.Data, FullRedraw) then
              Touched := Default(TTouchedPanes);
            // Visual steps flush themselves. CLEAR holds the last visual
            // unchanged until its canonical event, even if the drain budget
            // splits the adjacent wire frames across two Idle iterations.
          end;
        sekLayoutEv:
          begin
            ApplyRemoteLayoutEv(RemoteEvent.Data);
            // panes were renumbered: a stale mark would repaint the wrong one
            Touched := Default(TTouchedPanes);
            FullRedraw := True;
          end;
        sekLayoutPeerEv:
          begin
            // Apply canonical changes made by other pane owners without
            // advancing this client's older lease base or relocating its
            // in-flight local gesture.
            ApplyRemoteLayoutEv(RemoteEvent.Data, True, RemoteEvent.Pane);
            Touched := Default(TTouchedPanes);
            FullRedraw := True;
          end;
        sekKillPaneEv:
          begin
            if RemoteEvent.Pane = -1 then
            begin
              // Close all is one wire event and one visual transaction. Work
              // backwards so array compaction never renumbers a survivor.
              SavedSuppress := SuppressFlush;
              SuppressFlush := True;
              try
                while PaneCount > 0 do
                  ApplyRemoteKillPane(PaneCount - 1);
              finally
                SuppressFlush := SavedSuppress;
              end;
            end
            else
              ApplyRemoteKillPane(RemoteEvent.Pane);
            // panes were renumbered: a stale mark would repaint the wrong one
            Touched := Default(TTouchedPanes);
            ResetSizeRequests;   // panes were renumbered: the requests name the wrong ones
            FullRedraw := True;
          end;
        sekNewPaneEv:
          begin
            // A NEWPANE event is authoritative server state.  Constructing
            // its FreeVision window selects it internally; without this guard
            // that incidental selection was sent back as a fresh shared-focus
            // command and could overtake a later explicit CLI/client focus.
            // Layout events already use the same settling guard.
            SavedSettling := RemoteAttachSettling;
            SavedSuppress := SuppressFlush;
            RemoteAttachSettling := True;
            SuppressFlush := True;
            try
              ApplyRemoteNewPane(RemoteEvent.Data);
            finally
              SuppressFlush := SavedSuppress;
              RemoteAttachSettling := SavedSettling;
            end;
            // panes were renumbered: a stale mark would repaint the wrong one
            Touched := Default(TTouchedPanes);
            ResetSizeRequests;   // panes were renumbered: the requests name the wrong ones
            FullRedraw := True;
          end;
        sekResizeEv: ApplyRemoteResize(RemoteEvent.Pane, RemoteEvent.Data);
        sekTitleEv: ApplyRemoteTitle(RemoteEvent.Pane, RemoteEvent.Data);
        sekFocusEv:
          if (RemoteEvent.Pane >= 0) and (RemoteEvent.Pane < MAX_PANES) and
             (Win[RemoteEvent.Pane] <> nil) then
          begin
            RemoteSharedFocus := RemoteEvent.Pane;
            RemoteAttachSettling := True;
            try
              FocusPane(RemoteEvent.Pane);
            finally
              RemoteAttachSettling := False;
            end;
            RemoteLayoutHash := ComputeLayoutHash;
            // SetCurrent changes the FreeVision selection immediately, but
            // a focus-only server frame has no pane output/layout event to
            // make the batched remote loop flush the changed frames.  With
            // three windows this left the visible active border one focus
            // operation behind the daemon.  Paint once at the end of this
            // batch, just like a layout event; never paint from inside the
            // socket parser.
            FullRedraw := True;
          end;
        sekIgnore: ;
        sekShutdown:
          begin
            RemoteLost := True;
            RemoteMode := False;
            RemoteHostSizeArmed := False;
            RemoteHostSummaryValid := False;
            RemoteMembershipReady := False;
            ResetRemotePreviewState;
            ResetRemoteZoomState;
            SkipSave := True;
            MessageBox(UiText('The session was closed.',
              'La sesion se cerro.'), nil, mfInformation or mfOKButton);
            Message(@Self, evCommand, cmQuit, nil);
          end;
        sekLost:
          begin
            RemoteLost := True;
            RemoteMode := False;
            RemoteHostSizeArmed := False;
            RemoteHostSummaryValid := False;
            RemoteMembershipReady := False;
            ResetRemotePreviewState;
            ResetRemoteZoomState;
            // flag before the MessageBox: nothing from this instance must
            // be saved (the layout belongs to the lost remote session)
            SkipSave := True;
            MessageBox(UiText('Connection to the session was lost.',
              'Se perdio la conexion con la sesion.'), nil,
              mfError or mfOKButton);
            Message(@Self, evCommand, cmQuit, nil);
          end;
      end;
        if not RemoteMode then
          Break;   // shutdown/lost: stop draining
      end;
      // ONE repaint for the whole batch. Doing it per frame meant a full
      // pane redraw and a blocking write to the terminal for every 64 KB the
      // pane produced, which over SSH is a round trip each -- that is what
      // turned a flood from slow into completely unresponsive.
      if RemoteMode then
      begin
        if FullRedraw then
          RepaintChanges
        else
          for i := 0 to MAX_PANES - 1 do
            if Touched[i] and (Win[i] <> nil) and (Win[i]^.Term <> nil) then
              RepaintPane(i);
        // Restore animations start only after the ACK's settled IDE frame is
        // physically visible. Drawing them earlier would overlay rings on a
        // stale raw surface or expose an intermediate geometry.
        if RemoteZoomContractPending and (not PassthroughActive) then
          FinishRemoteZoomAnimation;
      end;
    end;
    UpdateMemberNotices(GetTickCount64);
    if RemoteMode and RemoteZoomPending and
       (Tick - RemoteZoomSentTick >= 2500) then
    begin
      if DebugActive then
        DebugLog('remote-zoom: acknowledgement timeout; proposal cancelled');
      ResetRemoteZoomState;
    end;
    LocalGestureActive := False;
    for i := 0 to MAX_PANES - 1 do
      if (Win[i] <> nil) and Win[i]^.GetState(sfDragging) then
      begin
        LocalGestureActive := True;
        Break;
      end;
    // Debounced shared-layout push. The daemon orders and echoes one
    // authoritative state to every client. Never turn a modal pane lease into
    // a zero-change global commit while its mouse button is still held.
    if RemoteMode and (Current = PView(Desktop)) and
       (not LocalGestureActive) and
       (Tick - LastLayoutSync >= 400) then
    begin
      LastLayoutSync := Tick;
      if ComputeLayoutHash <> RemoteLayoutHash then
        SyncRemoteLayout;
    end;
    if Tick - LastBlink >= 530 then
    begin
      LastBlink := Tick;
      CursorPhase := not CursorPhase;
      i := Lay.Focused;
      // TTermView.Draw also updates FreeVision's hardware-cursor state.
      // Even though the video framebuffer flush is suppressed in raw mode,
      // that cursor path can emit a relative movement (for example ESC[3B)
      // on top of the pane's output. The application owns the cursor too.
      if (not PassthroughActive) and
         (i >= 0) and (i < MAX_PANES) and (Win[i] <> nil) and
         (Win[i]^.Term <> nil) then
        RepaintPane(i);
    end;
    WaitForActivity(10);
    Exit;
  end;
  // poll ptys
  maxfd := -1;
  fpFD_ZERO(fdset);
  for i := 0 to MAX_PANES - 1 do
    if (Panes[i] <> nil) and Panes[i].Alive then
    begin
      fpFD_SET(Panes[i].Master, fdset);
      if Panes[i].Master > maxfd then
        maxfd := Panes[i].Master;
    end;
  if maxfd >= 0 then
  begin
    tv.tv_sec := 0;
    tv.tv_usec := 0;
    if fpSelect(maxfd + 1, @fdset, nil, nil, @tv) > 0 then
      for i := 0 to MAX_PANES - 1 do
        if (Panes[i] <> nil) and Panes[i].Alive and
           (fpFD_ISSET(Panes[i].Master, fdset) <> 0) then
        begin
          n := Panes[i].ReadBuf(Buf);
          DebugLog(Format('poll pane=%d master=%d n=%d', [i, Panes[i].Master, n]));
          if n > 0 then
          begin
            if PassthroughActive and (i = PassPane) then
            begin
              Scr[i].WriteBytes(Buf, n);
              DrainPaneOsc52(i, True);
              PassthroughFiltered(Buf[0], n);
            end
            else
            begin
              Scr[i].WriteBytes(Buf, n);
              DrainPaneOsc52(i, False);
              if Win[i] <> nil then
                RepaintPane(i);
            end;
          end
          else if (n = 0) or (fpgeterrno <> ESysEAGAIN) then
          begin
            if PassthroughActive and (i = PassPane) then
              ExitPassthrough;
            Panes[i].MarkDead;
          end;
        end;
  end
  else ;
  // Reap only leaders owned by the current local workspace. waitpid(-1)
  // could collect a child whose PTY was transferred to an older daemon and
  // make that daemon's still-stored PGID reusable before it observes EOF.
  for i := 0 to MAX_PANES - 1 do
    if (Panes[i] <> nil) and (Panes[i].Pid > 1) then
    begin
      st2 := Default(cint);
      repeat
        p := fpWaitPid(Panes[i].Pid, st2, WNOHANG);
      until (p >= 0) or (FpGetErrNo <> ESysEINTR);
      if p = Panes[i].Pid then
      begin
        Panes[i].MarkExited;
        if (PaneTerm[i] >= 0) and
           (PaneTerm[i] < Length(WClasses)) and
           (WClasses[PaneTerm[i]].Kind = wcSSH) then
          FallbackPane(i)
        else if Win[i] <> nil then
          Win[i]^.SetTitle(UiText(' EXITED', ' TERMINO'));
      end;
    end;
  // blinking cursor of the focused pane
  if Tick - LastBlink >= 530 then
  begin
    LastBlink := Tick;
    CursorPhase := not CursorPhase;
    i := Lay.Focused;
    if (not PassthroughActive) and
       (i >= 0) and (i < MAX_PANES) and (Win[i] <> nil) and
       (Win[i]^.Term <> nil) then
      RepaintPane(i);
  end;
  // periodic titles
  if Tick - LastTitle > 1500 then
  begin
    LastTitle := Tick;
    for i := 0 to MAX_PANES - 1 do
      if (Panes[i] <> nil) and Panes[i].Alive and (Win[i] <> nil) and
          (PaneTerm[i] = -1) and (not Win[i]^.TitleFixed) then
      begin
        Panes[i].QueryState;
        if Panes[i].TitleCmd <> '' then
          Win[i]^.SetTitle(' ' + Copy(ExtractFileName(
            FirstWord(Panes[i].TitleCmd)), 1, 24))
        else if Panes[i].TitleCwd <> '' then
          Win[i]^.SetTitle(' ' + Copy(ExtractFileName(Panes[i].TitleCwd), 1, 24));
      end;
  end;
  WaitForActivity(10);
end;

// informational menu row: always gray, never dispatchable (TV
// command sets only cover 0..255, so the item is marked directly)
function NewInfoItem(const AText, AParam: string; ANext: PMenuItem): PMenuItem;
begin
  Result := NewItem(AText, AParam, kbNoKey, cmInfoRow, hcNoContext, ANext);
  if Result <> nil then
    Result^.Disabled := True;
end;


{ ---- desktop background: ASCII art behind the windows ---- }

// Nearest of the 16 VGA colours, for the CP437 fallback the chrome path uses
// when a cell is not carried by the rich renderer.
function Vga16FromRgb(C: LongWord): byte;
var
  r, g, b, m: integer;
begin
  r := (C shr 16) and $FF;
  g := (C shr 8) and $FF;
  b := C and $FF;
  m := r;
  if g > m then m := g;
  if b > m then m := b;
  Result := 0;
  if r > m div 2 then Result := Result or 4;   // VGA red bit
  if g > m div 2 then Result := Result or 2;
  if b > m div 2 then Result := Result or 1;
  if m > 160 then Result := Result or 8;       // bright
  if m < 40 then Result := 0;
end;

// CP437 byte that looks closest to a picture glyph, so the 16-colour grid
// still shows the shape when a cell does not reach the rich renderer.
function Cp437ForGlyph(const G: RawByteString): byte;
begin
  Result := Ord(' ');
  if G = '' then
    Exit;
  if Length(G) = 1 then
    Exit(byte(G[1]));
  if G = #$E2#$96#$80 then Result := 223       // upper half block
  else if G = #$E2#$96#$84 then Result := 220  // lower half block
  else if G = #$E2#$96#$88 then Result := 219  // full block
  else if G = #$E2#$96#$91 then Result := 176  // light shade
  else if G = #$E2#$96#$92 then Result := 177  // medium shade
  else if G = #$E2#$96#$93 then Result := 178  // dark shade
  else Result := Ord('.');
end;

// The desktop behind the windows, painted black.
//
// FreeVision's own background is the classic blue field of dotted shade. A
// picture drawn on top of that had the blue showing through everywhere the
// picture did not reach, and the pictures themselves are photographic: they
// belong on a plain ground, the way a screen border does. So the desktop is
// one flat colour -- black unless the user picked another in
// Options > Desktop colour -- with a picture or without one, and the empty
// cells of a picture take that same colour rather than blue dots.
const
  // U+2588 as UTF-8, and the CP437 code for it
  FULL_BLOCK = #$E2#$96#$88;
  CP437_FULL_BLOCK = 219;

function TArtBackground.DeskAttr: byte;
var
  App: PSuperApp;
begin
  App := PSuperApp(Application);
  if App = nil then
    Exit(0);
  DeskAttr := byte((App^.Cfg.DesktopColor and $0F) shl 4);
end;

procedure TArtBackground.FillDesk(AStartX, AStartY, AWidth,
  AHeight: integer);
var
  B: TDrawBuffer;
  y: integer;
begin
  if (AWidth <= 0) or (AHeight <= 0) then
    Exit;
  B := Default(TDrawBuffer);
  MoveChar(B, ' ', DeskAttr, AWidth);
  for y := AStartY to AStartY + AHeight - 1 do
    WriteLine(AStartX, y, AWidth, 1, B);
end;

procedure TArtBackground.Draw;
var
  B: TDrawBuffer;
  x, y, FrontN, X0, Y0, X1, Y1, VX, VY: integer;
  App: PSuperApp;
  Idx: integer;
  Mode: TArtMode;
  C: TArtCell;
  Attr: byte;
  W: integer;
  GOrig: Objects.TPoint;
  Word0: word;
  PW, MyView: PView;
  FrontR: array of Objects.TRect;

  function CoveredByFrontView(AGlobalX, AGlobalY: integer): boolean;
  var
    I: integer;
  begin
    Result := False;
    for I := 0 to FrontN - 1 do
      if (AGlobalX >= FrontR[I].A.X) and
         (AGlobalX < FrontR[I].B.X) and
         (AGlobalY >= FrontR[I].A.Y) and
         (AGlobalY < FrontR[I].B.Y) then
        Exit(True);
  end;
begin
  FrontR := nil;
  App := PSuperApp(Application);
  // With no picture this must cost exactly what it cost before the feature
  // existed: one string compare and the ancestor's single WriteLine. Nothing
  // is looked up, nothing is registered, no per-cell work happens at all.
  W := Size.X;
  if W > MaxViewWidth then
    W := MaxViewWidth;
  if W < 0 then
    W := 0;
  X0 := 0;
  Y0 := 0;
  X1 := W;
  Y1 := Size.Y;
  if (App <> nil) and (App^.ViewportW > 0) and (App^.ViewportH > 0) then
  begin
    X0 := App^.ViewportX;
    Y0 := App^.ViewportY;
    X1 := X0 + App^.ViewportW;
    Y1 := Y0 + App^.ViewportH;
    if X0 < 0 then X0 := 0;
    if Y0 < 0 then Y0 := 0;
    if X1 > W then X1 := W;
    if Y1 > Size.Y then Y1 := Size.Y;
  end;
  VX := X1 - X0;
  VY := Y1 - Y0;
  if (VX <= 0) or (VY <= 0) then
    Exit;
  if (App = nil) or (App^.Cfg.Background = '') or
     (App^.Cfg.Background = 'none') then
  begin
    // With no picture this costs exactly what the ancestor cost: one filled
    // buffer and one WriteLine per row, nothing looked up or registered.
    FillDesk(X0, Y0, VX, VY);
    Exit;
  end;
  Idx := ArtIndexOf(App^.Cfg.Background);
  // Clear first: this covers the view's whole extent, so nothing of a
  // previous layout can survive in a row the picture does not reach.
  FillDesk(X0, Y0, VX, VY);
  if Idx <= 0 then
    Exit;                // name not found on disk: a plain desktop
  Mode := ArtModeOf(App^.Cfg.BackgroundMode);
  GOrig.X := 0;
  GOrig.Y := 0;
  MakeGlobal(GOrig, GOrig);
  // Rich entries are not clipped by FreeVision's WriteLine machinery. Record
  // every visible sibling in front of the background so this draw updates only
  // exposed desktop cells. Without this, a focus repaint replaced both panes'
  // truecolor entries with the artwork before WriteLine clipped the artwork,
  // and the pane that lost focus fell back to its gray 16-color oracle.
  FrontN := 0;
  MyView := @Self;
  if Owner <> nil then
  begin
    PW := Owner^.First;
    while (PW <> nil) and (PW <> MyView) do
    begin
      if PW^.GetState(sfVisible) then
        Inc(FrontN);
      PW := PW^.NextView;
    end;
    SetLength(FrontR, FrontN);
    FrontN := 0;
    PW := Owner^.First;
    while (PW <> nil) and (PW <> MyView) do
    begin
      if PW^.GetState(sfVisible) then
      begin
        FrontR[FrontN].A.X := GOrig.X - Origin.X + PW^.Origin.X;
        FrontR[FrontN].A.Y := GOrig.Y - Origin.Y + PW^.Origin.Y;
        FrontR[FrontN].B.X := FrontR[FrontN].A.X + PW^.Size.X;
        FrontR[FrontN].B.Y := FrontR[FrontN].A.Y + PW^.Size.Y;
        Inc(FrontN);
      end;
      PW := PW^.NextView;
    end;
  end;
  // Nothing registered on exposed desktop ground by a previous layout may
  // survive. Covered cells still belong to their pane or dialog.
  for y := Y0 to Y1 - 1 do
    for x := X0 to X1 - 1 do
      if not CoveredByFrontView(GOrig.X + x, GOrig.Y + y) then
        RichClear(GOrig.X + x, GOrig.Y + y);
  for y := Y0 to Y1 - 1 do
  begin
    B := Default(TDrawBuffer);
    for x := X0 to X1 - 1 do
    begin
      C := ArtCellFor(Idx, Mode, W, Size.Y, x, y);
      if C.Glyph = '' then
      begin
        // Empty cell: black, and NOT registered in the overlay. A background
        // covers the whole desktop, so registering every empty cell filled
        // the overlay with entries that a later layout could match by
        // coincidence and resurrect as a stale glyph.
        Word0 := (word(DeskAttr) shl 8) or word(' ');
        B[x - X0] := Word0;
        if not CoveredByFrontView(GOrig.X + x, GOrig.Y + y) then
          RichClear(GOrig.X + x, GOrig.Y + y);
      end
      else
      begin
        // A cell painted whole is drawn as a SPACE on a coloured background,
        // never as a full block glyph in that colour. They should look the
        // same and do not: the block comes from the terminal's font, and a
        // font whose U+2588 does not quite fill its cell -- most of them, once
        // the terminal stretches or hints it -- leaves hairlines between one
        // cell and the next, which is what a picture drawn out of them looks
        // blurred by. A background colour is painted by the terminal itself
        // and covers the cell exactly, whatever the font is doing.
        // The GRID always gets the full block, whatever the picture is
        // drawn with. That word is the overlay's oracle -- what says a cell
        // is still the picture's -- so it has to be a word nothing else on
        // this screen writes. "A space in some attribute" is written by every
        // dialog and menu; the shade characters are written by every
        // scrollbar trough, which is where a picture last showed through the
        // body of a dialog, in colour, at exactly the column its scrollbar
        // was in. The block is written by nobody, and the terminal never sees
        // it: the overlay below says what is actually emitted.
        Attr := Vga16FromRgb(C.Fg);
        if (C.Bg <> 0) and (C.Glyph <> FULL_BLOCK) then
          Attr := Attr or (Vga16FromRgb(C.Bg) shl 4);
        Word0 := (word(Attr) shl 8) or word(CP437_FULL_BLOCK);
        B[x - X0] := Word0;
        if CoveredByFrontView(GOrig.X + x, GOrig.Y + y) then
          Continue
        else if C.Glyph = FULL_BLOCK then
          // a cell painted whole goes out as a SPACE on a coloured
          // background: the terminal fills that exactly, where a block glyph
          // is only as solid as the font's idea of it
          RichSetCell(GOrig.X + x, GOrig.Y + y, ' ', 0, C.Fg, 0,
            Word0, False, False, True)
        else
          RichSetCell(GOrig.X + x, GOrig.Y + y, C.Glyph, C.Fg, C.Bg, 0,
            Word0, False, False, True);
      end;
    end;
    WriteLine(X0, y, VX, 1, B);
  end;
end;

procedure TArtDesktop.InitBackground;
var
  R: Objects.TRect;
begin
  R := Default(Objects.TRect);
  GetExtent(R);
  Background := New(PArtBackground, Init(R, ' '));
end;

function TArtDesktop.ExecView(P: PView): word;
var
  App: PSuperApp;
  R: Objects.TRect;
  X, Y, W, H, DeskW, DeskH: integer;
  SavedOptions: word;
begin
  App := PSuperApp(Application);
  if (P <> nil) and (App <> nil) and
     (App^.ViewportW > 0) and (App^.ViewportH > 0) then
  begin
    R := Default(Objects.TRect);
    P^.GetBounds(R);
    W := R.B.X - R.A.X;
    H := R.B.Y - R.A.Y;
    DeskW := Size.X;
    DeskH := Size.Y;
    if W > App^.ViewportW then
      // Keep the dialog's controls and title origin visible. Aligning its far
      // edge instead put the left side outside a scrolled small client.
      X := App^.ViewportX
    else
    begin
      X := App^.ViewportX + (App^.ViewportW - W) div 2;
      if X < App^.ViewportX then X := App^.ViewportX;
      if X + W > App^.ViewportX + App^.ViewportW then
        X := App^.ViewportX + App^.ViewportW - W;
      if X < 0 then X := 0;
      if (W <= DeskW) and (X + W > DeskW) then X := DeskW - W;
    end;
    if H > App^.ViewportH then
      Y := App^.ViewportY
    else
    begin
      Y := App^.ViewportY + (App^.ViewportH - H) div 2;
      if Y < App^.ViewportY then Y := App^.ViewportY;
      if Y + H > App^.ViewportY + App^.ViewportH then
        Y := App^.ViewportY + App^.ViewportH - H;
      if Y < 0 then Y := 0;
      if (H <= DeskH) and (Y + H > DeskH) then Y := DeskH - H;
    end;
    R.Assign(X, Y, X + W, Y + H);
    P^.Locate(R);
  end;
  if P = nil then
    Exit(inherited ExecView(P));
  // TGroup.InsertBefore reapplies ofCenterX/ofCenterY when ExecView inserts a
  // detached dialog. Keep the caller's option for reuse, but suppress that
  // second centering while our viewport-aware rectangle is modal.
  SavedOptions := P^.Options;
  P^.Options := SavedOptions and (not ofCentered);
  try
    Result := inherited ExecView(P);
  finally
    P^.Options := SavedOptions;
  end;
end;

procedure TSuperApp.InitDeskTop;
var
  R: Objects.TRect;
begin
  // Same geometry as TProgram.InitDeskTop: the edges are only pulled in when
  // the bar in question actually exists. Trimming unconditionally left the
  // desktop the wrong size and cells stale after a resize.
  R := Default(Objects.TRect);
  GetExtent(R);
  if MenuBar <> nil then
    Inc(R.A.Y);
  if StatusLine <> nil then
    Dec(R.B.Y);
  Desktop := New(PArtDesktop, Init(R));
end;

procedure TSuperApp.InitMenuBar;
var
  R: Objects.TRect;
  MPanes, MWindows, MDesktop, MClipboard, MClasses, MProfiles, MSessMenu,
    MOptions, MHelp: PMenu;
  Chain: PMenuItem;
  PaneItems, WindowItems, DesktopItems, ClipboardItems, ClassItems,
    ProfileItems, SessItems, LanguageItems: PMenuItem;
  i, Num, Idx: integer;
  TitleS, ProfileTopTitle, SessionTopTitle, OptionsTopTitle: string;
  HasProfiles: boolean;
  PaletteItems: PMenuItem;
  BgItems, BgModeItems: PMenuItem;
  AM: TArtMode;
begin
  R := Default(Objects.TRect);
  GetExtent(R);
  R.B.Y := R.A.Y + 1;
  MenuCompact := CompactTopMenuFor(R.B.X - R.A.X);
  if MenuCompact then
  begin
    if CurrentLanguage = ulSpanish then
    begin
      ProfileTopTitle := 'Pe~r~f.';
      SessionTopTitle := '~S~es.';
      OptionsTopTitle := '~O~pc.';
    end
    else
    begin
      ProfileTopTitle := 'P~r~of.';
      SessionTopTitle := '~S~ess.';
      OptionsTopTitle := '~O~pts.';
    end;
  end
  else
  begin
    ProfileTopTitle := UiText('P~r~ofiles', 'Pe~r~files');
    SessionTopTitle := UiText('~S~essions', '~S~esiones');
    OptionsTopTitle := UiText('~O~ptions', '~O~pciones');
  end;

  // ---- Panes: tile operations (split, focus, zoom, min, size) ----
  PaneItems := nil;
  // Closing the last window leaves an empty desktop now, so leaving has to be
  // something you ask for. It is on the Sessions menu too; this is where the
  // hand already is after closing panes.
  PaneItems := NewItem(UiText('E~x~it superterm', 'Sa~l~ir de superterm'),
    'Alt-X', kbAltX, cmQuit, hcNoContext, PaneItems);
  PaneItems := NewLine(PaneItems);
  PaneItems := NewItem(UiText('Rename t~i~tle...', 'Renombrar t~i~tulo...'),
    '', kbNoKey, cmRenameWindow, hcNoContext, PaneItems);
  PaneItems := NewLine(PaneItems);
  PaneItems := NewItem(UiText('~S~horter', 'Meno~s~ alto'), PrefixKeyLabel(Cfg.PrefixKey) + ' ' + #24,
    kbNoKey, cmShrinkH, hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('~T~aller', 'Mas a~l~to'), PrefixKeyLabel(Cfg.PrefixKey) + ' ' + #25,
    kbNoKey, cmGrowH, hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('Narrow~e~r', 'M~e~nos ancho'), PrefixKeyLabel(Cfg.PrefixKey) + ' ' + #27,
    kbNoKey, cmShrinkV, hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('~W~ider', 'Mas ~a~ncho'), PrefixKeyLabel(Cfg.PrefixKey) + ' ' + #26,
    kbNoKey, cmGrowV, hcNoContext, PaneItems);
  PaneItems := NewLine(PaneItems);
  PaneItems := NewItem(UiText('M~o~ve/resize', 'M~o~ver/tamano'), 'Ctrl-F5',
    kbCtrlF5, cmResize, hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('Set PT~Y~ to this window',
    'Ajustar PT~Y~ a esta ventana'), '', kbNoKey,
    cmFitSessionSize, hcNoContext, PaneItems);
  for i := MAX_PANES - 1 downto 0 do
    if (Win[i] <> nil) and Win[i]^.Minimized then
    begin
      TitleS := Trim(Win[i]^.GetTitle(24));
      if TitleS = '' then
        TitleS := UiText('pane ', 'panel ') + IntToStr(i + 1);
      Chain := NewItem(Format(UiText('Restore %d %s', 'Restaurar %d %s'),
        [i + 1, Copy(TitleS, 1, 16)]), '', kbNoKey,
        cmWindowRestoreBase + i, hcNoContext, PaneItems);
      if Chain <> nil then
        PaneItems := Chain;
    end;
  PaneItems := NewItem(UiText('~M~inimize', '~M~inimizar'), 'Alt-F9',
    kbAltF9, cmWindowMinimize, hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('~F~ull screen', '~P~antalla completa'),
    PrefixKeyLabel(Cfg.PrefixKey) + ' f', kbNoKey, cmFullScreen,
    hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('Ma~x~imize/restore', 'Ma~x~imizar/restaurar'),
    '', kbNoKey, cmZoom, hcNoContext, PaneItems);
  PaneItems := NewLine(PaneItems);
  PaneItems := NewInfoItem(UiText('Go to pane 1-9', 'Ir al panel 1-9'),
    'Alt-1..9', PaneItems);
  PaneItems := NewItem(UiText('~P~revious pane', 'Panel an~t~erior'), 'F7',
    kbF7, cmPanePrev, hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('~N~ext pane', 'Siguie~n~te panel'), 'F6',
    kbF6, cmPaneNext, hcNoContext, PaneItems);
  PaneItems := NewLine(PaneItems);
  PaneItems := NewItem(UiText('~C~lose pane', '~C~errar panel'), 'Alt-F3',
    kbAltF3, cmPaneClose, hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('Split ~h~orizontal', 'Dividir ~h~orizontal'),
    'F3', kbF3, cmSplitH, hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('Split ~v~ertical', 'Dividir ~v~ertical'),
    'F2', kbF2, cmSplitV, hcNoContext, PaneItems);
  MPanes := NewMenu(PaneItems);

  // ---- Windows: only workspace navigation of the active profile ----
  WindowItems := nil;
  if ProfileMode and (ActiveProfile >= 0) and
     (ActiveProfile < Length(Profiles)) then
  begin
    for i := Length(Profiles[ActiveProfile].Windows) - 1 downto 0 do
      if Profiles[ActiveProfile].Windows[i].Enabled then
      begin
        Chain := NewItem(ActiveMark(i = ActiveWindow) +
          Copy(Profiles[ActiveProfile].Windows[i].Name, 1, 22),
          PrefixKeyLabel(Cfg.PrefixKey) + ' ' + IntToStr(i + 1), kbNoKey,
          cmWindowBase + i, hcNoContext, WindowItems);
        if Chain <> nil then
          WindowItems := Chain;
      end;
    if WindowItems <> nil then
      WindowItems := NewLine(WindowItems);
    WindowItems := NewItem(UiText('~P~revious window', 'Ventana an~t~erior'),
      'F9', kbF9, cmWindowPrev, hcNoContext, WindowItems);
    WindowItems := NewItem(UiText('~N~ext window', 'Siguie~n~te ventana'),
      'F8', kbF8, cmWindowNext, hcNoContext, WindowItems);
  end
  else
    WindowItems := NewInfoItem(UiText('(no profile active)',
      '(sin perfil activo)'), '', nil);
  // whole-workspace visibility and arrangement (classic IDE Window menu)
  WindowItems := NewLine(WindowItems);
  WindowItems := NewItem(UiText('~R~estore all windows',
    '~R~estaurar todas las ventanas'), '', kbNoKey, cmWindowRestoreAll,
    hcNoContext, WindowItems);
  WindowItems := NewItem(UiText('Minimize ~a~ll windows',
    'Minimizar to~d~as las ventanas'), '', kbNoKey, cmWindowMinimizeAll,
    hcNoContext, WindowItems);
  WindowItems := NewItem(UiText('~C~lose all windows',
    '~C~errar todas las ventanas'), '', kbNoKey, cmWindowCloseAll,
    hcNoContext, WindowItems);
  WindowItems := NewLine(WindowItems);
  WindowItems := NewItem(UiText('Re~f~resh display', 'Re~f~rescar pantalla'),
    '', kbNoKey, cmRedrawAll, hcNoContext, WindowItems);
  WindowItems := NewItem(UiText('~L~ist...', '~L~ista...'), 'Alt-0', kbAlt0,
    cmPaneList, hcNoContext, WindowItems);
  WindowItems := NewItem(UiText('Cascad~e~', 'Cascad~a~'), '', kbNoKey,
    cmPaneCascade, hcNoContext, WindowItems);
  WindowItems := NewItem(UiText('~O~rganize', '~O~rganizar'), '', kbNoKey,
    cmPaneOrganize, hcNoContext, WindowItems);
  WindowItems := NewItem(UiText('~T~ile', '~M~osaico'), '', kbNoKey,
    cmPaneTile, hcNoContext, WindowItems);
  MWindows := NewMenu(WindowItems);

  // ---- Desktop: one canonical shared work area, changed only explicitly ----
  DesktopItems := NewItem(UiText('~S~how current dimensions...',
    '~M~ostrar dimensiones actuales...'), '', kbNoKey,
    cmDesktopShowSize, hcNoContext, nil);
  DesktopItems := NewItem(ActiveMark(Cfg.DesktopNotifications) +
    UiText('Show desktop ~n~otifications',
           'Mostrar ~n~otificaciones del escritorio'), '', kbNoKey,
    cmToggleDesktopNotifications, hcNoContext, DesktopItems);
  DesktopItems := NewItem(UiText('~M~odify dimensions...',
    'Modificar ~d~imensiones...'), '', kbNoKey,
    cmDesktopModify, hcNoContext, DesktopItems);
  DesktopItems := NewItem(UiText('~A~djust to this terminal size',
    '~A~justar al tamano de este terminal'), '', kbNoKey,
    cmDesktopFitTerminal, hcNoContext, DesktopItems);
  MDesktop := NewMenu(DesktopItems);

  // ---- Clipboard: copy mode and the ten client-local history entries ----
  ClipboardItems := NewItem(UiText('~C~lear history...',
    '~B~orrar historial...'), '', kbNoKey, cmClipboardClear,
    hcNoContext, nil);
  ClipboardItems := NewLine(ClipboardItems);
  ClipboardItems := NewItem(UiText('Paste from ~h~istory...',
    'Pegar del ~h~istorial...'), PrefixKeyLabel(Cfg.PrefixKey) + ' h',
    kbNoKey, cmClipboardHistory, hcNoContext, ClipboardItems);
  ClipboardItems := NewItem(UiText('Paste ~l~atest', 'Pegar ~u~ltimo'),
    PrefixKeyLabel(Cfg.PrefixKey) + ' ]', kbNoKey, cmClipboardPaste,
    hcNoContext, ClipboardItems);
  ClipboardItems := NewItem(UiText('~C~opy from pane...',
    '~C~opiar del panel...'), PrefixKeyLabel(Cfg.PrefixKey) + ' [',
    kbNoKey, cmClipboardCopy, hcNoContext, ClipboardItems);
  MClipboard := NewMenu(ClipboardItems);

  // ---- Classes: opens a new pane of each configured class ----
  ClassItems := nil;
  Num := 0;
  ClassMenuCount := 0;
  for i := 0 to Length(WClasses) - 1 do
    if WClasses[i].Enabled then
    begin
      Inc(Num);
      if ClassMenuCount < MAX_CLASS_MENU_ITEMS then
      begin
        ClassMenuNames[ClassMenuCount] := WClasses[i].Name;
        Inc(ClassMenuCount);
      end;
    end;
  for i := ClassMenuCount - 1 downto 0 do
  begin
    Idx := FindClassByName(WClasses, ClassMenuNames[i]);
    if Idx < 0 then
      continue;
    if i < 8 then
      TitleS := Format('~%d~ %s', [i + 2, Copy(WClasses[Idx].Name, 1, 20)])
    else
      TitleS := '  ' + Copy(WClasses[Idx].Name, 1, 20);
    Chain := NewItem(TitleS, '', kbNoKey, cmOpenClass + i, hcNoContext,
      ClassItems);
    if Chain <> nil then
      ClassItems := Chain;
  end;
  if Num > ClassMenuCount then
    ClassItems := NewInfoItem(UiText(
      '(more classes in Open/Manage...)',
      '(mas clases en Abrir/Gestionar...)'), '', ClassItems);
  ClassItems := NewItem(UiText('~1~ Local shell', '~1~ Shell local'), '',
    kbNoKey, cmSplitV, hcNoContext, ClassItems);
  // management at the end of the menu, separate from the open list
  Chain := ClassItems;
  while (Chain <> nil) and (Chain^.Next <> nil) do
    Chain := Chain^.Next;
  if Chain <> nil then
    Chain^.Next := NewLine(
      NewItem(UiText('~O~pen class in new pane...',
        '~A~brir clase en panel nuevo...'), PrefixKeyLabel(Cfg.PrefixKey) + ' c', kbNoKey, cmClassPick,
        hcNoContext,
      NewItem(UiText('~M~anage classes...', '~G~estionar clases...'), '',
        kbNoKey, cmClassManage, hcNoContext, nil)));
  MClasses := NewMenu(ClassItems);

  // ---- Profiles: activate and manage ----
  ProfileItems := NewLine(
    NewItem(UiText('~S~ave current as profile...',
      '~G~uardar actual como perfil...'), '', kbNoKey, cmProfileSaveAs,
      hcNoContext,
    NewItem(UiText('~N~ew empty profile...', '~N~uevo perfil vacio...'), '',
      kbNoKey, cmProfileNewEmpty, hcNoContext,
    NewItem(UiText('~M~anage profiles...', 'Ge~s~tionar perfiles...'), '',
      kbNoKey, cmProfileManage, hcNoContext, nil))));
  ProfileMenuCount := 0;
  Num := 0;
  for i := 0 to High(Profiles) do
    if Profiles[i].Enabled then
    begin
      Inc(Num);
      if ProfileMenuCount < MAX_PROFILE_MENU_ITEMS then
      begin
        ProfileMenuNames[ProfileMenuCount] := Profiles[i].Name;
        Inc(ProfileMenuCount);
      end;
    end;
  HasProfiles := ProfileMenuCount > 0;
  if Num > ProfileMenuCount then
    ProfileItems := NewInfoItem(UiText(
      '(more profiles in Manage...)',
      '(mas perfiles en Gestionar...)'), '', ProfileItems);
  for i := ProfileMenuCount - 1 downto 0 do
  begin
      Idx := FindProfileByName(Profiles, ProfileMenuNames[i]);
      if Idx < 0 then
        continue;
      Chain := NewItem(ActiveMark(ProfileMode and (Idx = ActiveProfile)) +
        Copy(Profiles[Idx].Name, 1, 24), '', kbNoKey,
        cmProfileBase + i, hcNoContext, ProfileItems);
      if Chain <> nil then
        ProfileItems := Chain;
  end;
  if not HasProfiles then
    ProfileItems := NewInfoItem(UiText('(no profiles yet)',
      '(aun no hay perfiles)'), '', ProfileItems);
  MProfiles := NewMenu(ProfileItems);

  // ---- Sessions: detach and application life cycle ----
  SessItems := nil;
  SessItems := NewItem(UiText('E~x~it', 'Sa~l~ir'),
    'Alt-X', kbAltX, cmQuit, hcNoContext, SessItems);
  SessItems := NewLine(SessItems);
  SessItems := NewItem(UiText('Quick session ~w~izard...',
    '~A~sistente de sesion rapida...'), '', kbNoKey, cmSessionWizard,
    hcNoContext, SessItems);
  SessItems := NewItem(UiText('~N~ew session...', '~N~ueva sesion...'), '',
    kbNoKey, cmSessionNew, hcNoContext, SessItems);
  SessItems := NewLine(SessItems);
  SessItems := NewItem(UiText('~A~ttach / manage sessions...',
    '~C~onectar / gestionar...'), PrefixKeyLabel(Cfg.PrefixKey) + ' s', kbNoKey,
    cmSessionPick, hcNoContext, SessItems);
  SessItems := NewItem(UiText('~D~etach...', '~S~eparar...'), PrefixKeyLabel(Cfg.PrefixKey) + ' d',
    kbNoKey, cmDetach, hcNoContext, SessItems);
  // attached to a named session: show it as an informational row
  if RemoteMode and (CurrentSessionName <> '') then
  begin
    SessItems := NewLine(SessItems);
    SessItems := NewInfoItem(UiText('Session: ', 'Sesion: ') +
      Copy(CurrentSessionName, 1, 24), '', SessItems);
  end;
  MSessMenu := NewMenu(SessItems);

  // ---- Options: languages in fixed order, untranslated names ----
  LanguageItems := nil;
  LanguageItems := NewItem(ActiveMark(CurrentLanguage = ulSpanish) +
    'E~s~pa'#164'ol', '', kbNoKey, cmLanguageBase + Ord(ulSpanish),
    hcNoContext, LanguageItems);
  LanguageItems := NewItem(ActiveMark(CurrentLanguage = ulEnglish) +
    '~E~nglish', '', kbNoKey, cmLanguageBase + Ord(ulEnglish), hcNoContext,
    LanguageItems);
  PaletteItems := nil;
  PaletteItems := NewItem(ActiveMark(AppPalette = apMonochrome) +
    UiText('~M~onochrome', '~M~onocromo'), '', kbNoKey,
    cmPaletteBase + apMonochrome, hcNoContext, PaletteItems);
  PaletteItems := NewItem(ActiveMark(AppPalette = apBlackWhite) +
    UiText('~B~lack and white', '~B~lanco y negro'), '', kbNoKey,
    cmPaletteBase + apBlackWhite, hcNoContext, PaletteItems);
  PaletteItems := NewItem(ActiveMark(AppPalette = apColor) +
    UiText('~C~olor (Turbo Pascal)',
      '~C~olor (Turbo Pascal)'), '', kbNoKey,
    cmPaletteBase + apColor, hcNoContext, PaletteItems);
  // Desktop background: one entry per picture found on disk, plus the
  // classic layout modes. Built at run time because the pictures are files,
  // so a new one appears in the menu without rebuilding.
  BgItems := nil;
  for i := ArtCount - 1 downto 0 do
    BgItems := NewItem(ActiveMark(ArtIndexOf(Cfg.Background) = i) +
      UiText(ArtLabel(i), ArtLabelEs(i)), '', kbNoKey,
      cmBackgroundBase + i, hcNoContext, BgItems);
  BgModeItems := nil;
  for AM := High(TArtMode) downto Low(TArtMode) do
    BgModeItems := NewItem(ActiveMark(ArtModeOf(Cfg.BackgroundMode) = AM) +
      UiText(ArtModeLabel(AM), ArtModeLabelEs(AM)), '', kbNoKey,
      cmBackgroundModeBase + Ord(AM), hcNoContext, BgModeItems);

  MOptions := NewMenu(
    NewSubMenu(UiText('~L~anguage', '~I~dioma'), hcNoContext,
      NewMenu(LanguageItems),
    NewSubMenu(UiText('Color ~p~alette', '~P~aleta de colores'), hcNoContext,
      NewMenu(PaletteItems),
    NewSubMenu(UiText('Desktop ~b~ackground', '~F~ondo del escritorio'),
      hcNoContext, NewMenu(BgItems),
    NewSubMenu(UiText('Background la~y~out', 'Dis~p~osicion del fondo'),
      hcNoContext, NewMenu(BgModeItems),
    NewLine(
    NewItem(ActiveMark(Cfg.AutoSave) +
      UiText('Auto~s~ave on exit', 'Auto~g~uardar al salir'), '', kbNoKey,
      cmToggleAutoSave, hcNoContext,
    NewItem(ActiveMark(Cfg.AutoRestore) +
      UiText('Auto~r~estore on start', 'Auto~r~estaurar al arrancar'), '',
      kbNoKey, cmToggleAutoRestore, hcNoContext,
    NewItem(UiText('Desktop ~c~olour...', '~C~olor del escritorio...'), '',
      kbNoKey, cmDesktopColor, hcNoContext,
    NewItem(ActiveMark(Cfg.SolidBg) +
      UiText('Sol~i~d background', 'Fondo sol~i~do'), '',
      kbNoKey, cmToggleSolidBg, hcNoContext,
    NewItem(ActiveMark(Cfg.DragContent) +
      UiText('Contents while ~d~ragging',
             'Contenido al ~a~rrastrar'), '',
      kbNoKey, cmToggleDragContent, hcNoContext,
    NewItem(ActiveMark(Cfg.ZoomAnim) +
      UiText('Zoom/fullscreen ~t~ransition',
             '~T~ransicion de zoom/pantalla'), '',
      kbNoKey, cmToggleZoomAnim, hcNoContext, nil ))))))))))));

  MHelp := NewMenu(
    NewItem(UiText('~H~elp and shortcuts', '~A~yuda y atajos'), '', kbNoKey,
      cmHelp, hcNoContext,
    NewLine(
    NewItem(UiText('A~b~out...', 'A~c~erca de...'), '', kbNoKey,
      cmAbout, hcNoContext, nil))));

  MenuBar := New(PMenuBar, Init(R, NewMenu(
    NewSubMenu(UiText('~P~anes', '~P~aneles'), 0, MPanes,
    NewSubMenu(UiText('~W~indows', '~V~entanas'), 0, MWindows,
    NewSubMenu(UiText('~D~esktop', '~E~scritorio'), 0, MDesktop,
    NewSubMenu(UiText('~C~lasses', '~C~lases'), 0, MClasses,
    NewSubMenu(ProfileTopTitle, 0, MProfiles,
    NewSubMenu(SessionTopTitle, 0, MSessMenu,
    NewSubMenu(OptionsTopTitle, 0, MOptions,
    NewSubMenu(UiText('Clip~b~oard', 'Por~t~apapeles'), 0, MClipboard,
    NewSubMenu(UiText('~H~elp', '~A~yuda'), 0, MHelp,
    nil))))))))))));
end;

procedure TSuperApp.InitStatusLine;
var
  R: Objects.TRect;
  Items: PStatusItem;
begin
  R := Default(Objects.TRect);
  GetExtent(R);
  R.A.Y := R.B.Y - 1;
  Items := nil;
  // invisible keys: dispatch without taking room in the status line
  Items := NewStatusKey('', kbCtrlF5, cmResize, Items);
  Items := NewStatusKey('', kbAltF9, cmWindowMinimize, Items);
  Items := NewStatusKey('', kbAltF4, cmClose, Items);
  Items := NewStatusKey('', kbAltF3, cmPaneClose, Items);
  Items := NewStatusKey('', kbF9, cmWindowPrev, Items);
  Items := NewStatusKey('', kbF7, cmPanePrev, Items);
  Items := NewStatusKey('', kbF3, cmSplitH, Items);
  // Exit remains an intentional keyboard command, but it is not advertised
  // or clickable on the status line: the safe everyday action is Detach.
  Items := NewStatusKey('', kbAltX, cmQuit, Items);
  // visible: what a novice needs most, fitting in 80 columns
  Items := NewStatusKey(UiText(
    '~' + PrefixKeyLabel(Cfg.PrefixKey) + ' d~ Detach',
    '~' + PrefixKeyLabel(Cfg.PrefixKey) + ' d~ Separar'),
    kbNoKey, cmDetach, Items);
  Items := NewStatusKey(UiText(
    '~' + PrefixKeyLabel(Cfg.PrefixKey) + ' f~ Full screen',
    '~' + PrefixKeyLabel(Cfg.PrefixKey) + ' f~ Pantalla'),
    kbNoKey, cmFullScreen, Items);
  Items := NewStatusKey(UiText('~F8~ Window', '~F8~ Ventana'), kbF8,
    cmWindowNext, Items);
  Items := NewStatusKey(UiText('~F6~ Pane', '~F6~ Panel'), kbF6,
    cmPaneNext, Items);
  Items := NewStatusKey(UiText('~F2~ Split', '~F2~ Dividir'), kbF2,
    cmSplitV, Items);
  StatusLine := New(PGeometryStatusLine, Init(R,
    NewStatusDef(0, $FFFF, Items, nil)));
end;

end.
