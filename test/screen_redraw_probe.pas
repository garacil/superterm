program screen_redraw_probe;

{ A pane's redraw must leave a cleared terminal exactly where the program
  left its own: the same cells, cursor, pen, scrolling region and wrap state.
  Each case parses a stream into one screen, plays that screen's RedrawBytes
  into a second, cleared one, and compares them -- then feeds the same
  further bytes to both and compares again, which is what the program's
  next raw output does to the host terminal. }

{$mode objfpc}{$H+}

uses
  SysUtils, st_screen;

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

function CellText(const C: TCell): RawByteString;
var
  I: integer;
begin
  if C.Len = 0 then
    Exit(' ');
  Result := '';
  for I := 0 to C.Len - 1 do
    Result := Result + C.Txt[I];
end;

// a blank a cleared terminal shows anyway: its foreground cannot be seen
function Plain(const C: TCell): boolean;
begin
  Result := (not C.Cont) and (CellText(C) = ' ') and
    ((C.Attr and A_BGDEF) <> 0) and (C.BgRGB = 0) and
    ((C.Attr and (A_UNDER or A_REVERSE)) = 0);
end;

function SameCell(const A, B: TCell): boolean;
begin
  if Plain(A) then
    Exit(Plain(B));
  Result := (A.Cont = B.Cont) and (CellText(A) = CellText(B)) and
    (A.Attr = B.Attr) and (A.FgRGB = B.FgRGB) and (A.BgRGB = B.BgRGB);
end;

function SameScreen(A, B: TScreen; out AWhy: string): boolean;
var
  X, Y: integer;
begin
  AWhy := '';
  for Y := 0 to A.Height - 1 do
    for X := 0 to A.Width - 1 do
      if not SameCell(A.Grid[Y][X], B.Grid[Y][X]) then
      begin
        AWhy := Format('cell %d,%d %s/%x/%x vs %s/%x/%x', [X, Y,
          CellText(A.Grid[Y][X]), A.Grid[Y][X].Attr, A.Grid[Y][X].FgRGB,
          CellText(B.Grid[Y][X]), B.Grid[Y][X].Attr, B.Grid[Y][X].FgRGB]);
        Exit(False);
      end;
  if (A.CursorX <> B.CursorX) or (A.CursorY <> B.CursorY) then
    AWhy := Format('cursor %d,%d vs %d,%d',
      [A.CursorX, A.CursorY, B.CursorX, B.CursorY])
  else if (A.Attr <> B.Attr) or (A.AttrFgRGB <> B.AttrFgRGB) or
     (A.AttrBgRGB <> B.AttrBgRGB) then
    AWhy := Format('pen %x/%x/%x vs %x/%x/%x', [A.Attr, A.AttrFgRGB,
      A.AttrBgRGB, B.Attr, B.AttrFgRGB, B.AttrBgRGB])
  else if (A.ScrollTop <> B.ScrollTop) or (A.ScrollBot <> B.ScrollBot) then
    AWhy := Format('region %d-%d vs %d-%d',
      [A.ScrollTop, A.ScrollBot, B.ScrollTop, B.ScrollBot])
  else if A.CursorVisible <> B.CursorVisible then
    AWhy := 'cursor visibility';
  Result := AWhy = '';
end;

procedure Feed(AScreen: TScreen; const AData: RawByteString);
begin
  if AData <> '' then
    AScreen.WriteBytes(AData[1], Length(AData));
end;

procedure RoundTrip(const AName: string; AW, AH: integer;
  const AStream, AThen: RawByteString);
var
  Source, Mirror: TScreen;
  Why: string;
begin
  Source := TScreen.Create(AW, AH, 0);
  Mirror := TScreen.Create(AW, AH, 0);
  try
    Feed(Source, AStream);
    Feed(Mirror, #27'[0m'#27'[2J'#27'[H' + Source.RedrawBytes);
    Check(AName + ' redraws identically', SameScreen(Source, Mirror, Why));
    if Why <> '' then
      WriteLn('  ', Why);
    Feed(Source, AThen);
    Feed(Mirror, AThen);
    Check(AName + ' continues identically', SameScreen(Source, Mirror, Why));
    if Why <> '' then
      WriteLn('  ', Why);
  finally
    Mirror.Free;
    Source.Free;
  end;
end;

begin
  RoundTrip('renditions', 40, 8,
    #27'[1;31mbold red'#27'[0m '#27'[2;94mfaint bright'#27'[0m'#13#10 +
    #27'[4;7;43munder rev'#27'[0m '#27'[8mhidden'#27'[28m '#27'[105mbg'#13#10 +
    #27'[0;38;5;200;48;5;17mpalette'#27'[38;2;255;100;0;48;2;0;80;200mrgb' +
    #27'[0m'#13#10#27'[44m'#27'[K'#27'[0m'#13#10 +
    #27'[3;5H'#27'[4;38;2;1;2;3mpen',
    'more'#13#10'next line');
  RoundTrip('wide and combining glyphs', 12, 3,
    #$E6#$BC#$A2'x'#$CC#$81#$E2#$9D#$AF' '#$E6#$BC#$A2#$E6#$BC#$A2,
    'yz');
  RoundTrip('pending wrap', 10, 4,
    #27'[2;1H'#27'[32m0123456789',
    'W'#13#10'X');
  RoundTrip('pending wrap after a wide glyph', 10, 4,
    #27'[3;1H01234567'#$E6#$BC#$A2,
    'W');
  RoundTrip('pending wrap at the bottom row', 10, 3,
    #27'[3;1H0123456789',
    'W');
  RoundTrip('autowrap off', 10, 3,
    #27'[?7l'#27'[1;1H0123456789AB',
    'CD'#13#10'e');
  RoundTrip('scrolling region', 20, 10,
    'top'#27'[3;7r'#27'[7;1Hbottom of region'#27'[10;1Hlast',
    #27'[7;1H'#10#10'scrolled');
  RoundTrip('hidden cursor', 10, 3,
    #27'[?25lhid',
    'den');
  RoundTrip('alternate screen', 20, 4,
    'main'#27'[?1049h'#27'[2;3H'#27'[35malt',
    ' still');
  if Failed then
    Halt(1);
end.
