(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_mouse - mouse driver that never blocks and never gives up

  The RTL decides whether there is a mouse from a fixed list of TERM
  prefixes -- cons, eterm, gnome, konsole, rxvt, screen, xterm -- and for
  anything else it tries gpm. Two things go wrong with that.

  On a terminal it does not know (tmux-256color, alacritty, foot, wezterm)
  nobody enables xterm mouse tracking, so there is no mouse at all. Worse,
  the gpm attempt is a BLOCKING connect to /dev/gpmctl made while the
  Drivers unit initialises -- before the program's first line runs. With
  gpm installed but not accepting (its accept backlog full), superterm hangs
  at startup forever, and nothing in the program can do anything about it
  because the program has not started yet.

  On a GNU/Linux virtual console the RTL's gpm client is no better. It takes
  the console number from the digits that end ttyname(0), and behind the
  pseudo-terminal sudo puts in front of a console (sudo su on tty1 leaves the
  shell on /dev/pts/N with TERM=linux) that number is N, not the console; the
  kernel console ignores the xterm modes a terminal would honour; and the
  pointer the RTL draws into VideoBuf is overwritten by the next repaint.

  This unit registers its own driver before Drivers initialises, which is
  why it must appear BEFORE Drivers in the program's uses clause. Off the
  console it declares a mouse for every terminal and enables xterm tracking
  itself; the reports are decoded by st_kbd into its own event queue. On a
  virtual console -- the program's own terminal, or the console a transparent
  relay such as sudo or su forwards -- it speaks gpm's client protocol itself:
  a non-blocking connect for that console, every event decoded into the same
  queue, and a pointer the renderer paints into each frame. Without gpm there
  is no console mouse and, above all, no hang.
*)

unit st_mouse;

{$mode objfpc}{$H+}

interface

type
  TMouseOutputWriter = procedure(const S: AnsiString);
  // Paints, moves or removes the software pointer at a 0-based screen cell.
  TMousePointerPainter = procedure(AX, AY: LongInt; AVisible: Boolean);

// True only when stdin is an actual GNU/Linux virtual console, where the
// only possible mouse is GPM. TERM alone is not sufficient: it can be stale,
// overridden, or forwarded through a pseudo-terminal.
function OnLinuxConsole: boolean;
// The virtual console whose GPM mouse this process follows: its own
// terminal, or the console behind a transparent relay (sudo, su) whose
// pseudo-terminal still says TERM=linux. 0 when the mouse is not GPM's.
function ConsoleMouseVt: LongInt;
// True when the mouse comes from GPM rather than from terminal reports.
function ConsoleMouse: boolean;
// Descriptor which becomes readable for a GPM event on a virtual console.
// Terminal-emulator mouse reports travel through stdin and return -1 here.
function MouseInputWaitHandle: LongInt;

// Install the application's nonblocking terminal writer after unit
// initialization and before FreeVision starts the mouse driver. Keeping this
// callback out of the uses graph is essential: a st_mouse -> st_video ->
// Drivers cycle would let Drivers probe the blocking RTL driver first.
procedure InstallMouseOutputWriter(AWriter: TMouseOutputWriter);
// The renderer's software pointer, installed the same way and for the same
// reason. Only a GPM console uses it: there nothing else draws a pointer.
procedure InstallMousePointerPainter(APainter: TMousePointerPainter);

// Queue whatever GPM has delivered as mouse events. Non-blocking and cheap
// when there is nothing; st_kbd calls it whenever its own queue runs dry.
procedure PumpConsoleMouse;
// Whether motion with no button held reaches the application. A terminal is
// asked for it with ?1003; GPM always reports it, so here it is a filter.
procedure SetConsoleAnyMotion(AOn: boolean);
// A forked daemon inherits the GPM socket of the client it was born from.
// Drop that copy without touching the connection the client still owns.
procedure ReleaseInheritedConsoleMouse;

// The exact set of modes this driver wants the host terminal in, and the way
// back. One place decides, so anything that hands the terminal to a pane and
// takes it back again restores precisely what was enabled -- a pane's own
// program (a superterm inside a pane, say) writes its own mode resets
// straight to the host while it owns the screen, and they must be undone by
// the same rules that set them. On a GPM console there are no modes: the
// same two calls connect to GPM and give the pointer back to it.
procedure HostMouseOn;
procedure HostMouseOff;

implementation

uses
  SysUtils, Mouse, Video, BaseUnix, Sockets, st_debug
  {$IFDEF LINUX}, Linux{$ENDIF};

{$IFDEF LINUX}
type
  // gpm's wire records (src/headers/gpm.h) in C layout and native byte
  // order. The daemon is built without GPM_USE_MAGIC, so nothing precedes
  // them; FPC's own gpm.pp declares the same two records.
  {$PACKRECORDS C}
  TGpmConnectRequest = record
    EventMask, DefaultMask, MinMod, MaxMod: Word;
    Pid, Vc: LongInt;
  end;
  TGpmWireEvent = record
    Buttons, Modifiers: Byte;
    Vc: Word;
    Dx, Dy, X, Y: SmallInt;
    EventType: LongInt;
    Clicks: LongInt;
    Margin: LongInt;
    Wdx, Wdy: SmallInt;
  end;
  {$PACKRECORDS DEFAULT}

{$IF SizeOf(TGpmConnectRequest) <> 16}
  {$ERROR gpm connect request must be 16 bytes}
{$ENDIF}
{$IF SizeOf(TGpmWireEvent) <> 28}
  {$ERROR gpm event must be 28 bytes}
{$ENDIF}

const
  GPM_SOCKET = '/dev/gpmctl';
  GPM_MOVE = 1;
  GPM_DRAG = 2;
  GPM_DOWN = 4;
  GPM_UP = 8;
  GPM_B_RIGHT = 1;
  GPM_B_MIDDLE = 2;
  GPM_B_LEFT = 4;
  GPM_B_UP = 16;           // the wheel, as gpm's imps2 decoder reports it
  GPM_B_DOWN = 32;
  VT_MAJOR = 4;            // /dev/tty1 .. /dev/tty63
  MAX_VT = 63;
  MAX_RELAY_HOPS = 32;
  GPM_PUMP_EVENTS = 32;    // records drained per call; the rest wait in gpm
  GPM_RETRY_MIN_MS = 1000; // after gpm went away: first retry, then doubling
  GPM_RETRY_MAX_MS = 30000;
{$ENDIF}

var
  SysDriver: TMouseDriver;   // the RTL's: terminal emulators keep its Show/Hide/Get*
  OurDriver: TMouseDriver;
  MouseOutputWriter: TMouseOutputWriter = nil;
  PointerPainter: TMousePointerPainter = nil;
  {$IFDEF LINUX}
  GpmVt: LongInt = 0;        // console whose pointer this process follows
  GpmFd: cint = -1;          // this process's own connection to gpm
  GpmReleased: boolean = False;
  GpmCarry: array[0..SizeOf(TGpmWireEvent) - 1] of Byte;
  GpmCarryLen: integer = 0;
  GpmButtons: Word = 0;      // button state after the last decoded event
  GpmX: Word = 0;
  GpmY: Word = 0;
  GpmAnyMotion: boolean = False;
  PointerShown: boolean = False;
  GpmWanted: boolean = False;  // between HostMouseOn and HostMouseOff
  GpmHeard: boolean = False;   // this connection has delivered an event
  GpmRefused: boolean = False;
  GpmRetryTick: QWord = 0;
  GpmRetryMs: QWord = GPM_RETRY_MIN_MS;
  {$ENDIF}

procedure InstallMouseOutputWriter(AWriter: TMouseOutputWriter);
begin
  MouseOutputWriter := AWriter;
end;

procedure InstallMousePointerPainter(APainter: TMousePointerPainter);
begin
  PointerPainter := APainter;
end;

procedure WriteMouseControl(const S: AnsiString);
begin
  if Assigned(MouseOutputWriter) then
    MouseOutputWriter(S);
end;

function OnLinuxConsole: boolean;
{$IFDEF LINUX}
var
  ConsoleMode: cint;
{$ENDIF}
begin
  {$IFDEF LINUX}
  // KDGETMODE is accepted by the kernel console driver and rejected with
  // ENOTTY by Unix PTYs. This is the same installed FPC/Linux console ioctl
  // contract used by the RTL, without guessing from a terminal name.
  ConsoleMode := -1;
  Result := FpIOCtl(StdInputHandle, KDGETMODE, @ConsoleMode) = 0;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

{$IFDEF LINUX}
// Linux encodes a character device the same way in st_rdev and in the tty_nr
// field of /proc/PID/stat: major in bits 8..19, minor in bits 0..7 and
// 20..31. Only /dev/tty1../dev/tty63 are virtual consoles gpm can serve.
function VtOfDevice(ADev: QWord): LongInt;
var
  Major, Minor: QWord;
begin
  Major := (ADev shr 8) and $FFF;
  Minor := (ADev and $FF) or ((ADev shr 12) and $FFF00);
  if (Major = VT_MAJOR) and (Minor >= 1) and (Minor <= MAX_VT) then
    Result := LongInt(Minor)
  else
    Result := 0;
end;

// ppid and tty_nr (fields 4 and 7) of /proc/PID/stat. The command name in
// field 2 may itself hold spaces and parentheses, so the fields are counted
// from its LAST closing parenthesis.
function ReadProcTty(const APid: string; out APPid: LongInt;
  out ATty: QWord): boolean;
var
  F: THandle;
  Buf: array[0..1023] of AnsiChar;
  N, P, Field: integer;
  S, Token: string;
begin
  Result := False;
  APPid := 0;
  ATty := 0;
  F := FileOpen('/proc/' + APid + '/stat', fmOpenRead);
  if F = THandle(-1) then
    Exit;
  try
    N := FileRead(F, Buf, SizeOf(Buf));
  finally
    FileClose(F);
  end;
  if N <= 0 then
    Exit;
  SetString(S, PAnsiChar(@Buf[0]), N);
  P := LastDelimiter(')', S);
  if P = 0 then
    Exit;
  S := Copy(S, P + 1, MaxInt);
  // fields after the name: 3 state, 4 ppid, 5 pgrp, 6 session, 7 tty_nr
  Field := 2;
  while Field < 7 do
  begin
    S := TrimLeft(S);
    P := Pos(' ', S);
    if P = 0 then
      Exit;
    Token := Copy(S, 1, P - 1);
    S := Copy(S, P + 1, MaxInt);
    Inc(Field);
    if Field = 4 then
      APPid := StrToIntDef(Token, 0)
    else if Field = 7 then
      ATty := QWord(StrToInt64Def(Token, 0));
  end;
  Result := APPid > 0;
end;

// A transparent relay -- sudo with use_pty, su --pty, script -- puts the
// program on a pseudo-terminal of its own while the relay itself stays on
// the console and copies bytes both ways. Nothing on that pseudo-terminal
// says where it leads, but the ancestry does: walking up while processes
// share this pseudo-terminal, the first one on a different terminal is the
// relay, and its terminal is the console. Only an untouched TERM=linux is
// trusted to mean that nothing in between emulates a terminal of its own:
// tmux, screen, SSH and every emulator change TERM or are not on a console.
function RelayedConsoleVt: LongInt;
var
  Own, Tty: QWord;
  Pid, PPid: LongInt;
  Hop: integer;
  Start: string;
begin
  Result := 0;
  if GetEnvironmentVariable('TERM') <> 'linux' then
    Exit;
  Start := 'self';
  {$IFDEF SUPERTERM_TEST_BUILD}
  // Lets a probe walk a real relay chain from another process, read-only.
  if (GetEnvironmentVariable('SUPERTERM_TESTING') = '1') and
     (GetEnvironmentVariable('SUPERTERM_TEST_RELAY_PID') <> '') then
    Start := GetEnvironmentVariable('SUPERTERM_TEST_RELAY_PID');
  {$ENDIF}
  if (not ReadProcTty(Start, PPid, Own)) or (Own = 0) then
    Exit;
  Pid := PPid;
  for Hop := 1 to MAX_RELAY_HOPS do
  begin
    if (Pid <= 1) or (not ReadProcTty(IntToStr(Pid), PPid, Tty)) then
      Exit;
    if Tty <> Own then
      Exit(VtOfDevice(Tty));
    Pid := PPid;
  end;
end;

function DetectConsoleVt: LongInt;
var
  St: Stat;
begin
  {$IFDEF SUPERTERM_TEST_BUILD}
  // The suite has no console to sit on; it names one and serves gpm itself.
  if (GetEnvironmentVariable('SUPERTERM_TESTING') = '1') and
     (GetEnvironmentVariable('SUPERTERM_TEST_CONSOLE_VT') <> '') then
    Exit(StrToIntDef(GetEnvironmentVariable('SUPERTERM_TEST_CONSOLE_VT'), 0));
  {$ENDIF}
  if OnLinuxConsole then
  begin
    St := Default(Stat);
    if FpFStat(StdInputHandle, St) = 0 then
      Exit(VtOfDevice(St.st_rdev));
    Exit(0);
  end;
  Result := RelayedConsoleVt;
end;

function GpmSocketPath: string;
begin
  Result := GPM_SOCKET;
  {$IFDEF SUPERTERM_TEST_BUILD}
  if (GetEnvironmentVariable('SUPERTERM_TESTING') = '1') and
     (GetEnvironmentVariable('SUPERTERM_TEST_GPM_SOCKET') <> '') then
    Result := GetEnvironmentVariable('SUPERTERM_TEST_GPM_SOCKET');
  {$ENDIF}
end;

// Deciding that the mouse is gpm's needs no connection: FreeVision asks while
// its units initialise, for every invocation including one-shot CLI commands,
// and only the interactive client connects (OurInitDriver).
function GpmSocketPresent: boolean;
var
  St: Stat;
begin
  St := Default(Stat);
  Result := (FpStat(GpmSocketPath, St) = 0) and fpS_ISSOCK(St.st_mode);
end;

// Connects without ever blocking: a listening socket with room accepts at
// once, one whose backlog is full says EAGAIN, and no gpm at all is a
// refusal or a missing path. Only the first answer yields a descriptor. It
// is close-on-exec, so no pane ever inherits it.
function GpmOpenSocket: cint;
var
  Fd: cint;
  Addr: sockaddr_un;
  Path: string;
begin
  Result := -1;
  Path := GpmSocketPath;
  if Length(Path) >= SizeOf(Addr.sun_path) then
    Exit;
  Fd := fpsocket(AF_UNIX, SOCK_STREAM, 0);
  if Fd < 0 then
    Exit;
  fpfcntl(Fd, F_SETFL, fpfcntl(Fd, F_GETFL) or O_NONBLOCK);
  fpfcntl(Fd, F_SETFD, 1 {FD_CLOEXEC});
  Addr := Default(sockaddr_un);
  Addr.sun_family := AF_UNIX;
  StrPCopy(Addr.sun_path, Path);
  if fpconnect(Fd, psockaddr(@Addr), SizeOf(Addr)) <> 0 then
  begin
    fpclose(Fd);
    Exit;
  end;
  Result := Fd;
end;

procedure PaintPointer;
begin
  if Assigned(PointerPainter) then
    PointerPainter(GpmX, GpmY, PointerShown and (GpmFd >= 0));
end;

procedure GpmDisconnect;
begin
  if GpmFd >= 0 then
    fpclose(GpmFd);
  GpmFd := -1;
  GpmCarryLen := 0;
  GpmButtons := 0;
end;

// FPC declares fpRead/fpWrite with untyped buffers and marks them inline; at
// these call sites 3.2.2 reports a compiler implementation note with nothing
// actionable in the project, as the server and video units note for the same
// calls.
{$push}{$notes off}{$hints off}
function GpmSendRequest(AFd: cint; const ARequest: TGpmConnectRequest): boolean;
begin
  Result := fpwrite(AFd, ARequest, SizeOf(ARequest)) = SizeOf(ARequest);
end;

function GpmRead(AFd: cint; var ABuf; ASize: integer): integer;
begin
  repeat
    Result := fpread(AFd, ABuf, ASize);
  until (Result >= 0) or (fpgeterrno <> ESysEINTR);
end;
{$pop}

function GpmConnect: boolean;
var
  Req: TGpmConnectRequest;
begin
  Result := GpmFd >= 0;
  if Result or (GpmVt <= 0) or GpmReleased then
    Exit;
  GpmFd := GpmOpenSocket;
  if GpmFd < 0 then
    Exit(False);
  Req := Default(TGpmConnectRequest);
  // Every bare event, so the pointer can follow the mouse. No modifier: with
  // Shift (or any other) held the event stays gpm's, whose console selection
  // then copies text exactly as it does under every other program.
  Req.EventMask := GPM_MOVE or GPM_DRAG or GPM_DOWN or GPM_UP;
  Req.DefaultMask := 0;
  Req.MinMod := 0;
  Req.MaxMod := 0;
  Req.Pid := fpGetPid;
  Req.Vc := GpmVt;
  if not GpmSendRequest(GpmFd, Req) then
  begin
    GpmDisconnect;
    Exit(False);
  end;
  GpmHeard := False;
  Result := True;
end;

// gpm restarted, upgraded or briefly absent: try again now and then, never
// blocking and never more often than the doubling interval allows.
procedure GpmRetry;
var
  NowTick: QWord;
begin
  if (not GpmWanted) or GpmRefused or GpmReleased or (GpmVt <= 0) then
    Exit;
  NowTick := GetTickCount64;
  if NowTick - GpmRetryTick < GpmRetryMs then
    Exit;
  GpmRetryTick := NowTick;
  if GpmConnect then
  begin
    if DebugActive then
      DebugLog(Format('mouse: gpm reconnected for console %d fd=%d',
        [GpmVt, GpmFd]));
    GpmRetryMs := GPM_RETRY_MIN_MS;
    PaintPointer;
  end
  else if GpmRetryMs < GPM_RETRY_MAX_MS then
    GpmRetryMs := GpmRetryMs * 2;
end;

// gpm accepts a non-root client only for a console whose /dev/ttyN that user
// owns. Say which owner it found, the one fact that explains a refusal.
procedure TraceGpmRefusal;
var
  St: Stat;
  Owner: LongInt;
begin
  St := Default(Stat);
  Owner := -1;
  if FpStat('/dev/tty' + IntToStr(GpmVt), St) = 0 then
    Owner := LongInt(St.st_uid);
  DebugLog(Format('mouse: gpm refused console %d for uid %d (/dev/tty%d is ' +
    'owned by uid %d); no console mouse', [GpmVt, LongInt(FpGetUid), GpmVt,
    Owner]));
end;

function MapGpmButtons(AButtons: Byte): Word;
begin
  Result := 0;
  if (AButtons and GPM_B_LEFT) <> 0 then
    Result := Result or MouseLeftButton;
  if (AButtons and GPM_B_RIGHT) <> 0 then
    Result := Result or MouseRightButton;
  if (AButtons and GPM_B_MIDDLE) <> 0 then
    Result := Result or MouseMiddleButton;
  // the same buttons st_kbd gives the X10/SGR wheel
  if (AButtons and GPM_B_UP) <> 0 then
    Result := Result or MouseButton4;
  if (AButtons and GPM_B_DOWN) <> 0 then
    Result := Result or MouseButton5;
end;

// One gpm record in the semantics of processmouse.c: a change of buttons is
// GPM_DOWN when the new set is larger and carries that whole set, GPM_UP
// when it is smaller and carries only the buttons released; no change is a
// GPM_DRAG with buttons held or a GPM_MOVE without. Consecutive motions are
// folded into the last one, which is all FreeVision and the pointer need.
procedure DecodeGpmEvent(const E: TGpmWireEvent; var APending: TMouseEvent;
  var AHavePending: boolean);
var
  Ev: TMouseEvent;
  Mapped, Wheel: Word;

  procedure Flush;
  begin
    if AHavePending then
      PutMouseEvent(APending);
    AHavePending := False;
  end;

begin
  if E.X > 0 then GpmX := Word(E.X - 1) else GpmX := 0;
  if E.Y > 0 then GpmY := Word(E.Y - 1) else GpmY := 0;
  if (ScreenWidth > 0) and (GpmX >= ScreenWidth) then
    GpmX := ScreenWidth - 1;
  if (ScreenHeight > 0) and (GpmY >= ScreenHeight) then
    GpmY := ScreenHeight - 1;
  Mapped := MapGpmButtons(E.Buttons);
  Ev := Default(TMouseEvent);
  Ev.X := GpmX;
  Ev.Y := GpmY;
  case E.EventType and $0F of
    GPM_DOWN:
      begin
        GpmButtons := Mapped;
        Ev.Action := MouseActionDown;
      end;
    GPM_UP:
      begin
        GpmButtons := GpmButtons and not Mapped;
        Ev.Action := MouseActionUp;
      end;
  else
    begin
      GpmButtons := Mapped;
      Ev.Action := MouseActionMove;
    end;
  end;
  Ev.Buttons := GpmButtons;
  if Ev.Action = MouseActionMove then
  begin
    // A protocol that reports the wheel only as a displacement leaves the
    // buttons alone: press and release the wheel button for each notch.
    if (E.Wdy <> 0) and ((E.Buttons and (GPM_B_UP or GPM_B_DOWN)) = 0) then
    begin
      Flush;
      if E.Wdy > 0 then Wheel := MouseButton4 else Wheel := MouseButton5;
      Ev.Action := MouseActionDown;
      Ev.Buttons := GpmButtons or Wheel;
      PutMouseEvent(Ev);
      Ev.Action := MouseActionUp;
      Ev.Buttons := GpmButtons;
      PutMouseEvent(Ev);
      Exit;
    end;
    if (GpmButtons = 0) and not GpmAnyMotion then
      Exit;               // a hover only moves the pointer
    APending := Ev;
    AHavePending := True;
    Exit;
  end;
  Flush;
  PutMouseEvent(Ev);
end;
{$ENDIF}

function ConsoleMouseVt: LongInt;
begin
  {$IFDEF LINUX}
  Result := GpmVt;
  {$ELSE}
  Result := 0;
  {$ENDIF}
end;

function ConsoleMouse: boolean;
begin
  Result := ConsoleMouseVt > 0;
end;

function MouseInputWaitHandle: LongInt;
begin
  {$IFDEF LINUX}
  Result := GpmFd;
  {$ELSE}
  Result := -1;
  {$ENDIF}
end;

procedure PumpConsoleMouse;
{$IFDEF LINUX}
type
  TGpmPumpBuffer = array[0..GPM_PUMP_EVENTS * SizeOf(TGpmWireEvent) - 1] of Byte;
var
  Buf: TGpmPumpBuffer;
  N, Total, Off: integer;
  E: TGpmWireEvent;
  Pending: TMouseEvent;
  HavePending: boolean;
  OldX, OldY: Word;
begin
  if GpmFd < 0 then
  begin
    GpmRetry;
    if GpmFd < 0 then
      Exit;
  end;
  Buf := Default(TGpmPumpBuffer);
  if GpmCarryLen > 0 then
    Move(GpmCarry[0], Buf[0], GpmCarryLen);
  N := GpmRead(GpmFd, Buf[GpmCarryLen], SizeOf(Buf) - GpmCarryLen);
  if N = 0 then
  begin
    // Stop waiting on a descriptor that would only report hang-up, and take
    // the pointer off the screen. gpm answers every client it accepts with
    // the pointer position at once, so a close before any event is a refusal
    // and retrying would only repeat it; a close after events means gpm went
    // away, and it may well come back.
    if GpmHeard then
    begin
      if DebugActive then
        DebugLog(Format('mouse: gpm connection lost on console %d; retrying',
          [GpmVt]));
      GpmRetryMs := GPM_RETRY_MIN_MS;
    end
    else
    begin
      GpmRefused := True;
      if DebugActive then
        TraceGpmRefusal;
    end;
    GpmRetryTick := GetTickCount64;
    GpmDisconnect;
    PaintPointer;
    Exit;
  end;
  if N < 0 then
    Exit;                 // EAGAIN: nothing yet
  GpmHeard := True;
  Total := GpmCarryLen + N;
  OldX := GpmX;
  OldY := GpmY;
  Pending := Default(TMouseEvent);
  HavePending := False;
  E := Default(TGpmWireEvent);
  Off := 0;
  while Total - Off >= SizeOf(E) do
  begin
    Move(Buf[Off], E, SizeOf(E));
    Inc(Off, SizeOf(E));
    DecodeGpmEvent(E, Pending, HavePending);
  end;
  if HavePending then
    PutMouseEvent(Pending);
  GpmCarryLen := Total - Off;
  if GpmCarryLen > 0 then
    Move(Buf[Off], GpmCarry[0], GpmCarryLen);
  if (GpmX <> OldX) or (GpmY <> OldY) then
    PaintPointer;
end;
{$ELSE}
begin
end;
{$ENDIF}

procedure SetConsoleAnyMotion(AOn: boolean);
begin
  {$IFDEF LINUX}
  GpmAnyMotion := AOn;
  {$ELSE}
  if AOn then ;           // a terminal is asked with ?1003 instead
  {$ENDIF}
end;

procedure ReleaseInheritedConsoleMouse;
begin
  {$IFDEF LINUX}
  // Closing only this process's copy: the socket stays open in the client,
  // which remains gpm's client. The daemon must never paint or reconnect.
  if GpmFd >= 0 then
    fpclose(GpmFd);
  GpmFd := -1;
  GpmCarryLen := 0;
  GpmReleased := True;
  GpmWanted := False;
  PointerShown := False;
  PointerPainter := nil;
  {$ENDIF}
end;

procedure HostMouseOn;
begin
  {$IFDEF LINUX}
  if ConsoleMouse then
  begin
    // an explicit start asks again even after a refusal
    GpmWanted := True;
    GpmRefused := False;
    GpmRetryMs := GPM_RETRY_MIN_MS;
    GpmRetryTick := GetTickCount64;
    GpmConnect;
    PaintPointer;
    Exit;
  end;
  {$ENDIF}
  // normal tracking, motion while a button is held, SGR encoding (no
  // 223-column limit). Any-motion tracking (?1003) is not asked for: the
  // RTL queue holds 16 events and FreeVision drains one per loop, so a
  // sweep of the pointer under ?1003 overflows it for nothing.
  WriteMouseControl(#27'[?1000h'#27'[?1002h'#27'[?1006h');
end;

procedure HostMouseOff;
begin
  {$IFDEF LINUX}
  if ConsoleMouse then
  begin
    // gpm draws its own pointer and runs its selection again once no client
    // holds the console
    GpmWanted := False;
    GpmDisconnect;
    PaintPointer;
    Exit;
  end;
  {$ENDIF}
  WriteMouseControl(#27'[?1006l'#27'[?1002l'#27'[?1000l');
end;

function OurDetectMouse: byte;
begin
  {$IFDEF LINUX}
  GpmVt := DetectConsoleVt;
  if (GpmVt > 0) and GpmSocketPresent then
    Exit(3);
  GpmVt := 0;
  {$ENDIF}
  if OnLinuxConsole then
    // the kernel console has no mouse reports of its own; without gpm there
    // is no mouse at all
    Result := 0
  else
    // every terminal emulator: we enable tracking ourselves below and
    // st_kbd decodes the reports, so there is always a mouse to declare
    Result := 2;
end;

procedure OurInitDriver;
begin
  HostMouseOn;
end;

procedure OurDoneDriver;
begin
  {$IFDEF LINUX}
  PointerShown := False;
  {$ENDIF}
  HostMouseOff;
end;

procedure OurShowMouse;
begin
  {$IFDEF LINUX}
  if ConsoleMouse then
  begin
    PointerShown := True;
    PaintPointer;
    Exit;
  end;
  {$ENDIF}
  if Assigned(SysDriver.ShowMouse) then
    SysDriver.ShowMouse();
end;

procedure OurHideMouse;
begin
  {$IFDEF LINUX}
  if ConsoleMouse then
  begin
    PointerShown := False;
    PaintPointer;
    Exit;
  end;
  {$ENDIF}
  if Assigned(SysDriver.HideMouse) then
    SysDriver.HideMouse();
end;

function OurGetMouseX: word;
begin
  {$IFDEF LINUX}
  if ConsoleMouse then
    Exit(GpmX);
  {$ENDIF}
  if Assigned(SysDriver.GetMouseX) then
    Result := SysDriver.GetMouseX()
  else
    Result := 0;
end;

function OurGetMouseY: word;
begin
  {$IFDEF LINUX}
  if ConsoleMouse then
    Exit(GpmY);
  {$ENDIF}
  if Assigned(SysDriver.GetMouseY) then
    Result := SysDriver.GetMouseY()
  else
    Result := 0;
end;

function OurGetMouseButtons: word;
begin
  {$IFDEF LINUX}
  if ConsoleMouse then
    Exit(GpmButtons);
  {$ENDIF}
  if Assigned(SysDriver.GetMouseButtons) then
    Result := SysDriver.GetMouseButtons()
  else
    Result := 0;
end;

initialization
  SysDriver := Default(TMouseDriver);
  GetMouseDriver(SysDriver);
  OurDriver := SysDriver;           // SetMouseXY and the queue stay the RTL's
  OurDriver.UseDefaultQueue := True;
  OurDriver.DetectMouse := @OurDetectMouse;
  OurDriver.InitDriver := @OurInitDriver;
  OurDriver.DoneDriver := @OurDoneDriver;
  OurDriver.ShowMouse := @OurShowMouse;
  OurDriver.HideMouse := @OurHideMouse;
  OurDriver.GetMouseX := @OurGetMouseX;
  OurDriver.GetMouseY := @OurGetMouseY;
  OurDriver.GetMouseButtons := @OurGetMouseButtons;
  SetMouseDriver(OurDriver);

end.
