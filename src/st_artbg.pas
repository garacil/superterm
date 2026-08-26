(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_artbg - ASCII art desktop backgrounds

  The desktop can show a picture behind the windows instead of the plain
  pattern. Pictures are PLAIN TEXT FILES loaded at run time, not compiled
  in, so anyone can drop their own into ~/.superterm/backgrounds/ without
  rebuilding. A file looks like this:

    name: City at night
    name.es: Ciudad de noche
    palette: 0E1430 1B2450 26325F FFD866
    >    333   33333
    :    111   22222
    .    000   00000

  Line prefixes:
    mode:  optional, the layout the picture is meant for (center, tile,
           stretch or fit). Choosing it from the menu adopts that layout.

    width: optional logical cell width. This preserves transparent columns
           at the right edge without storing trailing spaces. When absent,
           the longest glyph row remains the width, as in every older file.

    charset: optional. 'quad' means a glyph row holds quadrant masks --
           '0'..'9' then 'a'..'f', one bit per quarter of the cell: 1 upper
           left, 2 upper right, 4 lower left, 8 lower right. A cell then
           carries four pixels in its two colours instead of two, so a
           picture holds twice the horizontal detail. Without the key the
           glyph row means what it always did.

    >   a row of glyphs. ' ' leaves the cell empty so the desktop shows
        through; '1' '2' '3' are the block characters U+2580 (upper half),
        U+2584 (lower half) and U+2588 (full); '4' '5' '6' are the light,
        medium and dark shades; anything else is drawn literally.
    :   the foreground palette index of each cell: '0'..'9', then 'a'..'z',
        then 'A'..'Z' (62 entries). ' ' means the terminal default.
    .   the same for the background colour. Optional.

  Colours are real RGB and reach the terminal through the rich renderer,
  so a picture is not confined to the 16-colour grid.
*)

unit st_artbg;

{$mode objfpc}{$H+}

interface

type
  TArtCell = record
    Glyph: RawByteString;   // '' = empty cell, nothing is painted
    Fg, Bg: LongWord;       // $01RRGGBB, 0 = terminal default
  end;

  // How a picture is laid over the desktop, the classic wallpaper modes
  // that make sense on a character grid:
  //   amCenter   drawn once at its own size, centred (default)
  //   amTile     repeated to cover the whole desktop
  //   amStretch  scaled to the desktop by nearest-neighbour sampling, so a
  //              cell is duplicated rather than interpolated -- there is no
  //              blending between two characters
  //   amFit      scaled keeping the aspect ratio, then centred
  TArtMode = (amCenter, amTile, amStretch, amFit);

// Pictures found on disk, in menu order. Index 0 is always 'none' (the
// plain desktop pattern) and always exists, even with no files installed.
function ArtCount: integer;
function ArtName(AIndex: integer): string;          // key for [ui] background
function ArtLabel(AIndex: integer): string;         // menu label, English
function ArtLabelEs(AIndex: integer): string;       // menu label, Spanish
function ArtIndexOf(const AName: string): integer;  // 0 when unknown
procedure ArtSize(AIndex: integer; out AW, AH: integer);
// Layout the picture asks for with its 'mode:' key, '' when it does not
// care. A seamless pattern ships with 'tile' so picking it from the menu
// lays it out the way it was designed for.
function ArtSuggestedMode(AIndex: integer): string;
function ArtCellAt(AIndex, AX, AY: integer): TArtCell;
// The cell to paint at desktop position (X, Y) for a given mode. This is
// what the background view calls; it handles the centring, wrapping and
// scaling so the caller only walks its own rectangle.
function ArtCellFor(AIndex: integer; AMode: TArtMode;
  ADeskW, ADeskH, AX, AY: integer): TArtCell;
function ArtModeName(AMode: TArtMode): string;
function ArtModeLabel(AMode: TArtMode): string;
function ArtModeLabelEs(AMode: TArtMode): string;
function ArtModeOf(const AName: string): TArtMode;
// Directories searched, first match wins, for diagnostics and docs.
function ArtSearchPath: string;
// Re-scan the directories (after the user drops in a new file).
procedure ArtReload;

implementation

uses
  SysUtils, Classes;

const
  // A user may drop an .art file into a searched directory. Keep declared
  // geometry bounded before it participates in fit/stretch arithmetic.
  MAX_ART_DECLARED_WIDTH = 4096;

type
  TArtRow = record
    Glyphs, Fg, Bg: RawByteString;
  end;

  TArtPicture = record
    Name: string;         // file name without extension = config key
    Title: string;        // name:
    TitleEs: string;      // name.es:
    Mode: string;         // mode: suggested layout, '' = leave the current one
    // charset: 'quad' means a glyph row holds quadrant masks rather than the
    // half-block shorthand. A cell then carries FOUR pixels instead of two --
    // its own two colours split over a 2x2 grid -- which doubles the
    // horizontal resolution a picture can hold. Anything else, including the
    // key being absent, keeps the original meaning, so every picture written
    // before this still loads exactly as it did.
    Quad: boolean;
    Pal: array of LongWord;
    Rows: array of TArtRow;
    Width: integer;
  end;

var
  Pics: array of TArtPicture;
  Loaded: boolean = False;

function ArtSearchPath: string;
var
  Bin: string;
begin
  // First match wins, so a user's own file shadows the installed one of the
  // same name. The path relative to the binary makes any --prefix work
  // without baking the install location into the executable, and the last
  // entry lets the program run straight from a source checkout.
  Bin := ExtractFilePath(ParamStr(0));
  Result := '';
  if GetEnvironmentVariable('SUPERTERM_BACKGROUNDS') <> '' then
    Result := GetEnvironmentVariable('SUPERTERM_BACKGROUNDS') + PathSep;
  Result := Result +
    GetEnvironmentVariable('HOME') + '/.superterm/backgrounds' + PathSep +
    Bin + '../share/superterm/backgrounds' + PathSep +
    '/usr/local/share/superterm/backgrounds' + PathSep +
    '/usr/share/superterm/backgrounds' + PathSep +
    Bin + '../backgrounds';
end;

function HexColor(const S: string): LongWord;
var
  V: LongWord;
begin
  Result := 0;
  if Length(S) <> 6 then
    Exit;
  if not TryStrToDWord('$' + S, V) then
    Exit;
  Result := $01000000 or (V and $FFFFFF);
end;

// One picture file. Returns False when it holds no rows.
function LoadPicture(const APath: string; out P: TArtPicture): boolean;
var
  F: TextFile;
  Line, Key, Val: string;
  Body: string;
  n, sp: integer;
  R: TArtRow;
  Started: boolean;
begin
  Result := False;
  P := Default(TArtPicture);
  P.Name := ChangeFileExt(ExtractFileName(APath), '');
  P.Title := P.Name;
  P.TitleEs := P.Name;
  {$I-}
  AssignFile(F, APath);
  Reset(F);
  {$I+}
  if IOResult <> 0 then
    Exit;
  Started := False;
  try
    while not EOF(F) do
    begin
      ReadLn(F, Line);
      if Line = '' then
        Continue;
      case Line[1] of
        '#': Continue;
        '>':
          begin
            // a glyph row opens a new cell row; the colour lines that
            // follow belong to it
            R := Default(TArtRow);
            R.Glyphs := Copy(Line, 3, MaxInt);
            SetLength(P.Rows, Length(P.Rows) + 1);
            P.Rows[High(P.Rows)] := R;
            if Length(R.Glyphs) > P.Width then
              P.Width := Length(R.Glyphs);
            Started := True;
          end;
        ':':
          if Started then
            P.Rows[High(P.Rows)].Fg := Copy(Line, 3, MaxInt);
        '.':
          if Started then
            P.Rows[High(P.Rows)].Bg := Copy(Line, 3, MaxInt);
      else
        begin
          sp := Pos(':', Line);
          if sp < 2 then
            Continue;
          Key := LowerCase(Trim(Copy(Line, 1, sp - 1)));
          Val := Trim(Copy(Line, sp + 1, MaxInt));
          if Key = 'name' then
            P.Title := Val
          else if Key = 'name.es' then
            P.TitleEs := Val
          else if Key = 'mode' then
            P.Mode := LowerCase(Val)
          else if Key = 'width' then
          begin
            // The declaration may occur before or after the rows. It can
            // enlarge their logical canvas, never crop visible glyphs.
            if TryStrToInt(Val, n) and (n > 0) and
               (n <= MAX_ART_DECLARED_WIDTH) and (n > P.Width) then
              P.Width := n;
          end
          else if Key = 'charset' then
            P.Quad := LowerCase(Val) = 'quad'
          else if Key = 'palette' then
          begin
            Body := Val;
            while Body <> '' do
            begin
              sp := Pos(' ', Body);
              if sp = 0 then
              begin
                Key := Body;
                Body := '';
              end
              else
              begin
                Key := Copy(Body, 1, sp - 1);
                Body := Trim(Copy(Body, sp + 1, MaxInt));
              end;
              if Key <> '' then
              begin
                n := Length(P.Pal);
                SetLength(P.Pal, n + 1);
                P.Pal[n] := HexColor(Key);
              end;
            end;
          end;
        end;
      end;
    end;
  finally
    CloseFile(F);
  end;
  if P.TitleEs = P.Name then
    P.TitleEs := P.Title;
  Result := Length(P.Rows) > 0;
end;

procedure ScanDir(const ADir: string);
var
  Rec: TSearchRec;
  P: TArtPicture;
  i: integer;
  Dup: boolean;
begin
  if not DirectoryExists(ADir) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*.art', faAnyFile, Rec) <> 0 then
    Exit;
  try
    repeat
      if (Rec.Attr and faDirectory) <> 0 then
        Continue;
      if not LoadPicture(IncludeTrailingPathDelimiter(ADir) + Rec.Name, P) then
        Continue;
      // a picture already found in an earlier directory wins, so a user
      // file shadows the system one of the same name
      Dup := False;
      for i := 0 to High(Pics) do
        if SameText(Pics[i].Name, P.Name) then
        begin
          Dup := True;
          Break;
        end;
      if Dup then
        Continue;
      SetLength(Pics, Length(Pics) + 1);
      Pics[High(Pics)] := P;
    until FindNext(Rec) <> 0;
  finally
    FindClose(Rec);
  end;
end;

// Alphabetical by label, so the menu reads the same whatever order the
// directory happened to hand the files over in.
procedure SortPics;
var
  i, j: integer;
  T: TArtPicture;
begin
  for i := 0 to High(Pics) - 1 do
    for j := 0 to High(Pics) - 1 - i do
      if CompareText(Pics[j].Title, Pics[j + 1].Title) > 0 then
      begin
        T := Pics[j];
        Pics[j] := Pics[j + 1];
        Pics[j + 1] := T;
      end;
end;

procedure EnsureLoaded;
var
  Path, Dir: string;
  sp: integer;
begin
  if Loaded then
    Exit;
  Loaded := True;
  SetLength(Pics, 0);
  Path := ArtSearchPath;
  while Path <> '' do
  begin
    sp := Pos(PathSep, Path);
    if sp = 0 then
    begin
      Dir := Path;
      Path := '';
    end
    else
    begin
      Dir := Copy(Path, 1, sp - 1);
      Path := Copy(Path, sp + 1, MaxInt);
    end;
    if Dir <> '' then
      ScanDir(Dir);
  end;
  SortPics;
end;

procedure ArtReload;
begin
  Loaded := False;
  EnsureLoaded;
end;

function ArtCount: integer;
begin
  EnsureLoaded;
  Result := Length(Pics) + 1;   // + 'none'
end;

function ArtName(AIndex: integer): string;
begin
  EnsureLoaded;
  if (AIndex <= 0) or (AIndex > Length(Pics)) then
    Result := 'none'
  else
    Result := Pics[AIndex - 1].Name;
end;

function ArtLabel(AIndex: integer): string;
begin
  EnsureLoaded;
  if (AIndex <= 0) or (AIndex > Length(Pics)) then
    Result := 'None'
  else
    Result := Pics[AIndex - 1].Title;
end;

function ArtLabelEs(AIndex: integer): string;
begin
  EnsureLoaded;
  if (AIndex <= 0) or (AIndex > Length(Pics)) then
    Result := 'Ninguno'
  else
    Result := Pics[AIndex - 1].TitleEs;
end;

function ArtIndexOf(const AName: string): integer;
var
  i: integer;
begin
  EnsureLoaded;
  for i := 1 to ArtCount - 1 do
    if SameText(AName, ArtName(i)) then
      Exit(i);
  Result := 0;
end;

procedure ArtSize(AIndex: integer; out AW, AH: integer);
begin
  EnsureLoaded;
  AW := 0;
  AH := 0;
  if (AIndex <= 0) or (AIndex > Length(Pics)) then
    Exit;
  AW := Pics[AIndex - 1].Width;
  AH := Length(Pics[AIndex - 1].Rows);
end;

function ArtSuggestedMode(AIndex: integer): string;
begin
  EnsureLoaded;
  if (AIndex <= 0) or (AIndex > Length(Pics)) then
    Result := ''
  else
    Result := Pics[AIndex - 1].Mode;
end;

// The sixteen ways two colours can fill a 2x2 cell, indexed by a bit per
// quarter: 1 upper-left, 2 upper-right, 4 lower-left, 8 lower-right. Written
// in a glyph row as '0'..'9' then 'a'..'f'.
function QuadGlyphOf(C: AnsiChar): RawByteString;
const
  QUADS: array[0..15] of RawByteString = (
    '',                 // 0  nothing: the desktop shows through
    #$E2#$96#$98,       // 1  upper left
    #$E2#$96#$9D,       // 2  upper right
    #$E2#$96#$80,       // 3  upper half
    #$E2#$96#$96,       // 4  lower left
    #$E2#$96#$8C,       // 5  left half
    #$E2#$96#$9E,       // 6  upper right + lower left
    #$E2#$96#$9B,       // 7  all but lower right
    #$E2#$96#$97,       // 8  lower right
    #$E2#$96#$9A,       // 9  upper left + lower right
    #$E2#$96#$90,       // a  right half
    #$E2#$96#$9C,       // b  all but lower left
    #$E2#$96#$84,       // c  lower half
    #$E2#$96#$99,       // d  all but upper right
    #$E2#$96#$9F,       // e  all but upper left
    #$E2#$96#$88);      // f  full block
var
  I: integer;
begin
  I := -1;
  if (C >= '0') and (C <= '9') then
    I := Ord(C) - Ord('0')
  else if (C >= 'a') and (C <= 'f') then
    I := 10 + Ord(C) - Ord('a');
  if (I >= 0) and (I <= 15) then
    Result := QUADS[I]
  else
    Result := '';
end;

function GlyphOf(C: AnsiChar): RawByteString;
begin
  case C of
    ' ': Result := '';
    '1': Result := #$E2#$96#$80;   // upper half block
    '2': Result := #$E2#$96#$84;   // lower half block
    '3': Result := #$E2#$96#$88;   // full block
    '4': Result := #$E2#$96#$91;   // light shade
    '5': Result := #$E2#$96#$92;   // medium shade
    '6': Result := #$E2#$96#$93;   // dark shade
  else
    Result := C;
  end;
end;

function PalIndex(C: AnsiChar): integer;
begin
  // '0'-'9', then 'a'-'z', then 'A'-'Z': 62 palette entries, enough for a
  // picture sampled from a gradient rather than drawn by hand.
  if (C >= '0') and (C <= '9') then
    Result := Ord(C) - Ord('0')
  else if (C >= 'a') and (C <= 'z') then
    Result := 10 + Ord(C) - Ord('a')
  else if (C >= 'A') and (C <= 'Z') then
    Result := 36 + Ord(C) - Ord('A')
  else
    Result := -1;          // ' ' or anything else: terminal default
end;

function ArtCellAt(AIndex, AX, AY: integer): TArtCell;
var
  P: ^TArtPicture;
  k: integer;

  function Col(const S: RawByteString): LongWord;
  var
    j: integer;
  begin
    Result := 0;
    if (AX < 1) or (AX > Length(S)) then
      Exit;
    j := PalIndex(S[AX]);
    if (j >= 0) and (j <= High(P^.Pal)) then
      Result := P^.Pal[j];
  end;

begin
  EnsureLoaded;
  Result.Glyph := '';
  Result.Fg := 0;
  Result.Bg := 0;
  if (AIndex <= 0) or (AIndex > Length(Pics)) then
    Exit;
  P := @Pics[AIndex - 1];
  if (AY < 0) or (AY > High(P^.Rows)) then
    Exit;
  if (AX < 1) or (AX > Length(P^.Rows[AY].Glyphs)) then
    Exit;
  if P^.Quad then
    Result.Glyph := QuadGlyphOf(P^.Rows[AY].Glyphs[AX])
  else
    Result.Glyph := GlyphOf(P^.Rows[AY].Glyphs[AX]);
  if Result.Glyph = '' then
    Exit;
  k := AIndex;   // silence the unused warning on some compilers
  if k > 0 then
  begin
    Result.Fg := Col(P^.Rows[AY].Fg);
    Result.Bg := Col(P^.Rows[AY].Bg);
  end;
end;

function ArtModeName(AMode: TArtMode): string;
begin
  case AMode of
    amTile: Result := 'tile';
    amStretch: Result := 'stretch';
    amFit: Result := 'fit';
  else
    Result := 'center';
  end;
end;

function ArtModeLabel(AMode: TArtMode): string;
begin
  case AMode of
    amTile: Result := 'Tiled';
    amStretch: Result := 'Stretched';
    amFit: Result := 'Fitted';
  else
    Result := 'Centred';
  end;
end;

function ArtModeLabelEs(AMode: TArtMode): string;
begin
  case AMode of
    amTile: Result := 'Mosaico';
    amStretch: Result := 'Estirado';
    amFit: Result := 'Ajustado';
  else
    Result := 'Centrado';
  end;
end;

function ArtModeOf(const AName: string): TArtMode;
begin
  if SameText(AName, 'tile') then Result := amTile
  else if SameText(AName, 'stretch') then Result := amStretch
  else if SameText(AName, 'fit') then Result := amFit
  else Result := amCenter;
end;

function ArtCellFor(AIndex: integer; AMode: TArtMode;
  ADeskW, ADeskH, AX, AY: integer): TArtCell;
var
  W, H, sx, sy, sw, sh, ox, oy: integer;
begin
  Result.Glyph := '';
  Result.Fg := 0;
  Result.Bg := 0;
  ArtSize(AIndex, W, H);
  if (W <= 0) or (H <= 0) or (ADeskW <= 0) or (ADeskH <= 0) then
    Exit;
  case AMode of
    amTile:
      begin
        sx := (AX mod W) + 1;
        sy := AY mod H;
      end;
    amStretch:
      begin
        sx := (AX * W) div ADeskW + 1;
        sy := (AY * H) div ADeskH;
      end;
    amFit:
      begin
        // largest integer-free scale that fits both axes, keeping the
        // picture's proportions, then centred in what is left over
        if ADeskW * H < ADeskH * W then
        begin
          sw := ADeskW;
          sh := (ADeskW * H) div W;
        end
        else
        begin
          sh := ADeskH;
          sw := (ADeskH * W) div H;
        end;
        if sw < 1 then sw := 1;
        if sh < 1 then sh := 1;
        ox := (ADeskW - sw) div 2;
        oy := (ADeskH - sh) div 2;
        if (AX < ox) or (AX >= ox + sw) or (AY < oy) or (AY >= oy + sh) then
          Exit;
        sx := ((AX - ox) * W) div sw + 1;
        sy := ((AY - oy) * H) div sh;
      end;
  else
    begin
      ox := (ADeskW - W) div 2;
      oy := (ADeskH - H) div 2;
      sx := AX - ox + 1;
      sy := AY - oy;
    end;
  end;
  Result := ArtCellAt(AIndex, sx, sy);
end;

end.
