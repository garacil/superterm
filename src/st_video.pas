unit st_video;

{$mode objfpc}{$H+}

interface

procedure InstallWideVideoOutput;
procedure CaptureConsoleCursor;
procedure RestoreConsoleCursor;
// Hand the terminal back exactly as it was found: every mouse mode off,
// bracketed paste off, and anything the terminal already reported dropped.
// Call at the very end, after the application is done.
procedure ReleaseConsoleInput;
// True on a real Linux virtual console (TERM=linux), where the mouse can only
// come from gpm and never from terminal escape sequences.
function IsLinuxConsole: boolean;

// Passthrough: while active the FreeVision screen driver stays silent and the
// client writes a pane's raw PTY bytes straight to the host terminal, so a
// full-fidelity TUI (truecolor, emoji, wide glyphs) renders untouched.
procedure PassthroughRaw(const Data; ALen: LongInt);
// Raw escape/string writer to the host terminal (respects OutputFailed).
procedure WriteRaw(const S: AnsiString);

// True when more input is already waiting to be read. Painting a frame that
// the very next event will overwrite is wasted work and, over a slow link,
// wasted latency -- so callers use this to coalesce a burst of events into one
// frame. Bounded by time so continuous input can never starve the screen.
function InputPending: Boolean;

// Rich overlay (the "option B" renderer). A pane registers each of its cells
// -- the full UTF-8 glyph plus the EXACT color -- at its GLOBAL screen
// position, passing the VideoBuf word it wrote there as an oracle. Then
// WideUpdateScreen emits the rich cell (truecolor + UTF-8) whenever VideoBuf
// still holds that oracle (i.e. the pane cell is the visible top one), and
// falls back to the CP437/16-color chrome for everything else (window frames,
// menu, status line, cells covered by another window). This keeps FreeVision
// untouched: the grid is still drawn (it is the visibility oracle), but the
// pane area is presented richly. Colors: $01RRGGBB = truecolor;
// $02000000 or index (0..15, 8..15 = bright) = the 16-color fallback;
// $03000000 or index (16..255) = an xterm-256 palette index; 0 = the
// terminal default. Flags: 1 = bold, 2 = underline, 4 = reverse. ASkip marks
// a wide-glyph continuation cell (its lead already emitted the 2-wide glyph,
// so nothing is written here).
procedure RichSetCell(AX, AY: LongInt; const AGlyph: AnsiString;
  AFg, ABg: LongWord; AFlags: Byte; AOracle: Word; ASkip: Boolean;
  AWide: Boolean);
// Drop the whole overlay (nothing renders rich until panes repopulate it).
procedure RichInvalidate;
// Forget one cell. A view that covers ground it does not colour richly says
// so here, instead of leaving whatever the previous layout registered.
procedure RichClear(AX, AY: LongInt);

// Wireframe drag. While a window is dragged with its contents hidden, the
// window itself is hidden too, so FreeVision repaints the desktop and the
// other windows normally and VideoBuf holds the TRUE screen. The moving
// outline is then painted straight to the terminal, outside the buffer, and
// erased by repainting just its cells back from VideoBuf. Only the ring
// travels -- a few dozen cells per step instead of the window's whole area.
procedure OutlinePaint(X1, Y1, X2, Y2: LongInt; AAttr: Byte);
// Forget what we believe is on those ring cells, so the NEXT update repaints
// them through the normal path. Painting them back by hand is wrong: this unit
// would rebuild them from the 16-colour VideoBuf and a pane cell would come
// back as its CP437 approximation instead of its real colour -- text restored,
// attributes lost. Letting the regular delta redraw them keeps truecolor.
procedure OutlineInvalidate(X1, Y1, X2, Y2: LongInt);
// Move an outline by touching ONLY the difference between the two rings: the
// cells the frame leaves behind are invalidated (so the normal renderer
// repaints them with their real colours) and only the cells it newly occupies
// are drawn. Consecutive positions overlap almost completely, so a one-cell
// step costs a sliver instead of two full perimeters.
procedure OutlineLeaveDiff(OX1, OY1, OX2, OY2, NX1, NY1, NX2, NY2: LongInt);
procedure OutlineEnterDiff(NX1, NY1, NX2, NY2, OX1, OY1, OX2, OY2: LongInt;
  AAttr: Byte);

// Declare that what the terminal currently shows is unknown, so the NEXT
// update repaints every cell. This is the only legitimate way to ask for a
// full repaint: the per-cell delta is otherwise always trustworthy, because
// this unit is the only writer to the terminal and it tracks what it wrote.
// FreeVision's TGroup.Redraw asks for a forced update on every ChangeBounds,
// which during a window drag meant a whole-screen resend per mouse step; that
// request is now ignored and only an explicit invalidation forces a repaint.
procedure InvalidateFrame;

var
  PassthroughActive: Boolean = False;
  // startup: while True, FreeVision draws into the buffer normally but the
  // driver does NOT write to the terminal, so the whole build+promote+
  // attach is flushed ONCE (a forced paint at the end) instead of several
  SuppressFlush: Boolean = False;

implementation

uses
  SysUtils, termio, BaseUnix, Video, st_debug;

var
  SavedDriver: TVideoDriver;
  DriverInstalled: Boolean;
  OutputFailed: Boolean;
  ConsoleRow, ConsoleCol: Integer; // cursor position at startup (0 = unknown)
  UseSyncOutput: Boolean = False;  // DECSET 2026; opt-in via SUPERTERM_SYNC=1

procedure PassthroughRaw(const Data; ALen: LongInt);
var
  P: PByte;
  Left: LongInt;
  Written: Int64;
begin
  if (ALen <= 0) or OutputFailed then
    Exit;
  P := @Data;
  Left := ALen;
  while Left > 0 do
  begin
    Written := FileWrite(StdOutputHandle, P^, Left);
    if Written > 0 then
    begin
      Inc(P, Written);
      Dec(Left, LongInt(Written));
    end
    else
      Exit;   // EINTR is retried by FileWrite; anything else = give up on this chunk
  end;
  if DebugActive then
    DebugLog(Format('pass: raw %d bytes straight to terminal', [ALen]));
end;

function VideoCellAt(ABuffer: PVideoBuf; AIndex: LongInt): TVideoCell; inline;
var
  Cell: PVideoCell;
begin
  { VideoBuf is dynamically allocated even though PVideoBuf has a legacy
    fixed upper bound in the RTL declaration. Use cell-sized pointer math so
    wide screens do not depend on that declaration. }
  Cell := PVideoCell(ABuffer);
  Inc(Cell, AIndex);
  Result := Cell^;
end;

procedure WriteRaw(const S: AnsiString);
var
  Offset, Remaining: LongInt;
  Written: Int64;
begin
  if OutputFailed or (Length(S) = 0) then
    Exit;
  Offset := 1;
  while Offset <= Length(S) do
  begin
    Remaining := Length(S) - Offset + 1;
    { FileWrite retries EINTR internally, so any non-positive result here
      is a real failure. }
    Written := FileWrite(StdOutputHandle, S[Offset], Remaining);
    if Written > 0 then
    begin
      if Written > Remaining then
      begin
        OutputFailed := True;
        Exit;
      end;
      Inc(Offset, LongInt(Written));
    end
    else
    begin
      OutputFailed := True;
      Exit;
    end;
  end;
end;

function InputPending: Boolean;
var
  fds: TFDSet;
  tv: TTimeVal;
begin
  fpFD_ZERO(fds);
  fpFD_SET(StdInputHandle, fds);
  tv.tv_sec := 0;
  tv.tv_usec := 0;
  InputPending := fpSelect(StdInputHandle + 1, @fds, nil, nil, @tv) > 0;
end;

function VgaColorToAnsi(AColor: Byte; AForeground: Boolean): Integer;
var
  Base: Byte;
begin
  Base := AColor and $07;
  case Base of
    0: Base := 0;
    1: Base := 4;
    2: Base := 2;
    3: Base := 6;
    4: Base := 1;
    5: Base := 5;
    6: Base := 3;
  else
    Base := 7;
  end;
  if AForeground then
    if (AColor and $08) <> 0 then
      Result := 90 + Base
    else
      Result := 30 + Base
  else if (AColor and $08) <> 0 then
    Result := 100 + Base
  else
    Result := 40 + Base;
end;

function AttrSequence(AAttr: Byte): AnsiString;
var
  Foreground, Background: Byte;
begin
  Foreground := AAttr and $0F;
  Background := (AAttr shr 4) and $0F;
  Result := #27'[0;' + IntToStr(VgaColorToAnsi(Foreground, True)) + ';' +
    IntToStr(VgaColorToAnsi(Background, False)) + 'm';
end;

function VgaChar(AChar: Byte): AnsiString;
begin
  if (AChar >= 32) and (AChar < 127) then
    Exit(AnsiChar(AChar));
  case AChar of
    0: Result := ' ';
    1: Result := '☺';
    2: Result := '☻';
    3: Result := '♥';
    4: Result := '♦';
    5: Result := '♣';
    6: Result := '♠';
    7: Result := '•';
    8: Result := '█';
    9: Result := '○';
    10: Result := '◙';
    11: Result := '♂';
    12: Result := '♀';
    13: Result := '♪';
    14: Result := '♫';
    15: Result := '☼';
    16: Result := '►';
    17: Result := '◄';
    18: Result := '↕';
    19: Result := '‼';
    20: Result := '¶';
    21: Result := '§';
    22: Result := '▬';
    23: Result := '↨';
    24: Result := '↑';
    25: Result := '↓';
    26: Result := '→';
    27: Result := '←';
    28: Result := '∟';
    29: Result := '↔';
    30: Result := '▲';
    31: Result := '▼';
    129: Result := 'ü';
    130: Result := 'é';
    144: Result := 'É';
    160: Result := 'á';
    161: Result := 'í';
    162: Result := 'ó';
    163: Result := 'ú';
    164: Result := 'ñ';
    165: Result := 'Ñ';
    176: Result := '░';
    177: Result := '▒';
    178: Result := '▓';
    179: Result := '│';
    180: Result := '┤';
    185: Result := '╣';
    186: Result := '║';
    187: Result := '╗';
    188: Result := '╝';
    191: Result := '┐';
    192: Result := '└';
    193: Result := '┴';
    194: Result := '┬';
    195: Result := '├';
    196: Result := '─';
    197: Result := '┼';
    199: Result := '╟';
    200: Result := '╚';
    201: Result := '╔';
    202: Result := '╩';
    203: Result := '╦';
    204: Result := '╠';
    205: Result := '═';
    206: Result := '╬'; // canonical CP437 (0xCE is the double cross)
    207: Result := '╧';
    209: Result := '╤';
    217: Result := '┘';
    218: Result := '┌';
    219: Result := '█';
    220: Result := '▄';
    223: Result := '▀';
    250: Result := '·';
    254: Result := '■';
  else
    Result := '?';
end;
end;

function CursorPosition(AX, AY: Word): AnsiString;
begin
  Result := #27'[' + IntToStr(AY + 1) + ';' + IntToStr(AX + 1) + 'H';
end;

function CellsToStr(AStart, AStop: LongInt): AnsiString;
var
  I: LongInt;
begin
  Result := '';
  for I := AStart to AStop - 1 do
    Result := Result + VgaChar(Byte(VideoCellAt(VideoBuf, I)));
end;

type
  // overlay entry populated by panes; persists across frames and is gated at
  // emission time by Oracle = VideoBuf (so a covered/scrolled cell falls back
  // to chrome automatically without any explicit invalidation)
  TRichCell = record
    Valid: Boolean;
    Skip: Boolean;      // wide-glyph continuation: emit nothing here
    Wide: Boolean;      // lead of a two-column glyph
    Oracle: Word;       // the VideoBuf word the pane wrote at this cell
    Glyph: string[7];   // UTF-8 bytes to emit
    Fg, Bg: LongWord;
    Flags: Byte;
  end;
  // the per-cell "effective" screen the delta is computed against: either a
  // rich pane cell or a chrome cell, unified so one diff covers both
  TEffCell = record
    Skip: Boolean;
    Rich: Boolean;
    Wide: Boolean;
    Glyph: string[7];
    Attr: Byte;         // chrome path (VGA attribute byte)
    Fg, Bg: LongWord;   // rich path
    Flags: Byte;
  end;

const
  COALESCE_MS = 40;   // never defer a frame longer than this: ~25 fps floor

var
  LastEmitTick: QWord = 0;
  RichScreen: array of TRichCell;   // overlay, persists across frames
  EffOld: array of TEffCell;        // previous frame's effective screen (delta)
  RichW: LongInt = 0;
  RichH: LongInt = 0;

procedure RichEnsureSize;
var
  i: LongInt;
begin
  if (RichW = ScreenWidth) and (RichH = ScreenHeight) and (RichScreen <> nil) then
    Exit;
  RichW := ScreenWidth;
  RichH := ScreenHeight;
  SetLength(RichScreen, RichW * RichH);
  SetLength(EffOld, RichW * RichH);
  for i := 0 to High(RichScreen) do
    RichScreen[i].Valid := False;
  // sentinel that never equals a real effective cell -> first frame after a
  // resize is a full paint
  for i := 0 to High(EffOld) do
  begin
    EffOld[i].Skip := False;
    EffOld[i].Rich := False;
    EffOld[i].Glyph := #1;
    EffOld[i].Attr := $FF;
  end;
end;

procedure RichInvalidate;
var
  i: LongInt;
begin
  for i := 0 to High(RichScreen) do
    RichScreen[i].Valid := False;
end;

procedure RichClear(AX, AY: LongInt);
var
  idx: LongInt;
begin
  if (RichW <> ScreenWidth) or (RichH <> ScreenHeight) then
    RichEnsureSize;
  if (AX < 0) or (AY < 0) or (AX >= RichW) or (AY >= RichH) then
    Exit;
  idx := AY * RichW + AX;
  if (idx >= 0) and (idx <= High(RichScreen)) then
    RichScreen[idx].Valid := False;
end;

procedure InvalidateFrame;
var
  i: LongInt;
begin
  // poison the previous-frame snapshot so no cell can compare equal
  for i := 0 to High(EffOld) do
  begin
    EffOld[i].Skip := False;
    EffOld[i].Rich := False;
    EffOld[i].Glyph := #1;
    EffOld[i].Attr := $FF;
  end;
  if (OldVideoBuf <> nil) and (VideoBufSize > 0) then
    FillChar(OldVideoBuf^, VideoBufSize, $FF);
end;

procedure RichSetCell(AX, AY: LongInt; const AGlyph: AnsiString;
  AFg, ABg: LongWord; AFlags: Byte; AOracle: Word; ASkip: Boolean;
  AWide: Boolean);
var
  idx: LongInt;
begin
  if (RichW <> ScreenWidth) or (RichH <> ScreenHeight) then
    RichEnsureSize;
  if (AX < 0) or (AY < 0) or (AX >= RichW) or (AY >= RichH) then
    Exit;
  idx := AY * RichW + AX;
  RichScreen[idx].Valid := True;
  RichScreen[idx].Skip := ASkip;
  RichScreen[idx].Wide := AWide;
  RichScreen[idx].Oracle := AOracle;
  if Length(AGlyph) > 7 then
    RichScreen[idx].Glyph := Copy(AGlyph, 1, 7)
  else
    RichScreen[idx].Glyph := AGlyph;
  RichScreen[idx].Fg := AFg;
  RichScreen[idx].Bg := ABg;
  RichScreen[idx].Flags := AFlags;
end;

// SGR for a rich cell: a full reset then bold/underline/reverse and the fg/bg
// as truecolor (38/48;2;r;g;b) or 16-color (30-37/90-97, 40-47/100-107).
// A missing color falls through to the terminal default from the leading 0.
function RichSGR(AFg, ABg: LongWord; AFlags: Byte): AnsiString;
var
  n: LongWord;
begin
  Result := #27'[0';
  if (AFlags and 1) <> 0 then Result := Result + ';1';
  if (AFlags and 8) <> 0 then Result := Result + ';2';   // faint
  if (AFlags and 2) <> 0 then Result := Result + ';4';
  if (AFlags and 4) <> 0 then Result := Result + ';7';
  case AFg shr 24 of
    1: Result := Result + ';38;2;' + IntToStr((AFg shr 16) and $FF) + ';' +
         IntToStr((AFg shr 8) and $FF) + ';' + IntToStr(AFg and $FF);
    2: begin
         n := AFg and $0F;
         if n < 8 then Result := Result + ';' + IntToStr(30 + LongInt(n))
         else Result := Result + ';' + IntToStr(90 + (LongInt(n) - 8));
       end;
    3: Result := Result + ';38;5;' + IntToStr(AFg and $FF);
  end;
  case ABg shr 24 of
    1: Result := Result + ';48;2;' + IntToStr((ABg shr 16) and $FF) + ';' +
         IntToStr((ABg shr 8) and $FF) + ';' + IntToStr(ABg and $FF);
    2: begin
         n := ABg and $0F;
         if n < 8 then Result := Result + ';' + IntToStr(40 + LongInt(n))
         else Result := Result + ';' + IntToStr(100 + (LongInt(n) - 8));
       end;
    3: Result := Result + ';48;5;' + IntToStr(ABg and $FF);
  end;
  Result := Result + 'm';
end;

function EffEqual(const A, B: TEffCell): Boolean;
begin
  if A.Skip or B.Skip then Exit(A.Skip and B.Skip);
  if A.Rich <> B.Rich then Exit(False);
  if A.Glyph <> B.Glyph then Exit(False);
  if A.Rich then
    Result := (A.Fg = B.Fg) and (A.Bg = B.Bg) and (A.Flags = B.Flags) and
              (A.Wide = B.Wide)
  else
    Result := (A.Attr = B.Attr);
end;


// --- wireframe drag outline -------------------------------------------------

// Ring cells of a rectangle, CLIPPED to the screen. A dragged window is
// routinely pushed partly off-screen, and bailing out on an out-of-range
// rectangle meant the outline was neither painted nor erased -- the frame
// vanished and left debris behind. Clip instead, and draw what is visible.

function OnScreen(X, Y: LongInt): Boolean; inline;
begin
  OnScreen := (X >= 0) and (Y >= 0) and (X < ScreenWidth) and (Y < ScreenHeight);
end;

procedure OutlineInvalidate(X1, Y1, X2, Y2: LongInt);
var
  X, Y: LongInt;

  procedure Poison(AX, AY: LongInt);
  var
    idx: LongInt;
  begin
    if not OnScreen(AX, AY) then
      Exit;
    idx := AY * RichW + AX;
    if (idx < 0) or (idx > High(EffOld)) then
      Exit;
    EffOld[idx].Skip := False;
    EffOld[idx].Rich := False;
    EffOld[idx].Glyph := #1;      // no real cell can compare equal to this
    EffOld[idx].Attr := $FF;
  end;

begin
  if (RichW <> ScreenWidth) or (RichH <> ScreenHeight) then
    RichEnsureSize;
  if (X2 < X1) or (Y2 < Y1) then
    Exit;
  for X := X1 to X2 do
  begin
    Poison(X, Y1);
    if Y2 <> Y1 then Poison(X, Y2);
  end;
  for Y := Y1 + 1 to Y2 - 1 do
  begin
    Poison(X1, Y);
    if X2 <> X1 then Poison(X2, Y);
  end;
end;


function OnRing(X, Y, X1, Y1, X2, Y2: LongInt): Boolean;
begin
  OnRing := (X >= X1) and (X <= X2) and (Y >= Y1) and (Y <= Y2) and
            ((X = X1) or (X = X2) or (Y = Y1) or (Y = Y2));
end;

// glyph for a position on a ring
function RingGlyph(X, Y, X1, Y1, X2, Y2: LongInt): AnsiString;
begin
  if (X = X1) and (Y = Y1) then RingGlyph := #$E2#$94#$8C        // U+250C
  else if (X = X2) and (Y = Y1) then RingGlyph := #$E2#$94#$90   // U+2510
  else if (X = X1) and (Y = Y2) then RingGlyph := #$E2#$94#$94   // U+2514
  else if (X = X2) and (Y = Y2) then RingGlyph := #$E2#$94#$98   // U+2518
  else if (Y = Y1) or (Y = Y2) then RingGlyph := #$E2#$94#$80    // U+2500
  else RingGlyph := #$E2#$94#$82;                                // U+2502
end;

procedure OutlineLeaveDiff(OX1, OY1, OX2, OY2, NX1, NY1, NX2, NY2: LongInt);
var
  X, Y: LongInt;

  procedure Maybe(AX, AY: LongInt);
  begin
    if OnRing(AX, AY, NX1, NY1, NX2, NY2) then
      Exit;                       // still covered by the outline: leave it
    OutlineInvalidate(AX, AY, AX, AY);
  end;

begin
  for X := OX1 to OX2 do
  begin
    Maybe(X, OY1);
    if OY2 <> OY1 then Maybe(X, OY2);
  end;
  for Y := OY1 + 1 to OY2 - 1 do
  begin
    Maybe(OX1, Y);
    if OX2 <> OX1 then Maybe(OX2, Y);
  end;
end;

procedure OutlineEnterDiff(NX1, NY1, NX2, NY2, OX1, OY1, OX2, OY2: LongInt;
  AAttr: Byte);
var
  X, Y: LongInt;
  Body: AnsiString;
  LastX, LastY: LongInt;

  procedure Put(AX, AY: LongInt; Corner: Boolean);
  begin
    if not OnScreen(AX, AY) then
      Exit;
    if Corner then ;   // corners always differ in glyph, handled by the test
    // A cell already under the outline may still need redrawing: staying on
    // the ring is not enough, its GLYPH can change. Moving one step
    // horizontally or vertically keeps two corners on the ring but turns them
    // into edge segments (and edges into corners), so skipping them left a
    // corner glyph sitting in the middle of a straight side. Compare the
    // glyphs, not the membership. (Diagonal steps never showed it because no
    // corner is shared.)
    if OnRing(AX, AY, OX1, OY1, OX2, OY2) and
       (RingGlyph(AX, AY, OX1, OY1, OX2, OY2) =
        RingGlyph(AX, AY, NX1, NY1, NX2, NY2)) then
      Exit;
    if (AY <> LastY) or (AX <> LastX + 1) then
      Body := Body + CursorPosition(AX, AY);
    LastX := AX;
    LastY := AY;
    Body := Body + RingGlyph(AX, AY, NX1, NY1, NX2, NY2);
  end;

begin
  if PassthroughActive or OutputFailed then
    Exit;
  if (NX2 <= NX1) or (NY2 <= NY1) then
    Exit;
  Body := AttrSequence(AAttr);
  LastX := -99;
  LastY := -99;
  Put(NX1, NY1, True);
  Put(NX2, NY1, True);
  Put(NX1, NY2, True);
  Put(NX2, NY2, True);
  for X := NX1 + 1 to NX2 - 1 do
  begin
    Put(X, NY1, False);
    Put(X, NY2, False);
  end;
  for Y := NY1 + 1 to NY2 - 1 do
  begin
    Put(NX1, Y, False);
    Put(NX2, Y, False);
  end;
  WriteRaw(Body);
end;

procedure OutlinePaint(X1, Y1, X2, Y2: LongInt; AAttr: Byte);
var
  X, Y: LongInt;
  Body: AnsiString;

  procedure Put(AX, AY: LongInt; const G: AnsiString);
  begin
    if not OnScreen(AX, AY) then
      Exit;
    Body := Body + CursorPosition(AX, AY) + G;
  end;

begin
  if PassthroughActive or OutputFailed then
    Exit;
  if (X2 <= X1) or (Y2 <= Y1) then
    Exit;
  Body := AttrSequence(AAttr);
  // horizontal edges as runs (one cursor move each), verticals cell by cell
  Put(X1, Y1, #$E2#$94#$8C);                      // U+250C
  for X := X1 + 1 to X2 - 1 do
    if OnScreen(X, Y1) then
    begin
      if not OnScreen(X - 1, Y1) then Body := Body + CursorPosition(X, Y1);
      Body := Body + #$E2#$94#$80;                // U+2500
    end;
  if OnScreen(X2, Y1) then
  begin
    if not OnScreen(X2 - 1, Y1) then Body := Body + CursorPosition(X2, Y1);
    Body := Body + #$E2#$94#$90;                  // U+2510
  end;
  Put(X1, Y2, #$E2#$94#$94);                      // U+2514
  for X := X1 + 1 to X2 - 1 do
    if OnScreen(X, Y2) then
    begin
      if not OnScreen(X - 1, Y2) then Body := Body + CursorPosition(X, Y2);
      Body := Body + #$E2#$94#$80;
    end;
  if OnScreen(X2, Y2) then
  begin
    if not OnScreen(X2 - 1, Y2) then Body := Body + CursorPosition(X2, Y2);
    Body := Body + #$E2#$94#$98;                  // U+2518
  end;
  for Y := Y1 + 1 to Y2 - 1 do
  begin
    Put(X1, Y, #$E2#$94#$82);                     // U+2502
    Put(X2, Y, #$E2#$94#$82);
  end;
  WriteRaw(Body);
end;

// Builds the whole frame in one buffer and emits it with a SINGLE write,
// wrapped in DECSET 2026 synchronized output. Over SSH this collapses the
// hundreds of tiny writes the per-run approach produced into one segment,
// which is what made moving/resizing windows feel laggy; the terminal also
// paints the frame atomically (no tearing). Terminals without 2026 ignore it.
procedure WideUpdateScreen(Force: Boolean);
var
  X, Y, Index, Nx: LongInt;
  VCell: TVideoCell;
  Eff: TEffCell;
  NeedMove: Boolean;
  OutCursorX, OutCursorY: Word;
  Body, Frame, CurSGR, LastSGR: AnsiString;
  ChangedCells, Runs, RHit, RMiss: LongInt;
begin
  if PassthroughActive then
  begin
    if DebugActive then
      DebugLog('video: update SUPPRESSED (passthrough owns the terminal)');
    Exit;   // the pane owns the terminal; FreeVision must not write over it
  end;
  if SuppressFlush then
  begin
    if DebugActive then
      DebugLog('video: flush suppressed (booting; buffer kept, no write)');
    Exit;   // booting: draw into the buffer only; one forced flush at the end
  end;
  if (VideoBuf = nil) or (OldVideoBuf = nil) or
     (ScreenWidth = 0) or (ScreenHeight = 0) then
    Exit;
  // Coalesce: if more input is already queued, this frame is about to be
  // superseded, so skip it and let the NEXT one emit the accumulated delta.
  // EffOld is only advanced by cells we actually emit, so skipping is safe.
  // The time bound keeps at least ~25 frames a second under continuous input.
  if InputPending and (GetTickCount64 - LastEmitTick < COALESCE_MS) then
  begin
    if DebugActive then
      DebugLog('video: frame coalesced (more input already waiting)');
    Exit;
  end;
  LastEmitTick := GetTickCount64;

  RichEnsureSize;
  Body := '';
  ChangedCells := 0;
  Runs := 0;
  RHit := 0;
  RMiss := 0;
  LastSGR := #0;   // impossible SGR: the first emitted cell always sets color
  for Y := 0 to ScreenHeight - 1 do
  begin
    NeedMove := True;   // start of a row is always a discontinuity
    for X := 0 to ScreenWidth - 1 do
    begin
      Index := Y * ScreenWidth + X;
      VCell := VideoCellAt(VideoBuf, Index);
      // effective cell: the rich pane cell when its oracle still stands in
      // VideoBuf (visible top cell), otherwise the CP437/16-color chrome
      if RichScreen[Index].Valid then
        if Word(VCell) = RichScreen[Index].Oracle then Inc(RHit) else Inc(RMiss);
      if RichScreen[Index].Valid and (Word(VCell) = RichScreen[Index].Oracle) then
      begin
        Eff.Skip := RichScreen[Index].Skip;
        Eff.Wide := RichScreen[Index].Wide;
        Eff.Rich := True;
        Eff.Glyph := RichScreen[Index].Glyph;
        Eff.Fg := RichScreen[Index].Fg;
        Eff.Bg := RichScreen[Index].Bg;
        Eff.Flags := RichScreen[Index].Flags;
        Eff.Attr := 0;
      end
      else
      begin
        Eff.Skip := False;
        Eff.Wide := False;
        Eff.Rich := False;
        Eff.Attr := Byte(VCell shr 8);
        Eff.Glyph := VgaChar(Byte(VCell and $FF));
        Eff.Fg := 0;
        Eff.Bg := 0;
        Eff.Flags := 0;
      end;
      // A two-column glyph and its continuation are two independent cells
      // here, and a pane edge can separate them: the lead's right half would
      // then land on the window frame (which the delta sees as unchanged and
      // never repaints), or a continuation would be left blank forever with no
      // lead to fill it. Only emit the pair when BOTH halves are ours.
      if Eff.Rich and Eff.Wide then
      begin
        Nx := Index + 1;
        if (X + 1 >= ScreenWidth) or (not RichScreen[Nx].Valid) or
           (not RichScreen[Nx].Skip) or
           (Word(VideoCellAt(VideoBuf, Nx)) <> RichScreen[Nx].Oracle) then
        begin
          Eff.Glyph := ' ';    // split pair: never overflow into a foreign cell
          Eff.Wide := False;
        end;
      end
      else if Eff.Rich and Eff.Skip then
      begin
        Nx := Index - 1;
        if (X = 0) or (not RichScreen[Nx].Valid) or
           (not RichScreen[Nx].Wide) or
           (Word(VideoCellAt(VideoBuf, Nx)) <> RichScreen[Nx].Oracle) then
        begin
          // orphan continuation: fall back to the chrome cell so the column is
          // painted instead of staying blank
          Eff.Skip := False;
          Eff.Rich := False;
          Eff.Wide := False;
          Eff.Attr := Byte(VCell shr 8);
          Eff.Glyph := VgaChar(Byte(VCell and $FF));
          Eff.Fg := 0;
          Eff.Bg := 0;
          Eff.Flags := 0;
        end;
      end;
      // Force is IGNORED on purpose: FreeVision asks for a forced update from
      // TGroup.Redraw, which TGroup.ChangeBounds triggers on every step of a
      // window drag -- that resent all ~10k cells per mouse move (measured:
      // 802 of 1639 frames, 9.9 MB of 10.2 MB, over SSH). The delta below is
      // always correct because this unit is the sole writer to the terminal;
      // when that stops being true the caller must say so via InvalidateFrame.
      if EffEqual(Eff, EffOld[Index]) then
      begin
        NeedMove := True;   // skipped a cell: next change needs a reposition
        Continue;
      end;
      EffOld[Index] := Eff;
      Inc(ChangedCells);
      if Eff.Skip then
      begin
        // wide-glyph continuation: the lead already advanced the cursor two
        // columns, so emit nothing and force the next change to reposition
        NeedMove := True;
        Continue;
      end;
      if NeedMove then
      begin
        Body := Body + CursorPosition(X, Y);
        NeedMove := False;
        Inc(Runs);
      end;
      if Eff.Rich then
        CurSGR := RichSGR(Eff.Fg, Eff.Bg, Eff.Flags)
      else
        CurSGR := AttrSequence(Eff.Attr);
      if CurSGR <> LastSGR then
      begin
        Body := Body + CurSGR;
        LastSGR := CurSGR;
      end;
      Body := Body + Eff.Glyph;
    end;
  end;

  if CursorX >= ScreenWidth then
    OutCursorX := ScreenWidth - 1
  else
    OutCursorX := CursorX;
  if CursorY >= ScreenHeight then
    OutCursorY := ScreenHeight - 1
  else
    OutCursorY := CursorY;

  if Body <> '' then
  begin
    // neutral SGR reset + autowrap off + body + cursor, in ONE write. Each
    // cell carries its own color now (chrome or rich), so the prefix must NOT
    // pin a default fg/bg. Optionally wrapped in DECSET 2026 synchronized
    // output (atomic present, no tearing) -- but that holds the frame until
    // ?2026l, and some terminals do not present it until the next input, so it
    // is OFF by default and enabled with SUPERTERM_SYNC=1.
    Frame := #27'[0m'#27'[?7l' + Body +
      CursorPosition(OutCursorX, OutCursorY);
    if UseSyncOutput then
      Frame := #27'[?2026h' + Frame + #27'[?2026l';
  end
  else
    // nothing changed: only keep the hardware cursor in sync (cheap)
    Frame := CursorPosition(OutCursorX, OutCursorY);
  WriteRaw(Frame);
  Move(VideoBuf^, OldVideoBuf^, VideoBufSize);
  // per-frame detail is FULL-mode only: a blinking cursor alone writes two
  // lines every half second, which buried everything worth reading
  if DebugFull then
    DebugLog(Format('video: update force=%d runs=%d changed_cells=%d ' +
      'of %d bytes=%d rich_hit=%d rich_miss=%d', [Ord(Force), Runs, ChangedCells,
      LongInt(ScreenWidth) * ScreenHeight, Length(Frame), RHit, RMiss]));
end;

procedure WideDoneVideo;
begin
  WriteRaw(#27'[?7h');
  if Assigned(SavedDriver.DoneDriver) then
    SavedDriver.DoneDriver;
  { FreeVision homes the cursor while tearing down the alternate screen.
    Restore the shell's cursor after that teardown, not before it. This is
    only the fallback: the RTL keyboard teardown still emits ESC[H after
    this point, so the authoritative repositioning happens at program exit
    via RestoreConsoleCursor (DSR-based), immune to that late homing. }
  WriteRaw(#27'[u'#27'8');
end;

procedure WideInitVideo;
begin
  { Keep the cursor position from the shell even on terminals that do not
    restore it reliably for private alternate-screen mode 1049. }
  WriteRaw(#27'7'#27'[s');
  if Assigned(SavedDriver.InitDriver) then
    SavedDriver.InitDriver;
end;

procedure InstallWideVideoOutput;
var
  Driver: TVideoDriver;
begin
  if DriverInstalled then
    Exit;
  UseSyncOutput := GetEnvironmentVariable('SUPERTERM_SYNC') = '1';
  GetVideoDriver(SavedDriver);
  Driver := SavedDriver;
  Driver.InitDriver := @WideInitVideo;
  Driver.UpdateScreen := @WideUpdateScreen;
  Driver.DoneDriver := @WideDoneVideo;
  if SetVideoDriver(Driver) then
    DriverInstalled := True;
end;

// Reads the real console cursor position via DSR (ESC[6n). Must be
// called BEFORE InitVideo. Reason: the ESC 7/ESC[s save done by
// WideInitVideo is not enough on real xterm terminals (Konsole), since
// the RTL driver emits ESC[H and then ?1049h, and in xterm ?1049h saves
// the cursor again -- already at 1;1 -- into the same slot as DECSC, so
// the final ESC[u ESC 8 restores the first line. Asking the terminal for
// the position and repositioning explicitly is immune to that slot overlap.
procedure CaptureConsoleCursor;
var
  OldTio, RawTio: TermIOS;
  Resp: AnsiString;
  ch: AnsiChar;
  n: longint;
  i, j, k: integer;
begin
  ConsoleRow := 0;
  ConsoleCol := 0;
  OldTio := Default(TermIOS);
  ch := #0;
  if IsATTY(StdInputHandle) <> 1 then
    Exit;
  if TCGetAttr(StdInputHandle, OldTio) <> 0 then
    Exit;
  RawTio := OldTio;
  RawTio.c_lflag := RawTio.c_lflag and (not (ICANON or ECHO));
  RawTio.c_cc[VMIN] := 0;
  RawTio.c_cc[VTIME] := 2; // 0.2s maximum wait per read
  if TCSetAttr(StdInputHandle, TCSANOW, RawTio) <> 0 then
    Exit;
  WriteRaw(#27'[6n');
  Resp := '';
  repeat
    n := FileRead(StdInputHandle, ch, 1);
    if n <> 1 then
      Break;
    Resp := Resp + ch;
  until (ch = 'R') or (Length(Resp) >= 32);
  TCSetAttr(StdInputHandle, TCSANOW, OldTio);
  // response: ESC [ row ; column R (ignore typeahead before the last ESC)
  i := Length(Resp);
  while (i > 0) and (Resp[i] <> #27) do
    Dec(i);
  if i = 0 then
    Exit;
  j := i;
  while (j <= Length(Resp)) and (Resp[j] <> ';') do
    Inc(j);
  k := j;
  while (k <= Length(Resp)) and (Resp[k] <> 'R') do
    Inc(k);
  if (j > Length(Resp)) or (k > Length(Resp)) then
    Exit;
  ConsoleRow := StrToIntDef(Copy(Resp, i + 2, j - i - 2), 0);
  ConsoleCol := StrToIntDef(Copy(Resp, j + 1, k - j - 1), 0);
end;

// Turns off everything that makes the terminal send us bytes, and throws
// away whatever it sent before we got here.
//
// The RTL's mouse driver enables and disables ONLY ?1003 and ?1006 (see
// mouse.pp, SysInitMouse/SysDoneMouse). superterm also enables ?1000 and
// ?1002 by hand when it reclaims the screen from a maximised pane, and the
// RTL knows nothing about those: after teardown they stay ON, so the
// terminal keeps reporting every mouse movement to whatever runs next --
// the shell, which prints the reports as line noise at its prompt.
//
// Disabling is not quite enough on its own either: reports the terminal
// already sent are sitting in the tty input buffer and would be read by the
// shell as typed characters. Flush them.
function IsLinuxConsole: boolean;
var
  T: string;
begin
  T := LowerCase(GetEnvironmentVariable('TERM'));
  Result := (T = 'linux') or (Copy(T, 1, 6) = 'linux-');
end;

procedure ReleaseConsoleInput;
begin
  // order matters: SGR last, so the tracking modes are already off and
  // nothing new can arrive in either encoding
  WriteRaw(#27'[?1003l'#27'[?1002l'#27'[?1000l'#27'[?1015l'#27'[?1006l' +
    #27'[?2004l'#27'[?9l');
  if IsATTY(StdInputHandle) = 1 then
    TCFlush(StdInputHandle, TCIFLUSH);
end;

// Puts the console cursor back where it was at startup. Call at the
// very end (after App.Done), because the RTL video and keyboard
// drivers emit ESC[H during teardown. If the terminal did not answer
// the DSR, WideDoneVideo's ESC[u ESC 8 fallback remains.
procedure RestoreConsoleCursor;
begin
  if (ConsoleRow > 0) and (ConsoleCol > 0) then
    WriteRaw(#27'[' + IntToStr(ConsoleRow) + ';' + IntToStr(ConsoleCol) + 'H');
end;

end.
