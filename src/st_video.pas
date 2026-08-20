unit st_video;

{$mode objfpc}{$H+}

interface

procedure InstallWideVideoOutput;
procedure CaptureConsoleCursor;
procedure RestoreConsoleCursor;

implementation

uses
  SysUtils, termio, Video;

var
  SavedDriver: TVideoDriver;
  DriverInstalled: Boolean;
  OutputFailed: Boolean;
  ConsoleRow, ConsoleCol: Integer; // posicion del cursor al arrancar (0 = desconocida)

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
    206: Result := '╬'; // CP437 canonico (0xCE es la cruz doble)
    207: Result := '╧';
    209: Result := '╤';
    217: Result := '┘';
    218: Result := '┌';
    219: Result := '█';
    220: Result := '▄';
    223: Result := '▀';
    254: Result := '■';
  else
    Result := '?';
end;
end;

function CursorPosition(AX, AY: Word): AnsiString;
begin
  Result := #27'[' + IntToStr(AY + 1) + ';' + IntToStr(AX + 1) + 'H';
end;

procedure WriteCells(AStart, AStop: LongInt);
var
  I: LongInt;
  Text: AnsiString;
begin
  Text := '';
  for I := AStart to AStop - 1 do
  begin
    Text := Text + VgaChar(Byte(VideoCellAt(VideoBuf, I)));
    if Length(Text) >= 512 then
    begin
      WriteRaw(Text);
      Text := '';
    end;
  end;
  WriteRaw(Text);
end;

procedure WideUpdateScreen(Force: Boolean);
var
  X, Y, Index, RunStart, RunStop: LongInt;
  Attr: Byte;
  OutCursorX, OutCursorY: Word;
begin
  if (VideoBuf = nil) or (OldVideoBuf = nil) or
     (ScreenWidth = 0) or (ScreenHeight = 0) then
    Exit;

  WriteRaw(#27'[0;40;37m'#27'[?7l');
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
      WriteRaw(CursorPosition(RunStart, Y));
      WriteRaw(AttrSequence(Attr));
      WriteCells(Y * ScreenWidth + RunStart,
        Y * ScreenWidth + RunStop);
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
  WriteRaw(CursorPosition(OutCursorX, OutCursorY));
  Move(VideoBuf^, OldVideoBuf^, VideoBufSize);
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

// Lee la posicion real del cursor de la consola via DSR (ESC[6n). Debe
// llamarse ANTES de InitVideo. Motivo: el guardado con ESC 7/ESC[s de
// WideInitVideo no basta en terminales xterm reales (Konsole), porque el
// driver RTL emite ESC[H y despues ?1049h, y en xterm ?1049h vuelve a
// guardar el cursor -- ya en 1;1 -- en el mismo slot que DECSC, asi que
// el ESC[u ESC 8 final restaura la primera linea. Preguntar la posicion
// al terminal y recolocar explicitamente es inmune a ese solape de slots.
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
  RawTio.c_cc[VTIME] := 2; // 0.2s de espera maxima por lectura
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
  // respuesta: ESC [ fila ; columna R (ignorar typeahead previo al ultimo ESC)
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

// Recoloca el cursor de la consola donde estaba al arrancar. Llamar al
// final del todo (tras App.Done), porque los drivers RTL de video y
// teclado emiten ESC[H durante el desmontaje. Si el terminal no contesto
// al DSR queda el respaldo ESC[u ESC 8 de WideDoneVideo.
procedure RestoreConsoleCursor;
begin
  if (ConsoleRow > 0) and (ConsoleCol > 0) then
    WriteRaw(#27'[' + IntToStr(ConsoleRow) + ';' + IntToStr(ConsoleCol) + 'H');
end;

end.
