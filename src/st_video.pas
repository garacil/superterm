unit st_video;

{$mode objfpc}{$H+}

interface

procedure InstallWideVideoOutput;
procedure CaptureConsoleCursor;
procedure RestoreConsoleCursor;

// Passthrough: while active the FreeVision screen driver stays silent and the
// client writes a pane's raw PTY bytes straight to the host terminal, so a
// full-fidelity TUI (truecolor, emoji, wide glyphs) renders untouched.
procedure PassthroughRaw(const Data; ALen: LongInt);
// Raw escape/string writer to the host terminal (respects OutputFailed).
procedure WriteRaw(const S: AnsiString);

// Rich overlay (the "option B" renderer). A pane registers each of its cells
// -- the full UTF-8 glyph plus the EXACT color -- at its GLOBAL screen
// position, passing the VideoBuf word it wrote there as an oracle. Then
// WideUpdateScreen emits the rich cell (truecolor + UTF-8) whenever VideoBuf
// still holds that oracle (i.e. the pane cell is the visible top one), and
// falls back to the CP437/16-color chrome for everything else (window frames,
// menu, status line, cells covered by another window). This keeps FreeVision
// untouched: the grid is still drawn (it is the visibility oracle), but the
// pane area is presented richly. Colors: $01RRGGBB = truecolor;
// $02000000 or index (0..15, 8..15 = bright) = the 16-color fallback; 0 = the
// terminal default. Flags: 1 = bold, 2 = underline, 4 = reverse. ASkip marks
// a wide-glyph continuation cell (its lead already emitted the 2-wide glyph,
// so nothing is written here).
procedure RichSetCell(AX, AY: LongInt; const AGlyph: AnsiString;
  AFg, ABg: LongWord; AFlags: Byte; AOracle: Word; ASkip: Boolean);
// Drop the whole overlay (nothing renders rich until panes repopulate it).
procedure RichInvalidate;

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
  SysUtils, termio, Video, st_debug;

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
    Glyph: string[7];
    Attr: Byte;         // chrome path (VGA attribute byte)
    Fg, Bg: LongWord;   // rich path
    Flags: Byte;
  end;

var
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
  AFg, ABg: LongWord; AFlags: Byte; AOracle: Word; ASkip: Boolean);
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
  end;
  case ABg shr 24 of
    1: Result := Result + ';48;2;' + IntToStr((ABg shr 16) and $FF) + ';' +
         IntToStr((ABg shr 8) and $FF) + ';' + IntToStr(ABg and $FF);
    2: begin
         n := ABg and $0F;
         if n < 8 then Result := Result + ';' + IntToStr(40 + LongInt(n))
         else Result := Result + ';' + IntToStr(100 + (LongInt(n) - 8));
       end;
  end;
  Result := Result + 'm';
end;

function EffEqual(const A, B: TEffCell): Boolean;
begin
  if A.Skip or B.Skip then Exit(A.Skip and B.Skip);
  if A.Rich <> B.Rich then Exit(False);
  if A.Glyph <> B.Glyph then Exit(False);
  if A.Rich then
    Result := (A.Fg = B.Fg) and (A.Bg = B.Bg) and (A.Flags = B.Flags)
  else
    Result := (A.Attr = B.Attr);
end;

// Builds the whole frame in one buffer and emits it with a SINGLE write,
// wrapped in DECSET 2026 synchronized output. Over SSH this collapses the
// hundreds of tiny writes the per-run approach produced into one segment,
// which is what made moving/resizing windows feel laggy; the terminal also
// paints the frame atomically (no tearing). Terminals without 2026 ignore it.
procedure WideUpdateScreen(Force: Boolean);
var
  X, Y, Index: LongInt;
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
        Eff.Rich := False;
        Eff.Attr := Byte(VCell shr 8);
        Eff.Glyph := VgaChar(Byte(VCell and $FF));
        Eff.Fg := 0;
        Eff.Bg := 0;
        Eff.Flags := 0;
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
  if DebugActive then
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
