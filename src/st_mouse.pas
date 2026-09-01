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

  On a real virtual console, the opposite: TERM is 'linux', which is not on
  the list either, so the RTL goes to gpm -- but FreeVision only initialises
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

// True on a Linux virtual console (TERM=linux), where the only possible
// mouse is gpm.
function OnLinuxConsole: boolean;
// Tracking is enabled through the client's central emitter so it cannot be
// interleaved with the frames that emitter queues. It is reached by a hook
// rather than by USING st_video, which would be a dependency cycle in spirit
// and a real one in effect: st_video reaches Drivers and Mouse through st_kbd,
// so this unit would then initialise AFTER them. The main program's uses
// clause states why that must never happen -- this driver has to register
// before the Drivers unit asks the RTL whether a mouse exists. Measured when
// it was inverted: the RTL installed its own console driver and the client
// blocked forever in connect() to /dev/gpmctl.
var
  HostMouseEmit: procedure(const S: AnsiString) = nil;


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
  SysUtils, BaseUnix, Sockets, Mouse;

var
  SysDriver: TMouseDriver;   // the RTL's, kept for the console
  OurDriver: TMouseDriver;


function OnLinuxConsole: boolean;
var
  T: string;
begin
  T := LowerCase(GetEnvironmentVariable('TERM'));
  Result := (T = 'linux') or (Copy(T, 1, 6) = 'linux-');
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
      Result := SysDriver.DetectMouse()
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
    Exit;
  end;
  HostMouseOn;
end;
procedure EmitToHost(const S: AnsiString);
begin
  if Assigned(HostMouseEmit) then
    HostMouseEmit(S)
  else
  begin
    Write(S);
    Flush(Output);
  end;
end;


procedure HostMouseOn;
begin
  if OnLinuxConsole then
    Exit;                      // gpm, not escape sequences
  // normal tracking, motion while a button is held, SGR encoding (no
  // 223-column limit). Any-motion tracking (?1003) is not asked for: the
  // RTL queue holds 16 events and FreeVision drains one per loop, so a
  // sweep of the pointer under ?1003 overflows it for nothing.
  EmitToHost(#27'[?1000h'#27'[?1002h'#27'[?1006h');
end;

procedure HostMouseOff;
begin
  if OnLinuxConsole then
    Exit;
  EmitToHost(#27'[?1006l'#27'[?1002l'#27'[?1000l');
end;

procedure OurDoneDriver;
begin
  if OnLinuxConsole then
  begin
    if Assigned(SysDriver.DoneDriver) then
      SysDriver.DoneDriver();
    Exit;
  end;
  HostMouseOff;
end;

initialization
  SysDriver := Default(TMouseDriver);
  GetMouseDriver(SysDriver);
  OurDriver := SysDriver;           // Show/Hide/Get*/Poll stay the RTL's
  OurDriver.UseDefaultQueue := True;
  OurDriver.DetectMouse := @OurDetectMouse;
  OurDriver.InitDriver := @OurInitDriver;
  OurDriver.DoneDriver := @OurDoneDriver;
  SetMouseDriver(OurDriver);

end.
