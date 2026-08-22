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
  st_layout, st_session, st_debug, st_server, st_video, st_cli;

const
  // Command range INVARIANT: each dynamic base (cmOpenClass,
  // cmProfileBase, cmSessionBase, cmWindowBase, cmWindowRestoreBase,
  // cmLanguageBase) owns a reserved range and NO direct case may fall
  // inside a dynamic range. Before, cmOpenClass=2111 collided with
  // cmSessionWizard=2112 and cmDetach=2113: pressing the 2nd terminal
  // in the menu launched the wizard and the 3rd one detached.
  // Ranges: 2100-2199 panes/app - 2200-2259 templates - 2300-2349
  // terminals (cmOpenClass+i) - 2400-2439 windows - 2500-2539 minimized
  // - 2550-2569 session (detach/wizard) - 2600 help - 2700 language.
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
  cmQuitNoSave = 2110;
  cmPaneTile    = 2111;    // retile as a mosaic (classic Window|Tile)
  cmPaneCascade = 2112;
  cmPaneList    = 2113;    // pane list (Alt+0)
  cmRedrawAll   = 2114;    // refresh the screen
  cmPaneOrganize = 2115;   // vendor NxM grid (TDeskTop.Tile)
  cmRenameWindow = 2116;   // custom title of the focused window
  cmInfoRow    = 2199;     // informational menu rows, always disabled
  cmProfileBase = 2200;   // + profile index (0..39)
  cmProfileSaveAs = 2250;  // save the workspace as a profile
  cmProfileManage = 2251;  // profile manager
  cmOpenClass   = 2320;     // + index into WClasses (0..29)
  cmWindowNext   = 2400;
  cmWindowPrev   = 2401;
  cmWindowBase   = 2410;   // + window index (0..15)
  cmClassPick    = 2340;   // class picker for a new pane
  cmClassManage  = 2341;   // class manager
  cmWindowMinimize = 2500;
  cmWindowMinimizeAll = 2501;
  cmWindowRestoreAll = 2502;
  cmWindowRestoreBase = 2520;  // + pane index (0..15)
  cmDetach        = 2550;
  cmSessionPick   = 2551;   // picker/manager of detached sessions
  cmSessionWizard = 2560;
  cmHelp        = 2600;
  cmAbout       = 2601;
  cmLanguageBase = 2700;
  cmPaletteBase  = 2750;   // +apColor/apBlackWhite/apMonochrome
  cmToggleAutoSave    = 2760;
  cmToggleAutoRestore = 2761;
  cmToggleDragContent = 2762;
  cmToggleZoomAnim    = 2763;

type
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
  TTermWindow = object(TWindow)
    Term: PTermView;
    PaneIdx: integer;
    Minimized: boolean;
    Zoomed: boolean;
    TitleFixed: boolean;       // custom title: cwd refresh must not touch it
    SavedRect: Objects.TRect;  // bounds before the minimized icon
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
  end;

  TSuperApp = object(TApplication)
    Cfg: TConfig;
    Lay: TLayout;
    Panes: array[0..MAX_PANES - 1] of TPty;
    Scr: array[0..MAX_PANES - 1] of TScreen;
    Win: array[0..MAX_PANES - 1] of PTermWindow;
    PaneTerm: array[0..MAX_PANES - 1] of integer;  // index in WClasses or -1
    PaneConnect: array[0..MAX_PANES - 1] of string; // ad-hoc free connection
    WClasses: TWindowClassArray;
    Profiles: TProfileArray;
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
    CurrentSessionSocket: string;  // socket of the attached session
    // attach under construction: windows pass through intermediate
    // bounds (tile -> final geometry) and must NOT request transient
    // sizes from the daemon nor resize the snapshot screen every step
    RemoteAttachSettling: boolean;
    // passthrough: when a pane is maximized it owns the whole host
    // terminal and its raw PTY bytes are written straight through, so a
    // truecolor/emoji TUI renders untouched. PassPane = that pane (-1 off).
    PassPane: integer;
    PassReqW, PassReqH: integer;  // full size requested on enter
    // startup: hold one LockScreenUpdate across the whole build+promote+
    // attach so the screen is flushed ONCE at the end, not several times
    FBootLocked: boolean;
    constructor Init;
    destructor Done; virtual;
    procedure Idle; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    procedure InitMenuBar; virtual;
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
    procedure DoTilePanes;
    procedure DoCascadePanes;
    procedure DoOrganizePanes;
    procedure DoPaneList;
    procedure ApplyPalette(AKind: integer);
    procedure CollectPaneGeom(out AGeom: TPaneGeomArray;
      out ADeskW, ADeskH: integer);
    procedure SyncRemoteLayout;
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
    procedure ZoomAnimate(AX1, AY1, AX2, AY2, BX1, BY1, BX2, BY2: integer);
    function ComputeLayoutHash: string;
    procedure ApplyRemoteLayoutEv(const AData: TByteArray);
    procedure ApplyRemoteKillPane(APane: integer);
    procedure ApplyRemoteNewPane(const AData: TByteArray);
    procedure ApplyRemoteResize(APane: integer; const AData: TByteArray);
    procedure ApplyRemoteTitle(APane: integer; const AData: TByteArray);
    function FindWindowClass(const AName: string): integer;
    function FindProfile(const AName: string): integer;
    function ActivateProfile(AProfile, AWindow: integer): boolean;
    procedure ApplyWindowGeometry(const WS: TProfileWindowSpec);
    function CaptureCurrentAsWindow(const AName: string): TProfileWindowSpec;
    procedure SaveWorkspaceAsProfile(const AName: string);
    procedure RunProfileSaveAs;
    procedure DoProfileManage;
    procedure StopRuntime;
    procedure ReleaseRuntime;
    procedure CreateWindowForPane(i: integer; const ATitle: string);
    procedure WritePaneInput(i: integer; const S: RawByteString);
    function AttachRemoteSession(const APath: string): boolean;
    // why the last attach attempt failed (empty = generic/none)
    // server-always: converts the freshly built local workspace into a
    // daemon session and attaches to it as a client
    procedure PromoteToServer;
    // drops the current remote session by killing its daemon (profile swap)
    procedure LeaveRemoteSession;
    function PickSessionSocketUI(AForAttach: boolean): string;
    function PromptAttachOnStart: boolean;
    procedure DoSessionPick;
    procedure RequestDetach;
    procedure DoSwitchProfile(AIndex: integer);
    procedure DoSwitchWindow(AIndex: integer);
    procedure DoCycleWindow(ADelta: integer);
    procedure RunSessionWizard;
    procedure ShowHelp;
    procedure RebuildMenu;
    procedure RebuildStatusLine;
    procedure RememberProfileSelection;
    procedure ApplyTerminalSize(ACols, ARows: integer);
    procedure SyncTerminalSize;
  end;

implementation

uses
  st_keys;

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
  // wireframe drag: the window being dragged is HIDDEN, and this is the
  // outline currently painted on the terminal (Valid=False = none painted)
  OutlineValid: boolean = False;
  OutlineX1, OutlineY1, OutlineX2, OutlineY2: integer;
  OutlineOwner: integer = -1;
  // reason the last attach was refused (shown to the user instead of silently
  // starting a fresh local session)
  AttachFailReason: string = '';

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
procedure TSuperApp.RepaintChanges;
begin
  if DebugActive then
    DebugLog('fvui: RepaintChanges (incremental DrawView -> diff)');
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
  b0, k: byte;
  need: byte;
  cp: cardinal;
begin
  Result := ' ';
  if C.Len = 0 then
    Exit;
  b0 := byte(C.Txt[0]);
  if C.Len = 1 then
  begin
    if (b0 >= $20) and (b0 <= $7E) then
      Result := AnsiChar(b0)
    else
      Result := '?';        // controls, DEL and bare high bytes
    Exit;
  end;
  if C.Len > 4 then
    Exit('?');
  // length implied by the lead byte must match, and $C0/$C1/$F5..$FF are
  // never legal lead bytes
  if (b0 >= $C2) and (b0 <= $DF) then need := 2
  else if (b0 >= $E0) and (b0 <= $EF) then need := 3
  else if (b0 >= $F0) and (b0 <= $F4) then need := 4
  else Exit('?');
  if need <> C.Len then
    Exit('?');
  for k := 1 to C.Len - 1 do
    if (byte(C.Txt[k]) and $C0) <> $80 then
      Exit('?');            // continuation bytes must be $80..$BF
  case C.Len of
    2: cp := ((b0 and $1F) shl 6) or (byte(C.Txt[1]) and $3F);
    3: cp := ((b0 and $0F) shl 12) or ((byte(C.Txt[1]) and $3F) shl 6) or
             (byte(C.Txt[2]) and $3F);
  else
    cp := ((b0 and $07) shl 18) or ((byte(C.Txt[1]) and $3F) shl 12) or
          ((byte(C.Txt[2]) and $3F) shl 6) or (byte(C.Txt[3]) and $3F);
  end;
  // overlong encodings, surrogates and out-of-range code points
  if ((C.Len = 2) and (cp < $80)) or
     ((C.Len = 3) and (cp < $800)) or
     ((C.Len = 4) and ((cp < $10000) or (cp > $10FFFF))) or
     ((cp >= $D800) and (cp <= $DFFF)) then
    Exit('?');
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
  EventMask := EventMask or evKeyDown or evCommand;
end;

procedure TTermView.Draw;
var
  B: TDrawBuffer;
  x, y, w, h: integer;
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
    cursor: boolean);
  var
    g: RawByteString;
    ffg, fbg: LongWord;
    fl, k: integer;
    isSkip: boolean;
  begin
    isSkip := c.Cont;
    if isSkip then
      g := ''
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
    if ((c.Attr and A_REVERSE) <> 0) <> cursor then fl := fl or 4;
    if Occluded(GOrig.X + lx, GOrig.Y + ly) then
      Exit;   // that cell belongs to the window in front; leave its entry alone
    RichSetCell(GOrig.X + lx, GOrig.Y + ly, g, ffg, fbg, byte(fl),
      oracle, isSkip);
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
  cx := App^.Scr[PaneIdx].CursorX;
  cy := App^.Scr[PaneIdx].CursorY;
  // DECSCUSR 2/4/6 = steady style (no blink); 0/1/3/5 blinks
  ShowBlk := GetState(sfSelected) and (not Scrolled) and
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
  PadCell := Default(TCell);
  PadCell.Attr := App^.Scr[PaneIdx].Attr;
  PadCell.FgRGB := App^.Scr[PaneIdx].AttrFgRGB;
  PadCell.BgRGB := App^.Scr[PaneIdx].AttrBgRGB;
  for y := 0 to h - 1 do
  begin
    RowLen := 0;
    if (not Scrolled) and (y < App^.Scr[PaneIdx].Height) then
    begin
      for x := 0 to w - 1 do
      begin
         if x < App^.Scr[PaneIdx].Width then
         begin
           cell := App^.Scr[PaneIdx].Grid[y][x];
           if (cell.Len > 0) or (cell.Cont) then
             Inc(NonBlank);
           B[x] := RenderAttr(cell.Attr) or word(TranslitByte(cell));
           if ShowBlk and (x = cx) and (y = cy) then
           begin
             fg := (B[x] shr 8) and $0F;
             bg := (B[x] shr 12) and $0F;
             B[x] := (word(fg) shl 12) or (word(bg) shl 8) or
               word(TranslitByte(cell));
           end;
           RichReg(x, y, cell, B[x], ShowBlk and (x = cx) and (y = cy));
         end
         else
         begin
           B[x] := BlankWord or word(' ');
           RichReg(x, y, PadCell, B[x], false);
         end;
      end;
    end
    else if Scrolled then
    begin
      Row := App^.Scr[PaneIdx].DisplayRow(y);
      RowLen := Length(Row);
      for x := 0 to w - 1 do
      begin
        if x < RowLen then
         begin
           cell := Row[x];
           if (cell.Len > 0) or (cell.Cont) then
             Inc(NonBlank);
           B[x] := RenderAttr(cell.Attr) or word(TranslitByte(cell));
           RichReg(x, y, cell, B[x], false);
         end
         else
         begin
           B[x] := BlankWord or word(' ');
           RichReg(x, y, PadCell, B[x], false);
         end;
       end;
    end
    else
      for x := 0 to w - 1 do
      begin
        B[x] := BlankWord or word(' ');
        RichReg(x, y, PadCell, B[x], false);
      end;
    WriteLine(0, y, w, 1, B);
  end;
  if Scrolled then
    DebugLog(Format('draw pane=%d scrolled=%d', [PaneIdx, App^.Scr[PaneIdx].ViewOffset]))
  else if NonBlank > 0 then
    DebugLog(Format('draw pane=%d %dx%d nonblank=%d cur=(%d,%d) selected=%d',
      [PaneIdx, w, h, NonBlank, App^.Scr[PaneIdx].CursorX, App^.Scr[PaneIdx].CursorY,
       Ord(GetState(sfSelected))]))
  else
    DebugLog(Format('draw pane=%d %dx%d EMPTY scr=%dx%d',
      [PaneIdx, w, h, App^.Scr[PaneIdx].Width, App^.Scr[PaneIdx].Height]));
  // terminal cursor in the focused pane
  if (cx >= w) then cx := w - 1;
  if (cy >= h) then cy := h - 1;
  if Scrolled then
  begin
    SetCursor(0, 0);
    HideCursor;
  end
  else
  begin
    SetCursor(cx, cy);
    if GetState(sfSelected) and App^.Scr[PaneIdx].CursorVisible then
      ShowCursor
    else
      HideCursor;
  end;
end;

procedure TTermView.HandleEvent(var Event: TEvent);
var
  App: PSuperApp;
  seq: RawByteString;
begin
  App := PSuperApp(Application);
  if (App = nil) then
  begin
    inherited HandleEvent(Event);
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
    case Event.KeyCode of
      kbAltPgUp:
        begin
          App^.Scr[PaneIdx].ScrollViewport(+Size.Y);
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbAltPgDn:
        begin
          App^.Scr[PaneIdx].ScrollViewport(-Size.Y);
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbAltHome:
        begin
          App^.Scr[PaneIdx].ScrollViewport(MaxInt);
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbAltEnd:
        begin
          App^.Scr[PaneIdx].ScrollViewport(-MaxInt);
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
    end;
  end;
  if (Event.What = evKeyDown) then
  begin
    seq := TranslateKey(Event.KeyCode);
    if seq <> '' then
    begin
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
  W, i, xo: integer;
  T: string;
begin
  B := Default(TDrawBuffer);
  // minimized icon: frame and title in black (the passive gray is
  // unreadable on light blue); custom drawing of the two rows
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
    if Length(T) > W - 6 then
      T := Copy(T, 1, W - 6);
    T := ' ' + T + ' ';
    MoveChar(B, #196, $10, W);
    B[0] := (B[0] and $FF00) or word(byte(#218));
    B[W - 1] := (B[W - 1] and $FF00) or word(byte(#191));
    xo := (W - Length(T)) div 2;
    for i := 1 to Length(T) do
      B[xo + i - 1] := (B[xo + i - 1] and $FF00) or word(byte(T[i]));
    WriteLine(0, 0, W, 1, B);
    MoveChar(B, #196, $10, W);
    B[0] := (B[0] and $FF00) or word(byte(#192));
    B[W - 1] := (B[W - 1] and $FF00) or word(byte(#217));
    WriteLine(0, 1, W, 1, B);
    Exit;
  end;
  inherited Draw;
  // FreeVision has close and zoom buttons but no minimize button. Keep the
  // minimize control in the same title-bar language as the native controls.
  if (Owner <> nil) and (State and sfActive <> 0) and (Size.X >= 14) then
  begin
    Color := byte(GetColor($0503));
    MoveChar(B, ' ', Color, 3);
    B[0] := (B[0] and $FF00) or word('[');
    B[1] := (B[1] and $FF00) or word('-');
    B[2] := (B[2] and $FF00) or word(']');
    WriteLine(Size.X - 10, 0, 3, 1, B);
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
      App^.FocusPane(PTermWindow(Owner)^.PaneIdx);
    Mouse := Default(Objects.TPoint);
    MakeLocal(Event.Where, Mouse);
    if (State and sfActive <> 0) and (Mouse.Y = 0) and
       (Size.X >= 14) and (Mouse.X >= Size.X - 10) and
       (Mouse.X <= Size.X - 8) then
    begin
      Event.What := evCommand;
      Event.Command := cmWindowMinimize;
      Event.InfoPtr := Owner;
      PutEvent(Event);
      ClearEvent(Event);
      DrawView;
      Exit;
    end;
  end;
  inherited HandleEvent(Event);
end;

{ ---------------- TTermWindow ---------------- }

constructor TTermWindow.Init(var Bounds: Objects.TRect; const ATitle: string; APane: integer);
var
  R: Objects.TRect;
begin
  inherited Init(Bounds, ATitle, APane + 1);
  PaneIdx := APane;
  Minimized := False;
  Zoomed := False;
  State := State and (not sfShadow);     // no shadow: exact tiling
  R.Assign(1, 1, Bounds.B.X - Bounds.A.X - 1, Bounds.B.Y - Bounds.A.Y - 1);
  Term := New(PTermView, Init(R, APane));
  Insert(Term);
end;

procedure TTermWindow.HandleEvent(var Event: TEvent);
var
  App: PSuperApp;
  Dragging: boolean;
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
  Dragging := (App <> nil) and (not App^.Cfg.DragContent) and (not Minimized) and
    (((Event.What = evMouseDown) and (Term <> nil) and
      MouseInView(Event.Where) and (not Term^.MouseInView(Event.Where))) or
     ((Event.What = evCommand) and (Event.Command = cmResize)));
  if Dragging then
  begin
    // Hide the WHOLE window, not just the pane: the frame paints its interior
    // full width (vendor/fv322/views.pas:2935-2939), so a visible frame is an
    // opaque blue rectangle, and a visible window keeps clipping the desktop
    // underneath. Hidden, FreeVision repaints the desktop and the other
    // windows normally, VideoBuf ends up holding the true screen, and we paint
    // the moving outline on top of it ourselves.
    OutlineOwner := PaneIdx;
    OutlineX1 := Desktop^.Origin.X + Origin.X;
    OutlineY1 := Desktop^.Origin.Y + Origin.Y;
    OutlineX2 := OutlineX1 + Size.X - 1;
    OutlineY2 := OutlineY1 + Size.Y - 1;
    Hide;
    OutlineValid := True;
    OutlinePaint(OutlineX1, OutlineY1, OutlineX2, OutlineY2, $1F);
  end;
  inherited HandleEvent(Event);
  if Dragging then
  begin
    // released: drop the outline and bring the window back at its new place
    if OutlineValid then
      OutlineRestore(OutlineX1, OutlineY1, OutlineX2, OutlineY2);
    OutlineValid := False;
    OutlineOwner := -1;
    Show;
  end;
end;

procedure TTermWindow.SizeLimits(var Min, Max: Objects.TPoint);
begin
  inherited SizeLimits(Min, Max);
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
  gx1, gy1, gx2, gy2: integer;
  pw, ph: integer;
begin
  inherited ChangeBounds(Bounds);
  // Wireframe drag: the window is hidden, so nothing of it is drawn. Move the
  // outline instead -- erase the ring we painted last (straight from VideoBuf,
  // which holds the true screen) and paint the new one. Only those cells
  // travel, so a drag step costs the perimeter, not the area.
  if OutlineValid and (OutlineOwner = PaneIdx) and (Desktop <> nil) then
  begin
    gx1 := Desktop^.Origin.X + Bounds.A.X;
    gy1 := Desktop^.Origin.Y + Bounds.A.Y;
    gx2 := Desktop^.Origin.X + Bounds.B.X - 1;
    gy2 := Desktop^.Origin.Y + Bounds.B.Y - 1;
    if (gx1 <> OutlineX1) or (gy1 <> OutlineY1) or
       (gx2 <> OutlineX2) or (gy2 <> OutlineY2) then
    begin
      OutlineRestore(OutlineX1, OutlineY1, OutlineX2, OutlineY2);
      OutlineX1 := gx1; OutlineY1 := gy1;
      OutlineX2 := gx2; OutlineY2 := gy2;
      OutlinePaint(gx1, gy1, gx2, gy2, $1F);   // bright white on blue
    end;
  end;
  if Term <> nil then
  begin
    R.Assign(1, 1, Bounds.B.X - Bounds.A.X - 1, Bounds.B.Y - Bounds.A.Y - 1);
    if (R.B.X > R.A.X) and (R.B.Y > R.A.Y) then
      Term^.Locate(R);
  end;
  App := PSuperApp(Application);
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
    if (pw <> App^.Scr[PaneIdx].Width) or (ph <> App^.Scr[PaneIdx].Height) then
    begin
      App^.Scr[PaneIdx].Resize(pw, ph);
      if App^.RemoteMode then
        App^.Remote.SendResize(PaneIdx, pw, ph)
      else if App^.Panes[PaneIdx] <> nil then
        App^.Panes[PaneIdx].Resize(pw, ph);
    end;
  end;
end;

procedure TTermWindow.Zoom;
var
  App: PSuperApp;
  i: integer;
  WasZoomed: boolean;
begin
  App := PSuperApp(Application);
  WasZoomed := Zoomed;
  if (App <> nil) and (not WasZoomed) then
    for i := 0 to MAX_PANES - 1 do
      if (i <> PaneIdx) and (App^.Win[i] <> nil) and
         App^.Win[i]^.Zoomed then
        App^.Win[i]^.Zoom;
  inherited Zoom;
  Zoomed := not WasZoomed;
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

constructor TSuperApp.Init;
var
  Pin: TPaneArray;
  i, n, k, SysIdx: integer;
  Ok: boolean;
  Dir: TSplitDir;
  DeskW, DeskH: integer;
  RD, WR: Objects.TRect;
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
  LoadConfig(Cfg);
  if Cfg.Palette = 'bw' then
    AppPalette := apBlackWhite
  else if Cfg.Palette = 'mono' then
    AppPalette := apMonochrome
  else
    AppPalette := apColor;
  CurrentLanguage := Cfg.Language;
  SetMessageBoxLanguage(CurrentLanguage = ulSpanish);
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
  CurrentSessionSocket := '';
  RemoteAttachSettling := False;
  PassPane := -1;
  PassReqW := 0;
  PassReqH := 0;

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
  else if PromptAttachOnStart then
    Exit;

  if ProfileMode then
  begin
    // default profile resolution: new default_profile, with backwards
    // compatibility for default_template [+ /default_session]
    ActiveProfile := FindProfile(Cfg.DefaultProfile);
    if ActiveProfile < 0 then
      ActiveProfile := FindProfile(Cfg.DefaultTemplate);
    if (ActiveProfile < 0) and (Cfg.DefaultSession <> '') then
      ActiveProfile := FindProfile(Cfg.DefaultTemplate + '/' +
        Cfg.DefaultSession);
    if (ActiveProfile < 0) or (not Profiles[ActiveProfile].Enabled) then
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
      ActiveWindow := -1;
      for i := 0 to Length(Profiles[ActiveProfile].Windows) - 1 do
        if Profiles[ActiveProfile].Windows[i].Enabled and
           SameText(Profiles[ActiveProfile].Windows[i].Name,
             Cfg.DefaultWindow) then
        begin
          ActiveWindow := i;
          Break;
        end;
      if (ActiveWindow < 0) and
         (Profiles[ActiveProfile].FocusedWindow >= 0) and
         (Profiles[ActiveProfile].FocusedWindow <
          Length(Profiles[ActiveProfile].Windows)) and
         Profiles[ActiveProfile].Windows[
           Profiles[ActiveProfile].FocusedWindow].Enabled then
        ActiveWindow := Profiles[ActiveProfile].FocusedWindow;
      if ActiveWindow < 0 then
        for i := 0 to Length(Profiles[ActiveProfile].Windows) - 1 do
          if Profiles[ActiveProfile].Windows[i].Enabled then
          begin
            ActiveWindow := i;
            Break;
          end;
      if (ActiveWindow < 0) or
         (not ActivateProfile(ActiveProfile, ActiveWindow)) then
        ProfileMode := False;
    end;
    if ProfileMode then
      Exit;
  end;
  Pin := nil;
  Ok := False;
  DeskW := 0;
  DeskH := 0;
  if Cfg.AutoRestore then
    Ok := LoadSession(SessionFile, Lay, Pin, DeskW, DeskH);
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
  // reapply manual window geometry/state (moved or resized with
  // Ctrl-F5, maximized, minimized) saved in session.ini; only if the
  // desktop has the same size as when saving, because the bounds
  // are absolute
  RD := Default(Objects.TRect);
  Desktop^.GetExtent(RD);
  if Ok and (DeskW = RD.B.X - RD.A.X) and (DeskH = RD.B.Y - RD.A.Y) then
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
      end;
    // minimized ones last: MinimizeWindow manages the focus
    for i := 0 to n - 1 do
      if (i <= High(Pin)) and (i < MAX_PANES) and (Win[i] <> nil) and
         Pin[i].Minimized then
        MinimizeWindow(i);
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
    if (Remote <> nil) and Remote.Connected then
    begin
      // push the final geometry and ask the daemon to save (Alt-X);
      // with Alt-Q SkipSave rules and it dies without saving, as locally
      SyncRemoteLayout;
      Remote.CloseSession(Cfg.AutoSave and (not SkipSave));
    end;
    ReleaseRuntime;
  end
  else if ProfileMode then
  begin
    if not SkipSave then
    begin
      RememberProfileSelection;
      SaveConfig(Cfg);
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
  NeedVideo, NeedBounds: boolean;
begin
  if (ACols < 1) or (ARows < 1) then
    Exit;
  if ACols > MaxViewWidth then
    ACols := MaxViewWidth;
  NeedVideo := (ScreenWidth <> ACols) or (ScreenHeight <> ARows);
  NeedBounds := (Size.X <> ACols) or (Size.Y <> ARows);
  if (not NeedVideo) and (not NeedBounds) then
    Exit;

  if NeedVideo then
  begin
    Mode.Col := ACols;
    Mode.Row := ARows;
    Mode.Color := True;
    SetScreenVideoMode(Mode);
  end;

  if NeedBounds then
  begin
    R.Assign(0, 0, ACols, ARows);
    ChangeBounds(R);
  end;
  if Lay <> nil then
  begin
    RelayoutAll;
    ResetVideoSurface;
    ReDraw;
  end;
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
  FallbackCmd: string;
  SpawnOK: boolean;
begin
  if Win[i] <> nil then
    Exit;
  R.Assign(0, 0, 40, 15);
  if i = 0 then
    Desktop^.GetExtent(R);
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
  PaneTerm[i] := ASysIdx;
  PaneConnect[i] := ''; // callers with a free connection set it afterwards
  Scr[i] := TScreen.Create(pw, ph, AMaxSB);
  Panes[i] := TPty.Create;
  ExecArgs := TStringList.Create;
  try
    ExecProgram := '';
    ExecSecret := '';
    if (ASysIdx >= 0) and (WClasses[ASysIdx].Kind = wcSSH) then
    begin
      BuildWindowClassExec(WClasses[ASysIdx], ExecProgram, ExecArgs,
        ExecSecret, ACommandOverride);
      SpawnOK := Panes[i].SpawnArgv(ExecProgram, ExecArgs.ToStringArray,
        CwdS, pw, ph, ExtraS, ExecSecret);
    end
    else
      SpawnOK := Panes[i].Spawn(ShellS, CwdS, CmdS, pw, ph, ExtraS,
        Cfg.LoginShell);
  finally
    ExecArgs.Free;
  end;
  if not SpawnOK then
  begin
    DebugLog(Format('spawn failed pane=%d sysidx=%d shell=%s cwd=%s cmd=%s',
      [i, ASysIdx, ShellS, CwdS, CmdS]));
    FreeAndNil(Panes[i]);
    FreeAndNil(Scr[i]);
    PaneTerm[i] := -1;
    // Keep the pane usable when a remote endpoint or configured shell fails.
    if ASysIdx >= 0 then
    begin
      TitleS := UiText('FAILED ', 'FALLO ') + TitleS;
      PaneTerm[i] := -2;
      FallbackCmd := 'printf ' +
        ShellQuote(UiText('superterm: terminal unavailable: ',
          'superterm: terminal no disponible: ') + TitleS + #10) +
        '; exec ' + ShellQuote(Cfg.Shell);
      Scr[i] := TScreen.Create(pw, ph, AMaxSB);
      Panes[i] := TPty.Create;
      SpawnOK := Panes[i].Spawn(Cfg.Shell, GetEnvironmentVariable('HOME'),
        FallbackCmd, pw, ph, '', Cfg.LoginShell);
    end;
    if not SpawnOK then
    begin
      FreeAndNil(Panes[i]);
      FreeAndNil(Scr[i]);
      Exit;
    end;
  end;
  CreateWindowForPane(i, TitleS);
  // a class pane keeps its title (class name/title); the periodic
  // cwd refresh must not overwrite it
  if (ASysIdx >= 0) and (Win[i] <> nil) then
    Win[i]^.TitleFixed := True;
  DebugLog(Format('startpane i=%d sysidx=%d win=%p term=%p termidx=%d scr=%dx%d',
    [i, ASysIdx, Win[i], Win[i]^.Term, Win[i]^.Term^.PaneIdx, pw, ph]));
end;

procedure TSuperApp.CreateWindowForPane(i: integer; const ATitle: string);
var
  R: Objects.TRect;
begin
  if (i < 0) or (i >= MAX_PANES) or (Win[i] <> nil) then
    Exit;
  R.Assign(0, 0, 40, 15);
  Desktop^.GetExtent(R);
  Win[i] := New(PTermWindow, Init(R, ' ' + ATitle, i));
  Desktop^.Insert(Win[i]);
end;

procedure TSuperApp.KillPane(i: integer);
begin
  if Win[i] <> nil then
  begin
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
  TitleS := WClasses[PaneTerm[i]].Name;
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
  i, TileH: integer;
  R: Objects.TRect;
  HasIcons: boolean;
begin
  R := Default(Objects.TRect);
  Desktop^.GetExtent(R);
  // with minimized windows, the tile reserves the bottom icon strip
  HasIcons := False;
  for i := 0 to MAX_PANES - 1 do
    if (Win[i] <> nil) and Win[i]^.Minimized then
      HasIcons := True;
  TileH := R.B.Y - R.A.Y;
  if HasIcons then
    Dec(TileH, 2);
  Lay.ComputeRects(R.B.X - R.A.X, TileH, Rects);
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
        LR.Assign(0, 0, R.B.X - R.A.X, R.B.Y - R.A.Y)
      else
        LR := TileR;
      Win[i]^.Locate(LR);
    end;
end;

procedure TSuperApp.FocusPane(i: integer);
begin
  if (i >= 0) and (i < MAX_PANES) and (Win[i] <> nil) and
     (not Win[i]^.Minimized) then
  begin
    Lay.Focused := i;
    Win[i]^.Select;
    if Win[i]^.Term <> nil then
      Win[i]^.Term^.Select;
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

// groups the minimized icons into rows at the bottom of the desktop
procedure TSuperApp.ArrangeIcons;
const
  ICON_W = 26;
  ICON_H = 2;
var
  RD, R: Objects.TRect;
  i, k, PerRow, DeskW: integer;
begin
  if Desktop = nil then
    Exit;
  RD := Default(Objects.TRect);
  Desktop^.GetExtent(RD);
  DeskW := RD.B.X - RD.A.X;
  PerRow := DeskW div (ICON_W + 1);
  if PerRow < 1 then
    PerRow := 1;
  k := 0;
  for i := 0 to MAX_PANES - 1 do
    if (Win[i] <> nil) and Win[i]^.Minimized then
    begin
      R.Assign((k mod PerRow) * (ICON_W + 1),
        RD.B.Y - RD.A.Y - ICON_H * (1 + k div PerRow),
        (k mod PerRow) * (ICON_W + 1) + ICON_W,
        RD.B.Y - RD.A.Y - ICON_H * (k div PerRow));
      Win[i]^.Locate(R);
      Inc(k);
    end;
end;

procedure TSuperApp.MinimizeWindow(i: integer);
var
  NextPane: integer;
begin
  if (i < 0) or (i >= MAX_PANES) or (Win[i] = nil) or
     Win[i]^.Minimized then
    Exit;
  NextPane := FindVisiblePane(i, 1);
  if NextPane = i then
    NextPane := -1;
  Win[i]^.Minimize;
  // do NOT re-tile: the other windows stay where the user left them.
  // Only the minimized icons are re-placed at the desktop bottom.
  ArrangeIcons;
  if Lay.Focused = i then
  begin
    if NextPane >= 0 then
    begin
      Lay.Focused := NextPane;
      FocusPane(NextPane);
    end
    else
      Lay.Focused := -1;
  end;
  RebuildMenu;
end;

procedure TSuperApp.RestoreWindow(i: integer);
begin
  if (i < 0) or (i >= MAX_PANES) or (Win[i] = nil) or
     (not Win[i]^.Minimized) then
    Exit;
  Win[i]^.Restore;
  // go back EXACTLY to where it was before minimizing, without
  // re-tiling or touching other windows (the user rules positions)
  if (Win[i]^.SavedRect.B.X > Win[i]^.SavedRect.A.X) and
     (Win[i]^.SavedRect.B.Y > Win[i]^.SavedRect.A.Y) then
    Win[i]^.Locate(Win[i]^.SavedRect);
  Lay.Focused := i;
  ArrangeIcons;   // re-place the icons that remain minimized
  FocusPane(i);
  RebuildMenu;
end;

procedure TSuperApp.MinimizeAllWindows;
var
  i: integer;
begin
  for i := 0 to MAX_PANES - 1 do
    if Win[i] <> nil then
      Win[i]^.Minimize;
  Lay.Focused := -1;
  ArrangeIcons;   // place all icons at the bottom, without re-tiling
  RebuildMenu;
end;

procedure TSuperApp.RestoreAllWindows;
var
  i: integer;
begin
  // each window returns to its pre-minimize position; nothing re-tiles
  for i := 0 to MAX_PANES - 1 do
    if (Win[i] <> nil) and Win[i]^.Minimized then
    begin
      Win[i]^.Restore;
      if (Win[i]^.SavedRect.B.X > Win[i]^.SavedRect.A.X) and
         (Win[i]^.SavedRect.B.Y > Win[i]^.SavedRect.A.Y) then
        Win[i]^.Locate(Win[i]^.SavedRect);
    end;
  if (Lay.Focused < 0) or (Lay.Focused >= MAX_PANES) or
     (Win[Lay.Focused] = nil) or Win[Lay.Focused]^.Minimized then
    Lay.Focused := FirstVisiblePane;
  FocusPane(Lay.Focused);
  RebuildMenu;
end;

procedure TSuperApp.DoSplit(ADir: TSplitDir; ASysIdx: integer);
var
  OldCount, NewIdx, j: integer;
  DirB: byte;
  ClassS: string;
begin
  if Lay.Focused < 0 then
    Lay.Focused := FirstVisiblePane;
  if Lay.Focused < 0 then
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
  OldCount := Lay.PaneCount;
  if not Lay.SplitPane(Lay.Focused, ADir) then
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
    if Win[j] <> nil then
    begin
      Win[j]^.PaneIdx := j;
      Win[j]^.Number := j + 1;
      if Win[j]^.Term <> nil then
        Win[j]^.Term^.PaneIdx := j;
    end;
  end;
  Panes[NewIdx] := nil;
  Scr[NewIdx] := nil;
  Win[NewIdx] := nil;
  PaneTerm[NewIdx] := -1;
  if ASysIdx >= 0 then
    StartPaneEx(NewIdx, '', '', ASysIdx, '', '', '', 0)
  else
    StartPane(NewIdx, GetEnvironmentVariable('HOME'), '');
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
      if Win[j] <> nil then
      begin
        Win[j]^.PaneIdx := j;
        Win[j]^.Number := j + 1;
        if Win[j]^.Term <> nil then
          Win[j]^.Term^.PaneIdx := j;
      end;
    end;
    Panes[OldCount] := nil;
    Scr[OldCount] := nil;
    Win[OldCount] := nil;
    PaneTerm[OldCount] := -1;
    if Lay.Focused >= OldCount then
      Lay.Focused := OldCount - 1;
    RelayoutAll;
    FocusPane(Lay.Focused);
    Exit;
  end;
  RelayoutAll;
  Lay.Focused := NewIdx;
  FocusPane(Lay.Focused);
end;

procedure TSuperApp.DoOpenClassPane(ASysIdx: integer);
var
  Dir: TSplitDir;
begin
  if PaneCount >= MAX_PANES then
  begin
    MessageBox(UiText('Maximum 16 panes', 'Maximo 16 paneles'), nil,
      mfInformation or mfOKButton);
    Exit;
  end;
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

procedure TSuperApp.StopRuntime;
var
  i: integer;
begin
  for i := 0 to MAX_PANES - 1 do
    KillPane(i);
  for i := 0 to MAX_PANES - 1 do
  begin
    Panes[i] := nil;
    Scr[i] := nil;
    Win[i] := nil;
    PaneTerm[i] := -1;
  end;
end;

procedure TSuperApp.ReleaseRuntime;
var
  i: integer;
begin
  // Release only the client-side objects. PTy objects are deliberately left
  // untouched when the detached server owns them.
  for i := 0 to MAX_PANES - 1 do
  begin
    if Win[i] <> nil then
    begin
      if Desktop <> nil then
        Desktop^.Delete(Win[i]);
      Dispose(Win[i], Done);
      Win[i] := nil;
    end;
    if Scr[i] <> nil then
      FreeAndNil(Scr[i]);
    Panes[i] := nil;
    PaneTerm[i] := -1;
  end;
end;

procedure TSuperApp.WritePaneInput(i: integer; const S: RawByteString);
begin
  if (i < 0) or (i >= MAX_PANES) or (S = '') then
    Exit;
  if RemoteMode then
  begin
    if (Remote <> nil) and Remote.Connected then
      Remote.SendInput(i, S);
  end
  else if (Panes[i] <> nil) and Panes[i].Alive then
    Panes[i].WriteStr(S);
end;

function TSuperApp.AttachRemoteSession(const APath: string): boolean;
var
  Snapshot: TSessionSnapshot;
  NewLay, OldLay: TLayout;
  Stream: TMemoryStream;
  I, N, SysIdx: integer;
  OldActiveProfile, OldActiveWindow: integer;
  OldProfileMode: boolean;
  OldSessionName: string;
  TitleS: string;
  Loaded: boolean;
  GR: Objects.TRect;
  PW, PH: integer;
begin
  if DebugActive then DebugLog('attach: AttachRemoteSession begin (build remote workspace)');
  Result := False;
  Remote := TSessionClient.Create;
  if not Remote.Connect(APath, Snapshot) then
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
  if not LoadLayoutString(Snapshot.LayoutNodes, NewLay) then
  begin
    Remote.Free;
    Remote := nil;
    Exit;
  end;
  N := Snapshot.PaneCount;
  if (N < 1) or (N > MAX_PANES) or (NewLay.PaneCount <> N) then
  begin
    NewLay.Free;
    Remote.Free;
    Remote := nil;
    Exit;
  end;
  // save the previous state: per-pane loading can still fail (corrupt
  // screen blob or window not created) and it must be restorable
  OldLay := Lay;
  OldProfileMode := ProfileMode;
  OldActiveProfile := ActiveProfile;
  OldActiveWindow := ActiveWindow;
  OldSessionName := CurrentSessionName;
  Lay := NewLay;
  Lay.Focused := Snapshot.Focused;
  if (Lay.Focused < 0) or (Lay.Focused >= N) then
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
    CreateWindowForPane(I, TitleS);
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
    NewLay.Free;
    Remote.Free;
    Remote := nil;
    Exit;
  end;
  OldLay.Free;
  RelayoutAll;
  // window geometry the daemon keeps (moved, maximized, minimized);
  // only applicable if the desktop size matches the one at save time
  if (Length(Snapshot.Geom) = Lay.PaneCount) and (Desktop <> nil) then
  begin
    GR := Default(Objects.TRect);
    Desktop^.GetExtent(GR);
    if (Snapshot.DeskW = GR.B.X - GR.A.X) and
       (Snapshot.DeskH = GR.B.Y - GR.A.Y) then
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
        end;
      for I := 0 to Lay.PaneCount - 1 do
        if (I < MAX_PANES) and (Win[I] <> nil) and
           Snapshot.Geom[I].Minimized then
          MinimizeWindow(I);
    end;
  end;
  // the windows are already in their final place: ONE size request
  // per pane (exact mirror of ChangeBounds); with no transients the
  // daemon does not bounce sizes to other clients as this one attaches
  RemoteAttachSettling := False;
  for I := 0 to Lay.PaneCount - 1 do
    if (I < MAX_PANES) and (Win[I] <> nil) and
       (not Win[I]^.Minimized) and (Scr[I] <> nil) then
    begin
      PW := Win[I]^.Size.X - 2;
      PH := Win[I]^.Size.Y - 2;
      if PW < 4 then PW := 4;
      if PH < 2 then PH := 2;
      if (PW <> Scr[I].Width) or (PH <> Scr[I].Height) then
      begin
        Scr[I].Resize(PW, PH);
        Remote.SendResize(I, PW, PH);
      end;
    end;
  RepaintChanges;
  FocusPane(Lay.Focused);
  RebuildMenu;
  CurrentSessionSocket := APath;
  RemoteLayoutHash := ComputeLayoutHash;
  Result := True;
end;

// server-always startup: the local workspace (panes already alive)
// moves to a child daemon and this process becomes its first
// interactive client; if fork or attach fails, stay local (degrade)
procedure TSuperApp.PromoteToServer;
var
  N, I: integer;
  PtyRefs: TPtyArray;
  ScreenRefs: TScreenArray;
  Titles, Terms: TStrArray;
  Fixed: TBoolArray;
  DGeom: TPaneGeomArray;
  DW, DH: integer;
  SessName, ProfName, Sock: string;
  WasProfile: boolean;
  OldActiveProfile, OldActiveWindow: integer;
begin
  if RemoteMode or AbortRun or DetachRequested then
    Exit;
  if DebugActive then DebugLog('promote: PromoteToServer begin (fork daemon, hand off PTYs, re-attach)');
  if Cfg.ServerMode <> 'always' then
    Exit;
  N := Lay.PaneCount;
  if (N < 1) or (N > MAX_PANES) then
    Exit;
  // automatic name, no dialogs: --session > active profile > session
  ProfName := '';
  if ProfileMode and (ActiveProfile >= 0) and
     (ActiveProfile < Length(Profiles)) then
    ProfName := Profiles[ActiveProfile].Name;
  if CliSessionName <> '' then
    SessName := SuggestSessionName(SanitizeSessionName(CliSessionName))
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
  if not StartDetachedServer(SessName, ProfName, Lay, PtyRefs, ScreenRefs,
    Titles, Terms, Lay.Focused, DGeom, DW, DH, Fixed) then
    Exit;   // no daemon: classic local mode
  Sock := SessionSocketPathFor(SessName);
  // the daemon now owns the processes: release the parent's PTYs
  // without signalling anyone and swap the workspace for the remote
  for I := 0 to MAX_PANES - 1 do
    if Panes[I] <> nil then
    begin
      Panes[I].Abandon;
      Panes[I].Free;
      Panes[I] := nil;
    end;
  ReleaseRuntime;
  // attach resets the profile state (it is meant for attaching to
  // foreign sessions); here the session IS the active profile: keep it
  WasProfile := ProfileMode;
  OldActiveProfile := ActiveProfile;
  OldActiveWindow := ActiveWindow;
  if not AttachRemoteSession(Sock) then
  begin
    // very rare (newborn daemon): do not orphan it nor pretend there
    // is a workspace; shut down in an orderly fashion
    CloseSessionAt(Sock);
    SkipSave := True;
    AbortRun := True;
    Message(@Self, evCommand, cmQuit, nil);
    Exit;
  end;
  ProfileMode := WasProfile;
  ActiveProfile := OldActiveProfile;
  ActiveWindow := OldActiveWindow;
  if ProfileMode then
    RebuildMenu;
end;

// leaves the current remote session closing its daemon: the profile
// switch or the wizard rebuild the workspace locally and re-promote
procedure TSuperApp.LeaveRemoteSession;
begin
  if not RemoteMode then
    Exit;
  if (Remote <> nil) and Remote.Connected then
    Remote.CloseSession(False);
  if Remote <> nil then
  begin
    Remote.Free;
    Remote := nil;
  end;
  RemoteMode := False;
  CurrentSessionSocket := '';
  CurrentSessionName := '';
  ReleaseRuntime;
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
    Result := AttachRemoteSession(Path);
end;

// session manager inside the app: list, purge and close; hot session
// switching will come later (detach first)
procedure TSuperApp.DoSessionPick;
var
  Act: TSessionPickAction;
  Path: string;
begin
  Path := '';
  Act := RunSessionPicker(False, Path);
  if Act = spAttach then
    MessageBox(UiText(
      'Detach first (' + PrefixKeyLabel(Cfg.PrefixKey) +
      ' d) and run superterm --attach to connect.',
      'Separa primero (' + PrefixKeyLabel(Cfg.PrefixKey) +
      ' d) y usa superterm --attach para conectar.'),
      nil, mfInformation or mfOKButton);
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
begin
  if DetachRequested then
    Exit;
  if RemoteMode then
  begin
    // client already attached: the daemon keeps its name, no prompt;
    // push the layout first so the next attach restores it
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
  if (N < 1) or (N > MAX_PANES) then
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
  if not StartDetachedServer(SessName, ProfName, Lay, PtyRefs, ScreenRefs,
    Titles, Terms, Lay.Focused, DGeom, DW, DH, Fixed) then
  begin
    MessageBox(UiText('Could not create the detached session server.',
      'No se pudo crear el servidor de la sesion separada.'), nil,
      mfError or mfOKButton);
    Exit;
  end;
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
  Started: boolean;
  CommandOverride, LocalCmd, ShellFor, TitleS: string;
begin
  Result := False;
  if (AProfile < 0) or (AProfile >= Length(Profiles)) or
     (not Profiles[AProfile].Enabled) then
    Exit;
  if (AWindow < 0) or (AWindow >= Length(Profiles[AProfile].Windows)) or
     (not Profiles[AProfile].Windows[AWindow].Enabled) then
    Exit;
  // switching profiles while attached: the remote session is closed
  // and the new workspace is built locally (re-promoted at the end)
  WasRemote := RemoteMode;
  if RemoteMode then
    LeaveRemoteSession;

  WS := Profiles[AProfile].Windows[AWindow];
  if not LoadLayoutString(WS.Layout, NewLay) then
    NewLay := TLayout.Create;
  n := NewLay.PaneCount;
  DebugLog(Format('profile activate p=%d w=%d layout=%s leaves=%d specs=%d',
    [AProfile, AWindow, WS.Layout, n, Length(WS.Panes)]));
  if (Length(WS.Panes) > n) or (n < 1) or (n > MAX_PANES) then
  begin
    NewLay.Free;
    Exit;
  end;

  StopRuntime;
  if Lay <> nil then
    Lay.Free;
  Lay := NewLay;
  ActiveProfile := AProfile;
  ActiveWindow := AWindow;

  Started := True;
  for i := 0 to n - 1 do
  begin
    PS := Default(TProfilePaneSpec);
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
  if not Started then
  begin
    StopRuntime;
    Exit;
  end;
  Lay.Focused := WS.FocusedPane;
  if (Lay.Focused < 0) or (Lay.Focused >= n) or (Win[Lay.Focused] = nil) then
    Lay.Focused := 0;
  RelayoutAll;
  ApplyWindowGeometry(WS);
  FocusPane(Lay.Focused);
  RebuildMenu;
  Result := True;
  if WasRemote then
    PromoteToServer;   // the new session is also born with a server
end;

// reapplies the EXACT geometry saved in the profile (manual
// position/size, maximized and minimized), leaving everything as
// saved; only if the desktop size matches (bounds are absolute)
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
      if WS.Panes[i].Zoomed and (not Win[i]^.Zoomed) then
        Win[i]^.Zoom;
    end;
  // minimized ones last (MinimizeWindow manages focus and icons)
  for i := 0 to n - 1 do
    if (i <= High(WS.Panes)) and (i < MAX_PANES) and (Win[i] <> nil) and
       WS.Panes[i].Minimized then
      MinimizeWindow(i);
end;

function TSuperApp.CaptureCurrentAsWindow(const AName: string): TProfileWindowSpec;
var
  i, n: integer;
  CurTitle, DefTitle: string;
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
  // desktop size: the saved bounds are absolute and are reapplied
  // only if the desktop size matches when restoring the profile
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
    Result.Panes[i].Name := 'pane' + IntToStr(i + 1);
    Result.Panes[i].Enabled := True;
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
      Result.Panes[i].Zoomed := Win[i]^.Zoomed;
    end;
    // custom title: saved only if it differs from the class default
    // title (so the profile does not pin a title the class provides)
    if (Win[i] <> nil) and Win[i]^.TitleFixed and (Win[i]^.Title <> nil) then
    begin
      CurTitle := Trim(Win[i]^.Title^);
      DefTitle := '';
      if (PaneTerm[i] >= 0) and (PaneTerm[i] < Length(WClasses)) then
      begin
        if WClasses[PaneTerm[i]].Title <> '' then
          DefTitle := WClasses[PaneTerm[i]].Title
        else
          DefTitle := WClasses[PaneTerm[i]].Name;
      end;
      if CurTitle <> DefTitle then
        Result.Panes[i].Title := CurTitle;
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

procedure TSuperApp.SaveWorkspaceAsProfile(const AName: string);
var
  P: TProfileSpec;
  idx: integer;
begin
  P := Default(TProfileSpec);
  P.Name := AName;
  P.Enabled := True;
  P.Origin := coUser;
  P.FocusedWindow := 0;
  SetLength(P.Windows, 1);
  P.Windows[0] := CaptureCurrentAsWindow(UiText('main', 'principal'));
  idx := FindProfileByName(Profiles, AName);
  if idx >= 0 then
    Profiles[idx] := P
  else
  begin
    SetLength(Profiles, Length(Profiles) + 1);
    Profiles[High(Profiles)] := P;
  end;
  SaveProfiles(ConfigFile, Profiles);
  RebuildMenu;
end;

procedure TSuperApp.RunProfileSaveAs;
var
  NameS: string;
  Buf: ShortString;
begin
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
  SaveWorkspaceAsProfile(NameS);
  // no FormatStr: the name could contain '%'
  MessageBox(UiText('Profile saved: ', 'Perfil guardado: ') + NameS, nil,
    mfInformation or mfOKButton);
end;

procedure TSuperApp.DoProfileManage;
var
  Act: TProfileAction;
  Tgt, DefIdx: integer;
begin
  DefIdx := FindProfileByName(Profiles, Cfg.DefaultProfile);
  if not RunProfileManager(Profiles, ActiveProfile, DefIdx, Act, Tgt) then
    Exit;
  case Act of
    paActivate:
      DoSwitchProfile(Tgt);
    paSaveCurrent:
      if (Tgt >= 0) and (Tgt < Length(Profiles)) then
      begin
        if ProfileMode and (Tgt = ActiveProfile) and (ActiveWindow >= 0) and
           (ActiveWindow < Length(Profiles[Tgt].Windows)) then
          // save the current workspace ONLY into the active window of the
          // profile, preserving its other windows
          Profiles[Tgt].Windows[ActiveWindow] :=
            CaptureCurrentAsWindow(Profiles[Tgt].Windows[ActiveWindow].Name)
        else
        begin
          SetLength(Profiles[Tgt].Windows, 1);
          Profiles[Tgt].Windows[0] :=
            CaptureCurrentAsWindow(UiText('main', 'principal'));
          Profiles[Tgt].FocusedWindow := 0;
        end;
        Profiles[Tgt].Origin := coUser;
        SaveProfiles(ConfigFile, Profiles);
      end;
    paSetDefault:
      if (Tgt >= 0) and (Tgt < Length(Profiles)) then
      begin
        Cfg.DefaultProfile := Profiles[Tgt].Name;
        SaveConfig(Cfg);
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
  Started: boolean;
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
  RebuildMenu;
end;

procedure TSuperApp.ShowHelp;
var
  R: Objects.TRect;
  D: PDialog;
  Lines: array[0..6] of string;
  I: integer;
begin
  // standard dialog: dialog palette with proper contrast (the old
  // THelpDialog painted with GetColor(1), the passive frame color)
  Lines[0] := UiText(
    'F2/F3 split panes; F6/F7 next/prev pane; Alt-1..9 go to pane N',
    'F2/F3 dividen paneles; F6/F7 panel sig./ant.; Alt-1..9 ir al panel N');
  Lines[1] := UiText(
    'F5 zoom; Alt-F9 minimize; Ctrl-F5 move/resize; Alt-F3 close pane',
    'F5 zoom; Alt-F9 minimiza; Ctrl-F5 mover/tamano; Alt-F3 cierra panel');
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
  Lines[4] := UiText(
    PrefixKeyLabel(Cfg.PrefixKey) + ' d detach; superterm --attach ' +
    'returns; Ctrl-S save',
    PrefixKeyLabel(Cfg.PrefixKey) + ' d separa; superterm --attach ' +
    'vuelve; Ctrl-S guarda');
  Lines[5] := UiText(
    'Profiles menu saves and restores named workspaces',
    'El menu Perfiles guarda y restaura areas de trabajo con nombre');
  Lines[6] := UiText(
    'Alt-X save and exit; Alt-Q quit without saving',
    'Alt-X guarda y sale; Alt-Q sale sin guardar');
  R.Assign(0, 0, 74, 13);
  D := New(PDialog, Init(R, UiText('Help and shortcuts', 'Ayuda y atajos')));
  D^.Options := D^.Options or ofCentered;
  for I := 0 to High(Lines) do
  begin
    R.Assign(3, 2 + I, 71, 3 + I);
    D^.Insert(New(PStaticText, Init(R, Lines[I])));
  end;
  D^.NewButton(31, 10, 12, 2, UiText('~O~K', '~A~ceptar'), cmOK,
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
  Win[i]^.SetTitle(' ' + Cur);
  Win[i]^.TitleFixed := True;
  // in remote mode the fixed title must live in the daemon (it is
  // broadcast to other clients and survives the daemon-side save)
  if RemoteMode and (Remote <> nil) and Remote.Connected then
    Remote.SendRename(i, Cur);
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

procedure TSuperApp.RememberProfileSelection;
begin
  if (ActiveProfile >= 0) and (ActiveProfile < Length(Profiles)) then
    Cfg.DefaultProfile := Profiles[ActiveProfile].Name;
  if (ActiveProfile >= 0) and (ActiveProfile < Length(Profiles)) and
     (ActiveWindow >= 0) and
     (ActiveWindow < Length(Profiles[ActiveProfile].Windows)) then
    Cfg.DefaultWindow := Profiles[ActiveProfile].Windows[ActiveWindow].Name;
end;

procedure TSuperApp.DoSwitchProfile(AIndex: integer);
var
  W, I, OldP, OldW: integer;
begin
  if (AIndex < 0) or (AIndex >= Length(Profiles)) or
     (not Profiles[AIndex].Enabled) then
    Exit;
  OldP := ActiveProfile;
  OldW := ActiveWindow;
  W := -1;
  if (Profiles[AIndex].FocusedWindow >= 0) and
     (Profiles[AIndex].FocusedWindow < Length(Profiles[AIndex].Windows)) and
     Profiles[AIndex].Windows[Profiles[AIndex].FocusedWindow].Enabled then
    W := Profiles[AIndex].FocusedWindow;
  if W < 0 then
    for I := 0 to Length(Profiles[AIndex].Windows) - 1 do
      if Profiles[AIndex].Windows[I].Enabled then
      begin
        W := I;
        Break;
      end;
  if (W < 0) or not ActivateProfile(AIndex, W) then
  begin
    if (OldP >= 0) and (OldW >= 0) then
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
  if PaneCount <= 1 then
  begin
    Message(@Self, evCommand, cmQuit, nil);
    Exit;
  end;
  OldFocused := Lay.Focused;
  // in remote mode the pane lives in the daemon: kill it there and
  // compact mirroring it (same indexes); locally KillPane does the job
  if RemoteMode and (Remote <> nil) and Remote.Connected then
    Remote.SendKillPane(i);
  Lay.ClosePane(i);
  KillPane(i);
  for j := i to MAX_PANES - 2 do
  begin
    Panes[j] := Panes[j + 1];
    Scr[j] := Scr[j + 1];
    Win[j] := Win[j + 1];
    PaneTerm[j] := PaneTerm[j + 1];
    if Win[j] <> nil then
    begin
      Win[j]^.PaneIdx := j;
      Win[j]^.Number := j + 1;
      if Win[j]^.Term <> nil then
        Win[j]^.Term^.PaneIdx := j;
    end;
  end;
  Panes[MAX_PANES - 1] := nil;
  Scr[MAX_PANES - 1] := nil;
  Win[MAX_PANES - 1] := nil;
  PaneTerm[MAX_PANES - 1] := -1;
  if OldFocused > i then
    Lay.Focused := OldFocused - 1
  else
    Lay.Focused := OldFocused;
  if Lay.Focused >= PaneCount then
    Lay.Focused := PaneCount - 1;
  if (Lay.Focused < 0) or (Lay.Focused >= MAX_PANES) or
     (Win[Lay.Focused] = nil) or Win[Lay.Focused]^.Minimized then
    Lay.Focused := FirstVisiblePane;
  // do NOT re-tile: remaining windows keep their size and position.
  // KillPane already removed the closed one from the desktop; repaint.
  RepaintChanges;
  FocusPane(Lay.Focused);
  SyncRemoteLayout; // the tree changed: mirror it in the daemon
end;

// current geometry of all windows (same rules as the local save: a
// maximized one contributes its ZoomRect, a minimized one its bounds)
procedure TSuperApp.CollectPaneGeom(out AGeom: TPaneGeomArray;
  out ADeskW, ADeskH: integer);
var
  n, i: integer;
  WR, RD: Objects.TRect;
begin
  AGeom := Default(TPaneGeomArray);
  ADeskW := 0;
  ADeskH := 0;
  n := Lay.PaneCount;
  if (n < 1) or (Desktop = nil) then
    Exit;
  RD := Default(Objects.TRect);
  Desktop^.GetExtent(RD);
  ADeskW := RD.B.X - RD.A.X;
  ADeskH := RD.B.Y - RD.A.Y;
  SetLength(AGeom, n);
  for i := 0 to n - 1 do
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
      AGeom[i].BX := WR.A.X;
      AGeom[i].BY := WR.A.Y;
      AGeom[i].BW := WR.B.X - WR.A.X;
      AGeom[i].BH := WR.B.Y - WR.A.Y;
      AGeom[i].Zoomed := Win[i]^.Zoomed;
      AGeom[i].Minimized := Win[i]^.Minimized;
    end;
end;

// while attached, pushes the client state to the daemon so the next
// attach restores exactly what is on screen now
procedure TSuperApp.SyncRemoteLayout;
var
  Geom: TPaneGeomArray;
  Titles: TStrArray;
  DeskW, DeskH: integer;
  n, i: integer;
begin
  if (not RemoteMode) or (Remote = nil) or (not Remote.Connected) then
    Exit;
  n := Lay.PaneCount;
  if n < 1 then
    Exit;
  CollectPaneGeom(Geom, DeskW, DeskH);
  if Length(Geom) <> n then
    Exit;
  Titles := Default(TStrArray);
  SetLength(Titles, n);
  for i := 0 to n - 1 do
    if (i < MAX_PANES) and (Win[i] <> nil) then
      Titles[i] := Win[i]^.GetTitle(80);
  Remote.SendLayout(SaveLayoutString(Lay), Lay.Focused, Titles, Geom,
    DeskW, DeskH);
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
  PassthroughActive := True;   // silences all FreeVision screen writes
  // hand a clean surface to the app: show cursor, reset attrs, clear.
  // Also RELEASE the mouse: turn superterm's own tracking off so, in
  // fullscreen, a drag selects text normally and clicks are NOT reported to
  // FreeVision (a click on the hidden-but-logical menu row would otherwise pop
  // the menu and drop out of zoom). The app (Claude) re-asserts whatever mouse
  // modes it wants through its raw output; ExitPassthrough re-enables ours.
  WriteRaw(#27'[?25h'#27'[0m'#27'[2J'#27'[H' +
    #27'[?1000l'#27'[?1002l'#27'[?1003l'#27'[?1006l');
  // resize the pane's PTY to the full terminal (menu + desktop + status
  // rows included). Single client => the daemon applies it as-is; the
  // RESIZE_EV round-trip in ApplyRemoteResize aborts if another client
  // constrains the size (falls back to grid rendering).
  if Scr[i] <> nil then
    Scr[i].Resize(ScreenWidth, ScreenHeight);
  if RemoteMode then
  begin
    if (Remote <> nil) and Remote.Connected then
      Remote.SendResize(i, ScreenWidth, ScreenHeight);
  end
  else if Panes[i] <> nil then
    Panes[i].Resize(ScreenWidth, ScreenHeight);
end;

// reclaim the terminal for the window manager: reset the modes the app may
// have set, restore the pane's windowed size, and force one clean full
// repaint so menus, status line and window frames come back.
// Cosmetic zoom transition: a handful of outline frames interpolating between
// the window's rectangle and the full desktop. It reuses the wireframe-drag
// primitives, so each frame costs only its ring. Opt-in (Options > zoom
// transition); the default F5 stays instant.
procedure TSuperApp.ZoomAnimate(AX1, AY1, AX2, AY2, BX1, BY1, BX2, BY2: integer);
const
  STEPS = 8;
  FRAME_MS = 45;
var
  k, x1, y1, x2, y2: integer;
begin
  if PassthroughActive or (Desktop = nil) then
    Exit;
  for k := 1 to STEPS do
  begin
    x1 := AX1 + ((BX1 - AX1) * k) div STEPS;
    y1 := AY1 + ((BY1 - AY1) * k) div STEPS;
    x2 := AX2 + ((BX2 - AX2) * k) div STEPS;
    y2 := AY2 + ((BY2 - AY2) * k) div STEPS;
    OutlinePaint(x1, y1, x2, y2, $1F);
    Sleep(FRAME_MS);
    OutlineRestore(x1, y1, x2, y2);
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
  WriteRaw(#27'[?1049h'#27'[0m'#27'[?7l'#27'[?25h' +
    #27'[?1000h'#27'[?1002h'#27'[?1003h'#27'[?1006h'#27'[?2004l' +
    #27']22;default'#27'\');
  // Resize ONLY the pane that owned the screen, to the bounds its window
  // already has. Un-zooming (F5) restored those bounds itself, but the
  // ChangeBounds guard suppressed the PTY resize while passthrough was active,
  // so the PTY is still full-screen and must be synced here. Do NOT call
  // RelayoutAll: that re-tiles every window and overwrites the size the user's
  // window had (an 80x20 pane came back filling the whole screen).
  if (P >= 0) and (P < MAX_PANES) and (Win[P] <> nil) and
     (not Win[P]^.Minimized) and (Scr[P] <> nil) then
  begin
    pw := Win[P]^.Size.X - 2;
    ph := Win[P]^.Size.Y - 2;
    if pw < 4 then pw := 4;
    if ph < 2 then ph := 2;
    if (pw <> Scr[P].Width) or (ph <> Scr[P].Height) then
    begin
      Scr[P].Resize(pw, ph);
      if RemoteMode then
      begin
        if (Remote <> nil) and Remote.Connected then
          Remote.SendResize(P, pw, ph);
      end
      else if Panes[P] <> nil then
        Panes[P].Resize(pw, ph);
    end;
  end;
  ResetVideoSurface;   // blank both buffers
  ReDraw;              // full repaint of menu, desktop, windows and status
  if (Lay.Focused >= 0) and (Lay.Focused < MAX_PANES) then
    FocusPane(Lay.Focused);
end;

// derive passthrough purely from the maximized state, once per Idle tick,
// so any window-management action (restore, minimize, switch, close, split)
// leaves it automatically without wiring every command.
procedure TSuperApp.UpdatePassthrough;
var
  f: integer;
  want: boolean;
begin
  f := Lay.Focused;
  want := (f >= 0) and (f < MAX_PANES) and (Win[f] <> nil) and
    Win[f]^.Zoomed and (Current = PView(Desktop));
  if want and (not PassthroughActive) then
    EnterPassthrough(f)
  else if PassthroughActive and (not want) then
    ExitPassthrough
  else if PassthroughActive and
    ((ScreenWidth <> PassReqW) or (ScreenHeight <> PassReqH)) then
  begin
    // host terminal was resized while passthrough was on: re-request the
    // new full size so the app repaints to fit
    PassReqW := ScreenWidth;
    PassReqH := ScreenHeight;
    if Scr[PassPane] <> nil then
      Scr[PassPane].Resize(ScreenWidth, ScreenHeight);
    if RemoteMode then
    begin
      if (Remote <> nil) and Remote.Connected then
        Remote.SendResize(PassPane, ScreenWidth, ScreenHeight);
    end
    else if Panes[PassPane] <> nil then
      Panes[PassPane].Resize(ScreenWidth, ScreenHeight);
  end;
end;

// fingerprint of the visible state (geometry+titles+focus): if it
// differs from the last sync, the layout must be pushed to the daemon
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
  Result := IntToStr(Lay.PaneCount) + ':' + IntToStr(Lay.Focused) + ':' +
    IntToStr(DeskW) + 'x' + IntToStr(DeskH);
  for i := 0 to Length(Geom) - 1 do
  begin
    Result := Result + Format('|%d,%d,%d,%d,%d,%d',
      [Geom[i].BX, Geom[i].BY, Geom[i].BW, Geom[i].BH,
       Ord(Geom[i].Zoomed), Ord(Geom[i].Minimized)]);
    if (i < MAX_PANES) and (Win[i] <> nil) then
      Result := Result + ',' + Win[i]^.GetTitle(80);
  end;
end;

// applies a LAYOUT_EV broadcast by the daemon (another client moved,
// minimized or renamed windows): tree, titles, geometry and focus
procedure TSuperApp.ApplyRemoteLayoutEv(const AData: TByteArray);
var
  Nodes: string;
  Focused, DeskW, DeskH: Longint;
  Titles: TStrArray;
  Geom: TPaneGeomArray;
  NewLay: TLayout;
  I: integer;
  GR: Objects.TRect;
begin
  if not DecodeLayoutBlob(AData, Nodes, Focused, Titles, Geom, DeskW,
    DeskH) then
    Exit;
  if Length(Titles) <> Lay.PaneCount then
    Exit;   // out of sync: another event will arrive after convergence
  NewLay := nil;
  if LoadLayoutString(Nodes, NewLay) and (NewLay <> nil) then
  begin
    if NewLay.PaneCount = Lay.PaneCount then
    begin
      Lay.Free;
      Lay := NewLay;
    end
    else
      NewLay.Free;
  end;
  for I := 0 to Lay.PaneCount - 1 do
    if (I < MAX_PANES) and (Win[I] <> nil) and (Trim(Titles[I]) <> '') then
      Win[I]^.SetTitle(' ' + Trim(Titles[I]));
  if Desktop <> nil then
  begin
    GR := Default(Objects.TRect);
    Desktop^.GetExtent(GR);
    // geometry only if both desktops have the same size
    if (DeskW = GR.B.X - GR.A.X) and (DeskH = GR.B.Y - GR.A.Y) then
    begin
      for I := 0 to Lay.PaneCount - 1 do
        if (I < MAX_PANES) and (Win[I] <> nil) then
        begin
          if Win[I]^.Minimized and (not Geom[I].Minimized) then
            RestoreWindow(I);
          if (Geom[I].BW > 0) and (Geom[I].BH > 0) and
             (not Geom[I].Minimized) then
          begin
            GR.Assign(Geom[I].BX, Geom[I].BY, Geom[I].BX + Geom[I].BW,
              Geom[I].BY + Geom[I].BH);
            Win[I]^.Locate(GR);
          end;
          if Geom[I].Zoomed <> Win[I]^.Zoomed then
            Win[I]^.Zoom;
        end;
      for I := 0 to Lay.PaneCount - 1 do
        if (I < MAX_PANES) and (Win[I] <> nil) and Geom[I].Minimized and
           (not Win[I]^.Minimized) then
          MinimizeWindow(I);
    end;
  end;
  if (Focused >= 0) and (Focused < Lay.PaneCount) then
  begin
    Lay.Focused := Focused;
    FocusPane(Focused);
  end;
  RepaintChanges;
  // what was applied is the common state: do not re-push (no bounces)
  RemoteLayoutHash := ComputeLayoutHash;
end;

// another client (or the CLI) closed a pane: compact in daemon mirror
procedure TSuperApp.ApplyRemoteKillPane(APane: integer);
var
  j, OldFocused: integer;
begin
  if (APane < 0) or (APane >= MAX_PANES) or (Win[APane] = nil) or
     (PaneCount <= 1) then
    Exit;
  OldFocused := Lay.Focused;
  Lay.ClosePane(APane);
  KillPane(APane);
  for j := APane to MAX_PANES - 2 do
  begin
    Panes[j] := Panes[j + 1];
    Scr[j] := Scr[j + 1];
    Win[j] := Win[j + 1];
    PaneTerm[j] := PaneTerm[j + 1];
    if Win[j] <> nil then
    begin
      Win[j]^.PaneIdx := j;
      Win[j]^.Number := j + 1;
      if Win[j]^.Term <> nil then
        Win[j]^.Term^.PaneIdx := j;
    end;
  end;
  Panes[MAX_PANES - 1] := nil;
  Scr[MAX_PANES - 1] := nil;
  Win[MAX_PANES - 1] := nil;
  PaneTerm[MAX_PANES - 1] := -1;
  if OldFocused > APane then
    Lay.Focused := OldFocused - 1
  else
    Lay.Focused := OldFocused;
  if Lay.Focused >= PaneCount then
    Lay.Focused := PaneCount - 1;
  if (Lay.Focused < 0) or (Lay.Focused >= MAX_PANES) or
     (Win[Lay.Focused] = nil) or Win[Lay.Focused]^.Minimized then
    Lay.Focused := FirstVisiblePane;
  RepaintChanges;
  FocusPane(Lay.Focused);
  RemoteLayoutHash := ComputeLayoutHash;
end;

// the daemon created a pane (requested by this client, another one
// or the CLI): repeat the split locally and give it a window
procedure TSuperApp.ApplyRemoteNewPane(const AData: TByteArray);
var
  At, NewIdx, PC, Cols, Rows: Longint;
  Dir: byte;
  TitleS, TermS: string;
  OldCount, j: integer;
  SDir: TSplitDir;
begin
  if not DecodeNewPaneEv(AData, At, NewIdx, PC, Dir, Cols, Rows,
    TitleS, TermS) then
    Exit;
  if (Lay.PaneCount + 1 <> PC) or (At < 0) or (At >= Lay.PaneCount) or
     (PC > MAX_PANES) then
    Exit;   // out of sync: better not to touch anything
  OldCount := Lay.PaneCount;
  if Dir = 1 then
    SDir := sdH
  else
    SDir := sdV;
  if not Lay.SplitPane(At, SDir) then
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
    if Win[j] <> nil then
    begin
      Win[j]^.PaneIdx := j;
      Win[j]^.Number := j + 1;
      if Win[j]^.Term <> nil then
        Win[j]^.Term^.PaneIdx := j;
    end;
  end;
  Panes[NewIdx] := nil;
  PaneTerm[NewIdx] := FindWindowClass(TermS);
  Scr[NewIdx] := TScreen.Create(Cols, Rows, DEFAULT_SCROLLBACK);
  if Trim(TitleS) = '' then
    TitleS := UiText('session pane', 'panel de sesion');
  CreateWindowForPane(NewIdx, Trim(TitleS));
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
      if Win[j] <> nil then
      begin
        Win[j]^.PaneIdx := j;
        Win[j]^.Number := j + 1;
        if Win[j]^.Term <> nil then
          Win[j]^.Term^.PaneIdx := j;
      end;
    end;
    Panes[OldCount] := nil;
    Scr[OldCount] := nil;
    Win[OldCount] := nil;
    PaneTerm[OldCount] := -1;
    Exit;
  end;
  RelayoutAll;
  Lay.Focused := NewIdx;
  FocusPane(NewIdx);
  RemoteLayoutHash := ComputeLayoutHash;
end;

// authoritative daemon size (common minimum among clients): adjust
// the TScreen without resending a request (echo suppression)
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
  if (C < 4) or (R < 2) then
    Exit;
  // while a pane is drawn raw its size is owned by EnterPassthrough; ignore
  // resize echoes for it (incl. the stale desktop-size echo from the zoom
  // that preceded passthrough). Passthrough assumes a single attached
  // client -- see EnterPassthrough.
  if PassthroughActive and (APane = PassPane) then
    Exit;
  if (C <> Scr[APane].Width) or (R <> Scr[APane].Height) then
  begin
    Scr[APane].Resize(C, R);
    if (Win[APane] <> nil) and (Win[APane]^.Term <> nil) then
      Win[APane]^.Term^.DrawView;
  end;
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
begin
  for i := 0 to MAX_PANES - 1 do
    if (Win[i] <> nil) and Win[i]^.Minimized then
      RestoreWindow(i);
  RelayoutAll;
  RepaintChanges;
  FocusPane(Lay.Focused);
  SyncRemoteLayout;
end;

// classic Window|Cascade: staggered windows at 2/3 of the desktop
procedure TSuperApp.DoCascadePanes;
var
  RD, R: Objects.TRect;
  i, k, w, h, maxoff: integer;
begin
  if Desktop = nil then
    Exit;
  RD := Default(Objects.TRect);
  Desktop^.GetExtent(RD);
  w := (RD.B.X - RD.A.X) * 2 div 3;
  h := (RD.B.Y - RD.A.Y) * 2 div 3;
  if w < 20 then w := 20;
  if h < 6 then h := 6;
  maxoff := RD.B.Y - RD.A.Y - h - 1;
  if maxoff < 1 then maxoff := 1;
  k := 0;
  for i := 0 to MAX_PANES - 1 do
    if (Win[i] <> nil) and (not Win[i]^.Minimized) then
    begin
      R.Assign(RD.A.X + (k * 3) mod (RD.B.X - RD.A.X - w),
        RD.A.Y + k mod maxoff,
        RD.A.X + (k * 3) mod (RD.B.X - RD.A.X - w) + w,
        RD.A.Y + k mod maxoff + h);
      Win[i]^.Locate(R);
      Inc(k);
    end;
  RepaintChanges;
  FocusPane(Lay.Focused);
  SyncRemoteLayout;
end;

// vendor grid: spreads all visible windows into rows and columns
// that fit the screen (TDeskTop.Tile over the ofTileable views)
procedure TSuperApp.DoOrganizePanes;
var
  R: Objects.TRect;
  i: integer;
  HasIcons: boolean;
begin
  if Desktop = nil then
    Exit;
  R := Default(Objects.TRect);
  Desktop^.GetExtent(R);
  HasIcons := False;
  for i := 0 to MAX_PANES - 1 do
    if (Win[i] <> nil) and Win[i]^.Minimized then
      HasIcons := True;
  if HasIcons then
    Dec(R.B.Y, 2); // respect the icon strip
  Desktop^.Tile(R);
  RepaintChanges;
  FocusPane(Lay.Focused);
  SyncRemoteLayout;
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
  SaveConfig(Cfg);
  RebuildMenu;
  RebuildStatusLine;
  RepaintChanges;
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
      if PaneTerm[i] >= 0 then
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
      Pin[i].Zoomed := Win[i]^.Zoomed;
    end;
  end;
  RD := Default(Objects.TRect);
  Desktop^.GetExtent(RD);
  SaveSession(SessionFile, Lay, Pin, RD.B.X - RD.A.X, RD.B.Y - RD.A.Y);
end;

procedure TSuperApp.HandleEvent(var Event: TEvent);
var
  SaveReply: string;
  SavePayload: TByteArray;
  i: integer;
  ResizeEvent: boolean;
  ResizeWidth, ResizeHeight: integer;
  PrefixByte: byte;
  PrefixSeq: RawByteString;
  ZoomSaveFlush: boolean;
  ZoomAnimOn, ZoomWasZoomed: boolean;
  ZoomF: integer;
  ZoomWX1, ZoomWY1, ZoomWX2, ZoomWY2: integer;
  ZoomDX1, ZoomDY1, ZoomDX2, ZoomDY2: integer;
begin
  ResizeEvent := (Event.What = evCommand) and (Event.Command = cmResizeApp);
  ResizeWidth := Event.Id;
  ResizeHeight := Event.InfoWord;
  // In passthrough the maximized pane owns the whole terminal, so FreeVision
  // must NOT act on the mouse: a click on the hidden-but-still-logical menu
  // row would pop the menu and drop out of zoom. The mouse was released to the
  // app/terminal on EnterPassthrough (tracking off), so normal text selection
  // works; only F5 (a key, handled below) leaves passthrough. Swallow every
  // mouse event here before the inherited handler can dispatch it.
  if PassthroughActive and ((Event.What and evMouse) <> 0) then
  begin
    ClearEvent(Event);
    Exit;
  end;
  // F5 used to be visible in TWO steps: the window first maximized inside the
  // IDE (one painted frame, menu and status still there) and only on the next
  // Idle tick did passthrough take the screen -- which reads as a little
  // zoom animation. Same on the way back. Do the whole transition with the
  // flush held, then decide passthrough, then paint ONCE: straight to
  // fullscreen, and straight back to the IDE exactly as it was.
  if (Event.What = evCommand) and (Event.Command = cmZoom) then
  begin
    // optional transition: expand the outline out to full screen before
    // zooming in, and contract it back after restoring
    ZoomF := Lay.Focused;
    ZoomAnimOn := Cfg.ZoomAnim and (Desktop <> nil) and
      (ZoomF >= 0) and (ZoomF < MAX_PANES) and (Win[ZoomF] <> nil) and
      (not Win[ZoomF]^.Minimized);
    if ZoomAnimOn then
    begin
      ZoomWasZoomed := Win[ZoomF]^.Zoomed;
      ZoomWX1 := Desktop^.Origin.X + Win[ZoomF]^.Origin.X;
      ZoomWY1 := Desktop^.Origin.Y + Win[ZoomF]^.Origin.Y;
      ZoomWX2 := ZoomWX1 + Win[ZoomF]^.Size.X - 1;
      ZoomWY2 := ZoomWY1 + Win[ZoomF]^.Size.Y - 1;
      ZoomDX1 := Desktop^.Origin.X;
      ZoomDY1 := Desktop^.Origin.Y;
      ZoomDX2 := ZoomDX1 + Desktop^.Size.X - 1;
      ZoomDY2 := ZoomDY1 + Desktop^.Size.Y - 1;
      // growing: animate BEFORE the zoom, while the IDE is still on screen
      if not ZoomWasZoomed then
        ZoomAnimate(ZoomWX1, ZoomWY1, ZoomWX2, ZoomWY2,
                    ZoomDX1, ZoomDY1, ZoomDX2, ZoomDY2);
    end;
    ZoomSaveFlush := SuppressFlush;
    SuppressFlush := True;
    try
      inherited HandleEvent(Event);
      for i := 0 to MAX_PANES - 1 do
        if (Win[i] <> nil) and Win[i]^.GetState(sfSelected) then
          Lay.Focused := i;
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
      ZoomAnimate(ZoomDX1, ZoomDY1, ZoomDX2, ZoomDY2,
                  Desktop^.Origin.X + Win[ZoomF]^.Origin.X,
                  Desktop^.Origin.Y + Win[ZoomF]^.Origin.Y,
                  Desktop^.Origin.X + Win[ZoomF]^.Origin.X + Win[ZoomF]^.Size.X - 1,
                  Desktop^.Origin.Y + Win[ZoomF]^.Origin.Y + Win[ZoomF]^.Size.Y - 1);
    Exit;
  end;
  if Event.What = evKeyDown then
  begin
    PrefixByte := Event.KeyCode and $00FF;
    if PrefixPending then
    begin
      PrefixPending := False;
      // prefix chords (tmux style): d=detach, n/p=window +-,
      // 1..9=window N, arrows=pane size, double prefix=literal
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
      PrefixSeq := AnsiChar(Chr(Cfg.PrefixKey)) + TranslateKey(Event.KeyCode);
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
    // passthrough: the maximized pane owns the screen, so every key goes to
    // it -- bypass menu/status/Alt-1..9 which would otherwise steal F-keys,
    // Alt-letters and Ctrl-S. Two escapes are kept for superterm: the prefix
    // (handled above, detaches) and F5, which un-maximizes and is therefore
    // the way OUT of passthrough -- so F5 falls through to the zoom handler.
    if PassthroughActive and (Event.KeyCode <> kbF5) then
    begin
      PrefixSeq := TranslateKey(Event.KeyCode);
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
    if (Win[i] <> nil) and Win[i]^.GetState(sfSelected) then
      Lay.Focused := i;
  inherited HandleEvent(Event);
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
      cmWindowMinimize: MinimizeWindow(Lay.Focused);
      cmAbout: ShowAbout;
      cmRenameWindow: RenameFocusedWindow;
      cmPaneTile: DoTilePanes;
      cmPaneCascade: DoCascadePanes;
      cmPaneOrganize: DoOrganizePanes;
      cmPaneList: DoPaneList;
      cmRedrawAll:
        begin
          ResetVideoSurface;
          ReDraw;
        end;
      cmToggleAutoSave:
        begin
          Cfg.AutoSave := not Cfg.AutoSave;
          SaveConfig(Cfg);
          RebuildMenu;
        end;
      cmToggleDragContent:
        begin
          Cfg.DragContent := not Cfg.DragContent;
          SaveConfig(Cfg);
          RebuildMenu;
        end;
      cmToggleZoomAnim:
        begin
          Cfg.ZoomAnim := not Cfg.ZoomAnim;
          SaveConfig(Cfg);
          RebuildMenu;
        end;
      cmToggleAutoRestore:
        begin
          Cfg.AutoRestore := not Cfg.AutoRestore;
          SaveConfig(Cfg);
          RebuildMenu;
        end;
      cmWindowMinimizeAll: MinimizeAllWindows;
      cmWindowRestoreAll: RestoreAllWindows;
      cmSaveSess:
        begin
          // contextual toast: each mode states exactly what was saved
          if ProfileMode then
          begin
            RememberProfileSelection;
            SaveConfig(Cfg);
            MessageBox(UiText('Profile selection saved.',
              'Seleccion del perfil guardada.'), nil,
              mfInformation or mfOKButton);
          end
          else if RemoteMode then
          begin
            SyncRemoteLayout;
            SaveReply := '';
            SavePayload := nil;
            SetLength(SavePayload, 1);
            SavePayload[0] := WINOP_SAVE;
            if (CurrentSessionSocket <> '') and
               CtlSimple(CurrentSessionSocket, FRAME_CTL_WINOP, -1,
                 SavePayload, SaveReply) then
              MessageBox(UiText('Session saved by the server.',
                'Sesion guardada por el servidor.'), nil,
                mfInformation or mfOKButton)
            else
              MessageBox(UiText('Layout synced to the detached session.',
                'Layout sincronizado con la sesion separada.'), nil,
                mfInformation or mfOKButton);
          end
          else
          begin
            SaveSessionNow;
            MessageBox(UiText('Session layout saved.',
              'Layout de la sesion guardado.'), nil,
              mfInformation or mfOKButton);
          end;
        end;
      cmSessionWizard: RunSessionWizard;
      cmDetach: RequestDetach;
      cmSessionPick: DoSessionPick;
      cmClassPick:
        begin
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
          if RunClassManager(WClasses) then
            RebuildMenu;
        end;
      cmHelp: ShowHelp;
      cmQuitNoSave:
        begin
          SkipSave := True;
          Cfg.AutoSave := False;
          Message(@Self, evCommand, cmQuit, nil);
        end;
      cmGrowV: begin Lay.ResizeFocused(sdV, +1); RelayoutAll; end;
      cmShrinkV: begin Lay.ResizeFocused(sdV, -1); RelayoutAll; end;
      cmGrowH: begin Lay.ResizeFocused(sdH, +1); RelayoutAll; end;
      cmShrinkH: begin Lay.ResizeFocused(sdH, -1); RelayoutAll; end;
    else
      if (Event.Command >= cmLanguageBase) and
         (Event.Command < cmLanguageBase + 2) then
      begin
        CurrentLanguage := TUiLanguage(Event.Command - cmLanguageBase);
        Cfg.Language := CurrentLanguage;
        SetMessageBoxLanguage(CurrentLanguage = ulSpanish);
        SaveConfig(Cfg);
        RebuildMenu;
        RebuildStatusLine;
      end
      else if (Event.Command >= cmProfileBase) and
         (Event.Command < cmProfileBase + Length(Profiles)) then
        DoSwitchProfile(Event.Command - cmProfileBase)
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
         (Event.Command < cmOpenClass + Length(WClasses)) then
        DoOpenClassPane(Event.Command - cmOpenClass)
      else
        Exit;
    end;
    ClearEvent(Event);
  end;
end;

procedure TSuperApp.Idle;
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
  const
    LastTitle: cardinal = 0;
    LastBlink: cardinal = 0;
    LastSizeCheck: cardinal = 0;
    LastLayoutSync: cardinal = 0;
  begin
    inherited Idle;
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
  if RemoteMode then
  begin
    // with a modal open the socket is not drained: events (closing or
    // creating panes, output) wait in order for the modal to finish,
    // so pane indexes never desync in the middle of a dialog
    if Current = PView(Desktop) then
      while (Remote <> nil) and Remote.Poll(RemoteEvent) do
      begin
      case RemoteEvent.Kind of
        sekOutput:
          if (RemoteEvent.Pane >= 0) and (RemoteEvent.Pane < MAX_PANES) and
             (Length(RemoteEvent.Data) > 0) then
          begin
            if PassthroughActive and (RemoteEvent.Pane = PassPane) then
              // no parsing: the pane owns the terminal, write bytes verbatim
              PassthroughRaw(RemoteEvent.Data[0], Length(RemoteEvent.Data))
            else if Scr[RemoteEvent.Pane] <> nil then
            begin
              Scr[RemoteEvent.Pane].WriteBytes(RemoteEvent.Data[0],
                Length(RemoteEvent.Data));
              if Win[RemoteEvent.Pane] <> nil then
                Win[RemoteEvent.Pane]^.Term^.DrawView;
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
          DebugLog('remote session error: ' + RemoteEvent.Text);
        sekLayoutEv: ApplyRemoteLayoutEv(RemoteEvent.Data);
        sekKillPaneEv: ApplyRemoteKillPane(RemoteEvent.Pane);
        sekNewPaneEv: ApplyRemoteNewPane(RemoteEvent.Data);
        sekResizeEv: ApplyRemoteResize(RemoteEvent.Pane, RemoteEvent.Data);
        sekTitleEv: ApplyRemoteTitle(RemoteEvent.Pane, RemoteEvent.Data);
        sekFocusEv:
          if (RemoteEvent.Pane >= 0) and (RemoteEvent.Pane < MAX_PANES) and
             (Win[RemoteEvent.Pane] <> nil) then
          begin
            Lay.Focused := RemoteEvent.Pane;
            FocusPane(RemoteEvent.Pane);
            RemoteLayoutHash := ComputeLayoutHash;
          end;
        sekIgnore: ;
        sekShutdown:
          begin
            RemoteLost := True;
            RemoteMode := False;
            SkipSave := True;
            MessageBox(UiText('The session was closed.',
              'La sesion se cerro.'), nil, mfInformation or mfOKButton);
            Message(@Self, evCommand, cmQuit, nil);
          end;
        sekLost:
          begin
            RemoteLost := True;
            RemoteMode := False;
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
    // debounced layout push: moving, minimizing or renaming here gets
    // mirrored in the daemon (and from there to the other clients)
    // without hooking every single UI action
    if RemoteMode and (Current = PView(Desktop)) and
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
      if (i >= 0) and (i < MAX_PANES) and (Win[i] <> nil) and
         (Win[i]^.Term <> nil) then
        Win[i]^.Term^.DrawView;
    end;
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
    tv.tv_usec := 8000;
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
              PassthroughRaw(Buf[0], n)
            else
            begin
              Scr[i].WriteBytes(Buf, n);
              if Win[i] <> nil then
                Win[i]^.Term^.DrawView;
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
  else
    Sleep(8);
  // dead children
  st2 := Default(cint);
  repeat
    p := fpWaitPid(-1, st2, WNOHANG);
    if p > 0 then
      for i := 0 to MAX_PANES - 1 do
        if (Panes[i] <> nil) and (Panes[i].Pid = p) then
        begin
          Panes[i].MarkExited;
          if (PaneTerm[i] >= 0) and
             (PaneTerm[i] < Length(WClasses)) and
             (WClasses[PaneTerm[i]].Kind = wcSSH) then
            FallbackPane(i)
          else if Win[i] <> nil then
            Win[i]^.SetTitle(UiText(' EXITED', ' TERMINO'));
        end;
  until p <= 0;
  // blinking cursor of the focused pane
  if Tick - LastBlink >= 530 then
  begin
    LastBlink := Tick;
    CursorPhase := not CursorPhase;
    i := Lay.Focused;
    if (i >= 0) and (i < MAX_PANES) and (Win[i] <> nil) and
       (Win[i]^.Term <> nil) then
      Win[i]^.Term^.DrawView;
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
          Win[i]^.SetTitle(' ' + Copy(FirstWord(Panes[i].TitleCmd), 1, 24))
        else if Panes[i].TitleCwd <> '' then
          Win[i]^.SetTitle(' ' + Copy(ExtractFileName(Panes[i].TitleCwd), 1, 24));
      end;
  end;
end;

// informational menu row: always gray, never dispatchable (TV
// command sets only cover 0..255, so the item is marked directly)
function NewInfoItem(const AText, AParam: string; ANext: PMenuItem): PMenuItem;
begin
  Result := NewItem(AText, AParam, kbNoKey, cmInfoRow, hcNoContext, ANext);
  if Result <> nil then
    Result^.Disabled := True;
end;

procedure TSuperApp.InitMenuBar;
var
  R: Objects.TRect;
  MPanes, MWindows, MClasses, MProfiles, MSessMenu, MOptions, MHelp: PMenu;
  Chain: PMenuItem;
  PaneItems, WindowItems, ClassItems, ProfileItems, SessItems,
    LanguageItems: PMenuItem;
  i, Num: integer;
  TitleS: string;
  HasProfiles: boolean;
  PaletteItems: PMenuItem;
begin
  R := Default(Objects.TRect);
  GetExtent(R);
  R.B.Y := R.A.Y + 1;

  // ---- Panes: tile operations (split, focus, zoom, min, size) ----
  PaneItems := nil;
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
  for i := MAX_PANES - 1 downto 0 do
    if (Win[i] <> nil) and Win[i]^.Minimized then
    begin
      TitleS := Trim(Win[i]^.GetTitle(24));
      if TitleS = '' then
        TitleS := UiText('pane ', 'panel ') + IntToStr(i + 1);
      Chain := NewItem(Format(UiText('Restore %d %s', 'Restaurar %d %s'),
        [i + 1, Copy(TitleS, 1, 20)]), '', kbNoKey,
        cmWindowRestoreBase + i, hcNoContext, PaneItems);
      if Chain <> nil then
        PaneItems := Chain;
    end;
  PaneItems := NewItem(UiText('~R~estore all', '~R~estaurar todos'), '',
    kbNoKey, cmWindowRestoreAll, hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('Minimize ~a~ll', 'Minimizar to~d~os'), '',
    kbNoKey, cmWindowMinimizeAll, hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('~M~inimize', '~M~inimizar'), 'Alt-F9',
    kbAltF9, cmWindowMinimize, hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('Ma~x~imize/restore', 'Ma~x~imizar/restaurar'),
    'F5', kbF5, cmZoom, hcNoContext, PaneItems);
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
  // window arrangement on screen (like the classic IDE's Window menu)
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

  // ---- Classes: opens a new pane of each configured class ----
  ClassItems := nil;
  Num := 0;
  for i := 0 to Length(WClasses) - 1 do
    if WClasses[i].Enabled then
      Inc(Num);
  for i := Length(WClasses) - 1 downto 0 do
  begin
    if not WClasses[i].Enabled then
      continue;
    if Num <= 8 then
      TitleS := Format('~%d~ %s', [Num + 1, Copy(WClasses[i].Name, 1, 20)])
    else
      TitleS := '  ' + Copy(WClasses[i].Name, 1, 20);
    Dec(Num);
    Chain := NewItem(TitleS, '', kbNoKey, cmOpenClass + i, hcNoContext,
      ClassItems);
    if Chain <> nil then
      ClassItems := Chain;
  end;
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
    NewItem(UiText('~M~anage profiles...', 'Ge~s~tionar perfiles...'), '',
      kbNoKey, cmProfileManage, hcNoContext, nil)));
  HasProfiles := False;
  for i := Length(Profiles) - 1 downto 0 do
    if Profiles[i].Enabled then
    begin
      HasProfiles := True;
      Chain := NewItem(ActiveMark(ProfileMode and (i = ActiveProfile)) +
        Copy(Profiles[i].Name, 1, 24), '', kbNoKey,
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
  SessItems := NewItem(UiText('~Q~uit without saving', 'Salir si~n~ guardar'),
    'Alt-Q', kbAltQ, cmQuitNoSave, hcNoContext, SessItems);
  SessItems := NewItem(UiText('Save and e~x~it', 'Guardar y sa~l~ir'),
    'Alt-X', kbAltX, cmQuit, hcNoContext, SessItems);
  SessItems := NewLine(SessItems);
  SessItems := NewItem(UiText('Quick session ~w~izard...',
    '~A~sistente de sesion rapida...'), '', kbNoKey, cmSessionWizard,
    hcNoContext, SessItems);
  SessItems := NewItem(UiText('Sa~v~e now', '~G~uardar ahora'), 'Ctrl-S',
    kbCtrlS, cmSaveSess, hcNoContext, SessItems);
  SessItems := NewLine(SessItems);
  SessItems := NewItem(UiText('~A~ttach / manage sessions...',
    '~C~onectar / gestionar sesiones...'), PrefixKeyLabel(Cfg.PrefixKey) + ' s', kbNoKey,
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
    UiText('~C~olor (classic Turbo Pascal)',
      '~C~olor (Turbo Pascal clasico)'), '', kbNoKey,
    cmPaletteBase + apColor, hcNoContext, PaletteItems);
  MOptions := NewMenu(
    NewSubMenu(UiText('~L~anguage', '~I~dioma'), hcNoContext,
      NewMenu(LanguageItems),
    NewSubMenu(UiText('Color ~p~alette', '~P~aleta de colores'), hcNoContext,
      NewMenu(PaletteItems),
    NewLine(
    NewItem(ActiveMark(Cfg.AutoSave) +
      UiText('Auto~s~ave on exit', 'Auto~g~uardar al salir'), '', kbNoKey,
      cmToggleAutoSave, hcNoContext,
    NewItem(ActiveMark(Cfg.AutoRestore) +
      UiText('Auto~r~estore on start', 'Auto~r~estaurar al arrancar'), '',
      kbNoKey, cmToggleAutoRestore, hcNoContext,
    NewItem(ActiveMark(Cfg.DragContent) +
      UiText('Show contents while ~d~ragging',
             'Ver contenido al ~a~rrastrar'), '',
      kbNoKey, cmToggleDragContent, hcNoContext,
    NewItem(ActiveMark(Cfg.ZoomAnim) +
      UiText('Zoom ~t~ransition (F5)',
             '~T~ransicion al hacer zoom (F5)'), '',
      kbNoKey, cmToggleZoomAnim, hcNoContext, nil ))))))));

  MHelp := NewMenu(
    NewItem(UiText('~H~elp and shortcuts', '~A~yuda y atajos'), '', kbNoKey,
      cmHelp, hcNoContext,
    NewLine(
    NewItem(UiText('A~b~out...', 'A~c~erca de...'), '', kbNoKey,
      cmAbout, hcNoContext, nil))));

  MenuBar := New(PMenuBar, Init(R, NewMenu(
    NewSubMenu(UiText('~P~anes', '~P~aneles'), 0, MPanes,
    NewSubMenu(UiText('~W~indows', '~V~entanas'), 0, MWindows,
    NewSubMenu(UiText('~C~lasses', '~C~lases'), 0, MClasses,
    NewSubMenu(UiText('P~r~ofiles', 'Pe~r~files'), 0, MProfiles,
    NewSubMenu(UiText('~S~essions', '~S~esiones'), 0, MSessMenu,
    NewSubMenu(UiText('~O~ptions', '~O~pciones'), 0, MOptions,
    NewSubMenu(UiText('~H~elp', '~A~yuda'), 0, MHelp,
    nil))))))))));
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
  Items := NewStatusKey('', kbAltQ, cmQuitNoSave, Items);
  Items := NewStatusKey('', kbCtrlS, cmSaveSess, Items);
  Items := NewStatusKey('', kbCtrlF5, cmResize, Items);
  Items := NewStatusKey('', kbAltF9, cmWindowMinimize, Items);
  Items := NewStatusKey('', kbAltF4, cmClose, Items);
  Items := NewStatusKey('', kbAltF3, cmPaneClose, Items);
  Items := NewStatusKey('', kbF9, cmWindowPrev, Items);
  Items := NewStatusKey('', kbF7, cmPanePrev, Items);
  Items := NewStatusKey('', kbF3, cmSplitH, Items);
  // visible: what a novice needs most, fitting in 80 columns
  Items := NewStatusKey(UiText('~Alt-X~ Exit', '~Alt-X~ Salir'), kbAltX,
    cmQuit, Items);
  Items := NewStatusKey(UiText(
    '~' + PrefixKeyLabel(Cfg.PrefixKey) + ' d~ Detach',
    '~' + PrefixKeyLabel(Cfg.PrefixKey) + ' d~ Separar'),
    kbNoKey, cmDetach, Items);
  Items := NewStatusKey(UiText('~F5~ Zoom', '~F5~ Zoom'), kbF5,
    cmZoom, Items);
  Items := NewStatusKey(UiText('~F8~ Window', '~F8~ Ventana'), kbF8,
    cmWindowNext, Items);
  Items := NewStatusKey(UiText('~F6~ Pane', '~F6~ Panel'), kbF6,
    cmPaneNext, Items);
  Items := NewStatusKey(UiText('~F2~ Split', '~F2~ Dividir'), kbF2,
    cmSplitV, Items);
  StatusLine := New(PStatusLine, Init(R,
    NewStatusDef(0, $FFFF, Items, nil)));
end;

end.
