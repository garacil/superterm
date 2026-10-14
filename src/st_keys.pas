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

const
  // modifiers as xterm numbers them: the parameter it sends is 1 + these
  KM_SHIFT = 1;
  KM_ALT = 2;
  KM_CTRL = 4;

type
  // One key exactly as the terminal reported it. A FreeVision key event
  // cannot say Shift+Up, Ctrl+Alt+Left or Alt+> -- it has one scancode per
  // physical key and keeps a modifier only where the PC keyboard had a code
  // for it -- so the keyboard driver keeps this beside every event it makes,
  // and the key the pane receives is built from this, not from the event.
  TKeyInfo = record
    // a named key as its plain FreeVision code: kbUp, kbF5, kbIns, kbEnter,
    // kbTab, kbBack, kbEsc ...; 0 for a character
    Key: word;
    Text: RawByteString;   // that character as typed, UTF-8
    Mods: byte;            // KM_*
  end;

// The bytes a terminal sends for AKey to a program in the given modes, the way
// tmux builds them (input-keys.c, input_key): a named key with modifiers as
// xterm's CSI 1;m / CSI n;m ~ forms; a character as itself, with Ctrl turning
// it into its C0 control and Alt adding an ESC in front; and, once the program
// has asked for modifyOtherKeys (AModifyOtherKeys 1 or 2), the modified keys
// a VT100 had no code for as CSI 27;m;code ~. Alt alone on a named key keeps
// the Meta convention -- ESC and then the key's own sequence -- which is what
// the programs reading it have always been given.
function EncodeKey(const AKey: TKeyInfo; AAppCursor: boolean;
  AModifyOtherKeys: integer): RawByteString;

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
    kbCtrlPgUp: Result := #27'[5;5~';
    kbCtrlPgDn: Result := #27'[6;5~';
    kbCtrlIns: Result := #27'[2;5~';
    kbCtrlDel: Result := #27'[3;5~';
    kbShiftDel: Result := #27'[3;2~';
  else
    if KeyCode and $00FF <> 0 then
      Result := AnsiChar(Chr(KeyCode and $00FF));
  end;
end;

function Utf8Codepoint(const S: RawByteString): cardinal;
var
  B0, Need, I: integer;
begin
  Result := 0;
  if S = '' then
    Exit;
  B0 := byte(S[1]);
  if B0 < $80 then
    Exit(B0)
  else if (B0 and $E0) = $C0 then
  begin
    Result := B0 and $1F;
    Need := 2;
  end
  else if (B0 and $F0) = $E0 then
  begin
    Result := B0 and $0F;
    Need := 3;
  end
  else if (B0 and $F8) = $F0 then
  begin
    Result := B0 and $07;
    Need := 4;
  end
  else
    Exit(0);
  if Length(S) <> Need then
    Exit(0);
  for I := 2 to Need do
  begin
    if (byte(S[I]) and $C0) <> $80 then
      Exit(0);
    Result := (Result shl 6) or (byte(S[I]) and $3F);
  end;
end;

function EncodeKey(const AKey: TKeyInfo; AAppCursor: boolean;
  AModifyOtherKeys: integer): RawByteString;
const
  // tmux's standard_map: Ctrl on these keys gives this byte, not a C0 code
  CTRL_FROM: RawByteString = '1!9(0)=+;:''",<.>/-8? 2';
  CTRL_TO: RawByteString = '119900=+;;'''',,..'#$1F#$1F#$7F#$7F#0#0;
var
  Mods: byte;
  M, Code: integer;
  Final: AnsiChar;
  Ch: AnsiChar;
  Cp: cardinal;
  P: integer;

  function Extended(ACode: cardinal): RawByteString;
  begin
    Result := #27'[27;' + IntToStr(1 + Mods) + ';' + IntToStr(ACode) + '~';
  end;

  // the VT100 form: Alt is an ESC in front, Ctrl a C0 code where there is
  // one; a modifier with no such form is simply lost, as it is on a VT100
  function Vt10x: RawByteString;
  begin
    Result := '';
    if (Mods and KM_ALT) <> 0 then
      Result := #27;
    if Cp > $7F then
      Exit(Result + AKey.Text);
    Ch := AnsiChar(Cp);
    // Ctrl never turns Tab or Enter into another key; on Backspace it gives
    // the other erase character, BS, as terminals send it
    if ((Mods and KM_CTRL) <> 0) and (Ch = #$7F) then
      Ch := #8
    else if ((Mods and KM_CTRL) <> 0) and (Ch <> #9) and (Ch <> #13) then
    begin
      P := Pos(Ch, CTRL_FROM);
      if P > 0 then
        Ch := CTRL_TO[P]
      else if (Ch >= '3') and (Ch <= '7') then
        Ch := AnsiChar(Ord(Ch) - $18)
      else if (Ch >= '@') and (Ch <= '~') then
        Ch := AnsiChar(Ord(Ch) and $1F)
      else
        Exit('');
    end;
    Result := Result + Ch;
  end;

  // modifyOtherKeys=1 leaves the keys a VT100 could already express alone:
  // Ctrl on its own over a key with a C0 code, and Alt on its own
  function Mode1Keeps: boolean;
  begin
    Ch := AnsiChar(Cp and $7F);
    if (Mods and (KM_ALT or KM_CTRL)) = KM_ALT then
      Exit(True);
    Result := ((Mods and (KM_ALT or KM_CTRL)) = KM_CTRL) and (Cp < $80) and
      ((Ch = ' ') or (Ch = '/') or ((Ch >= '2') and (Ch <= '8')) or
       ((Ch >= '@') and (Ch <= '~')));
  end;

begin
  Result := '';
  Mods := AKey.Mods and (KM_SHIFT or KM_ALT or KM_CTRL);
  M := 1 + Mods;
  Final := #0;
  Code := 0;
  case AKey.Key of
    kbUp: Final := 'A';
    kbDown: Final := 'B';
    kbRight: Final := 'C';
    kbLeft: Final := 'D';
    kbHome: Final := 'H';
    kbEnd: Final := 'F';
    kbF1: Final := 'P';
    kbF2: Final := 'Q';
    kbF3: Final := 'R';
    kbF4: Final := 'S';
    kbIns: Code := 2;
    kbDel: Code := 3;
    kbPgUp: Code := 5;
    kbPgDn: Code := 6;
    kbF5: Code := 15;
    kbF6: Code := 17;
    kbF7: Code := 18;
    kbF8: Code := 19;
    kbF9: Code := 20;
    kbF10: Code := 21;
    kbF11: Code := 23;
    kbF12: Code := 24;
  end;
  if (Final <> #0) or (Code <> 0) then
  begin
    if Mods = 0 then
      Result := TranslateKey(AKey.Key, AAppCursor)
    else if Mods = KM_ALT then
      Result := #27 + TranslateKey(AKey.Key, AAppCursor)
    else if Final <> #0 then
      Result := #27'[1;' + IntToStr(M) + Final
    else
      Result := #27'[' + IntToStr(Code) + ';' + IntToStr(M) + '~';
    Exit;
  end;
  // everything else is a character; these four keys are their C0 codes
  case AKey.Key of
    kbEnter: Cp := 13;
    kbTab: Cp := 9;
    kbBack: Cp := $7F;
    kbEsc: Cp := 27;
    0: Cp := Utf8Codepoint(AKey.Text);
  else
    Exit(TranslateKey(AKey.Key, AAppCursor));
  end;
  if (AKey.Key = 0) and (Cp = 0) and (AKey.Text <> '') then
  begin
    // not one whole character (a lone byte of a sequence the terminal sent
    // a byte at a time): it travels as it came
    if (Mods and KM_ALT) <> 0 then
      Result := #27;
    Exit(Result + AKey.Text);
  end;
  if (Cp = 9) and ((Mods and KM_SHIFT) <> 0) and (AModifyOtherKeys = 0) then
    Exit(#27'[Z');        // back-tab: the only Shift+Tab a VT100 has
  if Mods = 0 then
  begin
    if AKey.Key = 0 then
      Exit(AKey.Text);
    Exit(AnsiChar(Cp));
  end;
  case AModifyOtherKeys of
    2: Result := Extended(Cp);
    1:
      if Mode1Keeps then
        Result := Vt10x
      else
        Result := Extended(Cp);
  else
    Result := Vt10x;
  end;
end;

end.
