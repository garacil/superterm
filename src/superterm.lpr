(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Main program: starts the FreeVision application
*)

program superterm;

{$mode objfpc}{$H+}

uses
  // The pthread thread manager must be installed before Classes or any unit
  // which can create a TThread. It starts no threads by itself, so the daemon
  // still forks while the parent is single-threaded.
  {$ifdef unix}cthreads,{$endif}
  // st_mouse BEFORE Drivers: it must register its mouse driver before the
  // Drivers unit initialises and asks the RTL whether a mouse exists
  SysUtils, BaseUnix, Objects, st_mouse, Drivers, App, st_fvui, st_server,
  st_video, st_kbd, st_config, st_cli, st_debug;

// The daemon child must run Pascal unit finalizers (notably HeapTrc) after
// its inherited TApplication has unwound, but must not enter the platform's
// normal post-fork exit/atexit path.  This is the RTL routine System itself
// calls from Halt; FpExit below is the raw Unix syscall on Linux and macOS.
procedure FinalizePascalUnits; external name 'FPC_FINALIZEUNITS';

procedure Main;
var
  STApp: PSuperApp;
  i, CliExitCode: integer;
  AttachName: string;
  ListOnly: boolean;
  Infos: TSessionInfoArray;
  BootCfg: TConfig;

begin
  // In a HeapTrc build this also gives even short-lived CLI commands their
  // own PID-tagged memory report. The daemon calls it again after fork.
  DebugSetRole('client');
  AttachRequested := False;
  AttachSocket := '';
  // language resolved BEFORE printing anything: the CLI speaks the IDE
  // language (or the LANG one if there is no configuration yet)
  BootCfg := Default(TConfig);
  if FileExists(ConfigFile) then
  begin
    LoadConfig(BootCfg);
    CurrentLanguage := BootCfg.Language;
  end
  else if Copy(LowerCase(GetEnvironmentVariable('LANG')), 1, 2) = 'es' then
    CurrentLanguage := ulSpanish;
  // CLI commands (list/send/capture/... in English or Spanish): they run
  // and exit; the TUI startup and --attach continue through here
  if RunCli(CliExitCode) then
  begin
    System.ExitCode := CliExitCode;
    Exit;
  end;
  AttachName := '';
  ListOnly := False;
  i := 1;
  while i <= ParamCount do
  begin
    if (ParamStr(i) = '--session') or (ParamStr(i) = '--sesion') then
    begin
      if i < ParamCount then
      begin
        CliSessionName := ParamStr(i + 1);
        Inc(i);
      end;
    end
    else if ParamStr(i) = '--attach' then
    begin
      AttachRequested := True;
      if (i < ParamCount) and (Copy(ParamStr(i + 1), 1, 1) <> '-') then
      begin
        AttachName := ParamStr(i + 1);
        Inc(i);
      end;
    end
    else if ParamStr(i) = '--list-sessions' then
      ListOnly := True;
    Inc(i);
  end;
  if ListOnly then
  begin
    // simple table for scripts; also purges orphaned sockets
    if EnumerateSessions(Infos) then
    begin
      WriteLn(Format('%-24s %-16s %5s  %s',
        ['NAME', 'PROFILE', 'PANES', 'CREATED']));
      for i := 0 to High(Infos) do
        WriteLn(Format('%-24s %-16s %5d  %s',
          [Infos[i].Name, Infos[i].Profile, Infos[i].PaneCount,
           Infos[i].Created]));
    end
    else
      WriteLn('superterm: no detached sessions');
    System.ExitCode := 0;
    Exit;
  end;
  if AttachRequested then
  begin
    if not EnumerateSessions(Infos) then
    begin
      WriteLn(StdErr, 'superterm: no detached session is available');
      System.ExitCode := 1;
      Exit;
    end;
    if AttachName <> '' then
    begin
      // session names are case-sensitive: exact match first; only when
      // there is none, second pass with the sanitized name
      for i := 0 to High(Infos) do
        if Infos[i].Name = AttachName then
        begin
          AttachSocket := Infos[i].SocketPath;
          break;
        end;
      if AttachSocket = '' then
        for i := 0 to High(Infos) do
          if Infos[i].Name = SanitizeSessionName(AttachName) then
          begin
            AttachSocket := Infos[i].SocketPath;
            break;
          end;
      if AttachSocket = '' then
      begin
        WriteLn(StdErr, 'superterm: no session named "', AttachName, '"');
        System.ExitCode := 1;
        Exit;
      end;
      // inside a pane: never the session this pane belongs to, nor one
      // above it (see st_server.SessionAllowedFromHere)
      for i := 0 to High(Infos) do
        if (Infos[i].SocketPath = AttachSocket) and
           (not SessionAllowedFromHere(Infos[i], Infos)) then
        begin
          if CurrentLanguage = ulSpanish then
            WriteLn(StdErr, 'superterm: "', Infos[i].Name,
              '" es la sesion de este panel (o una de sus antecesoras); ',
              'engancharse a ella seria un espejo sin fin.')
          else
            WriteLn(StdErr, 'superterm: "', Infos[i].Name,
              '" is the session this pane belongs to (or one above it); ',
              'attaching to it would be a mirror without end.');
          System.ExitCode := 2;
          Exit;
        end;
    end
    else
    begin
      // no name: the one session that is safe from here, if there is
      // exactly one; several leave the choice to the picker
      KeepAllowedSessions(Infos);
      if Length(Infos) = 1 then
        AttachSocket := Infos[0].SocketPath
      else if Length(Infos) = 0 then
      begin
        if CurrentLanguage = ulSpanish then
          WriteLn(StdErr, 'superterm: no hay ninguna sesion a la que ',
            'engancharse desde aqui.')
        else
          WriteLn(StdErr, 'superterm: no session can be attached from here.');
        System.ExitCode := 1;
        Exit;
      end;
    end;
    // with several sessions and no name, the app selector decides
  end;
  // Nesting. A superterm inside a pane used to be refused outright, because
  // attaching the pane to its own session mirrors forever. The guard is now
  // by identity: every pane carries SUPERTERM_SESSION_CHAIN, each daemon
  // writes its id in the sidecar, and only the sessions on the chain are
  // refused -- above, for an explicit name; in KeepAllowedSessions for the
  // auto-pick and the picker. A new session, or another session, is as safe
  // from a pane as from any terminal. SUPERTERM_ALLOW_NESTED=1 disables it.
  // a crash here loses the visible terminal only, but the report is just as
  // useful and costs nothing when nothing goes wrong
  DebugSetRole('client');
  InstallCrashHandler;
  // st_mouse already decided whether there is a mouse (see that unit); what
  // is left is to say so in the trace, which is the one line that explains a
  // machine where the mouse is missing
  if DebugActive then
    DebugLog(Format('mouse: TERM=%s console=%s ButtonCount=%d',
      [GetEnvironmentVariable('TERM'), BoolToStr(OnLinuxConsole, True),
       Drivers.ButtonCount]));
  // custom keyboard driver: lone ESC works (timeout, not an Alt prefix)
  InstallSuperKeyboard;
  // save the console cursor position before touching the video
  CaptureConsoleCursor;
  STApp := New(PSuperApp, Init);
  Application := Pointer(STApp);
  // attach cancelled or failed during Init: do not start the event
  // loop (a cmQuit posted in Init would be lost when entering Run)
  if not STApp^.AbortRun then
  begin
    // server-always: the freshly built workspace moves to a daemon
    // and this instance becomes a client (config [session] server=always)
    STApp^.PromoteToServer;
    if not STApp^.AbortRun then
    begin
      if DebugActive then DebugLog('== BOOT: startup complete, entering event loop ==');
      STApp^.FinishBoot;   // release the boot lock and paint ONCE
      if not STApp^.AbortRun then
        STApp^.Run;
    end;
  end;
  Dispose(STApp, Done);
  // stop the terminal reporting to whatever runs next, and drop anything it
  // already reported, before putting the cursor back
  ReleaseConsoleInput;
  // leave the cursor where it was at program launch (quit or detach)
  RestoreConsoleCursor;
end;

begin
  try
    Main;
  finally
    if DetachedServerChildFinished then
    begin
      // FinalizeUnits decrements the RTL init count before every callback, so
      // this emits one HeapTrc report.  The raw exit prevents System/Halt or
      // libc atexit from repeating inherited pre-fork cleanup afterwards.
      FinalizePascalUnits;
      FpExit(System.ExitCode);
    end;
  end;
end.
