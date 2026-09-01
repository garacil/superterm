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

// Input pump. The decoder below only reads stdin when the single UI thread
// asks it for a byte, and under a flood that thread is busy parsing pane
// output and repainting. Meanwhile the host terminal keeps reporting: with
// button-event tracking a drag emits one ~13 byte report per pointer step.
// Nobody is draining, the tty input buffer fills, and the kernel discards the
// newest bytes in silence -- a press on a window title simply never happens
// as far as the application is concerned, which is why one window answered
// the mouse and another ignored it. The pump is a thread that does nothing
// but move stdin into a large ring, so input survives however long a repaint
// takes. Start it only once every synchronous probe has finished: while it
// runs it is the sole reader of fd 0.
procedure StartInputPump;
procedure StopInputPump;
// Descriptor to wait on for input once the pump owns stdin. A caller that
// selects must use this instead of fd 0, which the pump has already drained.
// Falls back to fd 0 when the pump is not running, so a caller needs no branch.
function InputWakeupFd: longint;
// Whether the pump owns stdin. Callers that ask the tty about pending input
// must ask this first: under the pump the tty is always drained.
function InputPumpActive: boolean;
// True when a byte is already buffered, so the caller must not block at all.
// Named apart from st_video.InputPending on purpose: that one asks the tty,
// which the pump has already drained.
function InputBuffered: boolean;
// Bytes the pump had to discard because the application never consumed them.
// Zero unless the UI thread stalled for longer than the ring can absorb.
function InputPumpDropped: QWord;
// A session daemon is forked WITHOUT exec, so the child continues in this
// address space and inherits every lock a thread happened to hold, with no
// owner left to release it. Stop the pump around such a fork. Whatever it had
// already collected is carried over in order rather than thrown away: losing
// input silently is the exact defect the pump exists to remove.
procedure QuiesceInputForFork;
procedure ResumeInputAfterFork;

implementation

uses
  BaseUnix, termio, SysUtils, Classes, Keyboard, Mouse, Drivers;

const
  // Large enough that a stall of a whole second under button-event tracking
  // still fits: a drag reports ~13 bytes per pointer step.
  PUMP_RING_SIZE = 64 * 1024;
  PUMP_CHUNK = 4096;
  PUMP_TICK_MS = 40;     // bounded wait so Terminate is honoured at shutdown

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

type
  TInputPump = class(TThread)
  protected
    procedure Execute; override;
  end;

var
  Pump: TInputPump = nil;
  PumpLock: TRTLCriticalSection;
  PumpLockReady: boolean = False;
  PumpRing: array[0..PUMP_RING_SIZE - 1] of byte;
  PumpHead: integer = 0;      // written by the pump, read by the UI thread
  PumpTail: integer = 0;      // written by the UI thread
  PumpCount: integer = 0;
  PumpDropped: QWord = 0;
  PumpPipe: TFildes = (-1, -1);
  PumpSignalled: boolean = False;
  PumpRunning: boolean = False;
  PumpForkQuiesced: boolean = False;

// FPC declares fpRead/fpWrite with untyped buffers and marks them inline; at
// call sites 3.2.2 reports a compiler implementation note with nothing
// actionable behind it. Keep that noise inside these two wrappers, exactly as
// st_server does for its own self-pipe, so the build stays diagnostic clean.
{$push}{$notes off}{$hints off}
function PumpSignalWrite(AFd: longint): boolean;
var
  Value: byte;
begin
  Value := 1;
  Result := (AFd >= 0) and (FpWrite(AFd, Value, SizeOf(Value)) = 1);
end;

procedure PumpSignalDrain(AFd: longint);
var
  Buf: array[0..63] of byte;
begin
  FillChar(Buf, SizeOf(Buf), 0);
  if AFd < 0 then
    Exit;
  while FpRead(AFd, Buf, SizeOf(Buf)) > 0 do ;
end;
{$pop}

// The pump reads stdin and nothing else. It never touches the decoder state,
// FreeVision, or the screen: the only thing it shares with the UI thread is
// the ring below and the pipe that says the ring stopped being empty.
procedure TInputPump.Execute;
var
  Chunk: array[0..PUMP_CHUNK - 1] of byte;
  Fds: TFDSet;
  N: cint;
  I: integer;
begin
  while not Terminated do
  begin
    fpFD_ZERO(Fds);
    fpFD_SET(0, Fds);
    // A bounded wait, so Terminate is noticed even on a silent terminal.
    N := fpSelect(1, @Fds, nil, nil, PUMP_TICK_MS);
    if Terminated then
      Break;
    if N <= 0 then
      Continue;                       // timeout or EINTR: look again
    N := FileRead(0, Chunk, SizeOf(Chunk));
    if N <= 0 then
    begin
      if N = 0 then
        Break;                        // stdin closed: there is nothing to pump
      Continue;
    end;
    EnterCriticalSection(PumpLock);
    try
      for I := 0 to N - 1 do
      begin
        if PumpCount >= PUMP_RING_SIZE then
        begin
          // The UI thread has not consumed anything for a very long time.
          // Account for it: a silent loss here is the bug this unit exists
          // to remove, so it must be visible in the trace.
          Inc(PumpDropped, QWord(N - I));
          Break;
        end;
        PumpRing[PumpHead] := Chunk[I];
        PumpHead := (PumpHead + 1) mod PUMP_RING_SIZE;
        Inc(PumpCount);
      end;
      // One byte at a time in the pipe, gated by PumpSignalled, so the write
      // can never block and the reader can never miss a transition.
      if not PumpSignalled then
        PumpSignalled := PumpSignalWrite(PumpPipe[1]);
    finally
      LeaveCriticalSection(PumpLock);
    end;
  end;
end;

// Moves what the pump has collected into the decoder's own buffer. Only ever
// called by the UI thread, and only with RBuf empty.
function PumpTake: boolean;
var
  N, I: integer;
begin
  Result := False;
  EnterCriticalSection(PumpLock);
  try
    N := PumpCount;
    if N > Length(RBuf) - 1 then
      N := Length(RBuf) - 1;          // a full RBuf would read back as empty
    if N > 0 then
    begin
      for I := 0 to N - 1 do
      begin
        RBuf[I] := PumpRing[PumpTail];
        PumpTail := (PumpTail + 1) mod PUMP_RING_SIZE;
        Dec(PumpCount);
      end;
      RTail := 0;
      RHead := N;
      Result := True;
    end;
    if (PumpCount = 0) and PumpSignalled then
    begin
      PumpSignalled := False;
      PumpSignalDrain(PumpPipe[0]);
    end;
  finally
    LeaveCriticalSection(PumpLock);
  end;
end;

procedure StartInputPump;
begin
  if PumpRunning then
    Exit;
  if not PumpLockReady then
  begin
    InitCriticalSection(PumpLock);
    PumpLockReady := True;
  end;
  if fpPipe(PumpPipe) <> 0 then
    Exit;                             // no pipe: keep reading stdin inline
  fpfcntl(PumpPipe[0], F_SETFL, fpfcntl(PumpPipe[0], F_GETFL) or O_NONBLOCK);
  fpfcntl(PumpPipe[1], F_SETFL, fpfcntl(PumpPipe[1], F_GETFL) or O_NONBLOCK);
  PumpHead := 0;
  PumpTail := 0;
  PumpCount := 0;
  PumpDropped := 0;
  PumpSignalled := False;
  PumpRunning := True;
  Pump := TInputPump.Create(False);
end;

// Everything still undecoded, in the order it arrived: what the decoder has
// buffered first, then what the pump collected after that.
function DrainBufferedInput: RawByteString;
begin
  Result := '';
  while RHead <> RTail do
  begin
    Result := Result + AnsiChar(RBuf[RTail]);
    RTail := (RTail + 1) mod Length(RBuf);
  end;
  if not PumpRunning then
    Exit;
  EnterCriticalSection(PumpLock);
  try
    while PumpCount > 0 do
    begin
      Result := Result + AnsiChar(PumpRing[PumpTail]);
      PumpTail := (PumpTail + 1) mod PUMP_RING_SIZE;
      Dec(PumpCount);
    end;
  finally
    LeaveCriticalSection(PumpLock);
  end;
end;

procedure QuiesceInputForFork;
var
  Carried: RawByteString;
begin
  if not PumpRunning then
    Exit;
  StopInputPump;
  Carried := DrainBufferedInput;
  if Carried <> '' then
    AppendDeferredInput(Carried);   // consumed before any newly read byte
  PumpForkQuiesced := True;
end;

procedure ResumeInputAfterFork;
begin
  if not PumpForkQuiesced then
    Exit;
  PumpForkQuiesced := False;
  StartInputPump;
end;

procedure StopInputPump;
begin
  if not PumpRunning then
    Exit;
  if Pump <> nil then
  begin
    Pump.Terminate;
    Pump.WaitFor;                     // no reader of fd 0 survives this call
    FreeAndNil(Pump);
  end;
  PumpRunning := False;
  if PumpPipe[0] >= 0 then
    fpClose(PumpPipe[0]);
  if PumpPipe[1] >= 0 then
    fpClose(PumpPipe[1]);
  PumpPipe[0] := -1;
  PumpPipe[1] := -1;
end;

function InputPumpActive: boolean;
begin
  Result := PumpRunning and (PumpPipe[0] >= 0);
end;

function InputWakeupFd: longint;
begin
  if PumpRunning and (PumpPipe[0] >= 0) then
    Result := longint(PumpPipe[0])
  else
    Result := 0;
end;

function InputBuffered: boolean;
begin
  if RHead <> RTail then
    Exit(True);
  Result := False;
  if not PumpRunning then
    Exit;
  EnterCriticalSection(PumpLock);
  try
    Result := PumpCount > 0;
  finally
    LeaveCriticalSection(PumpLock);
  end;
end;

function InputPumpDropped: QWord;
begin
  if not PumpRunning then
    Exit(0);
  EnterCriticalSection(PumpLock);
  try
    Result := PumpDropped;
  finally
    LeaveCriticalSection(PumpLock);
  end;
end;

// waits up to TimeoutMs (negative = forever) for bytes in the buffer
function FillBuf(TimeoutMs: integer): boolean;
type
  TReadChunk = array[0..255] of byte;
var
  fds: TFDSet;
  tmp: TReadChunk;
  n: cint;
  r: integer;
  i: integer;
begin
  if RHead <> RTail then
    Exit(True);
  if PumpRunning then
  begin
    if PumpTake then
      Exit(True);
    fpFD_ZERO(fds);
    fpFD_SET(PumpPipe[0], fds);
    if TimeoutMs < 0 then
      n := fpSelect(PumpPipe[0] + 1, @fds, nil, nil, nil)
    else
      n := fpSelect(PumpPipe[0] + 1, @fds, nil, nil, TimeoutMs);
    if n <= 0 then
      Exit(False);
    Exit(PumpTake);
  end;
  fpFD_ZERO(fds);
  fpFD_SET(0, fds);
  if TimeoutMs < 0 then
    n := fpSelect(1, @fds, nil, nil, nil)
  else
    n := fpSelect(1, @fds, nil, nil, TimeoutMs);
  if n <= 0 then
    Exit(False);
  tmp := Default(TReadChunk);
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
  // Private CSI replies are terminal protocol traffic, never keyboard text.
  // In raw fullscreen a pane query such as DA1 (CSI c) reaches every host;
  // Windows Terminal answers with CSI ? 61;...c.  Treating '?' as the final
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
