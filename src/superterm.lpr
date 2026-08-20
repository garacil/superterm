(*
  Autor: Germán Luis Aracil Boned
  Proyecto: superterm - terminal con autologin, splits y sesiones
  Programa principal: arranca la aplicacion FreeVision
*)

program superterm;

{$mode objfpc}{$H+}

uses
  SysUtils, Objects, Drivers, App, st_fvui, st_server, st_video, st_kbd;

var
  STApp: PSuperApp;
  i: integer;
  AttachName: string;
  ListOnly: boolean;
  Infos: TSessionInfoArray;

begin
  AttachRequested := False;
  AttachSocket := '';
  AttachName := '';
  ListOnly := False;
  i := 1;
  while i <= ParamCount do
  begin
    if ParamStr(i) = '--attach' then
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
    // tabla simple para scripts; tambien purga sockets huerfanos
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
      for i := 0 to High(Infos) do
        if SameText(Infos[i].Name, AttachName) or
           SameText(Infos[i].Name, SanitizeSessionName(AttachName)) then
          AttachSocket := Infos[i].SocketPath;
      if AttachSocket = '' then
      begin
        WriteLn(StdErr, 'superterm: no session named "', AttachName, '"');
        Halt(1);
      end;
    end
    else if Length(Infos) = 1 then
      AttachSocket := Infos[0].SocketPath;
    // con varias sesiones y sin nombre, el selector de la app decide
  end;
  // driver de teclado propio: ESC solitario funciona (timeout, no prefijo Alt)
  InstallSuperKeyboard;
  // guardar la posicion del cursor de la consola antes de tocar el video
  CaptureConsoleCursor;
  STApp := New(PSuperApp, Init);
  Application := Pointer(STApp);
  STApp^.Run;
  Dispose(STApp, Done);
  // dejar el cursor donde estaba al lanzar el programa (cierre o detach)
  RestoreConsoleCursor;
end.
