unit st_video;

{$mode objfpc}{$H+}

interface

procedure InstallWideVideoOutput;

implementation

uses
  BaseUnix, SysUtils, Video;

var
  SavedDriver: TVideoDriver;
  DriverInstalled: Boolean;

procedure WriteRaw(const S: AnsiString);
begin
  if Length(S) > 0 then
    fpWrite(StdOutputHandle, S[1], Length(S));
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
    16: Result := '►';
    17: Result := '◄';
    18: Result := '↕';
    24: Result := '↔';
    25: Result := '↑';
    26: Result := '↓';
    27: Result := '←';
    176: Result := '░';
    177: Result := '▒';
    178: Result := '▓';
    179: Result := '│';
    180: Result := '┤';
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
    200: Result := '╚';
    201: Result := '╔';
    205: Result := '═';
    217: Result := '┘';
    218: Result := '┌';
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
    Text := Text + VgaChar(Byte(VideoBuf^[I]));
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
      if (not Force) and (VideoBuf^[Index] = OldVideoBuf^[Index]) then
      begin
        Inc(X);
        Continue;
      end;

      RunStart := X;
      Attr := Byte(VideoBuf^[Index] shr 8);
      Inc(X);
      while X < ScreenWidth do
      begin
        Index := Y * ScreenWidth + X;
        if (not Force) and (VideoBuf^[Index] = OldVideoBuf^[Index]) then
          Break;
        if Byte(VideoBuf^[Index] shr 8) <> Attr then
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

  WriteRaw(CursorPosition(CursorX, CursorY));
  Move(VideoBuf^, OldVideoBuf^, VideoBufSize);
end;

procedure WideDoneVideo;
begin
  WriteRaw(#27'[?7h');
  if Assigned(SavedDriver.DoneDriver) then
    SavedDriver.DoneDriver;
end;

procedure InstallWideVideoOutput;
var
  Driver: TVideoDriver;
begin
  if DriverInstalled then
    Exit;
  GetVideoDriver(SavedDriver);
  Driver := SavedDriver;
  Driver.UpdateScreen := @WideUpdateScreen;
  Driver.DoneDriver := @WideDoneVideo;
  if SetVideoDriver(Driver) then
    DriverInstalled := True;
end;

end.
