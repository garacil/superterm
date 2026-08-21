(*
  Autor: Germán Luis Aracil Boned
  Proyecto: superterm - terminal con autologin, splits y sesiones
  Unidad: st_fvui - interfaz FreeVision (estilo Turbo Pascal)
*)

unit st_fvui;

{$mode objfpc}{$H+}

interface

uses
  Objects, Drivers, Views, Menus, Dialogs, App, FVConsts, MsgBox,
  SysUtils, Classes, baseunix, unix, termio, Video,
  st_config, st_wclass, st_profiles, st_dialogs, st_pty, st_screen,
  st_layout, st_session, st_debug, st_server, st_video;

const
  // INVARIANTE de rangos de comandos: cada base dinamica (cmOpenClass,
  // cmProfileBase, cmSessionBase, cmWindowBase, cmWindowRestoreBase,
  // cmLanguageBase) posee un rango reservado y NINGUN case directo puede
  // caer dentro de un rango dinamico. Antes cmOpenClass=2111 chocaba con
  // cmSessionWizard=2112 y cmDetach=2113: pulsar el 2o terminal del menu
  // lanzaba el asistente y el 3o hacia detach.
  // Rangos: 2100-2199 paneles/app · 2200-2259 plantillas · 2300-2349
  // terminales (cmOpenClass+i) · 2400-2439 ventanas · 2500-2539 minimizados
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
  cmPaneTile    = 2111;    // recolocar en mosaico (Window|Tile clasico)
  cmPaneCascade = 2112;
  cmPaneList    = 2113;    // lista de paneles (Alt+0)
  cmRedrawAll   = 2114;    // refrescar pantalla
  cmPaneOrganize = 2115;   // rejilla NxM del vendor (TDeskTop.Tile)
  cmRenameWindow = 2116;   // titulo propio de la ventana enfocada
  cmInfoRow    = 2199;     // filas informativas de menu, siempre deshabilitado
  cmProfileBase = 2200;   // + indice de perfil (0..39)
  cmProfileSaveAs = 2250;  // guardar el area de trabajo como perfil
  cmProfileManage = 2251;  // gestor de perfiles
  cmOpenClass   = 2320;     // + indice en WClasses (0..29)
  cmWindowNext   = 2400;
  cmWindowPrev   = 2401;
  cmWindowBase   = 2410;   // + indice de ventana (0..15)
  cmClassPick    = 2340;   // selector de clase para panel nuevo
  cmClassManage  = 2341;   // gestor de clases
  cmWindowMinimize = 2500;
  cmWindowMinimizeAll = 2501;
  cmWindowRestoreAll = 2502;
  cmWindowRestoreBase = 2520;  // + indice de panel (0..15)
  cmDetach        = 2550;
  cmSessionPick   = 2551;   // selector/gestor de sesiones separadas
  cmSessionWizard = 2560;
  cmHelp        = 2600;
  cmAbout       = 2601;
  cmLanguageBase = 2700;
  cmPaletteBase  = 2750;   // +apColor/apBlackWhite/apMonochrome
  cmToggleAutoSave    = 2760;
  cmToggleAutoRestore = 2761;

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
    TitleFixed: boolean;       // titulo propio: no lo pisa el refresco por cwd
    SavedRect: Objects.TRect;  // bounds previos al icono de minimizado
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
    PaneTerm: array[0..MAX_PANES - 1] of integer;  // indice en WClasses o -1
    PaneConnect: array[0..MAX_PANES - 1] of string; // conexion libre ad-hoc
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
    RemoteLayoutHash: string;   // ultima geometria empujada/aplicada
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

// cita solo cuando hace falta: los valores INI que empiezan por comilla
// pierden las comillas exteriores al releerse (TIniFile las recorta)
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

// True si el proceso observado es simplemente una shell interactiva/login:
// capturarlo como comando seria redundante (y fragil); mejor cmd vacio
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
  // '-bash' (shell de login) y variantes
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

// CommandWithInteractiveShell y WizardCommand viven ahora en st_wclass,
// compartidos con la composicion de comandos de las clases de ventana.

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
    $00A0: Result := ' ';
    $00AB, $00BB: Result := '"';
    $00D7: Result := 'x';
    $00F7: Result := '/';
    $2018, $2019, $201A: Result := '''';
    $201C, $201D: Result := '"';
    $2010, $2011, $2012, $2013, $2014, $2212: Result := '-';
    $2026: Result := '.';
    // caja y bloques: bytes CP437, el driver los pinta como glifos reales
    $2022: Result := #7;                       // punto gordo
    $2800..$28FF: Result := #250;              // braille (spinners CLI)
    $2500, $2501: Result := #196;              // linea horizontal
    $2502, $2503: Result := #179;              // linea vertical
    $250C, $250F, $256D: Result := #218;       // esquinas
    $2510, $2513, $256E: Result := #191;
    $2514, $2517, $2570: Result := #192;
    $2518, $251B, $256F: Result := #217;
    $251C, $2523: Result := #195;              // cruces en T
    $2524, $252B: Result := #180;
    $252C, $2533: Result := #194;
    $2534, $253B: Result := #193;
    $253C, $254B: Result := #197;              // cruz completa
    $2550: Result := #205;                     // dobles
    $2551: Result := #186;
    $2554: Result := #201;
    $2557: Result := #187;
    $255A: Result := #200;
    $255D: Result := #188;
    $2560: Result := #204;                     // uniones dobles
    $2563: Result := #185;
    $2566: Result := #203;
    $2569: Result := #202;
    $256C, $256A, $256B: Result := #206;
    $2564: Result := #209;
    $2567: Result := #207;
    $2580: Result := #223;                     // medios bloques y sombras
    $2584: Result := #220;
    $2588: Result := #219;
    $2591: Result := #176;
    $2592: Result := #177;
    $2593: Result := #178;
    $25A0, $25AA, $25FC, $25FE: Result := #254;
    $2190: Result := #27;                      // flechas
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
    // circulos y puntos (bullets de CLIs y TUIs modernas), que antes
    // caian a '?'
    $25CF, $25CB, $25C9, $25CE, $2B24, $23FA, $26AB, $26AA: Result := #7;
    $25E6, $2218, $2219, $2027, $30FB: Result := #250;
    $25AB, $25FB, $25FD, $25A1, $2610: Result := #254;
    // triangulos/flechas de reproduccion y navegacion
    $23F5, $25B7, $2023: Result := #16;        // play / triangulo derecha
    $23F4, $25C1: Result := #17;
    $23F6: Result := #30;
    $23F7: Result := #31;
    // continuacion de arbol (ramas de arbol, flechas de retorno)
    $23BF, $2937, $21B3: Result := #192;
    // asteriscos decorativos y estrellas (spinners) -> '*'
    $2733, $2734, $273B, $273C, $273D, $2739, $2735,
    $2724, $2725, $2726, $2727, $272F, $2730: Result := '*';
    $2605, $2606, $2B50: Result := '*';        // estrellas
    // simbolos varios frecuentes en TUIs
    $2699: Result := '*';                      // engranaje
    $26A0: Result := '!';                      // aviso
    $2764, $2665: Result := #3;                // corazon
    $221A: Result := 'v';                      // raiz -> check visual
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
  W, i, xo: integer;
  T: string;
begin
  B := Default(TDrawBuffer);
  // icono de minimizada: marco y titulo en negro (el gris pasivo no se
  // lee sobre el azul claro); dibujo propio de las dos filas
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
  State := State and (not sfShadow);     // sin sombra: tiling exacto
  R.Assign(1, 1, Bounds.B.X - Bounds.A.X - 1, Bounds.B.Y - Bounds.A.Y - 1);
  Term := New(PTermView, Init(R, APane));
  Insert(Term);
end;

procedure TTermWindow.HandleEvent(var Event: TEvent);
var
  App: PSuperApp;
begin
  // un clic sobre el icono minimizado lo restaura, antes de que la
  // seleccion de ventana del vendor se trague el evento
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
  inherited HandleEvent(Event);
end;

procedure TTermWindow.SizeLimits(var Min, Max: Objects.TPoint);
begin
  inherited SizeLimits(Min, Max);
  if Minimized then
  begin
    // el icono de minimizada es una barrita de 2 filas
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
    // icono estilo Turbo Vision: la ventana queda visible como barrita;
    // la aplicacion la coloca abajo con ArrangeIcons
    GetBounds(SavedRect);
    Minimized := True;
    Options := Options and (not ofTileable); // fuera del Tile del vendor
    if Term <> nil then
      Term^.Hide; // el icono es solo marco y titulo
  end;
end;

procedure TTermWindow.Restore;
begin
  if Minimized then
  begin
    Minimized := False; // el llamante recoloca con RelayoutAll
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
  inherited Init;
  LoadConfig(Cfg);
  if Cfg.Palette = 'bw' then
    AppPalette := apBlackWhite
  else if Cfg.Palette = 'mono' then
    AppPalette := apMonochrome
  else
    AppPalette := apColor;
  CurrentLanguage := Cfg.Language;
  SetMessageBoxLanguage(CurrentLanguage = ulSpanish);
  // clases de ventana: fichero de usuario + fichero de sistema (gana user);
  // si SUPERTERM_INI apunta al fichero de usuario, la mezcla deduplica
  LoadWindowClasses(ConfigFile, coUser, WClasses);
  LoadWindowClasses(SystemConfigFile, coSystem, SysClassesTmp);
  MergeWindowClasses(WClasses, SysClassesTmp);
  // perfiles: [profile.*] de usuario+sistema mas plantillas legadas aplanadas
  LoadProfiles(ConfigFile, SystemConfigFile, Profiles);
  DebugLog(Format('init: sysini=%s shell=%s classes=%d profiles=%d',
    [SystemConfigFile, Cfg.Shell, Length(WClasses), Length(Profiles)]));
  // inherited Init llamo a InitMenuBar con WClasses vacio: reconstruir
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

  CurrentSessionName := '';
  if AttachRequested then
  begin
    if AttachSocket = '' then
    begin
      AttachSocket := PickSessionSocketUI(True);
      ResetVideoSurface;
      ReDraw;
    end;
    if (AttachSocket <> '') and AttachRemoteSession(AttachSocket) then
      Exit;
    // seleccion cancelada o attach fallido: salir limpio sin guardar.
    // Un cmQuit posteado aqui se perderia (TGroup.Execute pone EndState
    // a 0 al entrar en Run), asi que se marca AbortRun y el programa
    // principal se salta Run; no se construye ningun workspace
    SkipSave := True;
    AbortRun := True;
    Exit;
  end
  else if PromptAttachOnStart then
    Exit;

  if ProfileMode then
  begin
    // resolucion del perfil por defecto: default_profile nuevo, con
    // retro-compatibilidad para default_template [+ /default_session]
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
    // terminales definidos en /etc/superterm/superterm.ini
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
  // reaplicar titulos propios (renombrados a mano) tal como se guardaron
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
  else if ProfileMode then
  begin
    if not SkipSave then
    begin
      RememberProfileSelection;
      SaveConfig(Cfg);
    end;
  end
  // SkipSave tambien protege este ramal: tras un attach abortado o una
  // conexion remota perdida, Lay puede ser el layout remoto (con Panes=nil)
  // y guardarlo machacaria el session.ini local con paneles vacios
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
    // wcLocal/wcCommand: comando compuesto con la semantica unificada
    // (para wcSSH el camino es el argv estructurado de mas abajo)
    CmdS := ComposePaneCommand(WClasses[ASysIdx], ACmd, '', '', ShellS,
      Cfg.LoginShell);
    if WClasses[ASysIdx].Kind <> wcSSH then
      CwdS := WClasses[ASysIdx].Cwd
    else
      CwdS := '';
    if ACwd <> '' then
      CwdS := ACwd;
    ExtraS := '';
    // titulo por defecto de la clase (o su nombre si no tiene titulo)
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
  PaneConnect[i] := ''; // los llamantes con conexion libre lo fijan despues
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
  // un panel de clase conserva su titulo (nombre/titulo de la clase); el
  // refresco periodico por cwd no debe pisarlo
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
  // con minimizadas, el mosaico reserva la franja inferior de iconos
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

// agrupa los iconos de minimizadas en filas al pie del escritorio
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
  // NO re-tilear: las demas ventanas se quedan donde el usuario las dejo.
  // Solo se recolocan los iconos de minimizadas al pie del escritorio.
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
  // volver EXACTAMENTE a donde estaba antes de minimizar, sin re-tilear ni
  // tocar el resto de ventanas (el usuario manda sobre sus posiciones)
  if (Win[i]^.SavedRect.B.X > Win[i]^.SavedRect.A.X) and
     (Win[i]^.SavedRect.B.Y > Win[i]^.SavedRect.A.Y) then
    Win[i]^.Locate(Win[i]^.SavedRect);
  Lay.Focused := i;
  ArrangeIcons;   // recolocar los iconos que sigan minimizados
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
  ArrangeIcons;   // colocar todos los iconos al pie, sin re-tilear
  RebuildMenu;
end;

procedure TSuperApp.RestoreAllWindows;
var
  i: integer;
begin
  // cada ventana vuelve a su posicion previa a minimizar; nada se re-tila
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
    // el panel vive en el daemon: pedirlo alli; la ventana llega para
    // todos los clientes con el evento NEWPANE_EV
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
begin
  Result := False;
  Remote := TSessionClient.Create;
  if not Remote.Connect(APath, Snapshot) then
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
  // guardar el estado previo: la carga por panel aun puede fallar (blob de
  // pantalla corrupto o ventana no creada) y hay que poder restaurarlo
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
    // deshacer toda la mutacion: el arranque debe continuar como si el
    // attach nunca se hubiera intentado (perfil incluido)
    RemoteMode := False;
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
  // geometria de ventanas que el daemon conserva (movidas, maximizadas,
  // minimizadas); solo aplicable si el escritorio mide igual que al guardar
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
  ResetVideoSurface;
  ReDraw;
  FocusPane(Lay.Focused);
  RebuildMenu;
  Result := True;
end;

// selector de sesiones para --attach (o arranque con sesiones vivas)
function TSuperApp.PickSessionSocketUI(AForAttach: boolean): string;
var
  Act: TSessionPickAction;
  Path: string;
begin
  Result := '';
  Path := '';
  Act := RunSessionPicker(not AForAttach, Path);
  if Act = spAttach then
    Result := Path;
end;

// arranque normal con sesiones vivas: ofrecer engancharse antes de crear
// un workspace nuevo; Esc o "Nueva sesion" siguen el arranque normal
function TSuperApp.PromptAttachOnStart: boolean;
var
  Infos: TSessionInfoArray;
  Act: TSessionPickAction;
  Path: string;
begin
  Result := False;
  if not EnumerateSessions(Infos) then
    Exit;
  Path := '';
  Act := RunSessionPicker(True, Path);
  if (Act = spAttach) and (Path <> '') then
    Result := AttachRemoteSession(Path);
end;

// gestor de sesiones dentro de la app: listar, purgar y cerrar; el cambio
// de sesion en caliente llegara mas adelante (separar primero)
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
  DGeom: TPaneGeomArray;
  DW, DH: integer;
  NameBuf: ShortString;
  SessName, ProfName: string;
begin
  if DetachRequested then
    Exit;
  if RemoteMode then
  begin
    // cliente ya enganchado: el daemon conserva su nombre, sin prompt;
    // empujar antes el layout para que el proximo attach lo restaure
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
  // nombre de la sesion: por defecto el perfil activo (o sesion-N libre);
  // colision con una sesion viva -> sugerir nombre-2 y volver a preguntar
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
      if PaneTerm[I] < Length(WClasses) then
        Terms[I] := WClasses[PaneTerm[I]].Name;
    if (PtyRefs[I] = nil) or (ScreenRefs[I] = nil) then
    begin
      // avisar en vez de abortar en silencio: el usuario ya confirmo un
      // nombre y debe saber que la sesion NO se ha separado
      MessageBox(UiText(
        'Cannot detach: a pane has no live terminal.',
        'No se puede separar: un panel no tiene terminal vivo.'), nil,
        mfError or mfOKButton);
      Exit;
    end;
  end;
  // el daemon nace conociendo la geometria actual de las ventanas
  CollectPaneGeom(DGeom, DW, DH);
  if not StartDetachedServer(SessName, ProfName, Lay, PtyRefs, ScreenRefs,
    Titles, Terms, Lay.Focused, DGeom, DW, DH) then
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
      // ssh: la precedencia pane.post > class.post > pane.cmd > class.cmd
      // se resuelve entre el override y BuildWindowClassExec
      CommandOverride := PS.PostConnect;
      if CommandOverride = '' then
        CommandOverride := PS.Cmd;
      StartPaneEx(i, PS.Cwd, '', SysIdx, '', '', TitleS, PS.ScrollBack,
        CommandOverride);
    end
    else if SysIdx >= 0 then
    begin
      // clase local o de comando libre con overrides del panel
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
      // panel ad-hoc sin clase (incluye los del asistente persistidos)
      AdHoc := DefaultWindowClass;
      LocalCmd := ComposePaneCommand(AdHoc, PS.Cmd, PS.PostConnect,
        PS.Connect, Cfg.Shell, Cfg.LoginShell);
      StartPaneEx(i, PS.Cwd, LocalCmd, -1, '', '', TitleS, PS.ScrollBack);
      PaneConnect[i] := PS.Connect;
    end;
    // titulo propio guardado en el perfil: manda sobre clase/cwd
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
end;

// reaplica la geometria EXACTA guardada en el perfil (posicion/tamano
// manuales, maximizadas y minimizadas), dejando todo como al guardarlo;
// solo si el escritorio mide igual (los bounds son absolutos)
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
  // los minimizados al final (MinimizeWindow gestiona el foco e iconos)
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
begin
  Result := Default(TProfileWindowSpec);
  Result.Name := AName;
  Result.Enabled := True;
  Result.Layout := SaveLayoutString(Lay);
  Result.FocusedPane := Lay.Focused;
  // tamano del escritorio: los bounds guardados son absolutos y solo se
  // reaplican si el escritorio mide igual al restaurar el perfil
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
    // geometria EXACTA de la ventana: maximizada aporta su ZoomRect,
    // minimizada su SavedRect, el resto sus bounds actuales
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
    // titulo propio: se guarda solo si difiere del titulo por defecto de la
    // clase (para no fijar en el perfil un titulo que la clase ya aporta)
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
        // una shell interactiva se captura como cmd vacio (= shell normal)
        if not IsPlainShell(Panes[i].TitleArgs, Panes[i].TitleCmd) then
        begin
          if Length(Panes[i].TitleArgs) > 0 then
            Result.Panes[i].Cmd := ArgsAsShell(Panes[i].TitleArgs)
          else
            Result.Panes[i].Cmd := Panes[i].TitleCmd;
        end;
        Result.Panes[i].Cwd := Panes[i].TitleCwd;
      end;
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
  // sin FormatStr: el nombre podria contener '%'
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
          // guardar el area actual SOLO en la ventana activa del perfil,
          // conservando sus demas ventanas
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
    // recordar la conexion libre para poder guardar esto como perfil
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
    ResetVideoSurface;
    ReDraw;
    FocusPane(Lay.Focused);
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
  // dialogo estandar: paleta de dialogo con contraste correcto (el antiguo
  // THelpDialog pintaba con GetColor(1), el color del marco pasivo)
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

// renombra el titulo de la ventana enfocada; queda fijado (TitleFixed) para
// que el refresco periodico no lo pise, y persiste en sesion y en perfil
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
  // en remoto el panel vive en el daemon: matarlo alli y compactar en
  // espejo (mismos indices); en local KillPane hace el trabajo
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
  // NO re-tilear: las ventanas que quedan conservan su tamano y posicion.
  // KillPane ya quito la cerrada del escritorio; solo repintar.
  ReDraw;
  FocusPane(Lay.Focused);
  SyncRemoteLayout; // el arbol cambio: reflejarlo en el daemon
end;

// geometria actual de todas las ventanas (mismas reglas que el guardado
// local: una maximizada aporta su ZoomRect, una minimizada sus bounds)
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

// estando enganchado, empuja el estado del cliente al daemon para que el
// proximo attach restaure exactamente lo que se ve ahora
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

// huella del estado visible (geometria+titulos+foco): si cambia respecto
// a lo ultimo sincronizado, hay que empujar el layout al daemon
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

// aplica un LAYOUT_EV difundido por el daemon (otro cliente movio,
// minimizo o renombro ventanas): arbol, titulos, geometria y foco
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
    Exit;   // desincronizado: llegara otro evento tras converger
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
    // geometria solo si ambos escritorios miden igual
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
  ReDraw;
  // lo aplicado ya es el estado comun: no re-empujarlo (evita rebotes)
  RemoteLayoutHash := ComputeLayoutHash;
end;

// otro cliente (o la CLI) cerro un panel: compactar en espejo del daemon
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
  ReDraw;
  FocusPane(Lay.Focused);
  RemoteLayoutHash := ComputeLayoutHash;
end;

// el daemon creo un panel (pedido por este cliente, por otro o por la
// CLI): repetir el split en local y darle ventana
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
    Exit;   // desincronizado: mejor no tocar nada
  OldCount := Lay.PaneCount;
  if Dir = 1 then
    SDir := sdH
  else
    SDir := sdV;
  if not Lay.SplitPane(At, SDir) then
    Exit;
  if Lay.LastInsertedIndex <> NewIdx then
  begin
    // el arbol local no coincide con el del daemon: deshacer
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

// tamano autoritativo del daemon (minimo comun entre clientes): ajustar
// la TScreen sin reenviar peticion (supresion de eco)
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
  ReDraw;
  RemoteLayoutHash := ComputeLayoutHash;
end;

// Window|Tile clasico: recalcular el mosaico y descartar geometria manual
procedure TSuperApp.DoTilePanes;
var
  i: integer;
begin
  for i := 0 to MAX_PANES - 1 do
    if (Win[i] <> nil) and Win[i]^.Minimized then
      RestoreWindow(i);
  RelayoutAll;
  ResetVideoSurface;
  ReDraw;
  FocusPane(Lay.Focused);
  SyncRemoteLayout;
end;

// Window|Cascade clasico: ventanas escalonadas de 2/3 del escritorio
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
  ResetVideoSurface;
  ReDraw;
  FocusPane(Lay.Focused);
  SyncRemoteLayout;
end;

// rejilla del vendor: reparte todas las visibles en filas y columnas
// que quepan en pantalla (TDeskTop.Tile sobre las vistas ofTileable)
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
    Dec(R.B.Y, 2); // respetar la franja de iconos
  Desktop^.Tile(R);
  ResetVideoSurface;
  ReDraw;
  FocusPane(Lay.Focused);
  SyncRemoteLayout;
end;

// Window|List clasico (Alt+0): elegir panel, restaurando si esta minimizado
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

// cambio de paleta en vivo + persistencia en superterm.ini
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
  ResetVideoSurface;
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
    // titulo propio (renombrado a mano): guardarlo para restaurarlo tal cual
    if (i < MAX_PANES) and (Win[i] <> nil) and Win[i]^.TitleFixed and
       (Win[i]^.Title <> nil) then
      Pin[i].Title := Trim(Win[i]^.Title^);
    // geometria y estado de la ventana: para una maximizada el rect real
    // es ZoomRect (el de restauracion); Minimize solo oculta, conserva bounds
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
          // toast contextual: cada modo dice exactamente que se guardo
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
  if RemoteMode then
  begin
    // con un modal abierto no se drena el socket: los eventos (cerrar o
    // crear paneles, salida) esperan en orden a que el modal termine, y
    // asi los indices de panel nunca se desincronizan a mitad de dialogo
    if Current = PView(Desktop) then
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
            // marcar antes del MessageBox: nada de esta instancia debe
            // guardarse (el layout es el de la sesion remota perdida)
            SkipSave := True;
            MessageBox(UiText('Connection to the session was lost.',
              'Se perdio la conexion con la sesion.'), nil,
              mfError or mfOKButton);
            Message(@Self, evCommand, cmQuit, nil);
          end;
      end;
      if not RemoteMode then
        Break;   // shutdown/lost: no seguir drenando
      end;
    // empuje con debounce del layout: mover, minimizar o renombrar aqui
    // se refleja en el daemon (y de ahi en los demas clientes) sin tocar
    // cada accion de la UI una a una
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
             (PaneTerm[i] < Length(WClasses)) and
             (WClasses[PaneTerm[i]].Kind = wcSSH) then
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
  HasProfiles: boolean;
  PaletteItems: PMenuItem;
begin
  R := Default(Objects.TRect);
  GetExtent(R);
  R.B.Y := R.A.Y + 1;

  // ---- Paneles: operaciones de tile (split, foco, zoom, min, tamano) ----
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

  // ---- Ventanas: solo navegacion de workspaces del perfil activo ----
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
  // organizacion de ventanas en pantalla (como Window del IDE clasico)
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

  // ---- Clases: abre un panel nuevo de cada clase configurada ----
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
  // gestion al final del menu, separada de la lista de apertura
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

  // ---- Perfiles: activar y gestionar ----
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
  SessItems := NewItem(UiText('~A~ttach / manage sessions...',
    '~C~onectar / gestionar sesiones...'), PrefixKeyLabel(Cfg.PrefixKey) + ' s', kbNoKey,
    cmSessionPick, hcNoContext, SessItems);
  SessItems := NewItem(UiText('~D~etach...', '~S~eparar...'), PrefixKeyLabel(Cfg.PrefixKey) + ' d',
    kbNoKey, cmDetach, hcNoContext, SessItems);
  // enganchado a una sesion con nombre: mostrarlo como fila informativa
  if RemoteMode and (CurrentSessionName <> '') then
  begin
    SessItems := NewLine(SessItems);
    SessItems := NewInfoItem(UiText('Session: ', 'Sesion: ') +
      Copy(CurrentSessionName, 1, 24), '', SessItems);
  end;
  MSessMenu := NewMenu(SessItems);

  // ---- Opciones: idioma en orden fijo, nombres sin traducir ----
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
      kbNoKey, cmToggleAutoRestore, hcNoContext, nil))))));

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
