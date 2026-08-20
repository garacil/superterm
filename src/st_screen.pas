(*
  Autor: Germán Luis Aracil Boned
  Proyecto: superterm - terminal con autologin, splits y sesiones
  Unidad: st_screen - pantalla virtual + parser VT100/ANSI
*)

unit st_screen;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, Classes;

const
  MAX_SCREEN_SCROLLBACK = 100000;
  // bits de atributo
  A_BOLD = $0100;
  A_UNDER = $0200;
  A_REVERSE = $0400;
  A_FGDEF = $0800;
  A_BGDEF = $1000;

type
  TCell = record
    Txt: array[0..7] of AnsiChar;
    Len: byte;
    Attr: word;
    Cont: boolean; // celda de continuacion de caracter ancho
  end;

  TRow = array of TCell;
  TGridArray = array of TRow;
  TParserState = (psGround, psEsc, psCsi, psOsc, psCharset, psOscEsc);

  TScreen = class
  private
    FGrid: TGridArray;
    FAltGrid: TGridArray;   // alt screen buffer
    FUsingAlt: boolean;
    FPendingWrap: boolean;
    // scrollback
    FSBRing: array of TRow;
    FSBCount: integer;
    FSBHead: integer;
    FViewTop: integer;         // 0 = vivo; >0 = lineas hacia atras
    // parser
    FPState: TParserState;
    FPParams: array[0..15] of integer;
    FPCount: integer;
    FPPriv: boolean;
    FUtfBuf: array[0..7] of byte;
    FUtfLen: byte;
    FUtfNeed: byte;
    FOscBuf: RawByteString;
    FSaveX, FSaveY: integer;
    FInterm: AnsiChar;      // byte intermedio CSI (ej. ' ' de DECSCUSR)
    FAutoWrap: boolean;     // DECAWM ?7 (default on)
    procedure ClearCell(var C: TCell);
    procedure ResizeGrid(var AGrid: TGridArray; OldWidth, OldHeight,
      NewWidth, NewHeight: integer);
    procedure CopyGrid(const Source: TGridArray; out Target: TGridArray);
    procedure BlankRow(y: integer; AAttr: word);
    procedure PutRawChar(const b: array of AnsiChar; alen: byte; AAttr: word);
    procedure ScrollUp(n: integer);
    procedure ScrollDown(n: integer);
    procedure LineFeed;
    procedure PutCharByte(b: byte);
    procedure DoCSI(final: AnsiChar);
    procedure DispatchEsc(c: AnsiChar);
    function GetParam(i, def: integer): integer;
    procedure SetCellStr(x, y: integer; const S: RawByteString; AAttr: word);
    function CellWidth(const S: RawByteString): integer;
    procedure EraseRange(x1, y1, x2, y2: integer; AAttr: word);
    procedure PushScrollRow(const R: TRow);
  public
    Width, Height: integer;
    CursorX, CursorY: integer;
    ScrollTop, ScrollBot: integer;
    CursorVisible: boolean;
    CursorStyle: integer;   // DECSCUSR: 0 def | 1/2 block | 3/4 under | 5/6 bar
    Attr: word; // attr actual del stream
    Dirty: boolean;
    MaxScrollBack: integer;    // capacidad del historial (0 = sin historial)
    constructor Create(AWidth, AHeight: integer; AMaxScrollBack: integer = 10000);
    destructor Destroy; override;
    procedure Resize(AWidth, AHeight: integer);
    procedure WriteBytes(const Buf; Count: integer);
    procedure ResetSoft;
    function ViewOffset: integer;
    procedure ScrollViewport(ADelta: integer);  // + atras, - adelante
    function DisplayRow(y: integer): TRow;
    procedure SaveToStream(Stream: TStream);
    function LoadFromStream(Stream: TStream): boolean;
    property Grid: TGridArray read FGrid;
  end;

implementation

constructor TScreen.Create(AWidth, AHeight: integer; AMaxScrollBack: integer);
begin
  inherited Create;
  Width := AWidth;
  Height := AHeight;
  CursorX := 0;
  CursorY := 0;
  ScrollTop := 0;
  ScrollBot := Height - 1;
  CursorVisible := True;
  CursorStyle := 0;
  Attr := A_FGDEF or A_BGDEF;
  Dirty := True;
  FUsingAlt := False;
  FAutoWrap := True;
  FInterm := #0;
  MaxScrollBack := AMaxScrollBack;
  if MaxScrollBack < 0 then
    MaxScrollBack := 0;
  if MaxScrollBack > MAX_SCREEN_SCROLLBACK then
    MaxScrollBack := MAX_SCREEN_SCROLLBACK;
  FSBCount := 0;
  FSBHead := 0;
  FViewTop := 0;
  if MaxScrollBack > 0 then
    SetLength(FSBRing, MaxScrollBack);
  Resize(AWidth, AHeight);
end;

destructor TScreen.Destroy;
begin
  inherited;
end;

procedure TScreen.ClearCell(var C: TCell);
begin
  FillChar(C, SizeOf(C), 0);
  C.Attr := A_FGDEF or A_BGDEF;
end;

procedure TScreen.ResizeGrid(var AGrid: TGridArray; OldWidth, OldHeight,
  NewWidth, NewHeight: integer);
var
  NewGrid: TGridArray;
  x, y, CopyWidth, CopyHeight: integer;
begin
  if AGrid = nil then
    Exit;
  SetLength(NewGrid, NewHeight);
  for y := 0 to NewHeight - 1 do
  begin
    SetLength(NewGrid[y], NewWidth);
    for x := 0 to NewWidth - 1 do
      ClearCell(NewGrid[y][x]);
  end;
  CopyWidth := Min(OldWidth, NewWidth);
  CopyHeight := Min(OldHeight, NewHeight);
  for y := 0 to CopyHeight - 1 do
    for x := 0 to CopyWidth - 1 do
      NewGrid[y][x] := AGrid[y][x];
  AGrid := NewGrid;
end;

procedure TScreen.CopyGrid(const Source: TGridArray; out Target: TGridArray);
var
  y: integer;
begin
  SetLength(Target, Length(Source));
  for y := 0 to High(Source) do
    Target[y] := Copy(Source[y], 0, Length(Source[y]));
end;

procedure TScreen.BlankRow(y: integer; AAttr: word);
var
  x: integer;
begin
  if (y < 0) or (y >= Height) then
    Exit;
  for x := 0 to Width - 1 do
  begin
    ClearCell(FGrid[y][x]);
    FGrid[y][x].Attr := AAttr;
  end;
end;

procedure TScreen.Resize(AWidth, AHeight: integer);
var
  NewGrid: TGridArray;
  x, y, cw, ch, Lost, SrcY, OldWidth, OldHeight: integer;
begin
  cw := AWidth;
  ch := AHeight;
  if cw < 1 then cw := 1;
  if ch < 1 then ch := 1;
  Lost := 0;
  if (cw = Width) and (ch = Height) and (FGrid <> nil) then
    Exit;
  OldWidth := Width;
  OldHeight := Height;
  SetLength(NewGrid, ch);
  for y := 0 to ch - 1 do
  begin
    SetLength(NewGrid[y], cw);
    for x := 0 to cw - 1 do
      ClearCell(NewGrid[y][x]);
  end;
  if FGrid <> nil then
  begin
    // al encoger: las lineas superiores que se pierden van al historial
    Lost := OldHeight - ch;
    if Lost < 0 then
      Lost := 0;
    if Lost > 0 then
      for y := 0 to Lost - 1 do
        PushScrollRow(Copy(FGrid[y], 0, OldWidth));
    for y := 0 to ch - 1 do
    begin
      if ch < OldHeight then
        SrcY := y + Lost
      else
        SrcY := y;
      if SrcY < OldHeight then
        for x := 0 to Min(cw, OldWidth) - 1 do
          NewGrid[y][x] := FGrid[SrcY][x];
    end;
  end;
  if FAltGrid <> nil then
    ResizeGrid(FAltGrid, OldWidth, OldHeight, cw, ch);
  FGrid := NewGrid;
  Width := cw;
  Height := ch;
  if CursorX >= Width then CursorX := Width - 1;
  Dec(CursorY, Lost);
  if CursorY >= Height then CursorY := Height - 1;
  if CursorY < 0 then CursorY := 0;
  ScrollTop := 0;
  ScrollBot := Height - 1;
  FPendingWrap := False;
  if FViewTop > FSBCount then
    FViewTop := FSBCount;
  Dirty := True;
end;

function TScreen.ViewOffset: integer;
begin
  Result := FViewTop;
end;

procedure TScreen.ScrollViewport(ADelta: integer);
begin
  if FSBCount <= 0 then
  begin
    FViewTop := 0;
    Exit;
  end;
  FViewTop := EnsureRange(FViewTop + ADelta, 0, FSBCount);
  Dirty := True;
end;

function TScreen.DisplayRow(y: integer): TRow;
var
  k, a, slot: integer;
begin
  Result := nil;
  if (y < 0) or (y >= Height) then
    Exit;
  if FViewTop > FSBCount then
    k := FSBCount
  else
    k := FViewTop;
  a := FSBCount - k + y;
  if a < FSBCount then
  begin
    slot := (FSBHead - FSBCount + a + MaxScrollBack) mod MaxScrollBack;
    Result := Copy(FSBRing[slot], 0, MaxInt);
  end
  else
    Result := Copy(FGrid[a - FSBCount], 0, MaxInt);
end;

procedure WriteScreenString(Stream: TStream; const S: RawByteString);
var
  L: Longint;
begin
  L := Length(S);
  Stream.WriteBuffer(L, SizeOf(L));
  if L > 0 then
    Stream.WriteBuffer(S[1], L);
end;

function ReadScreenString(Stream: TStream; out S: RawByteString): boolean;
var
  L: Longint;
begin
  Result := False;
  S := '';
  Stream.ReadBuffer(L, SizeOf(L));
  if (L < 0) or (L > 1024 * 1024) then
    Exit;
  SetLength(S, L);
  if L > 0 then
    Stream.ReadBuffer(S[1], L);
  Result := True;
end;

procedure SaveScreenGrid(Stream: TStream; const G: TGridArray);
var
  Y, X, N: Longint;
begin
  N := Length(G);
  Stream.WriteBuffer(N, SizeOf(N));
  for Y := 0 to N - 1 do
  begin
    N := Length(G[Y]);
    Stream.WriteBuffer(N, SizeOf(N));
    for X := 0 to N - 1 do
      Stream.WriteBuffer(G[Y][X], SizeOf(TCell));
  end;
end;

function LoadScreenGrid(Stream: TStream; out G: TGridArray): boolean;
var
  Y, X, Rows, Cols: Longint;
begin
  Result := False;
  G := nil;
  Stream.ReadBuffer(Rows, SizeOf(Rows));
  if (Rows < 0) or (Rows > 4096) then
    Exit;
  SetLength(G, Rows);
  for Y := 0 to Rows - 1 do
  begin
    Stream.ReadBuffer(Cols, SizeOf(Cols));
    if (Cols < 0) or (Cols > 4096) then
      Exit;
    SetLength(G[Y], Cols);
    for X := 0 to Cols - 1 do
      Stream.ReadBuffer(G[Y][X], SizeOf(TCell));
  end;
  Result := True;
end;

procedure TScreen.SaveToStream(Stream: TStream);
var
  I, Slot, X, N: Longint;
  B: byte;
begin
  Stream.WriteBuffer(Width, SizeOf(Width));
  Stream.WriteBuffer(Height, SizeOf(Height));
  Stream.WriteBuffer(CursorX, SizeOf(CursorX));
  Stream.WriteBuffer(CursorY, SizeOf(CursorY));
  Stream.WriteBuffer(ScrollTop, SizeOf(ScrollTop));
  Stream.WriteBuffer(ScrollBot, SizeOf(ScrollBot));
  B := Ord(CursorVisible); Stream.WriteBuffer(B, SizeOf(B));
  Stream.WriteBuffer(CursorStyle, SizeOf(CursorStyle));
  Stream.WriteBuffer(Attr, SizeOf(Attr));
  B := Ord(Dirty); Stream.WriteBuffer(B, SizeOf(B));
  Stream.WriteBuffer(MaxScrollBack, SizeOf(MaxScrollBack));
  B := Ord(FUsingAlt); Stream.WriteBuffer(B, SizeOf(B));
  B := Ord(FPendingWrap); Stream.WriteBuffer(B, SizeOf(B));
  N := Ord(FPState); Stream.WriteBuffer(N, SizeOf(N));
  Stream.WriteBuffer(FPParams, SizeOf(FPParams));
  Stream.WriteBuffer(FPCount, SizeOf(FPCount));
  B := Ord(FPPriv); Stream.WriteBuffer(B, SizeOf(B));
  Stream.WriteBuffer(FUtfBuf, SizeOf(FUtfBuf));
  Stream.WriteBuffer(FUtfLen, SizeOf(FUtfLen));
  Stream.WriteBuffer(FUtfNeed, SizeOf(FUtfNeed));
  WriteScreenString(Stream, FOscBuf);
  Stream.WriteBuffer(FSaveX, SizeOf(FSaveX));
  Stream.WriteBuffer(FSaveY, SizeOf(FSaveY));
  Stream.WriteBuffer(FInterm, SizeOf(FInterm));
  B := Ord(FAutoWrap); Stream.WriteBuffer(B, SizeOf(B));
  SaveScreenGrid(Stream, FGrid);
  SaveScreenGrid(Stream, FAltGrid);

  N := FSBCount;
  Stream.WriteBuffer(N, SizeOf(N));
  Stream.WriteBuffer(FViewTop, SizeOf(FViewTop));
  if (MaxScrollBack > 0) and (FSBCount > 0) then
    for I := 0 to FSBCount - 1 do
    begin
      Slot := (FSBHead - FSBCount + I + MaxScrollBack) mod MaxScrollBack;
      N := Length(FSBRing[Slot]);
      Stream.WriteBuffer(N, SizeOf(N));
      if N > 0 then
        for X := 0 to N - 1 do
          Stream.WriteBuffer(FSBRing[(FSBHead - FSBCount + I + MaxScrollBack) mod MaxScrollBack][X],
            SizeOf(TCell));
    end;
end;

function TScreen.LoadFromStream(Stream: TStream): boolean;
var
  I, X, N, Cols, MaxSB, StateValue: Longint;
  B: byte;
  Row: TRow;
begin
  Result := False;
  try
    Stream.ReadBuffer(Width, SizeOf(Width));
    Stream.ReadBuffer(Height, SizeOf(Height));
    if (Width < 1) or (Width > 4096) or (Height < 1) or (Height > 4096) then
      Exit;
    Stream.ReadBuffer(CursorX, SizeOf(CursorX));
    Stream.ReadBuffer(CursorY, SizeOf(CursorY));
    Stream.ReadBuffer(ScrollTop, SizeOf(ScrollTop));
    Stream.ReadBuffer(ScrollBot, SizeOf(ScrollBot));
    Stream.ReadBuffer(B, SizeOf(B)); CursorVisible := B <> 0;
    Stream.ReadBuffer(CursorStyle, SizeOf(CursorStyle));
    Stream.ReadBuffer(Attr, SizeOf(Attr));
    Stream.ReadBuffer(B, SizeOf(B)); Dirty := B <> 0;
    Stream.ReadBuffer(MaxSB, SizeOf(MaxSB));
    if (MaxSB < 0) or (MaxSB > MAX_SCREEN_SCROLLBACK) then
      Exit;
    MaxScrollBack := MaxSB;
    Stream.ReadBuffer(B, SizeOf(B)); FUsingAlt := B <> 0;
    Stream.ReadBuffer(B, SizeOf(B)); FPendingWrap := B <> 0;
    Stream.ReadBuffer(StateValue, SizeOf(StateValue));
    if (StateValue < Ord(Low(FPState))) or
       (StateValue > Ord(High(FPState))) then
      Exit;
    FPState := TParserState(StateValue);
    Stream.ReadBuffer(FPParams, SizeOf(FPParams));
    Stream.ReadBuffer(FPCount, SizeOf(FPCount));
    Stream.ReadBuffer(B, SizeOf(B)); FPPriv := B <> 0;
    Stream.ReadBuffer(FUtfBuf, SizeOf(FUtfBuf));
    Stream.ReadBuffer(FUtfLen, SizeOf(FUtfLen));
    Stream.ReadBuffer(FUtfNeed, SizeOf(FUtfNeed));
    if not ReadScreenString(Stream, FOscBuf) then
      Exit;
    Stream.ReadBuffer(FSaveX, SizeOf(FSaveX));
    Stream.ReadBuffer(FSaveY, SizeOf(FSaveY));
    Stream.ReadBuffer(FInterm, SizeOf(FInterm));
    Stream.ReadBuffer(B, SizeOf(B)); FAutoWrap := B <> 0;
    if not LoadScreenGrid(Stream, FGrid) then
      Exit;
    if (Length(FGrid) <> Height) then
      Exit;
    for I := 0 to Height - 1 do
      if Length(FGrid[I]) <> Width then
        Exit;
    if not LoadScreenGrid(Stream, FAltGrid) then
      Exit;
    if (Length(FAltGrid) <> 0) and (Length(FAltGrid) <> Height) then
      Exit;
    if Length(FAltGrid) = Height then
      for I := 0 to Height - 1 do
        if Length(FAltGrid[I]) <> Width then
          Exit;

    Stream.ReadBuffer(N, SizeOf(N));
    if (N < 0) or (N > MaxScrollBack) then
      Exit;
    FSBCount := N;
    Stream.ReadBuffer(FViewTop, SizeOf(FViewTop));
    if FViewTop < 0 then FViewTop := 0;
    if FViewTop > FSBCount then FViewTop := FSBCount;
    FSBHead := 0;
    SetLength(FSBRing, MaxScrollBack);
    for I := 0 to FSBCount - 1 do
    begin
      Stream.ReadBuffer(Cols, SizeOf(Cols));
      if (Cols < 0) or (Cols > 4096) then
        Exit;
      SetLength(Row, Cols);
      for X := 0 to Cols - 1 do
        Stream.ReadBuffer(Row[X], SizeOf(TCell));
      FSBRing[I] := Row;
    end;
    if MaxScrollBack > 0 then
      FSBHead := FSBCount mod MaxScrollBack;
    Result := True;
  except
    Result := False;
  end;
end;

function TScreen.CellWidth(const S: RawByteString): integer;
var
  b: byte;
  cp: cardinal;
begin
  Result := 1;
  if Length(S) = 0 then
    Exit;
  b := byte(S[1]);
  if b < $80 then
    Exit;
  if b < $C0 then
    Exit;
  if b < $E0 then
  begin
    if Length(S) < 2 then Exit;
    cp := ((b and $1F) shl 6) or (byte(S[2]) and $3F);
  end
  else if b < $F0 then
  begin
    if Length(S) < 3 then Exit;
    cp := ((b and $0F) shl 12) or ((byte(S[2]) and $3F) shl 6) or (byte(S[3]) and $3F);
  end
  else
  begin
    if Length(S) < 4 then Exit;
    cp := ((b and $07) shl 18) or ((byte(S[2]) and $3F) shl 12) or
      ((byte(S[3]) and $3F) shl 6) or (byte(S[4]) and $3F);
  end;
  // rangos CJK/ancho completo aproximados
  if ((cp >= $1100) and (cp <= $115F)) or
     ((cp >= $2E80) and (cp <= $A4CF)) or
     ((cp >= $AC00) and (cp <= $D7A3)) or
     ((cp >= $F900) and (cp <= $FAFF)) or
     ((cp >= $FE30) and (cp <= $FE6F)) or
     ((cp >= $FF00) and (cp <= $FF60)) or
     ((cp >= $FFE0) and (cp <= $FFE6)) or
     ((cp >= $20000) and (cp <= $3FFFD)) then
    Result := 2;
end;

procedure TScreen.SetCellStr(x, y: integer; const S: RawByteString; AAttr: word);
var
  i: integer;
begin
  if (x < 0) or (x >= Width) or (y < 0) or (y >= Height) then
    Exit;
  ClearCell(FGrid[y][x]);
  FGrid[y][x].Len := Min(Length(S), 7);
  for i := 1 to FGrid[y][x].Len do
    FGrid[y][x].Txt[i - 1] := S[i];
  FGrid[y][x].Attr := AAttr;
  if CellWidth(S) = 2 then
  begin
    FGrid[y][x].Cont := False;
    if x + 1 < Width then
    begin
      ClearCell(FGrid[y][x + 1]);
      FGrid[y][x + 1].Cont := True;
      FGrid[y][x + 1].Attr := AAttr;
    end;
  end;
end;

procedure TScreen.PushScrollRow(const R: TRow);
begin
  if MaxScrollBack <= 0 then
    Exit;
  FSBRing[FSBHead] := R;
  FSBHead := (FSBHead + 1) mod MaxScrollBack;
  if FSBCount < MaxScrollBack then
    Inc(FSBCount);
end;

procedure TScreen.ScrollUp(n: integer);
var
  y: integer;
begin
  if n > Height then
    n := Height;
  if n < 1 then
    Exit;
  while n > 0 do
  begin
    Dec(n);
    if ScrollTop = 0 then
      PushScrollRow(Copy(FGrid[0], 0, Width));
    for y := ScrollTop to ScrollBot - 1 do
      FGrid[y] := Copy(FGrid[y + 1], 0, Width);
    BlankRow(ScrollBot, Attr);
  end;
  Dirty := True;
end;

procedure TScreen.ScrollDown(n: integer);
var
  y: integer;
begin
  if n > Height then
    n := Height;
  if n < 1 then
    Exit;
  while n > 0 do
  begin
    Dec(n);
    for y := ScrollBot downto ScrollTop + 1 do
      FGrid[y] := Copy(FGrid[y - 1], 0, Width);
    BlankRow(ScrollTop, Attr);
  end;
  Dirty := True;
end;

procedure TScreen.LineFeed;
begin
  if CursorY = ScrollBot then
    ScrollUp(1)
  else if CursorY < Height - 1 then
    Inc(CursorY);
  FPendingWrap := False;
  Dirty := True;
end;

procedure TScreen.PutRawChar(const b: array of AnsiChar; alen: byte; AAttr: word);
var
  S: RawByteString;
  i: integer;
  w: integer;
begin
  if FPendingWrap then
  begin
    CursorX := 0;
    LineFeed;
  end;
  SetLength(S, alen);
  for i := 0 to alen - 1 do
    S[i + 1] := b[i];
  w := CellWidth(S);
  if CursorX + w > Width then
  begin
    if not FAutoWrap then
    begin
      CursorX := Width - w;
      if CursorX < 0 then CursorX := 0;
    end
    else
    begin
      CursorX := 0;
      LineFeed;
    end;
  end;
  SetCellStr(CursorX, CursorY, S, AAttr);
  Inc(CursorX, w);
  if CursorX >= Width then
  begin
    CursorX := Width - 1;
    if FAutoWrap then
      FPendingWrap := True
    else
      FPendingWrap := False;
  end
  else
    FPendingWrap := False;
  Dirty := True;
end;

procedure TScreen.PutCharByte(b: byte);
var
  arr: array[0..7] of AnsiChar;
  i: integer;
begin
  FillChar(arr, SizeOf(arr), 0);
  if FUtfLen = 0 then
  begin
    if b < $80 then
    begin
      arr[0] := AnsiChar(b);
      PutRawChar(arr, 1, Attr);
      Exit;
    end;
    FUtfBuf[0] := b;
    FUtfLen := 1;
    if b < $C0 then FUtfNeed := 1
    else if b < $E0 then FUtfNeed := 2
    else if b < $F0 then FUtfNeed := 3
    else FUtfNeed := 4;
    Exit;
  end;
  if (b and $C0) = $80 then
  begin
    if FUtfLen < 8 then
    begin
      FUtfBuf[FUtfLen] := b;
      Inc(FUtfLen);
    end;
  end
  else
  begin
    // secuencia rota: emitir tal cual y reprocesar
    for i := 0 to FUtfLen - 1 do
    begin
      arr[0] := AnsiChar(FUtfBuf[i]);
      PutRawChar(arr, 1, Attr);
    end;
    FUtfLen := 0;
    PutCharByte(b);
    Exit;
  end;
  if FUtfLen >= FUtfNeed then
  begin
    for i := 0 to FUtfLen - 1 do
      arr[i] := AnsiChar(FUtfBuf[i]);
    PutRawChar(arr, FUtfLen, Attr);
    FUtfLen := 0;
  end;
end;

procedure TScreen.EraseRange(x1, y1, x2, y2: integer; AAttr: word);
var
  x, y: integer;
begin
  for y := y1 to y2 do
  begin
    if (y < 0) or (y >= Height) then
      continue;
    for x := x1 to x2 do
    begin
      if (x < 0) or (x >= Width) then
        continue;
      ClearCell(FGrid[y][x]);
      FGrid[y][x].Attr := AAttr;
    end;
  end;
  Dirty := True;
end;

function TScreen.GetParam(i, def: integer): integer;
begin
  if (i <= FPCount) and (FPParams[i] <> -1) then
    Result := FPParams[i]
  else
    Result := def;
end;

procedure TScreen.DoCSI(final: AnsiChar);
var
  p1, p2, i, n: integer;
begin
  case final of
    'A':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Height then n := Height;
        Dec(CursorY, n);
        if CursorY < ScrollTop then CursorY := ScrollTop;
        FPendingWrap := False;
      end;
    'B', 'e':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Height then n := Height;
        Inc(CursorY, n);
        if CursorY > ScrollBot then CursorY := ScrollBot;
        FPendingWrap := False;
      end;
    'C', 'a':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Width then n := Width;
        Inc(CursorX, n);
        if CursorX >= Width then CursorX := Width - 1;
        FPendingWrap := False;
      end;
    'D':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Width then n := Width;
        Dec(CursorX, n);
        if CursorX < 0 then CursorX := 0;
        FPendingWrap := False;
      end;
    'E':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Height then n := Height;
        Inc(CursorY, n);
        if CursorY > ScrollBot then CursorY := ScrollBot;
        CursorX := 0;
        FPendingWrap := False;
      end;
    'F':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Height then n := Height;
        Dec(CursorY, n);
        if CursorY < ScrollTop then CursorY := ScrollTop;
        CursorX := 0;
        FPendingWrap := False;
      end;
    'G', '`':
      begin
        CursorX := GetParam(0, 1) - 1;
        if CursorX >= Width then CursorX := Width - 1;
        if CursorX < 0 then CursorX := 0;
        FPendingWrap := False;
      end;
    'd':
      begin
        CursorY := GetParam(0, 1) - 1;
        if CursorY >= Height then CursorY := Height - 1;
        if CursorY < 0 then CursorY := 0;
        FPendingWrap := False;
      end;
    'H', 'f':
      begin
        CursorY := GetParam(0, 1) - 1;
        CursorX := GetParam(1, 1) - 1;
        if CursorX >= Width then CursorX := Width - 1;
        if CursorY >= Height then CursorY := Height - 1;
        if CursorX < 0 then CursorX := 0;
        if CursorY < 0 then CursorY := 0;
        FPendingWrap := False;
      end;
    'J':
      begin
        n := GetParam(0, 0);
        case n of
          0: EraseRange(CursorX, CursorY, Width - 1, Height - 1, Attr);
          1: EraseRange(0, 0, CursorX, CursorY, Attr);
          2:
            for i := 0 to Height - 1 do
              BlankRow(i, Attr);
          3:
            begin
              // xterm/tmux: 3J = limpiar pantalla + historial
              for i := 0 to Height - 1 do
                BlankRow(i, Attr);
              FSBCount := 0;
              FSBHead := 0;
              FViewTop := 0;
            end;
        end;
        Dirty := True;
      end;
    'K':
      begin
        n := GetParam(0, 0);
        case n of
          0: EraseRange(CursorX, CursorY, Width - 1, CursorY, Attr);
          1: EraseRange(0, CursorY, CursorX, CursorY, Attr);
          2: EraseRange(0, CursorY, Width - 1, CursorY, Attr);
        end;
      end;
    'L':
      begin
        if (CursorY >= ScrollTop) and (CursorY <= ScrollBot) then
        begin
          n := GetParam(0, 1);
          if n < 1 then n := 1;
          if n > Height then n := Height;
          for i := ScrollBot downto CursorY + n do
            FGrid[i] := Copy(FGrid[i - n], 0, Width);
          for i := CursorY to Min(CursorY + n - 1, ScrollBot) do
            BlankRow(i, Attr);
          Dirty := True;
        end;
      end;
    'M':
      begin
        if (CursorY >= ScrollTop) and (CursorY <= ScrollBot) then
        begin
          n := GetParam(0, 1);
          if n < 1 then n := 1;
          if n > Height then n := Height;
          for i := CursorY to ScrollBot - n do
            FGrid[i] := Copy(FGrid[i + n], 0, Width);
          for i := Max(ScrollBot - n + 1, CursorY) to ScrollBot do
            BlankRow(i, Attr);
          Dirty := True;
        end;
      end;
    '@':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Width then n := Width;
        for i := Width - 1 downto CursorX + n do
          FGrid[CursorY][i] := FGrid[CursorY][i - n];
        for i := CursorX to Min(CursorX + n - 1, Width - 1) do
        begin
          ClearCell(FGrid[CursorY][i]);
          FGrid[CursorY][i].Attr := Attr;
        end;
        Dirty := True;
      end;
    'P':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Width then n := Width;
        for i := CursorX to Width - 1 - n do
          FGrid[CursorY][i] := FGrid[CursorY][i + n];
        for i := Max(Width - n, 0) to Width - 1 do
        begin
          ClearCell(FGrid[CursorY][i]);
          FGrid[CursorY][i].Attr := Attr;
        end;
        Dirty := True;
      end;
    'X':
      begin
        n := GetParam(0, 1);
        if n < 1 then n := 1;
        if n > Width then n := Width;
        EraseRange(CursorX, CursorY, Min(CursorX + n - 1, Width - 1), CursorY, Attr);
      end;
    'm':
      begin
        if (FPCount = 0) and (FPParams[0] = -1) then
        begin
          Attr := A_FGDEF or A_BGDEF;
          Exit;
        end;
        i := 0;
        while i <= FPCount do
        begin
          n := GetParam(i, 0);
          case n of
            0: Attr := A_FGDEF or A_BGDEF;
            1: Attr := Attr or A_BOLD;
            2, 3, 5, 6, 8, 9, 23, 29: ;
            4: Attr := Attr or A_UNDER;
            7: Attr := Attr or A_REVERSE;
            21, 22: Attr := Attr and (not A_BOLD);
            24: Attr := Attr and (not A_UNDER);
            27: Attr := Attr and (not A_REVERSE);
            30..37: Attr := ((Attr and $FFF0) and (not A_FGDEF)) or word(n - 30);
            39: Attr := (Attr and $FFF0) or A_FGDEF;
            40..47: Attr := ((Attr and $FF0F) and (not A_BGDEF)) or (word(n - 40) shl 4);
            49: Attr := (Attr and $FF0F) or A_BGDEF;
            90..97: Attr := ((Attr and $FFF0) and (not A_FGDEF)) or word(n - 90) or A_BOLD;
            100..107: Attr := ((Attr and $FF0F) and (not A_BGDEF)) or (word(n - 100) shl 4);
            38, 48:
              begin
                if GetParam(i + 1, -1) = 5 then
                begin
                  p1 := GetParam(i + 2, -1);
                  if p1 < 8 then
                  begin
                    if n = 38 then
                      Attr := ((Attr and $FFF0) and (not A_FGDEF)) or word(p1)
                    else
                      Attr := ((Attr and $FF0F) and (not A_BGDEF)) or (word(p1) shl 4);
                  end
                  else if (p1 >= 8) and (p1 < 16) then
                  begin
                    if n = 38 then
                      Attr := ((Attr and $FFF0) and (not A_FGDEF)) or word(p1 - 8) or A_BOLD
                    else
                      Attr := ((Attr and $FF0F) and (not A_BGDEF)) or (word(p1 - 8) shl 4);
                  end
                  else
                  begin
                    if n = 38 then
                      Attr := (Attr and $FFF0) or A_FGDEF
                    else
                      Attr := (Attr and $FF0F) or A_BGDEF;
                  end;
                end
                else
                begin
                  // 38;2;r;g;b truecolor: aproximar a default
                  if n = 38 then
                    Attr := (Attr and $FFF0) or A_FGDEF
                  else
                    Attr := (Attr and $FF0F) or A_BGDEF;
                end;
                Inc(i, 4);
              end;
          end;
          Inc(i);
        end;
      end;
    'r':
      begin
        p1 := GetParam(0, 1);
        p2 := GetParam(1, Height);
        if (p1 < 1) then p1 := 1;
        if (p2 > Height) then p2 := Height;
        if p2 > p1 then
        begin
          ScrollTop := p1 - 1;
          ScrollBot := p2 - 1;
          CursorX := 0;
          CursorY := ScrollTop;
        end;
      end;
    's':
      begin
        FSaveX := CursorX;
        FSaveY := CursorY;
      end;
    'u':
      begin
        CursorX := FSaveX;
        CursorY := FSaveY;
      end;
    'q':
      begin
        // DECSCUSR: CSI Ps SP q  (estilo de cursor)
        if FInterm = ' ' then
          CursorStyle := GetParam(0, 0);
      end;
    'S': ScrollUp(GetParam(0, 1));
    'T': ScrollDown(GetParam(0, 1));
    'h', 'l':
      begin
        if FPPriv then
        begin
            for i := 0 to FPCount do
            begin
              n := GetParam(i, 0);
              case n of
                25: CursorVisible := (final = 'h');
                7: FAutoWrap := (final = 'h');
                47, 1047, 1049:
                begin
                  if final = 'h' then
                  begin
                    if not FUsingAlt then
                    begin
                       CopyGrid(FGrid, FAltGrid);
                      FUsingAlt := True;
                      if n = 1049 then
                      begin
                        FSaveX := CursorX;
                        FSaveY := CursorY;
                        EraseRange(0, 0, Width - 1, Height - 1, Attr);
                      end;
                      CursorX := 0;
                      CursorY := 0;
                    end;
                  end
                  else
                  begin
                    if FUsingAlt then
                    begin
                      FUsingAlt := False;
                      if FAltGrid <> nil then
                        FGrid := Copy(FAltGrid, 0, Height);
                      FAltGrid := nil;
                      if n = 1049 then
                      begin
                        CursorX := FSaveX;
                        CursorY := FSaveY;
                      end;
                    end;
                  end;
                  Dirty := True;
                end;
            end;
          end;
        end;
      end;
  end;
  Dirty := True;
end;

procedure TScreen.DispatchEsc(c: AnsiChar);
var
  i: integer;
begin
  case c of
    '[':
      begin
        FPState := psCsi;
        FPCount := 0;
        for i := 0 to High(FPParams) do
          FPParams[i] := -1;
        FPPriv := False;
        FInterm := #0;
        Exit;
      end;
    ']':
      begin
        // Keep OSC payloads out of the visible grid until BEL or ST ends them.
        FOscBuf := '';
        FPState := psOsc;
        Exit;
      end;
    '(', ')', '*', '+': FPState := psCharset;
    '7':
      begin
        FSaveX := CursorX;
        FSaveY := CursorY;
        FPState := psGround;
      end;
    '8':
      begin
        CursorX := FSaveX;
        CursorY := FSaveY;
        FPState := psGround;
      end;
    'D': LineFeed;
    'M':
      begin
        if CursorY = ScrollTop then
          ScrollDown(1)
        else if CursorY > 0 then
          Dec(CursorY);
        FPendingWrap := False;
      end;
    'E':
      begin
        CursorX := 0;
        LineFeed;
      end;
    'c': ResetSoft;
  else
    ; // =, >, etc: ignorar
  end;
  if FPState <> psCsi then
    FPState := psGround;
end;

procedure TScreen.ResetSoft;
begin
  Attr := A_FGDEF or A_BGDEF;
  CursorX := 0;
  CursorY := 0;
  ScrollTop := 0;
  ScrollBot := Height - 1;
  CursorVisible := True;
  CursorStyle := 0;
  FAutoWrap := True;
  FPendingWrap := False;
end;

procedure TScreen.WriteBytes(const Buf; Count: integer);
var
  P: ^byte;
  b: byte;
  i: integer;
begin
  P := @Buf;
  for i := 0 to Count - 1 do
  begin
    b := P^;
    Inc(P);
    case FPState of
      psGround:
        begin
          case b of
            27: FPState := psEsc;
            13:
              begin
                CursorX := 0;
                FPendingWrap := False;
              end;
            10, 11, 12: LineFeed;
            8:
              begin
                if CursorX > 0 then
                  Dec(CursorX);
                FPendingWrap := False;
              end;
            9:
              begin
                CursorX := ((CursorX div 8) + 1) * 8;
                if CursorX >= Width then
                  CursorX := Width - 1;
                FPendingWrap := False;
              end;
            7: ; // bell
            14, 15: ; // charset shift
          else
            if b >= 32 then
              PutCharByte(b);
          end;
        end;
      psEsc:
        DispatchEsc(AnsiChar(b));
      psCsi:
        begin
          if (b >= $30) and (b <= $39) then
          begin
            if FPCount > 15 then FPCount := 15;
            if FPParams[FPCount] = -1 then
              FPParams[FPCount] := b - $30
            else if FPParams[FPCount] >= (MaxInt div 10) then
              FPParams[FPCount] := MaxInt
            else
              FPParams[FPCount] := FPParams[FPCount] * 10 + (b - $30);
          end
          else if b = Ord(';') then
          begin
            Inc(FPCount);
            if FPCount > 15 then FPCount := 15;
          end
          else if b = Ord('?') then
            FPPriv := True
          else if (b >= $20) and (b <= $2F) then
          begin
            FInterm := AnsiChar(b);   // intermedio: ' ' de DECSCUSR etc.
          end
          else if (b >= $40) and (b <= $7E) then
          begin
            DoCSI(AnsiChar(b));
            FPState := psGround;
            FPPriv := False;
            FInterm := #0;
          end
          else
          begin
            FPState := psGround;
            FInterm := #0;
          end;
        end;
      psOsc:
        begin
          if b = 7 then
            FPState := psGround // BEL fin de OSC
          else if b = 27 then
            FPState := psOscEsc
          else
          begin
            if Length(FOscBuf) < 1024 then
              FOscBuf := FOscBuf + AnsiChar(b);
          end;
        end;
      psOscEsc:
        begin
          if b = Ord('\') then
            FPState := psGround
          else
            FPState := psGround;
          FOscBuf := '';
        end;
      psCharset:
        FPState := psGround;
    end;
  end;
  Dirty := True;
end;

end.
