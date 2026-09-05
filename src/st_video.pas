unit st_video;

{$mode objfpc}{$H+}

interface

procedure InstallWideVideoOutput;
// Runtime presentation uses a separately opened, nonblocking /dev/tty handle.
// This keeps a slow outer terminal from parking the Free Vision/UI thread and
// does not change O_NONBLOCK on the stdout file description inherited by the
// caller's shell. Startup probes remain synchronous until this is enabled.
procedure StartAsyncVideoOutput;
// POSIX fork preserves only the calling thread. Stop the physical-output
// reactor before the session daemon is forked, then recreate it only in the
// parent. Otherwise the child inherits a TThread object whose pthread no
// longer exists and unit finalization waits for it forever.
procedure PauseAsyncVideoOutputForFork(out AWasActive,
  AResumeNeedsFullFrame: Boolean);
procedure ResumeAsyncVideoOutputAfterFork(AWasActive,
  AResumeNeedsFullFrame: Boolean);
// Make bounded progress on queued physical output. True means a renderer
// update was coalesced while the terminal was busy and must now be retried.
function PumpVideoOutput: Boolean;
function VideoOutputHasFailed: Boolean;
function VideoOutputWaitHandle: LongInt;
function VideoOutputPending: Boolean;
// Admit one intentional animation step behind an already queued physical
// frame. Ordinary renderer updates still coalesce to the latest state; this
// narrow path preserves the documented show/hide sequence of an opt-in
// transition without making the UI perform a physical write.
procedure PresentOrderedVideoFrame;
// Renderer capability of this process/host terminal.  Every attached client
// has its own process and therefore its own value; it is never shared with the
// canonical desktop kept by the daemon.
function HostUtf8Output: Boolean;
procedure CaptureConsoleCursor;
procedure RestoreConsoleCursor;
// Ask the outer terminal to delimit paste operations. st_kbd consumes those
// delimiters and delivers the payload atomically to the application.
procedure HostPasteOn;
// Hand the terminal back exactly as it was found: every mouse mode off,
// bracketed paste off, and anything the terminal already reported dropped.
// Call at the very end, after the application is done.
procedure ReleaseConsoleInput;

// Passthrough: while active the FreeVision screen driver stays silent and the
// client writes a pane's raw PTY bytes straight to the host terminal, so a
// full-fidelity TUI (truecolor, emoji, wide glyphs) renders untouched.
procedure PassthroughRaw(const Data; ALen: LongInt);
// Raw escape/string writer to the host terminal (respects OutputFailed).
procedure WriteRaw(const S: AnsiString);
// Audible client-local notification. Never route this byte through a pane or
// the shared session transport: it belongs only to the outer host terminal.
procedure HostBell;

// True when more input is already waiting to be read. Painting a frame that
// the very next event will overwrite is wasted work and, over a slow link,
// wasted latency -- so callers use this to coalesce a burst of events into one
// frame. Bounded by time so continuous input can never starve the screen.
function InputPending: Boolean;

// Rich overlay (the "option B" renderer). A pane registers each of its cells
// -- the full UTF-8 glyph plus the EXACT color -- at its GLOBAL screen
// position, passing the VideoBuf word it wrote there as an oracle. Then
// WideUpdateScreen emits the rich cell (truecolor + UTF-8) whenever VideoBuf
// still holds that oracle (i.e. the pane cell is the visible top one), and
// falls back to the CP437/16-color chrome for everything else (window frames,
// menu, status line, cells covered by another window). This keeps FreeVision
// untouched: the grid is still drawn (it is the visibility oracle), but the
// pane area is presented richly. Colors: $01RRGGBB = truecolor;
// $02000000 or index (0..15, 8..15 = bright) = the 16-color fallback;
// $03000000 or index (16..255) = an xterm-256 palette index; 0 = the
// terminal default. Flags: 1 = bold, 2 = underline, 4 = reverse, 8 = faint.
// ASkip marks a wide-glyph continuation cell (its lead already emitted the
// 2-wide glyph, so nothing is written here). AShadowable is for desktop art:
// FreeVision may dim it below a menu/dialog shadow. Terminal panes pass False
// because their content colours never represent window focus or chrome.
procedure RichSetCell(AX, AY: LongInt; const AGlyph: AnsiString;
  AFg, ABg: LongWord; AFlags: Byte; AOracle: Word; ASkip: Boolean;
  AWide, AShadowable: Boolean);
// Drop the whole overlay (nothing renders rich until panes repopulate it).
procedure RichInvalidate;
// Forget one cell. A view that covers ground it does not colour richly says
// so here, instead of leaving whatever the previous layout registered.
procedure RichClear(AX, AY: LongInt);

// Wireframe drag. While a window is dragged with its contents hidden, the
// window itself is hidden too, so FreeVision repaints the desktop and the
// other windows normally and VideoBuf holds the TRUE screen. The moving
// outline is then painted straight to the terminal, outside the buffer, and
// erased by repainting just its cells back from VideoBuf. Only the ring
// travels -- a few dozen cells per step instead of the window's whole area.
procedure OutlinePaint(X1, Y1, X2, Y2: LongInt; AAttr: Byte);
// Forget what we believe is on those ring cells, so the NEXT update repaints
// them through the normal path. Painting them back by hand is wrong: this unit
// would rebuild them from the 16-colour VideoBuf and a pane cell would come
// back as its CP437 approximation instead of its real colour -- text restored,
// attributes lost. Letting the regular delta redraw them keeps truecolor.
procedure OutlineInvalidate(X1, Y1, X2, Y2: LongInt);
// Move an outline by touching ONLY the difference between the two rings: the
// cells the frame leaves behind are invalidated (so the normal renderer
// repaints them with their real colours) and only the cells it newly occupies
// are drawn. Consecutive positions overlap almost completely, so a one-cell
// step costs a sliver instead of two full perimeters.
procedure OutlineLeaveDiff(OX1, OY1, OX2, OY2, NX1, NY1, NX2, NY2: LongInt);
procedure OutlineEnterDiff(NX1, NY1, NX2, NY2, OX1, OY1, OX2, OY2: LongInt;
  AAttr: Byte);

// Renderer-owned transient outlines. Unlike OutlinePaint these participate in
// the effective-screen delta, so ordinary pane repaints cannot erase them and
// replacing/clearing one is presented in the same frame as the restored cells
// underneath. Slots are independent (0..15); when rings overlap the higher
// slot has deterministic priority. Set/Clear only change renderer state: the
// caller decides when to present it by calling UpdateScreen.
procedure TransientOutlineSet(ASlot, X1, Y1, X2, Y2: LongInt; AAttr: Byte;
  ALocked: Boolean = False);
procedure TransientOutlineClear(ASlot: LongInt);
procedure TransientOutlineClearAll;
function TransientOutlineActive(ASlot: LongInt): Boolean;

// Declare that what the terminal currently shows is unknown, so the NEXT
// update repaints every cell. This is the only legitimate way to ask for a
// full repaint: the per-cell delta is otherwise always trustworthy, because
// this unit is the only writer to the terminal and it tracks what it wrote.
// FreeVision's TGroup.Redraw asks for a forced update on every ChangeBounds,
// which during a window drag meant a whole-screen resend per mouse step; that
// request is now ignored and only an explicit invalidation forces a repaint.
procedure InvalidateFrame;

var
  // Paint our own ground instead of leaving it to the host terminal. A cell
  // whose background is black -- or, for a pane, the terminal default -- is
  // emitted as an explicit RGB black rather than as "colour 0" or "no colour
  // at all". Host terminals with a transparent background, or with a palette
  // that maps ANSI black to something else, otherwise show THEIR ground
  // through everything superterm draws: menus, dialogs, the status line and
  // the panes all came out tinted. Off leaves the old behaviour, which is
  // what a deliberately transparent terminal wants.
  SolidBackground: Boolean = True;
  PassthroughActive: Boolean = False;
  // startup: while True, FreeVision draws into the buffer normally but the
  // driver does NOT write to the terminal, so the whole build+promote+
  // attach is flushed ONCE (a forced paint at the end) instead of several
  SuppressFlush: Boolean = False;

implementation

uses
  Classes, SysUtils, Video, st_debug, st_kbd
  {$IFDEF UNIX}, termio, BaseUnix{$ENDIF}
  {$IFDEF WINDOWS}, Windows{$ENDIF};

{$IFDEF WINDOWS}
type
  // The client output reactor is a POSIX design: one private nonblocking
  // /dev/tty descriptor, two wake pipes and a poll loop on a helper thread.
  // Windows Phase 1 keeps the established blocking console writer, so these
  // aliases exist only so the shared declarations and call sites below compile
  // unchanged. Every descriptor stays -1 and AsyncOutputActive stays False,
  // which is exactly the branch WriteRaw, PassthroughRaw and WideUpdateScreen
  // already take on Unix when the reactor cannot be started.
  cint = LongInt;
  TFilDes = array[0..1] of cint;
{$ENDIF}

{$IFDEF UNIX}
type
  TClientOutputReactor = class(TThread)
  protected
    procedure Execute; override;
  end;
{$ENDIF}

var
  SavedDriver: TVideoDriver;
  DriverInstalled: Boolean;
  OutputFailed: Boolean;
  ConsoleRow, ConsoleCol: Integer; // cursor position at startup (0 = unknown)
  UseSyncOutput: Boolean = False;  // DECSET 2026; opt-in via SUPERTERM_SYNC=1
  HostUtf8: Boolean = True;
  ProbeHostEncoding: Boolean = True;

{$IFDEF UNIX}
const
  // A renderer frame is normally at most a few hundred KiB, while direct
  // passthrough can burst much harder. Keep the queue finite: saturation is a
  // client-local failure, never permission to consume unbounded memory or to
  // block the UI thread.
  OUTPUT_QUEUE_CAPACITY = 8 * 1024 * 1024;
  OUTPUT_TEARDOWN_DRAIN_MS = 500;
{$ENDIF}

var
  {$IFDEF UNIX}
  OutputHandle: cint = -1;
  OutputRing: array of Byte;
  OutputHead: LongInt = 0;
  OutputFrameRemaining: LongInt = 0;
  AsyncOutputEverStarted: Boolean = False;
  {$ENDIF}
  OutputCount: LongInt = 0;
  AsyncOutputActive: Boolean = False;
  BlockingTeardownUnsafe: Boolean = False;
  DeferredFrame: Boolean = False;
  CursorStateDirty: Boolean = False;
  DesiredCursorType: Word = crHidden;
  QueuedCursorType: Word = $FFFF;
  QueuedCursorX: Word = $FFFF;
  QueuedCursorY: Word = $FFFF;
  OutputLock: TRTLCriticalSection;
  OutputLockInitialized: Boolean = False;
  {$IFDEF UNIX}
  OutputWakePipe: TFilDes = (-1, -1);
  {$ENDIF}
  OutputProgressPipe: TFilDes = (-1, -1);
  {$IFDEF UNIX}
  OutputReactor: TClientOutputReactor = nil;
  {$ENDIF}
  OrderedFrameAdmission: Boolean = False;

{$IFDEF WINDOWS}
// Marks a parameter of a fixed cross-platform signature as intentionally
// unused, the same diagnostic-free helper the vendored Free Vision units use.
procedure Unused(const A); begin if @A = nil then; end;
{$ENDIF}

function HostUtf8Output: Boolean;
begin
  Result := HostUtf8;
end;

function PendingOutputByteCount: LongInt;
begin
  if not OutputLockInitialized then
    Exit(0);
  EnterCriticalSection(OutputLock);
  try
    Result := OutputCount;
  finally
    LeaveCriticalSection(OutputLock);
  end;
end;

// FPC 3.2.2 emits a non-actionable inline note for its untyped fpRead/fpWrite
// declarations. Keep it confined to the physical-I/O leaf, as st_server does
// for the same system calls, so strict project builds stay diagnostic-clean.
{$push}{$notes off}{$hints off}
procedure SignalPipe(AFd: cint);
{$IFDEF WINDOWS}
begin
  // No reactor thread to wake: Windows submits every frame synchronously on
  // the UI thread, so progress is observed by the caller that wrote it.
end;
{$ELSE}
var
  B: Byte;
  N: ssize_t;
begin
  if AFD < 0 then
    Exit;
  B := 1;
  N := fpWrite(AFd, PChar(@B)^, 1);
  if (N < 0) and (fpGetErrNo <> ESysEINTR) and
     (fpGetErrNo <> ESysEAGAIN) and (fpGetErrNo <> ESysEWOULDBLOCK) and
     DebugActive then
    DebugLog('video: output wake pipe failed errno=' + IntToStr(fpGetErrNo));
end;
{$ENDIF}

procedure DrainPipe(AFd: cint);
{$IFDEF WINDOWS}
begin
  // Counterpart of the SignalPipe stub: there is no progress pipe to drain.
end;
{$ELSE}
var
  Buf: array[0..63] of Byte;
  N: ssize_t;
begin
  if AFD < 0 then
    Exit;
  repeat
    N := fpRead(AFd, PChar(@Buf[0])^, SizeOf(Buf));
  until (N <= 0) and (fpGetErrNo <> ESysEINTR);
end;
{$ENDIF}

procedure MarkOutputFailure(const AReason: string);
var
  First: Boolean;
begin
  First := False;
  if OutputLockInitialized then
    EnterCriticalSection(OutputLock);
  try
    if not OutputFailed then
    begin
      OutputFailed := True;
      First := True;
    end;
  finally
    if OutputLockInitialized then
      LeaveCriticalSection(OutputLock);
  end;
  if First and DebugActive then
    DebugLog('video: physical output failed: ' + AReason);
  if First then
    SignalPipe(OutputProgressPipe[1]);
end;

{$IFDEF UNIX}
function WritePendingNonblocking: Boolean;
var
  Head, Chunk, Written, ErrNo, FromFrame: LongInt;
  BecameEmpty: Boolean;
begin
  Result := False;
  repeat
    EnterCriticalSection(OutputLock);
    try
      if OutputFailed or (OutputCount <= 0) or (OutputHandle < 0) then
        Exit(not OutputFailed);
      Head := OutputHead;
      Chunk := Length(OutputRing) - Head;
      if Chunk > OutputCount then
        Chunk := OutputCount;
    finally
      LeaveCriticalSection(OutputLock);
    end;
    Written := fpWrite(OutputHandle, PChar(@OutputRing[Head])^, Chunk);
    if Written > 0 then
    begin
      BecameEmpty := False;
      EnterCriticalSection(OutputLock);
      try
        FromFrame := Written;
        if FromFrame > OutputFrameRemaining then
          FromFrame := OutputFrameRemaining;
        Dec(OutputFrameRemaining, FromFrame);
        Inc(OutputHead, Written);
        if OutputHead >= Length(OutputRing) then
          OutputHead := 0;
        Dec(OutputCount, Written);
        if OutputCount = 0 then
        begin
          OutputHead := 0;
          BecameEmpty := True;
        end;
      finally
        LeaveCriticalSection(OutputLock);
      end;
      // The UI only needs the empty edge: that is when a deferred latest
      // frame or cursor state can be admitted. Waking it for every partial
      // write turns a large terminal frame into an avoidable wake storm.
      if BecameEmpty then
        SignalPipe(OutputProgressPipe[1]);
      Continue;
    end;
    ErrNo := fpGetErrNo;
    if ErrNo = ESysEINTR then
      Continue;
    if (ErrNo = ESysEAGAIN) or (ErrNo = ESysEWOULDBLOCK) then
      Exit(True);
    MarkOutputFailure('write errno=' + IntToStr(ErrNo));
    Exit(False);
  until False;
end;
{$ENDIF}

{$pop}

{$IFDEF UNIX}
procedure TClientOutputReactor.Execute;
var
  Fds: array[0..1] of TPollFD;
  NFds, N: cint;
  HaveOutput: Boolean;
begin
  TThread.NameThreadForDebugging('st-client-output');
  while not Terminated do
  begin
    EnterCriticalSection(OutputLock);
    try
      HaveOutput := OutputCount > 0;
    finally
      LeaveCriticalSection(OutputLock);
    end;
    Fds[0] := Default(TPollFD);
    Fds[0].fd := OutputWakePipe[0];
    Fds[0].events := POLLIN;
    NFds := 1;
    if HaveOutput then
    begin
      Fds[1] := Default(TPollFD);
      Fds[1].fd := OutputHandle;
      Fds[1].events := POLLOUT;
      NFds := 2;
    end;
    N := fpPoll(@Fds[0], NFds, -1);
    if N < 0 then
    begin
      if fpGetErrNo = ESysEINTR then
        Continue;
      MarkOutputFailure('poll errno=' + IntToStr(fpGetErrNo));
      Break;
    end;
    if (Fds[0].revents and (POLLIN or POLLHUP)) <> 0 then
      DrainPipe(OutputWakePipe[0]);
    if Terminated then
      Break;
    if (NFds = 2) and
       ((Fds[1].revents and (POLLOUT or POLLERR or POLLHUP or POLLNVAL)) <> 0) then
      if not WritePendingNonblocking then
        Break;
  end;
end;
{$ENDIF}

{$IFDEF WINDOWS}
// No reactor, so no queue to admit anything to. Every producer already tests
// AsyncOutputActive first and takes the blocking writer instead; these exist
// so that shared code needs no platform branch of its own.
function QueueOutputTransaction(const AData; ALen: LongInt;
  AFrame, AAppendFrame: Boolean): Boolean;
begin
  Unused(AData);
  Unused(ALen);
  Unused(AFrame);
  Unused(AAppendFrame);
  Result := False;
end;
{$ELSE}
function QueueOutputTransaction(const AData; ALen: LongInt;
  AFrame, AAppendFrame: Boolean): Boolean;
var
  Tail, FirstPart: LongInt;
  Src: PByte;
  Overflow: Boolean;
begin
  Result := False;
  if ALen <= 0 then
    Exit(True);
  if not OutputLockInitialized then
    Exit;
  Overflow := False;
  EnterCriticalSection(OutputLock);
  try
    if OutputFailed or (not AsyncOutputActive) then
      Exit;
    if AFrame and (OutputCount <> 0) and (not AAppendFrame) then
      Exit
    else if ALen > Length(OutputRing) - OutputCount then
      Overflow := True
    else
    begin
      Tail := OutputHead + OutputCount;
      if Tail >= Length(OutputRing) then
        Dec(Tail, Length(OutputRing));
      FirstPart := Length(OutputRing) - Tail;
      if FirstPart > ALen then
        FirstPart := ALen;
      Src := @AData;
      Move(Src^, OutputRing[Tail], FirstPart);
      if FirstPart < ALen then
      begin
        Inc(Src, FirstPart);
        Move(Src^, OutputRing[0], ALen - FirstPart);
      end;
      Inc(OutputCount, ALen);
      if AFrame then
        OutputFrameRemaining := ALen;
      Result := True;
    end;
  finally
    LeaveCriticalSection(OutputLock);
  end;
  if Overflow then
  begin
    MarkOutputFailure(Format('bounded queue overflow append=%d cap=%d',
      [ALen, Length(OutputRing)]));
    Exit(False);
  end;
  if Result then
    SignalPipe(OutputWakePipe[1]);
end;
{$ENDIF}

function QueueOutputBytes(const AData; ALen: LongInt): Boolean;
begin
  Result := QueueOutputTransaction(AData, ALen, False, False);
end;

function QueueOutputFrame(const S: AnsiString;
  AAppendFrame: Boolean = False): Boolean;
begin
  if S = '' then
    Exit(True);
  Result := QueueOutputTransaction(S[1], Length(S), True, AAppendFrame);
end;

{$IFDEF WINDOWS}
// Diagnostic tee: SUPERTERM_TEE=path copies every byte written to the console
// into that file, and path.idx records "offset length tick" per write, so a
// frame can be replayed byte-for-byte outside superterm.
var
  TeeData: THandle = INVALID_HANDLE_VALUE;
  TeeIndex: THandle = INVALID_HANDLE_VALUE;
  TeeResolved: Boolean = False;
  TeeOffset: Int64 = 0;

procedure TeeWrite(const AData; ALen: LongInt);
var
  Written: DWORD;
  FN: string;
  Line: AnsiString;
begin
  if not TeeResolved then
  begin
    TeeResolved := True;
    FN := SysUtils.GetEnvironmentVariable('SUPERTERM_TEE');
    if FN = '' then
      Exit;
    TeeData := CreateFileW(PWideChar(UnicodeString(FN)), GENERIC_WRITE,
      FILE_SHARE_READ, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    TeeIndex := CreateFileW(PWideChar(UnicodeString(FN + '.idx')),
      GENERIC_WRITE, FILE_SHARE_READ, nil, CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, 0);
  end;
  if (TeeData = INVALID_HANDLE_VALUE) or (ALen <= 0) then
    Exit;
  Written := 0;
  WriteFile(TeeData, AData, DWORD(ALen), Written, nil);
  if TeeIndex <> INVALID_HANDLE_VALUE then
  begin
    Line := Format('%d %d %d'#13#10, [TeeOffset, ALen, GetTickCount64]);
    WriteFile(TeeIndex, Line[1], DWORD(Length(Line)), Written, nil);
  end;
  Inc(TeeOffset, ALen);
end;
{$ENDIF}

function RawWriteBlocking(const AData; ALen: LongInt): Boolean;
var
  P: PByte;
  Left: LongInt;
  Written: Int64;
begin
  {$IFDEF WINDOWS}TeeWrite(AData, ALen);{$ENDIF}
  Result := False;
  if ALen <= 0 then
    Exit(True);
  P := @AData;
  Left := ALen;
  while Left > 0 do
  begin
    Written := FileWrite(StdOutputHandle, P^, Left);
    if Written <= 0 then
      Exit;
    Inc(P, Written);
    Dec(Left, LongInt(Written));
  end;
  Result := True;
end;

{$push}{$notes off}{$hints off}
function RawWriteBestEffort(const AData; ALen: LongInt): Boolean;
{$IFDEF WINDOWS}
begin
  // Only reached after a bounded-queue teardown failure, which Windows cannot
  // enter because it never activates the reactor. Kept defined, and honest:
  // the ordinary console writer is the only physical output path here.
  Result := RawWriteBlocking(AData, ALen);
end;
{$ELSE}
var
  N: ssize_t;
begin
  Result := False;
  if (ALen <= 0) or (OutputHandle < 0) then
    Exit(ALen <= 0);
  repeat
    N := fpWrite(OutputHandle, AData, ALen);
  until (N >= 0) or (fpGetErrNo <> ESysEINTR);
  Result := N = ALen;
end;
{$ENDIF}
{$pop}

{$IFDEF WINDOWS}
const
  ENABLE_VIRTUAL_TERMINAL_PROCESSING_ = $0004;
  DISABLE_NEWLINE_AUTO_RETURN_        = $0008;

var
  SavedOutMode: DWORD = 0;
  SavedOutputCP: UINT = 0;
  OutModeSaved: Boolean = False;
  OutputCPSaved: Boolean = False;

// Put the Windows console into VT mode: the output side interprets the ANSI
// escapes st_video emits (colours, cursor, alternate screen), and the input
// side delivers keys and mouse as the same VT byte stream st_kbd already
// decodes on Unix. Without this, conhost prints the escapes literally. Windows
// Terminal enables output VT by default; doing it explicitly covers plain
// conhost on Windows 10 1809+ too.
procedure EnableVTConsole;
var
  HOut: THandle;
  M: DWORD;
begin
  M := 0;
  HOut := GetStdHandle(STD_OUTPUT_HANDLE);
  if (HOut <> INVALID_HANDLE_VALUE) and GetConsoleMode(HOut, M) then
  begin
    SavedOutMode := M;
    OutModeSaved := SetConsoleMode(HOut,
      M or ENABLE_VIRTUAL_TERMINAL_PROCESSING_
        or DISABLE_NEWLINE_AUTO_RETURN_);
    SavedOutputCP := GetConsoleOutputCP;
    if (SavedOutputCP <> 0) and (SavedOutputCP <> CP_UTF8) then
      OutputCPSaved := SetConsoleOutputCP(CP_UTF8);
  end;
end;

procedure RestoreVTConsole;
begin
  if OutModeSaved then
  begin
    SetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), SavedOutMode);
    OutModeSaved := False;
  end;
  if OutputCPSaved then
  begin
    SetConsoleOutputCP(SavedOutputCP);
    OutputCPSaved := False;
  end;
end;
{$ENDIF}

procedure PassthroughRaw(const Data; ALen: LongInt);
begin
  if (ALen <= 0) or VideoOutputHasFailed then
    Exit;
  if AsyncOutputActive then
  begin
    if not QueueOutputBytes(Data, ALen) then
      Exit;
  end
  else if not RawWriteBlocking(Data, ALen) then
  begin
    MarkOutputFailure('blocking passthrough write failed');
    Exit;
  end;
  if DebugActive then
    DebugLog(Format('pass: raw %d bytes straight to terminal', [ALen]));
end;

procedure HostPasteOn;
begin
  WriteRaw(#27'[?2004h');
end;

function VideoCellAt(ABuffer: PVideoBuf; AIndex: LongInt): TVideoCell; inline;
var
  Cell: PVideoCell;
begin
  { VideoBuf is dynamically allocated even though PVideoBuf has a legacy
    fixed upper bound in the RTL declaration. Use cell-sized pointer math so
    wide screens do not depend on that declaration. }
  Cell := PVideoCell(ABuffer);
  Inc(Cell, AIndex);
  Result := Cell^;
end;

procedure WriteRaw(const S: AnsiString);
var
  Started, Elapsed: QWord;
  TrackTiming: Boolean;
begin
  if (Length(S) = 0) or VideoOutputHasFailed then
    Exit;
  TrackTiming := DebugActive;
  Started := 0;
  if TrackTiming then
    Started := GetTickCount64;
  if AsyncOutputActive then
  begin
    if not QueueOutputBytes(S[1], Length(S)) then
      Exit;
  end
  else if BlockingTeardownUnsafe then
  begin
    // A terminal which did not drain the bounded runtime queue must never
    // trap teardown in a blocking stdout write. Restoration is best-effort in
    // that physically unwritable case; normal exits use the exact old path.
    RawWriteBestEffort(S[1], Length(S));
  end
  else if not RawWriteBlocking(S[1], Length(S)) then
  begin
    MarkOutputFailure('blocking write failed');
    Exit;
  end;
  if TrackTiming then
  begin
    Elapsed := GetTickCount64 - Started;
    if DebugFull or (Elapsed >= 10) then
      DebugLog(Format('video: physical-submit bytes=%d pending=%d elapsed_ms=%d',
        [Length(S), PendingOutputByteCount, Elapsed]));
  end;
end;

function VideoOutputHasFailed: Boolean;
begin
  if not OutputLockInitialized then
    Exit(OutputFailed);
  EnterCriticalSection(OutputLock);
  try
    Result := OutputFailed;
  finally
    LeaveCriticalSection(OutputLock);
  end;
end;

function VideoOutputWaitHandle: LongInt;
begin
  Result := OutputProgressPipe[0];
end;

function VideoOutputPending: Boolean;
begin
  Result := PendingOutputByteCount > 0;
end;

procedure HostBell;
begin
  WriteRaw(#7);
end;

function InputPending: Boolean;
{$IFDEF WINDOWS}
begin
  // Frame coalescing only needs "is there something to read right now"; a
  // signalled console input handle answers that without blocking. Any pending
  // record (key or mouse) counts, which is exactly what we want.
  Result := WaitForSingleObject(GetStdHandle(STD_INPUT_HANDLE), 0)
    = WAIT_OBJECT_0;
end;
{$ELSE}
var
  fds: TFDSet;
  tv: TTimeVal;
begin
  fpFD_ZERO(fds);
  fpFD_SET(StdInputHandle, fds);
  tv.tv_sec := 0;
  tv.tv_usec := 0;
  InputPending := fpSelect(StdInputHandle + 1, @fds, nil, nil, @tv) > 0;
end;
{$ENDIF}

function VgaColorToAnsi(AColor: Byte; AForeground: Boolean): Integer;
var
  Base: Byte;
begin
  Base := AColor and $07;
  case Base of
    0: Base := 0;
    1: Base := 4;
    2: Base := 2;
    3: Base := 6;
    4: Base := 1;
    5: Base := 5;
    6: Base := 3;
  else
    Base := 7;
  end;
  if AForeground then
    if (AColor and $08) <> 0 then
      Result := 90 + Base
    else
      Result := 30 + Base
  else if (AColor and $08) <> 0 then
    Result := 100 + Base
  else
    Result := 40 + Base;
end;

function AttrSequence(AAttr: Byte): AnsiString;
var
  Foreground, Background: Byte;
begin
  Foreground := AAttr and $0F;
  Background := (AAttr shr 4) and $0F;
  Result := #27'[0;' + IntToStr(VgaColorToAnsi(Foreground, True)) + ';';
  // Only black is forced: every other colour is left as its palette index, so
  // a themed terminal keeps its own idea of blue, cyan and the rest. The text
  // colour is never touched either -- it is the ground that has to be solid.
  if SolidBackground and (Background = 0) then
    Result := Result + '48;2;0;0;0m'
  else
    Result := Result + IntToStr(VgaColorToAnsi(Background, False)) + 'm';
end;

function Utf8VgaChar(AChar: Byte): AnsiString;
begin
  if (AChar >= 32) and (AChar < 127) then
    Exit(AnsiChar(AChar));
  case AChar of
    0: Result := ' ';
    1: Result := '☺';
    2: Result := '☻';
    3: Result := '♥';
    4: Result := '♦';
    5: Result := '♣';
    6: Result := '♠';
    7: Result := '•';
    8: Result := '█';
    9: Result := '○';
    10: Result := '◙';
    11: Result := '♂';
    12: Result := '♀';
    13: Result := '♪';
    14: Result := '♫';
    15: Result := '☼';
    16: Result := '►';
    17: Result := '◄';
    18: Result := '↕';
    19: Result := '‼';
    20: Result := '¶';
    21: Result := '§';
    22: Result := '▬';
    23: Result := '↨';
    24: Result := '↑';
    25: Result := '↓';
    26: Result := '→';
    27: Result := '←';
    28: Result := '∟';
    29: Result := '↔';
    30: Result := '▲';
    31: Result := '▼';
    129: Result := 'ü';
    130: Result := 'é';
    144: Result := 'É';
    160: Result := 'á';
    161: Result := 'í';
    162: Result := 'ó';
    163: Result := 'ú';
    164: Result := 'ñ';
    165: Result := 'Ñ';
    176: Result := '░';
    177: Result := '▒';
    178: Result := '▓';
    179: Result := '│';
    180: Result := '┤';
    181: Result := '╡';
    182: Result := '╢';
    185: Result := '╣';
    186: Result := '║';
    187: Result := '╗';
    188: Result := '╝';
    191: Result := '┐';
    192: Result := '└';
    193: Result := '┴';
    194: Result := '┬';
    195: Result := '├';
    196: Result := '─';
    197: Result := '┼';
    199: Result := '╟';
    200: Result := '╚';
    201: Result := '╔';
    202: Result := '╩';
    203: Result := '╦';
    204: Result := '╠';
    205: Result := '═';
    206: Result := '╬'; // canonical CP437 (0xCE is the double cross)
    207: Result := '╧';
    209: Result := '╤';
    217: Result := '┘';
    218: Result := '┌';
    219: Result := '█';
    220: Result := '▄';
    223: Result := '▀';
    {$IFDEF DARWIN}
    235: Result := '⌥';  // Option-key symbol for shortcut labels (KEY_ALT)
    {$ENDIF}
    250: Result := '·';
    254: Result := '■';
  else
    Result := '?';
end;
end;

// Convert the CP437 presentation byte used throughout FreeVision to either
// UTF-8 or the 7-bit DEC Alternate Character Set.  DEC ACS is deliberately
// represented as a glyph plus a state flag: the frame emitter can keep ACS
// selected across a whole run instead of wrapping every cell in two escape
// sequences.  Unsupported symbols degrade to one printable ASCII cell.
procedure PresentedVgaChar(AChar: Byte; out AGlyph: AnsiString;
  out AACS: Boolean);
begin
  AACS := False;
  if HostUtf8 then
  begin
    AGlyph := Utf8VgaChar(AChar);
    Exit;
  end;
  if (AChar >= 32) and (AChar < 127) then
  begin
    AGlyph := AnsiChar(AChar);
    Exit;
  end;
  case AChar of
    0: AGlyph := ' ';
    16, 26: AGlyph := '>';
    17: AGlyph := '<';
    18: AGlyph := '|';
    24, 30: AGlyph := '^';
    25, 31: AGlyph := 'v';
    27: AGlyph := '<';
    29: AGlyph := '-';
    129: AGlyph := 'u';
    130: AGlyph := 'e';
    144: AGlyph := 'E';
    160: AGlyph := 'a';
    161: AGlyph := 'i';
    162: AGlyph := 'o';
    163: AGlyph := 'u';
    164: AGlyph := 'n';
    165: AGlyph := 'N';
    8, 176, 177, 178, 219, 220, 223:
      begin AGlyph := 'a'; AACS := True; end;  // checkerboard/shade
    180, 181, 182, 185:
      begin AGlyph := 'u'; AACS := True; end;  // right junction
    183, 184, 187, 191:
      begin AGlyph := 'k'; AACS := True; end;  // upper-right
    188, 189, 190, 217:
      begin AGlyph := 'j'; AACS := True; end;  // lower-right
    192, 200, 211, 212:
      begin AGlyph := 'm'; AACS := True; end;  // lower-left
    193, 202, 207, 208:
      begin AGlyph := 'v'; AACS := True; end;  // bottom junction
    194, 203, 209, 210:
      begin AGlyph := 'w'; AACS := True; end;  // top junction
    195, 198, 199, 204:
      begin AGlyph := 't'; AACS := True; end;  // left junction
    196, 205:
      begin AGlyph := 'q'; AACS := True; end;  // horizontal
    179, 186:
      begin AGlyph := 'x'; AACS := True; end;  // vertical
    197, 206, 215, 216:
      begin AGlyph := 'n'; AACS := True; end;  // crossing
    201, 213, 214, 218:
      begin AGlyph := 'l'; AACS := True; end;  // upper-left
    1, 2, 7, 9, 10: AGlyph := 'o';
    3..6, 13..15, 22, 254: AGlyph := '*';
    {$IFDEF DARWIN}
    235: AGlyph := '*';  // KEY_ALT on a 7-bit host: degrade like the suits do
    {$ENDIF}
    11: AGlyph := 'M';
    12: AGlyph := 'F';
    19: AGlyph := '!';
    20: AGlyph := 'P';
    21: AGlyph := 'S';
    23: AGlyph := '^';
    28: AGlyph := '+';
    250: AGlyph := '.';
  else
    AGlyph := '?';
  end;
end;

function CursorPosition(AX, AY: Word): AnsiString;
begin
  Result := #27'[' + IntToStr(AY + 1) + ';' + IntToStr(AX + 1) + 'H';
end;

function CursorTypeSequence(AType: Word): AnsiString;
begin
  case AType of
    crHidden: Result := #27'[?25l';
    crBlock: Result := #27'[2 q'#27'[?25h';
  else
    // crUnderline and the platform fallbacks use a steady underline. A host
    // which does not implement DECSCUSR simply ignores the style selector and
    // still honours the standard visibility sequence.
    Result := #27'[4 q'#27'[?25h';
  end;
end;

procedure QueueLatestCursorState;
var
  S: AnsiString;
  QueueIsEmpty: Boolean;
begin
  if not AsyncOutputActive or VideoOutputHasFailed or
     (not CursorStateDirty) then
    Exit;
  EnterCriticalSection(OutputLock);
  try
    QueueIsEmpty := OutputCount = 0;
  finally
    LeaveCriticalSection(OutputLock);
  end;
  if not QueueIsEmpty or DeferredFrame then
    Exit;
  S := '';
  if (QueuedCursorX <> CursorX) or (QueuedCursorY <> CursorY) then
    S := CursorPosition(CursorX, CursorY);
  if QueuedCursorType <> DesiredCursorType then
    S := S + CursorTypeSequence(DesiredCursorType);
  if (S = '') or QueueOutputBytes(S[1], Length(S)) then
  begin
    QueuedCursorX := CursorX;
    QueuedCursorY := CursorY;
    QueuedCursorType := DesiredCursorType;
    CursorStateDirty := False;
  end;
end;

procedure WideSetCursorPos(NewCursorX, NewCursorY: Word);
begin
  if (CursorX = NewCursorX) and (CursorY = NewCursorY) then
    Exit;
  CursorX := NewCursorX;
  CursorY := NewCursorY;
  CursorStateDirty := True;
  if AsyncOutputActive then
    QueueLatestCursorState
  else
    WriteRaw(CursorPosition(NewCursorX, NewCursorY));
end;

function WideGetCursorType: Word;
begin
  Result := DesiredCursorType;
end;

procedure WideSetCursorType(NewType: Word);
begin
  if DesiredCursorType = NewType then
    Exit;
  DesiredCursorType := NewType;
  CursorStateDirty := True;
  if AsyncOutputActive then
    QueueLatestCursorState
  else
    WriteRaw(CursorTypeSequence(NewType));
end;

function PumpVideoOutput: Boolean;
var
  QueueIsEmpty: Boolean;
begin
  DrainPipe(OutputProgressPipe[0]);
  if not AsyncOutputActive then
    Exit(False);
  EnterCriticalSection(OutputLock);
  try
    QueueIsEmpty := OutputCount = 0;
  finally
    LeaveCriticalSection(OutputLock);
  end;
  Result := QueueIsEmpty and DeferredFrame;
  if QueueIsEmpty and (not DeferredFrame) then
    QueueLatestCursorState;
end;

type
  // overlay entry populated by panes; persists across frames and is gated at
  // emission time by Oracle = VideoBuf (so a covered/scrolled cell falls back
  // to chrome automatically without any explicit invalidation)
  TRichCell = record
    Valid: Boolean;
    Skip: Boolean;      // wide-glyph continuation: emit nothing here
    Wide: Boolean;      // lead of a two-column glyph
    Shadowable: Boolean; // desktop art may dim; terminal content never does
    Oracle: Word;       // the VideoBuf word the pane wrote at this cell
    Glyph: string[7];   // UTF-8 bytes to emit
    Fg, Bg: LongWord;
    Flags: Byte;
  end;
  // the per-cell "effective" screen the delta is computed against: either a
  // rich pane cell or a chrome cell, unified so one diff covers both
  TEffCell = record
    Skip: Boolean;
    Rich: Boolean;
    Wide: Boolean;
    ACS: Boolean;
    Glyph: string[7];
    Attr: Byte;         // chrome path (VGA attribute byte)
    Fg, Bg: LongWord;   // rich path
    Flags: Byte;
  end;
  TTransientOutline = record
    Active: Boolean;
    Locked: Boolean;
    X1, Y1, X2, Y2: LongInt;
    Attr: Byte;
  end;

const
  COALESCE_MS = 40;   // never defer a frame longer than this: ~25 fps floor
  // FreeVision draws a view's shadow by KEEPING the character underneath and
  // forcing its attribute to ShadowAttr (vendor/fv322/views.pas:688, applied
  // in do_writeViewRec1). Naming the unit from here would be circular, so the
  // value is mirrored. Only rich cells explicitly registered as Shadowable
  // are dimmed; pane content keeps its exact colours in every focus state.
  FV_SHADOW_ATTR = $08;
  SHADOW_LIGHT = 34;   // percentage of an art colour left under a shadow
  Vga16Rgb: array[0..15] of LongWord = (
    $000000, $0000AA, $00AA00, $00AAAA, $AA0000, $AA00AA, $AA5500, $AAAAAA,
    $555555, $5555FF, $55FF55, $55FFFF, $FF5555, $FF55FF, $FFFF55, $FFFFFF);
  Xterm6: array[0..5] of LongWord = (0, 95, 135, 175, 215, 255);

var
  LastEmitTick: QWord = 0;
  RichScreen: array of TRichCell;   // overlay, persists across frames
  EffOld: array of TEffCell;        // previous frame's effective screen (delta)
  RichW: LongInt = 0;
  RichH: LongInt = 0;
  TransientOutlines: array[0..15] of TTransientOutline;
  TransientOutlineMask: LongWord = 0;

procedure RichEnsureSize;
var
  i: LongInt;
begin
  if (RichW = ScreenWidth) and (RichH = ScreenHeight) and (RichScreen <> nil) then
    Exit;
  RichW := ScreenWidth;
  RichH := ScreenHeight;
  SetLength(RichScreen, RichW * RichH);
  SetLength(EffOld, RichW * RichH);
  for i := 0 to High(RichScreen) do
    RichScreen[i].Valid := False;
  // sentinel that never equals a real effective cell -> first frame after a
  // resize is a full paint
  for i := 0 to High(EffOld) do
  begin
    EffOld[i].Skip := False;
    EffOld[i].Rich := False;
    EffOld[i].Glyph := #1;
    EffOld[i].Attr := $FF;
  end;
end;

procedure RichInvalidate;
var
  i: LongInt;
begin
  for i := 0 to High(RichScreen) do
    RichScreen[i].Valid := False;
end;

procedure RichClear(AX, AY: LongInt);
var
  idx: LongInt;
begin
  if (RichW <> ScreenWidth) or (RichH <> ScreenHeight) then
    RichEnsureSize;
  if (AX < 0) or (AY < 0) or (AX >= RichW) or (AY >= RichH) then
    Exit;
  idx := AY * RichW + AX;
  if (idx >= 0) and (idx <= High(RichScreen)) then
    RichScreen[idx].Valid := False;
end;

procedure InvalidateFrame;
var
  i: LongInt;
begin
  // poison the previous-frame snapshot so no cell can compare equal
  for i := 0 to High(EffOld) do
  begin
    EffOld[i].Skip := False;
    EffOld[i].Rich := False;
    EffOld[i].Glyph := #1;
    EffOld[i].Attr := $FF;
  end;
  if (OldVideoBuf <> nil) and (VideoBufSize > 0) then
    FillChar(OldVideoBuf^, VideoBufSize, $FF);
end;

procedure RichSetCell(AX, AY: LongInt; const AGlyph: AnsiString;
  AFg, ABg: LongWord; AFlags: Byte; AOracle: Word; ASkip: Boolean;
  AWide, AShadowable: Boolean);
var
  idx: LongInt;
begin
  if (RichW <> ScreenWidth) or (RichH <> ScreenHeight) then
    RichEnsureSize;
  if (AX < 0) or (AY < 0) or (AX >= RichW) or (AY >= RichH) then
    Exit;
  idx := AY * RichW + AX;
  RichScreen[idx].Valid := True;
  RichScreen[idx].Skip := ASkip;
  RichScreen[idx].Wide := AWide;
  RichScreen[idx].Shadowable := AShadowable;
  RichScreen[idx].Oracle := AOracle;
  if Length(AGlyph) > 7 then
    RichScreen[idx].Glyph := Copy(AGlyph, 1, 7)
  else
    RichScreen[idx].Glyph := AGlyph;
  RichScreen[idx].Fg := AFg;
  RichScreen[idx].Bg := ABg;
  RichScreen[idx].Flags := AFlags;
end;

// SGR for a rich cell: a full reset then bold/underline/reverse and the fg/bg
// as truecolor (38/48;2;r;g;b) or 16-color (30-37/90-97, 40-47/100-107).
// A missing color falls through to the terminal default from the leading 0.
function RichSGR(AFg, ABg: LongWord; AFlags: Byte): AnsiString;
var
  n: LongWord;
begin
  Result := #27'[0';
  if (AFlags and 1) <> 0 then Result := Result + ';1';
  if (AFlags and 8) <> 0 then Result := Result + ';2';   // faint
  if (AFlags and 2) <> 0 then Result := Result + ';4';
  if (AFlags and 4) <> 0 then Result := Result + ';7';
  case AFg shr 24 of
    1: Result := Result + ';38;2;' + IntToStr((AFg shr 16) and $FF) + ';' +
         IntToStr((AFg shr 8) and $FF) + ';' + IntToStr(AFg and $FF);
    2: begin
         n := AFg and $0F;
         if n < 8 then Result := Result + ';' + IntToStr(30 + LongInt(n))
         else Result := Result + ';' + IntToStr(90 + (LongInt(n) - 8));
       end;
    3: Result := Result + ';38;5;' + IntToStr(AFg and $FF);
  end;
  case ABg shr 24 of
    1: Result := Result + ';48;2;' + IntToStr((ABg shr 16) and $FF) + ';' +
         IntToStr((ABg shr 8) and $FF) + ';' + IntToStr(ABg and $FF);
    2: if SolidBackground and ((ABg and $0F) = 0) then
         Result := Result + ';48;2;0;0;0'
       else
       begin
         n := ABg and $0F;
         if n < 8 then Result := Result + ';' + IntToStr(40 + LongInt(n))
         else Result := Result + ';' + IntToStr(100 + (LongInt(n) - 8));
       end;
    3: if SolidBackground and ((ABg and $FF) = 0) then
         Result := Result + ';48;2;0;0;0'
       else
         Result := Result + ';48;5;' + IntToStr(ABg and $FF);
  else
    // the pane said "whatever the terminal's background is". On a
    // transparent terminal that is a hole straight through superterm, so
    // we answer for it: our screen's ground is black.
    if SolidBackground then
      Result := Result + ';48;2;0;0;0';
  end;
  Result := Result + 'm';
end;

// A rich colour as it looks below a desktop menu/dialog shadow. Pane cells do
// not call this path: their colours are application state, not window chrome.
function DimColor(AColor, ADefault: LongWord): LongWord;
var
  r, g, b, n: LongWord;
begin
  case AColor shr 24 of
    1: begin
         r := (AColor shr 16) and $FF;
         g := (AColor shr 8) and $FF;
         b := AColor and $FF;
       end;
    2: begin
         n := AColor and $0F;
         r := Vga16Rgb[n] shr 16;
         g := (Vga16Rgb[n] shr 8) and $FF;
         b := Vga16Rgb[n] and $FF;
       end;
    3: begin
         n := AColor and $FF;
         if n < 16 then
         begin
           r := Vga16Rgb[n] shr 16;
           g := (Vga16Rgb[n] shr 8) and $FF;
           b := Vga16Rgb[n] and $FF;
         end
         else if n < 232 then
         begin
           n := n - 16;
           r := Xterm6[(n div 36) mod 6];
           g := Xterm6[(n div 6) mod 6];
           b := Xterm6[n mod 6];
         end
         else
         begin
           r := 8 + (n - 232) * 10;
           g := r;
           b := r;
         end;
       end;
  else
    begin
      r := (ADefault shr 16) and $FF;
      g := (ADefault shr 8) and $FF;
      b := ADefault and $FF;
    end;
  end;
  r := (r * SHADOW_LIGHT) div 100;
  g := (g * SHADOW_LIGHT) div 100;
  b := (b * SHADOW_LIGHT) div 100;
  DimColor := $01000000 or (r shl 16) or (g shl 8) or b;
end;

// Does the rich cell at AIndex still own that position? A matching
// FreeVision shadow keeps ownership. AShadowed is True only for cells whose
// producer explicitly allows dimming (desktop art, never a terminal pane).
function RichStands(AIndex: LongInt; out AShadowed: Boolean): Boolean;
var
  W: Word;
begin
  AShadowed := False;
  if (AIndex < 0) or (AIndex > High(RichScreen)) or
     (not RichScreen[AIndex].Valid) then
    Exit(False);
  W := Word(VideoCellAt(VideoBuf, AIndex));
  if W = RichScreen[AIndex].Oracle then
    Exit(True);
  if (Byte(W and $FF) = Byte(RichScreen[AIndex].Oracle and $FF)) and
     (Byte(W shr 8) = FV_SHADOW_ATTR) and
     (Byte(RichScreen[AIndex].Oracle shr 8) <> FV_SHADOW_ATTR) then
  begin
    AShadowed := RichScreen[AIndex].Shadowable;
    Exit(True);
  end;
  RichStands := False;
end;

function EffEqual(const A, B: TEffCell): Boolean;
begin
  if A.Skip or B.Skip then Exit(A.Skip and B.Skip);
  if A.Rich <> B.Rich then Exit(False);
  if A.Glyph <> B.Glyph then Exit(False);
  if A.ACS <> B.ACS then Exit(False);
  if A.Rich then
    Result := (A.Fg = B.Fg) and (A.Bg = B.Bg) and (A.Flags = B.Flags) and
              (A.Wide = B.Wide)
  else
    Result := (A.Attr = B.Attr);
end;


// --- wireframe drag outline -------------------------------------------------

// Ring cells of a rectangle, CLIPPED to the screen. A dragged window is
// routinely pushed partly off-screen, and bailing out on an out-of-range
// rectangle meant the outline was neither painted nor erased -- the frame
// vanished and left debris behind. Clip instead, and draw what is visible.

function OnScreen(X, Y: LongInt): Boolean; inline;
begin
  OnScreen := (X >= 0) and (Y >= 0) and (X < ScreenWidth) and (Y < ScreenHeight);
end;

procedure OutlineInvalidate(X1, Y1, X2, Y2: LongInt);
var
  X, Y: LongInt;

  procedure Poison(AX, AY: LongInt);
  var
    idx: LongInt;
  begin
    if not OnScreen(AX, AY) then
      Exit;
    idx := AY * RichW + AX;
    if (idx < 0) or (idx > High(EffOld)) then
      Exit;
    EffOld[idx].Skip := False;
    EffOld[idx].Rich := False;
    EffOld[idx].Glyph := #1;      // no real cell can compare equal to this
    EffOld[idx].Attr := $FF;
  end;

begin
  if (RichW <> ScreenWidth) or (RichH <> ScreenHeight) then
    RichEnsureSize;
  if (X2 < X1) or (Y2 < Y1) then
    Exit;
  for X := X1 to X2 do
  begin
    Poison(X, Y1);
    if Y2 <> Y1 then Poison(X, Y2);
  end;
  for Y := Y1 + 1 to Y2 - 1 do
  begin
    Poison(X1, Y);
    if X2 <> X1 then Poison(X2, Y);
  end;
end;


function OnRing(X, Y, X1, Y1, X2, Y2: LongInt): Boolean;
begin
  OnRing := (X >= X1) and (X <= X2) and (Y >= Y1) and (Y <= Y2) and
            ((X = X1) or (X = X2) or (Y = Y1) or (Y = Y2));
end;

// CP437 presentation byte for a position on a ring.  Keeping this as CP437
// lets the same geometry feed either the UTF-8 or DEC-ACS client renderer.
function RingVgaChar(X, Y, X1, Y1, X2, Y2: LongInt): Byte;
begin
  if (X = X1) and (Y = Y1) then RingVgaChar := 218
  else if (X = X2) and (Y = Y1) then RingVgaChar := 191
  else if (X = X1) and (Y = Y2) then RingVgaChar := 192
  else if (X = X2) and (Y = Y2) then RingVgaChar := 217
  else if (Y = Y1) or (Y = Y2) then RingVgaChar := 196
  else RingVgaChar := 179;
end;

// A remote owner is shown with the same visual vocabulary as TTermFrame's
// locked border: CP437 176/177 become U+2591/U+2592, and LOCK is written down
// the left edge.  The actor keeps the ordinary line-drawing ring; only other
// clients receive this form, so ownership remains unambiguous while the real
// window is hidden for a wireframe drag.
function LockedRingVgaChar(X, Y, X1, Y1, X2, Y2: LongInt): Byte;
const
  LOCK_TEXT = 'LOCK';
var
  Height, Start, Pos: LongInt;
begin
  Height := Y2 - Y1 + 1;
  if (X = X1) and (Height >= 6) then
  begin
    Start := (Height - Length(LOCK_TEXT)) div 2;
    if Start < 1 then Start := 1;
    Pos := Y - (Y1 + Start) + 1;
    if (Pos >= 1) and (Pos <= Length(LOCK_TEXT)) then
      Exit(Byte(LOCK_TEXT[Pos]));
  end;
  if (X = X1) or (X = X2) then
    Result := 177
  else
    Result := 176;
end;

// Poison a changed ring and its horizontal neighbours. A rich wide glyph is
// represented by a lead and a continuation cell; an outline can cover either
// half. Invalidating the neighbour as well guarantees the pair is re-emitted
// together when an outline appears, moves or disappears.
procedure InvalidateTransientRingPairs(X1, Y1, X2, Y2: LongInt);
var
  X, Y, FirstX, LastX, FirstY, LastY: LongInt;

  procedure Poison(AX, AY: LongInt);
  var
    Index: LongInt;
  begin
    if (AX < 0) or (AY < 0) or (AX >= ScreenWidth) or
       (AY >= ScreenHeight) then
      Exit;
    Index := AY * RichW + AX;
    if (Index < 0) or (Index > High(EffOld)) then
      Exit;
    EffOld[Index].Skip := False;
    EffOld[Index].Rich := False;
    EffOld[Index].Glyph := #1;
    EffOld[Index].Attr := $FF;
  end;

  procedure PoisonPair(AX, AY: LongInt);
  begin
    Poison(AX - 1, AY);
    Poison(AX, AY);
    Poison(AX + 1, AY);
  end;

begin
  if (ScreenWidth <= 0) or (ScreenHeight <= 0) or
     (X2 < X1) or (Y2 < Y1) then
    Exit;
  if (RichW <> ScreenWidth) or (RichH <> ScreenHeight) then
    RichEnsureSize;
  FirstX := X1;
  if FirstX < 0 then FirstX := 0;
  LastX := X2;
  if LastX >= ScreenWidth then LastX := ScreenWidth - 1;
  FirstY := Y1;
  if FirstY < 0 then FirstY := 0;
  LastY := Y2;
  if LastY >= ScreenHeight then LastY := ScreenHeight - 1;
  if (FirstX > LastX) or (FirstY > LastY) then
    Exit;
  for X := FirstX to LastX do
  begin
    PoisonPair(X, Y1);
    if Y2 <> Y1 then PoisonPair(X, Y2);
  end;
  // Include the clipped endpoints too. When the real top/bottom lies outside
  // the screen, the first visible cell is part of a vertical edge rather than
  // a horizontal one and still has to be invalidated.
  for Y := FirstY to LastY do
  begin
    if (X1 >= 0) and (X1 < ScreenWidth) then
      PoisonPair(X1, Y);
    if (X2 <> X1) and (X2 >= 0) and (X2 < ScreenWidth) then
      PoisonPair(X2, Y);
  end;
end;


procedure TransientOutlineSet(ASlot, X1, Y1, X2, Y2: LongInt; AAttr: Byte;
  ALocked: Boolean);
begin
  if (ASlot < Low(TransientOutlines)) or
     (ASlot > High(TransientOutlines)) then
    Exit;
  // Match OutlinePaint's definition of a drawable rectangle. Treating a
  // degenerate Set as Clear also prevents an invisible active slot lingering.
  if (X2 <= X1) or (Y2 <= Y1) then
  begin
    TransientOutlineClear(ASlot);
    Exit;
  end;
  if TransientOutlines[ASlot].Active and
     (TransientOutlines[ASlot].X1 = X1) and
     (TransientOutlines[ASlot].Y1 = Y1) and
     (TransientOutlines[ASlot].X2 = X2) and
     (TransientOutlines[ASlot].Y2 = Y2) and
     (TransientOutlines[ASlot].Attr = AAttr) and
     (TransientOutlines[ASlot].Locked = ALocked) then
    Exit;
  if TransientOutlines[ASlot].Active then
    InvalidateTransientRingPairs(TransientOutlines[ASlot].X1,
      TransientOutlines[ASlot].Y1, TransientOutlines[ASlot].X2,
      TransientOutlines[ASlot].Y2);
  TransientOutlines[ASlot].Active := True;
  TransientOutlines[ASlot].X1 := X1;
  TransientOutlines[ASlot].Y1 := Y1;
  TransientOutlines[ASlot].X2 := X2;
  TransientOutlines[ASlot].Y2 := Y2;
  TransientOutlines[ASlot].Attr := AAttr;
  TransientOutlines[ASlot].Locked := ALocked;
  TransientOutlineMask := TransientOutlineMask or
    (LongWord(1) shl ASlot);
  InvalidateTransientRingPairs(X1, Y1, X2, Y2);
end;


procedure TransientOutlineClear(ASlot: LongInt);
begin
  if (ASlot < Low(TransientOutlines)) or
     (ASlot > High(TransientOutlines)) or
     (not TransientOutlines[ASlot].Active) then
    Exit;
  InvalidateTransientRingPairs(TransientOutlines[ASlot].X1,
    TransientOutlines[ASlot].Y1, TransientOutlines[ASlot].X2,
    TransientOutlines[ASlot].Y2);
  TransientOutlines[ASlot] := Default(TTransientOutline);
  TransientOutlineMask := TransientOutlineMask and
    not (LongWord(1) shl ASlot);
end;


procedure TransientOutlineClearAll;
var
  Slot: LongInt;
begin
  for Slot := Low(TransientOutlines) to High(TransientOutlines) do
    TransientOutlineClear(Slot);
end;


function TransientOutlineActive(ASlot: LongInt): Boolean;
begin
  if (ASlot < Low(TransientOutlines)) or
     (ASlot > High(TransientOutlines)) then
    Exit(False);
  Result := TransientOutlines[ASlot].Active;
end;


function TransientOutlineCell(X, Y: LongInt; out AGlyph: AnsiString;
  out AAttr: Byte; out AACS: Boolean): Boolean;
var
  Slot: LongInt;
begin
  Result := False;
  AGlyph := '';
  AAttr := 0;
  AACS := False;
  if TransientOutlineMask = 0 then
    Exit;
  // Higher slots win at intersections. Walking downwards makes that priority
  // explicit and independent of update/arrival order.
  for Slot := High(TransientOutlines) downto Low(TransientOutlines) do
    if ((TransientOutlineMask and (LongWord(1) shl Slot)) <> 0) and
       TransientOutlines[Slot].Active and
       OnRing(X, Y, TransientOutlines[Slot].X1,
         TransientOutlines[Slot].Y1, TransientOutlines[Slot].X2,
         TransientOutlines[Slot].Y2) then
    begin
      if TransientOutlines[Slot].Locked then
        PresentedVgaChar(LockedRingVgaChar(X, Y,
          TransientOutlines[Slot].X1, TransientOutlines[Slot].Y1,
          TransientOutlines[Slot].X2, TransientOutlines[Slot].Y2),
          AGlyph, AACS)
      else
        PresentedVgaChar(RingVgaChar(X, Y, TransientOutlines[Slot].X1,
          TransientOutlines[Slot].Y1, TransientOutlines[Slot].X2,
          TransientOutlines[Slot].Y2), AGlyph, AACS);
      AAttr := TransientOutlines[Slot].Attr;
      Exit(True);
    end;
end;


function TransientOutlineAt(X, Y: LongInt): Boolean; inline;
var
  Slot: LongInt;
begin
  Result := False;
  if TransientOutlineMask = 0 then
    Exit;
  for Slot := High(TransientOutlines) downto Low(TransientOutlines) do
    if ((TransientOutlineMask and (LongWord(1) shl Slot)) <> 0) and
       TransientOutlines[Slot].Active and
       OnRing(X, Y, TransientOutlines[Slot].X1,
         TransientOutlines[Slot].Y1, TransientOutlines[Slot].X2,
         TransientOutlines[Slot].Y2) then
      Exit(True);
end;


procedure OutlineLeaveDiff(OX1, OY1, OX2, OY2, NX1, NY1, NX2, NY2: LongInt);
var
  X, Y: LongInt;

  procedure Maybe(AX, AY: LongInt);
  begin
    if OnRing(AX, AY, NX1, NY1, NX2, NY2) then
      Exit;                       // still covered by the outline: leave it
    OutlineInvalidate(AX, AY, AX, AY);
  end;

begin
  for X := OX1 to OX2 do
  begin
    Maybe(X, OY1);
    if OY2 <> OY1 then Maybe(X, OY2);
  end;
  for Y := OY1 + 1 to OY2 - 1 do
  begin
    Maybe(OX1, Y);
    if OX2 <> OX1 then Maybe(OX2, Y);
  end;
end;

procedure OutlineEnterDiff(NX1, NY1, NX2, NY2, OX1, OY1, OX2, OY2: LongInt;
  AAttr: Byte);
var
  X, Y: LongInt;
  Body, G: AnsiString;
  LastX, LastY: LongInt;
  ACSActive, GACS: Boolean;

  procedure AppendVga(AChar: Byte);
  begin
    PresentedVgaChar(AChar, G, GACS);
    if GACS <> ACSActive then
    begin
      if GACS then Body := Body + #27'(0'
      else Body := Body + #27'(B';
      ACSActive := GACS;
    end;
    Body := Body + G;
  end;

  procedure Put(AX, AY: LongInt; Corner: Boolean);
  begin
    if not OnScreen(AX, AY) then
      Exit;
    if Corner then ;   // corners always differ in glyph, handled by the test
    // A cell already under the outline may still need redrawing: staying on
    // the ring is not enough, its GLYPH can change. Moving one step
    // horizontally or vertically keeps two corners on the ring but turns them
    // into edge segments (and edges into corners), so skipping them left a
    // corner glyph sitting in the middle of a straight side. Compare the
    // glyphs, not the membership. (Diagonal steps never showed it because no
    // corner is shared.)
    if OnRing(AX, AY, OX1, OY1, OX2, OY2) and
       (RingVgaChar(AX, AY, OX1, OY1, OX2, OY2) =
        RingVgaChar(AX, AY, NX1, NY1, NX2, NY2)) then
      Exit;
    if (AY <> LastY) or (AX <> LastX + 1) then
      Body := Body + CursorPosition(AX, AY);
    LastX := AX;
    LastY := AY;
    AppendVga(RingVgaChar(AX, AY, NX1, NY1, NX2, NY2));
  end;

begin
  if PassthroughActive or VideoOutputHasFailed then
    Exit;
  if (NX2 <= NX1) or (NY2 <= NY1) then
    Exit;
  Body := AttrSequence(AAttr);
  ACSActive := False;
  LastX := -99;
  LastY := -99;
  Put(NX1, NY1, True);
  Put(NX2, NY1, True);
  Put(NX1, NY2, True);
  Put(NX2, NY2, True);
  for X := NX1 + 1 to NX2 - 1 do
  begin
    Put(X, NY1, False);
    Put(X, NY2, False);
  end;
  for Y := NY1 + 1 to NY2 - 1 do
  begin
    Put(NX1, Y, False);
    Put(NX2, Y, False);
  end;
  if ACSActive then
    Body := Body + #27'(B';
  WriteRaw(Body);
end;

procedure OutlinePaint(X1, Y1, X2, Y2: LongInt; AAttr: Byte);
var
  X, Y: LongInt;
  Body, G: AnsiString;
  ACSActive, GACS: Boolean;

  procedure AppendVga(AChar: Byte);
  begin
    PresentedVgaChar(AChar, G, GACS);
    if GACS <> ACSActive then
    begin
      if GACS then Body := Body + #27'(0'
      else Body := Body + #27'(B';
      ACSActive := GACS;
    end;
    Body := Body + G;
  end;

  procedure Put(AX, AY: LongInt; AChar: Byte);
  begin
    if not OnScreen(AX, AY) then
      Exit;
    Body := Body + CursorPosition(AX, AY);
    AppendVga(AChar);
  end;

begin
  if PassthroughActive or VideoOutputHasFailed then
    Exit;
  if (X2 <= X1) or (Y2 <= Y1) then
    Exit;
  Body := AttrSequence(AAttr);
  ACSActive := False;
  // horizontal edges as runs (one cursor move each), verticals cell by cell
  Put(X1, Y1, 218);
  for X := X1 + 1 to X2 - 1 do
    if OnScreen(X, Y1) then
    begin
      if not OnScreen(X - 1, Y1) then Body := Body + CursorPosition(X, Y1);
      AppendVga(196);
    end;
  if OnScreen(X2, Y1) then
  begin
    if not OnScreen(X2 - 1, Y1) then Body := Body + CursorPosition(X2, Y1);
    AppendVga(191);
  end;
  Put(X1, Y2, 192);
  for X := X1 + 1 to X2 - 1 do
    if OnScreen(X, Y2) then
    begin
      if not OnScreen(X - 1, Y2) then Body := Body + CursorPosition(X, Y2);
      AppendVga(196);
    end;
  if OnScreen(X2, Y2) then
  begin
    if not OnScreen(X2 - 1, Y2) then Body := Body + CursorPosition(X2, Y2);
    AppendVga(217);
  end;
  for Y := Y1 + 1 to Y2 - 1 do
  begin
    Put(X1, Y, 179);
    Put(X2, Y, 179);
  end;
  if ACSActive then
    Body := Body + #27'(B';
  WriteRaw(Body);
end;

// Builds the whole frame in one buffer and emits it with a SINGLE write,
// wrapped in DECSET 2026 synchronized output. Over SSH this collapses the
// hundreds of tiny writes the per-run approach produced into one segment,
// which is what made moving/resizing windows feel laggy; the terminal also
// paints the frame atomically (no tearing). Terminals without 2026 ignore it.
procedure WideUpdateScreen(Force: Boolean);
var
  X, Y, Index, Nx: LongInt;
  VCell: TVideoCell;
  Eff: TEffCell;
  NeedMove, Shadowed, NShadow, OverlayHere, OverlayACS, ACSActive,
    CellACS: Boolean;
  OutCursorX, OutCursorY: Word;
  Body, Frame, CursorTail, CurSGR, LastSGR, OverlayGlyph,
    CellGlyph: AnsiString;
  OverlayAttr: Byte;
  ChangedCells, Runs, RHit, RMiss: LongInt;
begin
  if PassthroughActive then
  begin
    if DebugActive then
      DebugLog('video: update SUPPRESSED (passthrough owns the terminal)');
    Exit;   // the pane owns the terminal; FreeVision must not write over it
  end;
  if SuppressFlush then
  begin
    if DebugActive then
      DebugLog('video: flush suppressed (booting; buffer kept, no write)');
    Exit;   // booting: draw into the buffer only; one forced flush at the end
  end;
  if (VideoBuf = nil) or (OldVideoBuf = nil) or
     (ScreenWidth = 0) or (ScreenHeight = 0) then
    Exit;
  // A physical frame already admitted to the output reactor is immutable and
  // is never abandoned halfway through an ANSI transaction. Do not advance
  // EffOld again while it is pending. Once the reactor reports completion,
  // the next call diffs the latest VideoBuf against that actually admitted
  // baseline, coalescing every superseded intermediate presentation.
  if AsyncOutputActive and VideoOutputPending and
     (not OrderedFrameAdmission) then
  begin
    DeferredFrame := True;
    Exit;
  end;
  DeferredFrame := False;
  // Coalesce: if more input is already queued, this frame is about to be
  // superseded, so skip it and let the NEXT one emit the accumulated delta.
  // EffOld is only advanced by cells we actually emit, so skipping is safe.
  // The time bound keeps at least ~25 frames a second under continuous input.
  if (not OrderedFrameAdmission) and InputPending and
     (GetTickCount64 - LastEmitTick < COALESCE_MS) then
  begin
    // This may itself be the retry of a frame deferred behind physical
    // output. Keep the latest-state obligation alive: clearing it here loses
    // the final canonical paint when the pending input causes no later draw.
    DeferredFrame := True;
    if DebugActive then
      DebugLog('video: frame coalesced (more input already waiting)');
    Exit;
  end;
  LastEmitTick := GetTickCount64;

  RichEnsureSize;
  // TransientOutlineCell initializes both out parameters on every call.  Set
  // an explicit baseline here as well: FPC -O4 does not propagate that fact
  // through the helper and otherwise reports two false uninitialized-value
  // warnings at the overlay assignment below.
  OverlayGlyph := '';
  CellGlyph := '';
  OverlayAttr := 0;
  OverlayACS := False;
  Body := '';
  ACSActive := False;
  ChangedCells := 0;
  Runs := 0;
  RHit := 0;
  RMiss := 0;
  LastSGR := #0;   // impossible SGR: the first emitted cell always sets color
  for Y := 0 to ScreenHeight - 1 do
  begin
    NeedMove := True;   // start of a row is always a discontinuity
    for X := 0 to ScreenWidth - 1 do
    begin
      Index := Y * ScreenWidth + X;
      VCell := VideoCellAt(VideoBuf, Index);
      // effective cell: the rich pane cell when its oracle still stands in
      // VideoBuf (visible top cell), otherwise the CP437/16-color chrome
      if RichScreen[Index].Valid then
        if Word(VCell) = RichScreen[Index].Oracle then Inc(RHit) else Inc(RMiss);
      if HostUtf8 and RichStands(Index, Shadowed) then
      begin
        Eff.Skip := RichScreen[Index].Skip;
        Eff.Wide := RichScreen[Index].Wide;
        Eff.Rich := True;
        Eff.Glyph := RichScreen[Index].Glyph;
        Eff.Fg := RichScreen[Index].Fg;
        Eff.Bg := RichScreen[Index].Bg;
        Eff.Flags := RichScreen[Index].Flags;
        Eff.Attr := 0;
        Eff.ACS := False;
        if Shadowed then
        begin
          Eff.Fg := DimColor(Eff.Fg, $00AAAAAA);
          Eff.Bg := DimColor(Eff.Bg, $00000000);
          Eff.Flags := 0;
        end;
      end
      else
      begin
        Eff.Skip := False;
        Eff.Wide := False;
        Eff.Rich := False;
        Eff.Attr := Byte(VCell shr 8);
        PresentedVgaChar(Byte(VCell and $FF), CellGlyph, CellACS);
        Eff.Glyph := CellGlyph;
        Eff.ACS := CellACS;
        Eff.Fg := 0;
        Eff.Bg := 0;
        Eff.Flags := 0;
      end;
      if TransientOutlineMask <> 0 then
        OverlayHere := TransientOutlineCell(X, Y, OverlayGlyph, OverlayAttr,
          OverlayACS)
      else
        OverlayHere := False;
      // A two-column glyph and its continuation are two independent cells
      // here, and a pane edge can separate them: the lead's right half would
      // then land on the window frame (which the delta sees as unchanged and
      // never repaints), or a continuation would be left blank forever with no
      // lead to fill it. A transient outline is another one-cell owner, so it
      // splits a rich pair in exactly the same way. Only emit the pair when
      // BOTH halves are ours.
      if Eff.Rich and Eff.Wide then
      begin
        if not OverlayHere then
        begin
          Nx := Index + 1;
          if (X + 1 >= ScreenWidth) or TransientOutlineAt(X + 1, Y) or
             (not RichScreen[Nx].Skip) or
             (not RichStands(Nx, NShadow)) or (NShadow <> Shadowed) then
          begin
            Eff.Glyph := ' ';  // split pair: never overflow into a foreign cell
            Eff.Wide := False;
          end;
        end;
      end
      else if Eff.Rich and Eff.Skip then
      begin
        if not OverlayHere then
        begin
          Nx := Index - 1;
          if (X = 0) or TransientOutlineAt(X - 1, Y) or
             (not RichScreen[Nx].Wide) or
             (not RichStands(Nx, NShadow)) or (NShadow <> Shadowed) then
          begin
            // orphan continuation: fall back to the chrome cell so the column
            // is painted instead of staying blank
            Eff.Skip := False;
            Eff.Rich := False;
            Eff.Wide := False;
            Eff.Attr := Byte(VCell shr 8);
            PresentedVgaChar(Byte(VCell and $FF), CellGlyph, CellACS);
            Eff.Glyph := CellGlyph;
            Eff.ACS := CellACS;
            Eff.Fg := 0;
            Eff.Bg := 0;
            Eff.Flags := 0;
          end;
        end;
      end;
      // Overlay last: it is presentation chrome and deliberately wins over
      // both rich pane content and ordinary FreeVision cells. Attr remains the
      // caller's palette-mapped frame attribute; no RGB conversion is needed.
      if OverlayHere then
      begin
        Eff.Skip := False;
        Eff.Rich := False;
        Eff.Wide := False;
        Eff.Attr := OverlayAttr;
        Eff.Glyph := OverlayGlyph;
        Eff.ACS := OverlayACS;
        Eff.Fg := 0;
        Eff.Bg := 0;
        Eff.Flags := 0;
      end;
      // Force is IGNORED on purpose: FreeVision asks for a forced update from
      // TGroup.Redraw, which TGroup.ChangeBounds triggers on every step of a
      // window drag -- that resent all ~10k cells per mouse move (measured:
      // 802 of 1639 frames, 9.9 MB of 10.2 MB, over SSH). The delta below is
      // always correct because this unit is the sole writer to the terminal;
      // when that stops being true the caller must say so via InvalidateFrame.
      if EffEqual(Eff, EffOld[Index]) then
      begin
        NeedMove := True;   // skipped a cell: next change needs a reposition
        Continue;
      end;
      EffOld[Index] := Eff;
      Inc(ChangedCells);
      if Eff.Skip then
      begin
        // wide-glyph continuation: the lead already advanced the cursor two
        // columns, so emit nothing and force the next change to reposition
        NeedMove := True;
        Continue;
      end;
      if NeedMove then
      begin
        Body := Body + CursorPosition(X, Y);
        NeedMove := False;
        Inc(Runs);
      end;
      if Eff.Rich then
        CurSGR := RichSGR(Eff.Fg, Eff.Bg, Eff.Flags)
      else
        CurSGR := AttrSequence(Eff.Attr);
      if CurSGR <> LastSGR then
      begin
        Body := Body + CurSGR;
        LastSGR := CurSGR;
      end;
      if Eff.ACS <> ACSActive then
      begin
        if Eff.ACS then Body := Body + #27'(0'
        else Body := Body + #27'(B';
        ACSActive := Eff.ACS;
      end;
      Body := Body + Eff.Glyph;
    end;
  end;

  // Never leak the alternate character set into cursor-only updates, direct
  // pane output or the shell that receives the terminal after superterm.
  if ACSActive then
    Body := Body + #27'(B';

  if CursorX >= ScreenWidth then
    OutCursorX := ScreenWidth - 1
  else
    OutCursorX := CursorX;
  if CursorY >= ScreenHeight then
    OutCursorY := ScreenHeight - 1
  else
    OutCursorY := CursorY;

  CursorTail := CursorPosition(OutCursorX, OutCursorY);
  if QueuedCursorType <> DesiredCursorType then
    CursorTail := CursorTail + CursorTypeSequence(DesiredCursorType);

  if Body <> '' then
  begin
    // neutral SGR reset + autowrap off + body + cursor, in ONE write. Each
    // cell carries its own color now (chrome or rich), so the prefix must NOT
    // pin a default fg/bg. Optionally wrapped in DECSET 2026 synchronized
    // output (atomic present, no tearing) -- but that holds the frame until
    // ?2026l, and some terminals do not present it until the next input, so it
    // is OFF by default and enabled with SUPERTERM_SYNC=1.
    Frame := #27'[0m'#27'[?7l' + Body + CursorTail;
    if UseSyncOutput then
      Frame := #27'[?2026h' + Frame + #27'[?2026l';
  end
  else
    // nothing changed: only keep the hardware cursor in sync (cheap)
    Frame := CursorTail;
  if AsyncOutputActive then
  begin
    if not QueueOutputFrame(Frame, OrderedFrameAdmission) then
      Exit;
  end
  else
    WriteRaw(Frame);
  QueuedCursorX := OutCursorX;
  QueuedCursorY := OutCursorY;
  QueuedCursorType := DesiredCursorType;
  CursorStateDirty := False;
  Move(VideoBuf^, OldVideoBuf^, VideoBufSize);
  // per-frame detail is FULL-mode only: a blinking cursor alone writes two
  // lines every half second, which buried everything worth reading
  if DebugFull then
    DebugLog(Format('video: update force=%d runs=%d changed_cells=%d ' +
      'of %d bytes=%d rich_hit=%d rich_miss=%d', [Ord(Force), Runs, ChangedCells,
      LongInt(ScreenWidth) * ScreenHeight, Length(Frame), RHit, RMiss]));
end;

procedure PresentOrderedVideoFrame;
begin
  OrderedFrameAdmission := True;
  try
    WideUpdateScreen(False);
  finally
    OrderedFrameAdmission := False;
  end;
end;

{$IFDEF WINDOWS}
// Accept the size the console window already has.
//
// The RTL's Win32 mode selector is wrong for this program in two ways. It only
// recognises a fixed table of legacy modes -- 40x25, 80x25, 80x30, 80x43 and
// 80x50 -- and rejects everything else; and when a mode does match it commands
// the console to that geometry with SetConsoleWindowInfo and
// SetConsoleScreenBufferSize, then clears it.
//
// SuperTerm never invents a size: ReadTerminalSize asks the console what the
// user has just made the window, and that size is what arrives here. So every
// size is valid and nothing may be resized back.
//
// A rejected mode was not merely ignored, either. Video.ScreenWidth and
// ScreenHeight kept their previous values and the video buffer was not
// reallocated, while Free Vision went on to lay the application out at the new
// size -- so after a maximize or a drag-resize every view drew against a buffer
// of the wrong geometry and the whole interface came apart. Reporting success
// here lets the RTL's own SetVideoMode reallocate the buffer for the new
// dimensions, which is the only step that was missing.
function WideSetVideoMode(const AMode: TVideoMode): Boolean;
begin
  Result := (AMode.Col > 0) and (AMode.Row > 0);
  if not Result then
    Exit;
  Video.ScreenWidth := AMode.Col;
  Video.ScreenHeight := AMode.Row;
  Video.ScreenColor := AMode.Color;
  // The terminal still shows the old frame at the old geometry; nothing that
  // was tracked about it describes the new surface.
  InvalidateFrame;
end;
{$ENDIF}

procedure WideClearScreen;
begin
  // Video.ClearScreen has already filled VideoBuf with its canonical blank
  // cells before invoking the driver hook. Present that state through the
  // same bounded reactor as every other frame. The FPC Unix hook writes an
  // escape sequence directly to stdout and can otherwise block teardown
  // before WideDoneVideo gets a chance to stop the reactor.
  WideUpdateScreen(True);
end;

function StopAsyncVideoOutput: Boolean; forward;

procedure WideDoneVideo;
var
  Drained: Boolean;
begin
  Drained := StopAsyncVideoOutput;
  // Restore the ordinary ASCII character set even if teardown follows a
  // partially written compatibility frame.
  WriteRaw(#27'(B'#27'[?7h');
  if Drained and Assigned(SavedDriver.DoneDriver) then
    SavedDriver.DoneDriver;
  if not Drained then
    // The original driver uses blocking writes to stdout. Calling it after a
    // bounded drain timed out would recreate the exact shutdown deadlock this
    // reactor prevents. Best-effort the portable alternate-screen exit on the
    // independent nonblocking handle instead.
    WriteRaw(#27'[?1049l'#27'[0m'#27'[?25h');
  { FreeVision homes the cursor while tearing down the alternate screen.
    Restore the shell's cursor after that teardown, not before it. This is
    only the fallback: the RTL keyboard teardown still emits ESC[H after
    this point, so the authoritative repositioning happens at program exit
    via RestoreConsoleCursor (DSR-based), immune to that late homing. }
  WriteRaw(#27'[u'#27'8');
end;

procedure DetectHostEncoding;
var
  BaseRow, BaseCol, AfterRow, AfterCol, CellWidth: Integer;
begin
  if not ProbeHostEncoding then
    Exit;
  ProbeHostEncoding := False;
  // CaptureConsoleCursor already proved that this terminal answers CPR.  If
  // it did not, do not issue another query: its late reply could otherwise be
  // mistaken for our baseline.  The existing UTF-8 behaviour is the safest
  // default for a terminal which cannot be measured.
  if (ConsoleRow <= 0) or (ConsoleCol <= 0) or (ScreenWidth < 4) then
  begin
    if DebugActive then
      DebugLog('video: encoding probe skipped (no reliable CPR)');
    Exit;
  end;

  // SavedDriver.InitDriver has already entered the alternate screen, while
  // Video.InitVideo has not yet performed its ClearScreen.  The marker is
  // concealed, and that imminent clear removes its cell before the first
  // application frame: no shared state and no visible screen are touched.
  ArmCursorPositionReply;
  WriteRaw(#27'[H'#27'[6n');
  if not ReadCursorPositionReply(BaseRow, BaseCol) then
  begin
    if DebugActive then
      DebugLog('video: encoding probe baseline timed out; keeping UTF-8');
    Exit;
  end;
  if (BaseRow <> 1) or (BaseCol <> 1) then
  begin
    if DebugActive then
      DebugLog(Format('video: encoding probe invalid baseline=%d,%d',
        [BaseRow, BaseCol]));
    Exit;
  end;

  // U+00A3 (C2 A3) is one cell in UTF-8.  Under the legacy Windows pages
  // involved in the reported corruption both bytes are printable characters,
  // so the same wire bytes advance two cells.  Unlike box drawing, this glyph
  // has no East-Asian ambiguous width and contains no C1 control byte.
  ArmCursorPositionReply;
  WriteRaw(#27'[8m'#$C2#$A3#27'[0m'#27'[6n');
  if not ReadCursorPositionReply(AfterRow, AfterCol) then
  begin
    if DebugActive then
      DebugLog('video: encoding probe result timed out; keeping UTF-8');
    Exit;
  end;
  if (AfterRow <> BaseRow) or (AfterCol <= BaseCol) or
     (AfterCol > ScreenWidth) then
  begin
    if DebugActive then
      DebugLog(Format('video: encoding probe invalid result=%d,%d base=%d,%d',
        [AfterRow, AfterCol, BaseRow, BaseCol]));
    Exit;
  end;
  CellWidth := AfterCol - BaseCol;
  HostUtf8 := CellWidth = 1;
  if DebugActive then
    if HostUtf8 then
      DebugLog(Format('video: encoding probe width=%d mode=utf8', [CellWidth]))
    else
      DebugLog(Format('video: encoding probe width=%d mode=acs', [CellWidth]));
end;

procedure WideInitVideo;
begin
  { Keep the cursor position from the shell even on terminals that do not
    restore it reliably for private alternate-screen mode 1049. }
  WriteRaw(#27'7'#27'[s');
  if Assigned(SavedDriver.InitDriver) then
    SavedDriver.InitDriver;
  {$IFDEF WINDOWS}
  // On Unix the RTL driver's InitDriver enters the alternate screen (smcup);
  // the Win32 driver knows nothing of VT and leaves us in the console's main
  // buffer. WideDoneVideo already leaves the alternate screen on exit, so
  // enter it here too: it keeps the shell's scrollback intact under the
  // application, and Windows Terminal does not reflow it on a resize -- a
  // window being dragged narrower merely clips the picture until the next
  // frame, instead of re-wrapping every full-width row into two.
  WriteRaw(#27'[?1049h'#27'[H'#27'[2J');
  {$ENDIF}
  DetectHostEncoding;
  // TTermView and every FreeVision frame use CP437 semantic bytes. FPC may
  // select CP850 when LANG is not UTF-8; keep one canonical grid and perform
  // the client-specific UTF-8/ACS conversion only at the final emitter.
  {$IFDEF UNIX}
  Video.internal_codepage := Video.cp437;
  {$ENDIF}
end;

{$IFDEF UNIX}
function ConfigureNonblockingDescriptor(AFd: cint): Boolean;
var
  Flags: cint;
begin
  Result := False;
  Flags := fpFcntl(AFd, F_GETFL, 0);
  if (Flags < 0) or (fpFcntl(AFd, F_SETFL, Flags or O_NONBLOCK) < 0) then
    Exit;
  Flags := fpFcntl(AFd, F_GETFD, 0);
  if (Flags < 0) or
     (fpFcntl(AFd, F_SETFD, Flags or 1 {FD_CLOEXEC}) < 0) then
    Exit;
  Result := True;
end;

function CreateOutputPipe(out APipe: TFilDes): Boolean;
begin
  APipe[0] := -1;
  APipe[1] := -1;
  Result := fpPipe(APipe) = 0;
  if not Result then
    Exit;
  if not ConfigureNonblockingDescriptor(APipe[0]) or
     not ConfigureNonblockingDescriptor(APipe[1]) then
  begin
    fpClose(APipe[0]);
    fpClose(APipe[1]);
    APipe[0] := -1;
    APipe[1] := -1;
    Exit(False);
  end;
end;

procedure CloseOutputDescriptor(var AFD: cint);
begin
  if AFD >= 0 then
    fpClose(AFd);
  AFD := -1;
end;
{$ENDIF}

{$push}{$notes off}{$hints off}
procedure StartAsyncVideoOutput;
{$IFDEF WINDOWS}
begin
  // Phase 1 has no Windows reactor. The console writer stays synchronous, so
  // AsyncOutputActive remains False and every producer takes the blocking
  // branch it already takes on a Unix host whose /dev/tty cannot be opened.
  if DebugActive then
    DebugLog('video: client output reactor unavailable: windows phase 1');
end;
{$ELSE}
begin
  if AsyncOutputActive or AsyncOutputEverStarted then
    Exit;
  OutputHandle := fpOpen(PChar('/dev/tty'), O_WRONLY or O_NONBLOCK);
  if OutputHandle < 0 then
  begin
    if DebugActive then
      DebugLog('video: client output reactor unavailable: cannot open /dev/tty');
    Exit;
  end;
  if not ConfigureNonblockingDescriptor(OutputHandle) or
     not CreateOutputPipe(OutputWakePipe) or
     not CreateOutputPipe(OutputProgressPipe) then
  begin
    CloseOutputDescriptor(OutputWakePipe[0]);
    CloseOutputDescriptor(OutputWakePipe[1]);
    CloseOutputDescriptor(OutputProgressPipe[0]);
    CloseOutputDescriptor(OutputProgressPipe[1]);
    CloseOutputDescriptor(OutputHandle);
    if DebugActive then
      DebugLog('video: client output reactor unavailable: descriptor setup failed');
    Exit;
  end;
  InitCriticalSection(OutputLock);
  OutputLockInitialized := True;
  SetLength(OutputRing, OUTPUT_QUEUE_CAPACITY);
  OutputHead := 0;
  OutputCount := 0;
  OutputFrameRemaining := 0;
  OutputFailed := False;
  DeferredFrame := False;
  BlockingTeardownUnsafe := False;
  AsyncOutputActive := True;
  AsyncOutputEverStarted := True;
  OutputReactor := TClientOutputReactor.Create(True);
  OutputReactor.FreeOnTerminate := False;
  OutputReactor.Start;
  if DebugActive then
    DebugLog(Format('video: client output reactor started fd=%d cap=%d',
      [OutputHandle, Length(OutputRing)]));
end;
{$ENDIF}
{$pop}

function StopAsyncVideoOutput: Boolean;
{$IFDEF WINDOWS}
begin
  // Nothing was ever admitted to a queue, so teardown is always fully drained
  // and the ordinary blocking restoration path stays safe.
  Result := True;
end;
{$ELSE}
var
  Deadline, NowTick: QWord;
  Pending, WaitMs: LongInt;
  Failed: Boolean;
  PollItem: TPollFD;
begin
  Result := True;
  if not AsyncOutputEverStarted or (OutputReactor = nil) then
    Exit;
  Deadline := GetTickCount64 + OUTPUT_TEARDOWN_DRAIN_MS;
  repeat
    EnterCriticalSection(OutputLock);
    try
      Pending := OutputCount;
      Failed := OutputFailed;
    finally
      LeaveCriticalSection(OutputLock);
    end;
    if (Pending = 0) or Failed then
      Break;
    NowTick := GetTickCount64;
    if NowTick >= Deadline then
      Break;
    WaitMs := Deadline - NowTick;
    if WaitMs > 50 then
      WaitMs := 50;
    PollItem := Default(TPollFD);
    PollItem.fd := OutputProgressPipe[0];
    PollItem.events := POLLIN;
    if (fpPoll(@PollItem, 1, WaitMs) < 0) and
       (fpGetErrNo <> ESysEINTR) then
      Break;
    DrainPipe(OutputProgressPipe[0]);
  until False;
  EnterCriticalSection(OutputLock);
  try
    Pending := OutputCount;
    Failed := OutputFailed;
    if Pending > 0 then
    begin
      OutputCount := 0;
      OutputHead := 0;
      OutputFrameRemaining := 0;
    end;
    AsyncOutputActive := False;
  finally
    LeaveCriticalSection(OutputLock);
  end;
  BlockingTeardownUnsafe := (Pending > 0) or Failed;
  Result := not BlockingTeardownUnsafe;
  OutputReactor.Terminate;
  SignalPipe(OutputWakePipe[1]);
  OutputReactor.WaitFor;
  FreeAndNil(OutputReactor);
  CloseOutputDescriptor(OutputWakePipe[0]);
  CloseOutputDescriptor(OutputWakePipe[1]);
  CloseOutputDescriptor(OutputProgressPipe[0]);
  CloseOutputDescriptor(OutputProgressPipe[1]);
  SetLength(OutputRing, 0);
  if OutputLockInitialized then
  begin
    DoneCriticalSection(OutputLock);
    OutputLockInitialized := False;
  end;
  if not BlockingTeardownUnsafe then
    CloseOutputDescriptor(OutputHandle);
  if DebugActive then
    DebugLog(Format('video: client output reactor stopped drained=%d abandoned=%d',
      [Ord(Result), Pending]));
end;
{$ENDIF}

procedure PauseAsyncVideoOutputForFork(out AWasActive,
  AResumeNeedsFullFrame: Boolean);
{$IFDEF WINDOWS}
begin
  // There is no fork and no reactor on Windows; the pair stays callable so the
  // shared client code needs no platform branch of its own.
  AWasActive := False;
  AResumeNeedsFullFrame := False;
end;
{$ELSE}
begin
  AWasActive := AsyncOutputActive and (OutputReactor <> nil);
  AResumeNeedsFullFrame := False;
  if not AWasActive then
    Exit;
  AResumeNeedsFullFrame := not StopAsyncVideoOutput;
  // StopAsyncVideoOutput deliberately retains the nonblocking descriptor
  // when terminal teardown could not drain. A fork pause is not teardown:
  // discard that private descriptor and let the parent reopen a clean one.
  CloseOutputDescriptor(OutputHandle);
  BlockingTeardownUnsafe := False;
  OutputFailed := False;
  AsyncOutputEverStarted := False;
end;
{$ENDIF}

procedure ResumeAsyncVideoOutputAfterFork(AWasActive,
  AResumeNeedsFullFrame: Boolean);
{$IFDEF WINDOWS}
begin
  Unused(AWasActive);
  Unused(AResumeNeedsFullFrame);
end;
{$ELSE}
begin
  if not AWasActive then
    Exit;
  StartAsyncVideoOutput;
  // A clean pause drained every admitted frame, so the physical terminal and
  // EffOld still describe the same screen. Preserve that valuable baseline.
  // A bounded pause that abandoned output must instead make the next
  // presentation self-contained.
  if AResumeNeedsFullFrame then
    InvalidateFrame;
end;
{$ENDIF}

procedure InstallWideVideoOutput;
var
  Driver: TVideoDriver;
  Encoding: string;
begin
  if DriverInstalled then
    Exit;
  {$IFDEF WINDOWS}
  EnableVTConsole;
  {$ENDIF}
  UseSyncOutput := SysUtils.GetEnvironmentVariable('SUPERTERM_SYNC') = '1';
  Encoding := LowerCase(Trim(
    SysUtils.GetEnvironmentVariable('SUPERTERM_CLIENT_ENCODING')));
  // The only safe override is the 7-bit compatibility renderer.  Never
  // force UTF-8 from an environment variable: FPC may already have selected
  // an ISO-8859 terminal mode from LANG, and only the live cursor probe can
  // prove how this particular terminal interprets the wire bytes.
  if (Encoding = 'acs') or (Encoding = 'legacy') then
  begin
    HostUtf8 := False;
    ProbeHostEncoding := False;
  end
  else
  begin
    HostUtf8 := True;
    {$IFDEF WINDOWS}
    // Native output is explicitly put into CP_UTF8 above. At this point the
    // custom keyboard driver's KInit has not run yet, so VT input is not
    // available for a cursor-position round trip; the Win32 console mode and
    // code page are the authoritative capability instead.
    ProbeHostEncoding := False;
    {$ELSE}
    ProbeHostEncoding := True;
    {$ENDIF}
  end;
  GetVideoDriver(SavedDriver);
  Driver := SavedDriver;
  Driver.InitDriver := @WideInitVideo;
  Driver.UpdateScreen := @WideUpdateScreen;
  Driver.ClearScreen := @WideClearScreen;
  Driver.DoneDriver := @WideDoneVideo;
  Driver.SetCursorPos := @WideSetCursorPos;
  Driver.GetCursorType := @WideGetCursorType;
  Driver.SetCursorType := @WideSetCursorType;
  {$IFDEF WINDOWS}
  Driver.SetVideoMode := @WideSetVideoMode;
  {$ENDIF}
  if SetVideoDriver(Driver) then
    DriverInstalled := True;
end;

// Reads the real console cursor position via DSR (ESC[6n). Must be
// called BEFORE InitVideo. Reason: the ESC 7/ESC[s save done by
// WideInitVideo is not enough on real xterm terminals (Konsole), since
// the RTL driver emits ESC[H and then ?1049h, and in xterm ?1049h saves
// the cursor again -- already at 1;1 -- into the same slot as DECSC, so
// the final ESC[u ESC 8 restores the first line. Asking the terminal for
// the position and repositioning explicitly is immune to that slot overlap.
{$IFDEF WINDOWS}
procedure CaptureConsoleCursor;
var
  Info: TConsoleScreenBufferInfo;
  HOut: THandle;
begin
  Info := Default(TConsoleScreenBufferInfo);
  // No DSR round-trip needed: the console buffer knows the cursor position.
  ConsoleRow := 0;
  ConsoleCol := 0;
  HOut := GetStdHandle(STD_OUTPUT_HANDLE);
  if (HOut <> INVALID_HANDLE_VALUE) and
     GetConsoleScreenBufferInfo(HOut, Info) then
  begin
    // Stored 1-based to match the terminal's ESC[row;colH addressing.
    ConsoleRow := Info.dwCursorPosition.Y + 1;
    ConsoleCol := Info.dwCursorPosition.X + 1;
  end;
end;
{$ELSE}
procedure CaptureConsoleCursor;
var
  OldTio, RawTio: TermIOS;
begin
  ConsoleRow := 0;
  ConsoleCol := 0;
  OldTio := Default(TermIOS);
  if IsATTY(StdInputHandle) <> 1 then
    Exit;
  if TCGetAttr(StdInputHandle, OldTio) <> 0 then
    Exit;
  RawTio := OldTio;
  RawTio.c_lflag := RawTio.c_lflag and
    (not (ICANON or ECHO or ISIG or IEXTEN));
  RawTio.c_iflag := RawTio.c_iflag and
    (not (IXON or IXOFF or ICRNL or INLCR or IGNCR or ISTRIP or BRKINT));
  RawTio.c_cc[VMIN] := 0;
  RawTio.c_cc[VTIME] := 2; // 0.2s maximum wait per read
  if TCSetAttr(StdInputHandle, TCSANOW, RawTio) <> 0 then
    Exit;
  // If the outer terminal answers after our bounded synchronous read, the
  // custom keyboard driver must still recognize that one late CSI r;c R as a
  // report. Otherwise CSI's overlapping final 'R' is decoded as F3.
  ArmCursorPositionReply;
  WriteRaw(#27'[6n');
  try
    if not ReadCursorPositionReply(ConsoleRow, ConsoleCol) or
       (ConsoleRow <= 0) or (ConsoleCol <= 0) then
    begin
      ConsoleRow := 0;
      ConsoleCol := 0;
    end;
  finally
    TCSetAttr(StdInputHandle, TCSANOW, OldTio);
  end;
end;
{$ENDIF}

// Turns off everything that makes the terminal send us bytes, and throws
// away whatever it sent before we got here.
//
// The RTL's mouse driver enables and disables ONLY ?1003 and ?1006 (see
// mouse.pp, SysInitMouse/SysDoneMouse). superterm also enables ?1000 and
// ?1002 by hand when it reclaims the screen from a maximised pane, and the
// RTL knows nothing about those: after teardown they stay ON, so the
// terminal keeps reporting every mouse movement to whatever runs next --
// the shell, which prints the reports as line noise at its prompt.
//
// Disabling is not quite enough on its own either: reports the terminal
// already sent are sitting in the tty input buffer and would be read by the
// shell as typed characters. Flush them.
procedure ReleaseConsoleInput;
begin
  // order matters: SGR last, so the tracking modes are already off and
  // nothing new can arrive in either encoding
  WriteRaw(#27'[?1003l'#27'[?1002l'#27'[?1000l'#27'[?1015l'#27'[?1006l' +
    #27'[?2004l'#27'[?9l');
  {$IFDEF WINDOWS}
  FlushConsoleInputBuffer(GetStdHandle(STD_INPUT_HANDLE));
  RestoreVTConsole;
  {$ELSE}
  if IsATTY(StdInputHandle) = 1 then
    TCFlush(StdInputHandle, TCIFLUSH);
  {$ENDIF}
end;

// Puts the console cursor back where it was at startup. Call at the
// very end (after App.Done), because the RTL video and keyboard
// drivers emit ESC[H during teardown. If the terminal did not answer
// the DSR, WideDoneVideo's ESC[u ESC 8 fallback remains.
procedure RestoreConsoleCursor;
begin
  if (ConsoleRow > 0) and (ConsoleCol > 0) then
    WriteRaw(#27'[' + IntToStr(ConsoleRow) + ';' + IntToStr(ConsoleCol) + 'H');
end;

finalization
  {$IFDEF UNIX}
  if OutputReactor <> nil then
  begin
    OutputReactor.Terminate;
    SignalPipe(OutputWakePipe[1]);
    OutputReactor.WaitFor;
    FreeAndNil(OutputReactor);
  end;
  CloseOutputDescriptor(OutputWakePipe[0]);
  CloseOutputDescriptor(OutputWakePipe[1]);
  CloseOutputDescriptor(OutputProgressPipe[0]);
  CloseOutputDescriptor(OutputProgressPipe[1]);
  CloseOutputDescriptor(OutputHandle);
  {$ENDIF}
  if OutputLockInitialized then
    DoneCriticalSection(OutputLock);

end.
