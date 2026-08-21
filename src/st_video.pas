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

// Builds the whole frame in one buffer and emits it with a SINGLE write,
// wrapped in DECSET 2026 synchronized output. Over SSH this collapses the
// hundreds of tiny writes the per-run approach produced into one segment,
// which is what made moving/resizing windows feel laggy; the terminal also
// paints the frame atomically (no tearing). Terminals without 2026 ignore it.
procedure WideUpdateScreen(Force: Boolean);
var
  X, Y, Index, RunStart, RunStop: LongInt;
  Attr: Byte;
  OutCursorX, OutCursorY: Word;
  Body, Frame: AnsiString;
  ChangedCells, Runs: LongInt;
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

  Body := '';
  ChangedCells := 0;
  Runs := 0;
  for Y := 0 to ScreenHeight - 1 do
  begin
    X := 0;
    while X < ScreenWidth do
    begin
      Index := Y * ScreenWidth + X;
      if (not Force) and
         (VideoCellAt(VideoBuf, Index) = VideoCellAt(OldVideoBuf, Index)) then
      begin
        Inc(X);
        Continue;
      end;

      RunStart := X;
      Attr := Byte(VideoCellAt(VideoBuf, Index) shr 8);
      Inc(X);
      while X < ScreenWidth do
      begin
        Index := Y * ScreenWidth + X;
        if (not Force) and
           (VideoCellAt(VideoBuf, Index) = VideoCellAt(OldVideoBuf, Index)) then
          Break;
        if Byte(VideoCellAt(VideoBuf, Index) shr 8) <> Attr then
          Break;
        Inc(X);
      end;
      RunStop := X;
      Inc(Runs);
      Inc(ChangedCells, RunStop - RunStart);
      Body := Body + CursorPosition(RunStart, Y) + AttrSequence(Attr) +
        CellsToStr(Y * ScreenWidth + RunStart, Y * ScreenWidth + RunStop);
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

  if (Body <> '') or Force then
    // synchronized begin + SGR reset + autowrap off + body + cursor + sync end
    Frame := #27'[?2026h'#27'[0;40;37m'#27'[?7l' + Body +
      CursorPosition(OutCursorX, OutCursorY) + #27'[?2026l'
  else
    // nothing changed: only keep the hardware cursor in sync (cheap)
    Frame := CursorPosition(OutCursorX, OutCursorY);
  WriteRaw(Frame);
  Move(VideoBuf^, OldVideoBuf^, VideoBufSize);
  if DebugActive then
    DebugLog(Format('video: update force=%d runs=%d changed_cells=%d ' +
      'of %d bytes=%d', [Ord(Force), Runs, ChangedCells,
      LongInt(ScreenWidth) * ScreenHeight, Length(Frame)]));
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
