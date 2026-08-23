(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_clipboard - client-local clipboard history and OSC 52 helpers
*)

unit st_clipboard;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, base64;

const
  CLIPBOARD_HISTORY_LIMIT = 10;
  // Leave room for the two six-byte bracketed-paste delimiters when the
  // destination pane has DECSET 2004 enabled (TPty caps pending input at 1M).
  CLIPBOARD_MAX_BYTES = 1024 * 1024 - 16;

type
  TClipboardOrigin = (coPaneSelection, coHostPaste, coRemoteOsc52);

  TClipboardItem = record
    Text: RawByteString;
    Origin: TClipboardOrigin;
    PaneTitle: string;
  end;

  TClipboardItemArray = array of TClipboardItem;

  TClipboardHistory = class
  private
    FItems: TClipboardItemArray;
  public
    function Add(const AText: RawByteString; AOrigin: TClipboardOrigin;
      const APaneTitle: string): boolean;
    procedure Clear;
    function Count: integer;
    function Item(AIndex: integer): TClipboardItem;
    function Latest: RawByteString;
    function Preview(AIndex, AMaxLen: integer): string;
  end;

function ClipboardOriginLabel(AOrigin: TClipboardOrigin): string;
function EncodeOsc52(const AText: RawByteString): RawByteString;
function DecodeOsc52(const APayload: RawByteString;
  out AText: RawByteString): boolean;

implementation

function TClipboardHistory.Add(const AText: RawByteString;
  AOrigin: TClipboardOrigin; const APaneTitle: string): boolean;
var
  I, J, N: integer;
  NewItem: TClipboardItem;
begin
  Result := False;
  if (AText = '') or (Length(AText) > CLIPBOARD_MAX_BYTES) then
    Exit;

  NewItem.Text := AText;
  NewItem.Origin := AOrigin;
  NewItem.PaneTitle := APaneTitle;

  // An identical item becomes the newest one instead of consuming another
  // history slot. Its source metadata is refreshed as part of the move.
  I := -1;
  for J := 0 to High(FItems) do
    if FItems[J].Text = AText then
    begin
      I := J;
      Break;
    end;
  if I >= 0 then
  begin
    for J := I downto 1 do
      FItems[J] := FItems[J - 1];
    FItems[0] := NewItem;
    Exit(True);
  end;

  N := Length(FItems);
  if N < CLIPBOARD_HISTORY_LIMIT then
    SetLength(FItems, N + 1)
  else
    N := CLIPBOARD_HISTORY_LIMIT - 1;
  for J := N downto 1 do
    FItems[J] := FItems[J - 1];
  FItems[0] := NewItem;
  Result := True;
end;

procedure TClipboardHistory.Clear;
begin
  FItems := nil;
end;

function TClipboardHistory.Count: integer;
begin
  Result := Length(FItems);
end;

function TClipboardHistory.Item(AIndex: integer): TClipboardItem;
begin
  Result := Default(TClipboardItem);
  if (AIndex >= 0) and (AIndex < Length(FItems)) then
    Result := FItems[AIndex];
end;

function TClipboardHistory.Latest: RawByteString;
begin
  if Length(FItems) > 0 then
    Result := FItems[0].Text
  else
    Result := '';
end;

function TClipboardHistory.Preview(AIndex, AMaxLen: integer): string;
var
  S: RawByteString;
  I: integer;
  C: byte;
begin
  Result := '';
  if (AIndex < 0) or (AIndex >= Length(FItems)) or (AMaxLen < 1) then
    Exit;
  S := FItems[AIndex].Text;
  I := 1;
  while (I <= Length(S)) and (Length(Result) < AMaxLen) do
  begin
    C := byte(S[I]);
    case C of
      9: Result := Result + ' ';
      10, 13:
        begin
          if (Result <> '') and (Result[Length(Result)] <> ' ') then
            Result := Result + ' ';
        end;
      32..126: Result := Result + AnsiChar(C);
    else
      // FreeVision's dialog chrome is CP437, so keep arbitrary UTF-8 bytes
      // out of labels. The original item remains byte-for-byte intact.
      if (C and $C0) <> $80 then
        Result := Result + '?';
    end;
    Inc(I);
  end;
  Result := Trim(Result);
  if I <= Length(S) then
  begin
    if AMaxLen <= 3 then
      SetLength(Result, AMaxLen)
    else
    begin
      if Length(Result) > AMaxLen - 3 then
        SetLength(Result, AMaxLen - 3);
      Result := Result + '...';
    end;
  end;
end;

function ClipboardOriginLabel(AOrigin: TClipboardOrigin): string;
begin
  case AOrigin of
    coPaneSelection: Result := 'pane';
    coHostPaste: Result := 'host';
    coRemoteOsc52: Result := 'OSC52';
  else
    Result := '';
  end;
end;

function EncodeOsc52(const AText: RawByteString): RawByteString;
begin
  Result := '';
  if (AText = '') or (Length(AText) > CLIPBOARD_MAX_BYTES) then
    Exit;
  Result := #27']52;c;' + EncodeStringBase64(AText) + #7;
end;

function DecodeOsc52(const APayload: RawByteString;
  out AText: RawByteString): boolean;
begin
  Result := False;
  AText := '';
  if (APayload = '') or (APayload = '?') or
     (Length(APayload) > ((CLIPBOARD_MAX_BYTES + 2) div 3) * 4 + 4) then
    Exit;
  try
    AText := DecodeStringBase64(APayload, True);
    Result := (AText <> '') and (Length(AText) <= CLIPBOARD_MAX_BYTES);
  except
    AText := '';
    Result := False;
  end;
end;

end.
