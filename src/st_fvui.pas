(*
  Autor: Germán Luis Aracil Boned
  Proyecto: superterm - terminal con autologin, splits y sesiones
  Unidad: st_fvui - interfaz FreeVision (estilo Turbo Pascal)
*)

unit st_fvui;

{$mode objfpc}{$H+}

interface

uses
  Objects, Drivers, Views, Menus, App, FVConsts, MsgBox,
  SysUtils, Classes, baseunix, unix, termio, Video,
  st_config, st_pty, st_screen, st_layout, st_session, st_templates,
  st_debug, st_server, st_video;

const
  // INVARIANTE de rangos de comandos: cada base dinamica (cmOpenTerm,
  // cmTemplateBase, cmSessionBase, cmWindowBase, cmWindowRestoreBase,
  // cmLanguageBase) posee un rango reservado y NINGUN case directo puede
  // caer dentro de un rango dinamico. Antes cmOpenTerm=2111 chocaba con
  // cmSessionWizard=2112 y cmDetach=2113: pulsar el 2o terminal del menu
  // lanzaba el asistente y el 3o hacia detach.
  // Rangos: 2100-2199 paneles/app · 2200-2259 plantillas · 2300-2349
  // terminales (cmOpenTerm+i) · 2400-2439 ventanas · 2500-2539 minimizados
  // · 2550-2569 sesion (detach/asistente) · 2600 ayuda · 2700 idioma.
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
  cmInfoRow    = 2199;     // filas informativas de menu, siempre deshabilitado
  cmTemplateBase = 2200;   // + indice de plantilla (0..39)
  cmOpenTerm   = 2320;     // + indice en SysTerms (0..29)
  cmSessionBase  = 2260;   // + indice de sesion de plantilla (0..39)
  cmWindowNext   = 2400;
  cmWindowPrev   = 2401;
  cmWindowBase   = 2410;   // + indice de ventana (0..15)
  cmWindowMinimize = 2500;
  cmWindowMinimizeAll = 2501;
  cmWindowRestoreAll = 2502;
  cmWindowRestoreBase = 2520;  // + indice de panel (0..15)
  cmDetach        = 2550;
  cmSessionWizard = 2560;
  cmHelp        = 2600;
  cmLanguageBase = 2700;

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
    constructor Init(var Bounds: Objects.TRect; const ATitle: string; APane: integer);
    procedure InitFrame; virtual;
    procedure ChangeBounds(var Bounds: Objects.TRect); virtual;
    procedure Zoom; virtual;
    procedure Close; virtual;
    procedure Minimize;
    procedure Restore;
    procedure SetTitle(const S: string);
  end;

  PHelpDialog = ^THelpDialog;
  THelpDialog = object(TWindow)
    constructor Init(var Bounds: Objects.TRect; const ATitle: string);
    procedure Draw; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  TSuperApp = object(TApplication)
    Cfg: TConfig;
    Lay: TLayout;
    Panes: array[0..MAX_PANES - 1] of TPty;
    Scr: array[0..MAX_PANES - 1] of TScreen;
    Win: array[0..MAX_PANES - 1] of PTermWindow;
    PaneTerm: array[0..MAX_PANES - 1] of integer;  // indice en SysTerms o -1
    SysTerms: TTerminalArray;
    Templates: TTemplateArray;
    ActiveTemplate: integer;
    ActiveSession: integer;
    ActiveWindow: integer;
    TemplateMode: boolean;
    SkipSave: boolean;
    RemoteMode: boolean;
    RemoteLost: boolean;
    DetachRequested: boolean;
    PrefixPending: boolean;
    Remote: TSessionClient;
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
    procedure DoOpenSysTerm(ASysIdx: integer);
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
    function FindSysTerm(const AName: string): integer;
    function FindTemplate(const AName: string): integer;
    function FindTemplateSession(ATemplate: integer; const AName: string): integer;
    function ActivateTemplate(ATemplate, ASession, AWindow: integer): boolean;
    procedure StopRuntime;
    procedure ReleaseRuntime;
    procedure CreateWindowForPane(i: integer; const ATitle: string);
    procedure WritePaneInput(i: integer; const S: RawByteString);
    function AttachRemoteSession: boolean;
    procedure RequestDetach;
    procedure DoSwitchTemplate(AIndex: integer);
    procedure DoSwitchSession(AIndex: integer);
    procedure DoSwitchWindow(AIndex: integer);
    procedure DoCycleWindow(ADelta: integer);
    procedure RunSessionWizard;
    procedure ShowHelp;
    procedure RebuildMenu;
    procedure RebuildStatusLine;
    procedure RememberTemplateSelection;
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

function ArgsAsShell(const Args: TStringArray): string;
var
  i: integer;
begin
  Result := '';
  for i := 0 to High(Args) do
  begin
    if i > 0 then
      Result := Result + ' ';
    Result := Result + ShellQuote(Args[i]);
  end;
end;

function CommandWithInteractiveShell(const Command, Shell: string;
  LoginShell: boolean): string;
begin
  Result := Trim(Command);
  if Result = '' then
    Exit;
  Result := Result + '; exec ' + ShellQuote(Shell);
  if LoginShell then
    Result := Result + ' -l'
  else
    Result := Result + ' -i';
end;

function WizardCommand(const AConnect, APostConnect: string): string;
begin
  Result := Trim(AConnect);
  if Trim(APostConnect) <> '' then
    // Feed the follow-up command to the connection's stdin. This works for
    // ssh -tt and keeps the command out of the remote command arguments.
    Result := 'printf ''%s\n'' ' + ShellQuote(Trim(APostConnect)) +
      ' | (' + Result + ')';
end;

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

procedure ResetVideoSurface;
begin
  if (VideoBuf <> nil) and (VideoBufSize > 0) then
    FillWord(VideoBuf^, VideoBufSize div SizeOf(Word), $0720);
  ClearScreen;
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
  // decodificar UTF-8
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
    $00AB, $00BB: Result := '"';
    $2018, $2019, $201A: Result := '''';
    $201C, $201D: Result := '"';
    $2013, $2014: Result := '-';
    $2022: Result := '*';
    $2500, $2501: Result := '-';
    $2502, $2503: Result := '|';
    $2514, $2518, $250C, $2510: Result := '+';
    $251C, $2524, $252C, $2534, $253C: Result := '+';
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
    if (AAttr and A_BOLD) <> 0 then
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
  // DECSCUSR 2/4/6 = estilo fijo (sin parpadeo); 0/1/3/5 parpadea
  ShowBlk := GetState(sfSelected) and (not Scrolled) and
    App^.Scr[PaneIdx].CursorVisible and
    (CursorPhase or (App^.Scr[PaneIdx].CursorStyle in [2, 4, 6]));
  NonBlank := 0;
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
         end
         else
           B[x] := BlankWord or word(' ');
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
         end
         else
           B[x] := BlankWord or word(' ');
       end;
    end
    else
      for x := 0 to w - 1 do
        B[x] := BlankWord or word(' ');
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
  // cursor del terminal en el panel enfocado
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
begin
  B := Default(TDrawBuffer);
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
  State := State and (not sfShadow);     // sin sombra: tiling exacto
  R.Assign(1, 1, Bounds.B.X - Bounds.A.X - 1, Bounds.B.Y - Bounds.A.Y - 1);
  Term := New(PTermView, Init(R, APane));
  Insert(Term);
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
  pw, ph: integer;
begin
  inherited ChangeBounds(Bounds);
  if Term <> nil then
  begin
    R.Assign(1, 1, Bounds.B.X - Bounds.A.X - 1, Bounds.B.Y - Bounds.A.Y - 1);
    if (R.B.X > R.A.X) and (R.B.Y > R.A.Y) then
      Term^.Locate(R);
  end;
  App := PSuperApp(Application);
  if (App <> nil) and (App^.Scr[PaneIdx] <> nil) then
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
    Minimized := True;
    Hide;
  end;
end;

procedure TTermWindow.Restore;
begin
  if Minimized then
  begin
    Minimized := False;
    Show;
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

constructor THelpDialog.Init(var Bounds: Objects.TRect; const ATitle: string);
begin
  inherited Init(Bounds, Copy(ATitle, 1, 80), wnNoNumber);
  Flags := wfClose;
  State := State and (not sfShadow);
end;

procedure THelpDialog.Draw;
const
  EnglishLines: array[0..4] of string = (
    'F2/F3 split; F6/F7 change pane; F5 maximize',
    'Alt-F3/Alt-F4 close; Alt-F9 minimize/restore',
    'Ctrl-S save; Alt-X save and exit; Alt-Q exit without saving',
    'Ctrl-B D detaches the session; use superterm --attach to return.',
    'Session > New session wizard creates 1-4 panes with commands.');
  SpanishLines: array[0..4] of string = (
    'F2/F3 divide; F6/F7 cambia de panel; F5 maximiza',
    'Alt-F3/Alt-F4 cierran; Alt-F9 minimiza/restaura',
    'Ctrl-S guarda; Alt-X guarda y sale; Alt-Q sale sin guardar',
    'Ctrl-B D separa la sesion; luego superterm --attach para volver.',
    'Sesion > Asistente crea 1-4 paneles con comandos.');
var
  B: TDrawBuffer;
  Color: byte;
  I, J, InnerWidth, ButtonX: integer;
  Line, ButtonText: string;
begin
  B := Default(TDrawBuffer);
  if Frame <> nil then
    Frame^.DrawView;
  InnerWidth := Size.X - 2;
  if InnerWidth < 1 then
    Exit;
  Color := byte(GetColor(1));
  for I := 1 to Size.Y - 2 do
  begin
    MoveChar(B, ' ', Color, InnerWidth);
    Line := '';
    if I <= Length(EnglishLines) then
      if CurrentLanguage = ulSpanish then
        Line := SpanishLines[I - 1]
      else
        Line := EnglishLines[I - 1];
    if I = Size.Y - 2 then
    begin
      if CurrentLanguage = ulSpanish then
        ButtonText := 'Aceptar'
      else
        ButtonText := 'OK';
      Line := '[' + ButtonText + ']';
      ButtonX := (InnerWidth - Length(Line)) div 2;
      if ButtonX > 0 then
        for J := 1 to ButtonX do
          B[J - 1] := (B[J - 1] and $FF00) or word(' ');
      for J := 1 to Length(Line) do
        B[ButtonX + J - 1] := (B[ButtonX + J - 1] and $FF00) or word(Line[J]);
      WriteLine(1, I, InnerWidth, 1, B);
      Continue;
    end;
    if Length(Line) > InnerWidth then
      Line := Copy(Line, 1, InnerWidth);
    for J := 1 to Length(Line) do
      B[J - 1] := (B[J - 1] and $FF00) or word(Line[J]);
    WriteLine(1, I, InnerWidth, 1, B);
  end;
end;

procedure THelpDialog.HandleEvent(var Event: TEvent);
begin
  if (Event.What = evKeyDown) and
     ((Event.KeyCode = kbEsc) or (Event.KeyCode = kbEnter) or
      (Event.KeyCode = kbCtrlF4)) then
  begin
    EndModal(cmOK);
    ClearEvent(Event);
    Exit;
  end;
  if (Event.What = evCommand) and
     ((Event.Command = cmOK) or (Event.Command = cmCancel) or
      (Event.Command = cmClose)) then
  begin
    EndModal(cmOK);
    ClearEvent(Event);
    Exit;
  end;
  inherited HandleEvent(Event);
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
begin
  InstallWideVideoOutput;
  inherited Init;
  LoadConfig(Cfg);
  CurrentLanguage := Cfg.Language;
  SetMessageBoxLanguage(CurrentLanguage = ulSpanish);
  LoadSystemTerminals(SystemConfigFile, SysTerms);
  LoadTemplates(SystemConfigFile, Templates);
  DebugLog(Format('init: sysini=%s shell=%s terms=%d templates=%d',
    [SystemConfigFile, Cfg.Shell, Length(SysTerms), Length(Templates)]));
  // inherited Init llamo a InitMenuBar con SysTerms vacio: reconstruir
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
  ActiveTemplate := -1;
  ActiveSession := -1;
  ActiveWindow := -1;
  TemplateMode := Length(Templates) > 0;
  SkipSave := False;
  RemoteMode := False;
  RemoteLost := False;
  DetachRequested := False;
  PrefixPending := False;
  Remote := nil;

  if AttachRequested and AttachRemoteSession then
    Exit;

  if TemplateMode then
  begin
    ActiveTemplate := FindTemplate(Cfg.DefaultTemplate);
    if (ActiveTemplate < 0) or (not Templates[ActiveTemplate].Enabled) then
      for i := 0 to Length(Templates) - 1 do
        if Templates[i].Enabled then
        begin
          ActiveTemplate := i;
          Break;
        end;
    if ActiveTemplate < 0 then
      TemplateMode := False
    else
    begin
      ActiveSession := FindTemplateSession(ActiveTemplate, Cfg.DefaultSession);
      if ActiveSession < 0 then
        ActiveSession := FindTemplateSession(ActiveTemplate,
          Templates[ActiveTemplate].DefaultSession);
      if ActiveSession < 0 then
        for i := 0 to Length(Templates[ActiveTemplate].Sessions) - 1 do
          if Templates[ActiveTemplate].Sessions[i].Enabled then
          begin
            ActiveSession := i;
            Break;
          end;
      ActiveWindow := -1;
      if ActiveSession >= 0 then
      begin
        for i := 0 to Length(Templates[ActiveTemplate].Sessions[ActiveSession].Windows) - 1 do
          if Templates[ActiveTemplate].Sessions[ActiveSession].Windows[i].Enabled and
             SameText(Templates[ActiveTemplate].Sessions[ActiveSession].Windows[i].Name,
               Cfg.DefaultWindow) then
          begin
            ActiveWindow := i;
            Break;
          end;
        if (ActiveWindow < 0) and
           (Templates[ActiveTemplate].Sessions[ActiveSession].FocusedWindow >= 0) and
           (Templates[ActiveTemplate].Sessions[ActiveSession].FocusedWindow <
            Length(Templates[ActiveTemplate].Sessions[ActiveSession].Windows)) and
           Templates[ActiveTemplate].Sessions[ActiveSession].Windows[
             Templates[ActiveTemplate].Sessions[ActiveSession].FocusedWindow].Enabled then
          ActiveWindow := Templates[ActiveTemplate].Sessions[ActiveSession].FocusedWindow;
        if ActiveWindow < 0 then
          for i := 0 to Length(Templates[ActiveTemplate].Sessions[ActiveSession].Windows) - 1 do
            if Templates[ActiveTemplate].Sessions[ActiveSession].Windows[i].Enabled then
            begin
              ActiveWindow := i;
              Break;
            end;
      end;
      if (ActiveSession < 0) or (ActiveWindow < 0) or
         (not ActivateTemplate(ActiveTemplate, ActiveSession, ActiveWindow)) then
        TemplateMode := False;
    end;
    if TemplateMode then
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
    // terminales definidos en /etc/superterm/superterm.ini
    n := 0;
    for i := 0 to Length(SysTerms) - 1 do
      if SysTerms[i].Enabled then
        Inc(n);
    if n > MAX_PANES then
      n := MAX_PANES;
    if n > 0 then
    begin
      k := 0;
      for i := 0 to Length(SysTerms) - 1 do
      begin
        if (not SysTerms[i].Enabled) or (k >= MAX_PANES) then
          continue;
        if k > 0 then
        begin
          if Odd(k) then Dir := sdV else Dir := sdH;
          Lay.SplitPane(Lay.PaneCount - 1, Dir);
        end;
        StartPaneEx(k, SysTerms[i].Cwd, '', i, '', '', SysTerms[i].Name,
          SysTerms[i].ScrollBack);
        Inc(k);
      end;
      Lay.Focused := 0;
      RelayoutAll;
      ResetVideoSurface;
      ReDraw;
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
      SysIdx := FindSysTerm(Pin[i].Term);
    if SysIdx >= 0 then
      StartPaneEx(i, '', '', SysIdx, '', '', SysTerms[SysIdx].Name,
        SysTerms[SysIdx].ScrollBack)
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
  if Lay.Focused >= n then
    Lay.Focused := 0;
  RelayoutAll;
  // reaplicar geometria/estado manuales de las ventanas (movidas o
  // redimensionadas con Ctrl-F5, maximizadas, minimizadas) guardados en
  // session.ini; solo si el escritorio mide lo mismo que al guardar,
  // porque los bounds son absolutos
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
    // los minimizados al final: MinimizeWindow gestiona el foco
    for i := 0 to n - 1 do
      if (i <= High(Pin)) and (i < MAX_PANES) and (Win[i] <> nil) and
         Pin[i].Minimized then
        MinimizeWindow(i);
  end;
  ResetVideoSurface;
  ReDraw;
  FocusPane(Lay.Focused);
end;

destructor TSuperApp.Done;
begin
  try
  if DetachRequested then
  begin
    // The server owns the PTYs after detach. Do not run TPty.Destroy here.
    ReleaseRuntime;
  end
  else if RemoteMode then
  begin
    if (Remote <> nil) and Remote.Connected then
      Remote.CloseSession;
    ReleaseRuntime;
  end
  else if TemplateMode then
  begin
    if not SkipSave then
    begin
      RememberTemplateSelection;
      SaveConfig(Cfg);
    end;
  end
  else if Cfg.AutoSave then
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
    CmdS := TerminalCommand(SysTerms[ASysIdx]);
    if SysTerms[ASysIdx].Kind = tkLocal then
      CwdS := SysTerms[ASysIdx].Cwd
    else
      CwdS := '';
    if ACwd <> '' then
      CwdS := ACwd;
    if SysTerms[ASysIdx].Shell <> '' then
      ShellS := SysTerms[ASysIdx].Shell
    else
      ShellS := Cfg.Shell;
    ExtraS := TerminalEnvPass(SysTerms[ASysIdx]);
    TitleS := SysTerms[ASysIdx].Name;
    if AMaxSB <= 0 then
      AMaxSB := SysTerms[ASysIdx].ScrollBack;
    if ACmd <> '' then
      CmdS := ACmd;
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
  Scr[i] := TScreen.Create(pw, ph, AMaxSB);
  Panes[i] := TPty.Create;
  ExecArgs := TStringList.Create;
  try
    ExecProgram := '';
    ExecSecret := '';
    if (ASysIdx >= 0) and (SysTerms[ASysIdx].Kind = tkSSH) then
    begin
      BuildTerminalExec(SysTerms[ASysIdx], ExecProgram, ExecArgs, ExecSecret,
        ACommandOverride);
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
  TitleS := SysTerms[PaneTerm[i]].Name;
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
  i: integer;
  R: Objects.TRect;
begin
  R := Default(Objects.TRect);
  Desktop^.GetExtent(R);
  Lay.ComputeRects(R.B.X - R.A.X, R.B.Y - R.A.Y, Rects);
  for i := 0 to MAX_PANES - 1 do
    if Win[i] <> nil then
    begin
      Rects[i].W := Rects[i].W - 2;  // hueco entre marcos
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
  Lay.Focused := i;
  FocusPane(i);
  RelayoutAll;
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
  RebuildMenu;
end;

procedure TSuperApp.RestoreAllWindows;
var
  i: integer;
begin
  for i := 0 to MAX_PANES - 1 do
    if Win[i] <> nil then
      Win[i]^.Restore;
  if (Lay.Focused < 0) or (Lay.Focused >= MAX_PANES) or
     (Win[Lay.Focused] = nil) or Win[Lay.Focused]^.Minimized then
    Lay.Focused := FirstVisiblePane;
  RelayoutAll;
  FocusPane(Lay.Focused);
  RebuildMenu;
end;

procedure TSuperApp.DoSplit(ADir: TSplitDir; ASysIdx: integer);
var
  OldCount, NewIdx, j: integer;
begin
  if Lay.Focused < 0 then
    Lay.Focused := FirstVisiblePane;
  if Lay.Focused < 0 then
    Exit;
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

procedure TSuperApp.DoOpenSysTerm(ASysIdx: integer);
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

function TSuperApp.FindSysTerm(const AName: string): integer;
var
  i: integer;
begin
  Result := -1;
  if AName = '' then
    Exit;
  for i := 0 to Length(SysTerms) - 1 do
    if SameText(SysTerms[i].Name, AName) then
      Exit(i);
end;

function TSuperApp.FindTemplate(const AName: string): integer;
var
  i: integer;
begin
  Result := -1;
  if AName = '' then
    Exit;
  for i := 0 to Length(Templates) - 1 do
    if Templates[i].Enabled and SameText(Templates[i].Name, AName) then
      Exit(i);
end;

function TSuperApp.FindTemplateSession(ATemplate: integer;
  const AName: string): integer;
var
  i: integer;
begin
  Result := -1;
  if (ATemplate < 0) or (ATemplate >= Length(Templates)) or
     (AName = '') then
    Exit;
  for i := 0 to Length(Templates[ATemplate].Sessions) - 1 do
    if Templates[ATemplate].Sessions[i].Enabled and
       SameText(Templates[ATemplate].Sessions[i].Name, AName) then
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

function TSuperApp.AttachRemoteSession: boolean;
var
  Snapshot: TSessionSnapshot;
  NewLay: TLayout;
  Stream: TMemoryStream;
  I, N, SysIdx: integer;
  TitleS: string;
  Loaded: boolean;
begin
  Result := False;
  Remote := TSessionClient.Create;
  if not Remote.Connect(Snapshot) then
  begin
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
  if Lay <> nil then
    Lay.Free;
  Lay := NewLay;
  Lay.Focused := Snapshot.Focused;
  if (Lay.Focused < 0) or (Lay.Focused >= N) then
    Lay.Focused := 0;
  TemplateMode := False;
  ActiveTemplate := -1;
  ActiveSession := -1;
  ActiveWindow := -1;
  RemoteMode := True;
  Loaded := True;
  for I := 0 to N - 1 do
  begin
    PaneTerm[I] := -1;
    SysIdx := FindSysTerm(Snapshot.Panes[I].Term);
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
    RemoteMode := False;
    ReleaseRuntime;
    Remote.Free;
    Remote := nil;
    Exit;
  end;
  RelayoutAll;
  ResetVideoSurface;
  ReDraw;
  FocusPane(Lay.Focused);
  RebuildMenu;
  Result := True;
end;

procedure TSuperApp.RequestDetach;
var
  N, I: integer;
  PtyRefs: TPtyArray;
  ScreenRefs: TScreenArray;
  Titles, Terms: TStrArray;
begin
  if DetachRequested then
    Exit;
  if RemoteMode then
  begin
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
  PtyRefs := nil;
  ScreenRefs := nil;
  Titles := nil;
  Terms := nil;
  SetLength(PtyRefs, N);
  SetLength(ScreenRefs, N);
  SetLength(Titles, N);
  SetLength(Terms, N);
  for I := 0 to N - 1 do
  begin
    PtyRefs[I] := Panes[I];
    ScreenRefs[I] := Scr[I];
    if Win[I] <> nil then
      Titles[I] := Trim(Win[I]^.GetTitle(80));
    if PaneTerm[I] >= 0 then
      if PaneTerm[I] < Length(SysTerms) then
        Terms[I] := SysTerms[PaneTerm[I]].Name;
    if (PtyRefs[I] = nil) or (ScreenRefs[I] = nil) then
      Exit;
  end;
  if not StartDetachedServer(Lay, PtyRefs, ScreenRefs, Titles, Terms,
    Lay.Focused) then
  begin
    MessageBox(UiText('Could not create the detached session server.',
      'No se pudo crear el servidor de la sesion separada.'), nil,
      mfError or mfOKButton);
    Exit;
  end;
  DetachRequested := True;
  Message(@Self, evCommand, cmQuit, nil);
end;

function TSuperApp.ActivateTemplate(ATemplate, ASession,
  AWindow: integer): boolean;
var
  NewLay: TLayout;
  WS: TTemplateWindowSpec;
  PS: TTemplatePaneSpec;
  i, n, SysIdx: integer;
  Started: boolean;
  CommandOverride, LocalCmd: string;
begin
  Result := False;
  if (ATemplate < 0) or (ATemplate >= Length(Templates)) or
     (not Templates[ATemplate].Enabled) then
    Exit;
  if (ASession < 0) or
     (ASession >= Length(Templates[ATemplate].Sessions)) or
     (not Templates[ATemplate].Sessions[ASession].Enabled) then
    Exit;
  if (AWindow < 0) or
     (AWindow >= Length(Templates[ATemplate].Sessions[ASession].Windows)) or
     (not Templates[ATemplate].Sessions[ASession].Windows[AWindow].Enabled) then
    Exit;

  WS := Templates[ATemplate].Sessions[ASession].Windows[AWindow];
  if not LoadLayoutString(WS.Layout, NewLay) then
    NewLay := TLayout.Create;
  n := NewLay.PaneCount;
  DebugLog(Format('template activate t=%d s=%d w=%d layout=%s leaves=%d specs=%d',
    [ATemplate, ASession, AWindow, WS.Layout, n, Length(WS.Panes)]));
  if Length(WS.Panes) > n then
  begin
    NewLay.Free;
    Exit;
  end;
  if (n < 1) or (n > MAX_PANES) then
  begin
    NewLay.Free;
    Exit;
  end;

  StopRuntime;
  if Lay <> nil then
    Lay.Free;
  Lay := NewLay;
  ActiveTemplate := ATemplate;
  ActiveSession := ASession;
  ActiveWindow := AWindow;

  Started := True;
  for i := 0 to n - 1 do
  begin
    PS.Name := 'pane' + IntToStr(i);
    PS.Enabled := True;
    PS.Terminal := '';
    PS.Cmd := '';
    PS.Cwd := '';
    PS.PostConnect := '';
    PS.ScrollBack := 0;
    if i <= High(WS.Panes) then
      PS := WS.Panes[i];
    CommandOverride := PS.Cmd;
    if PS.PostConnect <> '' then
      CommandOverride := PS.PostConnect;
    SysIdx := FindSysTerm(PS.Terminal);
    DebugLog(Format('template pane=%d enabled=%d terminal=%s cmd=%s post=%s sysidx=%d',
      [i, Ord(PS.Enabled), PS.Terminal, PS.Cmd, PS.PostConnect, SysIdx]));
    if (SysIdx >= 0) and PS.Enabled then
      StartPaneEx(i, PS.Cwd, PS.Cmd, SysIdx, '', '',
        Templates[ATemplate].Name + '/' +
        Templates[ATemplate].Sessions[ASession].Name + '/' + WS.Name,
        PS.ScrollBack, CommandOverride)
    else if PS.Enabled then
    begin
      LocalCmd := PS.Cmd;
      if LocalCmd = '' then
        LocalCmd := PS.PostConnect;
      StartPane(i, PS.Cwd, LocalCmd);
    end
    else
      StartPane(i, '', '');
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
  FocusPane(Lay.Focused);
  RebuildMenu;
  Result := True;
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
      UiText('Number of windows (1-4):', 'Numero de ventanas (1-4):'),
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
      Format(UiText('Wizard: window %d/%d', 'Asistente: ventana %d/%d'),
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
      Format(UiText('Wizard: window %d/%d', 'Asistente: ventana %d/%d'),
        [I + 1, WindowCount]),
      UiText('After connecting (optional):',
        'Despues de conectar (opcional):'), PostConnectCmd[I], 240);
    if Choice = cmCancel then
      Exit;
  end;

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
  ActiveTemplate := -1;
  ActiveSession := -1;
  ActiveWindow := -1;
  TemplateMode := False;
  Started := True;
  for I := 0 to WindowCount - 1 do
  begin
    StartPaneEx(I, GetEnvironmentVariable('HOME'),
      WizardCommand(ConnectCmd[I], PostConnectCmd[I]), -1, '', '',
      UiText('wizard ', 'asistente ') + IntToStr(I + 1), DEFAULT_SCROLLBACK);
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
    MessageBox(UiText('The wizard could not start a window.',
      'No se pudo iniciar una ventana del asistente.'), nil,
      mfError or mfOKButton);
  end
  else
  begin
    Lay.Focused := 0;
    RelayoutAll;
    ResetVideoSurface;
    ReDraw;
    FocusPane(Lay.Focused);
  end;
  RebuildMenu;
end;

procedure TSuperApp.ShowHelp;
var
  R, DesktopRect: Objects.TRect;
  Dialog: PHelpDialog;
begin
  DesktopRect := Default(Objects.TRect);
  Desktop^.GetExtent(DesktopRect);
  R.Assign(0, 0, 84, 9);
  if R.B.X > DesktopRect.B.X then
    R.B.X := DesktopRect.B.X;
  if R.B.Y > DesktopRect.B.Y then
    R.B.Y := DesktopRect.B.Y;
  R.Move((DesktopRect.B.X - R.B.X) div 2,
    (DesktopRect.B.Y - R.B.Y) div 2);
  Dialog := New(PHelpDialog, Init(R, UiText('Help', 'Ayuda')));
  Desktop^.ExecView(Dialog);
  Dispose(Dialog, Done);
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

procedure TSuperApp.RememberTemplateSelection;
begin
  if (ActiveTemplate >= 0) and (ActiveTemplate < Length(Templates)) then
    Cfg.DefaultTemplate := Templates[ActiveTemplate].Name;
  if (ActiveTemplate >= 0) and (ActiveTemplate < Length(Templates)) and
     (ActiveSession >= 0) and
     (ActiveSession < Length(Templates[ActiveTemplate].Sessions)) then
    Cfg.DefaultSession := Templates[ActiveTemplate].Sessions[ActiveSession].Name;
  if (ActiveTemplate >= 0) and (ActiveTemplate < Length(Templates)) and
     (ActiveSession >= 0) and
     (ActiveSession < Length(Templates[ActiveTemplate].Sessions)) and
     (ActiveWindow >= 0) and
     (ActiveWindow < Length(Templates[ActiveTemplate].Sessions[ActiveSession].Windows)) then
    Cfg.DefaultWindow := Templates[ActiveTemplate].Sessions[ActiveSession].Windows[ActiveWindow].Name;
end;

procedure TSuperApp.DoSwitchTemplate(AIndex: integer);
var
  S, W, I, OldT, OldS, OldW: integer;
begin
  if (AIndex < 0) or (AIndex >= Length(Templates)) or
     (not Templates[AIndex].Enabled) then
    Exit;
  OldT := ActiveTemplate;
  OldS := ActiveSession;
  OldW := ActiveWindow;
  S := FindTemplateSession(AIndex, Templates[AIndex].DefaultSession);
  if S < 0 then
    for I := 0 to Length(Templates[AIndex].Sessions) - 1 do
      if Templates[AIndex].Sessions[I].Enabled then
      begin
        S := I;
        Break;
      end;
  W := -1;
  if (S >= 0) and (S < Length(Templates[AIndex].Sessions)) then
    for I := 0 to Length(Templates[AIndex].Sessions[S].Windows) - 1 do
      if Templates[AIndex].Sessions[S].Windows[I].Enabled then
      begin
        W := I;
        Break;
      end;
  if (S < 0) or (W < 0) or not ActivateTemplate(AIndex, S, W) then
  begin
    if (OldT >= 0) and (OldS >= 0) and (OldW >= 0) then
      ActivateTemplate(OldT, OldS, OldW);
    MessageBox(UiText('The template could not be started.',
      'No se pudo iniciar el template'), nil,
      mfError or mfOKButton);
  end;
end;

procedure TSuperApp.DoSwitchSession(AIndex: integer);
var
  W, I, OldS, OldW: integer;
begin
  if (ActiveTemplate < 0) or (ActiveTemplate >= Length(Templates)) then
    Exit;
  OldS := ActiveSession;
  OldW := ActiveWindow;
  W := -1;
  if (AIndex >= 0) and (AIndex < Length(Templates[ActiveTemplate].Sessions)) and
     Templates[ActiveTemplate].Sessions[AIndex].Enabled then
    for I := 0 to Length(Templates[ActiveTemplate].Sessions[AIndex].Windows) - 1 do
      if Templates[ActiveTemplate].Sessions[AIndex].Windows[I].Enabled then
      begin
        W := I;
        Break;
      end;
  if (W < 0) or not ActivateTemplate(ActiveTemplate, AIndex, W) then
  begin
    if (OldS >= 0) and (OldW >= 0) then
      ActivateTemplate(ActiveTemplate, OldS, OldW);
    MessageBox(UiText('The session could not be started.',
      'No se pudo iniciar la sesion'), nil,
      mfError or mfOKButton);
  end;
end;

procedure TSuperApp.DoSwitchWindow(AIndex: integer);
var
  OldWindow: integer;
begin
  if (ActiveTemplate < 0) or (ActiveTemplate >= Length(Templates)) or
     (ActiveSession < 0) or
     (ActiveSession >= Length(Templates[ActiveTemplate].Sessions)) then
    Exit;
  if (AIndex < 0) or
     (AIndex >= Length(Templates[ActiveTemplate].Sessions[ActiveSession].Windows)) or
     (not Templates[ActiveTemplate].Sessions[ActiveSession].Windows[AIndex].Enabled) then
    Exit;
  OldWindow := ActiveWindow;
  if not ActivateTemplate(ActiveTemplate, ActiveSession, AIndex) then
  begin
    if OldWindow >= 0 then
      ActivateTemplate(ActiveTemplate, ActiveSession, OldWindow);
    MessageBox(UiText('The window could not be started.',
      'No se pudo iniciar la ventana'), nil,
      mfError or mfOKButton);
  end;
end;

procedure TSuperApp.DoCycleWindow(ADelta: integer);
var
  N, Step, Candidate: integer;
begin
  if (ActiveTemplate < 0) or (ActiveTemplate >= Length(Templates)) or
     (ActiveSession < 0) or
     (ActiveSession >= Length(Templates[ActiveTemplate].Sessions)) then
    Exit;
  N := Length(Templates[ActiveTemplate].Sessions[ActiveSession].Windows);
  if N = 0 then
    Exit;
  Candidate := ActiveWindow;
  for Step := 1 to N do
  begin
    Candidate := (Candidate + ADelta) mod N;
    if Candidate < 0 then
      Inc(Candidate, N);
    if Templates[ActiveTemplate].Sessions[ActiveSession].Windows[Candidate].Enabled then
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
  RelayoutAll;
  FocusPane(Lay.Focused);
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
    if Panes[i] <> nil then
    begin
      if PaneTerm[i] >= 0 then
        Pin[i].Term := SysTerms[PaneTerm[i]].Name
      else
      begin
        Panes[i].QueryState;
        Pin[i].Cmd := Panes[i].TitleCmd;
        Pin[i].Cwd := Panes[i].TitleCwd;
        Pin[i].Args := Panes[i].TitleArgs;
      end;
    end;
    // geometria y estado de la ventana: para una maximizada el rect real
    // es ZoomRect (el de restauracion); Minimize solo oculta, conserva bounds
    if (i < MAX_PANES) and (Win[i] <> nil) then
    begin
      if Win[i]^.Zoomed then
        WR := Win[i]^.ZoomRect
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
  i: integer;
  ResizeEvent: boolean;
  ResizeWidth, ResizeHeight: integer;
  PrefixByte: byte;
  PrefixSeq: RawByteString;
begin
  ResizeEvent := (Event.What = evCommand) and (Event.Command = cmResizeApp);
  ResizeWidth := Event.Id;
  ResizeHeight := Event.InfoWord;
  if Event.What = evKeyDown then
  begin
    PrefixByte := Event.KeyCode and $00FF;
    if PrefixPending then
    begin
      PrefixPending := False;
      // chords del prefijo (estilo tmux): d=detach, n/p=ventana +-,
      // 1..9=ventana N, flechas=tamano del panel, prefijo doble=literal
      if (PrefixByte = Ord('d')) or (PrefixByte = Ord('D')) then
      begin
        RequestDetach;
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
        // prefijo doble: enviar UN prefijo literal al panel (como tmux)
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
  end;
  // Alt-1..9 ya NO se intercepta: cae al TProgram nativo, que selecciona
  // el panel N (cmSelectWindowNum); abrir clases vive en el menu Clases
  // sincronizar foco del layout con la ventana seleccionada
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
      cmWindowMinimizeAll: MinimizeAllWindows;
      cmWindowRestoreAll: RestoreAllWindows;
      cmSaveSess:
        begin
          if TemplateMode then
          begin
            RememberTemplateSelection;
            SaveConfig(Cfg);
          end
          else
            SaveSessionNow;
          MessageBox(UiText('Session saved.', 'Sesion guardada.'), nil,
            mfInformation or mfOKButton);
        end;
      cmSessionWizard: RunSessionWizard;
      cmDetach: RequestDetach;
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
      else if (Event.Command >= cmTemplateBase) and
         (Event.Command < cmTemplateBase + Length(Templates)) then
        DoSwitchTemplate(Event.Command - cmTemplateBase)
      else if TemplateMode and (ActiveTemplate >= 0) and
         (ActiveTemplate < Length(Templates)) and
         (Event.Command >= cmSessionBase) and
         (Event.Command < cmSessionBase + Length(Templates[ActiveTemplate].Sessions)) then
        DoSwitchSession(Event.Command - cmSessionBase)
      else if TemplateMode and (ActiveTemplate >= 0) and
         (ActiveTemplate < Length(Templates)) and (ActiveSession >= 0) and
         (ActiveSession < Length(Templates[ActiveTemplate].Sessions)) and
         (Length(Templates[ActiveTemplate].Sessions[ActiveSession].Windows) > 0) and
         (Event.Command = cmWindowNext) then
        DoCycleWindow(+1)
      else if TemplateMode and (ActiveTemplate >= 0) and
         (ActiveTemplate < Length(Templates)) and (ActiveSession >= 0) and
         (ActiveSession < Length(Templates[ActiveTemplate].Sessions)) and
         (Length(Templates[ActiveTemplate].Sessions[ActiveSession].Windows) > 0) and
         (Event.Command = cmWindowPrev) then
        DoCycleWindow(-1)
       else if TemplateMode and (ActiveTemplate >= 0) and
          (ActiveTemplate < Length(Templates)) and (ActiveSession >= 0) and
          (ActiveSession < Length(Templates[ActiveTemplate].Sessions)) and
          (Event.Command >= cmWindowBase) and
          (Event.Command < cmWindowBase +
           Length(Templates[ActiveTemplate].Sessions[ActiveSession].Windows)) then
         DoSwitchWindow(Event.Command - cmWindowBase)
       else if (Event.Command >= cmWindowRestoreBase) and
          (Event.Command < cmWindowRestoreBase + MAX_PANES) then
         RestoreWindow(Event.Command - cmWindowRestoreBase)
       else if (Event.Command >= cmOpenTerm) and
         (Event.Command < cmOpenTerm + Length(SysTerms)) then
        DoOpenSysTerm(Event.Command - cmOpenTerm)
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
  if RemoteMode then
  begin
    while (Remote <> nil) and Remote.Poll(RemoteEvent) do
    begin
      case RemoteEvent.Kind of
        sekOutput:
          if (RemoteEvent.Pane >= 0) and (RemoteEvent.Pane < MAX_PANES) and
             (Scr[RemoteEvent.Pane] <> nil) and
             (Length(RemoteEvent.Data) > 0) then
          begin
            Scr[RemoteEvent.Pane].WriteBytes(RemoteEvent.Data[0],
              Length(RemoteEvent.Data));
            if Win[RemoteEvent.Pane] <> nil then
              Win[RemoteEvent.Pane]^.Term^.DrawView;
          end;
        sekExit:
          if (RemoteEvent.Pane >= 0) and (RemoteEvent.Pane < MAX_PANES) and
             (Win[RemoteEvent.Pane] <> nil) then
            Win[RemoteEvent.Pane]^.SetTitle(UiText(' EXITED', ' TERMINO'));
        sekError:
          DebugLog('remote session error: ' + RemoteEvent.Text);
        sekLost:
          begin
            RemoteLost := True;
            RemoteMode := False;
          end;
      end;
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
  // poll de ptys
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
            Scr[i].WriteBytes(Buf, n);
            if Win[i] <> nil then
              Win[i]^.Term^.DrawView;
          end
          else if (n = 0) or (fpgeterrno <> ESysEAGAIN) then
            Panes[i].MarkDead;
        end;
  end
  else
    Sleep(8);
  // hijos muertos
  st2 := Default(cint);
  repeat
    p := fpWaitPid(-1, st2, WNOHANG);
    if p > 0 then
      for i := 0 to MAX_PANES - 1 do
        if (Panes[i] <> nil) and (Panes[i].Pid = p) then
        begin
          Panes[i].MarkExited;
          if (PaneTerm[i] >= 0) and
             (PaneTerm[i] < Length(SysTerms)) and
             (SysTerms[PaneTerm[i]].Kind = tkSSH) then
            FallbackPane(i)
          else if Win[i] <> nil then
            Win[i]^.SetTitle(UiText(' EXITED', ' TERMINO'));
        end;
  until p <= 0;
  // cursor parpadeante del panel enfocado
  if Tick - LastBlink >= 530 then
  begin
    LastBlink := Tick;
    CursorPhase := not CursorPhase;
    i := Lay.Focused;
    if (i >= 0) and (i < MAX_PANES) and (Win[i] <> nil) and
       (Win[i]^.Term <> nil) then
      Win[i]^.Term^.DrawView;
  end;
  // titulos periodicos
  if Tick - LastTitle > 1500 then
  begin
    LastTitle := Tick;
    for i := 0 to MAX_PANES - 1 do
      if (Panes[i] <> nil) and Panes[i].Alive and (Win[i] <> nil) and
          (PaneTerm[i] = -1) then
      begin
        Panes[i].QueryState;
        if Panes[i].TitleCmd <> '' then
          Win[i]^.SetTitle(' ' + Copy(FirstWord(Panes[i].TitleCmd), 1, 24))
        else if Panes[i].TitleCwd <> '' then
          Win[i]^.SetTitle(' ' + Copy(ExtractFileName(Panes[i].TitleCwd), 1, 24));
      end;
  end;
end;

// fila informativa de menu: siempre en gris, nunca despachable (los sets
// de comandos de TV solo cubren 0..255, asi que se marca el item directo)
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
  HasProfiles, HasWindows: boolean;
begin
  R := Default(Objects.TRect);
  GetExtent(R);
  R.B.Y := R.A.Y + 1;

  // ---- Paneles: operaciones de tile (split, foco, zoom, min, tamano) ----
  PaneItems := nil;
  PaneItems := NewItem(UiText('~S~horter', 'Meno~s~ alto'), 'Ctrl-B ' + #24,
    kbNoKey, cmShrinkH, hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('~T~aller', 'Mas a~l~to'), 'Ctrl-B ' + #25,
    kbNoKey, cmGrowH, hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('Narrow~e~r', 'M~e~nos ancho'), 'Ctrl-B ' + #27,
    kbNoKey, cmShrinkV, hcNoContext, PaneItems);
  PaneItems := NewItem(UiText('~W~ider', 'Mas ~a~ncho'), 'Ctrl-B ' + #26,
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

  // ---- Ventanas: solo navegacion de workspaces del perfil activo ----
  WindowItems := nil;
  if TemplateMode and (ActiveTemplate >= 0) and
     (ActiveTemplate < Length(Templates)) and (ActiveSession >= 0) and
     (ActiveSession < Length(Templates[ActiveTemplate].Sessions)) then
  begin
    for i := Length(Templates[ActiveTemplate].Sessions[ActiveSession].Windows) - 1
      downto 0 do
      if Templates[ActiveTemplate].Sessions[ActiveSession].Windows[i].Enabled then
      begin
        Chain := NewItem(ActiveMark(i = ActiveWindow) +
          Copy(Templates[ActiveTemplate].Sessions[ActiveSession].Windows[i].Name,
          1, 22), 'Ctrl-B ' + IntToStr(i + 1), kbNoKey,
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
  MWindows := NewMenu(WindowItems);

  // ---- Clases: abre un panel nuevo de cada clase configurada ----
  ClassItems := nil;
  Num := 0;
  for i := 0 to Length(SysTerms) - 1 do
    if SysTerms[i].Enabled then
      Inc(Num);
  for i := Length(SysTerms) - 1 downto 0 do
  begin
    if not SysTerms[i].Enabled then
      continue;
    if Num <= 8 then
      TitleS := Format('~%d~ %s', [Num + 1, Copy(SysTerms[i].Name, 1, 20)])
    else
      TitleS := '  ' + Copy(SysTerms[i].Name, 1, 20);
    Dec(Num);
    Chain := NewItem(TitleS, '', kbNoKey, cmOpenTerm + i, hcNoContext,
      ClassItems);
    if Chain <> nil then
      ClassItems := Chain;
  end;
  ClassItems := NewItem(UiText('~1~ Local shell', '~1~ Shell local'), '',
    kbNoKey, cmSplitV, hcNoContext, ClassItems);
  MClasses := NewMenu(ClassItems);

  // ---- Perfiles: activar uno (gestion llega en fases posteriores) ----
  ProfileItems := nil;
  HasProfiles := False;
  for i := Length(Templates) - 1 downto 0 do
    if Templates[i].Enabled then
    begin
      HasProfiles := True;
      Chain := NewItem(ActiveMark(TemplateMode and (i = ActiveTemplate)) +
        Copy(Templates[i].Name, 1, 24), '', kbNoKey,
        cmTemplateBase + i, hcNoContext, ProfileItems);
      if Chain <> nil then
        ProfileItems := Chain;
    end;
  if not HasProfiles then
    ProfileItems := NewInfoItem(UiText('(no profiles yet)',
      '(aun no hay perfiles)'), '', nil);
  // sesiones del perfil activo (plantillas multi-sesion legadas)
  if TemplateMode and (ActiveTemplate >= 0) and
     (ActiveTemplate < Length(Templates)) and
     (Length(Templates[ActiveTemplate].Sessions) > 1) then
  begin
    ProfileItems := NewLine(ProfileItems);
    HasWindows := False;
    for i := Length(Templates[ActiveTemplate].Sessions) - 1 downto 0 do
      if Templates[ActiveTemplate].Sessions[i].Enabled then
      begin
        HasWindows := True;
        Chain := NewItem('  ' + ActiveMark(i = ActiveSession) +
          Copy(Templates[ActiveTemplate].Sessions[i].Name, 1, 22), '',
          kbNoKey, cmSessionBase + i, hcNoContext, ProfileItems);
        if Chain <> nil then
          ProfileItems := Chain;
      end;
    if HasWindows then
      ProfileItems := NewInfoItem(UiText('Variants:', 'Variantes:'), '',
        ProfileItems);
  end;
  MProfiles := NewMenu(ProfileItems);

  // ---- Sesiones: detach y ciclo de vida de la aplicacion ----
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
  SessItems := NewItem(UiText('~D~etach...', '~S~eparar...'), 'Ctrl-B d',
    kbNoKey, cmDetach, hcNoContext, SessItems);
  MSessMenu := NewMenu(SessItems);

  // ---- Opciones: idioma en orden fijo, nombres sin traducir ----
  LanguageItems := nil;
  LanguageItems := NewItem(ActiveMark(CurrentLanguage = ulSpanish) +
    'E~s~panol', '', kbNoKey, cmLanguageBase + Ord(ulSpanish), hcNoContext,
    LanguageItems);
  LanguageItems := NewItem(ActiveMark(CurrentLanguage = ulEnglish) +
    '~E~nglish', '', kbNoKey, cmLanguageBase + Ord(ulEnglish), hcNoContext,
    LanguageItems);
  MOptions := NewMenu(
    NewSubMenu(UiText('~L~anguage', '~I~dioma'), hcNoContext,
      NewMenu(LanguageItems), nil));

  MHelp := NewMenu(
    NewItem(UiText('~H~elp and shortcuts', '~A~yuda y atajos'), '', kbNoKey,
      cmHelp, hcNoContext, nil));

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
  // teclas invisibles: despachan sin ocupar sitio en la linea de estado
  Items := NewStatusKey('', kbAltQ, cmQuitNoSave, Items);
  Items := NewStatusKey('', kbCtrlS, cmSaveSess, Items);
  Items := NewStatusKey('', kbCtrlF5, cmResize, Items);
  Items := NewStatusKey('', kbAltF9, cmWindowMinimize, Items);
  Items := NewStatusKey('', kbAltF4, cmClose, Items);
  Items := NewStatusKey('', kbAltF3, cmPaneClose, Items);
  Items := NewStatusKey('', kbF9, cmWindowPrev, Items);
  Items := NewStatusKey('', kbF7, cmPanePrev, Items);
  Items := NewStatusKey('', kbF3, cmSplitH, Items);
  // visibles: lo critico para un novato, cabiendo en 80 columnas
  Items := NewStatusKey(UiText('~Alt-X~ Exit', '~Alt-X~ Salir'), kbAltX,
    cmQuit, Items);
  Items := NewStatusKey(UiText('~Ctrl-B d~ Detach', '~Ctrl-B d~ Separar'),
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
