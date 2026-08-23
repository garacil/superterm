(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Main program: starts the FreeVision application
*)

program superterm;

{$mode objfpc}{$H+}

uses
  SysUtils, Objects, Drivers, App, st_fvui, st_server, st_video, st_kbd,
  st_config, st_cli, st_debug;

var
  STApp: PSuperApp;
  i: integer;
  AttachName: string;
  ListOnly: boolean;
  Infos: TSessionInfoArray;
  BootCfg: TConfig;

begin
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
  RunCli;
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
    Halt(0);
  end;
  if AttachRequested then
  begin
    if not EnumerateSessions(Infos) then
    begin
      WriteLn(StdErr, 'superterm: no detached session is available');
      Halt(1);
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
        Halt(1);
      end;
    end
    else if Length(Infos) = 1 then
      AttachSocket := Infos[0].SocketPath;
    // with several sessions and no name, the app selector decides
  end;
  // refuse to nest: launching the interactive UI (attach or a new session)
  // inside a superterm pane would attach the pane to its own session and
  // mirror forever. The control CLI (list/send/capture/...) already ran and
  // Halted in RunCli, so those still work inside a pane; only the TUI start
  // reaches here. Escape hatch mirrors tmux's $TMUX: SUPERTERM_ALLOW_NESTED.
  if (GetEnvironmentVariable('SUPERTERM') <> '') and
     (GetEnvironmentVariable('SUPERTERM_ALLOW_NESTED') = '') then
  begin
    if CurrentLanguage = ulSpanish then
    begin
      WriteLn(StdErr, 'superterm: ya estas dentro de una sesion de superterm; ' +
        'no se anida.');
      WriteLn(StdErr, '  Usa list/send/capture desde aqui, o Ctrl-Q d para ' +
        'separarte primero.');
      WriteLn(StdErr, '  (exporta SUPERTERM_ALLOW_NESTED=1 para forzar el anidado)');
    end
    else
    begin
      WriteLn(StdErr, 'superterm: already inside a superterm session; ' +
        'refusing to nest.');
      WriteLn(StdErr, '  Use list/send/capture from here, or Ctrl-Q d to ' +
        'detach first.');
      WriteLn(StdErr, '  (export SUPERTERM_ALLOW_NESTED=1 to force nesting)');
    end;
    Halt(2);
  end;
  // a crash here loses the visible terminal only, but the report is just as
  // useful and costs nothing when nothing goes wrong
  DebugSetRole('client');
  InstallCrashHandler;
  // Linux console: let FreeVision try the mouse at all.
  //
  // Drivers sets ButtonCount at unit initialisation from the RTL's terminal
  // detection, which matches TERM against a fixed list -- 'cons', 'eterm',
  // 'gnome', 'konsole', 'rxvt', 'screen', 'xterm' (mouse.pp,
  // detect_xterm_mouse). 'linux' is on none of them, so on a real virtual
  // console ButtonCount comes back 0, InitEvents skips Mouse.InitMouse
  // entirely, and InitMouse is the ONLY thing that would have opened gpm.
  // The result is no mouse on the console however well gpm is running.
  //
  // Saying a mouse exists lets the RTL's own gpm path run. It costs nothing
  // when it does not apply: without gpm, gpm_open fails and every poll
  // returns immediately. Restricted to the console on purpose -- forcing it
  // on a graphical terminal would send the RTL down the same gpm path, and
  // gpm reports the physical console, not the window.
  if IsLinuxConsole and (Drivers.ButtonCount = 0) then
    Drivers.ButtonCount := 2;
  if DebugActive then
    DebugLog(Format('mouse: TERM=%s console=%s ButtonCount=%d',
      [GetEnvironmentVariable('TERM'), BoolToStr(IsLinuxConsole, True),
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
    if DebugActive then DebugLog('== BOOT: startup complete, entering event loop ==');
    STApp^.FinishBoot;   // release the boot lock and paint ONCE
    if not STApp^.AbortRun then
      STApp^.Run;
  end;
  Dispose(STApp, Done);
  // stop the terminal reporting to whatever runs next, and drop anything it
  // already reported, before putting the cursor back
  ReleaseConsoleInput;
  // leave the cursor where it was at program launch (quit or detach)
  RestoreConsoleCursor;
end.
