program screen_ascii_fastpath_probe;

{$mode objfpc}{$H+}

uses
  SysUtils, st_screen;

const
  BatchBytes = 65536;
  BenchmarkRounds = 256;

var
  Failed: boolean = False;

procedure Check(const AName: string; ACondition: boolean);
begin
  if ACondition then
    WriteLn(AName, ': OK')
  else
  begin
    WriteLn(AName, ': FAIL');
    Failed := True;
  end;
end;

function CellText(AScreen: TScreen; AX, AY: integer): RawByteString;
var
  I: integer;
begin
  Result := '';
  if (AY < 0) or (AY >= Length(AScreen.Grid)) or
     (AX < 0) or (AX >= Length(AScreen.Grid[AY])) then
    Exit;
  for I := 0 to AScreen.Grid[AY][AX].Len - 1 do
    Result := Result + AScreen.Grid[AY][AX].Txt[I];
end;

procedure CheckSemantics;
var
  Screen: TScreen;
  Data: RawByteString;
begin
  Screen := TScreen.Create(4, 2, 0);
  try
    Data := 'abcde';
    Screen.WriteBytes(Data[1], Length(Data));
    Check('pending wrap keeps completed row',
      (CellText(Screen, 0, 0) = 'a') and
      (CellText(Screen, 3, 0) = 'd') and
      (CellText(Screen, 0, 1) = 'e') and
      (Screen.CursorX = 1) and (Screen.CursorY = 1));
  finally
    Screen.Free;
  end;

  Screen := TScreen.Create(4, 2, 0);
  try
    Data := #27'[?7labcde';
    Screen.WriteBytes(Data[1], Length(Data));
    Check('disabled autowrap overwrites final cell',
      (CellText(Screen, 0, 0) = 'a') and
      (CellText(Screen, 2, 0) = 'c') and
      (CellText(Screen, 3, 0) = 'e') and
      (Screen.CursorX = 3) and (Screen.CursorY = 0));
  finally
    Screen.Free;
  end;

  Screen := TScreen.Create(8, 2, 0);
  try
    Data := #27'[1;4;38;2;1;2;3;48;5;196mA';
    Screen.WriteBytes(Data[1], Length(Data));
    Check('ASCII preserves rendition',
      (CellText(Screen, 0, 0) = 'A') and
      ((Screen.Grid[0][0].Attr and A_BOLD) <> 0) and
      ((Screen.Grid[0][0].Attr and A_UNDER) <> 0) and
      (Screen.Grid[0][0].FgRGB = $01010203) and
      (Screen.Grid[0][0].BgRGB = $030000C4));
  finally
    Screen.Free;
  end;

  Screen := TScreen.Create(8, 2, 0);
  try
    Data := #$E6#$BC#$A2'A'#$CC#$81;
    Screen.WriteBytes(Data[1], Length(Data));
    Check('UTF-8 wide and combining paths remain intact',
      (CellText(Screen, 0, 0) = #$E6#$BC#$A2) and
      Screen.Grid[0][1].Cont and
      (CellText(Screen, 2, 0) = 'A'#$CC#$81) and
      (Screen.CursorX = 3));
  finally
    Screen.Free;
  end;
end;

procedure RunBenchmark;
var
  Screen: TScreen;
  Batch: RawByteString;
  I, J: integer;
  Started, Elapsed: QWord;
begin
  SetLength(Batch, BatchBytes);
  I := 1;
  while I <= Length(Batch) do
  begin
    for J := 0 to 398 do
      if I + J <= Length(Batch) then
        Batch[I + J] := AnsiChar(Ord('!') + (J mod 90));
    Inc(I, 399);
    if I <= Length(Batch) then
    begin
      Batch[I] := #13;
      Inc(I);
    end;
  end;
  Screen := TScreen.Create(400, 100, 0);
  try
    Screen.WriteBytes(Batch[1], Length(Batch));
    Started := GetTickCount64;
    for I := 1 to BenchmarkRounds do
      Screen.WriteBytes(Batch[1], Length(Batch));
    Elapsed := GetTickCount64 - Started;
    WriteLn('benchmark_bytes=', Int64(BatchBytes) * BenchmarkRounds);
    WriteLn('benchmark_ms=', Elapsed);
  finally
    Screen.Free;
  end;
end;

begin
  CheckSemantics;
  RunBenchmark;
  if Failed then
    Halt(1);
end.
