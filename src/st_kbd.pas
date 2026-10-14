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

uses
  st_keys;

// install before creating the application (before Keyboard.InitKeyboard)
procedure InstallSuperKeyboard;
// The key the last decoded event stands for, exactly as the terminal reported
// it: every modifier, and the character as typed (see st_keys.TKeyInfo). The
// RTL's keyboard layer holds a single pending event and FreeVision's
// GetKeyEvent polls and takes it in one call, so the application takes this
// right after FreeVision fetched an event and it belongs to that event. True
// once per decoded key; False for an event this driver did not just make.
function TakeKeyInfo(out AKey: TKeyInfo): boolean;
// CaptureConsoleCursor issues CSI 6 n before the keyboard driver starts. A
// slow host may answer only after startup; arm one pending CPR so CSI r;c R
// is consumed as a terminal reply rather than decoded as CSI-F3.
procedure ArmCursorPositionReply;
procedure CompleteCursorPositionReply;
// Read one CPR synchronously during video initialisation, remove only its
// protocol bytes and defer every interleaved key/mouse byte for the normal
// decoder. st_video calls this once before and once after its concealed probe.
function ReadCursorPositionReply(out ARow, ACol: integer): boolean;
// Bracketed paste arrives as one payload instead of thousands of unrelated
// key events. The application drains this queue from Idle and routes each
// item to the focused pane.
function TakeHostPaste(out AText: RawByteString): boolean;

// Undo what DecodeEscape did to an Alt key, so the pane can be given the
// Meta form of it.
//
// FreeVision carries the Alt bit in a separate KeyShift byte and requires the
// keycode's low byte to be zero, so building an Alt event here throws the
// character away and keeps only a scancode. These two invert that. They live
// next to EvalScan and the NavEvent table that produce those scancodes,
// because an inverse that drifts from its forward mapping is worse than no
// inverse at all.
//
// AltKeyChar answers the character of an Alt+character key, always unshifted
// and lower case: a scancode names a physical key, and st_kbd deliberately
// folds Alt-A onto Alt-a. A PC scancode cannot tell Alt-. from Alt->, and the
// unshifted form is the one that is actually bound in readline and friends.
function AltKeyChar(KeyCode: word): AnsiChar;
// AltKeyBase answers the plain keycode of an Alt+function/navigation key --
// Alt-F9 gives kbF9 -- so the caller can send ESC followed by that key's own
// sequence, which is the Meta convention every such application reads. It
// answers kbNoKey for anything else.
function AltKeyBase(KeyCode: word): word;

implementation

uses
  SysUtils, Keyboard, Mouse, Drivers, BaseUnix, Termio, st_mouse;

const
  ESC_TIMEOUT_MS = 50;   // lone ESC: margin to tell it apart from sequences
  SEQ_TIMEOUT_MS = 120;  // middle bytes of an already started sequence
  PASTE_TIMEOUT_MS = 2000;
  MAX_HOST_PASTE = 1024 * 1024 - 16;
  HOST_PASTE_QUEUE = 8;
  MOUSE_QUEUE = 64;      // this unit's own mouse ring; see SuperPutMouseEvent

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
  SavedTio: termios;
  TioSaved: boolean = False;
  RBuf: array[0..1023] of byte;
  RHead: integer = 0;
  RTail: integer = 0;
  PendingEscape: boolean = False;
  LastMouse: TMouseEvent;
  PasteQueue: array[0..HOST_PASTE_QUEUE - 1] of RawByteString;
  PasteHead: integer = 0;
  PasteTail: integer = 0;
  CursorReplyPending: boolean = False;
  DeferredInput: RawByteString = '';
  DeferredPos: integer = 1;
  MQ: array[0..MOUSE_QUEUE - 1] of TMouseEvent;
  MQHead: integer = 0;
  MQTail: integer = 0;
  MQCount: integer = 0;
  // TKeyInfo of the decode in progress, and of the last key event made
  Decoded: TKeyInfo;
  DecodedSet: boolean = False;
  LastKey: TKeyInfo;
  LastKeyFresh: boolean = False;

procedure ArmCursorPositionReply;
begin
  // Queries are strictly sequential: a timeout aborts the probing sequence,
  // so there can be only one legitimate late answer. Saturating at one also
  // prevents an accidental double arm from swallowing a later real F3.
  CursorReplyPending := True;
end;

procedure CompleteCursorPositionReply;
begin
  CursorReplyPending := False;
end;

procedure AppendDeferredInput(const S: RawByteString);
begin
  if S = '' then
    Exit;
  if DeferredPos > 1 then
  begin
    if DeferredPos <= Length(DeferredInput) then
      DeferredInput := Copy(DeferredInput, DeferredPos,
        Length(DeferredInput) - DeferredPos + 1)
    else
      DeferredInput := '';
    DeferredPos := 1;
  end;
  DeferredInput := DeferredInput + S;
end;

function ReadCursorPositionReply(out ARow, ACol: integer): boolean;
const
  PROBE_TIMEOUT_MS = 200;
  PROBE_MAX_READS = 64;
type
  TProbeState = (psGround, psEsc, psCsi, psRow, psColStart, psCol);
var
  State: TProbeState;
  Candidate, Kept: RawByteString;
  Row, Col: integer;
  Found: boolean;
  Reads, I, J, N, B, WaitMs: integer;
  NowTick, LastTick, Deadline: QWord;
  Fds: TFDSet;
  Chunk: array[0..255] of byte;

  procedure FlushCandidate;
  begin
    Kept := Kept + Candidate;
    Candidate := '';
    State := psGround;
  end;

  procedure AcceptReport;
  begin
    CompleteCursorPositionReply;
    if not Found then
    begin
      ARow := Row;
      ACol := Col;
      Found := True;
    end;
  end;

  procedure FeedByte(AB: byte);
  begin
    case State of
      psGround:
        if AB = 27 then
        begin
          Candidate := #27;
          State := psEsc;
        end
        else
          Kept := Kept + AnsiChar(AB);
      psEsc:
        if AB = Ord('[') then
        begin
          Candidate := Candidate + '[';
          State := psCsi;
        end
        else
        begin
          FlushCandidate;
          FeedByte(AB);
        end;
      psCsi:
        if (AB >= Ord('0')) and (AB <= Ord('9')) then
        begin
          Candidate := Candidate + AnsiChar(AB);
          Row := AB - Ord('0');
          State := psRow;
        end
        else
        begin
          FlushCandidate;
          FeedByte(AB);
        end;
      psRow:
        if (AB >= Ord('0')) and (AB <= Ord('9')) and
           (Length(Candidate) < 32) then
        begin
          Candidate := Candidate + AnsiChar(AB);
          if Row <= 100000 then
            Row := Row * 10 + AB - Ord('0');
        end
        else if AB = Ord(';') then
        begin
          Candidate := Candidate + ';';
          State := psColStart;
        end
        else
        begin
          FlushCandidate;
          FeedByte(AB);
        end;
      psColStart:
        if (AB >= Ord('0')) and (AB <= Ord('9')) then
        begin
          Candidate := Candidate + AnsiChar(AB);
          Col := AB - Ord('0');
          State := psCol;
        end
        else
        begin
          FlushCandidate;
          FeedByte(AB);
        end;
      psCol:
        if (AB >= Ord('0')) and (AB <= Ord('9')) and
           (Length(Candidate) < 32) then
        begin
          Candidate := Candidate + AnsiChar(AB);
          if Col <= 100000 then
            Col := Col * 10 + AB - Ord('0');
        end
        else if AB = Ord('R') then
        begin
          if (Row > 0) and (Col > 0) then
          begin
            Candidate := '';
            State := psGround;
            AcceptReport;
          end
          else
          begin
            Candidate := Candidate + 'R';
            FlushCandidate;
          end;
        end
        else
        begin
          FlushCandidate;
          FeedByte(AB);
        end;
    end;
  end;

begin
  Result := False;
  ARow := 0;
  ACol := 0;
  State := psGround;
  Candidate := '';
  Kept := '';
  Row := 0;
  Col := 0;
  Found := False;

  // Bytes buffered before this query cannot be its reply. Preserve them
  // literally and scan only newly read descriptor bytes; re-parsing old input
  // as CPR could eat a real modified F3 or an application's earlier report.
  while DeferredPos <= Length(DeferredInput) do
  begin
    Kept := Kept + DeferredInput[DeferredPos];
    Inc(DeferredPos);
  end;
  DeferredInput := '';
  DeferredPos := 1;
  while RHead <> RTail do
  begin
    Kept := Kept + AnsiChar(RBuf[RTail]);
    RTail := (RTail + 1) mod Length(RBuf);
  end;

  LastTick := GetTickCount64;
  Deadline := LastTick + PROBE_TIMEOUT_MS;
  Reads := 0;
  repeat
    NowTick := GetTickCount64;
    // FPC 3.2.2 on Darwin uses a wall clock here. A rollback or an overflow
    // ends the optional probe; it must never turn startup into an unbounded
    // wait. A forward jump simply shortens the probe and keeps UTF-8.
    if (NowTick < LastTick) or (NowTick >= Deadline) then
      Break;
    LastTick := NowTick;
    WaitMs := integer(Deadline - NowTick);
    if WaitMs > PROBE_TIMEOUT_MS then
      WaitMs := PROBE_TIMEOUT_MS;
    begin
      fpFD_ZERO(Fds);
      fpFD_SET(StdInputHandle, Fds);
      N := fpSelect(StdInputHandle + 1, @Fds, nil, nil, WaitMs);
    end;
    if N < 0 then
    begin
      if FpGetErrNo = ESysEINTR then
        Continue;
      Break;
    end;
    if N = 0 then
      Continue;
    N := FileRead(StdInputHandle, Chunk, SizeOf(Chunk));
    if N <= 0 then
      Break;
    Inc(Reads);
    for I := 0 to N - 1 do
    begin
      B := Chunk[I];
      FeedByte(byte(B));
      if Found then
      begin
        // A single read may contain the requested CPR followed immediately
        // by real keyboard input (or even another CPR-shaped key sequence).
        // Remove exactly the first accepted report and preserve the rest of
        // this descriptor chunk byte-for-byte for the normal decoder.
        for J := I + 1 to N - 1 do
          Kept := Kept + AnsiChar(Chunk[J]);
        Break;
      end;
    end;
    if Found then
      Break;
  until Reads >= PROBE_MAX_READS;
  if Candidate <> '' then
    Kept := Kept + Candidate;
  AppendDeferredInput(Kept);
  Result := Found;
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
  fds: TFDSet;
  n: cint;
  tmp: TReadChunk;
  r: integer;
  i: integer;
begin
  if RHead <> RTail then
    Exit(True);
  tmp := Default(TReadChunk);
  fpFD_ZERO(fds);
  fpFD_SET(0, fds);
  if TimeoutMs < 0 then
    n := fpSelect(1, @fds, nil, nil, nil)
  else
    n := fpSelect(1, @fds, nil, nil, TimeoutMs);
  if n <= 0 then
    Exit(False);
  r := FileRead(0, tmp, SizeOf(tmp)); // FileRead retries EINTR
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
  if DeferredPos <= Length(DeferredInput) then
  begin
    Result := byte(DeferredInput[DeferredPos]);
    Inc(DeferredPos);
    if DeferredPos > Length(DeferredInput) then
    begin
      DeferredInput := '';
      DeferredPos := 1;
    end;
    Exit;
  end;
  if not FillBuf(TimeoutMs) then
    Exit(-1);
  Result := RBuf[RTail];
  RTail := (RTail + 1) mod Length(RBuf);
end;

function PeekByte(TimeoutMs: integer): integer;
begin
  if DeferredPos <= Length(DeferredInput) then
    Exit(byte(DeferredInput[DeferredPos]));
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

function AltKeyChar(KeyCode: word): AnsiChar;
begin
  // The inverse of EvalScan above, restricted to the unshifted US layout --
  // one entry per physical key, in row order. The number row carries the
  // +$76 offset DecodeEscape adds to it.
  case Hi(KeyCode) of
    $29: Result := '`';
    $78: Result := '1';
    $79: Result := '2';
    $7A: Result := '3';
    $7B: Result := '4';
    $7C: Result := '5';
    $7D: Result := '6';
    $7E: Result := '7';
    $7F: Result := '8';
    $80: Result := '9';
    $81: Result := '0';
    $82: Result := '-';
    $83: Result := '=';
    $10: Result := 'q';
    $11: Result := 'w';
    $12: Result := 'e';
    $13: Result := 'r';
    $14: Result := 't';
    $15: Result := 'y';
    $16: Result := 'u';
    $17: Result := 'i';
    $18: Result := 'o';
    $19: Result := 'p';
    $1A: Result := '[';
    $1B: Result := ']';
    $1E: Result := 'a';
    $1F: Result := 's';
    $20: Result := 'd';
    $21: Result := 'f';
    $22: Result := 'g';
    $23: Result := 'h';
    $24: Result := 'j';
    $25: Result := 'k';
    $26: Result := 'l';
    $27: Result := ';';
    $28: Result := '''';
    $2B: Result := '\';
    $2C: Result := 'z';
    $2D: Result := 'x';
    $2E: Result := 'c';
    $2F: Result := 'v';
    $30: Result := 'b';
    $31: Result := 'n';
    $32: Result := 'm';
    $33: Result := ',';
    $34: Result := '.';
    $35: Result := '/';
    $39: Result := ' ';
  else
    Result := #0;
  end;
end;

function AltKeyBase(KeyCode: word): word;
begin
  // DecodeEscape offsets a function key by $2D ($06 for F11/F12) and picks a
  // navigation key's Alt scancode out of the NavEvent table; both directions
  // are written here side by side so neither can move alone.
  case Hi(KeyCode) of
    $68..$71: Result := (Hi(KeyCode) - $2D) shl 8;   // Alt-F1..Alt-F10
    $8B, $8C: Result := (Hi(KeyCode) - $06) shl 8;   // Alt-F11, Alt-F12
    $97: Result := kbHome;
    $98: Result := kbUp;
    $99: Result := kbPgUp;
    $9B: Result := kbLeft;
    $9D: Result := kbRight;
    $9F: Result := kbEnd;
    $A0: Result := kbDown;
    $A1: Result := kbPgDn;
    $A2: Result := kbIns;
    $A3: Result := kbDel;
    $08: Result := kbBack;                           // kbAltBack
    $A5: Result := kbTab;                            // kbAltTab
  else
    Result := kbNoKey;
  end;
end;

function KEv(ch: AnsiChar; scan: byte; state: byte): TKeyEvent;
begin
  Result := $03000000 or TKeyEvent(Ord(ch)) or (TKeyEvent(scan) shl 8) or
    (TKeyEvent(state) shl 16);
end;

function TakeKeyInfo(out AKey: TKeyInfo): boolean;
begin
  Result := LastKeyFresh;
  if Result then
    AKey := LastKey
  else
    AKey := Default(TKeyInfo);
  LastKeyFresh := False;
end;

// xterm's modifier parameter minus one: 1 Shift, 2 Alt, 4 Ctrl, 8 Meta. Meta
// is the Alt of a terminal that tells them apart, and programs read it as Alt.
function KeyMods(AXterm: integer): byte;
begin
  Result := AXterm and (KM_SHIFT or KM_ALT or KM_CTRL);
  if (AXterm and 8) <> 0 then
    Result := Result or KM_ALT;
end;

procedure Named(AKey: word; AXterm: integer);
begin
  Decoded.Key := AKey;
  Decoded.Text := '';
  Decoded.Mods := KeyMods(AXterm);
  DecodedSet := True;
end;

procedure Typed(const AText: RawByteString; AMods: byte);
begin
  Decoded.Key := 0;
  Decoded.Text := AText;
  Decoded.Mods := AMods;
  DecodedSet := True;
end;

// a C0 byte as the Ctrl+key that types it
procedure TypedControl(b: byte; AMods: byte);
begin
  if b = 0 then
    Typed(' ', AMods or KM_CTRL)
  else if b <= 26 then
    Typed(AnsiChar(b + $60), AMods or KM_CTRL)
  else
    Typed(AnsiChar(b + $40), AMods or KM_CTRL);
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

function NavKey(AKey: word; PlainScan, CtrlScan, AltScan: byte;
  Mods: integer): TKeyEvent;
begin
  Named(AKey, Mods);
  Result := NavEvent(PlainScan, CtrlScan, AltScan, Mods);
end;

function FKey(NumKey, Mods: integer): TKeyEvent;
const
  CODES: array[1..12] of word = (kbF1, kbF2, kbF3, kbF4, kbF5, kbF6, kbF7,
    kbF8, kbF9, kbF10, kbF11, kbF12);
begin
  Result := FKeyEvent(NumKey, Mods);
  if Result <> 0 then
    Named(CODES[NumKey], Mods);
end;

// The FreeVision event a byte makes on its own, and after an ESC (Alt). Both
// the plain stream and the extended reports below build their events here,
// so a key reaches FreeVision the same way whichever form the terminal used.
function PlainByteEvent(b: byte): TKeyEvent;
begin
  case b of
    13, 10: Result := KEv(#13, $1C, 0);  // raw NL: treat as Enter
    9: Result := KEv(#9, $0F, 0);
    8, 127: Result := KEv(#8, $0E, 0);
  else
    if b < 128 then
      Result := KEv(AnsiChar(b), EvalScan(b), 0)
    else
      Result := KEv(AnsiChar(b), 0, 0); // UTF-8 bytes: pass through as-is
  end;
end;

function AltByteEvent(b: byte): TKeyEvent;
var
  scan: byte;
begin
  case b of
    8, 127: Result := KEv(#0, $08, kbAlt);   // kbAltBack
    9: Result := KEv(#0, $A5, kbAlt);        // kbAltTab
    32..126:
      begin
        scan := EvalScan(b or $20);          // Alt-A and Alt-a: same scancode
        if scan in [$02..$0D] then
          Inc(scan, $76);                    // digit row -> kbAlt1..
        Result := KEv(#0, scan, kbAlt);
      end;
  else
    if b < 32 then
      Result := KEv(#0, EvalScan(b), kbAlt)
    else
      // no PC scancode: one picked from the byte would name some other key
      // (Alt+n with n's scancode) and set off its hotkey in a dialog
      Result := KEv(#0, 0, kbAlt);
  end;
end;

function Utf8Of(ACode: cardinal): RawByteString;
begin
  if ACode < $80 then
    Result := AnsiChar(ACode)
  else if ACode < $800 then
    Result := AnsiChar($C0 or (ACode shr 6)) + AnsiChar($80 or (ACode and $3F))
  else if ACode < $10000 then
    Result := AnsiChar($E0 or (ACode shr 12)) +
      AnsiChar($80 or ((ACode shr 6) and $3F)) + AnsiChar($80 or (ACode and $3F))
  else
    Result := AnsiChar($F0 or (ACode shr 18)) +
      AnsiChar($80 or ((ACode shr 12) and $3F)) +
      AnsiChar($80 or ((ACode shr 6) and $3F)) + AnsiChar($80 or (ACode and $3F));
end;

// A key in xterm's modifyOtherKeys report, CSI 27 ; m ; code ~, or the
// CSI code ; m u form of formatOtherKeys -- what a terminal sends once
// superterm asked it for those keys. FreeVision gets the event the same key
// makes in the plain stream (Ctrl+Q is still the prefix byte), and the pane
// gets the key with every modifier the report carried.
function OtherKey(ACode, AXterm: integer): TKeyEvent;
var
  Mods: byte;
  C0: integer;
  Ch: AnsiChar;
begin
  Result := 0;
  Mods := KeyMods(AXterm);
  case ACode of
    9:
      begin
        Named(kbTab, AXterm);
        if (Mods and KM_SHIFT) <> 0 then
          Result := KEv(#0, $0F, kbShift)    // kbShiftTab
        else if (Mods and KM_ALT) <> 0 then
          Result := AltByteEvent(9)
        else
          Result := PlainByteEvent(9);
      end;
    13:
      begin
        Named(kbEnter, AXterm);
        if (Mods and KM_ALT) <> 0 then
          Result := AltByteEvent(13)
        else
          Result := PlainByteEvent(13);
      end;
    27:
      begin
        Named(kbEsc, AXterm);
        Result := KEv(#27, $01, 0);
      end;
    8, 127:
      begin
        Named(kbBack, AXterm);
        if (Mods and KM_ALT) <> 0 then
          Result := AltByteEvent(127)
        else
          Result := PlainByteEvent(127);
      end;
    32..126:
      begin
        Typed(AnsiChar(ACode), Mods);
        Ch := AnsiChar(ACode);
        C0 := -1;
        if (Mods and KM_CTRL) <> 0 then
          // the control byte a VT100 sends for it (tmux's vt10x map)
          case Ch of
            ' ', '2': C0 := 0;
            '3'..'7': C0 := ACode - $18;
            '8', '?': C0 := 127;
            '/', '-': C0 := $1F;
            '@'..'~': C0 := ACode and $1F;
          end;
        if C0 < 0 then
          C0 := ACode;
        if (Mods and KM_ALT) <> 0 then
          Result := AltByteEvent(C0)
        else
          Result := PlainByteEvent(C0);
      end;
    128..$D7FF, $E000..$10FFFF:
      begin
        Typed(Utf8Of(ACode), Mods);
        if (Mods and KM_ALT) <> 0 then
          Result := KEv(#0, 0, kbAlt)
        else
          Result := KEv(#0, 0, 0);
      end;
  end;
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
  // Private CSI replies are terminal protocol traffic, never keyboard text.
  // In raw fullscreen a pane query such as DA1 (CSI c) reaches every host;
  // a host may answer with CSI ? 61;...c.  Treating '?' as the final
  // byte used to leave the numeric tail in stdin, where it was forwarded to
  // the shared PTY and visibly typed once per attached client.  Consume the
  // complete bounded CSI response, including arbitrary parameters/intermediates.
  if c in [Ord('?'), Ord('>'), Ord('=')] then
  begin
    for i := 1 to 256 do
    begin
      c := NextByte(SEQ_TIMEOUT_MS);
      if c < 0 then
        Exit;
      if (c >= $40) and (c <= $7E) then
        Exit;
    end;
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
  // modified CSI F3 on some terminals. Only an unanswered DSR we actually
  // emitted arms this one-shot swallow. Keep it armed after the synchronous
  // read times out: otherwise a genuinely late baseline becomes F3 and opens
  // a phantom pane. The ambiguity is unavoidable, but at most one such key
  // can be consumed, and only when the terminal never answers its own DSR.
  if (AnsiChar(c) = 'R') and (idx = 1) and seen[0] and seen[1] and
     (nums[0] > 0) and (nums[1] > 0) and
     CursorReplyPending then
  begin
    CompleteCursorPositionReply;
    Exit;
  end;
  case AnsiChar(c) of
    'A': Result := NavKey(kbUp, $48, $8D, $98, p2);
    'B': Result := NavKey(kbDown, $50, $91, $A0, p2);
    'C': Result := NavKey(kbRight, $4D, $74, $9D, p2);
    'D': Result := NavKey(kbLeft, $4B, $73, $9B, p2);
    'H': Result := NavKey(kbHome, $47, $77, $97, p2);
    'F': Result := NavKey(kbEnd, $4F, $75, $9F, p2);
    'Z':
      begin
        Named(kbTab, p2 or KM_SHIFT);
        Result := KEv(#0, $0F, kbShift);
      end;
    'P'..'S': Result := FKey(Ord(AnsiChar(c)) - Ord('P') + 1, p2);
    // formatOtherKeys=1 and the kitty protocol's base form: CSI code ; m u
    'u':
      if seen[0] and (idx <= 1) then
        Result := OtherKey(p1, p2);
    '~':
      if p1 = 200 then
        CaptureBracketedPaste
      else
        case p1 of
          1, 7: Result := NavKey(kbHome, $47, $77, $97, p2);
          2: Result := NavKey(kbIns, $52, $04, $A2, p2);
          3: Result := NavKey(kbDel, $53, $06, $A3, p2);
          4, 8: Result := NavKey(kbEnd, $4F, $75, $9F, p2);
          5: Result := NavKey(kbPgUp, $49, $84, $99, p2);
          6: Result := NavKey(kbPgDn, $51, $76, $A1, p2);
          11..15: Result := FKey(p1 - 10, p2);
          17..21: Result := FKey(p1 - 11, p2);
          23, 24: Result := FKey(p1 - 12, p2);
          // modifyOtherKeys: CSI 27 ; m ; code ~
          27:
            if (idx = 2) and seen[2] then
              Result := OtherKey(nums[2], p2);
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
    'A': Result := NavKey(kbUp, $48, $8D, $98, ExtraMods);
    'B': Result := NavKey(kbDown, $50, $91, $A0, ExtraMods);
    'C': Result := NavKey(kbRight, $4D, $74, $9D, ExtraMods);
    'D': Result := NavKey(kbLeft, $4B, $73, $9B, ExtraMods);
    'H': Result := NavKey(kbHome, $47, $77, $97, ExtraMods);
    'F': Result := NavKey(kbEnd, $4F, $75, $9F, ExtraMods);
    'P'..'S': Result := FKey(Ord(AnsiChar(c)) - Ord('P') + 1, ExtraMods);
  end;
end;

// after an already read ESC: lone kbEsc, sequence, or Alt+key
function DecodeEscape: TKeyEvent;
var
  n, c, need: integer;
  Glyph: RawByteString;
begin
  n := NextByte(ESC_TIMEOUT_MS);
  if n < 0 then
  begin
    Named(kbEsc, 0);
    Exit(KEv(#27, $01, 0)); // real ESC: nothing came after it
  end;
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
          Named(kbEsc, 0);
          Result := KEv(#27, $01, 0);
        end;
      end;
    Ord('['): Result := DecodeCSI(0);
    Ord('O'): Result := DecodeSS3(0);
  else
    case n of
      8, 127: Named(kbBack, KM_ALT);
      9: Named(kbTab, KM_ALT);
      10, 13: Named(kbEnter, KM_ALT);
      0..7, 11, 12, 14..26, 28..31: TypedControl(byte(n), KM_ALT);
      32..126: Typed(AnsiChar(n), KM_ALT);
    else
      // Alt and a character beyond ASCII: the rest of its UTF-8 sequence
      // belongs to this key, not to the next one
      Glyph := AnsiChar(n);
      if (n >= $C2) and (n <= $DF) then need := 1
      else if (n >= $E0) and (n <= $EF) then need := 2
      else if (n >= $F0) and (n <= $F4) then need := 3
      else need := 0;
      while need > 0 do
      begin
        c := PeekByte(SEQ_TIMEOUT_MS);
        if (c < $80) or (c > $BF) then
          Break;
        NextByte(0);
        Glyph := Glyph + AnsiChar(c);
        Dec(need);
      end;
      Typed(Glyph, KM_ALT);
    end;
    Result := AltByteEvent(byte(n));
  end;
end;

// core: decodes the next key event; 0 = nothing available
// (mouse events are queued separately and return 0 here)
function DecodeStream(Blocking: boolean): TKeyEvent;
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
    DecodedSet := False;
    if b = 27 then
      Result := DecodeEscape
    else
    begin
      case b of
        10, 13: Named(kbEnter, 0);
        9: Named(kbTab, 0);
        8, 127: Named(kbBack, 0);
        0..7, 11, 12, 14..26, 28..31: TypedControl(byte(b), 0);
      else
        Typed(AnsiChar(b), 0);
      end;
      Result := PlainByteEvent(byte(b));
    end;
  until (Result <> 0) or not Blocking;
end;

// every decoded key leaves its TKeyInfo for TakeKeyInfo
function DecodeEvent(Blocking: boolean): TKeyEvent;
begin
  DecodedSet := False;
  Result := DecodeStream(Blocking);
  if Result <> 0 then
  begin
    LastKey := Decoded;
    LastKeyFresh := DecodedSet;
  end;
end;

procedure KInit;
var
  T: termios;
begin
  RHead := 0;
  RTail := 0;
  PendingEscape := False;
  LastMouse := Default(TMouseEvent);
  PasteHead := 0;
  PasteTail := 0;
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
end;

procedure KDone;
begin
  if TioSaved then
  begin
    TCSetAttr(0, TCSANOW, SavedTio);
    TioSaved := False;
  end;
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

// The RTL's default mouse queue does not deliver what it was given: on the
// way out, GetPendingEvent recomputes Action from the button delta.
//
//   if (Last.Buttons <> New.Buttons) then
//     if Last.Buttons = 0 then Action := Down
//     else if (Last.Buttons and (MouseButton4 or MouseButton5)) = 0 then
//       Action := Up;
//
// That is written for a driver which reports a raw button state and lets the
// queue infer the gesture. This unit does the opposite: it decodes SGR and
// X10, where press and release are explicit in the protocol, and the button
// state is already correct. The rewrite therefore only damages it -- turning
// a wheel notch taken while another button is held into a release, because
// Last.Buttons is then non-zero. The RTL even tried to exempt the wheel, but
// tested the previous event's buttons instead of this one's, so the exemption
// never fires in exactly the case that needs it. Reported as issue #2.
//
// Owning the queue is the whole fix: what this unit decoded is what the
// application receives, in order and unmodified.
procedure SuperPutMouseEvent(const AEvent: TMouseEvent);
begin
  if MQCount >= MOUSE_QUEUE then
    Exit;   // a full queue drops the newest rather than corrupt the ring
  MQ[MQTail] := AEvent;
  MQTail := (MQTail + 1) mod MOUSE_QUEUE;
  Inc(MQCount);
end;

// GPM events do not travel through stdin: on a virtual console they wait in
// st_mouse's socket until a dry queue asks for them.
function SuperPollMouseEvent(var AEvent: TMouseEvent): boolean;
begin
  if MQCount = 0 then
    PumpConsoleMouse;
  Result := MQCount > 0;
  if Result then
    AEvent := MQ[MQHead]
  else
    AEvent := Default(TMouseEvent);
end;

procedure SuperGetMouseEvent(var AEvent: TMouseEvent);
begin
  if MQCount = 0 then
    PumpConsoleMouse;
  if MQCount = 0 then
  begin
    AEvent := Default(TMouseEvent);
    Exit;
  end;
  AEvent := MQ[MQHead];
  MQHead := (MQHead + 1) mod MOUSE_QUEUE;
  Dec(MQCount);
end;

procedure InstallSuperKeyboard;
var
  Drv: TKeyboardDriver;
  MDrv: TMouseDriver;
begin
  Drv := Default(TKeyboardDriver);
  Drv.InitDriver := @KInit;
  Drv.DoneDriver := @KDone;
  Drv.GetKeyEvent := @KGet;
  Drv.PollKeyEvent := @KPoll;
  Drv.GetShiftState := @KShiftState;
  SetKeyboardDriver(Drv);
  // Keep everything the platform driver does -- detection, show/hide, the
  // pointer position -- and take over only the queue.
  MDrv := Default(TMouseDriver);
  GetMouseDriver(MDrv);
  MDrv.UseDefaultQueue := False;
  MDrv.PutMouseEvent := @SuperPutMouseEvent;
  MDrv.PollMouseEvent := @SuperPollMouseEvent;
  MDrv.GetMouseEvent := @SuperGetMouseEvent;
  SetMouseDriver(MDrv);
end;

end.
