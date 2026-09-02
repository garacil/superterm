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

  On a real virtual console, the opposite: TERM is usually 'linux', which is
  not on the list either, so the RTL goes to gpm -- but FreeVision only initialises
  the mouse when the RTL reports one, and the report is 0 whenever gpm is
  absent, leaving the console without a mouse it could have had.

  This unit registers its own driver before Drivers initialises, which is
  why it must appear BEFORE Drivers in the program's uses clause. Off the
  console it declares a mouse for every terminal and enables xterm tracking
  itself; the reports are decoded by st_kbd into the RTL's event queue, so
  the RTL's own driver is never involved. On the console it probes gpm with
  a non-blocking connect first: if gpm is accepting, the RTL driver takes
  over exactly as before; if it is absent or wedged, there is no mouse and,
  above all, no hang.
*)

unit st_mouse;

{$mode objfpc}{$H+}

interface

type
  TMouseOutputWriter = procedure(const S: AnsiString);

// True only when stdin is an actual GNU/Linux virtual console, where the
// only possible mouse is GPM. TERM alone is not sufficient: it can be stale,
// overridden, or forwarded through a pseudo-terminal.
function OnLinuxConsole: boolean;
// Descriptor which becomes readable for a GPM event on a virtual console.
// Terminal-emulator mouse reports travel through stdin and return -1 here.
function MouseInputWaitHandle: LongInt;

// Install the application's nonblocking terminal writer after unit
// initialization and before FreeVision starts the mouse driver. Keeping this
// callback out of the uses graph is essential: a st_mouse -> st_video ->
// Drivers cycle would let Drivers probe the blocking RTL driver first.
procedure InstallMouseOutputWriter(AWriter: TMouseOutputWriter);

// The exact set of modes this driver wants the host terminal in, and the way
// back. One place decides, so anything that hands the terminal to a pane and
// takes it back again restores precisely what was enabled -- a pane's own
// program (a superterm inside a pane, say) writes its own mode resets
// straight to the host while it owns the screen, and they must be undone by
// the same rules that set them.
procedure HostMouseOn;
procedure HostMouseOff;

implementation

uses
  SysUtils, Mouse
  {$IFDEF UNIX}, BaseUnix, Sockets{$ENDIF}
  {$IFDEF LINUX}, Linux{$ENDIF};

var
  {$IFDEF UNIX}
  SysDriver: TMouseDriver;   // the RTL's, kept for the Linux console/gpm
  {$ENDIF}
  OurDriver: TMouseDriver;
  {$IFDEF UNIX}
  GpmWaitFd: cint = -1;
  {$ENDIF}
  MouseOutputWriter: TMouseOutputWriter = nil;

procedure InstallMouseOutputWriter(AWriter: TMouseOutputWriter);
begin
  MouseOutputWriter := AWriter;
end;

// Marks a parameter of a fixed driver signature as intentionally unused, the
// same diagnostic-free helper the vendored Free Vision units use.
procedure Unused(const A); begin if @A = nil then; end;

procedure WriteMouseControl(const S: AnsiString);
begin
  if Assigned(MouseOutputWriter) then
    MouseOutputWriter(S);
end;

{$IFDEF WINDOWS}
// Windows has no gpm and no Linux virtual console. The console (Windows
// Terminal, or conhost with VT enabled by st_video) reports the mouse as the
// very same ?1000/?1002/?1006 sequences a terminal emulator does, and st_kbd
// decodes them from the input stream. So there is nothing to register with the
// RTL mouse driver here: the two HostMouse* writers are the whole job.
function OnLinuxConsole: boolean;
begin
  Result := False;
end;

// The console mouse arrives as VT reports inside the ordinary input stream
// st_kbd already waits on, so there is no second descriptor to add to a wait
// set. This is the answer a Unix terminal emulator gives too; only a GNU/Linux
// virtual console with gpm has a separate one.
function MouseInputWaitHandle: LongInt;
begin
  Result := -1;
end;

procedure HostMouseOn;
begin
  // Through the installed writer, never the RTL text file: st_video owns the
  // single physical output path, and a buffered Write(Output) here could
  // reach the console out of order with the frames around it.
  WriteMouseControl(#27'[?1000h'#27'[?1002h'#27'[?1006h');
end;

procedure HostMouseOff;
begin
  WriteMouseControl(#27'[?1006l'#27'[?1002l'#27'[?1000l');
end;

function OurDetectMouse: byte;
begin
  Result := 2;
end;

procedure OurInitDriver;
begin
  HostMouseOn;
end;

procedure OurDoneDriver;
begin
  HostMouseOff;
end;

procedure OurShowMouse;
begin
end;

procedure OurHideMouse;
begin
end;

function OurGetMouseX: word;
begin
  Result := 0;
end;

function OurGetMouseY: word;
begin
  Result := 0;
end;

function OurGetMouseButtons: word;
begin
  Result := 0;
end;

// The driver record needs every slot filled (see the initialization comment),
// and a queue-only driver has nothing to do with a requested position.
procedure OurSetMouseXY(x, y: word);
begin
  Unused(x);                                         { Fixed signature }
  Unused(y);                                         { Fixed signature }
end;

procedure OurGetMouseEvent(var MouseEvent: TMouseEvent);
begin
  MouseEvent := Default(TMouseEvent);
end;

function OurPollMouseEvent(var MouseEvent: TMouseEvent): boolean;
begin
  MouseEvent := Default(TMouseEvent);
  Result := False;
end;

procedure OurPutMouseEvent(const MouseEvent: TMouseEvent);
begin
  Unused(MouseEvent);                                { Fixed signature }
end;

{$ELSE}

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

function FindGpmWaitHandle: cint;
var
  Fd: cint;
  Addr: sockaddr_un;
  AddrLen: TSockLen;
begin
  Result := -1;
  if not OnLinuxConsole then
    Exit;
  // FPC 3.2.2 keeps mouse.pp's gpm_fs private. Identify that one connected
  // descriptor once, immediately after the RTL opens it, by its Unix peer.
  // No descriptor is opened, duplicated or owned here.
  for Fd := 0 to 1023 do
  begin
    Addr := Default(sockaddr_un);
    AddrLen := SizeOf(Addr);
    if (fpGetPeerName(Fd, psockaddr(@Addr), @AddrLen) = 0) and
       (Addr.sun_family = AF_UNIX) and
       (StrPas(PChar(@Addr.sun_path[0])) = '/dev/gpmctl') then
      Exit(Fd);
  end;
end;

function MouseInputWaitHandle: LongInt;
begin
  Result := GpmWaitFd;
end;

// Can gpm take a connection right now? Asked without blocking: a listening
// socket with room accepts at once, one whose backlog is full says EAGAIN,
// and no gpm at all is a refusal or a missing path. Only the first answer
// makes it safe to let the RTL do its blocking connect.
function GpmAccepting: boolean;
var
  Fd: cint;
  Addr: sockaddr_un;
  Err: cint;
begin
  Result := False;
  Fd := fpsocket(AF_UNIX, SOCK_STREAM, 0);
  if Fd < 0 then
    Exit;
  try
    fpfcntl(Fd, F_SETFL, fpfcntl(Fd, F_GETFL) or O_NONBLOCK);
    Addr := Default(sockaddr_un);
    Addr.sun_family := AF_UNIX;
    StrPCopy(Addr.sun_path, '/dev/gpmctl');
    if fpconnect(Fd, psockaddr(@Addr), SizeOf(Addr)) = 0 then
      Result := True
    else
    begin
      Err := fpgeterrno;
      // EINPROGRESS never happens for AF_UNIX; EAGAIN is "backlog full"
      Result := False;
      if Err = 0 then
        Result := True;
    end;
  finally
    fpclose(Fd);
  end;
end;

function OurDetectMouse: byte;
begin
  if OnLinuxConsole then
  begin
    if GpmAccepting and Assigned(SysDriver.DetectMouse) then
    begin
      Result := SysDriver.DetectMouse();
      if Result <> 0 then
        GpmWaitFd := FindGpmWaitHandle;
    end
    else
      Result := 0;
  end
  else
    // every terminal emulator: we enable tracking ourselves below and
    // st_kbd decodes the reports, so there is always a mouse to declare
    Result := 2;
end;

procedure OurInitDriver;
begin
  if OnLinuxConsole then
  begin
    if Assigned(SysDriver.InitDriver) then
      SysDriver.InitDriver();
    GpmWaitFd := FindGpmWaitHandle;
    Exit;
  end;
  HostMouseOn;
end;

procedure HostMouseOn;
begin
  if OnLinuxConsole then
    Exit;                      // gpm, not escape sequences
  // normal tracking, motion while a button is held, SGR encoding (no
  // 223-column limit). Any-motion tracking (?1003) is not asked for: the
  // RTL queue holds 16 events and FreeVision drains one per loop, so a
  // sweep of the pointer under ?1003 overflows it for nothing.
  WriteMouseControl(#27'[?1000h'#27'[?1002h'#27'[?1006h');
end;

procedure HostMouseOff;
begin
  if OnLinuxConsole then
    Exit;
  WriteMouseControl(#27'[?1006l'#27'[?1002l'#27'[?1000l');
end;

procedure OurDoneDriver;
begin
  if OnLinuxConsole then
  begin
    if Assigned(SysDriver.DoneDriver) then
      SysDriver.DoneDriver();
    GpmWaitFd := -1;
    Exit;
  end;
  HostMouseOff;
end;
{$ENDIF}

initialization
  {$IFDEF UNIX}
  SysDriver := Default(TMouseDriver);
  GetMouseDriver(SysDriver);
  OurDriver := SysDriver;           // Show/Hide/Get*/Poll stay the RTL's
  {$ELSE}
  // Do not copy the stock Win32 callbacks. Its InitDriver starts a thread
  // which drains every INPUT_RECORD (and discards keys now owned by st_kbd).
  // The generic queue is all we need: st_kbd decodes VT mouse reports and
  // feeds it with PutMouseEvent.
  OurDriver := Default(TMouseDriver);
  {$ENDIF}
  OurDriver.UseDefaultQueue := True;
  OurDriver.DetectMouse := @OurDetectMouse;
  OurDriver.InitDriver := @OurInitDriver;
  OurDriver.DoneDriver := @OurDoneDriver;
  {$IFDEF WINDOWS}
  // FPC's public wrappers dispatch several of these callbacks directly.
  // Supply a complete driver record even though the default queue owns real
  // events; leaving callback slots unset produced invalid small addresses in
  // the Win64 record copied by SetMouseDriver on this FPC build.
  OurDriver.ShowMouse := @OurShowMouse;
  OurDriver.HideMouse := @OurHideMouse;
  OurDriver.GetMouseX := @OurGetMouseX;
  OurDriver.GetMouseY := @OurGetMouseY;
  OurDriver.GetMouseButtons := @OurGetMouseButtons;
  OurDriver.SetMouseXY := @OurSetMouseXY;
  OurDriver.GetMouseEvent := @OurGetMouseEvent;
  OurDriver.PollMouseEvent := @OurPollMouseEvent;
  OurDriver.PutMouseEvent := @OurPutMouseEvent;
  {$ENDIF}
  SetMouseDriver(OurDriver);

end.
