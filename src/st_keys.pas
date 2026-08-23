(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_keys - translation of FreeVision keycodes to terminal sequences
*)

unit st_keys;

{$mode objfpc}{$H+}

interface

uses
  Drivers, st_screen;

const
  // xterm button numbers as they travel in a mouse report
  MB_LEFT = 0;
  MB_MIDDLE = 1;
  MB_RIGHT = 2;
  MB_NONE = 3;          // X10 "release", and "no button" in a motion report
  MB_WHEEL_UP = 64;
  MB_WHEEL_DOWN = 65;
  MB_MOTION = 32;       // added to the button of a motion report

// One mouse report in the encoding the application asked for. ACol/ARow are
// 1-based pane cells. Returns '' when the protocol cannot express the
// position (X10 stops at 223), which is what xterm does too.
function EncodeMouseReport(AProto: TMouseProto; AButton, ACol, ARow: integer;
  APress: boolean): RawByteString;

// AAppCursor: the pane is in DECCKM (application cursor keys) mode, which
// every curses program sets; the cursor keys then go out as SS3 (ESC O A)
// and the CSI form (ESC [ A) is ignored by the application.
function TranslateKey(KeyCode: word; AAppCursor: boolean = False): RawByteString;

implementation

uses
  SysUtils;

function EncodeMouseReport(AProto: TMouseProto; AButton, ACol, ARow: integer;
  APress: boolean): RawByteString;
var
  B: integer;
begin
  Result := '';
  if (ACol < 1) or (ARow < 1) then
    Exit;
  case AProto of
    mpSGR, mpPixel:
      begin
        // SGR keeps the button on release and says 'm' instead of 'M'.
        // ?1016 wants pixels; cells are the best a cell grid can offer.
        Result := #27'[<' + IntToStr(AButton) + ';' + IntToStr(ACol) + ';' +
          IntToStr(ARow);
        if APress then Result := Result + 'M' else Result := Result + 'm';
      end;
    mpUrxvt:
      begin
        B := AButton;
        if not APress then B := (B and not 3) or MB_NONE;
        Result := #27'[' + IntToStr(B + 32) + ';' + IntToStr(ACol) + ';' +
          IntToStr(ARow) + 'M';
      end;
  else
    // X10 and its UTF-8 variant: three bytes, coordinates offset by 32
    if (ACol > 223) or (ARow > 223) then
      Exit;
    B := AButton;
    if not APress then B := (B and not 3) or MB_NONE;
    Result := #27'[M' + AnsiChar(Chr(B + 32)) + AnsiChar(Chr(ACol + 32)) +
      AnsiChar(Chr(ARow + 32));
  end;
end;

function TranslateKey(KeyCode: word; AAppCursor: boolean): RawByteString;
begin
  Result := '';
  if AAppCursor then
    case KeyCode of
      kbUp: Exit(#27'OA');
      kbDown: Exit(#27'OB');
      kbRight: Exit(#27'OC');
      kbLeft: Exit(#27'OD');
      kbHome: Exit(#27'OH');
      kbEnd: Exit(#27'OF');
    end;
  case KeyCode of
    kbUp: Result := #27'[A';
    kbDown: Result := #27'[B';
    kbRight: Result := #27'[C';
    kbLeft: Result := #27'[D';
    kbHome: Result := #27'[H';
    kbEnd: Result := #27'[F';
    kbPgUp: Result := #27'[5~';
    kbPgDn: Result := #27'[6~';
    kbIns: Result := #27'[2~';
    kbDel: Result := #27'[3~';
    kbBack: Result := #127;
    kbEnter: Result := #13;
    kbTab: Result := #9;
    kbShiftTab: Result := #27'[Z';
    kbF1: Result := #27'OP';
    kbF2: Result := #27'OQ';
    kbF3: Result := #27'OR';
    kbF4: Result := #27'OS';
    kbF5: Result := #27'[15~';
    kbF6: Result := #27'[17~';
    kbF7: Result := #27'[18~';
    kbF8: Result := #27'[19~';
    kbF9: Result := #27'[20~';
    kbF10: Result := #27'[21~';
    kbF11: Result := #27'[23~';
    kbF12: Result := #27'[24~';
    kbCtrlLeft: Result := #27'[1;5D';
    kbCtrlRight: Result := #27'[1;5C';
    kbCtrlUp: Result := #27'[1;5A';
    kbCtrlDown: Result := #27'[1;5B';
    kbCtrlHome: Result := #27'[1;5H';
    kbCtrlEnd: Result := #27'[1;5F';
    kbCtrlDel: Result := #27'[3;5~';
    kbShiftDel: Result := #27'[3;2~';
  else
    if KeyCode and $00FF <> 0 then
      Result := AnsiChar(Chr(KeyCode and $00FF));
  end;
end;

end.
