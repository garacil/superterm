(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_kbd - custom keyboard driver with ESC timeout

  The RTL unix driver treats ESC as an Alt prefix: after a lone ESC
  SysGetKeyEvent calls ReadKey again, which BLOCKS in a select with no
  timeout until the next key and delivers it as Alt+key even if seconds
  go by. Result: a plain Esc never reaches the application. This driver
  decodes the raw stdin stream with a short timeout: if nothing arrives
  after an ESC within ESC_TIMEOUT_MS a real kbEsc is delivered. It also
  decodes CSI/SS3 (arrows, F1..F12, Home/End, etc.), Alt+key and the two
  mouse protocols (X10 and SGR 1006) the RTL handled, delivering the
  events through the same queues (PutKeyEvent/PutMouseEvent) consumed by
  the vendor FreeVision. It is installed with Keyboard.SetKeyboardDriver
  BEFORE the application calls InitKeyboard.
*)

unit st_kbd;

{$mode objfpc}{$H+}

interface

// install before creating the application (before Keyboard.InitKeyboard)
procedure InstallSuperKeyboard;
// CaptureConsoleCursor issues CSI 6 n before the keyboard driver starts. A
// slow host may answer only after startup; arm one expiring CPR so CSI r;c R
// is consumed as a terminal reply rather than decoded as CSI-F3.
procedure ArmCursorPositionReply;
procedure CompleteCursorPositionReply;
// Bracketed paste arrives as one payload instead of thousands of unrelated
// key events. The application drains this queue from Idle and routes each
// item to the focused pane.
function TakeHostPaste(out AText: RawByteString): boolean;

implementation

uses
  SysUtils, Keyboard, Mouse, Drivers
  {$IFDEF UNIX}, BaseUnix, Termio{$ENDIF}
  {$IFDEF WINDOWS}, Windows{$ENDIF};

const
  ESC_TIMEOUT_MS = 50;   // lone ESC: margin to tell it apart from sequences
  SEQ_TIMEOUT_MS = 120;  // middle bytes of an already started sequence
  PASTE_TIMEOUT_MS = 2000;
  MAX_HOST_PASTE = 1024 * 1024 - 16;
  HOST_PASTE_QUEUE = 8;

// The RTL's mouse queue is allocated by Mouse.InitMouse, which FreeVision
// only calls when it believes a mouse exists (Drivers.InitEvents, gated on
// ButtonCount). On a terminal the RTL does not recognise -- alacritty, foot,
// wezterm, st-256color -- ButtonCount stays 0, the queue's head and tail
// pointers stay nil, and PutMouseEvent writes straight through a nil pointer.
// Reports can still arrive there: any program that left tracking enabled on
// this tty is enough. Drop them instead of dying.
procedure QueueMouse(const AEvent: TMouseEvent);
begin
  if ButtonCount = 0 then
    Exit;
  PutMouseEvent(AEvent);
end;

var
  {$IFDEF UNIX}
  SavedTio: termios;
  TioSaved: boolean = False;
  {$ENDIF}
  {$IFDEF WINDOWS}
  SavedInputMode: DWORD = 0;
  SavedInputCP: UINT = 0;
  InputModeSaved: boolean = False;
  InputCPSaved: boolean = False;
  {$ENDIF}
  RBuf: array[0..1023] of byte;
  RHead: integer = 0;
  RTail: integer = 0;
  PendingEscape: boolean = False;
  LastMouse: TMouseEvent;
  PasteQueue: array[0..HOST_PASTE_QUEUE - 1] of RawByteString;
  PasteHead: integer = 0;
  PasteTail: integer = 0;
  CursorReplyDeadline: QWord = 0;

procedure ArmCursorPositionReply;
begin
  CursorReplyDeadline := GetTickCount64 + 1500;
end;

procedure CompleteCursorPositionReply;
begin
  CursorReplyDeadline := 0;
end;

procedure QueueHostPaste(const AText: RawByteString);
var
  Next: integer;
begin
  Next := (PasteHead + 1) mod HOST_PASTE_QUEUE;
  if Next = PasteTail then
    PasteTail := (PasteTail + 1) mod HOST_PASTE_QUEUE;
  PasteQueue[PasteHead] := AText;
  PasteHead := Next;
end;

function TakeHostPaste(out AText: RawByteString): boolean;
begin
  Result := PasteTail <> PasteHead;
  if not Result then
  begin
    AText := '';
    Exit;
  end;
  AText := PasteQueue[PasteTail];
  PasteQueue[PasteTail] := '';
  PasteTail := (PasteTail + 1) mod HOST_PASTE_QUEUE;
end;

// waits up to TimeoutMs (negative = forever) for bytes in the buffer
function FillBuf(TimeoutMs: integer): boolean;
type
  TReadChunk = array[0..255] of byte;
var
  {$IFDEF UNIX}
  fds: TFDSet;
  n: cint;
  {$ENDIF}
  {$IFDEF WINDOWS}
  HIn: THandle;
  WaitMs, WaitResult, Got: DWORD;
  {$ENDIF}
  tmp: TReadChunk;
  r: integer;
  i: integer;
begin
  if RHead <> RTail then
    Exit(True);
  tmp := Default(TReadChunk);
  {$IFDEF WINDOWS}
  HIn := GetStdHandle(STD_INPUT_HANDLE);
  if (HIn = 0) or (HIn = INVALID_HANDLE_VALUE) then
    Exit(False);
  if TimeoutMs < 0 then
    WaitMs := INFINITE
  else
    WaitMs := DWORD(TimeoutMs);
  WaitResult := WaitForSingleObject(HIn, WaitMs);
  if WaitResult <> WAIT_OBJECT_0 then
    Exit(False);
  Got := 0;
  if not ReadFile(HIn, tmp[0], SizeOf(tmp), Got, nil) then
    Exit(False);
  r := integer(Got);
  {$ELSE}
  fpFD_ZERO(fds);
  fpFD_SET(0, fds);
  if TimeoutMs < 0 then
    n := fpSelect(1, @fds, nil, nil, nil)
  else
    n := fpSelect(1, @fds, nil, nil, TimeoutMs);
  if n <= 0 then
    Exit(False);
  r := FileRead(0, tmp, SizeOf(tmp)); // FileRead retries EINTR
  {$ENDIF}
  if r <= 0 then
    Exit(False);
  for i := 0 to r - 1 do
  begin
    RBuf[RHead] := tmp[i];
    RHead := (RHead + 1) mod Length(RBuf);
  end;
  Result := RHead <> RTail;
end;

function NextByte(TimeoutMs: integer): integer;
begin
  if not FillBuf(TimeoutMs) then
    Exit(-1);
  Result := RBuf[RTail];
  RTail := (RTail + 1) mod Length(RBuf);
end;

function PeekByte(TimeoutMs: integer): integer;
begin
  if not FillBuf(TimeoutMs) then
    Exit(-1);
  Result := RBuf[RTail];
end;

// PC scancode of an ASCII byte (same table as the RTL unix driver)
function EvalScan(b: byte): byte;
const
  DScan: array[0..31] of byte = (
    $39, $02, $28, $04, $05, $06, $08, $28,
    $0A, $0B, $09, $0D, $33, $0C, $34, $35,
    $0B, $02, $03, $04, $05, $06, $07, $08,
    $09, $0A, $27, $27, $33, $0D, $34, $35);
  LScan: array[0..31] of byte = (
    $29, $1E, $30, $2E, $20, $12, $21, $22,
    $23, $17, $24, $25, $26, $32, $31, $18,
    $19, $10, $13, $1F, $14, $16, $2F, $11,
    $2D, $15, $2C, $1A, $2B, $1B, $29, $0C);
begin
  if (b and $E0) = $20 then
    Result := DScan[b and $1F]
  else
    case b of
      $08: Result := $0E;
      $09: Result := $0F;
      $0D: Result := $1C;
      $1B: Result := $01;
      $40: Result := $03;
      $5E: Result := $07;
      $60: Result := $29;
    else
      Result := LScan[b and $1F];
    end;
end;

function KEv(ch: AnsiChar; scan: byte; state: byte): TKeyEvent;
begin
  Result := $03000000 or TKeyEvent(Ord(ch)) or (TKeyEvent(scan) shl 8) or
    (TKeyEvent(state) shl 16);
end;

// navigation key scancode according to modifiers (RTL tables)
function NavEvent(PlainScan, CtrlScan, AltScan: byte; Mods: integer): TKeyEvent;
var
  state: byte;
begin
  state := 0;
  if (Mods and 1) <> 0 then
    state := state or kbShift;
  if (Mods and 4) <> 0 then
    Result := KEv(#0, CtrlScan, state or kbCtrl)
  else if (Mods and 2) <> 0 then
    Result := KEv(#0, AltScan, state or kbAlt)
  else
    Result := KEv(#0, PlainScan, state);
end;

// F1..F12 with modifiers (same scancodes as the RTL's keyscan.inc)
function FKeyEvent(NumKey, Mods: integer): TKeyEvent;
const
  BASE: array[1..12] of byte = (
    $3B, $3C, $3D, $3E, $3F, $40, $41, $42, $43, $44, $85, $86);
var
  scan: byte;
  state: byte;
begin
  if (NumKey < 1) or (NumKey > 12) then
    Exit(0);
  scan := BASE[NumKey];
  state := 0;
  if (Mods and 4) <> 0 then
  begin
    state := kbCtrl;
    if NumKey <= 10 then
      scan := scan + $23   // kbCtrlF1 - kbF1
    else
      scan := scan + $04;  // kbCtrlF11 - kbF11
  end
  else if (Mods and 2) <> 0 then
  begin
    state := kbAlt;
    if NumKey <= 10 then
      scan := scan + $2D   // kbAltF1 - kbF1
    else
      scan := scan + $06;  // kbAltF11 - kbF11
  end
  else if (Mods and 1) <> 0 then
  begin
    state := kbShift;
    if NumKey <= 10 then
      scan := scan + $19   // kbShiftF1 - kbF1
    else
      scan := scan + $02;  // kbShiftF11 - kbF11
  end;
  Result := KEv(#0, scan, state);
end;

// X10 mouse: ESC [ M b x y (byte-32-1 coordinates); same logic as the RTL
procedure MouseX10;
var
  b, x, y: integer;
  Ev: TMouseEvent;
begin
  b := NextByte(SEQ_TIMEOUT_MS);
  x := NextByte(SEQ_TIMEOUT_MS);
  y := NextByte(SEQ_TIMEOUT_MS);
  if (b < 0) or (x < 0) or (y < 0) then
    Exit;
  Ev := Default(TMouseEvent);
  case (b - 32) and 67 of
    0: Ev.Buttons := 1;
    1: Ev.Buttons := 4;   // middle (RTL: 4)
    2: Ev.Buttons := 2;   // right (RTL: 2)
    3: Ev.Buttons := 0;
    64: Ev.Buttons := 8;
    65: Ev.Buttons := 16;
  end;
  Ev.X := x - 33;
  Ev.Y := y - 33;
  Ev.Action := MouseActionMove;
  if (LastMouse.Buttons = 0) and (Ev.Buttons <> 0) then
    Ev.Action := MouseActionDown;
  if (LastMouse.Buttons <> 0) and (Ev.Buttons = 0) then
    Ev.Action := MouseActionUp;
  QueueMouse(Ev);
  if (Ev.Buttons and (8 + 16)) <> 0 then
  begin
    // the wheel sends no release event in X10: fabricate it
    LastMouse := Ev;
    Ev.Action := MouseActionUp;
    Ev.Buttons := 0;
    QueueMouse(Ev);
  end;
  LastMouse := Ev;
end;

// SGR 1006 mouse: ESC [ < btn ; x ; y M/m ('M' press, 'm' release)
procedure MouseSGR;
var
  nums: array[0..2] of integer;
  idx, c: integer;
  press: boolean;
  Ev: TMouseEvent;
  mask: word;
begin
  nums[0] := 0;
  nums[1] := 0;
  nums[2] := 0;
  idx := 0;
  repeat
    c := NextByte(SEQ_TIMEOUT_MS);
    if c < 0 then
      Exit;
    if (c >= Ord('0')) and (c <= Ord('9')) then
      nums[idx] := nums[idx] * 10 + (c - Ord('0'))
    else if c = Ord(';') then
    begin
      if idx >= 2 then
        Exit;
      Inc(idx);
    end
    else if (c = Ord('M')) or (c = Ord('m')) then
      break
    else
      Exit;
  until False;
  press := c = Ord('M');
  if (idx <> 2) or (nums[1] < 1) or (nums[2] < 1) or
     (nums[1] > High(Ev.X) + 1) or (nums[2] > High(Ev.Y) + 1) then
    Exit;
  Ev := Default(TMouseEvent);
  Ev.X := nums[1] - 1;
  Ev.Y := nums[2] - 1;
  mask := 0;
  if (nums[0] and 32) <> 0 then
  begin
    Ev.Action := MouseActionMove;
    Ev.Buttons := LastMouse.Buttons;
  end
  else
  begin
    case nums[0] and 67 of
      0: mask := 1;
      1: mask := 4;   // middle (RTL: 4)
      2: mask := 2;   // right (RTL: 2)
      64: mask := 8;
      65: mask := 16;
    end;
    if press then
    begin
      Ev.Action := MouseActionDown;
      Ev.Buttons := LastMouse.Buttons or mask;
    end
    else
    begin
      Ev.Action := MouseActionUp;
      Ev.Buttons := LastMouse.Buttons and not mask;
    end;
  end;
  QueueMouse(Ev);
  LastMouse := Ev;
  if press and ((mask and (8 + 16)) <> 0) then
  begin
    // wheel: fabricate the release in SGR too to not leave stuck buttons
    Ev.Action := MouseActionUp;
    Ev.Buttons := LastMouse.Buttons and not mask;
    QueueMouse(Ev);
    LastMouse := Ev;
  end;
end;

// We have already consumed CSI 200~. Read through the matching CSI 201~ and
// keep its contents byte-for-byte. A bounded queue and payload cap prevent a
// hostile or broken terminal from growing memory without limit.
procedure CaptureBracketedPaste;
const
  Terminator: RawByteString = #27'[201~';
var
  S: RawByteString;
  B, Match, I, Used, Capacity, NewCapacity: integer;
  Overflow, Complete: boolean;

  procedure AppendByte(AB: byte);
  begin
    if Used >= MAX_HOST_PASTE then
    begin
      Overflow := True;
      Exit;
    end;
    if Used = Capacity then
    begin
      if Capacity = 0 then NewCapacity := 4096
      else NewCapacity := Capacity * 2;
      if NewCapacity > MAX_HOST_PASTE then NewCapacity := MAX_HOST_PASTE;
      Capacity := NewCapacity;
      SetLength(S, Capacity);
    end;
    Inc(Used);
    S[Used] := AnsiChar(AB);
  end;

begin
  S := '';
  Used := 0;
  Capacity := 0;
  Match := 0;
  Overflow := False;
  Complete := False;
  repeat
    B := NextByte(PASTE_TIMEOUT_MS);
    if B < 0 then
      Break;
    if B = byte(Terminator[Match + 1]) then
    begin
      Inc(Match);
      if Match = Length(Terminator) then
      begin
        Complete := True;
        Break;
      end;
      Continue;
    end;
    if Match > 0 then
    begin
      for I := 1 to Match do
        AppendByte(byte(Terminator[I]));
      Match := 0;
      if B = byte(Terminator[1]) then
      begin
        Match := 1;
        Continue;
      end;
    end;
    AppendByte(B);
  until False;
  if Complete and (not Overflow) then
  begin
    SetLength(S, Used);
    QueueHostPaste(S);
  end;
end;

// ESC [ params final -- 0 if the sequence is consumed with no key;
// ExtraMods is added to the xterm modifiers (2 = Alt via meta prefix)
function DecodeCSI(ExtraMods: integer): TKeyEvent;
var
  c, p1, p2, idx: integer;
  nums: array[0..3] of integer;
  seen: array[0..3] of boolean;
  i: integer;
begin
  Result := 0;
  for i := 0 to 3 do
  begin
    nums[i] := 0;
    seen[i] := False;
  end;
  idx := 0;
  c := NextByte(SEQ_TIMEOUT_MS);
  if c < 0 then
    Exit;
  if c = Ord('<') then
  begin
    MouseSGR;
    Exit;
  end;
  if c = Ord('M') then
  begin
    MouseX10;
    Exit;
  end;
  while (c >= Ord('0')) and (c <= Ord('9')) or (c = Ord(';')) do
  begin
    if c = Ord(';') then
    begin
      if idx < High(nums) then
        Inc(idx);
    end
    else
    begin
      nums[idx] := nums[idx] * 10 + (c - Ord('0'));
      seen[idx] := True;
    end;
    c := NextByte(SEQ_TIMEOUT_MS);
    if c < 0 then
      Exit;
  end;
  if seen[0] then
    p1 := nums[0]
  else
    p1 := 1;
  if seen[1] then
    p2 := nums[1]
  else
    p2 := 1;
  Dec(p2); // xterm modifier bits: 1=shift 2=alt 4=ctrl
  p2 := p2 or ExtraMods;
  // 'R' is also CSI-F3, hence the explicit pending query state. Do not infer
  // CPR from numeric ranges: row 1/column 2 is byte-for-byte identical to a
  // modified CSI F3 on some terminals. Only a DSR we actually emitted arms
  // this one-shot swallow, and it expires shortly after startup.
  if (AnsiChar(c) = 'R') and (CursorReplyDeadline <> 0) then
  begin
    if GetTickCount64 <= CursorReplyDeadline then
    begin
      CompleteCursorPositionReply;
      Exit;
    end;
    CompleteCursorPositionReply;
  end;
  case AnsiChar(c) of
    'A': Result := NavEvent($48, $8D, $98, p2);
    'B': Result := NavEvent($50, $91, $A0, p2);
    'C': Result := NavEvent($4D, $74, $9D, p2);
    'D': Result := NavEvent($4B, $73, $9B, p2);
    'H': Result := NavEvent($47, $77, $97, p2);
    'F': Result := NavEvent($4F, $75, $9F, p2);
    'Z': Result := KEv(#0, $0F, kbShift);
    'P'..'S': Result := FKeyEvent(Ord(AnsiChar(c)) - Ord('P') + 1, p2);
    '~':
      if p1 = 200 then
        CaptureBracketedPaste
      else
        case p1 of
          1, 7: Result := NavEvent($47, $77, $97, p2);
          2: Result := NavEvent($52, $04, $A2, p2);
          3: Result := NavEvent($53, $06, $A3, p2);
          4, 8: Result := NavEvent($4F, $75, $9F, p2);
          5: Result := NavEvent($49, $84, $99, p2);
          6: Result := NavEvent($51, $76, $A1, p2);
          11..15: Result := FKeyEvent(p1 - 10, p2);
          17..21: Result := FKeyEvent(p1 - 11, p2);
          23, 24: Result := FKeyEvent(p1 - 12, p2);
        end;
  end;
  // unrecognized sequences are swallowed whole (final byte consumed)
end;

// ESC O x (application mode / xterm F1..F4)
function DecodeSS3(ExtraMods: integer): TKeyEvent;
var
  c: integer;
begin
  Result := 0;
  c := NextByte(SEQ_TIMEOUT_MS);
  if c < 0 then
    Exit;
  case AnsiChar(c) of
    'A': Result := NavEvent($48, $8D, $98, ExtraMods);
    'B': Result := NavEvent($50, $91, $A0, ExtraMods);
    'C': Result := NavEvent($4D, $74, $9D, ExtraMods);
    'D': Result := NavEvent($4B, $73, $9B, ExtraMods);
    'H': Result := NavEvent($47, $77, $97, ExtraMods);
    'F': Result := NavEvent($4F, $75, $9F, ExtraMods);
    'P'..'S': Result := FKeyEvent(Ord(AnsiChar(c)) - Ord('P') + 1, ExtraMods);
  end;
end;

// after an already read ESC: lone kbEsc, sequence, or Alt+key
function DecodeEscape: TKeyEvent;
var
  n: integer;
  scan: byte;
begin
  n := NextByte(ESC_TIMEOUT_MS);
  if n < 0 then
    Exit(KEv(#27, $01, 0)); // real ESC: nothing came after it
  case n of
    27:
      begin
        // classic meta prefix: ESC ESC [ ... = Alt+sequence; if no
        // sequence follows the second ESC: real Esc (another pending)
        case PeekByte(ESC_TIMEOUT_MS) of
          Ord('['):
            begin
              NextByte(0);
              Result := DecodeCSI(2);
            end;
          Ord('O'):
            begin
              NextByte(0);
              Result := DecodeSS3(2);
            end;
        else
          PendingEscape := True;
          Result := KEv(#27, $01, 0);
        end;
      end;
    Ord('['): Result := DecodeCSI(0);
    Ord('O'): Result := DecodeSS3(0);
    8, 127: Result := KEv(#0, $08, kbAlt);   // kbAltBack
    9: Result := KEv(#0, $A5, kbAlt);        // kbAltTab
  else
    if (n >= 32) and (n < 127) then
    begin
      scan := EvalScan(byte(n) or $20); // Alt-A and Alt-a: same scancode
      if scan in [$02..$0D] then
        Inc(scan, $76);                 // digit row -> kbAlt1..
      Result := KEv(#0, scan, kbAlt);
    end
    else
      Result := KEv(#0, EvalScan(byte(n)), kbAlt);
  end;
end;

// core: decodes the next key event; 0 = nothing available
// (mouse events are queued separately and return 0 here)
function DecodeEvent(Blocking: boolean): TKeyEvent;
var
  b: integer;
begin
  Result := 0;
  repeat
    if PendingEscape then
    begin
      PendingEscape := False;
      Result := DecodeEscape;
      if Result <> 0 then
        Exit;
      continue;
    end;
    if Blocking then
      b := NextByte(-1)
    else
      b := NextByte(0);
    if b < 0 then
      Exit(0);
    case b of
      27: Result := DecodeEscape;
      13: Result := KEv(#13, $1C, 0);
      10: Result := KEv(#13, $1C, 0);  // raw NL: treat as Enter
      9: Result := KEv(#9, $0F, 0);
      8, 127: Result := KEv(#8, $0E, 0);
    else
      if b < 32 then
        Result := KEv(AnsiChar(b), EvalScan(byte(b)), 0)
      else if b < 128 then
        Result := KEv(AnsiChar(b), EvalScan(byte(b)), 0)
      else
        Result := KEv(AnsiChar(b), 0, 0); // UTF-8 bytes: pass through as-is
    end;
  until (Result <> 0) or not Blocking;
end;

procedure KInit;
{$IFDEF UNIX}
var
  T: termios;
{$ENDIF}
{$IFDEF WINDOWS}
const
  ENABLE_VIRTUAL_TERMINAL_INPUT_ = $0200;
var
  HIn: THandle;
  Mode: DWORD;
{$ENDIF}
begin
  RHead := 0;
  RTail := 0;
  PendingEscape := False;
  LastMouse := Default(TMouseEvent);
  PasteHead := 0;
  PasteTail := 0;
  {$IFDEF WINDOWS}
  HIn := GetStdHandle(STD_INPUT_HANDLE);
  Mode := 0;
  if (HIn <> 0) and (HIn <> INVALID_HANDLE_VALUE) and
     GetConsoleMode(HIn, Mode) then
  begin
    SavedInputMode := Mode;
    // VT input turns keys, mouse and focus into the same byte protocol this
    // decoder uses on POSIX. Disable cooked console processing so ReadFile
    // returns each key immediately and Ctrl-C reaches the focused pane.
    Mode := Mode or ENABLE_VIRTUAL_TERMINAL_INPUT_ or ENABLE_EXTENDED_FLAGS;
    Mode := Mode and not (ENABLE_LINE_INPUT or ENABLE_ECHO_INPUT or
      ENABLE_PROCESSED_INPUT or ENABLE_QUICK_EDIT_MODE or
      ENABLE_MOUSE_INPUT or ENABLE_WINDOW_INPUT);
    InputModeSaved := SetConsoleMode(HIn, Mode);
    SavedInputCP := GetConsoleCP;
    if (SavedInputCP <> 0) and (SavedInputCP <> CP_UTF8) then
      InputCPSaved := SetConsoleCP(CP_UTF8);
  end;
  {$ELSE}
  if TCGetAttr(0, SavedTio) = 0 then
  begin
    TioSaved := True;
    T := SavedTio;
    T.c_lflag := T.c_lflag and (not (ICANON or ECHO or ISIG or IEXTEN));
    T.c_iflag := T.c_iflag and
      (not (IXON or IXOFF or ICRNL or INLCR or IGNCR or ISTRIP or BRKINT));
    T.c_cc[VMIN] := 1;
    T.c_cc[VTIME] := 0;
    TCSetAttr(0, TCSANOW, T);
  end;
  {$ENDIF}
end;

procedure KDone;
begin
  {$IFDEF WINDOWS}
  if InputModeSaved then
  begin
    SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), SavedInputMode);
    InputModeSaved := False;
  end;
  if InputCPSaved then
  begin
    SetConsoleCP(SavedInputCP);
    InputCPSaved := False;
  end;
  {$ELSE}
  if TioSaved then
  begin
    TCSetAttr(0, TCSANOW, SavedTio);
    TioSaved := False;
  end;
  {$ENDIF}
end;

function KGet: TKeyEvent;
begin
  Result := DecodeEvent(True);
end;

function KPoll: TKeyEvent;
begin
  Result := DecodeEvent(False);
  if Result <> 0 then
    PutKeyEvent(Result); // the generic layer delivers it on the next Get
end;

function KShiftState: byte;
begin
  Result := 0; // an xterm pty cannot report standalone modifiers
end;

procedure InstallSuperKeyboard;
var
  Drv: TKeyboardDriver;
begin
  Drv := Default(TKeyboardDriver);
  Drv.InitDriver := @KInit;
  Drv.DoneDriver := @KDone;
  Drv.GetKeyEvent := @KGet;
  Drv.PollKeyEvent := @KPoll;
  Drv.GetShiftState := @KShiftState;
  SetKeyboardDriver(Drv);
end;

end.
