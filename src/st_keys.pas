(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_keys - translation of FreeVision keycodes to terminal sequences
*)

unit st_keys;

{$mode objfpc}{$H+}

interface

uses
  Drivers;

function TranslateKey(KeyCode: word): RawByteString;

implementation

function TranslateKey(KeyCode: word): RawByteString;
begin
  Result := '';
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
