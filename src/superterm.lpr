(*
  Autor: Germán Luis Aracil Boned
  Proyecto: superterm - terminal con autologin, splits y sesiones
  Programa principal: arranca la aplicacion FreeVision
*)

program superterm;

{$mode objfpc}{$H+}

uses
  Objects, Drivers, App, st_fvui, st_server, st_video;

var
  STApp: PSuperApp;

begin
  AttachRequested := False;
  if ParamCount > 0 then
    AttachRequested := (ParamStr(1) = '--attach');
  if AttachRequested and (not SessionSocketIsLive) then
  begin
    WriteLn(StdErr, 'superterm: no detached session is available');
    Halt(1);
  end;
  // guardar la posicion real del cursor antes de tocar video/teclado
  CaptureConsoleCursor;
  STApp := New(PSuperApp, Init);
  Application := Pointer(STApp);
  STApp^.Run;
  Dispose(STApp, Done);
  // dejar el cursor donde estaba al lanzar el programa (cierre o detach)
  RestoreConsoleCursor;
end.
