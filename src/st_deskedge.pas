(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_deskedge - dead area outside the canonical desktop: dithered shade
        ramp and the reverse-video label knocked out of it
*)

unit st_deskedge;

{$mode objfpc}{$H+}

(*
  The logical desktop is canonical and shared; a viewer whose terminal is
  larger than it has a leftover L-shaped band on the right and below. This
  unit decides what goes in that band and nothing else: it draws nothing,
  touches no view and knows no FreeVision type, so the geometry, the ramp and
  the font can be reasoned about (and tested) on their own.

  Two rules make up the whole appearance:

  * The ramp is a dissolve, not stripes and not a checkerboard. Distance from
    the desktop edge gives a continuous mix of the two neighbouring codes, and
    each cell decides which one it takes against its own threshold: half an
    8x8 ordered matrix, which keeps the minority code evenly spread, and half
    a hash of the cell's coordinates, which destroys the matrix's regularity.
    Ordered alone weaves a visible grid and at the midpoint collapses into a
    checkerboard; pure noise clumps. Half of each reads as cloud -- scattered,
    well distributed, no pattern to catch the eye -- and because the mix runs
    continuously with distance there is never a hard jump from a run of one
    code to a run of the next. The cell attribute never changes; only which
    of 178/177/176 lands where.

  * The label is reverse video and nothing else. Its strokes are cells left
    unpainted; the ramp runs through and around them untouched, and the holes
    are what form the letters. No plate, no frame, no local change of shade:
    the screen behind the word is the same screen as everywhere else. The
    word is set on a diagonal, and only ever at a step and a length that fit
    the band whole -- a half-drawn letter would read as corruption.
*)

interface

const
  // CP437 shade bytes, densest first: [0] hugs the desktop edge.
  EDGE_SHADES: array[0..2] of byte = (178, 177, 176);
  EDGE_SHADE_LEVELS = 3;
  // Sub-steps between two neighbouring codes; also the threshold range.
  EDGE_MIX = 256;
  // Ramp positions run 0 (solid densest) .. EDGE_MAX_POS (solid faintest).
  EDGE_MAX_POS = (EDGE_SHADE_LEVELS - 1) * EDGE_MIX;
  // Small and thick on purpose: a 5x5 block letter with two-cell stems keeps
  // its strokes readable when they are holes rather than ink.
  GLYPH_W = 5;
  GLYPH_H = 5;
  // Cells of screen kept clear around the word so it never touches the band
  // edge or the desktop.
  EDGE_LABEL_PAD = 1;

type
  TEdgeLabel = record
    Active: boolean;
    X, Y: LongInt;          // band-local top-left of the whole label box
    StepX, StepY: LongInt;  // per-glyph advance; a non-zero StepY is the angle
    BoxW, BoxH: LongInt;    // cheap rejection before touching the font
    Text: string;           // already normalised to A..Z and spaces
  end;

// Ramp position 0..EDGE_MAX_POS for a cell ADist cells (1-based) past the
// desktop edge of a band ADepth cells deep. Both ends are exact: the cell
// against the desktop is always the solid densest shade and the outermost one
// the solid faintest, whatever the depth.
function EdgeShadePos(ADist, ADepth: LongInt): LongInt;

// The CP437 byte for a ramp position at one cell. The threshold is keyed on
// the cell coordinates, so the cloud belongs to the position on the desktop
// rather than crawling when the view moves.
function EdgeShadeByte(APos, AX, AY: LongInt): byte;

// Largest label that fits AWidth x AHeight. ATexts is tried in order, so pass
// the wording from longest to shortest. Returns Active=False when none of them
// fits; the caller then screens the band without a word in it.
function PlaceEdgeLabel(AWidth, AHeight: LongInt;
  const ATexts: array of string): TEdgeLabel;

// True when the band-local cell is a letter stroke, i.e. must be left
// unpainted so the screen around it forms the glyph.
function EdgeLabelCovers(const ALabel: TEdgeLabel; AX, AY: LongInt): boolean;

implementation

const
  // 8x8 ordered matrix, 0..63, scaled to the 0..255 threshold range and then
  // averaged with the per-cell hash.
  BAYER8: array[0..7, 0..7] of byte = (
    ( 0, 32,  8, 40,  2, 34, 10, 42),
    (48, 16, 56, 24, 50, 18, 58, 26),
    (12, 44,  4, 36, 14, 46,  6, 38),
    (60, 28, 52, 20, 62, 30, 54, 22),
    ( 3, 35, 11, 43,  1, 33,  9, 41),
    (51, 19, 59, 27, 49, 17, 57, 25),
    (15, 47,  7, 39, 13, 45,  5, 37),
    (63, 31, 55, 23, 61, 29, 53, 21));

  // 5x5 block font, one byte per row, bit 4 = leftmost column. Stems are two
  // cells wide wherever the width allows it. Only A..Z is needed: the labels
  // are uppercase, and unaccented Spanish is already the convention for
  // chrome text elsewhere in the interface.
  FONT: array['A'..'Z', 0..GLYPH_H - 1] of byte = (
    ($0E, $1B, $1F, $1B, $1B),   // A
    ($1E, $1B, $1E, $1B, $1E),   // B
    ($0F, $18, $18, $18, $0F),   // C
    ($1E, $1B, $1B, $1B, $1E),   // D
    ($1F, $18, $1E, $18, $1F),   // E
    ($1F, $18, $1E, $18, $18),   // F
    ($0F, $18, $1B, $1B, $0F),   // G
    ($1B, $1B, $1F, $1B, $1B),   // H
    ($1F, $0E, $0E, $0E, $1F),   // I
    ($0F, $06, $06, $1E, $0C),   // J
    ($1B, $1E, $1C, $1E, $1B),   // K
    ($18, $18, $18, $18, $1F),   // L
    ($1B, $1F, $1B, $1B, $1B),   // M
    ($1B, $1D, $1F, $17, $1B),   // N
    ($0E, $1B, $1B, $1B, $0E),   // O
    ($1E, $1B, $1E, $18, $18),   // P
    ($0E, $1B, $1B, $1A, $0F),   // Q
    ($1E, $1B, $1E, $1C, $1B),   // R
    ($0F, $18, $0E, $03, $1E),   // S
    ($1F, $0E, $0E, $0E, $0E),   // T
    ($1B, $1B, $1B, $1B, $0E),   // U
    ($1B, $1B, $1B, $0E, $04),   // V
    ($1B, $1B, $1B, $1F, $1B),   // W
    ($1B, $0E, $0E, $0E, $1B),   // X
    ($1B, $1B, $0E, $0E, $0E),   // Y
    ($1F, $07, $0E, $1C, $1F));  // Z

  // Per-glyph advance, in visual preference order. The first three lay the
  // word out left to right (45-ish, shallow, flat) for a wide band; the last
  // three stack it downward for a narrow tall one. A cell aspect of about
  // 1:2 makes six columns per three rows read as a diagonal.
  STEPS: array[0..5, 0..1] of LongInt =
    ((6, 3), (6, 1), (6, 0), (2, 6), (1, 6), (0, 6));

function EdgeShadePos(ADist, ADepth: LongInt): LongInt;
begin
  if ADist < 1 then
    ADist := 1;
  if ADepth < 2 then
  begin
    // A one-cell band is the desktop edge itself: no room for a ramp.
    EdgeShadePos := 0;
    Exit;
  end;
  if ADist > ADepth then
    ADist := ADepth;
  EdgeShadePos := ((ADist - 1) * EDGE_MAX_POS) div (ADepth - 1);
  if EdgeShadePos > EDGE_MAX_POS then
    EdgeShadePos := EDGE_MAX_POS;
end;

// One byte of hash per cell: stable for a given position on the desktop, and
// with no structure of its own for the eye to lock on to.
function CellNoise(AX, AY: LongInt): LongInt;
var
  H: LongWord;
begin
  H := LongWord(AX) * 374761393 + LongWord(AY) * 668265263;
  H := (H xor (H shr 13)) * 1274126177;
  CellNoise := LongInt((H xor (H shr 16)) and $FF);
end;

function EdgeShadeByte(APos, AX, AY: LongInt): byte;
var
  Index, Frac, Threshold: LongInt;
begin
  if APos < 0 then
    APos := 0;
  if APos > EDGE_MAX_POS then
    APos := EDGE_MAX_POS;
  Index := APos div EDGE_MIX;
  Frac := APos mod EDGE_MIX;
  if Frac > 0 then
  begin
    Threshold := (BAYER8[AY and 7, AX and 7] * 4 + CellNoise(AX, AY)) div 2;
    if Frac > Threshold then
      Inc(Index);
  end;
  if Index > EDGE_SHADE_LEVELS - 1 then
    Index := EDGE_SHADE_LEVELS - 1;
  EdgeShadeByte := EDGE_SHADES[Index];
end;

// Uppercase, and reduce anything the font does not carry to a blank glyph.
// The label keeps its length either way, so the layout never shifts.
function NormalizeLabel(const AText: string): string;
var
  I: LongInt;
  C: char;
begin
  Result := AText;
  for I := 1 to Length(Result) do
  begin
    C := UpCase(Result[I]);
    if (C < 'A') or (C > 'Z') then
      C := ' ';
    Result[I] := C;
  end;
end;

function TryPlace(AWidth, AHeight: LongInt; const AText: string;
  out ALabel: TEdgeLabel): boolean;
var
  Count, I, W, H: LongInt;
begin
  Result := False;
  ALabel := Default(TEdgeLabel);
  Count := Length(AText);
  if (Count < 1) or (AWidth < GLYPH_W) or (AHeight < GLYPH_H) then
    Exit;
  for I := Low(STEPS) to High(STEPS) do
  begin
    W := (Count - 1) * STEPS[I][0] + GLYPH_W;
    H := (Count - 1) * STEPS[I][1] + GLYPH_H;
    if (W > AWidth) or (H > AHeight) then
      Continue;
    ALabel.Active := True;
    ALabel.StepX := STEPS[I][0];
    ALabel.StepY := STEPS[I][1];
    ALabel.BoxW := W;
    ALabel.BoxH := H;
    ALabel.X := (AWidth - W) div 2;
    ALabel.Y := (AHeight - H) div 2;
    ALabel.Text := AText;
    Exit(True);
  end;
end;

function PlaceEdgeLabel(AWidth, AHeight: LongInt;
  const ATexts: array of string): TEdgeLabel;
var
  I: LongInt;
begin
  AWidth := AWidth - 2 * EDGE_LABEL_PAD;
  AHeight := AHeight - 2 * EDGE_LABEL_PAD;
  for I := Low(ATexts) to High(ATexts) do
    if TryPlace(AWidth, AHeight, NormalizeLabel(ATexts[I]), Result) then
    begin
      Inc(Result.X, EDGE_LABEL_PAD);
      Inc(Result.Y, EDGE_LABEL_PAD);
      Exit;
    end;
  Result := Default(TEdgeLabel);
end;

function EdgeLabelCovers(const ALabel: TEdgeLabel; AX, AY: LongInt): boolean;
var
  I, Col, Row: LongInt;
  C: char;
begin
  Result := False;
  if not ALabel.Active then
    Exit;
  // Whole-box rejection first: most cells of a band are nowhere near the
  // word, and they must not pay for a walk over every glyph.
  if (AX < ALabel.X) or (AX >= ALabel.X + ALabel.BoxW) or
     (AY < ALabel.Y) or (AY >= ALabel.Y + ALabel.BoxH) then
    Exit;
  for I := 1 to Length(ALabel.Text) do
  begin
    C := ALabel.Text[I];
    if (C < 'A') or (C > 'Z') then
      Continue;
    Col := AX - (ALabel.X + (I - 1) * ALabel.StepX);
    Row := AY - (ALabel.Y + (I - 1) * ALabel.StepY);
    if (Col < 0) or (Col >= GLYPH_W) or (Row < 0) or (Row >= GLYPH_H) then
      Continue;
    if (FONT[C][Row] and (1 shl (GLYPH_W - 1 - Col))) <> 0 then
      Exit(True);
  end;
end;

end.
